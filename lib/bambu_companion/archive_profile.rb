# frozen_string_literal: true

require "cgi"
require "zip"
require_relative "archive_name"

module BambuCompanion
  # Prints started from a MakerWorld project report the profile title (for
  # example "V1.0 PLA") as subtask_name, while the archive on the SD card is
  # named after the design. The archive's own 3D/3dmodel.model metadata carries
  # both titles, so it is the authority for matching such a job to its file.
  module ArchiveProfile
    MODEL_ENTRY = "3D/3dmodel.model"
    TITLE_KEYS = %w[ProfileTitle Title].freeze
    # Title metadata sits in the model header, ahead of the mesh. A long
    # Description can precede it, so allow a generous but bounded prefix.
    MAX_HEADER_BYTES = 1024 * 1024
    module_function

    def matches?(path, subtask_name, plate_entry: nil)
      token = ArchiveName.canonical(subtask_name)
      return false if token.empty?

      Zip::File.open(path) do |archive|
        return false if plate_entry && !archive.find_entry(plate_entry)

        model = archive.find_entry(MODEL_ENTRY)
        return false unless model

        titles(read_header(model)).any? { |title| ArchiveName.canonical(title) == token }
      end
    rescue Zip::Error, IOError, SystemCallError
      false
    end

    def titles(header)
      TITLE_KEYS.filter_map do |key|
        match = header.match(/<metadata\s+name="#{key}"\s*>([^<]*)</)
        match && CGI.unescapeHTML(match[1]).strip
      end
    end

    def read_header(entry)
      entry.get_input_stream do |io|
        text = io.read(MAX_HEADER_BYTES).to_s
        text.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.scrub("")
      end
    end
  end
end
