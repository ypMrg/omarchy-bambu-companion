# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class QmlEventStoreTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  HARNESS = File.join(ROOT, "test/qml/event_store_smoke/shell.qml")

  def test_event_store_behavior_in_qml_runtime
    Dir.mktmpdir("bq-event-") do |temporary_root|
      config_dir = File.join(temporary_root, "config")
      runtime_dir = File.join(temporary_root, "runtime")
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      FileUtils.cp(File.join(ROOT, "BambuEventStore.qml"), config_dir)
      FileUtils.cp(HARNESS, File.join(config_dir, "shell.qml"))
      environment = {
        "QT_QPA_PLATFORM" => "offscreen",
        "QT_QPA_PLATFORMTHEME" => "",
        "QT_QUICK_BACKEND" => "software",
        "QT_STYLE_OVERRIDE" => "Fusion",
        "XDG_RUNTIME_DIR" => runtime_dir
      }
      output, errors, status = Open3.capture3(
        environment, "timeout", "15", "quickshell", "--no-color",
        "-p", File.join(config_dir, "shell.qml"), chdir: config_dir
      )
      report = [output, errors].reject(&:empty?).join("\n")

      assert status.success?, report
      assert_includes report, "BAMBU_EVENT_STORE_PASS"
      refute_includes report, "BAMBU_EVENT_STORE_FAIL"
    end
  end
end
