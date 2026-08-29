# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "zip"
require "bambu_companion/gcode_source"

class GcodeSourceTest < Minitest::Test
  class ChunkOnlyIo
    attr_reader :requests

    def initialize(content)
      @content = content.b
      @offset = 0
      @requests = []
    end

    def read(length)
      @requests << length
      return nil if @offset >= @content.bytesize

      chunk = @content.byteslice(@offset, length)
      @offset += chunk.bytesize
      chunk
    end

    def each_line
      raise "LimitedLineIO must not delegate to each_line"
    end
  end

  def with_zip(entries)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "model.gcode.3mf")
      Zip::File.open(path, create: true) do |zip|
        entries.each do |name, content|
          zip.get_output_stream(name) { |stream| stream.write(content) }
        end
      end
      yield path
    end
  end

  def read_source(path, hints = {}, max_bytes: 1024)
    source = BambuCompanion::GcodeSource.new(max_uncompressed_bytes: max_bytes)
    source.open(path, hints) { |io| io.each_line.to_a.join }
  end

  def test_reads_direct_gcode
    Dir.mktmpdir do |dir|
      path = File.join(dir, "part.gcode")
      File.write(path, "G1 X1\n")
      assert_equal "G1 X1\n", read_source(path)
    end
  end

  def test_rejects_non_positive_limits
    assert_raises(ArgumentError) { BambuCompanion::LimitedLineIO.new(StringIO.new, 0) }
    assert_raises(ArgumentError) do
      BambuCompanion::LimitedLineIO.new(StringIO.new, 1, max_line_bytes: 0)
    end
    assert_raises(ArgumentError) do
      BambuCompanion::GcodeSource.new(max_archive_bytes: 0)
    end
    assert_raises(ArgumentError) do
      BambuCompanion::GcodeSource.new(max_archive_entries: 0)
    end
  end

  def test_yields_only_the_line_oriented_source
    Dir.mktmpdir do |dir|
      path = File.join(dir, "part.gcode")
      File.write(path, "G1 X1\n")
      yielded = nil

      BambuCompanion::GcodeSource.new.open(path) { |*arguments| yielded = arguments }

      assert_equal 1, yielded.length
      assert_instance_of BambuCompanion::LimitedLineIO, yielded.first
    end
  end

  def test_remote_source_name_classifies_extensionless_download
    Dir.mktmpdir do |dir|
      path = File.join(dir, "download")
      File.write(path, "G1 X2\n")
      assert_equal "G1 X2\n", read_source(path, { "source_name" => "/cache/part.gcode" })
    end
  end

  def test_prefers_explicit_internal_path_then_zero_based_plate
    entries = {
      "Metadata/plate_1.gcode" => "PLATE1\n",
      "Metadata/plate_2.gcode" => "PLATE2\n"
    }
    with_zip(entries) do |path|
      assert_equal "PLATE2\n", read_source(path, { "gcode_file" => "Metadata/plate_2.gcode" })
      assert_equal "PLATE1\n", read_source(path, { "plate_idx" => 0 })
    end
  end

  def test_x2d_internal_path_selects_archive_entry_before_plate_idx
    entries = {
      "Metadata/plate_1.gcode" => "PLATE1\n",
      "Metadata/plate_2.gcode" => "PLATE2\n"
    }
    with_zip(entries) do |path|
      hints = {
        "gcode_file" => "/data/Metadata/plate_1.gcode",
        "plate_idx" => 1
      }

      assert_equal "PLATE1\n", read_source(path, hints)
    end
  end

  def test_x2d_internal_path_can_arrive_in_file_hint
    entries = {
      "Metadata/plate_1.gcode" => "PLATE1\n",
      "Metadata/plate_2.gcode" => "PLATE2\n"
    }
    with_zip(entries) do |path|
      assert_equal "PLATE1\n", read_source(
        path, { "file" => "/data/Metadata/plate_1.gcode", "plate_idx" => 1 }
      )
    end
  end

  def test_archive_filename_hint_does_not_override_the_unique_internal_gcode
    with_zip("Metadata/plate_1.gcode" => "LIVE-PLATE\n") do |path|
      hints = {
        "source_name" => "/cache/Single Colour Version.3mf",
        "gcode_file" => "Single Colour Version.3mf"
      }

      assert_equal "LIVE-PLATE\n", read_source(path, hints)
    end
  end

  def test_rejects_ambiguous_archive
    with_zip("a.gcode" => "A", "b.gcode" => "B") do |path|
      error = assert_raises(BambuCompanion::SourceError) { read_source(path) }
      assert_equal "ambiguous_archive", error.code
    end
  end

  def test_rejects_archives_with_too_many_entries
    with_zip(
      "Metadata/plate_1.gcode" => "G1 X1\n",
      "Metadata/info.txt" => "first",
      "Metadata/more.txt" => "second"
    ) do |path|
      source = BambuCompanion::GcodeSource.new(max_archive_entries: 2)
      error = assert_raises(BambuCompanion::SourceError) do
        source.open(path) { |io| io.each_line.to_a }
      end

      assert_equal "too_large", error.code
    end
  end

  def test_rejects_oversized_archive_containers_before_opening_zip
    with_zip("Metadata/plate_1.gcode" => "G1 X1\n") do |path|
      source = BambuCompanion::GcodeSource.new(max_archive_bytes: File.size(path) - 1)
      error = assert_raises(BambuCompanion::SourceError) do
        source.open(path) { |io| io.each_line.to_a }
      end

      assert_equal "too_large", error.code
    end
  end

  def test_ignores_archive_entries_with_oversized_names
    name = ("directory/" * 110) + "part.gcode"
    assert_operator name.bytesize, :>, BambuCompanion::Archive::MAX_ENTRY_NAME_BYTES
    with_zip(name => "G1 X1\n") do |path|
      error = assert_raises(BambuCompanion::SourceError) { read_source(path) }

      assert_equal "entry_not_found", error.code
    end
  end

  def test_bounds_actual_uncompressed_read
    with_zip("Metadata/plate_1.gcode" => "X" * 40) do |path|
      error = assert_raises(BambuCompanion::SourceError) { read_source(path, {}, max_bytes: 20) }
      assert_equal "too_large", error.code
    end
  end

  def test_ignores_path_traversal_entries
    with_zip("../Metadata/plate_1.gcode" => "UNSAFE") do |path|
      error = assert_raises(BambuCompanion::SourceError) { read_source(path) }
      assert_equal "entry_not_found", error.code
    end
  end

  def test_rejects_path_traversal_explicit_entry_name
    with_zip("Metadata/plate_1.gcode" => "SAFE") do |path|
      error = assert_raises(BambuCompanion::SourceError) do
        read_source(path, { "gcode_file" => "../Metadata/plate_1.gcode" })
      end
      assert_equal "entry_not_found", error.code
    end
  end

  def test_reads_hostile_unterminated_input_in_bounded_chunks
    io = ChunkOnlyIo.new("X" * 9)
    source = BambuCompanion::LimitedLineIO.new(io, 8)

    error = assert_raises(BambuCompanion::SourceError) { source.each_line.to_a }

    assert_equal "too_large", error.code
    assert_equal [9], io.requests
  end

  def test_rejects_unterminated_line_over_the_bounded_line_limit
    max_line_bytes = 1 << 20
    io = ChunkOnlyIo.new("X" * (max_line_bytes + 1))
    source = BambuCompanion::LimitedLineIO.new(io, 2 * max_line_bytes)

    error = assert_raises(BambuCompanion::SourceError) { source.each_line.to_a }

    assert_equal "too_large", error.code
    assert_operator io.requests.max, :<=, 64 << 10
  end

  def test_reads_direct_handle_that_was_opened_before_the_path_can_change
    Dir.mktmpdir do |dir|
      path = File.join(dir, "part.gcode")
      File.write(path, "ORIGINAL\n")
      original_size = File.method(:size)

      with_singleton_override(File, :size, lambda { |target|
        File.write(path, "REPLACED\n") if target == path
        original_size.call(target)
      }) do
        assert_equal "ORIGINAL\n", read_source(path)
      end
    end
  end

  def test_reads_3mf_stream_from_the_open_archive_handle_after_path_replacement
    Dir.mktmpdir do |dir|
      path = File.join(dir, "model.gcode.3mf")
      replacement = File.join(dir, "replacement.gcode.3mf")
      write_zip(path, "Metadata/plate_1.gcode" => "ORIGINAL\n")
      write_zip(replacement, "Metadata/plate_1.gcode" => "REPLACED\n")
      original_new = Zip::InputStream.method(:new)
      replaced = false

      with_singleton_override(Zip::InputStream, :new, lambda { |context, *arguments, **keywords|
        unless replaced
          FileUtils.mv(replacement, path)
          replaced = true
        end
        original_new.call(context, *arguments, **keywords)
      }) do
        assert_equal "ORIGINAL\n", read_source(path)
      end
    end
  end

  def test_rejects_negative_plate_index
    with_zip("Metadata/plate_1.gcode" => "PLATE1\n") do |path|
      error = assert_raises(BambuCompanion::SourceError) { read_source(path, { "plate_idx" => -1 }) }
      assert_equal "entry_not_found", error.code
    end
  end

  def test_uses_the_only_metadata_plate_when_firmware_index_does_not_match
    with_zip("Metadata/plate_1.gcode" => "PLATE1\n") do |path|
      assert_equal "PLATE1\n", read_source(path, { "plate_idx" => 1 })
    end
  end

  def test_rejects_missing_requested_plate_when_multiple_metadata_plates_exist
    entries = {
      "Metadata/plate_1.gcode" => "PLATE1\n",
      "Metadata/plate_2.gcode" => "PLATE2\n"
    }
    with_zip(entries) do |path|
      error = assert_raises(BambuCompanion::SourceError) { read_source(path, { "plate_idx" => 8 }) }
      assert_equal "entry_not_found", error.code
    end
  end

  def test_rejects_ambiguous_case_insensitive_explicit_entry_match
    entries = {
      "Metadata/PLATE_1.gcode" => "FIRST\n",
      "metadata/plate_1.gcode" => "SECOND\n"
    }
    with_zip(entries) do |path|
      error = assert_raises(BambuCompanion::SourceError) do
        read_source(path, { "gcode_file" => "METADATA/plate_1.gcode" })
      end
      assert_equal "ambiguous_archive", error.code
    end
  end

  def test_rejects_windows_drive_archive_entry
    with_zip("C:/Metadata/plate_1.gcode" => "UNSAFE") do |path|
      error = assert_raises(BambuCompanion::SourceError) { read_source(path) }
      assert_equal "entry_not_found", error.code
    end
  end

  def test_does_not_wrap_zip_errors_raised_by_the_consumer_block
    Dir.mktmpdir do |dir|
      path = File.join(dir, "part.gcode")
      File.write(path, "G1 X1\n")
      raised = Zip::Error.new("consumer failure")

      assert_raises(Zip::Error) { BambuCompanion::GcodeSource.new.open(path) { raise raised } }
    end
  end

  def test_wraps_zip_errors_raised_while_streaming_entry_data
    with_zip("Metadata/plate_1.gcode" => "G1 X1\n") do |path|
      original_read = Zip::InputStream.instance_method(:read)
      raised = Zip::DecompressionError.new(Zlib::DataError.new("corrupt deflate"))

      Zip::InputStream.define_method(:read) { |*| raise raised }
      error = assert_raises(BambuCompanion::SourceError) { read_source(path) }

      assert_equal "unsupported_source", error.code
    ensure
      Zip::InputStream.define_method(:read, original_read)
    end
  end

  def test_closes_duplicated_archive_handle_when_stream_initialization_fails
    with_zip("Metadata/plate_1.gcode" => "G1 X1\n") do |path|
      closed = 0
      original_dup = BambuCompanion::ArchiveFileIO.instance_method(:dup)
      original_new = Zip::InputStream.method(:new)

      BambuCompanion::ArchiveFileIO.define_method(:dup) do
        duplicate = original_dup.bind_call(self)
        original_close = duplicate.method(:close)
        duplicate.define_singleton_method(:close) { closed += 1; original_close.call }
        duplicate
      end
      with_singleton_override(Zip::InputStream, :new, lambda { |*arguments, **keywords|
        original_new.call(*arguments, **keywords)
        raise Zip::Error, "stream initialization failed"
      }) do
        error = assert_raises(BambuCompanion::SourceError) { read_source(path) }
        assert_equal "unsupported_source", error.code
      end

      assert_equal 1, closed
    ensure
      BambuCompanion::ArchiveFileIO.define_method(:dup, original_dup)
    end
  end

  def test_rejects_nonempty_entry_that_streams_zero_bytes
    with_zip("Metadata/plate_1.gcode" => "G1 X1\n") do |path|
      original_read = Zip::InputStream.instance_method(:read)
      Zip::InputStream.define_method(:read) { |_| nil }

      error = assert_raises(BambuCompanion::SourceError) { read_source(path) }

      assert_equal "unsupported_source", error.code
    ensure
      Zip::InputStream.define_method(:read, original_read)
    end
  end

  def test_rejects_archive_entry_that_ends_after_only_part_of_its_declared_size
    stream = BambuCompanion::ArchiveEntryIO.new(ChunkOnlyIo.new("123456"), 100)
    source = BambuCompanion::LimitedLineIO.new(stream, 200)

    error = assert_raises(BambuCompanion::SourceError) { source.each_line.to_a }

    assert_equal "unsupported_source", error.code
  end

  def test_accepts_empty_archive_entry_with_zero_declared_size
    stream = BambuCompanion::ArchiveEntryIO.new(ChunkOnlyIo.new(""), 0)
    source = BambuCompanion::LimitedLineIO.new(stream, 200)

    assert_empty source.each_line.to_a
  end

  private

  def write_zip(path, entries)
    Zip::File.open(path, create: true) do |zip|
      entries.each do |name, content|
        zip.get_output_stream(name) { |stream| stream.write(content) }
      end
    end
  end

  def with_singleton_override(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
