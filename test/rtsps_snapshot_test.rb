# frozen_string_literal: true

require_relative "test_helper"
require "base64"
require "digest"
require "rbconfig"
require "socket"
require "stringio"
require "timeout"
require "bambu_companion/rtsps_snapshot"

class RtspsSnapshotTest < Minitest::Test
  JPEG = BambuCompanion::TestFixtures.minimal_jpeg(payload: "snap").freeze
  SECRET = "rtsp-secret-sentinel"
  SDP = <<~SDP.gsub("\n", "\r\n").freeze
    v=0
    o=- 0 0 IN IP4 192.0.2.10
    s=Offline Bambu camera
    c=IN IP4 192.0.2.10
    t=0 0
    a=control:*
    m=video 0 RTP/AVP 96
    a=rtpmap:96 H264/90000
    a=fmtp:96 packetization-mode=1
    a=control:track1
  SDP

  class FakeGateway
    attr_reader :error, :stops

    def initialize(error)
      @error = error
      @stops = 0
    end

    def start = "rtsp://127.0.0.1:9/streaming/live/1"
    def stop = @stops += 1
  end

  class TlsLikeSocket
    def initialize(io) = @io = io

    def to_io = @io
    def readpartial(...) = @io.readpartial(...)
    def read_nonblock(...) = @io.read_nonblock(...)
    def write(...) = @io.write(...)
    def close = @io.close
  end

  class WaitWritableTlsSocket < TlsLikeSocket
    def initialize(io)
      super
      @waited = false
    end

    def read_nonblock(...)
      return super if @waited

      @waited = true
      :wait_writable
    end
  end

  def test_ffmpeg_available_uses_the_resolver
    assert BambuCompanion::RtspsSnapshot.ffmpeg_available?(-> { "/usr/bin/ffmpeg" })
    refute BambuCompanion::RtspsSnapshot.ffmpeg_available?(-> { nil })
  end

  def test_capture_runs_one_frame_ffmpeg_without_putting_the_secret_on_argv
    commands = []
    passwords = []
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32,
      runner: lambda { |command, password:, **|
        commands << command
        passwords << password
        JPEG
      }
    )

    assert_equal JPEG, snapshot.capture
    command = commands.fetch(0)
    refute_includes command.join(" "), SECRET
    assert_includes command, "-threads"
    assert_includes command, "1"
    assert_includes command, "-an"
    assert_includes command, "-frames:v"
    assert_equal "1", command[command.index("-frames:v") + 1]
    assert(command.any? { |part| part.include?("scale='min(960,iw)':-2") })
    assert_includes command, "rtsps://bblp@192.168.1.50:322/streaming/live/1"
    assert_equal [SECRET], passwords
  end

  def test_stream_command_keeps_one_ffmpeg_session_and_emits_mjpeg
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, runner: ->(*) { JPEG }
    )

    command = snapshot.send(:ffmpeg_stream_argv, "rtsp://127.0.0.1:9/streaming/live/1")

    refute_includes command, "-frames:v"
    assert_includes command, "image2pipe"
    assert_includes command, "mjpeg"
    assert(command.any? { |part| part.include?("fps=1") })
  end

  def test_successful_capture_ignores_x2d_peer_reset_after_teardown
    gateway = FakeGateway.new(Errno::ECONNRESET.new)
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, gateway_factory: ->(**) { gateway }
    )
    snapshot.define_singleton_method(:run_ffmpeg) { |*, **| JPEG }

    assert_equal JPEG, snapshot.capture
    assert_equal 1, gateway.stops
  end

  def test_successful_capture_still_preserves_gateway_certificate_error
    certificate_error = BambuCompanion::TlsCertificateError.new(
      "certificate_changed", "Printer TLS certificate changed"
    )
    gateway = FakeGateway.new(certificate_error)
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, gateway_factory: ->(**) { gateway }
    )
    snapshot.define_singleton_method(:run_ffmpeg) { |*, **| JPEG }

    error = assert_raises(BambuCompanion::TlsCertificateError) { snapshot.capture }

    assert_equal "certificate_changed", error.code
    assert_operator gateway.stops, :>=, 1
  end

  def test_stream_parser_yields_multiple_chunked_jpegs
    input = StringIO.new("noise" + JPEG.byteslice(0, 7) + JPEG.byteslice(7..) + JPEG)
    frames = []

    BambuCompanion::RtspsSnapshot.each_jpeg(input) { |frame| frames << frame }

    assert_equal [JPEG, JPEG], frames
  end

  def test_stream_parser_rejects_an_unbounded_incomplete_frame
    input = StringIO.new("\xFF\xD8".b + ("x" * BambuCompanion::CameraStore::MAX_JPEG_BYTES))

    error = assert_raises(BambuCompanion::RtspsError) do
      BambuCompanion::RtspsSnapshot.each_jpeg(input) { flunk("frame must stay incomplete") }
    end

    assert_equal "oversized_frame", error.code
  end

  def test_persistent_stream_reads_multiple_frames_from_one_process
    snapshot = new_snapshot
    hex = JPEG.unpack1("H*")
    program = "STDOUT.binmode; jpeg=['#{hex}'].pack('H*'); STDOUT.write(jpeg + jpeg)"
    frames = []

    error = assert_raises(BambuCompanion::RtspsError) do
      snapshot.send(
        :run_ffmpeg_stream, [RbConfig.ruby, "-e", program], cancelled: -> { false }
      ) { |frame| frames << frame }
    end

    assert_equal [JPEG, JPEG], frames
    assert_equal "stream_ended", error.code
  end

  def test_close_terminates_the_persistent_stream_process
    snapshot = new_snapshot
    hex = JPEG.unpack1("H*")
    program = <<~RUBY
      STDOUT.binmode
      STDOUT.write(['#{hex}'].pack('H*'))
      STDOUT.flush
      sleep 30
    RUBY
    frame_seen = Queue.new
    thread = Thread.new do
      snapshot.send(
        :run_ffmpeg_stream, [RbConfig.ruby, "-e", program], cancelled: -> { false }
      ) { frame_seen << true }
    end
    Timeout.timeout(2) { frame_seen.pop }

    snapshot.close

    assert thread.join(2), "stream process did not stop"
    refute thread.alive?
  ensure
    snapshot&.close
    thread&.kill
    thread&.join(1)
  end

  def test_stream_preserves_a_gateway_certificate_error
    certificate_error = BambuCompanion::TlsCertificateError.new(
      "certificate_changed", "Printer TLS certificate changed"
    )
    gateway = FakeGateway.new(certificate_error)
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, gateway_factory: ->(**) { gateway }
    )
    snapshot.define_singleton_method(:run_ffmpeg_stream) do |*, **|
      raise BambuCompanion::RtspsError.new("capture_failed", "generic ffmpeg failure")
    end

    error = assert_raises(BambuCompanion::TlsCertificateError) do
      snapshot.each_frame { flunk("no frame expected") }
    end

    assert_equal "certificate_changed", error.code
    assert_operator gateway.stops, :>=, 1
  end

  def test_stream_does_not_lose_gateway_error_after_clean_ffmpeg_exit
    certificate_error = BambuCompanion::TlsCertificateError.new(
      "certificate_changed", "Printer TLS certificate changed"
    )
    gateway = FakeGateway.new(certificate_error)
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, gateway_factory: ->(**) { gateway }
    )
    snapshot.define_singleton_method(:run_ffmpeg_stream) { |*, **| nil }

    error = assert_raises(BambuCompanion::TlsCertificateError) do
      snapshot.each_frame { flunk("no frame expected") }
    end

    assert_equal "certificate_changed", error.code
  end

  def test_stream_without_a_first_frame_falls_back_to_verified_single_captures
    gateway = FakeGateway.new(nil)
    cancelled = false
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, gateway_factory: ->(**) { gateway },
      stream_fallback_interval: 0
    )
    snapshot.define_singleton_method(:run_ffmpeg_stream) do |*, **|
      raise BambuCompanion::RtspsError.new(
        "capture_failed", "Output file does not contain any stream"
      )
    end
    snapshot.define_singleton_method(:capture) { JPEG }
    frames = []

    snapshot.each_frame(cancelled: -> { cancelled }) do |jpeg|
      frames << jpeg
      cancelled = true
    end

    assert_equal [JPEG], frames
    assert_operator gateway.stops, :>=, 1
  end

  def test_single_capture_fallback_retries_a_cold_x2d_stream
    gateway = FakeGateway.new(nil)
    cancelled = false
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, gateway_factory: ->(**) { gateway },
      stream_fallback_interval: 0
    )
    snapshot.define_singleton_method(:run_ffmpeg_stream) do |*, **|
      raise BambuCompanion::RtspsError.new(
        "capture_failed", "Output file does not contain any stream"
      )
    end
    captures = 0
    snapshot.define_singleton_method(:capture) do
      captures += 1
      if captures == 1
        raise BambuCompanion::RtspsError.new(
          "capture_failed", "Output file does not contain any stream"
        )
      end
      JPEG
    end

    frames = []
    snapshot.each_frame(cancelled: -> { cancelled }) do |jpeg|
      frames << jpeg
      cancelled = true
    end

    assert_equal 2, captures
    assert_equal [JPEG], frames
  end

  def test_single_capture_fallback_has_a_finite_retry_limit
    gateway = FakeGateway.new(nil)
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, gateway_factory: ->(**) { gateway },
      stream_fallback_interval: 0
    )
    snapshot.define_singleton_method(:run_ffmpeg_stream) do |*, **|
      raise BambuCompanion::RtspsError.new(
        "capture_failed", "Output file does not contain any stream"
      )
    end
    captures = 0
    snapshot.define_singleton_method(:capture) do
      captures += 1
      raise BambuCompanion::RtspsError.new(
        "capture_failed", "Output file does not contain any stream"
      )
    end

    error = assert_raises(BambuCompanion::RtspsError) do
      snapshot.each_frame { flunk("no frame expected") }
    end

    assert_equal "capture_failed", error.code
    assert_equal BambuCompanion::RtspsSnapshot::STREAM_FALLBACK_ATTEMPTS, captures
  end

  def test_loopback_rewrite_changes_the_origin_without_credentials
    from = "rtsp://127.0.0.1:9"
    to = "rtsps://192.168.1.50:322"
    rewritten = BambuCompanion::RtspsSnapshot.rewrite_rtsp(
      "DESCRIBE #{from}/streaming/live/1 RTSP/1.0\r\n", from, to
    )

    assert_includes rewritten, "rtsps://192.168.1.50:322/streaming/live/1"
    refute_includes rewritten, SECRET
    argv = [
      "ffmpeg", "-i", "rtsp://127.0.0.1:9/streaming/live/1"
    ]
    refute_includes argv.join(" "), SECRET
  end

  def test_loopback_gateway_handles_basic_auth_without_exposing_it_to_the_client
    gateway_side, printer_side = Socket.pair(:UNIX, :STREAM, 0)
    tls_socket = TlsLikeSocket.new(gateway_side)
    requests = Queue.new
    printer = Thread.new do
      request = read_rtsp_message(printer_side)
      requests << request
      printer_side.write(
        rtsp_response(401, 'WWW-Authenticate: Basic realm="Bambu Camera"',
                      cseq: request_cseq(request))
      )
      request = read_rtsp_message(printer_side)
      requests << request
      printer_side.write(rtsp_response(200, cseq: request_cseq(request)))
      request = read_rtsp_message(printer_side)
      requests << request
      printer_side.write(rtsp_response(200, cseq: request_cseq(request)))
    end
    gateway = new_gateway

    BambuCompanion::TlsCertificate.stub(:open_pinned, ->(**) { tls_socket }) do
      url = gateway.start
      port = Integer(url[/:(\d+)\//, 1])
      client = TCPSocket.new("127.0.0.1", port)
      client_request = "DESCRIBE #{url} RTSP/1.0\r\nCSeq: 1\r\n\r\n"
      client.write(client_request)
      response = read_rtsp_message(client)

      assert_match(/\ARTSP\/1\.0 200/, response)
      assert_includes response, "CSeq: 1\r\n"
      refute_includes client_request, SECRET
    ensure
      client&.close
      gateway.stop
    end

    first = Timeout.timeout(1) { requests.pop }
    authenticated_preflight = Timeout.timeout(1) { requests.pop }
    forwarded = Timeout.timeout(1) { requests.pop }
    token = Base64.strict_encode64("bblp:#{SECRET}")
    refute_includes first, "Authorization:"
    assert_includes authenticated_preflight, "Authorization: Basic #{token}"
    assert_includes forwarded, "Authorization: Basic #{token}"
    assert_includes forwarded, "rtsps://192.0.2.10:322/streaming/live/1"
    refute_includes forwarded.lines.first, "127.0.0.1"
    assert_operator request_cseq(first), :<, request_cseq(authenticated_preflight)
    assert_operator request_cseq(authenticated_preflight), :<, request_cseq(forwarded)
  ensure
    gateway&.stop
    printer_side&.close
    gateway_side&.close
    printer&.join(1)
    printer&.kill
  end

  def test_loopback_gateway_builds_valid_digest_auth_with_qop
    gateway = new_gateway
    challenge = {
      scheme: "digest",
      parameters: {
        "realm" => "Bambu Camera", "nonce" => "nonce-123",
        "qop" => "auth", "opaque" => "opaque-456"
      }
    }
    gateway.instance_variable_set(:@challenge, challenge)
    request = "SETUP rtsps://192.0.2.10:322/live RTSP/1.0\r\nCSeq: 7\r\n\r\n"

    authenticated = gateway.send(:add_authorization, request)
    authorization = authenticated[/^Authorization: Digest (.+)\r$/i, 1]
    fields = parse_digest_fields(authorization)
    ha1 = Digest::MD5.hexdigest("bblp:Bambu Camera:#{SECRET}")
    ha2 = Digest::MD5.hexdigest("SETUP:rtsps://192.0.2.10:322/live")
    expected = Digest::MD5.hexdigest(
      "#{ha1}:nonce-123:#{fields.fetch('nc')}:#{fields.fetch('cnonce')}:auth:#{ha2}"
    )

    assert_equal "bblp", fields.fetch("username")
    assert_equal "rtsps://192.0.2.10:322/live", fields.fetch("uri")
    assert_equal "opaque-456", fields.fetch("opaque")
    assert_equal expected, fields.fetch("response")
    refute_includes request, SECRET
  end

  def test_loopback_gateway_handles_the_live555_digest_challenge
    gateway_side, printer_side = Socket.pair(:UNIX, :STREAM, 0)
    tls_socket = WaitWritableTlsSocket.new(gateway_side)
    requests = Queue.new
    printer = Thread.new do
      request = read_rtsp_message(printer_side)
      requests << request
      challenge = 'WWW-Authenticate: Digest realm="LIVE555 Streaming Media", nonce="n-456"'
      printer_side.write(rtsp_response(401, challenge, cseq: request_cseq(request)))
      request = read_rtsp_message(printer_side)
      requests << request
      printer_side.write(rtsp_response(200, cseq: request_cseq(request)))
      request = read_rtsp_message(printer_side)
      requests << request
      printer_side.write(rtsp_response(200, cseq: request_cseq(request)))
    end
    gateway = new_gateway

    BambuCompanion::TlsCertificate.stub(:open_pinned, ->(**) { tls_socket }) do
      url = gateway.start
      port = Integer(url[/:(\d+)\//, 1])
      client = TCPSocket.new("127.0.0.1", port)
      client.write("SETUP #{url}/track1 RTSP/1.0\r\nCSeq: 2\r\n\r\n")
      response = read_rtsp_message(client)
      assert_match(/\ARTSP\/1\.0 200/, response)
      assert_includes response, "CSeq: 2\r\n"
    ensure
      client&.close
      gateway.stop
    end

    Timeout.timeout(1) { requests.pop }
    authenticated_preflight = Timeout.timeout(1) { requests.pop }
    forwarded = Timeout.timeout(1) { requests.pop }
    assert_valid_live555_digest(authenticated_preflight, method: "DESCRIBE")
    assert_valid_live555_digest(forwarded, method: "SETUP")
    refute_includes forwarded, SECRET
  ensure
    gateway&.stop
    printer_side&.close
    gateway_side&.close
    printer&.join(1)
    printer&.kill
  end


  def test_loopback_gateway_builds_reproducible_md5_sess_without_qop
    gateway = new_gateway
    gateway.instance_variable_set(
      :@challenge,
      scheme: "digest",
      parameters: {
        "realm" => "Bambu Camera", "nonce" => "sess-nonce",
        "algorithm" => "MD5-sess"
      }
    )
    request = "PLAY rtsps://192.0.2.10:322/live RTSP/1.0\r\nCSeq: 8\r\n\r\n"

    authenticated = gateway.send(:add_authorization, request)
    fields = parse_digest_fields(authenticated[/^Authorization: Digest (.+)\r$/i, 1])
    cnonce = fields.fetch("cnonce")
    initial_ha1 = Digest::MD5.hexdigest("bblp:Bambu Camera:#{SECRET}")
    ha1 = Digest::MD5.hexdigest("#{initial_ha1}:sess-nonce:#{cnonce}")
    ha2 = Digest::MD5.hexdigest("PLAY:rtsps://192.0.2.10:322/live")

    assert_equal Digest::MD5.hexdigest("#{ha1}:sess-nonce:#{ha2}"),
                 fields.fetch("response")
  end

  def test_loopback_gateway_forwards_interleaved_rtcp_without_modification
    gateway = new_gateway
    remote_reader, remote_writer = IO.pipe
    gateway.instance_variable_set(:@remote, remote_writer)
    frame = "$\x01\x00\x04rtcp".b
    buffer = frame.dup

    gateway.send(:forward_local_messages, buffer, "local", "remote")

    assert_equal frame, remote_reader.read(frame.bytesize)
    assert_empty buffer
  ensure
    remote_reader&.close
    remote_writer&.close
  end

  def test_real_ffmpeg_completes_authenticated_rtsp_handshake_through_gateway
    skip "ffmpeg is unavailable" unless BambuCompanion::RtspsSnapshot.ffmpeg_available?

    gateway_side, printer_side = Socket.pair(:UNIX, :STREAM, 0)
    tls_socket = TlsLikeSocket.new(gateway_side)
    requests = Queue.new
    printer = Thread.new do
      serve_ffmpeg_handshake(printer_side, requests)
    ensure
      printer_side.close
    end
    gateway = new_gateway

    BambuCompanion::TlsCertificate.stub(:open_pinned, ->(**) { tls_socket }) do
      url = gateway.start
      argv = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-rtsp_transport", "tcp", "-timeout", "1000000", "-i", url,
        "-t", "0.1", "-f", "null", "-"
      ]
      Open3.capture3(*argv)
      refute_includes argv.join(" "), SECRET
    ensure
      gateway.stop
    end

    assert printer.join(2), "fake RTSP printer did not finish the handshake"
    seen = drain_queue(requests)
    methods = seen.map { |request| request.split.first }
    cseqs = seen.map { |request| request_cseq(request) }
    %w[OPTIONS DESCRIBE SETUP PLAY].each { |method| assert_includes methods, method }
    assert(cseqs.each_cons(2).all? { |first, second| second > first })
    assert(seen.drop(1).all? { |request| request.include?("Authorization: Digest ") })
  ensure
    gateway&.stop
    printer_side&.close
    gateway_side&.close
    printer&.kill
    printer&.join(1)
  end

  def test_capped_stderr_truncates_instead_of_buffering_forever
    huge = StringIO.new("e" * 20_000)
    text = BambuCompanion::RtspsSnapshot.read_capped(huge, 4096, overflow: :truncate)

    assert_equal 4096, text.bytesize
  end

  def test_loopback_listener_closes_after_the_first_connection
    gateway = BambuCompanion::RtspsSnapshot::LoopbackGateway.new(
      host: "127.0.0.1", port: 1, username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, timeout: 0.2
    )
    url = gateway.start
    port = Integer(url[/:(\d+)\//, 1])
    first = TCPSocket.new("127.0.0.1", port)
    begin
      wait_until { second_connect_refused?(port) }
    ensure
      first.close
      gateway.stop
    end
  end

  def test_capped_stdout_rejects_oversize_before_decode
    huge = StringIO.new("x" * (BambuCompanion::CameraStore::MAX_JPEG_BYTES + 1))
    error = assert_raises(BambuCompanion::RtspsError) do
      BambuCompanion::RtspsSnapshot.read_capped(
        huge, BambuCompanion::CameraStore::MAX_JPEG_BYTES
      )
    end

    assert_equal "oversized_frame", error.code
  end

  def test_timeout_kills_the_process_group_and_redacts_the_secret
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32,
      runner: lambda { |*|
        raise BambuCompanion::RtspsError.new(
          "timeout", "ffmpeg timed out rtsps://bblp:#{SECRET}@192.168.1.50:322/streaming/live/1"
        )
      }
    )

    error = assert_raises(BambuCompanion::RtspsError) { snapshot.capture }
    assert_equal "timeout", error.code
    refute_includes error.message, SECRET
  end

  def test_rejects_non_jpeg_stdout
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32,
      runner: ->(*) { "not-jpeg" }
    )

    error = assert_raises(BambuCompanion::RtspsError) { snapshot.capture }
    assert_equal "invalid_frame", error.code
  end

  def test_rejects_jpeg_bomb_stdout
    snapshot = BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32,
      runner: ->(*) { BambuCompanion::TestFixtures.minimal_jpeg(width: 65_535, height: 65_535) }
    )

    error = assert_raises(BambuCompanion::RtspsError) { snapshot.capture }
    assert_equal "invalid_frame", error.code
  end

  private

  def new_snapshot
    BambuCompanion::RtspsSnapshot.new(
      host: "192.168.1.50", username: "bblp", password: SECRET,
      fingerprint: "AA" * 32
    )
  end

  def new_gateway
    BambuCompanion::RtspsSnapshot::LoopbackGateway.new(
      host: "192.0.2.10", port: 322, username: "bblp", password: SECRET,
      fingerprint: "AA" * 32, timeout: 1
    )
  end

  def read_rtsp_message(io)
    buffer = +""
    Timeout.timeout(1) do
      loop do
        buffer << io.readpartial(4096)
        header_end = buffer.index("\r\n\r\n")
        next unless header_end

        length = buffer.byteslice(0, header_end)[/^Content-Length:\s*(\d+)$/i, 1].to_i
        total = header_end + 4 + length
        return buffer.byteslice(0, total) if buffer.bytesize >= total
      end
    end
  end

  def rtsp_response(status, extra_header = nil, cseq: 1)
    reason = status == 200 ? "OK" : "Unauthorized"
    headers = ["RTSP/1.0 #{status} #{reason}", "CSeq: #{cseq}"]
    headers << extra_header if extra_header
    headers << "Content-Length: 0"
    "#{headers.join("\r\n")}\r\n\r\n"
  end


  def request_cseq(request) = Integer(request[/^CSeq:\s*(\d+)/i, 1])

  def response_for(request, status: 200, headers: [], body: "")
    reason = status == 200 ? "OK" : "Unauthorized"
    lines = ["RTSP/1.0 #{status} #{reason}", "CSeq: #{request_cseq(request)}", *headers]
    lines << "Content-Length: #{body.bytesize}"
    "#{lines.join("\r\n")}\r\n\r\n#{body}"
  end

  def serve_ffmpeg_handshake(socket, requests)
    request = read_rtsp_message(socket)
    requests << request
    challenge = 'WWW-Authenticate: Digest realm="LIVE555 Streaming Media", nonce="probe"'
    socket.write(response_for(request, status: 401, headers: [challenge]))

    request = read_rtsp_message(socket)
    requests << request
    socket.write(response_for(request, headers: ["Content-Type: application/sdp"], body: SDP))

    loop do
      request = read_rtsp_message(socket)
      requests << request
      case request.split.first
      when "OPTIONS"
        socket.write(response_for(request, headers: [
          "Public: OPTIONS, DESCRIBE, SETUP, PLAY"
        ]))
      when "DESCRIBE"
        socket.write(response_for(request, headers: [
          "Content-Type: application/sdp",
          "Content-Base: rtsps://192.0.2.10:322/streaming/live/1/"
        ], body: SDP))
      when "SETUP"
        socket.write(response_for(request, headers: [
          "Session: offline-session;timeout=60",
          "Transport: RTP/AVP/TCP;unicast;interleaved=0-1;ssrc=01020304"
        ]))
      when "PLAY"
        socket.write(response_for(request, headers: ["Session: offline-session"]))
        break
      else
        socket.write(response_for(request))
      end
    end
  end

  def drain_queue(queue)
    values = []
    values << queue.pop until queue.empty?
    values
  end

  def parse_digest_fields(text)
    text.scan(/([a-z]+)=("[^"]*"|[^,\s]+)/i).to_h do |key, value|
      [key.downcase, value.delete_prefix('"').delete_suffix('"')]
    end
  end

  def assert_valid_live555_digest(request, method:)
    authorization = request[/^Authorization: Digest (.+)\r$/i, 1]
    fields = parse_digest_fields(authorization)
    ha1 = Digest::MD5.hexdigest("bblp:LIVE555 Streaming Media:#{SECRET}")
    ha2 = Digest::MD5.hexdigest("#{method}:#{fields.fetch('uri')}")
    expected = Digest::MD5.hexdigest("#{ha1}:n-456:#{ha2}")

    assert_equal "bblp", fields.fetch("username")
    assert_equal expected, fields.fetch("response")
  end

  def second_connect_refused?(port)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.close
    false
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE
    true
  end

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      raise "condition not met" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
