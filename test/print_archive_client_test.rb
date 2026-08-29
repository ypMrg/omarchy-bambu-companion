# frozen_string_literal: true

require_relative "test_helper"
require "bambu_companion/ftps_error"
require "bambu_companion/print_archive_client"

class PrintArchiveClientTest < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(result: nil, error: nil)
      @result = result
      @error = error
      @calls = []
    end

    def download(**arguments)
      @calls << arguments
      raise @error if @error

      @result
    end
  end

  def test_uses_external_storage_when_archive_is_available
    external = FakeClient.new(result: "/cache/Part.gcode.3mf")
    internal = FakeClient.new(result: "/internal/Part.gcode.3mf")
    client = BambuCompanion::PrintArchiveClient.new(external: external, internal: internal)

    result = client.download(hints: internal_hints, destination: "/tmp/download")

    assert_equal "/cache/Part.gcode.3mf", result
    assert_equal 1, external.calls.length
    assert_empty internal.calls
  end

  def test_falls_back_to_internal_storage_only_for_internal_x2d_entry_not_found
    external = FakeClient.new(
      error: BambuCompanion::FtpsError.new("file_not_found", "not on USB")
    )
    internal = FakeClient.new(result: "/cache/Part.gcode.3mf")
    client = BambuCompanion::PrintArchiveClient.new(external: external, internal: internal)

    result = client.download(hints: internal_hints, destination: "/tmp/download")

    assert_equal "/cache/Part.gcode.3mf", result
    assert_equal 1, internal.calls.length
  end

  def test_internal_x2d_entry_falls_back_when_ftps_transport_is_unavailable
    external = FakeClient.new(
      error: BambuCompanion::FtpsError.new("transport", "FTPS failed")
    )
    internal = FakeClient.new(result: "/cache/Part.gcode.3mf")
    client = BambuCompanion::PrintArchiveClient.new(external: external, internal: internal)

    result = client.download(hints: internal_hints, destination: "/tmp/download")

    assert_equal "/cache/Part.gcode.3mf", result
    assert_equal 1, internal.calls.length
  end

  def test_does_not_hide_external_certificate_error
    error = BambuCompanion::FtpsError.new("certificate_changed", "FTPS pin changed")
    external = FakeClient.new(error: error)
    internal = FakeClient.new(result: "/cache/Part.gcode.3mf")
    client = BambuCompanion::PrintArchiveClient.new(external: external, internal: internal)

    raised = assert_raises(BambuCompanion::FtpsError) do
      client.download(hints: internal_hints, destination: "/tmp/download")
    end
    assert_same error, raised
    assert_empty internal.calls
  end

  def test_does_not_use_internal_storage_for_ordinary_sd_card_file
    error = BambuCompanion::FtpsError.new("file_not_found", "missing")
    external = FakeClient.new(error: error)
    internal = FakeClient.new(result: "/cache/Part.gcode.3mf")
    client = BambuCompanion::PrintArchiveClient.new(external: external, internal: internal)

    assert_raises(BambuCompanion::FtpsError) do
      client.download(
        hints: { "gcode_file" => "Part.gcode" }, destination: "/tmp/download"
      )
    end
    assert_empty internal.calls
  end

  private

  def internal_hints
    {
      "gcode_file" => "/data/Metadata/plate_1.gcode",
      "subtask_name" => "Part"
    }
  end
end
