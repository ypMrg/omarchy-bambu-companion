# frozen_string_literal: true

require "digest"
require "io/wait"
require "json"
require "tempfile"
require_relative "archive_name"
require_relative "native_storage_error"
require_relative "print_file_hints"
require_relative "tls_certificate"

module BambuCompanion
  class NativeStorageClient
    DEFAULT_PORT = 6000
    DEFAULT_MAX_BYTES = 1 << 30
    DEFAULT_MAX_FRAME_BYTES = 16 << 20
    DEFAULT_TIMEOUT = 30.0
    MAX_LIST_ENTRIES = 10_000
    MAX_RESPONSE_FRAMES = 100_000
    MAX_REMOTE_PATH_BYTES = 4096

    CLIENT_LOGIN_MAGIC = 0x0101013f
    SERVER_LOGIN_MAGIC = 0x0001013f
    CLIENT_CTRL_MAGIC = 0x0102013f
    SERVER_CTRL_MAGIC = 0x0002013f
    SETUP_MTYPE = 12_291
    RPC_MTYPE = 12_289
    LIST_INFO = 1
    SUB_FILE = 2
    FILE_DOWNLOAD = 4

    Entry = Data.define(:name, :path, :size)

    def initialize(config:, secret:, port: DEFAULT_PORT,
                   max_bytes: DEFAULT_MAX_BYTES,
                   max_frame_bytes: DEFAULT_MAX_FRAME_BYTES,
                   timeout: DEFAULT_TIMEOUT, socket_factory: nil,
                   client_id: nil)
      @config = config
      @secret = String(secret)
      @port = positive_integer(port, "port", maximum: 65_535)
      @max_bytes = positive_integer(max_bytes, "max_bytes")
      @max_frame_bytes = positive_integer(max_frame_bytes, "max_frame_bytes")
      @timeout = positive_finite(timeout, "timeout")
      @client_id = normalize_client_id(client_id || default_client_id)
      @socket_factory = socket_factory || method(:open_socket)
    end

    def download(hints:, destination:, cancelled: -> { false }, progress: ->(*) {})
      check_cancelled!(cancelled)
      socket = @socket_factory.call(
        host: @config.host, port: @port,
        fingerprint: trusted_fingerprints,
        connect_timeout: [@timeout, 8.0].min,
        handshake_timeout: @timeout, cancelled: cancelled
      )
      protocol = Protocol.new(
        socket: socket, timeout: @timeout,
        max_frame_bytes: @max_frame_bytes, cancelled: cancelled
      )
      protocol.login(username: @config.username, secret: @secret)
      protocol.setup(client_id: @client_id)
      entry = locate_internal_entry(protocol, hints)
      raise_too_large if entry.size && entry.size > @max_bytes

      download_active_archive(
        protocol, entry, hints: hints, destination: destination,
        cancelled: cancelled, progress: progress
      )
      entry.path || entry.name
    rescue NativeStorageError
      raise
    rescue TlsCertificateError => error
      raise NativeStorageError.new(error.code, error.message), cause: nil
    rescue StandardError
      raise NativeStorageError.new(
        "transport", "Internal-storage transfer failed"
      ), cause: nil
    ensure
      safely_close(socket)
    end

    private

    def locate_internal_entry(protocol, hints)
      entry = locate_entry(list_entries(protocol, storage: "internal"), hints)
      return entry
    rescue NativeStorageError => error
      raise unless %w[file_not_found storage_unavailable].include?(error.code)

      locate_entry(list_entries(protocol, storage: "emmc"), hints)
    end

    def list_entries(protocol, storage:)
      entries = []
      protocol.request(
        cmdtype: LIST_INFO,
        req: { "type" => "model", "api_version" => 2,
               "notify" => "DETAIL", "storage" => storage }
      ) do |message, binary|
        raise_protocol("LIST_INFO unexpectedly returned binary data") unless binary.empty?

        files = message.dig("reply", "file_lists")
        next unless files.is_a?(Array)

        files.each do |item|
          entry = normalize_entry(item)
          next unless entry

          entries << entry
          raise NativeStorageError.new(
            "too_large", "Internal-storage listing exceeds safe limits"
          ), cause: nil if entries.length > MAX_LIST_ENTRIES
        end
      end
      entries.uniq { |entry| [entry.path, entry.name] }
    end

    def normalize_entry(item)
      return unless item.is_a?(Hash)

      name = bounded_remote_text(item["name"])
      path = bounded_remote_text(item["path"], optional: true)
      return unless name && print_archive?(name)

      size = nonnegative_integer(item["size"], optional: true)
      Entry.new(name: name.freeze, path: path&.freeze, size: size)
    end

    def locate_entry(entries, hints)
      values = hints.to_h
      subtask = values["subtask_name"] || values[:subtask_name]
      token = ArchiveName.canonical(subtask)
      if token.empty?
        raise NativeStorageError.new(
          "file_not_found", "Active print archive name is unavailable"
        ), cause: nil
      end

      matches = entries.select { |entry| ArchiveName.canonical(entry.name) == token }
      %w[.gcode.3mf .3mf .gcode].each do |extension|
        tier = matches.select { |entry| entry.name.downcase.end_with?(extension) }
        return tier.first if tier.one?
        raise_ambiguous unless tier.empty?
      end
      raise NativeStorageError.new(
        "file_not_found", "Active print archive was not found in internal storage"
      ), cause: nil
    rescue NoMethodError, TypeError
      raise NativeStorageError.new(
        "file_not_found", "Active print archive name is unavailable"
      ), cause: nil
    end

    def download_active_archive(protocol, entry, hints:, destination:, cancelled:, progress:)
      plate_entry = PrintFileHints.internal_gcode_entry(hints)
      if entry.path && plate_entry
        begin
          return download_subfile_archive(
            protocol, entry, plate_entry: plate_entry,
            destination: destination, cancelled: cancelled,
            progress: progress
          )
        rescue NativeStorageError => error
          raise unless %w[file_not_found unsupported].include?(error.code)
        end
      end

      download_entry(
        protocol, entry, destination: destination,
        cancelled: cancelled, progress: progress
      )
    end

    def download_subfile_archive(protocol, entry, plate_entry:, destination:,
                                 cancelled:, progress:)
      thumbnail_entry = plate_entry.sub(/\.gcode\z/i, ".png")
      paths = [plate_entry, thumbnail_entry].map { |name| "#{entry.path}##{name}" }
      temporary = create_temporary(destination)
      temporary_path = temporary.path
      received = 0
      progress.call(0, nil)

      protocol.request(
        cmdtype: SUB_FILE, req: { "paths" => paths, "zip" => true }
      ) do |message, binary|
        check_cancelled!(cancelled)
        reply = message["reply"].is_a?(Hash) ? message["reply"] : {}
        declared_size = nonnegative_integer(reply["size"], optional: binary.empty?)
        if declared_size && declared_size != binary.bytesize
          raise_protocol("Internal-storage sub-file size is inconsistent")
        end
        next if binary.empty?

        raise_too_large if received + binary.bytesize > @max_bytes
        temporary.write(binary)
        received += binary.bytesize
        progress.call(received, nil)
      end

      temporary.flush
      raise_protocol("Internal-storage sub-file archive is invalid") unless zip_archive?(temporary)

      publish_temporary(temporary, temporary_path, destination)
      temporary_path = nil
    ensure
      safely_close(temporary)
      safely_unlink(temporary_path)
    end

    def download_entry(protocol, entry, destination:, cancelled:, progress:)
      temporary = create_temporary(destination)
      temporary_path = temporary.path
      progress.call(0, entry.size)
      request = entry.path ? { "path" => entry.path, "offset" => 0 } :
        { "file" => entry.name, "offset" => 0 }
      received = 0
      expected_total = entry.size
      total_reported = false
      expected_md5 = nil
      digest = Digest::MD5.new

      protocol.request(cmdtype: FILE_DOWNLOAD, req: request) do |message, binary|
        check_cancelled!(cancelled)
        reply = message["reply"].is_a?(Hash) ? message["reply"] : {}
        declared_size = nonnegative_integer(reply["size"], optional: binary.empty?)
        if declared_size && declared_size != binary.bytesize
          raise_protocol("Internal-storage chunk size is inconsistent")
        end
        unless binary.empty?
          offset = nonnegative_integer(reply["offset"])
          raise_protocol("Internal-storage chunk offset is inconsistent") unless offset == received

          total = nonnegative_integer(reply["total"])
          total_reported = true
          raise_protocol("Internal-storage total size changed") if expected_total && total != expected_total

          expected_total = total
          raise_too_large if received + binary.bytesize > @max_bytes
          temporary.write(binary)
          digest.update(binary)
          received += binary.bytesize
          progress.call(received, expected_total)
        end
        if Integer(message["result"]).zero?
          expected_md5 = md5_value(reply["file_md5"] || message["file_md5"])
        end
      end

      raise_protocol("Internal-storage total size is missing") unless total_reported
      if expected_total && received != expected_total
        raise_protocol("Internal-storage download length is inconsistent")
      end
      raise_protocol("Internal-storage checksum is missing") unless expected_md5
      unless secure_digest_equal?(expected_md5, digest.hexdigest)
        raise NativeStorageError.new(
          "checksum", "Internal-storage download checksum failed"
        ), cause: nil
      end
      publish_temporary(temporary, temporary_path, destination)
      temporary_path = nil
    ensure
      safely_close(temporary)
      safely_unlink(temporary_path)
    end

    def print_archive?(name)
      name.match?(/(?:\.gcode(?:\.3mf)?|\.3mf)\z/i)
    end

    def create_temporary(destination)
      Tempfile.create(
        [".#{File.basename(destination)}-", ".part"],
        File.dirname(destination), mode: 0o600, binmode: true
      )
    end

    def publish_temporary(temporary, temporary_path, destination)
      temporary.flush
      temporary.fsync
      temporary.close
      File.rename(temporary_path, destination)
    end

    def zip_archive?(temporary)
      return false if temporary.size < 4

      temporary.rewind
      temporary.read(4).start_with?("PK".b)
    end

    def bounded_remote_text(value, optional: false)
      return if optional && value.nil?

      text = String(value).dup
      text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY
      return unless text.valid_encoding?
      return if text.empty? || text.bytesize > MAX_REMOTE_PATH_BYTES
      return if text.match?(/[\x00-\x1f\x7f]/)

      text
    rescue TypeError
      nil
    end

    def nonnegative_integer(value, optional: false)
      return if optional && value.nil?

      integer = Integer(value)
      return integer if integer >= 0

      raise_protocol("Internal-storage response contains an invalid number")
    rescue ArgumentError, TypeError
      raise_protocol("Internal-storage response contains an invalid number")
    end

    def md5_value(value)
      return if value.nil?

      text = String(value)
      raise_protocol("Internal-storage checksum is invalid") unless text.match?(/\A[0-9a-f]{32}\z/i)

      text.downcase
    rescue TypeError
      raise_protocol("Internal-storage checksum is invalid")
    end

    def secure_digest_equal?(expected, actual)
      OpenSSL.fixed_length_secure_compare(expected, actual)
    end

    def open_socket(host:, port:, fingerprint:, connect_timeout:,
                    handshake_timeout:, cancelled:)
      TlsCertificate.open_pinned(
        host: host, port: port, fingerprint: fingerprint,
        connect_timeout: connect_timeout,
        handshake_timeout: handshake_timeout, cancelled: cancelled
      )
    end

    def trusted_fingerprints
      [@config.mqtt_tls_fingerprint, @config.ftps_tls_fingerprint].compact.uniq.freeze
    end

    def normalize_client_id(value)
      text = String(value)
      unless text.match?(/\A[A-Za-z0-9_-]{8}\z/)
        raise ArgumentError, "client_id must contain exactly 8 safe characters"
      end

      text.freeze
    end

    def default_client_id
      Digest::SHA256.hexdigest("bambu-companion:#{Process.pid}:#{object_id}")[0, 8]
    end

    def positive_integer(value, name, maximum: nil)
      integer = Integer(value)
      valid = integer.positive? && (!maximum || integer <= maximum)
      raise ArgumentError, "#{name} is invalid" unless valid

      integer
    end

    def positive_finite(value, name)
      number = Float(value)
      raise ArgumentError, "#{name} is invalid" unless number.finite? && number.positive?

      number
    end

    def check_cancelled!(cancelled)
      return unless cancelled.call

      raise NativeStorageError.new(
        "cancelled", "Internal-storage download cancelled"
      ), cause: nil
    end

    def raise_ambiguous
      raise NativeStorageError.new(
        "ambiguous_file", "Multiple internal-storage files match the active print"
      ), cause: nil
    end

    def raise_too_large
      raise NativeStorageError.new(
        "too_large", "Print file exceeds #{@max_bytes} bytes"
      ), cause: nil
    end

    def raise_protocol(message)
      raise NativeStorageError.new("protocol", message), cause: nil
    end

    def safely_close(io)
      return unless io
      return if io.respond_to?(:closed?) && io.closed?

      io.close
    rescue StandardError
      nil
    end

    def safely_unlink(path)
      File.unlink(path) if path && File.exist?(path)
    rescue StandardError
      nil
    end

    class Protocol
      def initialize(socket:, timeout:, max_frame_bytes:, cancelled:)
        @socket = socket
        @timeout = timeout
        @max_frame_bytes = max_frame_bytes
        @cancelled = cancelled
        @frame_sequence = 0
        @rpc_sequence = 0
      end

      def login(username:, secret:)
        payload = login_field(username, "username") + login_field(secret, "access code")
        write_frame(CLIENT_LOGIN_MAGIC, payload)
        magic, = read_frame
        raise_protocol("Internal-storage login was rejected") unless magic == SERVER_LOGIN_MAGIC
      end

      def setup(client_id:)
        payload = {
          "sequence" => 0, "mtype" => SETUP_MTYPE,
          "req" => {
            "t_av" => 1, "mtype" => RPC_MTYPE, "peer_t" => 3,
            "pid" => client_id, "ver" => "02.03.00.00"
          }
        }
        write_control(payload)
        message, binary = read_control
        valid = binary.empty? && message["mtype"] == SETUP_MTYPE &&
                integer(message["sequence"]) == 0 && integer(message["result"]) == 0
        raise_protocol("Internal-storage setup failed") unless valid
      end

      def request(cmdtype:, req:)
        @rpc_sequence += 1
        sequence = @rpc_sequence
        write_control(
          "mtype" => RPC_MTYPE, "cmdtype" => cmdtype,
          "sequence" => sequence, "req" => req
        )
        frames = 0
        loop do
          frames += 1
          raise_protocol("Internal-storage response has too many frames") if frames > MAX_RESPONSE_FRAMES

          message, binary = read_control
          unless integer(message["mtype"]) == RPC_MTYPE &&
                 integer(message["cmdtype"]) == cmdtype &&
                 integer(message["sequence"]) == sequence
            next if message.key?("notify") && !message.key?("result")

            raise_protocol("Internal-storage response does not match the request")
          end
          result = integer(message["result"])
          raise_result(result) unless [0, 1].include?(result)

          yield message, binary
          break if result.zero?
        end
      end

      private

      def login_field(value, name)
        text = String(value).b
        unless text.bytesize.between?(1, 8) && text.each_byte.all? { |byte| byte.between?(0x21, 0x7e) }
          raise NativeStorageError.new(
            "authentication", "Internal-storage #{name} is invalid"
          ), cause: nil
        end

        text.ljust(8, "\0")
      end

      def write_control(message)
        write_frame(CLIENT_CTRL_MAGIC, JSON.generate(message))
      end

      def read_control
        magic, payload = read_frame
        raise_protocol("Internal-storage response used an unexpected channel") unless magic == SERVER_CTRL_MAGIC

        parse_control(payload)
      end

      def parse_control(payload)
        separator, separator_bytes = control_separator(payload)
        json_bytes = separator ? payload.byteslice(0, separator) : payload
        binary = separator ? payload.byteslice((separator + separator_bytes)..) : "".b
        json_text = json_bytes.dup.force_encoding(Encoding::UTF_8)
        raise_protocol("Internal-storage response JSON is invalid") unless json_text.valid_encoding?

        message = JSON.parse(json_text)
        raise_protocol("Internal-storage response JSON is not an object") unless message.is_a?(Hash)

        [message, binary || "".b]
      rescue JSON::ParserError
        raise_protocol("Internal-storage response JSON is invalid")
      end

      def control_separator(payload)
        lf = payload.index("\n\n".b)
        crlf = payload.index("\r\n\r\n".b)
        return [crlf, 4] if crlf && (!lf || crlf < lf)
        return [lf, 2] if lf

        [nil, 0]
      end

      def write_frame(magic, payload)
        bytes = String(payload).b
        raise_protocol("Internal-storage request is too large") if bytes.bytesize > @max_frame_bytes

        header = [bytes.bytesize, magic, @frame_sequence, 0].pack("V4")
        @frame_sequence = (@frame_sequence + 1) & 0xffff_ffff
        write_exact(header + bytes)
      end

      def read_frame
        length, magic, _sequence, reserved = read_exact(16).unpack("V4")
        raise_protocol("Internal-storage frame header is invalid") unless reserved.zero?
        raise_protocol("Internal-storage response frame is too large") if length > @max_frame_bytes

        [magic, read_exact(length)]
      end

      def read_exact(length)
        buffer = String.new(capacity: length, encoding: Encoding::BINARY)
        deadline = monotonic_now + @timeout
        while buffer.bytesize < length
          check_cancelled!
          chunk = @socket.read_nonblock(length - buffer.bytesize, exception: false)
          case chunk
          when :wait_readable then wait_for(:readable, deadline)
          when :wait_writable then wait_for(:writable, deadline)
          when nil then raise_protocol("Internal-storage connection closed unexpectedly")
          else
            raise_protocol("Internal-storage connection closed unexpectedly") if chunk.empty?

            buffer << chunk
          end
        end
        buffer
      rescue EOFError
        raise_protocol("Internal-storage connection closed unexpectedly")
      end

      def write_exact(bytes)
        offset = 0
        deadline = monotonic_now + @timeout
        while offset < bytes.bytesize
          check_cancelled!
          result = @socket.write_nonblock(bytes.byteslice(offset..), exception: false)
          case result
          when :wait_readable then wait_for(:readable, deadline)
          when :wait_writable then wait_for(:writable, deadline)
          else
            raise_protocol("Internal-storage connection closed unexpectedly") unless result&.positive?

            offset += result
          end
        end
      end

      def wait_for(direction, deadline)
        remaining = deadline - monotonic_now
        raise_protocol("Internal-storage request timed out") unless remaining.positive?

        wait = [remaining, 0.1].min
        io = @socket.to_io
        ready = direction == :readable ? io.wait_readable(wait) : io.wait_writable(wait)
        check_cancelled!
        ready
      end

      def check_cancelled!
        return unless @cancelled.call

        raise NativeStorageError.new(
          "cancelled", "Internal-storage download cancelled"
        ), cause: nil
      end

      def integer(value)
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def raise_result(result)
        code, message = case result
                        when 10
                          ["file_not_found", "Internal-storage file does not exist"]
                        when 17
                          ["storage_unavailable", "Internal storage is unavailable"]
                        when 18
                          ["unsupported", "Internal-storage operation is unsupported"]
                        when 23
                          ["checksum", "Internal-storage checksum failed"]
                        else
                          ["protocol", "Internal-storage request failed (#{result || "invalid"})"]
                        end
        raise NativeStorageError.new(code, message), cause: nil
      end

      def raise_protocol(message)
        raise NativeStorageError.new("protocol", message), cause: nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
