# frozen_string_literal: true

module BambuCompanion
  module PrintFileHints
    INTERNAL_GCODE_ENTRY = %r{\A/?(?:data/)?Metadata/plate_([1-9]\d*)\.gcode\z}i
    module_function

    def internal_gcode_entry(hints)
      values = hints.to_h
      %w[gcode_file file].each do |key|
        value = values[key] || values[key.to_sym]
        entry = normalize_internal_gcode_entry(value)
        return entry if entry
      end
      nil
    end

    def internal_plate_number(hints)
      entry = internal_gcode_entry(hints)
      match = entry&.match(%r{\AMetadata/plate_([1-9]\d*)\.gcode\z}i)
      match && Integer(match[1])
    end

    def normalize_internal_gcode_entry(value)
      text = String(value).strip.tr("\\", "/").gsub(%r{/+}, "/")
      match = text.match(INTERNAL_GCODE_ENTRY)
      match && "Metadata/plate_#{Integer(match[1])}.gcode"
    rescue ArgumentError, TypeError
      nil
    end
  end
end
