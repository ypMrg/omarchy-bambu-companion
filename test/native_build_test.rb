# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class NativeBuildTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BUILD = File.join(ROOT, "native/build")
  BUILD_SOURCES = %w[
    CMakeLists.txt RouteHost.qml gcode_route.cpp gcode_route.hpp
    gcode_route.frag gcode_route.vert projection.hpp segments.hpp
  ].freeze

  def test_build_script_exists_and_is_executable
    assert File.executable?(BUILD)
  end

  def test_missing_cmake_exits_nonzero_without_a_module
    Dir.mktmpdir do |bin|
      Dir.mktmpdir do |data|
        write_failing_command(bin, "cmake")
        env = default_env(data).merge("PATH" => "#{bin}:#{ENV.fetch("PATH")}")
        _out, _err, status = Open3.capture3(env, [BUILD, BUILD])
        refute_predicate status, :success?
        refute Dir.glob(File.join(data, "qml/native/lib*")).any?
      end
    end
  end

  def test_stamp_hit_skips_rebuild_and_keeps_existing_module
    Dir.mktmpdir do |bin|
      Dir.mktmpdir do |data|
        native = File.join(data, "qml/native")
        FileUtils.mkdir_p(native)
        File.write(File.join(native, "RouteHost.qml"), "GcodeRoute {}\n")
        File.write(File.join(native, ".stamp"),
                   stamp_for(File.join(ROOT, "native")))
        write_failing_command(bin, "cmake")
        env = default_env(data).merge("PATH" => "#{bin}:#{ENV.fetch("PATH")}")
        out, err, status = Open3.capture3(env, [BUILD, BUILD])
        assert_predicate status, :success?, "#{out} #{err}"
        assert_includes File.read(File.join(native, "RouteHost.qml")), "GcodeRoute"
      end
    end
  end

  def test_stamp_hashes_source_contents_not_paths
    script = File.read(BUILD)
    BUILD_SOURCES.each { |source| assert_includes script, source }
    refute_includes script, 'find "$source_root"'

    Dir.mktmpdir do |source|
      FileUtils.cp_r(File.join(ROOT, "native/."), source)
      before = stamp_for(source)
      File.write(File.join(source, "gcode_route.cpp"),
                 File.read(File.join(source, "gcode_route.cpp")) + "\n")
      after = stamp_for(source)
      refute_equal before, after

      Dir.mktmpdir do |bin|
        Dir.mktmpdir do |data|
          native = File.join(data, "qml/native")
          FileUtils.mkdir_p(native)
          File.write(File.join(native, "RouteHost.qml"), "GcodeRoute {}\n")
          File.write(File.join(native, ".stamp"), before)
          write_failing_command(bin, "cmake")
          env = {
            "BAMBU_NATIVE_DATA_ROOT" => data,
            "BAMBU_NATIVE_SOURCE_ROOT" => source,
            "PATH" => "#{bin}:#{ENV.fetch("PATH")}"
          }
          _out, _err, status = Open3.capture3(env, [BUILD, BUILD])
          refute_predicate status, :success?
        end
      end
    end
  end

  def test_install_is_atomic_when_fake_cmake_succeeds
    Dir.mktmpdir do |bin|
      Dir.mktmpdir do |data|
        write_fake_cmake(bin)
        env = default_env(data).merge("PATH" => "#{bin}:#{ENV.fetch("PATH")}")
        _out, err, status = Open3.capture3(env, [BUILD, BUILD])
        assert_predicate status, :success?, err
        assert File.file?(File.join(data, "qml/native/RouteHost.qml"))
        refute File.exist?(File.join(data, "qml/native.staging"))
        refute Dir.glob(File.join(data, "qml/native.new*")).any?
      end
    end
  end

  def test_cmakelists_declares_qml_module_and_shaders
    lists = File.join(ROOT, "native/CMakeLists.txt")
    assert File.file?(lists), "native/CMakeLists.txt is required for the GPU module"
    source = File.read(lists)
    assert_includes source, "qt_add_qml_module"
    assert_includes source, "Bambu.Toolpath"
    assert_includes source, "PLUGIN_TARGET bambutoolpathplugin"
    assert_includes source, "gcode_route.hpp"
    assert_includes source, "gcode_route.cpp"
    assert_includes source, "RouteHost.qml"
    assert_includes source, "qt_add_shaders"
    assert_includes source, "gcode_route.vert"
    assert_includes source, "gcode_route.frag"
    assert_includes source, "DESTINATION ."
    %w[gcode_route.hpp gcode_route.cpp gcode_route.vert gcode_route.frag RouteHost.qml].each do |name|
      assert File.file?(File.join(ROOT, "native", name)), "missing native/#{name}"
    end
  end

  def test_gpu_route_uses_a_subpixel_stroke_and_compact_antialiasing
    source = File.read(File.join(ROOT, "native/gcode_route.cpp"))
    vertex = File.read(File.join(ROOT, "native/gcode_route.vert"))
    fragment = File.read(File.join(ROOT, "native/gcode_route.frag"))

    assert_includes source, "constexpr float kRouteLineWidth = 0.65f;"
    assert_includes source, "constexpr float kPlateLineWidth = 0.75f;"
    assert_includes vertex, "const float antialiasPx = 0.75;"
    assert_includes fragment, "const float antialiasPx = 0.75;"
  end

  def test_gpu_route_does_not_filter_physical_layers_by_zoom
    source = File.read(File.join(ROOT, "native/gcode_route.cpp"))
    fragment = File.read(File.join(ROOT, "native/gcode_route.frag"))

    refute_includes source, "visible_layer_stride"
    refute_includes fragment, "layerStride"
    refute_match(/discard.*layer/im, fragment)
  end

  def test_exploded_x1_uses_the_current_layer_bounds_instead_of_a_fixed_zoom
    source = File.read(File.join(ROOT, "native/gcode_route.cpp"))
    projection = File.read(File.join(ROOT, "native/projection.hpp"))

    assert_includes source, "m_focusLayerBounds"
    assert_match(/projection_scale\(.*\) \*\s*kFocusOccupancy/m, projection)
    refute_includes source, "kExplodedBaseZoom"
  end

  def test_nozzle_sampling_uses_physical_distance_along_the_layer
    source = File.read(File.join(ROOT, "native/gcode_route.cpp"))
    header = File.read(File.join(ROOT, "native/gcode_route.hpp"))

    assert_includes header, "sampleNozzle(qreal z, qreal distance)"
    assert_includes source, "std::fmod(distance, qreal(pathLength))"
    refute_match(/sampleNozzle\(qreal z, qreal phase\)/, source)
  end

  def test_plate_stays_visible_while_orbiting_and_tracks_the_viewing_side
    source = File.read(File.join(ROOT, "native/gcode_route.cpp"))
    header = File.read(File.join(ROOT, "native/gcode_route.hpp"))

    refute_includes source, "m_dragging"
    refute_includes header, "m_dragging"
    assert_includes source,
                    "fillPlate(ensureGeometry(plateNode), m_bounds, m_segments.size() >= 6)"
    assert_includes source,
                    "setPlateForeground(Bambu::viewing_from_below(float(m_pitch)))"
  end

  private

  def default_env(data)
    { "BAMBU_NATIVE_DATA_ROOT" => data,
      "BAMBU_NATIVE_SOURCE_ROOT" => File.join(ROOT, "native") }
  end

  def write_failing_command(directory, name)
    path = File.join(directory, name)
    File.write(path, "#!/bin/bash\nexit 127\n")
    File.chmod(0o755, path)
  end

  def stamp_for(source_root)
    hashes = BUILD_SOURCES.map do |name|
      out, _err, status = Open3.capture3("sha256sum", File.join(source_root, name))
      raise "stamp hash failed" unless status.success?
      out.split.first
    end
    files, _err, status = Open3.capture3("sha256sum", stdin_data: hashes.join("\n") + "\n")
    raise "stamp hash failed" unless status.success?
    qt, = Open3.capture3("pkg-config", "--modversion", "Qt6Core")
    "#{files.split.first} #{qt.strip.empty? ? "none" : qt.strip}"
  end

  def write_fake_cmake(bin)
    path = File.join(bin, "cmake")
    File.write(path, <<~SH)
      #!/bin/bash
      set -euo pipefail
      if [[ "${1:-}" == "--install" ]]; then
        prefix=""
        for arg in "$@"; do
          if [[ "$arg" == --prefix=* ]]; then prefix="${arg#--prefix=}"; fi
        done
        mkdir -p "$prefix"
        printf '%s\\n' 'GcodeRoute { anchors.fill: parent }' > "$prefix/RouteHost.qml"
        exit 0
      fi
      exit 0
    SH
    File.chmod(0o755, path)
    File.write(File.join(bin, "g++"), "#!/bin/bash\nexit 0\n")
    File.chmod(0o755, File.join(bin, "g++"))
    File.write(File.join(bin, "pkg-config"), <<~SH)
      #!/bin/bash
      [[ "${1:-}" == --modversion && "${2:-}" == Qt6Core ]] && echo 6.11.1 && exit 0
      exit 1
    SH
    File.chmod(0o755, File.join(bin, "pkg-config"))
    File.write(File.join(bin, "nproc"), "#!/bin/bash\necho 2\n")
    File.chmod(0o755, File.join(bin, "nproc"))
  end
end
