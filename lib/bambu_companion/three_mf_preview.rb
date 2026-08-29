# frozen_string_literal: true

require "zip"
require "zlib"
require_relative "archive_file_io"
require_relative "print_file_hints"

module BambuCompanion
  class PreviewError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  PreviewImage = Data.define(:data, :width, :height, :media_type)

  class ThreeMfPreview
    DEFAULT_MAX_BYTES = 512 * 1024
    DEFAULT_MAX_PIXELS = 4_194_304
    READ_CHUNK_BYTES = 64 * 1024
    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
    FALLBACK_ENTRIES = [
      "Auxiliaries/.thumbnails/thumbnail_middle.png",
      "Auxiliaries/.thumbnails/thumbnail_3mf.png",
      "Auxiliaries/.thumbnails/thumbnail_small.png"
    ].freeze

    def initialize(max_bytes: DEFAULT_MAX_BYTES, max_pixels: DEFAULT_MAX_PIXELS,
                   max_archive_bytes: Archive::MAX_BYTES,
                   max_archive_entries: Archive::MAX_ENTRIES)
      @max_bytes = Integer(max_bytes)
      @max_pixels = Integer(max_pixels)
      raise ArgumentError, "max_bytes must be positive" unless @max_bytes.positive?
      raise ArgumentError, "max_pixels must be positive" unless @max_pixels.positive?

      @max_archive_bytes = Integer(max_archive_bytes)
      raise ArgumentError, "max_archive_bytes must be positive" unless @max_archive_bytes.positive?

      @max_archive_entries = Integer(max_archive_entries)
      raise ArgumentError, "max_archive_entries must be positive" unless @max_archive_entries.positive?
    end

    def extract(path, hints: {}, cancelled: -> { false })
      hints = hints.to_h
      return unless archive_source?(path, hints)

      check_cancelled!(cancelled)
      File.open(path, "rb") do |file|
        check_archive_size!(file.stat.size)
        preview = nil
        archive_io = ArchiveFileIO.new(file)
        Zip::File.open_buffer(archive_io) do |archive|
          check_archive_entries!(archive.entries.length)
          preview = select_preview(archive.entries, archive_io, hints, cancelled)
        end
        preview
      end
    rescue PreviewError
      raise
    rescue Zip::Error, SystemCallError
      nil
    end

    private

    def archive_source?(path, hints)
      source = hints["source_name"] || hints[:source_name] || path
      File.basename(String(source)).downcase.end_with?(".3mf")
    rescue TypeError
      false
    end

    def select_preview(entries, archive, hints, cancelled)
      candidates = entries.select { |entry| entry.file? && Archive.safe_entry_name?(entry.name) }
      preview_names(candidates, hints).each do |name|
        entry = unique_entry(candidates, name)
        break if entry == :ambiguous
        next unless entry

        image = read_preview(entry, archive, cancelled)
        return image if image
      end
      nil
    end

    def preview_names(entries, hints)
      plate = selected_plate(hints)
      preferred = plate ? ["Metadata/plate_#{plate}.png"] : []
      plate_entries = entries.select do |entry|
        %r{\AMetadata/plate_\d+\.png\z}i.match?(entry.name)
      end
      preferred << plate_entries.first.name if plate_entries.length == 1
      [*preferred.uniq, *FALLBACK_ENTRIES]
    end

    def selected_plate(hints)
      internal_plate = PrintFileHints.internal_plate_number(hints)
      return internal_plate if internal_plate

      index = hints["plate_idx"] || hints[:plate_idx]
      return Integer(index) + 1 unless index.nil?

      gcode_file = hints["gcode_file"] || hints[:gcode_file]
      match = String(gcode_file).tr("\\", "/").match(%r{(?:\A|/)plate_(\d+)\.gcode\z}i)
      match && Integer(match[1])
    rescue ArgumentError, TypeError
      nil
    end

    def unique_entry(entries, name)
      matches = entries.select { |entry| entry.name.casecmp?(name) }
      return matches.first if matches.length == 1
      return nil if matches.empty?

      :ambiguous
    end

    def read_preview(entry, archive, cancelled)
      return if entry.encrypted? || entry.size > @max_bytes

      stream = archive.open_entry_stream(entry)
      data = String.new(capacity: entry.size, encoding: Encoding::BINARY)
      while (chunk = stream.read(READ_CHUNK_BYTES))
        break if chunk.empty?

        check_cancelled!(cancelled)
        data << chunk
        return if data.bytesize > @max_bytes
      end
      return unless data.bytesize == entry.size

      dimensions = png_dimensions(data)
      return unless dimensions

      PreviewImage.new(
        data: data.freeze, width: dimensions[0], height: dimensions[1],
        media_type: "image/png"
      )
    rescue Zip::Error
      nil
    ensure
      stream&.close
    end

    def png_dimensions(data)
      return unless data.start_with?(PNG_SIGNATURE)

      offset = PNG_SIGNATURE.bytesize
      dimensions = nil
      seen_data = false
      loop do
        return if offset + 12 > data.bytesize

        length = data.byteslice(offset, 4).unpack1("N")
        type = data.byteslice(offset + 4, 4)
        chunk_end = offset + 12 + length
        return if chunk_end > data.bytesize

        body = data.byteslice(offset + 8, length)
        expected_crc = data.byteslice(offset + 8 + length, 4).unpack1("N")
        return unless Zlib.crc32(type + body) == expected_crc

        if dimensions.nil?
          return unless type == "IHDR" && length == 13

          width, height = body.unpack("N2")
          return unless width.positive? && height.positive?
          return if width * height > @max_pixels

          dimensions = [width, height]
        elsif type == "IDAT"
          seen_data = true
        elsif type == "IEND"
          return unless length.zero? && seen_data && chunk_end == data.bytesize

          return dimensions
        end
        offset = chunk_end
      end
    end

    def check_archive_size!(size)
      return if Integer(size) <= @max_archive_bytes

      raise PreviewError.new("too_large", "3MF archive exceeds #{@max_archive_bytes} bytes"), cause: nil
    end

    def check_archive_entries!(count)
      return if Integer(count) <= @max_archive_entries

      raise PreviewError.new("too_large", "3MF archive contains too many entries"), cause: nil
    end

    def check_cancelled!(cancelled)
      return unless cancelled.call

      raise PreviewError.new("cancelled", "Preview extraction cancelled"), cause: nil
    end
  end
end
