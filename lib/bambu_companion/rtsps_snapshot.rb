# frozen_string_literal: true

require "cgi"
require "base64"
require "digest"
require "open3"
require "securerandom"
require "socket"
require "timeout"
require_relative "camera_store"
require_relative "tls_certificate"

module BambuCompanion
  class RtspsError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  class RtspsSnapshot
    PORT = 322
    PATH = "/streaming/live/1"
    TIMEOUT = 8.0
    KILL_GRACE_SECONDS = 0.5
    READ_CHUNK_BYTES = 16_384
    STREAM_FALLBACK_INTERVAL = 1.0
    STREAM_FALLBACK_ATTEMPTS = 4

    def self.each_jpeg(io, cancelled: -> { false })
      return enum_for(__method__, io, cancelled: cancelled) unless block_given?

      buffer = String.new(encoding: Encoding::BINARY)
      loop do
        break if cancelled.call

        buffer << io.readpartial(READ_CHUNK_BYTES).b
        loop do
          start = buffer.index("\xFF\xD8".b)
          unless start
            buffer = buffer.byteslice(-1, 1).to_s.b
            break
          end
          buffer = buffer.byteslice(start..)
          finish = buffer.index("\xFF\xD9".b, 2)
          break unless finish

          yield buffer.slice!(0, finish + 2)
        end
        if buffer.bytesize > CameraStore::MAX_JPEG_BYTES
          raise RtspsError.new("oversized_frame", "Camera snapshot exceeds the size limit")
        end
      end
    rescue EOFError
      nil
    end

    def self.ffmpeg_available?(resolver = nil)
      path = (resolver || method(:find_ffmpeg)).call
      !(path.nil? || path.to_s.empty?)
    end

    def self.find_ffmpeg
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        candidate = File.join(dir, "ffmpeg")
        return candidate if File.executable?(candidate)
      end
      nil
    end

    def self.read_capped(io, max, overflow: :reject)
      limit = Integer(max)
      buffer = String.new(encoding: Encoding::BINARY)
      loop do
        remaining = limit + 1 - buffer.bytesize
        break if remaining <= 0

        chunk = io.read([READ_CHUNK_BYTES, remaining].min)
        break if chunk.nil? || chunk.empty?

        buffer << chunk.b
        next unless buffer.bytesize > limit
        return buffer.byteslice(0, limit) if overflow == :truncate

        raise RtspsError.new("oversized_frame", "Camera snapshot exceeds the size limit")
      end
      buffer
    end

    def self.rewrite_rtsp(data, from_prefix, to_prefix)
      String(data).b.gsub(from_prefix.b, to_prefix.b)
    end

    def initialize(host:, username:, password:, fingerprint:,
                   port: PORT, timeout: TIMEOUT, runner: nil,
                   gateway_factory: nil,
                   stream_fallback_interval: STREAM_FALLBACK_INTERVAL,
                   sleeper: ->(seconds) { sleep(seconds) })
      @host = String(host)
      @port = Integer(port)
      @username = String(username)
      @password = String(password)
      @fingerprint = fingerprint
      @timeout = timeout
      @runner = runner
      @gateway_factory = gateway_factory || ->(**arguments) { LoopbackGateway.new(**arguments) }
      @stream_fallback_interval = Float(stream_fallback_interval)
      unless @stream_fallback_interval.finite? && @stream_fallback_interval >= 0
        raise ArgumentError, "stream_fallback_interval must be non-negative"
      end
      @sleeper = sleeper
      @process_mutex = Mutex.new
      @wait_thread = nil
      @closed = false
    end

    def capture
      jpeg = @runner ? capture_via_runner : capture_via_loopback
      validate!(jpeg)
      String(jpeg).b
    rescue RtspsError => error
      raise RtspsError.new(error.code, redact(error.message)), cause: nil
    end

    def each_frame(cancelled: -> { false })
      return enum_for(__method__, cancelled: cancelled) unless block_given?

      if @runner
        yield capture unless cancelled.call
        return self
      end

      return self if closed? || cancelled.call

      gateway = build_gateway(
        host: @host, port: @port, username: @username, password: @password,
        fingerprint: @fingerprint, timeout: @timeout
      )
      input = gateway.start
      frames = 0
      begin
        run_ffmpeg_stream(ffmpeg_stream_argv(input), cancelled: cancelled) do |jpeg|
          validate!(jpeg)
          frames += 1
          yield String(jpeg).b
        end
        raise_gateway_error(gateway)
      rescue RtspsError => stream_error
        gateway.stop
        raise_gateway_error(gateway)
        unless frames.zero? && stream_fallback_error?(stream_error)
          raise stream_error
        end
        each_snapshot_fallback(cancelled: cancelled) { |jpeg| yield jpeg }
      end
      self
    rescue RtspsError => error
      raise RtspsError.new(error.code, redact(error.message)), cause: nil
    ensure
      gateway&.stop
    end

    def close
      wait = @process_mutex.synchronize do
        @closed = true
        @wait_thread
      end
      terminate_process(wait)
      self
    end

    private

    def capture_via_runner
      @runner.call(
        ffmpeg_argv(public_url), password: @password, env: ENV, timeout: @timeout
      )
    end

    def capture_via_loopback
      gateway = build_gateway(
        host: @host, port: @port, username: @username, password: @password,
        fingerprint: @fingerprint, timeout: @timeout
      )
      input = gateway.start
      begin
        output = run_ffmpeg(ffmpeg_argv(input), timeout: @timeout)
        # X2D closes the RTSPS socket with RST after ffmpeg's successful
        # TEARDOWN.  At this point the complete JPEG is already in hand, so
        # that peer reset is a normal end-of-session signal rather than a
        # failed capture.  Other gateway errors (especially TLS pin failures)
        # must still win.
        raise_gateway_error(gateway, allow_peer_reset: true)
        output
      rescue RtspsError
        gateway.stop
        raise_gateway_error(gateway)

        raise
      ensure
        gateway.stop
      end
    end

    def build_gateway(**arguments) = @gateway_factory.call(**arguments)

    def raise_gateway_error(gateway, allow_peer_reset: false)
      error = gateway.error
      return unless error
      return if allow_peer_reset && error.is_a?(Errno::ECONNRESET)
      raise error if error.is_a?(TlsCertificateError) || error.is_a?(RtspsError)

      raise RtspsError.new("transport", "Camera TLS gateway failed"), cause: nil
    end

    def ffmpeg_argv(input_url)
      [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-rtsp_transport", "tcp", "-timeout", "5000000",
        "-threads", "1", "-an",
        "-i", input_url,
        "-frames:v", "1",
        "-vf", "scale='min(960,iw)':-2",
        "-f", "image2", "-q:v", "5", "pipe:1"
      ]
    end

    def ffmpeg_stream_argv(input_url)
      [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-rtsp_transport", "tcp", "-timeout", "5000000",
        "-threads", "1", "-an", "-i", input_url,
        "-vf", "fps=1,scale='min(960,iw)':-2",
        "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "5", "pipe:1"
      ]
    end

    def public_url
      "rtsps://#{@username}@#{@host}:#{@port}#{PATH}"
    end

    def validate!(jpeg)
      data = String(jpeg).b
      if data.bytesize > CameraStore::MAX_JPEG_BYTES
        raise RtspsError.new("oversized_frame", "Camera snapshot exceeds the size limit")
      end
      return if CameraStore.valid_jpeg?(data)

      raise RtspsError.new("invalid_frame", "Camera snapshot was not a JPEG still")
    end

    def run_ffmpeg(argv, timeout:)
      stdin, stdout, stderr, wait = Open3.popen3(*argv, pgroup: true)
      @process_mutex.synchronize { @wait_thread = wait }
      begin
        Timeout.timeout(timeout) do
          output = self.class.read_capped(stdout, CameraStore::MAX_JPEG_BYTES)
          status = wait.value
          unless status.success?
            detail = self.class.read_capped(stderr, 4096, overflow: :truncate)
            raise RtspsError.new(
              "capture_failed",
              redact("ffmpeg exited #{status.exitstatus}: #{detail}")
            )
          end
          output
        end
      rescue Timeout::Error
        kill_group(wait.pid)
        raise RtspsError.new("timeout", "Camera snapshot timed out")
      ensure
        [stdin, stdout, stderr].each do |io|
          io.close
        rescue StandardError
          nil
        end
        terminate_process(wait)
        @process_mutex.synchronize { @wait_thread = nil if @wait_thread.equal?(wait) }
      end
    end

    def stream_fallback_error?(error)
      %w[capture_failed stream_ended].include?(error.code)
    end

    def each_snapshot_fallback(cancelled:)
      consecutive_failures = 0
      loop do
        break if closed? || cancelled.call

        begin
          jpeg = capture
        rescue RtspsError => error
          raise unless snapshot_fallback_error?(error)

          consecutive_failures += 1
          raise if consecutive_failures >= STREAM_FALLBACK_ATTEMPTS

          wait_for_snapshot_fallback(cancelled)
          next
        end
        consecutive_failures = 0
        yield jpeg
        break if closed? || cancelled.call

        wait_for_snapshot_fallback(cancelled)
      end
      self
    end

    def snapshot_fallback_error?(error)
      stream_fallback_error?(error) || error.code == "timeout"
    end

    def wait_for_snapshot_fallback(cancelled)
      remaining = @stream_fallback_interval
      while remaining.positive? && !closed? && !cancelled.call
        slice = [remaining, 0.1].min
        @sleeper.call(slice)
        remaining -= slice
      end
    end

    def run_ffmpeg_stream(argv, cancelled:)
      stdin, stdout, stderr, wait = Open3.popen3(*argv, pgroup: true)
      @process_mutex.synchronize { @wait_thread = wait }
      detail = String.new(encoding: Encoding::BINARY)
      stderr_thread = Thread.new { drain_stderr(stderr, detail) }
      frames = 0
      self.class.each_jpeg(stdout, cancelled: -> { closed? || cancelled.call }) do |jpeg|
        frames += 1
        yield jpeg
      end
      terminate_process(wait) if closed? || cancelled.call
      status = wait.value
      unless closed? || cancelled.call || status.success?
        raise RtspsError.new(
          "capture_failed", redact("ffmpeg exited #{status.exitstatus}: #{detail}")
        )
      end
      unless closed? || cancelled.call
        message = frames.zero? ? "Camera stream ended without a frame" : "Camera stream ended"
        raise RtspsError.new("stream_ended", message)
      end
    ensure
      [stdin, stdout, stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
      terminate_process(wait)
      stderr_thread&.join(KILL_GRACE_SECONDS)
      @process_mutex.synchronize { @wait_thread = nil if @wait_thread.equal?(wait) }
    end

    def drain_stderr(stderr, detail)
      loop do
        chunk = stderr.readpartial(READ_CHUNK_BYTES)
        remaining = 4096 - detail.bytesize
        detail << chunk.byteslice(0, remaining) if remaining.positive?
      end
    rescue IOError
      nil
    end

    def closed?
      @process_mutex.synchronize { @closed }
    end

    def terminate_process(wait)
      return unless wait&.alive?

      Process.kill("-TERM", wait.pid)
      return if wait.join(KILL_GRACE_SECONDS)

      Process.kill("-KILL", wait.pid)
      wait.join(KILL_GRACE_SECONDS)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def kill_group(pid)
      Process.kill("-TERM", pid)
      begin
        Timeout.timeout(KILL_GRACE_SECONDS) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("-KILL", pid)
        Process.wait(pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def redact(text)
      String(text).gsub(@password, "[REDACTED]").gsub(CGI.escape(@password), "[REDACTED]")
    end

    class LoopbackGateway
      MAX_RTSP_MESSAGE_BYTES = 1_048_576

      attr_reader :error

      def initialize(host:, port:, username:, password:, fingerprint:, timeout:)
        @host = host
        @port = port
        @username = username
        @password = password
        @fingerprint = fingerprint
        @timeout = timeout
        @stop = false
        @nonce_count = 0
        @next_cseq = 1
        @local_cseq_by_remote = {}
      end

      def start
        @server = TCPServer.new("127.0.0.1", 0)
        @local_port = @server.addr[1]
        @thread = Thread.new { serve }
        @thread.report_on_exception = false
        "rtsp://127.0.0.1:#{@local_port}#{PATH}"
      end

      def stop
        @stop = true
        close_sockets
        @thread&.join(KILL_GRACE_SECONDS)
      end

      private

      def serve
        @local = @server.accept
        begin
          @server.close
        ensure
          @server = nil
        end
        return unless local_peer?(@local)

        @remote = TlsCertificate.open_pinned(
          host: @host, port: @port, fingerprint: @fingerprint,
          connect_timeout: @timeout
        )
        preflight_authentication
        from = "rtsp://127.0.0.1:#{@local_port}"
        to = remote_base_url
        local_buffer = String.new(encoding: Encoding::BINARY)
        remote_buffer = String.new(encoding: Encoding::BINARY)
        remote_wait_writable = false
        loop do
          break if @stop

          readers = remote_wait_writable ? [@local] : [@local, @remote]
          writers = remote_wait_writable ? [@remote] : nil
          remote_pending = !remote_wait_writable && tls_bytes_pending?
          readable, writable = IO.select(readers, writers, nil, remote_pending ? 0 : 0.2)
          ready = Array(readable)
          ready << @remote if remote_pending
          ready << @remote if Array(writable).include?(@remote)
          next if ready.empty?

          closed = false
          ready.uniq.each do |socket|
            data = socket.read_nonblock(READ_CHUNK_BYTES, exception: false)
            if data.nil? || data.empty?
              closed = true
              break
            end
            if data == :wait_readable || data == :wait_writable
              remote_wait_writable = data == :wait_writable if socket.equal?(@remote)
              next
            end

            if socket.equal?(@local)
              local_buffer << data.b
              if local_buffer.bytesize > MAX_RTSP_MESSAGE_BYTES
                raise RtspsError.new("transport", "Camera RTSP request is too large")
              end
              forward_local_messages(local_buffer, from, to)
            else
              remote_wait_writable = false
              remote_buffer << data.b
              if remote_buffer.bytesize > MAX_RTSP_MESSAGE_BYTES
                raise RtspsError.new("transport", "Camera RTSP response is too large")
              end
              forward_remote_messages(remote_buffer)
            end
          end
          break if closed
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError,
             TlsCertificateError, RtspsError => error
        @error = error unless @stop
      ensure
        close_sockets
      end

      def close_sockets
        [@server, @local, @remote].each do |socket|
          socket&.close
        rescue StandardError
          nil
        end
      end

      def local_peer?(socket)
        ip = socket.peeraddr[3]
        ip == "127.0.0.1" || ip == "::1"
      rescue StandardError
        false
      end

      def tls_bytes_pending?
        @remote.respond_to?(:pending) && @remote.pending.positive?
      rescue StandardError
        false
      end

      def preflight_authentication
        request = preflight_request
        @remote.write(request)
        response = read_rtsp_message(@remote)
        status, headers = parse_response(response)
        return if (200..299).cover?(status)

        unless status == 401
          raise RtspsError.new("auth_failed", "Camera rejected RTSP setup")
        end

        @challenge = authentication_challenge(headers)
        unless @challenge
          raise RtspsError.new("auth_failed", "Camera did not provide a supported RTSP challenge")
        end

        authenticated = add_authorization(preflight_request)
        @remote.write(authenticated)
        retry_status, = parse_response(read_rtsp_message(@remote))
        return if (200..299).cover?(retry_status)

        raise RtspsError.new("auth_failed", "Camera rejected RTSP credentials")
      end

      def preflight_request
        uri = "#{remote_base_url}#{PATH}"
        <<~RTSP.gsub("\n", "\r\n")
          DESCRIBE #{uri} RTSP/1.0
          CSeq: #{next_remote_cseq}
          Accept: application/sdp

        RTSP
      end

      def remote_base_url = "rtsps://#{@host}:#{@port}"

      def forward_local_messages(buffer, from, to)
        while (message = extract_local_message(buffer))
          if message.start_with?("$".b)
            @remote.write(message)
            next
          end

          rewritten = RtspsSnapshot.rewrite_rtsp(message, from, to)
          rewritten = map_request_cseq(rewritten)
          @remote.write(add_authorization(rewritten))
        end
      end

      def forward_remote_messages(buffer)
        while (message = extract_rtsp_or_interleaved(buffer))
          if message.start_with?("$".b)
            @local.write(message)
          else
            @local.write(restore_response_cseq(message))
          end
        end
      end

      def extract_local_message(buffer)
        extract_rtsp_or_interleaved(buffer)
      end

      def extract_rtsp_or_interleaved(buffer)
        return extract_interleaved_frame(buffer) if buffer.start_with?("$".b)

        header_end = buffer.index("\r\n\r\n".b)
        return unless header_end

        header = buffer.byteslice(0, header_end + 4)
        length = header[/^Content-Length:\s*(\d+)\s*$/i, 1].to_i
        total = header_end + 4 + length
        return if buffer.bytesize < total

        buffer.slice!(0, total)
      end

      def extract_interleaved_frame(buffer)
        return if buffer.bytesize < 4

        length = buffer.byteslice(2, 2).unpack1("n")
        return if buffer.bytesize < length + 4

        buffer.slice!(0, length + 4)
      end

      def map_request_cseq(request)
        local_cseq = request[/^CSeq:\s*(\d+)\s*$/i, 1]
        unless local_cseq
          raise RtspsError.new("transport", "Camera client sent RTSP without CSeq")
        end

        remote_cseq = next_remote_cseq
        @local_cseq_by_remote[remote_cseq.to_s] = local_cseq
        request.sub(/^CSeq:[ \t]*\d+[ \t]*(?=\r\n)/i, "CSeq: #{remote_cseq}")
      end

      def restore_response_cseq(response)
        remote_cseq = response[/^CSeq:\s*(\d+)\s*$/i, 1]
        local_cseq = @local_cseq_by_remote.delete(remote_cseq)
        return response unless local_cseq

        response.sub(/^CSeq:[ \t]*\d+[ \t]*(?=\r\n)/i, "CSeq: #{local_cseq}")
      end

      def next_remote_cseq
        current = @next_cseq
        @next_cseq += 1
        current
      end

      def read_rtsp_message(io)
        buffer = String.new(encoding: Encoding::BINARY)
        Timeout.timeout(@timeout) do
          loop do
            buffer << io.readpartial(READ_CHUNK_BYTES).b
            if buffer.bytesize > MAX_RTSP_MESSAGE_BYTES
              raise RtspsError.new("transport", "Camera RTSP response is too large")
            end

            header_end = buffer.index("\r\n\r\n".b)
            next unless header_end

            header = buffer.byteslice(0, header_end + 4)
            length = header[/^Content-Length:\s*(\d+)\s*$/i, 1].to_i
            total = header_end + 4 + length
            return buffer.byteslice(0, total) if buffer.bytesize >= total
          end
        end
      rescue Timeout::Error
        raise RtspsError.new("timeout", "Camera RTSP authentication timed out")
      rescue EOFError
        raise RtspsError.new("transport", "Camera closed RTSP authentication")
      end

      def parse_response(message)
        header = message.byteslice(0, message.index("\r\n\r\n") + 4)
        status = header[/\ARTSP\/\d\.\d\s+(\d{3})/, 1].to_i
        headers = Hash.new { |hash, key| hash[key] = [] }
        header.split("\r\n").drop(1).each do |line|
          name, value = line.split(":", 2)
          headers[name.to_s.downcase] << value.to_s.strip unless value.nil?
        end
        [status, headers]
      end

      def authentication_challenge(headers)
        values = headers.fetch("www-authenticate", [])
        value = values.find { |candidate| candidate.match?(/\ADigest\s/i) } ||
                values.find { |candidate| candidate.match?(/\ABasic\s/i) }
        return unless value

        scheme, parameters = value.split(/\s+/, 2)
        {
          scheme: scheme.downcase,
          parameters: parse_auth_parameters(parameters.to_s)
        }
      end

      def parse_auth_parameters(text)
        text.scan(/([A-Za-z][A-Za-z0-9_-]*)=("(?:\\.|[^"])*"|[^,\s]+)/).to_h do |key, value|
          decoded = value.start_with?('"') ? value[1...-1].gsub(/\\([\\"])/, '\\1') : value
          [key.downcase, decoded]
        end
      end

      def add_authorization(request)
        return request unless @challenge

        first_line = request.lines.first.to_s
        method, uri = first_line.split(/\s+/, 3)
        return request if method.to_s.empty? || uri.to_s.empty?

        header = authorization_header(method, uri)
        clean = request.gsub(/^Authorization:.*\r\n/i, "")
        clean.sub("\r\n", "\r\nAuthorization: #{header}\r\n")
      end

      def authorization_header(method, uri)
        return basic_authorization if @challenge.fetch(:scheme) == "basic"

        digest_authorization(method, uri)
      end

      def basic_authorization
        token = Base64.strict_encode64("#{@username}:#{@password}")
        "Basic #{token}"
      end

      def digest_authorization(method, uri)
        parameters = @challenge.fetch(:parameters)
        realm = parameters.fetch("realm")
        nonce = parameters.fetch("nonce")
        algorithm = parameters.fetch("algorithm", "MD5")
        unless algorithm.casecmp?("MD5") || algorithm.casecmp?("MD5-sess")
          raise RtspsError.new("auth_failed", "Camera uses an unsupported RTSP digest algorithm")
        end

        cnonce = SecureRandom.hex(8)
        ha1 = Digest::MD5.hexdigest("#{@username}:#{realm}:#{@password}")
        ha1 = Digest::MD5.hexdigest("#{ha1}:#{nonce}:#{cnonce}") if algorithm.casecmp?("MD5-sess")
        ha2 = Digest::MD5.hexdigest("#{method}:#{uri}")
        fields = [
          %(username="#{quote_digest(@username)}"),
          %(realm="#{quote_digest(realm)}"),
          %(nonce="#{quote_digest(nonce)}"),
          %(uri="#{quote_digest(uri)}")
        ]
        qop = supported_qop(parameters["qop"])
        if qop
          @nonce_count += 1
          nc = format("%08x", @nonce_count)
          response = Digest::MD5.hexdigest("#{ha1}:#{nonce}:#{nc}:#{cnonce}:#{qop}:#{ha2}")
          fields.concat(["qop=#{qop}", "nc=#{nc}", %(cnonce="#{cnonce}")])
        else
          response = Digest::MD5.hexdigest("#{ha1}:#{nonce}:#{ha2}")
          fields << %(cnonce="#{cnonce}") if algorithm.casecmp?("MD5-sess")
        end
        fields << %(response="#{response}")
        fields << "algorithm=#{algorithm}" if parameters.key?("algorithm")
        fields << %(opaque="#{quote_digest(parameters['opaque'])}") if parameters.key?("opaque")
        "Digest #{fields.join(', ')}"
      rescue KeyError
        raise RtspsError.new("auth_failed", "Camera sent an incomplete RTSP digest challenge")
      end

      def supported_qop(value)
        choices = value.to_s.split(",").map { |entry| entry.strip.downcase }
        return "auth" if choices.include?("auth")
        return if choices.empty?

        raise RtspsError.new("auth_failed", "Camera uses an unsupported RTSP digest qop")
      end

      def quote_digest(value) = String(value).gsub(/[\\"]/, '\\\\\0')
    end
  end
end
