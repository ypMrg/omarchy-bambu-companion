# frozen_string_literal: true

require "zip"
require_relative "archive_file_io"
require_relative "print_file_hints"

module BambuCompanion
  class SourceError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  class LimitedLineIO
    CHUNK_BYTES = 64 << 10
    DEFAULT_MAX_LINE_BYTES = 1 << 20

    def initialize(io, limit, max_line_bytes: DEFAULT_MAX_LINE_BYTES)
      @io = io
      @limit = Integer(limit)
      @max_line_bytes = Integer(max_line_bytes)
      raise ArgumentError, "limit must be positive" unless @limit.positive?
      raise ArgumentError, "max_line_bytes must be positive" unless @max_line_bytes.positive?

      @read = 0
    end

    def each_line
      return enum_for(__method__) unless block_given?

      pending = String.new(encoding: Encoding::BINARY)
      while (chunk = read_chunk)
        pending << chunk
        while (newline = pending.index("\n"))
          line = pending.slice!(0, newline + 1)
          check_line_size!(line.bytesize)
          yield line
        end

        check_line_size!(pending.bytesize)
      end
      @io.verify_complete! if @io.respond_to?(:verify_complete!)
      yield pending unless pending.empty?
    end

    private

    def read_chunk
      bytes_to_read = [CHUNK_BYTES, @limit - @read + 1].min
      chunk = @io.read(bytes_to_read)
      return if chunk.nil? || chunk.empty?

      @read += chunk.bytesize
      if @read > @limit
        raise SourceError.new("too_large", "Uncompressed G-code exceeds #{@limit} bytes")
      end

      chunk
    end

    def check_line_size!(size)
      return if size <= @max_line_bytes

      raise SourceError.new("too_large", "G-code line exceeds #{@max_line_bytes} bytes")
    end
  end

  class ArchiveEntryIO
    def initialize(io, declared_size)
      @io = io
      @declared_size = Integer(declared_size)
      @read = 0
    end

    def read(*)
      chunk = @io.read(*)
      @read += chunk.bytesize if chunk
      chunk
    rescue Zip::Error => error
      raise SourceError.new("unsupported_source", "Invalid 3MF archive: #{error.message}")
    end

    def verify_complete!
      return if @read == @declared_size

      raise SourceError.new("unsupported_source", "3MF G-code entry size did not match its declared data")
    end

    def close = @io.close
  end

  class GcodeSource
    DEFAULT_MAX_UNCOMPRESSED_BYTES = 1 << 30

    def initialize(max_uncompressed_bytes: DEFAULT_MAX_UNCOMPRESSED_BYTES,
                   max_archive_bytes: Archive::MAX_BYTES,
                   max_archive_entries: Archive::MAX_ENTRIES)
      @max_uncompressed_bytes = Integer(max_uncompressed_bytes)
      raise ArgumentError, "max_uncompressed_bytes must be positive" unless @max_uncompressed_bytes.positive?

      @max_archive_bytes = Integer(max_archive_bytes)
      raise ArgumentError, "max_archive_bytes must be positive" unless @max_archive_bytes.positive?

      @max_archive_entries = Integer(max_archive_entries)
      raise ArgumentError, "max_archive_entries must be positive" unless @max_archive_entries.positive?
    end

    def open(path, hints = {})
      raise ArgumentError, "block required" unless block_given?

      hints = hints.to_h
      source_name = hints["source_name"] || hints[:source_name] || path
      name = File.basename(source_name).downcase
      if name.end_with?(".gcode") && !name.end_with?(".gcode.3mf")
        return File.open(path, "rb") do |io|
          check_size!(io.stat.size)
          yield LimitedLineIO.new(io, @max_uncompressed_bytes)
        end
      end

      unless name.end_with?(".3mf")
        raise SourceError.new("unsupported_source", "Unsupported print file: #{File.basename(path)}")
      end

      open_archive(path, hints) { |io| yield io }
    end

    private

    def select_entry(entries, hints)
      candidates = entries.select do |entry|
        entry.file? && Archive.safe_entry_name?(entry.name) && entry.name.downcase.end_with?(".gcode")
      end
      raise SourceError.new("entry_not_found", "Archive contains no G-code entry") if candidates.empty?

      explicit = PrintFileHints.internal_gcode_entry(hints)
      explicit ||= hints["gcode_file"] || hints[:gcode_file]
      unless explicit.to_s.empty? || archive_container_hint?(explicit)
        found = exact_entry(candidates, explicit)
        return found if found

        raise SourceError.new("entry_not_found", "Requested G-code entry was not found")
      end

      metadata = candidates.select { |entry| %r{\AMetadata/plate_\d+\.gcode\z}i.match?(entry.name) }
      plate = hints["plate_idx"] || hints[:plate_idx]
      unless plate.nil?
        zero_based = Integer(plate)
        raise ArgumentError, "negative plate index" if zero_based.negative?

        selected = exact_entry(candidates, "Metadata/plate_#{zero_based + 1}.gcode")
        return selected if selected
        return metadata.first if metadata.length == 1

        raise SourceError.new("entry_not_found", "Requested G-code plate was not found")
      end

      return metadata.first if metadata.length == 1
      return candidates.first if candidates.length == 1

      raise SourceError.new("ambiguous_archive", "Archive contains multiple possible G-code entries")
    rescue ArgumentError, TypeError
      raise SourceError.new("entry_not_found", "Invalid plate index")
    end

    # Bambu MQTT reports use gcode_file for two different things depending on
    # firmware: either the selected entry or the outer 3MF archive on the SD
    # card. An archive name must not be matched against its internal entries.
    def archive_container_hint?(value)
      File.basename(String(value).tr("\\", "/")).downcase.end_with?(".3mf")
    rescue TypeError
      false
    end

    def exact_entry(entries, name)
      normalized = String(name).tr("\\", "/")
      return unless Archive.safe_entry_name?(normalized)

      exact = entries.find { |entry| entry.name == normalized }
      return exact if exact

      matches = entries.select { |entry| entry.name.casecmp?(normalized) }
      return matches.first if matches.length == 1
      return if matches.empty?

      raise SourceError.new("ambiguous_archive", "Archive contains ambiguous G-code entry names")
    end

    def open_archive(path, hints)
      File.open(path, "rb") do |file|
        check_archive_size!(file.stat.size)
        archive_io = ArchiveFileIO.new(file)
        archive = open_archive_buffer(archive_io)
        check_archive_entries!(archive.entries.length)
        entry = select_entry(archive.entries, hints)
        if entry.encrypted?
          raise SourceError.new("encrypted_archive", "Encrypted G-code entries are not supported")
        end

        check_size!(entry.size)
        stream = open_entry_stream(entry, archive_io)
        begin
          return yield LimitedLineIO.new(stream, @max_uncompressed_bytes)
        ensure
          stream.close
        end
      end
    end

    def open_archive_buffer(io)
      Zip::File.open_buffer(io)
    rescue Zip::Error => error
      raise SourceError.new("unsupported_source", "Invalid 3MF archive: #{error.message}")
    end

    def open_entry_stream(entry, archive)
      ArchiveEntryIO.new(archive.open_entry_stream(entry), entry.size)
    rescue Zip::Error => error
      raise SourceError.new("unsupported_source", "Invalid 3MF archive: #{error.message}")
    end

    def check_size!(size)
      return if Integer(size) <= @max_uncompressed_bytes

      raise SourceError.new("too_large", "G-code exceeds #{@max_uncompressed_bytes} bytes")
    end

    def check_archive_size!(size)
      return if Integer(size) <= @max_archive_bytes

      raise SourceError.new("too_large", "3MF archive exceeds #{@max_archive_bytes} bytes")
    end

    def check_archive_entries!(count)
      return if Integer(count) <= @max_archive_entries

      raise SourceError.new("too_large", "3MF archive contains too many entries")
    end
  end
end
