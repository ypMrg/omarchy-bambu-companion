# frozen_string_literal: true

require_relative "ftps_error"
require_relative "print_file_hints"

module BambuCompanion
  class PrintArchiveClient
    def initialize(external:, internal:)
      @external = external
      @internal = internal
    end

    def download(hints:, destination:, cancelled: -> { false }, progress: ->(*) {})
      @external.download(
        hints: hints, destination: destination,
        cancelled: cancelled, progress: progress
      )
    rescue FtpsError => error
      raise unless internal_fallback?(error, hints)

      @internal.download(
        hints: hints, destination: destination,
        cancelled: cancelled, progress: progress
      )
    end

    private

    def internal_fallback?(error, hints)
      %w[file_not_found transport].include?(error.code) &&
        PrintFileHints.internal_gcode_entry(hints)
    end
  end
end
