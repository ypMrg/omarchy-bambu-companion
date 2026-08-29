# frozen_string_literal: true

require_relative "test_helper"
require "openssl"
require "socket"
require "bambu_companion/tls_certificate"

class TlsCertificateTest < Minitest::Test
  FakeStoreContext = Struct.new(:current_cert, :error_depth)

  class FakeHandshakeSocket
    attr_reader :read_waits, :write_waits

    def initialize(results)
      @results = results
      @read_waits = []
      @write_waits = []
    end

    def connect_nonblock(**) = @results.shift || self
    def to_io = self
    def wait_readable(timeout) = @read_waits << timeout
    def wait_writable(timeout) = @write_waits << timeout
  end

  def test_normalizes_sha256_fingerprints
    colon_separated = Array.new(32, "ab").join(":")

    assert_equal "AB" * 32,
                 BambuCompanion::TlsCertificate.normalize_fingerprint(colon_separated)
    assert_equal "AB" * 32,
                 BambuCompanion::TlsCertificate.normalize_fingerprint("  #{"ab" * 32}  ")
  end

  def test_rejects_missing_or_malformed_fingerprints
    [nil, "", "AA", "GG" * 32, "AA:" * 32].each do |value|
      assert_raises(BambuCompanion::TlsCertificateError) do
        BambuCompanion::TlsCertificate.normalize_fingerprint(value)
      end
    end
  end

  def test_pinned_context_accepts_only_the_expected_leaf_certificate
    expected = certificate(common_name: "printer-expected")
    attacker = certificate(common_name: "printer-attacker")
    context = OpenSSL::SSL::SSLContext.new

    BambuCompanion::TlsCertificate.configure_pinned_context(
      context, BambuCompanion::TlsCertificate.fingerprint(expected)
    )

    assert_equal OpenSSL::SSL::VERIFY_PEER, context.verify_mode
    assert context.verify_callback.call(
      false, FakeStoreContext.new(expected, 0)
    )
    refute context.verify_callback.call(
      false, FakeStoreContext.new(attacker, 0)
    )
    assert context.verify_callback.call(
      false, FakeStoreContext.new(attacker, 1)
    )
  end

  def test_pinned_context_accepts_any_explicitly_trusted_device_leaf
    mqtt = certificate(common_name: "printer-mqtt")
    ftps = certificate(common_name: "printer-ftps")
    attacker = certificate(common_name: "printer-attacker")
    context = OpenSSL::SSL::SSLContext.new

    BambuCompanion::TlsCertificate.configure_pinned_context(
      context,
      [BambuCompanion::TlsCertificate.fingerprint(mqtt),
       BambuCompanion::TlsCertificate.fingerprint(ftps)]
    )

    assert context.verify_callback.call(false, FakeStoreContext.new(mqtt, 0))
    assert context.verify_callback.call(false, FakeStoreContext.new(ftps, 0))
    refute context.verify_callback.call(false, FakeStoreContext.new(attacker, 0))
  end

  def test_pin_rejection_becomes_a_stable_non_secret_error
    expected = certificate(common_name: "printer-expected")
    attacker = certificate(common_name: "printer-attacker")
    context = OpenSSL::SSL::SSLContext.new
    BambuCompanion::TlsCertificate.configure_pinned_context(
      context, BambuCompanion::TlsCertificate.fingerprint(expected)
    )
    context.verify_callback.call(false, FakeStoreContext.new(attacker, 0))
    transport = OpenSSL::SSL::SSLError.new("certificate verify failed attacker-data")

    error = assert_raises(BambuCompanion::TlsCertificateError) do
      BambuCompanion::TlsCertificate.raise_if_pin_rejected!(context, transport)
    end

    assert_equal "certificate_changed", error.code
    assert_nil error.cause
    refute_includes error.full_message, "attacker-data"
  end

  def test_identity_exposes_only_bounded_certificate_metadata
    cert = certificate(common_name: "printer-" + ("x" * 500))

    identity = BambuCompanion::TlsCertificate.identity(cert)

    assert_equal BambuCompanion::TlsCertificate.fingerprint(cert),
                 identity.fetch("fingerprint")
    assert_operator identity.fetch("commonName").bytesize, :<=, 256
    assert_operator identity.fetch("issuer").bytesize, :<=, 512
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, identity.fetch("notBefore"))
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, identity.fetch("notAfter"))
    assert_equal %w[commonName fingerprint issuer notAfter notBefore],
                 identity.keys.sort
  end

  def test_probe_reads_both_endpoint_certificates_without_credentials
    mqtt_cert = certificate(common_name: "mqtt-printer")
    ftps_cert = certificate(common_name: "ftps-printer")

    with_tls_server(mqtt_cert) do |mqtt_port|
      with_tls_server(ftps_cert) do |ftps_port|
        result = BambuCompanion::TlsProbe.new(
          connect_timeout: 1, handshake_timeout: 1
        ).probe(
          host: "127.0.0.1", mqtt_port: mqtt_port, ftps_port: ftps_port
        )

        assert_equal BambuCompanion::TlsCertificate.fingerprint(mqtt_cert),
                     result.dig("mqtt", "fingerprint")
        assert_equal BambuCompanion::TlsCertificate.fingerprint(ftps_cert),
                     result.dig("ftps", "fingerprint")
      end
    end
  end

  def test_probe_honors_cancellation_before_opening_a_socket
    socket_factory = lambda do |**|
      flunk("cancelled probe must not open a socket")
    end
    probe = BambuCompanion::TlsProbe.new(socket_factory: socket_factory)

    error = assert_raises(BambuCompanion::TlsCertificateError) do
      probe.probe(
        host: "printer.local", mqtt_port: 8883, ftps_port: 990,
        cancelled: -> { true }
      )
    end

    assert_equal "cancelled", error.code
  end

  def test_pinned_handshake_waits_nonblocking_until_connected
    socket = FakeHandshakeSocket.new([:wait_readable, :wait_writable, :connected])
    clock = -> { 0.0 }

    result = BambuCompanion::TlsCertificate.connect_with_deadline(
      socket, handshake_timeout: 1.0,
      cancelled: -> { false }, clock: clock
    )

    assert_same socket, result
    assert_equal [0.1], socket.read_waits
    assert_equal [0.1], socket.write_waits
  end

  def test_pinned_handshake_honors_cancellation_and_deadline
    socket = FakeHandshakeSocket.new([:wait_readable])
    cancelled = assert_raises(BambuCompanion::TlsCertificateError) do
      BambuCompanion::TlsCertificate.connect_with_deadline(
        socket, handshake_timeout: 1.0,
        cancelled: -> { true }, clock: -> { 0.0 }
      )
    end
    assert_equal "cancelled", cancelled.code

    times = [0.0, 2.0]
    timed_out = assert_raises(BambuCompanion::TlsCertificateError) do
      BambuCompanion::TlsCertificate.connect_with_deadline(
        FakeHandshakeSocket.new([:wait_writable]), handshake_timeout: 1.0,
        cancelled: -> { false }, clock: -> { times.shift || 2.0 }
      )
    end
    assert_equal "timeout", timed_out.code
  end

  private

  def certificate(common_name:)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1..100_000)
    cert.subject = OpenSSL::X509::Name.new([["CN", common_name]])
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now.utc - 60
    cert.not_after = Time.now.utc + 3600
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    cert.instance_variable_set(:@test_private_key, key)
    cert
  end

  def with_tls_server(cert)
    tcp_server = TCPServer.new("127.0.0.1", 0)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = cert.instance_variable_get(:@test_private_key)
    ssl_server = OpenSSL::SSL::SSLServer.new(tcp_server, context)
    thread = Thread.new do
      socket = ssl_server.accept
      socket.close
    rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
      nil
    end
    thread.report_on_exception = false
    yield tcp_server.local_address.ip_port
  ensure
    tcp_server&.close
    thread&.join(1)
    thread&.kill
  end
end
