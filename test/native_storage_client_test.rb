# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "tmpdir"
require "bambu_companion/native_storage_client"

class NativeStorageClientTest < Minitest::Test
  LOGIN_ACK = BambuCompanion::NativeStorageClient::SERVER_LOGIN_MAGIC
  CTRL_REPLY = BambuCompanion::NativeStorageClient::SERVER_CTRL_MAGIC

  class ScriptedSocket
    attr_reader :written

    def initialize(input, max_read: 5, max_write: 7)
      @input = input.b
      @max_read = max_read
      @max_write = max_write
      @written = "".b
      @closed = false
    end

    def read_nonblock(length, **)
      return nil if @input.empty?

      @input.slice!(0, [length, @max_read].min)
    end

    def write_nonblock(bytes, **)
      length = [bytes.bytesize, @max_write].min
      @written << bytes.byteslice(0, length)
      length
    end

    def close = @closed = true
    def closed? = @closed
  end

  def test_lists_internal_storage_and_downloads_verified_archive_atomically
    archive = "PK\x03\x04abc".b
    transcript = frame(LOGIN_ACK, "") +
                 control_frame("mtype" => 12_291, "sequence" => 0, "result" => 0) +
                 control_frame(
                   "mtype" => 12_289, "cmdtype" => 1, "sequence" => 1, "result" => 0,
                   "reply" => { "file_lists" => [
                     { "name" => "模型.gcode.3mf", "path" => "/cache/模型.gcode.3mf",
                       "size" => archive.bytesize }
                   ] }
                 ) +
                 control_frame(
                   {
                     "mtype" => 12_289, "cmdtype" => 2, "sequence" => 2, "result" => 1,
                     "reply" => { "size" => 3 }
                   }, archive.byteslice(0, 3)
                 ) +
                 control_frame(
                   {
                     "mtype" => 12_289, "cmdtype" => 2, "sequence" => 2, "result" => 0,
                     "reply" => { "size" => 4 }
                   }, archive.byteslice(3, 4)
                 )
    socket = ScriptedSocket.new(transcript)
    factory_arguments = nil
    client = build_client(socket) { |arguments| factory_arguments = arguments }
    updates = []

    Dir.mktmpdir do |directory|
      destination = File.join(directory, "archive.gcode.3mf")
      remote = client.download(
        hints: internal_hints("模型"), destination: destination,
        progress: ->(loaded, total) { updates << [loaded, total] }
      )

      assert_equal "/cache/模型.gcode.3mf", remote
      assert_equal archive, File.binread(destination)
      assert_equal [[0, nil], [3, nil], [7, nil]], updates
      assert_empty Dir.children(directory).grep(/\.part\z/)
    end

    assert socket.closed?
    assert_equal "192.168.1.50", factory_arguments.fetch(:host)
    assert_equal 6000, factory_arguments.fetch(:port)
    assert_equal ["11" * 32, "22" * 32], factory_arguments.fetch(:fingerprint)
    assert_client_requests(socket.written)
  end

  def test_rejects_inconsistent_offset_and_preserves_existing_destination
    archive = "abcdef".b
    transcript = basic_transcript(
      name: "broken.gcode.3mf", size: archive.bytesize,
      download_frames: [
        control_frame(
          {
            "mtype" => 12_289, "cmdtype" => 4, "sequence" => 3, "result" => 0,
            "reply" => { "size" => 6, "offset" => 2, "total" => 6 }
          }, archive
        )
      ]
    )
    client = build_client(ScriptedSocket.new(transcript))

    Dir.mktmpdir do |directory|
      destination = File.join(directory, "archive.gcode.3mf")
      File.binwrite(destination, "previous")

      error = assert_raises(BambuCompanion::NativeStorageError) do
        client.download(hints: internal_hints("broken"), destination: destination)
      end

      assert_equal "protocol", error.code
      assert_equal "previous", File.binread(destination)
      assert_equal ["archive.gcode.3mf"], Dir.children(directory)
    end
  end

  def test_prefers_gcode_3mf_over_project_3mf
    archive = "PK\x03\x04sliced".b
    transcript = frame(LOGIN_ACK, "") +
                 control_frame("mtype" => 12_291, "sequence" => 0, "result" => 0) +
                 control_frame(
                   "mtype" => 12_289, "cmdtype" => 1, "sequence" => 1, "result" => 0,
                   "reply" => { "file_lists" => [
                     { "name" => "Part.3mf", "path" => "/Part.3mf", "size" => 9 },
                     { "name" => "Part.gcode.3mf", "path" => "/cache/Part.gcode.3mf",
                       "size" => archive.bytesize }
                   ] }
                 ) +
                 control_frame(
                   {
                     "mtype" => 12_289, "cmdtype" => 2, "sequence" => 2, "result" => 0,
                     "reply" => { "size" => archive.bytesize }
                   }, archive
                 )
    socket = ScriptedSocket.new(transcript)
    client = build_client(socket)

    Dir.mktmpdir do |directory|
      remote = client.download(
        hints: internal_hints("Part"), destination: File.join(directory, "download")
      )
      assert_equal "/cache/Part.gcode.3mf", remote
    end

    requests = decode_client_frames(socket.written).select { |magic, _| magic == 0x0102013f }
    subfile = JSON.parse(requests.last.last)
    assert_equal 2, subfile.fetch("cmdtype")
    assert_equal true, subfile.dig("req", "zip")
    assert_equal [
      "/cache/Part.gcode.3mf#Metadata/plate_1.gcode",
      "/cache/Part.gcode.3mf#Metadata/plate_1.png"
    ], subfile.dig("req", "paths")
  end

  def test_falls_back_from_logical_internal_view_to_emmc_model_view
    archive = "PK\x03\x04sliced".b
    transcript = frame(LOGIN_ACK, "") +
                 control_frame("mtype" => 12_291, "sequence" => 0, "result" => 0) +
                 control_frame(
                   "mtype" => 12_289, "cmdtype" => 1, "sequence" => 1, "result" => 0,
                   "reply" => { "file_lists" => [] }
                 ) +
                 control_frame(
                   "mtype" => 12_289, "cmdtype" => 1, "sequence" => 2, "result" => 0,
                   "reply" => { "file_lists" => [
                     { "name" => "Part.gcode.3mf", "path" => "/cache/Part.gcode.3mf",
                       "size" => archive.bytesize }
                   ] }
                 ) +
                 control_frame(
                   {
                     "mtype" => 12_289, "cmdtype" => 2, "sequence" => 3, "result" => 0,
                     "reply" => { "size" => archive.bytesize }
                   }, archive
                 )
    socket = ScriptedSocket.new(transcript)
    client = build_client(socket)

    Dir.mktmpdir do |directory|
      remote = client.download(
        hints: internal_hints("Part"), destination: File.join(directory, "download")
      )
      assert_equal "/cache/Part.gcode.3mf", remote
    end

    requests = decode_client_frames(socket.written).filter_map do |magic, payload|
      JSON.parse(payload) if magic == 0x0102013f
    end
    list_requests = requests.select { |request| request["cmdtype"] == 1 }
    assert_equal(
      %w[internal emmc],
      list_requests.map { |request| request.dig("req", "storage") }
    )
    assert_equal 3, requests.last.fetch("sequence")
  end

  def test_full_download_fallback_requires_terminal_md5
    archive = "abcdef".b
    transcript = basic_transcript(
      name: "Part.gcode.3mf", size: archive.bytesize,
      download_frames: [
        control_frame(
          {
            "mtype" => 12_289, "cmdtype" => 4, "sequence" => 3, "result" => 0,
            "reply" => { "size" => 6, "offset" => 0, "total" => 6 }
          }, archive
        )
      ]
    )
    socket = ScriptedSocket.new(transcript)
    client = build_client(socket)

    Dir.mktmpdir do |directory|
      destination = File.join(directory, "archive.gcode.3mf")
      error = assert_raises(BambuCompanion::NativeStorageError) do
        client.download(hints: internal_hints("Part"), destination: destination)
      end

      assert_equal "protocol", error.code
      refute_path_exists destination
      assert_empty Dir.children(directory)
    end

    requests = decode_client_frames(socket.written).filter_map do |magic, payload|
      JSON.parse(payload) if magic == 0x0102013f
    end
    download = requests.last
    assert_equal 4, download.fetch("cmdtype")
    assert_equal 0, download.dig("req", "offset")
  end

  def test_full_download_fallback_publishes_only_after_length_and_md5_match
    archive = "PK\x03\x04verified".b
    transcript = basic_transcript(
      name: "Part.gcode.3mf", size: archive.bytesize,
      download_frames: [
        control_frame(
          {
            "mtype" => 12_289, "cmdtype" => 4, "sequence" => 3, "result" => 0,
            "reply" => {
              "size" => archive.bytesize, "offset" => 0,
              "total" => archive.bytesize,
              "file_md5" => Digest::MD5.hexdigest(archive)
            }
          }, archive
        )
      ]
    )
    client = build_client(ScriptedSocket.new(transcript))

    Dir.mktmpdir do |directory|
      destination = File.join(directory, "archive.gcode.3mf")
      remote = client.download(
        hints: internal_hints("Part"), destination: destination
      )

      assert_equal "/cache/Part.gcode.3mf", remote
      assert_equal archive, File.binread(destination)
      assert_equal ["archive.gcode.3mf"], Dir.children(directory)
    end
  end

  def test_full_download_fallback_rejects_wrong_md5_without_replacing_destination
    archive = "PK\x03\x04corrupt".b
    transcript = basic_transcript(
      name: "Part.gcode.3mf", size: archive.bytesize,
      download_frames: [
        control_frame(
          {
            "mtype" => 12_289, "cmdtype" => 4, "sequence" => 3, "result" => 0,
            "reply" => {
              "size" => archive.bytesize, "offset" => 0,
              "total" => archive.bytesize, "file_md5" => "00" * 16
            }
          }, archive
        )
      ]
    )
    client = build_client(ScriptedSocket.new(transcript))

    Dir.mktmpdir do |directory|
      destination = File.join(directory, "archive.gcode.3mf")
      File.binwrite(destination, "previous")

      error = assert_raises(BambuCompanion::NativeStorageError) do
        client.download(hints: internal_hints("Part"), destination: destination)
      end

      assert_equal "checksum", error.code
      assert_equal "previous", File.binread(destination)
      assert_equal ["archive.gcode.3mf"], Dir.children(directory)
    end
  end

  def test_rejects_oversized_protocol_frame_before_allocating_payload
    oversized_header = [17 << 20, LOGIN_ACK, 0, 0].pack("V4")
    client = build_client(ScriptedSocket.new(oversized_header))

    Dir.mktmpdir do |directory|
      destination = File.join(directory, "archive.gcode.3mf")
      error = assert_raises(BambuCompanion::NativeStorageError) do
        client.download(hints: internal_hints("Part"), destination: destination)
      end

      assert_equal "protocol", error.code
      refute_path_exists destination
      assert_empty Dir.children(directory)
    end
  end

  def test_rejects_ambiguous_same_tier
    transcript = frame(LOGIN_ACK, "") +
                 control_frame("mtype" => 12_291, "sequence" => 0, "result" => 0) +
                 control_frame(
                   "mtype" => 12_289, "cmdtype" => 1, "sequence" => 1, "result" => 0,
                   "reply" => { "file_lists" => [
                     { "name" => "Part.gcode.3mf", "path" => "/Part.gcode.3mf" },
                     { "name" => "part.gcode.3mf", "path" => "/cache/part.gcode.3mf" }
                   ] }
                 )
    client = build_client(ScriptedSocket.new(transcript))

    error = assert_raises(BambuCompanion::NativeStorageError) do
      client.download(hints: internal_hints("Part"), destination: "/tmp/not-written")
    end
    assert_equal "ambiguous_file", error.code
  end

  def test_cancellation_before_connect_does_not_open_storage_socket
    calls = 0
    client = BambuCompanion::NativeStorageClient.new(
      config: config_fixture, secret: "abcd1234", client_id: "client01",
      socket_factory: ->(**) { calls += 1 }
    )

    error = assert_raises(BambuCompanion::NativeStorageError) do
      client.download(
        hints: internal_hints("Part"), destination: "/tmp/not-written",
        cancelled: -> { true }
      )
    end
    assert_equal "cancelled", error.code
    assert_equal 0, calls
  end

  private

  def build_client(socket, &observer)
    BambuCompanion::NativeStorageClient.new(
      config: config_fixture, secret: "abcd1234", client_id: "client01",
      socket_factory: lambda do |**arguments|
        observer&.call(arguments)
        socket
      end
    )
  end

  def internal_hints(name)
    {
      "gcode_file" => "/data/Metadata/plate_1.gcode",
      "subtask_name" => name
    }
  end

  def basic_transcript(name:, size:, download_frames:)
    frame(LOGIN_ACK, "") +
      control_frame("mtype" => 12_291, "sequence" => 0, "result" => 0) +
      control_frame(
        "mtype" => 12_289, "cmdtype" => 1, "sequence" => 1, "result" => 0,
        "reply" => { "file_lists" => [
          { "name" => name, "path" => "/cache/#{name}", "size" => size }
        ] }
      ) +
      control_frame(
        "mtype" => 12_289, "cmdtype" => 2, "sequence" => 2, "result" => 10
      ) + download_frames.join
  end

  def frame(magic, payload)
    bytes = String(payload).b
    [bytes.bytesize, magic, 0, 0].pack("V4") + bytes
  end

  def control_frame(message, binary = "")
    payload = JSON.generate(message).b
    payload += "\n\n".b + binary.b unless binary.empty?
    frame(CTRL_REPLY, payload)
  end

  def decode_client_frames(bytes)
    frames = []
    offset = 0
    while offset < bytes.bytesize
      length, magic, _sequence, reserved = bytes.byteslice(offset, 16).unpack("V4")
      assert_equal 0, reserved
      payload = bytes.byteslice(offset + 16, length)
      frames << [magic, payload]
      offset += 16 + length
    end
    frames
  end

  def assert_client_requests(bytes)
    frames = decode_client_frames(bytes)
    assert_equal [0x0101013f, 0x0102013f, 0x0102013f, 0x0102013f], frames.map(&:first)
    assert_equal "bblp\0\0\0\0abcd1234".b, frames.first.last

    setup = JSON.parse(frames[1].last)
    assert_equal 12_291, setup.fetch("mtype")
    assert_equal "client01", setup.dig("req", "pid")

    list = JSON.parse(frames[2].last)
    assert_equal 1, list.fetch("cmdtype")
    assert_equal "internal", list.dig("req", "storage")

    subfile = JSON.parse(frames[3].last)
    assert_equal 2, subfile.fetch("cmdtype")
    assert_equal true, subfile.dig("req", "zip")
    assert_equal [
      "/cache/模型.gcode.3mf#Metadata/plate_1.gcode",
      "/cache/模型.gcode.3mf#Metadata/plate_1.png"
    ], subfile.dig("req", "paths")
  end
end
