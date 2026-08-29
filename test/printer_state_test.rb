# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "bambu_companion/printer_state"

class PrinterStateTest < Minitest::Test
  def setup
    @state = BambuCompanion::PrinterState.new(clock: -> { Time.utc(2026, 8, 12, 12, 0, 0) })
  end

  def test_merges_partial_reports_without_zeroing_absent_values
    first = @state.update("print" => {
      "nozzle_temper" => 215.25, "bed_temper" => 60,
      "mc_percent" => 12, "gcode_state" => "PREPARE"
    })
    second = @state.update("print" => { "mc_percent" => 13 })

    assert_equal 215.25, second.snapshot.fetch(:nozzle_temp)
    assert_equal 60.0, second.snapshot.fetch(:bed_temp)
    assert_equal 13, second.snapshot.fetch(:percent)
    refute second.load_model
    assert_equal "2026-08-12T12:00:00Z", first.snapshot.fetch(:last_update)
  end

  def test_exposes_live_print_telemetry_for_the_detailed_panel
    update = @state.update("print" => {
      "nozzle_target_temper" => 220, "bed_target_temper" => 65,
      "mc_remaining_time" => 6, "spd_lvl" => 2, "spd_mag" => 100,
      "wifi_signal" => "-49dBm", "cooling_fan_speed" => "11",
      "heatbreak_fan_speed" => "10"
    })

    assert_equal 220.0, update.snapshot.fetch(:nozzle_target_temp)
    assert_equal 65.0, update.snapshot.fetch(:bed_target_temp)
    assert_equal 6, update.snapshot.fetch(:remaining_minutes)
    assert_equal 2, update.snapshot.fetch(:speed_level)
    assert_equal 100, update.snapshot.fetch(:speed_magnitude)
    assert_equal "-49dBm", update.snapshot.fetch(:wifi_signal)
    assert_equal 11.0, update.snapshot.fetch(:cooling_fan_speed)
    assert_equal 10.0, update.snapshot.fetch(:heatbreak_fan_speed)
  end

  def test_decodes_x2d_dual_nozzle_temperatures_and_active_extruder
    fixture = JSON.parse(File.read(File.join(__dir__, "fixtures", "x2d-status.json")))
    update = @state.update(fixture)

    snapshot = update.snapshot
    assert update.load_model
    assert_equal "Bambu Lab X2D", snapshot.fetch(:product_name)
    assert_equal true, snapshot.dig(:camera, :liveview_enabled)
    assert_equal 1, snapshot.fetch(:active_nozzle)
    assert_equal 159.0, snapshot.fetch(:nozzle_temp)
    assert_equal 88.0, snapshot.fetch(:nozzle_target_temp)
    assert_equal [
      {
        id: 0, temp: 220.0, target_temp: 220.0, diameter: 0.4,
        type: "HS01", active: false
      },
      {
        id: 1, temp: 159.0, target_temp: 88.0, diameter: 0.4,
        type: "HS01", active: true
      }
    ], snapshot.fetch(:nozzles)
  end

  def test_x2d_plain_idle_temperatures_decode_with_zero_targets
    update = @state.update("print" => {
      "device" => {
        "extruder" => {
          "info" => [{ "id" => 0, "temp" => 24 }, { "id" => 1, "temp" => 25 }],
          "state" => 274
        }
      }
    })

    pairs = update.snapshot.fetch(:nozzles).map do |nozzle|
      [nozzle.fetch(:temp), nozzle.fetch(:target_temp)]
    end
    assert_equal [[24.0, 0.0], [25.0, 0.0]], pairs
  end

  def test_x2d_partial_state_update_reselects_existing_nozzle_values
    @state.update("print" => {
      "device" => {
        "extruder" => {
          "info" => [{ "id" => 0, "temp" => 13_107_400 },
                     { "id" => 1, "temp" => 12_451_940 }],
          "state" => 2
        }
      }
    })
    update = @state.update("print" => {
      "device" => { "extruder" => { "state" => 274 } }
    })

    assert_equal 1, update.snapshot.fetch(:active_nozzle)
    assert_equal 100.0, update.snapshot.fetch(:nozzle_temp)
    assert_equal 190.0, update.snapshot.fetch(:nozzle_target_temp)
  end

  def test_x2d_partial_extruder_info_preserves_the_other_nozzle
    @state.update("print" => {
      "device" => {
        "extruder" => {
          "info" => [{ "id" => 0, "temp" => 13_107_400 },
                     { "id" => 1, "temp" => 12_451_940 }],
          "state" => 274
        }
      }
    })

    update = @state.update("print" => {
      "device" => { "extruder" => { "info" => [{ "id" => 0, "temp" => 14_418_140 }] } }
    })

    ids = update.snapshot.fetch(:nozzles).map { |nozzle| nozzle.fetch(:id) }
    assert_equal [0, 1], ids
    assert_equal 100.0, update.snapshot.fetch(:nozzles).fetch(1).fetch(:temp)
  end

  def test_x2d_metadata_only_delta_updates_existing_nozzles
    @state.update("print" => {
      "device" => {
        "extruder" => {
          "info" => [{ "id" => 0, "temp" => 24 }, { "id" => 1, "temp" => 25 }],
          "state" => 274
        }
      }
    })

    update = @state.update("print" => {
      "device" => {
        "nozzle" => { "info" => [{ "id" => 1, "diameter" => 0.6, "type" => "HF02" }] }
      }
    })

    second = update.snapshot.fetch(:nozzles).find { |nozzle| nozzle.fetch(:id) == 1 }
    assert_equal 0.6, second.fetch(:diameter)
    assert_equal "HF02", second.fetch(:type)
  end

  def test_x2d_fresh_top_level_temperature_wins_over_cached_active_nozzle
    @state.update("print" => {
      "device" => {
        "extruder" => {
          "info" => [{ "id" => 0, "temp" => 13_107_300 },
                     { "id" => 1, "temp" => 13_107_300 }],
          "state" => 2
        }
      }
    })

    update = @state.update("print" => {
      "nozzle_temper" => 230,
      "nozzle_target_temper" => 240,
      "device" => { "extruder" => { "state" => 274 } }
    })

    active = update.snapshot.fetch(:nozzles).find { |nozzle| nozzle.fetch(:active) }
    assert_equal 1, active.fetch(:id)
    assert_equal 230.0, active.fetch(:temp)
    assert_equal 240.0, active.fetch(:target_temp)
    assert_equal 230.0, update.snapshot.fetch(:nozzle_temp)
    assert_equal 240.0, update.snapshot.fetch(:nozzle_target_temp)
  end

  def test_x2d_metadata_received_before_temperatures_is_preserved
    @state.update("print" => {
      "device" => {
        "nozzle" => { "info" => [{ "id" => 1, "diameter" => 0.6, "type" => "HF02" }] }
      }
    })

    update = @state.update("print" => {
      "device" => {
        "extruder" => {
          "info" => [{ "id" => 1, "temp" => 14_418_140 }],
          "state" => 274
        }
      }
    })

    nozzle = update.snapshot.fetch(:nozzles).find { |entry| entry.fetch(:id) == 1 }
    assert_equal 220.0, nozzle.fetch(:temp)
    assert_equal 220.0, nozzle.fetch(:target_temp)
    assert_equal 0.6, nozzle.fetch(:diameter)
    assert_equal "HF02", nozzle.fetch(:type)
  end

  def test_rejects_nonfinite_numbers_and_oversized_report_strings
    update = @state.update("print" => {
      "nozzle_temper" => Float::INFINITY,
      "bed_temper" => -Float::INFINITY,
      "subtask_name" => "x" * 4097
    })

    assert_nil update.snapshot[:nozzle_temp]
    assert_nil update.snapshot[:bed_temp]
    assert_nil update.snapshot[:subtask_name]
    JSON.generate(update.snapshot)
  end

  def test_detects_running_transition_and_late_job_identity_once
    @state.update("print" => { "gcode_state" => "IDLE" })
    started = @state.update("print" => { "gcode_state" => "RUNNING" })
    named = @state.update("print" => { "subtask_name" => "benchy.gcode.3mf", "plate_idx" => 0 })
    repeated = @state.update("print" => { "mc_percent" => 1 })

    assert started.load_model
    assert named.load_model
    refute repeated.load_model
    refute_respond_to named, :job_key
  end

  def test_progressive_identity_enrichment_does_not_reload_the_same_running_job
    @state.update("print" => { "gcode_state" => "IDLE" })
    started = @state.update("print" => { "gcode_state" => "RUNNING" })
    named = @state.update("print" => { "subtask_name" => "benchy.gcode.3mf" })
    plated = @state.update("print" => { "plate_idx" => 0 })
    identified = @state.update("print" => { "task_id" => "task-42" })

    assert started.load_model
    assert named.load_model
    refute plated.load_model
    refute identified.load_model
  end

  def test_changed_identity_detects_a_new_job_while_still_running
    @state.update("print" => {
      "gcode_state" => "RUNNING", "task_id" => "task-1",
      "subtask_name" => "first.gcode.3mf"
    })

    changed = @state.update("print" => {
      "task_id" => "task-2", "subtask_name" => "second.gcode.3mf"
    })

    assert changed.load_model
  end

  def test_stable_id_dominates_changes_to_weak_identity_hints
    @state.update("print" => {
      "gcode_state" => "RUNNING", "task_id" => "task-1",
      "subtask_name" => "draft"
    })

    renamed = @state.update("print" => { "subtask_name" => "final.gcode.3mf" })

    refute renamed.load_model
  end

  def test_first_stable_id_dominates_simultaneous_weak_hint_enrichment
    @state.update("print" => { "gcode_state" => "RUNNING", "subtask_name" => "draft" })

    identified = @state.update("print" => {
      "task_id" => "task-1", "subtask_name" => "final.gcode.3mf"
    })

    refute identified.load_model
  end

  def test_weak_identity_change_detects_new_job_when_no_stable_id_exists
    @state.update("print" => { "gcode_state" => "RUNNING", "subtask_name" => "first.gcode.3mf" })

    changed = @state.update("print" => { "subtask_name" => "second.gcode.3mf" })

    assert changed.load_model
  end

  def test_finished_job_then_same_file_running_again_reloads_the_model
    first = @state.update("print" => {
      "gcode_state" => "RUNNING", "subtask_name" => "repeat.gcode.3mf"
    })
    finished = @state.update("print" => { "gcode_state" => "FINISH" })
    restarted = @state.update("print" => {
      "gcode_state" => "RUNNING", "subtask_name" => "repeat.gcode.3mf"
    })

    assert first.load_model
    refute finished.load_model
    assert restarted.load_model
  end

  def test_mutating_a_snapshot_string_does_not_change_internal_state
    update = @state.update("print" => { "gcode_state" => "RUNNING", "task_id" => "task-1" })

    assert_raises(FrozenError) { update.snapshot.fetch(:gcode_state).replace("IDLE") }

    assert_equal "RUNNING", @state.snapshot.fetch(:gcode_state)
    refute @state.update("print" => { "mc_percent" => 1 }).load_model
  end

  def test_decodes_hms_severity_without_treating_maintenance_as_an_error
    update = @state.update("print" => {
      "hms" => [
        { "attr" => 0x0700_2300, "code" => 0x0003_0001 },
        { "attr" => 0x0800_0100, "code" => 0x0002_0007,
          "message" => "Toolhead sensor needs attention" }
      ]
    })

    maintenance, serious = update.snapshot.fetch(:alerts)
    assert_equal "HMS_0700_2300_0003_0001", maintenance.fetch(:code)
    assert_equal "warning", maintenance.fetch(:kind)
    assert_equal "common", maintenance.fetch(:severity)
    assert_equal "AMS", maintenance.fetch(:module)
    assert_match(/not treated as a print error/, maintenance.fetch(:description))

    assert_equal "error", serious.fetch(:kind)
    assert_equal "serious", serious.fetch(:severity)
    assert_equal "Toolhead sensor needs attention", serious.fetch(:description)
  end

  def test_hms_alerts_are_cached_across_deltas_and_cleared_explicitly
    first = @state.update("print" => {
      "hms" => [{ "attr" => 0x0500_0500, "code" => 0x0001_0007 }]
    })
    delta = @state.update("print" => { "mc_percent" => 25 })
    cleared = @state.update("print" => { "hms" => [] })

    assert_equal 1, first.snapshot.fetch(:alerts).length
    assert_equal first.snapshot.fetch(:alerts), delta.snapshot.fetch(:alerts)
    assert_empty cleared.snapshot.fetch(:alerts)
  end

  def test_print_error_is_a_separate_transient_error_channel
    failed = @state.update("print" => {
      "hms" => [], "print_error" => 0x0500_C010,
      "fail_reason" => "SD card read failed"
    })
    delta = @state.update("print" => { "mc_percent" => 0 })
    cleared = @state.update("print" => { "print_error" => 0 })

    alert = failed.snapshot.fetch(:alerts).fetch(0)
    assert_equal "print_error", alert.fetch(:source)
    assert_equal "error", alert.fetch(:kind)
    assert_equal "0x0500C010", alert.fetch(:code)
    assert_equal "SD card read failed", alert.fetch(:description)
    assert_equal failed.snapshot.fetch(:alerts), delta.snapshot.fetch(:alerts)
    assert_empty cleared.snapshot.fetch(:alerts)
  end

  def test_mc_print_error_is_used_as_a_fallback_and_snapshots_are_deeply_frozen
    update = @state.update("print" => {
      "mc_print_error_code" => "117473286"
    })

    alert = update.snapshot.fetch(:alerts).fetch(0)
    assert_equal "0x07008006", alert.fetch(:code)
    assert_raises(FrozenError) { alert[:title].replace("changed") }
    assert_raises(FrozenError) { update.snapshot.fetch(:alerts) << {} }
  end

  def test_zero_print_error_wins_over_a_stale_legacy_fallback
    @state.update("print" => { "mc_print_error_code" => "117473286" })
    cleared = @state.update("print" => { "print_error" => 0 })

    assert_empty cleared.snapshot.fetch(:alerts)
  end

  def test_changed_print_error_does_not_reuse_the_previous_failure_reason
    @state.update("print" => {
      "print_error" => 0x0500_C010,
      "fail_reason" => "SD card read failed"
    })
    changed = @state.update("print" => { "print_error" => 0x0700_8006 })

    alert = changed.snapshot.fetch(:alerts).fetch(0)
    assert_equal "0x07008006", alert.fetch(:code)
    refute_equal "SD card read failed", alert.fetch(:description)
    assert_match(/print-process failure/, alert.fetch(:description))
  end

  def test_extracts_printer_product_and_firmware_from_version_report
    update = @state.update("info" => { "module" => [
      { "name" => "ams/0", "product_name" => "AMS" },
      { "name" => "ota", "product_name" => "Bambu Lab P1S",
        "sw_ver" => "01.08.05.00" }
    ] })

    assert_equal "Bambu Lab P1S", update.snapshot.fetch(:product_name)
    assert_equal "01.08.05.00", update.snapshot.fetch(:firmware_version)
  end

  def test_connection_marks_cached_data_stale
    @state.connected!
    refute @state.snapshot.fetch(:stale)
    @state.disconnected!
    assert @state.snapshot.fetch(:stale)
  end

  def test_camera_defaults_to_absent
    camera = @state.snapshot.fetch(:camera)

    assert_equal false, camera.fetch(:present)
    assert_equal "none", camera.fetch(:transport)
    assert_equal false, camera.fetch(:liveview_enabled)
  end

  def test_p1_product_and_ipcam_dev_select_jpeg_tcp
    @state.update("info" => { "module" => [
      { "name" => "ota", "product_name" => "Bambu Lab P1S" }
    ] })
    update = @state.update("print" => {
      "ipcam" => { "ipcam_dev" => "1" }
    })

    camera = update.snapshot.fetch(:camera)
    assert_equal true, camera.fetch(:present)
    assert_equal "jpeg_tcp", camera.fetch(:transport)
    assert_equal true, camera.fetch(:liveview_enabled)
  end

  def test_rtsp_url_selects_rtsps_even_on_p1_name
    @state.update("info" => { "module" => [
      { "name" => "ota", "product_name" => "Bambu Lab P1S" }
    ] })
    update = @state.update("print" => {
      "ipcam" => {
        "ipcam_dev" => "1",
        "rtsp_url" => "rtsps://192.168.1.50:322/streaming/live/1"
      }
    })

    camera = update.snapshot.fetch(:camera)
    assert_equal "rtsps", camera.fetch(:transport)
    assert_equal true, camera.fetch(:liveview_enabled)
  end

  def test_disabled_rtsp_url_means_liveview_off
    @state.update("info" => { "module" => [
      { "name" => "ota", "product_name" => "Bambu Lab H2D" }
    ] })
    update = @state.update("print" => {
      "ipcam" => { "ipcam_dev" => "1", "rtsp_url" => "disable" }
    })

    camera = update.snapshot.fetch(:camera)
    assert_equal true, camera.fetch(:present)
    assert_equal "rtsps", camera.fetch(:transport)
    assert_equal false, camera.fetch(:liveview_enabled)
  end

  def test_x2d_liveview_preview_overrides_stale_disabled_rtsp_url
    @state.update("info" => { "module" => [
      { "name" => "ota", "product_name" => "Bambu Lab X2D" }
    ] })
    update = @state.update("print" => {
      "ipcam" => {
        "ipcam_dev" => "1", "rtsp_url" => "disable",
        "liveview_preview" => true
      }
    })

    camera = update.snapshot.fetch(:camera)
    assert_equal true, camera.fetch(:present)
    assert_equal "rtsps", camera.fetch(:transport)
    assert_equal true, camera.fetch(:liveview_enabled)
  end

  def test_x2d_explicit_false_liveview_preview_keeps_liveview_off
    @state.update("info" => { "module" => [
      { "name" => "ota", "product_name" => "Bambu Lab X2D" }
    ] })
    update = @state.update("print" => {
      "ipcam" => {
        "ipcam_dev" => "1", "rtsp_url" => "disable",
        "liveview_preview" => false
      }
    })

    assert_equal false, update.snapshot.fetch(:camera).fetch(:liveview_enabled)
  end

  def test_x2d_explicit_false_liveview_preview_overrides_stale_rtsp_url
    @state.update("info" => { "module" => [
      { "name" => "ota", "product_name" => "Bambu Lab X2D" }
    ] })
    update = @state.update("print" => {
      "ipcam" => {
        "ipcam_dev" => "1",
        "rtsp_url" => "rtsps://192.168.1.50:322/streaming/live/1",
        "liveview_preview" => false
      }
    })

    camera = update.snapshot.fetch(:camera)
    assert_equal "rtsps", camera.fetch(:transport)
    assert_equal false, camera.fetch(:liveview_enabled)
  end

  def test_h2_product_without_rtsp_url_still_selects_rtsps
    @state.update("info" => { "module" => [
      { "name" => "ota", "product_name" => "Bambu Lab H2D" }
    ] })
    update = @state.update("print" => { "ipcam" => { "ipcam_dev" => "1" } })

    assert_equal "rtsps", update.snapshot.fetch(:camera).fetch(:transport)
  end

  def test_x2d_internal_n6_product_id_selects_rtsps
    @state.update("info" => { "module" => [
      { "name" => "ota", "product_name" => "N6" }
    ] })
    update = @state.update("print" => {
      "ipcam" => { "ipcam_dev" => "1", "liveview_preview" => true }
    })

    camera = update.snapshot.fetch(:camera)
    assert_equal "rtsps", camera.fetch(:transport)
    assert_equal true, camera.fetch(:liveview_enabled)
  end

  def test_absent_ipcam_dev_disables_camera
    @state.update("print" => { "ipcam" => { "ipcam_dev" => "1" } })
    update = @state.update("print" => { "ipcam" => { "ipcam_dev" => "0" } })

    camera = update.snapshot.fetch(:camera)
    assert_equal false, camera.fetch(:present)
    assert_equal "none", camera.fetch(:transport)
  end

  def test_partial_ipcam_updates_do_not_clear_known_fields
    @state.update("print" => {
      "ipcam" => { "ipcam_dev" => "1", "rtsp_url" => "disable" }
    })
    update = @state.update("print" => { "ipcam" => { "ipcam_record" => "enable" } })

    camera = update.snapshot.fetch(:camera)
    assert_equal true, camera.fetch(:present)
    assert_equal "rtsps", camera.fetch(:transport)
    assert_equal false, camera.fetch(:liveview_enabled)
  end
end
