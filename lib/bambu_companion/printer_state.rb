# frozen_string_literal: true

require "time"

module BambuCompanion
  class PrinterState
    MAX_STRING_BYTES = 4096
    MAX_ALERTS = 64
    Update = Data.define(:snapshot, :load_model)

    HMS_MODULES = {
      0x03 => ["motion controller", "Motion controller"],
      0x05 => ["mainboard", "Mainboard"],
      0x07 => ["AMS", "AMS"],
      0x08 => ["toolhead", "Toolhead"],
      0x0C => ["vision system", "Vision system"]
    }.freeze
    HMS_SEVERITIES = {
      1 => ["fatal", "error"],
      2 => ["serious", "error"],
      3 => ["common", "warning"],
      4 => ["information", "warning"]
    }.freeze

    FIELD_MAP = {
      "nozzle_temper" => [:nozzle_temp, :float],
      "nozzle_target_temper" => [:nozzle_target_temp, :float],
      "bed_temper" => [:bed_temp, :float],
      "bed_target_temper" => [:bed_target_temp, :float],
      "mc_percent" => [:percent, :percent],
      "mc_remaining_time" => [:remaining_minutes, :integer],
      "spd_lvl" => [:speed_level, :integer],
      "spd_mag" => [:speed_magnitude, :integer],
      "wifi_signal" => [:wifi_signal, :string],
      "cooling_fan_speed" => [:cooling_fan_speed, :float],
      "heatbreak_fan_speed" => [:heatbreak_fan_speed, :float],
      "gcode_state" => [:gcode_state, :string],
      "subtask_name" => [:subtask_name, :string],
      "gcode_file" => [:gcode_file, :string],
      "file" => [:file, :string],
      "url" => [:url, :string],
      "plate_idx" => [:plate_idx, :integer],
      "layer_num" => [:layer, :integer],
      "total_layer_num" => [:total_layers, :integer],
      "task_id" => [:task_id, :string],
      "subtask_id" => [:subtask_id, :string]
    }.freeze
    STABLE_ID_FIELDS = %w[task_id subtask_id].freeze
    WEAK_IDENTITY_FIELDS = %w[file url gcode_file subtask_name plate_idx].freeze

    CAMERA_ABSENT = {
      present: false, transport: "none", liveview_enabled: false
    }.freeze
    RTSP_SERIES = /X1|X2|H2|P2|N6/i

    def initialize(clock: -> { Time.now.utc })
      @clock = clock
      @values = {
        connected: false, stale: true, last_update: nil,
        camera: CAMERA_ABSENT.dup
      }
      @hms_alerts = [].freeze
      @print_error_seen = false
      @print_error_code = 0
      @mc_print_error_code = 0
      @fail_reason = nil
      @running_job_identified = false
    end

    def connected!
      @values[:connected] = true
      @values[:stale] = false
    end

    def disconnected!
      @values[:connected] = false
      @values[:stale] = true
    end

    def update(report)
      print_state = report.is_a?(Hash) && report["print"].is_a?(Hash) ? report["print"] : {}
      was_running = running?
      identity_changed = identity_changed?(print_state)
      FIELD_MAP.each do |source, (target, kind)|
        next unless print_state.key?(source)

        converted = convert(print_state[source], kind)
        @values[target] = converted unless converted.nil?
      end
      update_alerts(print_state)
      update_extruders(print_state)
      update_printer_identity(report)
      update_camera(print_state)
      @values[:last_update] = @clock.call.utc.iso8601
      @values[:stale] = false if @values[:connected]

      identified = job_identified?
      should_load = false
      if running?
        should_load = !was_running || identity_changed || (!@running_job_identified && identified)
        @running_job_identified ||= identified
      else
        @running_job_identified = false
      end

      Update.new(snapshot: snapshot, load_model: should_load)
    end

    def snapshot
      deep_snapshot(@values)
    end

    private

    def running? = @values[:gcode_state].to_s.upcase == "RUNNING"

    def identity_changed?(print_state)
      fields = stable_identity?(print_state) ? STABLE_ID_FIELDS : WEAK_IDENTITY_FIELDS
      fields.any? do |source|
        next false unless print_state.key?(source)

        target, kind = FIELD_MAP.fetch(source)
        converted = convert(print_state[source], kind)
        !converted.nil? && @values.key?(target) && converted != @values[target]
      end
    end

    def stable_identity?(print_state)
      STABLE_ID_FIELDS.any? do |source|
        target, kind = FIELD_MAP.fetch(source)
        current = @values[target]
        incoming = convert(print_state[source], kind) if print_state.key?(source)
        [current, incoming].any? { |value| !value.nil? && !value.empty? }
      end
    end

    def job_identified?
      ids = [@values[:task_id], @values[:subtask_id]].compact.reject(&:empty?)
      return true unless ids.empty?

      hints = %i[file url gcode_file subtask_name plate_idx].map { |key| @values[key] }.compact
      !hints.empty?
    end

    def update_alerts(print_state)
      previous_error_code = effective_print_error_code
      if print_state.key?("hms")
        @hms_alerts = normalize_hms_alerts(print_state["hms"]).freeze
      end
      if print_state.key?("print_error")
        @print_error_seen = true
        @print_error_code = unsigned_integer(print_state["print_error"]) || 0
      end
      if print_state.key?("mc_print_error_code")
        @mc_print_error_code = unsigned_integer(print_state["mc_print_error_code"]) || 0
      end
      error_code = effective_print_error_code
      @fail_reason = nil if error_code.zero? || error_code != previous_error_code
      @fail_reason = clean_reason(print_state["fail_reason"]) if print_state.key?("fail_reason")

      alerts = @hms_alerts.dup
      alerts << print_error_alert(error_code) unless error_code.zero?
      @values[:alerts] = alerts.freeze
    end

    def effective_print_error_code
      @print_error_seen ? @print_error_code : @mc_print_error_code
    end

    def normalize_hms_alerts(value)
      return [] unless value.is_a?(Array)

      value.first(MAX_ALERTS).filter_map do |entry|
        next unless entry.is_a?(Hash)

        attr = unsigned_integer(entry["attr"] || entry[:attr])
        code = unsigned_integer(entry["code"] || entry[:code])
        next if attr.nil? || code.nil? || attr.zero? || code.zero?

        hms_alert(attr, code, entry)
      end.uniq { |alert| alert[:id] }
    end

    def hms_alert(attr, code, entry)
      severity_level = (code >> 16) & 0xFFFF
      severity, kind = HMS_SEVERITIES.fetch(severity_level, ["notice", "warning"])
      module_id = (attr >> 24) & 0xFF
      module_key, module_title = HMS_MODULES.fetch(
        module_id, [format("module 0x%02X", module_id), "Printer"]
      )
      formatted_code = format(
        "HMS_%04X_%04X_%04X_%04X",
        (attr >> 16) & 0xFFFF, attr & 0xFFFF,
        (code >> 16) & 0xFFFF, code & 0xFFFF
      )
      supplied_text = alert_text(entry)
      title_suffix = kind == "error" ? "error" : "notice"

      deep_snapshot({
        id: "hms:#{formatted_code}", source: "hms", kind: kind,
        severity: severity, severity_level: severity_level,
        module: module_key, title: "#{module_title} #{title_suffix}",
        description: supplied_text || hms_explanation(kind, severity, module_key),
        code: formatted_code, raw_attr: attr, raw_code: code
      })
    end

    def print_error_alert(code)
      formatted_code = format("0x%08X", code)
      description = @fail_reason ||
                    "The printer reported a print-process failure. " \
                    "Use the code below for code-specific troubleshooting."
      deep_snapshot({
        id: "print:#{formatted_code}", source: "print_error", kind: "error",
        severity: "print failure", severity_level: 0, module: "print process",
        title: "Print process error", description: description,
        code: formatted_code, raw_attr: nil, raw_code: code
      })
    end

    def hms_explanation(kind, severity, module_name)
      if kind == "error"
        "The printer reported a #{severity} #{module_name} condition. " \
          "The print may need attention before it can continue safely."
      else
        "The printer reported a #{module_name} maintenance or informational notice. " \
          "Review it when convenient; it is not treated as a print error."
      end
    end

    def alert_text(entry)
      %w[message intro description text].each do |key|
        value = entry[key] || entry[key.to_sym]
        text = clean_string(value)
        return text unless text.nil? || text.empty?
      end
      nil
    end

    def clean_reason(value)
      text = clean_string(value)
      return if text.nil? || text.empty? || text == "0" || text.casecmp("none").zero?

      text
    end

    def clean_string(value)
      text = String(value).strip
      text if text.bytesize <= MAX_STRING_BYTES
    rescue TypeError
      nil
    end

    def update_extruders(print_state)
      device = print_state["device"]
      return unless device.is_a?(Hash)

      extruder = device["extruder"]
      nozzle_state = device["nozzle"]
      return unless extruder.is_a?(Hash) || nozzle_state.is_a?(Hash)

      nozzles = Array(@values[:nozzles]).map(&:dup)
      if extruder.is_a?(Hash) && extruder["info"].is_a?(Array)
        decoded = extruder["info"].filter_map { |entry| decode_extruder(entry) }
        nozzles = merge_nozzle_updates(nozzles, decoded)
      end
      nozzles = merge_nozzle_metadata(nozzles, nozzle_state)

      active = decode_active_extruder(extruder["state"]) if extruder.is_a?(Hash)
      active ||= @values[:active_nozzle]
      @values[:active_nozzle] = active unless active.nil?
      nozzles.each { |nozzle| nozzle[:active] = nozzle[:id] == active }

      selected = nozzles.find { |nozzle| nozzle[:id] == active }
      if selected
        merge_active_nozzle_temperature(selected, print_state)
      end

      @values[:nozzles] = nozzles.sort_by { |nozzle| nozzle[:id] }.map(&:freeze).freeze
    end

    def merge_active_nozzle_temperature(selected, print_state)
      fresh_temp = converted_report_value(print_state, "nozzle_temper", :float)
      fresh_target = converted_report_value(print_state, "nozzle_target_temper", :float)

      if fresh_temp
        selected[:temp] = fresh_temp
      elsif selected.key?(:temp)
        @values[:nozzle_temp] = selected[:temp]
      end

      if fresh_target
        selected[:target_temp] = fresh_target
      elsif selected.key?(:target_temp)
        @values[:nozzle_target_temp] = selected[:target_temp]
      end
    end

    def converted_report_value(print_state, key, kind)
      return unless print_state.key?(key)

      convert(print_state[key], kind)
    end

    def merge_nozzle_updates(nozzles, updates)
      by_id = nozzles.to_h { |nozzle| [nozzle[:id], nozzle] }
      updates.each do |update|
        by_id[update[:id]] = by_id.fetch(update[:id], {}).merge(update)
      end
      by_id.values
    end

    def decode_extruder(entry)
      return unless entry.is_a?(Hash)

      id = Integer(entry["id"])
      return unless (0..15).cover?(id)

      temperatures = decode_extruder_temperature(entry["temp"])
      return unless temperatures

      { id: id, temp: temperatures[0], target_temp: temperatures[1] }
    rescue ArgumentError, TypeError
      nil
    end

    def decode_extruder_temperature(value)
      number = Float(value)
      return unless number.finite? && number >= 0 && number <= 0xFFFF_FFFF

      if number <= 0xFFFF && number != number.to_i
        return [number, 0.0]
      end

      packed = Integer(number)
      [(packed & 0xFFFF).to_f, ((packed >> 16) & 0xFFFF).to_f]
    rescue ArgumentError, TypeError, FloatDomainError
      nil
    end

    def decode_active_extruder(value)
      state = Integer(value)
      count = state & 0x0F
      active = (state >> 4) & 0x0F
      active if count.positive? && active < count
    rescue ArgumentError, TypeError
      nil
    end

    def merge_nozzle_metadata(nozzles, nozzle_state)
      return nozzles unless nozzle_state.is_a?(Hash) && nozzle_state["info"].is_a?(Array)

      metadata = nozzle_state["info"].each_with_object({}) do |entry, result|
        next unless entry.is_a?(Hash)

        id = Integer(entry["id"])
        next unless (0..15).cover?(id)

        result[id] = {
          diameter: convert(entry["diameter"], :float),
          type: clean_string(entry["type"])
        }.compact
      rescue ArgumentError, TypeError
        next
      end
      by_id = nozzles.to_h { |nozzle| [nozzle[:id], nozzle] }
      metadata.each do |id, attributes|
        by_id[id] = by_id.fetch(id, { id: id }).merge(attributes)
      end
      by_id.values
    end

    def unsigned_integer(value)
      Integer(value) & 0xFFFF_FFFF
    rescue ArgumentError, TypeError
      nil
    end

    def update_camera(print_state)
      ipcam = print_state["ipcam"]
      current = @values[:camera] || CAMERA_ABSENT
      present = current[:present]
      rtsp_url = current[:rtsp_url]
      liveview_preview = current[:liveview_preview]

      if ipcam.is_a?(Hash)
        if ipcam.key?("ipcam_dev")
          present = ipcam_present?(ipcam["ipcam_dev"])
        end
        if ipcam.key?("rtsp_url")
          rtsp_url = clean_string(ipcam["rtsp_url"])
        end
        if ipcam.key?("liveview_preview")
          liveview_preview = boolean_value(ipcam["liveview_preview"])
        end
      end

      @values[:camera] = camera_from(
        present: present, rtsp_url: rtsp_url,
        product_name: @values[:product_name], liveview_preview: liveview_preview
      )
    end

    def camera_from(present:, rtsp_url:, product_name:, liveview_preview: nil)
      unless present
        return { present: false, transport: "none", liveview_enabled: false,
                 rtsp_url: rtsp_url, liveview_preview: liveview_preview }.freeze
      end

      url = rtsp_url.to_s
      if liveview_preview == false && product_name.to_s.match?(RTSP_SERIES)
        return {
          present: true, transport: "rtsps", liveview_enabled: false,
          rtsp_url: rtsp_url, liveview_preview: liveview_preview
        }.freeze
      end
      if url.match?(%r{\Artsps?://}i)
        return {
          present: true, transport: "rtsps", liveview_enabled: true,
          rtsp_url: rtsp_url, liveview_preview: liveview_preview
        }.freeze
      end
      if url.casecmp("disable").zero?
        enabled = liveview_preview == true && product_name.to_s.match?(RTSP_SERIES)
        return {
          present: true, transport: "rtsps", liveview_enabled: enabled,
          rtsp_url: rtsp_url, liveview_preview: liveview_preview
        }.freeze
      end

      transport = product_name.to_s.match?(RTSP_SERIES) ? "rtsps" : "jpeg_tcp"
      {
        present: true, transport: transport, liveview_enabled: true,
        rtsp_url: rtsp_url, liveview_preview: liveview_preview
      }.freeze
    end

    def boolean_value(value)
      return value if value == true || value == false
      return true if value.to_s.strip.match?(/\A(?:1|true|enable)\z/i)
      return false if value.to_s.strip.match?(/\A(?:0|false|disable)\z/i)

      nil
    end

    def ipcam_present?(value)
      value.to_s.strip == "1"
    end

    def update_printer_identity(report)
      info = report.is_a?(Hash) ? report["info"] : nil
      modules = info.is_a?(Hash) ? info["module"] : nil
      return unless modules.is_a?(Array)

      candidate = modules.find do |entry|
        entry.is_a?(Hash) && entry["name"].to_s.casecmp("ota").zero?
      end
      candidate ||= modules.find { |entry| entry.is_a?(Hash) && entry["product_name"] }
      return unless candidate

      product_name = clean_string(candidate["product_name"])
      firmware_version = clean_string(candidate["sw_ver"])
      @values[:product_name] = product_name unless product_name.nil? || product_name.empty?
      @values[:firmware_version] = firmware_version unless firmware_version.nil? || firmware_version.empty?
    end

    def deep_snapshot(value)
      case value
      when Hash
        return value if value.frozen?

        value.each_with_object({}) do |(key, child), copy|
          copy[key] = deep_snapshot(child)
        end.freeze
      when Array
        return value if value.frozen?

        value.map { |child| deep_snapshot(child) }.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end

    def convert(value, kind)
      case kind
      when :float
        number = Float(value)
        number if number.finite?
      when :integer then Integer(value)
      when :percent then [[Integer(value), 0].max, 100].min
      when :string
        text = String(value).strip
        text if text.bytesize <= MAX_STRING_BYTES
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
