# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class QmlServiceSmokeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  HARNESS = File.join(ROOT, "test/qml/service_smoke/shell.qml")
  SHELL_MODULES = %w[Commons Ui].freeze
  STAGING_EXCLUSIONS = %w[.bundle .git graphify-out test].freeze
  LIVE_DATA_ROOT = File.expand_path(
    "~/.local/share/io.github.ypmrg.bambu-companion"
  )

  def test_offline_demo_loads_service_dashboard_route_and_animation
    Dir.mktmpdir("bq-") do |temporary_root|
      config_dir = File.join(temporary_root, "config")
      data_home = File.join(temporary_root, "data")
      runtime_dir = File.join(temporary_root, "runtime")
      stage_config(config_dir)
      stage_runtime_data(data_home)
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      environment = {
        "QT_QPA_PLATFORM" => "offscreen",
        "QT_QPA_PLATFORMTHEME" => "",
        "QT_QUICK_BACKEND" => "software",
        "QT_STYLE_OVERRIDE" => "Fusion",
        "BAMBU_COMPANION_DISABLE_UPDATE_CHECK" => "1",
        "XDG_DATA_HOME" => data_home,
        "XDG_RUNTIME_DIR" => runtime_dir,
        "QML_IMPORT_PATH" => "/usr/share/omarchy/shell"
      }
      stdout, stderr, status = Open3.capture3(
        environment, "timeout", "45", "quickshell", "--no-color",
        "-p", File.join(config_dir, "shell.qml"), chdir: config_dir
      )
      output = "#{stdout}\n#{stderr}"

      assert status.success?, output
      assert_includes output, "BAMBU_SMOKE_PASS"
      refute_includes output, "BAMBU_SMOKE_FAIL"
      refute_includes output, "camera_start"
    end
  end

  private

  def stage_config(config_dir)
    plugin_dir = File.join(config_dir, "plugin")
    FileUtils.mkdir_p(plugin_dir)
    Dir.children(ROOT).each do |entry|
      next if STAGING_EXCLUSIONS.include?(entry)

      FileUtils.cp_r(File.join(ROOT, entry), plugin_dir, preserve: true)
    end
    SHELL_MODULES.each do |name|
      FileUtils.cp_r(File.join("/usr/share/omarchy/shell", name), config_dir)
    end
    FileUtils.cp(HARNESS, File.join(config_dir, "shell.qml"))
  end

  def stage_runtime_data(data_home)
    data_root = File.join(data_home, "io.github.ypmrg.bambu-companion")
    FileUtils.mkdir_p(File.join(data_root, "qml"))
    FileUtils.cp_r(File.join(LIVE_DATA_ROOT, "bundle"), data_root)
    FileUtils.cp_r(
      File.join(LIVE_DATA_ROOT, "qml/native"), File.join(data_root, "qml")
    )
  end
end
