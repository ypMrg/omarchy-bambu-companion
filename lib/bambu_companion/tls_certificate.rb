# frozen_string_literal: true

require "openssl"
require "socket"
require "time"
require "io/wait"

module BambuCompanion
  class TlsCertificateError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  module TlsCertificate
    FINGERPRINT_BYTES = 32
    PLAIN_FINGERPRINT = /\A[0-9A-Fa-f]{64}\z/
    COLON_FINGERPRINT = /\A(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}\z/
    VERIFIER_IVAR = :@bambu_companion_pin_verifier

    class PinVerifier
      def initialize(expected)
        @expected = expected
        @mutex = Mutex.new
        @rejected = false
      end

      def call(_preverified, store_context)
        return true unless store_context.error_depth.zero?

        actual = TlsCertificate.fingerprint(store_context.current_cert)
        accepted = @expected.any? { |fingerprint| secure_equal?(fingerprint, actual) }
        @mutex.synchronize { @rejected = !accepted }
        accepted
      rescue StandardError
        @mutex.synchronize { @rejected = true }
        false
      end

      def rejected? = @mutex.synchronize { @rejected }

      private

      def secure_equal?(expected, actual)
        return false unless expected.bytesize == actual.bytesize

        OpenSSL.fixed_length_secure_compare(expected, actual)
      end
    end

    module_function

    def normalize_fingerprint(value)
      text = String(value).strip
      unless PLAIN_FINGERPRINT.match?(text) || COLON_FINGERPRINT.match?(text)
        raise_certificate_error("invalid_fingerprint", "TLS fingerprint is invalid")
      end

      text.delete(":").upcase.freeze
    rescue TypeError
      raise_certificate_error("invalid_fingerprint", "TLS fingerprint is invalid")
    end

    def normalize_fingerprints(value)
      values = value.is_a?(Array) ? value : [value]
      normalized = values.map { |fingerprint| normalize_fingerprint(fingerprint) }.uniq
      raise_certificate_error("invalid_fingerprint", "TLS fingerprint is invalid") if normalized.empty?

      normalized.freeze
    end

    def fingerprint(certificate)
      OpenSSL::Digest::SHA256.hexdigest(certificate.to_der).upcase.freeze
    end

    def configure_pinned_context(context, expected_fingerprint)
      verifier = PinVerifier.new(normalize_fingerprints(expected_fingerprint))
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.verify_callback = verifier
      context.instance_variable_set(VERIFIER_IVAR, verifier)
      context
    end

    def raise_if_pin_rejected!(context, transport_error)
      verifier = context.instance_variable_get(VERIFIER_IVAR)
      raise transport_error unless verifier&.rejected?

      raise TlsCertificateError.new(
        "certificate_changed", "Printer TLS certificate does not match the trusted fingerprint"
      ), cause: nil
    end

    def open_pinned(host:, port:, fingerprint:, connect_timeout: 8.0,
                    handshake_timeout: connect_timeout,
                    cancelled: -> { false },
                    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      raw = Socket.tcp(String(host), Integer(port), connect_timeout: connect_timeout)
      context = OpenSSL::SSL::SSLContext.new
      configure_pinned_context(context, fingerprint)
      tls = OpenSSL::SSL::SSLSocket.new(raw, context)
      tls.sync_close = true
      tls.hostname = String(host) if tls.respond_to?(:hostname=)
      connect_with_deadline(
        tls, handshake_timeout: handshake_timeout,
        cancelled: cancelled, clock: clock
      )
      tls
    rescue OpenSSL::SSL::SSLError => error
      raw&.close
      raise_if_pin_rejected!(context, error)
    rescue StandardError
      raw&.close
      raise
    end

    def connect_with_deadline(socket, handshake_timeout:, cancelled:, clock:)
      timeout = Float(handshake_timeout)
      unless timeout.finite? && timeout.positive?
        raise ArgumentError, "handshake_timeout must be positive"
      end

      deadline = clock.call + timeout
      loop do
        raise_cancelled if cancelled.call

        result = socket.connect_nonblock(exception: false)
        return socket unless %i[wait_readable wait_writable].include?(result)

        remaining = deadline - clock.call
        raise_handshake_timeout unless remaining.positive?

        wait = [remaining, 0.1].min
        io = socket.to_io
        if result == :wait_readable
          io.wait_readable(wait)
        else
          io.wait_writable(wait)
        end
      end
    end

    def raise_cancelled
      raise TlsCertificateError.new(
        "cancelled", "Printer TLS handshake cancelled"
      ), cause: nil
    end

    def raise_handshake_timeout
      raise TlsCertificateError.new(
        "timeout", "Printer TLS handshake timed out"
      ), cause: nil
    end

    def identity(certificate)
      {
        "fingerprint" => fingerprint(certificate),
        "commonName" => bounded_text(common_name(certificate), 256),
        "issuer" => bounded_text(certificate.issuer.to_s(OpenSSL::X509::Name::RFC2253), 512),
        "notBefore" => certificate.not_before.utc.iso8601,
        "notAfter" => certificate.not_after.utc.iso8601
      }.freeze
    end

    def common_name(certificate)
      certificate.subject.to_a.reverse_each do |name, value, _type|
        return value if name == "CN"
      end
      ""
    end

    def bounded_text(value, max_bytes)
      text = String(value).encode(
        Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?"
      )
      return text.freeze if text.bytesize <= max_bytes

      text.byteslice(0, max_bytes).force_encoding(Encoding::UTF_8).scrub("?").freeze
    end

    def raise_certificate_error(code, message)
      raise TlsCertificateError.new(code, message), cause: nil
    end
  end

  class TlsProbe
    DEFAULT_CONNECT_TIMEOUT = 8.0
    DEFAULT_HANDSHAKE_TIMEOUT = 8.0
    WAIT_SLICE_SECONDS = 0.1

    def initialize(connect_timeout: DEFAULT_CONNECT_TIMEOUT,
                   handshake_timeout: DEFAULT_HANDSHAKE_TIMEOUT,
                   socket_factory: nil, clock: nil)
      @connect_timeout = positive_finite(connect_timeout, "connect_timeout")
      @handshake_timeout = positive_finite(handshake_timeout, "handshake_timeout")
      @socket_factory = socket_factory || lambda do |host:, port:, connect_timeout:|
        Socket.tcp(host, port, connect_timeout: connect_timeout)
      end
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def probe(host:, mqtt_port:, ftps_port:, cancelled: -> { false })
      check_cancelled!(cancelled)
      {
        "mqtt" => probe_endpoint(
          host: host, port: mqtt_port, cancelled: cancelled
        ),
        "ftps" => probe_endpoint(
          host: host, port: ftps_port, cancelled: cancelled
        )
      }.freeze
    rescue TlsCertificateError
      raise
    rescue StandardError
      raise_probe_failed
    end

    private

    def probe_endpoint(host:, port:, cancelled:)
      check_cancelled!(cancelled)
      raw_socket = @socket_factory.call(
        host: String(host), port: Integer(port), connect_timeout: @connect_timeout
      )
      # Discovery cannot verify a certificate that has not been approved yet.
      # It sends no application data or credentials; the returned fingerprint
      # must be explicitly trusted before either authenticated transport starts.
      context = OpenSSL::SSL::SSLContext.new
      tls_socket = OpenSSL::SSL::SSLSocket.new(raw_socket, context)
      tls_socket.sync_close = true
      tls_socket.hostname = String(host) if tls_socket.respond_to?(:hostname=)
      connect_tls(tls_socket, cancelled)
      certificate = tls_socket.peer_cert
      raise_probe_failed unless certificate

      TlsCertificate.identity(certificate)
    ensure
      safely_close(tls_socket)
      safely_close(raw_socket)
    end

    def connect_tls(socket, cancelled)
      deadline = @clock.call + @handshake_timeout
      loop do
        check_cancelled!(cancelled)
        result = socket.connect_nonblock(exception: false)
        return unless %i[wait_readable wait_writable].include?(result)

        remaining = deadline - @clock.call
        raise_probe_failed("TLS certificate probe timed out") unless remaining.positive?

        wait = [remaining, WAIT_SLICE_SECONDS].min
        io = socket.to_io
        ready = result == :wait_readable ? io.wait_readable(wait) : io.wait_writable(wait)
        next if ready
      end
    end

    def check_cancelled!(cancelled)
      return unless cancelled.call

      TlsCertificate.raise_certificate_error(
        "cancelled", "TLS certificate probe cancelled"
      )
    end

    def raise_probe_failed(message = "TLS certificate probe failed")
      TlsCertificate.raise_certificate_error("probe_failed", message)
    end

    def safely_close(socket)
      return unless socket
      return if socket.respond_to?(:closed?) && socket.closed?

      socket.close
    rescue StandardError
      nil
    end

    def positive_finite(value, name)
      number = Float(value)
      return number if number.finite? && number.positive?

      raise ArgumentError, "#{name} must be finite and positive"
    end
  end
end
