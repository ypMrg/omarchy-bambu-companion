# frozen_string_literal: true

module BambuCompanion
  module ArchiveName
    module_function

    def canonical(value)
      text = File.basename(String(value)).dup
      text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY
      return "" unless text.valid_encoding?

      text.unicode_normalize(:nfkc).downcase
          .sub(/\.gcode\.3mf\z/, "").sub(/\.gcode\z/, "").sub(/\.3mf\z/, "")
          .gsub(/[^\p{Alnum}]+/u, "")
    rescue TypeError
      ""
    end
  end
end
