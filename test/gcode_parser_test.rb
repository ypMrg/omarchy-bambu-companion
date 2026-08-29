# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "bambu_companion/gcode_parser"
require "bambu_companion/ipc"
require "bambu_companion/model_worker"

class GcodeParserTest < Minitest::Test
  class LineOnlyIo
    def initialize(lines)
      @lines = lines
    end

    def each_line = @lines.each
    def read(*) = raise("parser attempted a whole-file read")
  end

  def test_parses_three_outer_wall_dialects_and_coordinate_modes
    parser = BambuCompanion::GcodeParser.new(max_segments: 100)
    path = File.join(__dir__, "fixtures", "outer-walls.gcode")
    geometry = File.open(path, "rb") { |io| parser.parse(io) }

    refute_respond_to geometry, :source_segment_count
    assert_equal 6, geometry.segments.length
    assert_equal [0.2, 0.4, 0.6], geometry.layer_z
    assert_equal 0.0, geometry.bounds.fetch(:min_x)
    assert_equal 10.0, geometry.bounds.fetch(:max_x)
    assert_equal 0.2, geometry.bounds.fetch(:min_z)
    assert_equal 0.6, geometry.bounds.fetch(:max_z)
    assert_equal 0.6, geometry.segments.fetch(4).fetch(5)
  end

  def test_ignores_travel_retraction_and_non_outer_moves
    gcode = <<~GCODE
      G90
      M82
      ; FEATURE: Outer wall
      G1 X0 Y0 Z0.2
      G1 X1 Y0
      G1 X2 Y0 E1
      G1 X3 Y0 E0.5
      ; FEATURE: Inner wall
      G1 X4 Y0 E2
    GCODE
    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))
    assert_equal 1, geometry.segments.length
    assert_equal [1.0, 0.0, 0.2, 2.0, 0.0, 0.2], geometry.segments.fetch(0)
  end

  def test_x2d_absolute_extrusion_is_independent_for_each_tool
    gcode = <<~GCODE
      G90
      M82
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      T0
      G1 X1 Y0 E5
      T1
      G1 X2 Y0 E1
      T0
      G1 X3 Y0 E6
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal 3, geometry.segments.length
    assert_equal [1.0, 2.0, 3.0], (geometry.segments.map { |segment| segment.fetch(3) })
  end

  def test_x2d_h_parameter_selects_hotend_when_t_is_a_filament_id
    gcode = <<~GCODE
      G90
      M82
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      T7 H1
      G1 X1 Y0 E3
      T0 H0
      G1 X2 Y0 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal 2, geometry.segments.length
  end

  def test_x2d_tool_sentinels_do_not_replace_the_active_extruder
    gcode = <<~GCODE
      G90
      M82
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      T1
      G1 X1 Y0 E4
      T65535
      G1 X2 Y0 E5
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal 2, geometry.segments.length
  end

  def test_decimation_is_deterministic_and_strictly_bounded
    lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0.2"]
    100.times { |index| lines << "G1 X#{index + 1} Y0 E1" }
    source = lines.join("\n")
    parser = BambuCompanion::GcodeParser.new(max_segments: 10)

    first = parser.parse(StringIO.new(source))
    second = parser.parse(StringIO.new(source))
    assert_operator first.segments.length, :<=, 10
    assert_equal first.segments, second.segments
  end

  def test_decimation_merges_connected_moves_instead_of_punching_gaps
    lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0.2"]
    100.times { |index| lines << "G1 X#{index + 1} Y0 E1" }

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(
      StringIO.new(lines.join("\n"))
    )

    assert_operator geometry.segments.length, :<=, 10
    assert_equal [0.0, 0.0, 0.2], geometry.segments.first.values_at(0, 1, 2)
    assert_equal [100.0, 0.0, 0.2], geometry.segments.last.values_at(3, 4, 5)
    geometry.segments.each_cons(2) do |left, right|
      assert_equal left.values_at(3, 4, 5), right.values_at(0, 1, 2)
    end
  end

  def test_x2d_combined_route_decimation_reaches_the_final_toolpath_endpoint
    lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0.2"]
    20.times do |index|
      lines << "T#{index % 2}"
      lines << "G1 X#{index + 1} Y0 E1"
    end

    geometry = BambuCompanion::GcodeParser.new(max_segments: 2).parse(
      StringIO.new(lines.join("\n"))
    )

    assert_operator geometry.segments.length, :<=, 2
    assert_equal 20.0, geometry.segments.last.fetch(3)
  end

  def test_rejects_files_without_known_outer_wall_markers
    error = assert_raises(BambuCompanion::GcodeError) do
      BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new("G1 X1 Y1 E1\n"))
    end
    assert_equal "no_outer_walls", error.code
  end

  def test_defaults_to_five_hundred_thousand_segments
    assert_equal 500_000, BambuCompanion::GcodeParser::DEFAULT_MAX_SEGMENTS

    lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0.2"]
    30_001.times { |index| lines << "G1 X#{index + 1} Y0 E1" }

    geometry = BambuCompanion::GcodeParser.new.parse(StringIO.new(lines.join("\n")))

    assert_equal 30_001, geometry.segments.length
  end

  def test_ignores_commands_with_non_finite_values
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      G1 X1e999 Y0 E1
      G1 X1 Y0 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal 1, geometry.segments.length
    assert geometry.segments.flatten.all?(&:finite?)
    assert geometry.bounds.values.all?(&:finite?)
  end

  def test_accepts_zero_padded_g1_commands
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      G01 X1 Y0 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal [[0.0, 0.0, 0.2, 1.0, 0.0, 0.2]], geometry.segments
  end

  def test_tessellates_bambu_ij_arcs_without_straightening_the_curve
    gcode = <<~GCODE
      G90
      M83
      ; FEATURE: Outer wall
      G1 X171.689 Y152.234 Z0.2
      G3 X166.611 Y155.115 I-7.077 J-6.557 E0.22091
      G2 X171.689 Y152.234 I-1.999 J-9.438 E0.22091
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 100).parse(StringIO.new(gcode))

    assert_operator geometry.segments.length, :>, 2
    assert_equal [171.689, 152.234], geometry.segments.first.values_at(0, 1)
    assert_in_delta 171.689, geometry.segments.last.fetch(3), 1e-9
    assert_in_delta 152.234, geometry.segments.last.fetch(4), 1e-9
    geometry.segments.each do |segment|
      chord = Math.hypot(segment.fetch(3) - segment.fetch(0),
                         segment.fetch(4) - segment.fetch(1))
      assert_operator chord, :<=, 0.8
    end
  end

  def test_an_arc_always_updates_position_before_the_next_linear_move
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      G2 X10 Y0 I5 J0
      G1 X11 Y0 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal [[10.0, 0.0, 0.2, 11.0, 0.0, 0.2]], geometry.segments
  end

  def test_tessellates_radius_arcs_and_keeps_the_segment_budget
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      G3 X10 Y0 R5 E1
      G2 X0 Y0 R5 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 100).parse(StringIO.new(gcode))
    bounded = BambuCompanion::GcodeParser.new(max_segments: 8).parse(StringIO.new(gcode))

    assert_operator bounded.segments.length, :<=, 8
    assert_in_delta 0.0, geometry.segments.last.fetch(3), 1e-9
    assert_in_delta 0.0, geometry.segments.last.fetch(4), 1e-9
    assert bounded.segments.flatten.all?(&:finite?)
  end

  def test_ignores_moves_whose_coordinate_math_overflows
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      G91
      G1 X1e308 Y0 E1
      G1 X1e308 Y0 E1
      G1 X-1e308 Y0 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal 2, geometry.segments.length
    assert geometry.segments.flatten.all?(&:finite?)
    assert geometry.bounds.values.all?(&:finite?)
  end

  def test_raises_stable_cancelled_error
    error = assert_raises(BambuCompanion::GcodeError) do
      BambuCompanion::GcodeParser.new.parse(
        StringIO.new("G1 X1 Y1 E1\n"), cancelled: -> { true }
      )
    end

    assert_equal "cancelled", error.code
  end

  def test_checks_cancellation_during_long_parses
    checks = 0
    cancelled = lambda do
      checks += 1
      checks == 2
    end
    lines = Array.new(300, "G1 X1 Y1 E1\n")

    error = assert_raises(BambuCompanion::GcodeError) do
      BambuCompanion::GcodeParser.new.parse(LineOnlyIo.new(lines), cancelled: cancelled)
    end

    assert_equal "cancelled", error.code
    assert_equal 2, checks
  end

  def test_rejects_oversized_lines_even_without_gcode_source_wrapper
    line = "X" * (BambuCompanion::GcodeParser::MAX_LINE_BYTES + 1)

    error = assert_raises(BambuCompanion::GcodeError) do
      BambuCompanion::GcodeParser.new.parse(StringIO.new(line))
    end

    assert_equal "too_large", error.code
  end

  def test_ignores_oversized_numeric_tokens
    huge_number = "1" * (BambuCompanion::GcodeParser::MAX_NUMBER_DIGITS + 1)
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      G1 X#{huge_number} Y0 E1
      G1 X1 Y0 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal [[0.0, 0.0, 0.2, 1.0, 0.0, 0.2]], geometry.segments
  end

  def test_ignores_lines_with_an_excessive_parameter_count
    parameters = Array.new(BambuCompanion::GcodeParser::MAX_PARAMETERS_PER_LINE + 1, "X1").join(" ")
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      G1 #{parameters} E1
      G1 X2 Y0 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal [[0.0, 0.0, 0.2, 2.0, 0.0, 0.2]], geometry.segments
  end

  def test_consumes_line_oriented_io_without_reading_the_whole_source
    io = LineOnlyIo.new([
      ";TYPE:WALL-OUTER\n",
      "G1 X0 Y0 Z0.2\n",
      "G1 X1 Y0 E1\n"
    ])

    geometry = BambuCompanion::GcodeParser.new.parse(io)

    assert_equal 1, geometry.segments.length
  end

  def test_ignores_g0_even_when_it_extrudes
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.2
      G0 X1 Y0 E1
      G1 X2 Y0 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal [[1.0, 0.0, 0.2, 2.0, 0.0, 0.2]], geometry.segments
  end

  def test_preserves_all_layer_values_when_segments_are_decimated
    lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0"]
    100.times { |index| lines << "G1 X#{index + 1} Y0 Z#{index + 1} E1" }

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(lines.join("\n")))

    assert_operator geometry.segments.length, :<=, 10
    assert_equal (0..100).map(&:to_f), geometry.layer_z
  end

  def test_single_segment_limit_remains_bounded_for_large_sources
    lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0.2"]
    10_000.times { |index| lines << "G1 X#{index + 1} Y0 E1" }

    parser = BambuCompanion::GcodeParser.new(max_segments: 1)
    geometry = parser.parse(StringIO.new(lines.join("\n")))

    assert_equal 1, geometry.segments.length
    assert_operator parser.instance_variable_get(:@sample_stride), :<=, 16_384
  end

  def test_preserves_gcode_z_precision_without_fixed_quantization
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.200001
      G1 X1 Y0 Z0.200002 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal [0.200001, 0.200002], geometry.layer_z
    assert_equal 0.200001, geometry.bounds.fetch(:min_z)
    assert_equal 0.200002, geometry.bounds.fetch(:max_z)
    assert_equal [0.0, 0.0, 0.200001, 1.0, 0.0, 0.200002], geometry.segments.fetch(0)
  end

  def test_layer_values_remain_unique_after_float_conversion
    gcode = <<~GCODE
      G90
      M83
      ;TYPE:WALL-OUTER
      G1 X0 Y0 Z0.20000000000000000
      G1 X1 Y0 Z0.20000000000000001 E1
    GCODE

    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(StringIO.new(gcode))

    assert_equal [0.2], geometry.layer_z
  end

  def test_layer_metadata_is_bounded_while_segments_remain_deterministic
    lines = ["G90", "M83", ";TYPE:WALL-OUTER", "G1 X0 Y0 Z0"]
    25_000.times { |index| lines << "G1 X#{index + 1} Y0 Z#{index + 1} E1" }
    source = lines.join("\n")
    parser = BambuCompanion::GcodeParser.new(max_segments: 8)

    geometry = parser.parse(StringIO.new(source))
    repeated = parser.parse(StringIO.new(source))

    assert_operator geometry.layer_z.length, :<=,
                    BambuCompanion::GcodeParser::DEFAULT_MAX_LAYER_VALUES
    assert_operator parser.instance_variable_get(:@layers).length, :<=,
                    BambuCompanion::GcodeParser::DEFAULT_MAX_LAYER_VALUES
    assert_equal geometry.layer_z, repeated.layer_z
    assert_equal geometry.segments, repeated.segments
    refute geometry.layer_z_exact
    assert_equal geometry.layer_z.sort, geometry.layer_z
    assert_equal 0.0, geometry.layer_z.first
    assert_equal 25_000.0, geometry.layer_z.last
    assert_operator geometry.segments.length, :<=, 8
    assert_equal [0.0, 0.0, 0.0], geometry.segments.first.values_at(0, 1, 2)
    assert_equal [25_000.0, 0.0, 25_000.0], geometry.segments.last.values_at(3, 4, 5)
    geometry.segments.each_cons(2) do |left, right|
      assert_equal left.values_at(3, 4, 5), right.values_at(0, 1, 2)
    end

    midpoint, mode = BambuCompanion::ZProgress.calculate(
      geometry, layer: geometry.layer_z.length / 2, percent: 50
    )
    assert_equal "estimated", mode
    assert_in_delta 12_500.0, midpoint, 2.0
  end

  def test_normal_layer_metadata_remains_exact
    geometry = BambuCompanion::GcodeParser.new(max_segments: 10).parse(
      StringIO.new(<<~GCODE)
        G90
        M83
        ;TYPE:WALL-OUTER
        G1 X0 Y0 Z0.2
        G1 X1 Y0 Z0.4 E1
      GCODE
    )

    assert geometry.layer_z_exact
    assert_equal [0.2, 0.4], geometry.layer_z
  end

  def test_maximum_layer_metadata_fits_the_qml_ipc_line_limit
    value = -Float::MAX
    layers = Array.new(BambuCompanion::GcodeParser::DEFAULT_MAX_LAYER_VALUES) do
      current = value
      value = value.next_float
      current
    end
    line = BambuCompanion::IpcEmitter.new(io: StringIO.new).line_for(
      "geometry_begin",
      generation: 1,
      segmentCount: BambuCompanion::GcodeParser::DEFAULT_MAX_SEGMENTS,
      bounds: {
        minX: -Float::MAX, maxX: Float::MAX,
        minY: -Float::MAX, maxY: Float::MAX,
        minZ: -Float::MAX, maxZ: Float::MAX
      },
      layerZ: layers
    )

    assert_equal layers.length, layers.uniq.length
    assert_operator line.length, :<, 1_048_576
  end
end
