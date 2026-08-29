# frozen_string_literal: true

require "bigdecimal"

module BambuCompanion
  class GcodeError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end

  Geometry = Data.define(:segments, :bounds, :layer_z, :layer_z_exact)

  class GcodeParser
    DEFAULT_MAX_SEGMENTS = 500_000
    DEFAULT_MAX_LAYER_VALUES = 20_000
    MAX_LINE_BYTES = 1 << 20
    MAX_PARAMETERS_PER_LINE = 32
    MAX_NUMBER_DIGITS = 32
    OUTER_MARKERS = [
      /\AFEATURE:\s*Outer wall\z/i,
      /\ATYPE:\s*External perimeter\z/i,
      /\ATYPE:\s*WALL-OUTER\z/i
    ].freeze
    FEATURE_MARKER = /\A(?:FEATURE|TYPE):/i
    NUMBER = /-?(?:\d{1,#{MAX_NUMBER_DIGITS}}(?:\.\d{0,#{MAX_NUMBER_DIGITS}})?|\.\d{1,#{MAX_NUMBER_DIGITS}})(?:[eE][+-]?\d{1,4})?/
    PARAMETER = /([XYZEIJRH])\s*(#{NUMBER})(?![\d.eE+-])/
    ZERO = BigDecimal("0")
    EPSILON = BigDecimal("1e-7")
    FLOAT_EPSILON = EPSILON.to_f
    ARC_MAX_CHORD_MM = 0.75
    ARC_MAX_ANGLE = Math::PI / 36
    ARC_MAX_SEGMENTS = 512
    ARC_RADIUS_TOLERANCE_MM = 0.05
    TWO_PI = 2 * Math::PI

    def initialize(max_segments: DEFAULT_MAX_SEGMENTS)
      @max_segments = Integer(max_segments)
      raise ArgumentError, "max_segments must be positive" unless @max_segments.positive?
    end

    def parse(io, cancelled: -> { false })
      reset
      io.each_line.with_index do |raw_line, index|
        if (index % 256).zero? && cancelled.call
          raise GcodeError.new("cancelled", "G-code parsing cancelled")
        end
        raw_line = raw_line.to_s
        if raw_line.bytesize > MAX_LINE_BYTES
          raise GcodeError.new("too_large", "G-code line exceeds #{MAX_LINE_BYTES} bytes")
        end

        parse_line(raw_line)
      end
      if @source_count.zero?
        raise GcodeError.new("no_outer_walls", "No supported outer-wall markers were found")
      end

      Geometry.new(
        segments: @segments.map { |segment| segment.map(&:to_f).freeze }.freeze,
        bounds: @bounds.transform_values(&:to_f).freeze,
        layer_z: layer_values.freeze,
        layer_z_exact: @layer_z_exact
      )
    end

    private

    def reset
      @absolute_position = true
      @absolute_extrusion = true
      @absolute_arc_center = false
      @plane = :xy
      @outer = false
      @active_tool = 0
      @tool_extrusion = { 0 => ZERO }
      @position = { "X" => ZERO, "Y" => ZERO, "Z" => ZERO, "E" => ZERO }
      @segments = []
      @source_count = 0
      @sample_stride = 1
      @last_source_segment = nil
      @layers = []
      @layer_sample_stride = 1
      @layer_source_count = 0
      @last_layer = nil
      @layer_z_exact = true
      @bounds = { min_x: nil, max_x: nil, min_y: nil, max_y: nil,
                  min_z: nil, max_z: nil }
    end

    def parse_line(raw_line)
      code, comment = raw_line.to_s.split(";", 2)
      update_feature(comment.to_s.strip) unless comment.nil?
      stripped = code.to_s.strip
      return if stripped.empty?

      command = stripped.split(/\s+/, 2).first.upcase
      parameters = parse_parameters(stripped)
      return unless parameters
      return unless parameters.values.all? { |value| finite_float?(value) }

      case command
      when "G90" then @absolute_position = true
      when "G91" then @absolute_position = false
      when "G90.1" then @absolute_arc_center = true
      when "G91.1" then @absolute_arc_center = false
      when "G17" then @plane = :xy
      when "G18" then @plane = :xz
      when "G19" then @plane = :yz
      when "M82" then @absolute_extrusion = true
      when "M83" then @absolute_extrusion = false
      when "G92"
        parameters.each { |axis, value| @position[axis] = value if @position.key?(axis) }
        @tool_extrusion[@active_tool] = @position["E"] if parameters.key?("E")
      when "G0", "G00", "G1", "G01", "G2", "G02", "G3", "G03"
        move(command, parameters)
      else
        select_tool(command, parameters)
      end
    end

    def select_tool(command, parameters)
      match = command.match(/\AT(\d{1,5})\z/)
      return unless match

      requested = parameters["H"] || BigDecimal(match[1])
      tool = Integer(requested)
      return unless (0..1).cover?(tool)
      return if tool == @active_tool

      @tool_extrusion[@active_tool] = @position["E"]
      @active_tool = tool
      @position["E"] = @tool_extrusion.fetch(tool, ZERO)
      @last_source_segment = nil
    rescue ArgumentError, TypeError
      nil
    end

    def parse_parameters(line)
      parameters = {}
      matches = 0
      valid = true
      line.scan(PARAMETER) do |axis, value|
        matches += 1
        if matches > MAX_PARAMETERS_PER_LINE
          valid = false
          break
        end

        parameters[axis] = BigDecimal(value)
      end
      parameters if valid
    end

    def update_feature(comment)
      return unless FEATURE_MARKER.match?(comment)

      @outer = OUTER_MARKERS.any? { |marker| marker.match?(comment) }
    end

    def move(command, parameters)
      before = @position.dup
      %w[X Y Z].each do |axis|
        next unless parameters.key?(axis)

        @position[axis] = @absolute_position ? parameters[axis] : @position[axis] + parameters[axis]
      end
      extrusion_delta = ZERO
      if parameters.key?("E")
        extrusion_delta = @absolute_extrusion ? parameters["E"] - @position["E"] : parameters["E"]
        @position["E"] = @absolute_extrusion ? parameters["E"] : @position["E"] + parameters["E"]
        @tool_extrusion[@active_tool] = @position["E"]
      end
      unless @position.values.all? { |value| finite_float?(value) } && finite_float?(extrusion_delta)
        @position = before
        return
      end

      moved_xy = (before["X"] - @position["X"]).abs > EPSILON ||
                 (before["Y"] - @position["Y"]).abs > EPSILON
      return unless @outer && extrusion_delta > EPSILON

      case command
      when "G1", "G01"
        return unless moved_xy

        record([before["X"], before["Y"], before["Z"],
                @position["X"], @position["Y"], @position["Z"]])
      when "G2", "G02", "G3", "G03"
        return unless @plane == :xy

        clockwise = command == "G2" || command == "G02"
        arc_segments(before, @position, parameters, clockwise: clockwise).each do |segment|
          record(segment)
        end
      end
    end

    def arc_segments(start_position, end_position, parameters, clockwise:)
      start_point = xyz_floats(start_position)
      end_point = xyz_floats(end_position)
      center = arc_center(start_point, end_point, parameters, clockwise: clockwise)
      return [] unless center

      radius = Math.hypot(start_point[0] - center[0], start_point[1] - center[1])
      return [] unless radius.finite? && radius > FLOAT_EPSILON

      start_angle = Math.atan2(start_point[1] - center[1], start_point[0] - center[0])
      sweep = arc_sweep(start_point, end_point, center, clockwise: clockwise)
      return [] unless sweep&.finite?

      tessellate_arc(start_point, end_point, center, radius, start_angle, sweep)
    rescue Math::DomainError, FloatDomainError
      []
    end

    def arc_center(start_point, end_point, parameters, clockwise:)
      if parameters.key?("I") || parameters.key?("J")
        ij_arc_center(start_point, end_point, parameters)
      elsif parameters.key?("R")
        radius_arc_center(start_point, end_point, parameters["R"].to_f,
                          clockwise: clockwise)
      end
    end

    def ij_arc_center(start_point, end_point, parameters)
      center = if @absolute_arc_center
                 [parameters.fetch("I", start_point[0]).to_f,
                  parameters.fetch("J", start_point[1]).to_f]
               else
                 [start_point[0] + parameters.fetch("I", ZERO).to_f,
                  start_point[1] + parameters.fetch("J", ZERO).to_f]
               end
      start_radius = Math.hypot(start_point[0] - center[0], start_point[1] - center[1])
      end_radius = Math.hypot(end_point[0] - center[0], end_point[1] - center[1])
      return unless center.all?(&:finite?) && start_radius.finite? && end_radius.finite?
      return if (start_radius - end_radius).abs > ARC_RADIUS_TOLERANCE_MM

      center
    end

    def radius_arc_center(start_point, end_point, signed_radius, clockwise:)
      return unless signed_radius.finite?

      dx = end_point[0] - start_point[0]
      dy = end_point[1] - start_point[1]
      chord = Math.hypot(dx, dy)
      radius = signed_radius.abs
      return if chord <= FLOAT_EPSILON || radius + ARC_RADIUS_TOLERANCE_MM < chord / 2

      midpoint = [start_point[0] + (dx / 2), start_point[1] + (dy / 2)]
      half_chord = chord / 2
      height = Math.sqrt([((radius - half_chord) * (radius + half_chord)), 0].max)
      return unless midpoint.all?(&:finite?) && height.finite?

      perpendicular = [-dy / chord, dx / chord]
      centers = [1, -1].map do |direction|
        [midpoint[0] + (direction * height * perpendicular[0]),
         midpoint[1] + (direction * height * perpendicular[1])]
      end.select { |center| center.all?(&:finite?) }
      major = signed_radius.negative?
      centers.find do |center|
        sweep = arc_sweep(start_point, end_point, center, clockwise: clockwise)
        major ? sweep.abs >= Math::PI : sweep.abs <= Math::PI
      end
    end

    def arc_sweep(start_point, end_point, center, clockwise:)
      if Math.hypot(end_point[0] - start_point[0], end_point[1] - start_point[1]) <= FLOAT_EPSILON
        return clockwise ? -TWO_PI : TWO_PI
      end

      start_angle = Math.atan2(start_point[1] - center[1], start_point[0] - center[0])
      end_angle = Math.atan2(end_point[1] - center[1], end_point[0] - center[0])
      sweep = end_angle - start_angle
      sweep -= TWO_PI while clockwise && sweep >= 0
      sweep += TWO_PI while !clockwise && sweep <= 0
      sweep
    end

    def tessellate_arc(start_point, end_point, center, radius, start_angle, sweep)
      arc_length = radius * sweep.abs
      segment_count = [
        (sweep.abs / ARC_MAX_ANGLE).ceil,
        (arc_length / ARC_MAX_CHORD_MM).ceil,
        1
      ].max.clamp(1, ARC_MAX_SEGMENTS)
      previous = start_point
      Array.new(segment_count) do |index|
        ratio = (index + 1).fdiv(segment_count)
        point = if index + 1 == segment_count
                  end_point
                else
                  angle = start_angle + (sweep * ratio)
                  [center[0] + (radius * Math.cos(angle)),
                   center[1] + (radius * Math.sin(angle)),
                   start_point[2] + ((end_point[2] - start_point[2]) * ratio)]
                end
        return [] unless point.all?(&:finite?)

        segment = [*previous, *point]
        previous = point
        segment
      end
    end

    def xyz_floats(position)
      %w[X Y Z].map { |axis| position.fetch(axis).to_f }
    end

    def record(segment)
      @source_count += 1
      update_bounds(segment)
      record_layer(segment[2])
      record_layer(segment[5])
      source_index = @source_count - 1
      if @segments.length >= @max_segments
        reduced = compact_connected_segments
        unless reduced
          if connected_segments?(@last_source_segment, segment) &&
             connected_segments?(@segments.last, segment)
            @segments[-1] = merge_segments(@segments.last, segment)
          end
          @last_source_segment = segment
          return
        end
      end

      continues_path = connected_segments?(@last_source_segment, segment)
      if (source_index % @sample_stride).zero? || !continues_path
        @segments << segment
      elsif connected_segments?(@segments.last, segment)
        @segments[-1] = merge_segments(@segments.last, segment)
      end
      @last_source_segment = segment
    end

    def compact_connected_segments
      compacted = []
      index = 0
      while index < @segments.length
        first = @segments[index]
        second = @segments[index + 1]
        if second && connected_segments?(first, second)
          compacted << merge_segments(first, second)
          index += 2
        else
          compacted << first
          index += 1
        end
      end
      return false unless compacted.length < @segments.length

      @segments = compacted
      @sample_stride *= 2
      true
    end

    def connected_segments?(left, right)
      return false unless left && right

      3.times.all? do |axis|
        (Float(left[axis + 3]) - Float(right[axis])).abs <= FLOAT_EPSILON
      end
    rescue ArgumentError, TypeError
      false
    end

    def merge_segments(first, second)
      [first[0], first[1], first[2], second[3], second[4], second[5]]
    end

    def record_layer(value)
      return if value == @last_layer

      @last_layer = value
      source_index = @layer_source_count
      @layer_source_count += 1
      return unless (source_index % @layer_sample_stride).zero?

      if @layers.length >= DEFAULT_MAX_LAYER_VALUES
        @layer_z_exact = false
        @layers = @layers.each_with_index.filter_map { |layer, index| layer if index.even? }
        @layer_sample_stride *= 2
        return unless (source_index % @layer_sample_stride).zero?
      end
      @layers << value
    end

    def layer_values
      values = (@layers + [@bounds[:min_z], @bounds[:max_z]]).compact
                                                              .sort.map(&:to_f).uniq
      return values if values.length <= DEFAULT_MAX_LAYER_VALUES

      last_index = values.length - 1
      Array.new(DEFAULT_MAX_LAYER_VALUES) do |index|
        values[index * last_index / (DEFAULT_MAX_LAYER_VALUES - 1)]
      end
    end

    def update_bounds(segment)
      [[segment[0], segment[1], segment[2]], [segment[3], segment[4], segment[5]]].each do |x, y, z|
        @bounds[:min_x] = x if @bounds[:min_x].nil? || x < @bounds[:min_x]
        @bounds[:max_x] = x if @bounds[:max_x].nil? || x > @bounds[:max_x]
        @bounds[:min_y] = y if @bounds[:min_y].nil? || y < @bounds[:min_y]
        @bounds[:max_y] = y if @bounds[:max_y].nil? || y > @bounds[:max_y]
        @bounds[:min_z] = z if @bounds[:min_z].nil? || z < @bounds[:min_z]
        @bounds[:max_z] = z if @bounds[:max_z].nil? || z > @bounds[:max_z]
      end
    end

    def finite_float?(value) = value.finite? && value.to_f.finite?
  end
end
