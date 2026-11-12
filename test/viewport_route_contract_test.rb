# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"

class ViewportRouteContractTest < Minitest::Test
  def setup
    @source = File.read(File.expand_path("../BambuModelViewport.qml", __dir__))
  end

  def test_route_view_is_a_gpu_loader_without_canvas
    refute_match(/Canvas\s*\{/, @source)
    refute_includes @source, "motionSegmentBudget"
    refute_includes @source, "stillSegmentBudget"
    refute_includes @source, "packedSegments"
    refute_includes @source, "function requestVisiblePaint"
    refute_includes @source, "onPaint:"
    assert_match(/Loader\s*\{.*id:\s*routeLoader.*source:.*nativeRouteUrl/m, @source)
    assert_includes @source, 'property string rendererStatus'
    assert_includes @source, 'id: routeCamera'
  end

  def test_renderer_empty_states_replace_the_software_fallback
    assert_includes @source, '"COMPILING ROUTE RENDERER"'
    assert_includes @source, '"ROUTE RENDERER UNAVAILABLE"'
    assert_includes @source, "Install cmake and g++ · see Quickshell logs"
    assert_match(/id:\s*loadingIndicator.*visible: viewport\.printerConfigured.*rendererStatus === "compiling"/m,
                 @source)
    assert_match(/interval:\s*16/, @source)
    assert_match(/rendererStatus === "ready"/, @source)
  end

  def test_unconfigured_printer_has_a_dismissible_dashboard_empty_state
    assert_includes @source, "property bool printerConfigured: false"
    assert_match(/function emptyModelTitle\(\).*!viewport\.printerConfigured.*NO PRINTER CONFIGURED/m,
                 @source)
    assert_match(/function emptyModelDetail\(\).*!viewport\.printerConfigured.*OPEN SETTINGS TO CONFIGURE A PRINTER/m,
                 @source)
  end

  def test_route_geometry_is_assigned_once_not_on_every_camera_tick
    geometry = extract_function("syncRouteGeometry")
    view = extract_function("syncRouteItem")

    assert_includes geometry, 'viewport.setMember(item, "segmentPath", viewport.activeSegmentPath)'
    assert_includes geometry, 'viewport.setMember(item, "bounds", viewport.activeBounds)'
    refute_includes view, '"segmentPath"'
    refute_includes view, '"bounds"'
    assert_match(/onLoaded:\s*\{\s*viewport\.syncRouteGeometry\(\).*viewport\.syncRouteItem\(\)/m,
                 @source)
    assert_match(/onActiveSegmentPathChanged:\s*\{.*syncRouteGeometry\(\)/m, @source)
    assert_match(/onActiveBoundsChanged:\s*syncRouteGeometry\(\)/, @source)
    assert_equal 1, @source.scan(/setMember\(item, "segmentPath",/).length
    assert_equal 1, @source.scan(/setMember\(item, "bounds",/).length
    refute_match(/onYawChanged:[^\n]*syncRouteGeometry/, @source)
    assert_match(/onYawChanged:\s*viewport\.syncRouteItem\(\)/, @source)
  end

  def test_route_item_sync_passes_stroke_alpha_and_explosion_factor
    assert_includes @source, 'viewport.setMember(item, "explosionFactor", routeCamera.explosionFactor)'
    assert_includes @source, 'viewport.setMember(item, "cutoffZ", viewport.zCurrent)'
    assert_match(/setMember\(item, "printedColor", Qt\.rgba\(printed\.r, printed\.g, printed\.b, 0\.74\)\)/,
                 @source)
    assert_match(/setMember\(item, "remainingColor", Qt\.rgba\(viewport\.foreground\.r, viewport\.foreground\.g,\s*viewport\.foreground\.b, 0\.10\)\)/m,
                 @source)
    assert_match(/setMember\(item, "plateColor", Qt\.rgba\(viewport\.foreground\.r, viewport\.foreground\.g,\s*viewport\.foreground\.b, 0\.07\)\)/m,
                 @source)
    refute_match(/setMember\(item, "printedColor",\s*viewport\.accent/, @source)
    refute_match(/setMember\(item, "remainingColor",\s*viewport\.foreground/, @source)
  end

  def test_source_icons_are_white_masks_recolored_by_the_plugin_palette
    %w[route.svg image.svg camera.svg list-restart.svg].each do |name|
      icon = File.read(File.expand_path("../assets/#{name}", __dir__))

      assert_includes icon, 'stroke="#fff"'
      refute_includes icon, 'stroke="#000"'
    end
    assert_match(/component SourceIconButton: BambuButton.*MultiEffect.*colorization:\s*1.*colorizationColor:\s*sourceButton\.foreground/m,
                 @source)
  end

  def test_loading_message_has_three_panel_scoped_staggered_bouncing_dots
    assert_match(/id:\s*loadingIndicator.*visible:.*!viewport\.downloadProgressVisible/m,
                 @source)
    assert_match(/Repeater\s*{\s*model:\s*3.*property int phaseDelay:\s*index \* 120/m,
                 @source)
    assert_match(/SequentialAnimation\s*{.*running:\s*viewport\.panelActive\s*&&\s*loadingIndicator\.visible.*loops:\s*Animation\.Infinite.*PauseAnimation\s*{\s*duration:\s*loadingDot\.phaseDelay\s*}.*NumberAnimation\s*{.*property:\s*"y".*to:\s*-Style\.space\(3\).*}.*NumberAnimation\s*{.*property:\s*"y".*to:\s*0/m,
                 @source)
    assert_includes @source, "readonly property bool downloadProgressVisible:"
    assert_match(/id: downloadProgressTrack.*visible: viewport\.downloadProgressVisible.*width: downloadProgressTrack\.width \* viewport\.modelLoadProgress \/ 100/m,
                 @source)
    assert_match(/function emptyModelTitle\(\).*modelLoadPhase === "downloading".*DOWNLOADING PRINT FILE.*modelLoadPhase === "processing".*PROCESSING PRINT DATA.*LOCATING PRINT FILE/m,
                 @source)
    assert_match(/function emptyModelDetail\(\).*formatBytes\(viewport\.modelLoadedBytes\).*formatBytes\(viewport\.modelTotalBytes\)/m,
                 @source)
  end

  def test_camera_animation_is_panel_scoped_and_sixteen_ms
    assert_match(/interval:\s*16/, @source)
    refute_includes @source, "interval: 50"
    assert_match(/running:\s*viewport\.panelActive.*viewport\.selectedSource === "gcode".*viewport\.rendererStatus === "ready".*routeCamera\.autoRotate/m,
                 @source)
    assert_includes @source, "function advanceAutoRotation(timestamp)"
    assert_match(/if \(dragging\) return/, @source)
    assert_match(/yaw = normalizeAngle\(yaw \+ elapsed \/ 14000 \* Math\.PI \* 2\)/,
                 @source)
    refute_includes @source, "schedulePaint"
  end

  def test_auto_rotation_uses_the_configured_default_but_remains_session_toggleable
    assert_includes @source, "property bool autoRotateDefault: true"
    assert_includes @source, "property bool autoRotate: viewport.autoRotateDefault"
    assert_match(/onAutoRotateDefaultChanged:\s*\{.*routeCamera\.autoRotate = viewport\.autoRotateDefault.*routeCamera\.lastFrameTimestamp = 0/m,
                 @source)
    assert_match(/text: routeCamera\.autoRotate \? "AUTO-ROTATE ON" : "AUTO-ROTATE OFF".*onClicked:\s*\{.*routeCamera\.autoRotate = !routeCamera\.autoRotate/m,
                 @source)
  end

  def test_two_axis_drag_allows_complete_orbits_across_both_sides_of_the_plate
    normalize = extract_function("normalizeAngle")
    normalize_signed = extract_function("normalizeSignedAngle")
    drag = extract_function("orientationAfterDrag")
    script = <<~JAVASCRIPT
      #{normalize}
      #{normalize_signed}
      #{drag}
      console.log(JSON.stringify([
        orientationAfterDrag(0, -0.28, 300, 0, 600, 360),
        orientationAfterDrag(0, -0.28, -150, 180, 600, 360),
        orientationAfterDrag(1, -0.28, 600, 360, 600, 360),
        orientationAfterDrag(1, -0.28, 0, 720, 600, 360)
      ]))
    JAVASCRIPT
    values = run_javascript(script)

    assert_in_delta Math::PI, values[0].fetch("yaw"), 1e-9
    assert_in_delta(-0.28, values[0].fetch("pitch"), 1e-9)
    assert_in_delta Math::PI * 1.5, values[1].fetch("yaw"), 1e-9
    assert_in_delta(-0.28 + (Math::PI / 2), values[1].fetch("pitch"), 1e-9)
    assert_in_delta 1.0, values[2].fetch("yaw"), 1e-9
    assert_in_delta(-0.28 + Math::PI, values[2].fetch("pitch"), 1e-9)
    assert_in_delta 1.0, values[3].fetch("yaw"), 1e-9
    assert_in_delta(-0.28, values[3].fetch("pitch"), 1e-9)
    refute_includes @source, "clampPitch"
    assert_match(/MouseArea\s*\{.*anchors\.fill: parent.*onPressed: function\(mouse\).*dragging = true.*onPositionChanged: function\(mouse\).*orientationAfterDrag.*onReleased:.*dragging = false/m,
                 @source)
  end

  def test_native_plate_is_not_toggled_by_the_drag_state
    sync_body = @source[/function syncRouteItem\(\) \{.*?\n  \}/m]
    refute_nil sync_body
    refute_includes sync_body, '"dragging"'
    assert_match(/onDraggingChanged:\s*viewport\.syncNozzleMarker\(\)/, @source)
  end

  def test_reload_sits_with_rotation_controls_and_route_view_uses_the_footer_space
    assert_match(/id:\s*viewportFrame.*anchors\.bottom:\s*parent\.bottom/m, @source)
    assert_match(/Row\s*{\s*id:\s*modelControls.*text: routeCamera\.autoRotate \? "AUTO-ROTATE ON" : "AUTO-ROTATE OFF".*text: "RELOAD PREVIEW"/m,
                 @source)
    assert_includes @source, 'text: "RELOAD PREVIEW"'
    refute_includes @source, "id: viewportFooter"
  end

  def test_gcode_and_preview_use_vertical_lucide_buttons_below_coordinates
    assert_includes @source, "property bool previewAvailable: false"
    assert_includes @source, "property bool gcodeAvailable: false"
    assert_includes @source, 'property string selectedSource: "gcode"'
    assert_includes @source, "signal sourceRequested(string source)"
    assert_match(/component SourceIconButton: BambuButton\s*\{.*required property string sourceName.*required property bool available.*enabled:\s*sourceName === "camera" \? available : true.*active: viewport\.selectedSource === sourceName.*onClicked: viewport\.sourceRequested\(sourceName\)/m,
                 @source)
    assert_match(/Column\s*\{\s*id:\s*sourceButtons.*anchors\.top:\s*coordinateBadge\.bottom.*SourceIconButton\s*\{.*sourceName:\s*"gcode".*available:\s*viewport\.gcodeAvailable.*iconSource:\s*Qt\.resolvedUrl\("assets\/route\.svg"\).*SourceIconButton\s*\{.*sourceName:\s*"camera".*available:\s*viewport\.cameraAvailable.*iconSource:\s*Qt\.resolvedUrl\("assets\/camera\.svg"\).*SourceIconButton\s*\{.*sourceName:\s*"preview".*available:\s*viewport\.previewAvailable.*iconSource:\s*Qt\.resolvedUrl\("assets\/image\.svg"\)/m,
                 @source)
    refute_includes @source, 'text: "MODEL"'
    refute_includes @source, 'text: "G-CODE"'
  end

  def test_event_log_button_is_square_below_preview_with_separator
    assert_includes @source, "signal eventsRequested()"
    assert_match(/id:\s*sourceButtons.*sourceName:\s*"preview".*assets\/image\.svg.*Item\s*{.*height:\s*Style\.space\(7\).*Rectangle\s*{.*width:\s*Style\.space\(18\).*height:\s*1.*BambuEventButton\s*{.*width:\s*sourceButtons\.width.*height:\s*width.*onClicked:\s*viewport\.eventsRequested\(\)/m,
                 @source)
  end

  def test_switching_source_does_not_reset_the_route_camera
    buttons = @source[/Column\s*\{\s*id:\s*sourceButtons.*?\n\s*\}/m]
    refute_nil buttons
    refute_match(/routeCamera\.(?:yaw|pitch|zoom)\s*=/, buttons)
  end

  def test_preview_is_centered_without_using_the_route_renderer
    assert_match(/Image\s*\{\s*anchors\.fill: parent.*source:\s*viewport\.previewSource.*fillMode:\s*Image\.PreserveAspectFit.*visible:\s*viewport\.selectedSource === "preview"/m,
                 @source)
    assert_match(/Loader\s*\{\s*id:\s*routeLoader.*visible:\s*viewport\.rendererStatus === "ready"/m,
                 @source)
  end

  def test_camera_still_uses_a_cached_busting_image_not_a_video_item
    refute_match(/MediaPlayer|VideoOutput|QtMultimedia/i, @source)
    assert_match(/Image\s*\{.*source:\s*viewport\.cameraFrameSource.*fillMode:\s*Image\.PreserveAspectFit.*cache:\s*false.*visible:\s*viewport\.selectedSource === "camera" && viewport\.cameraFrameAvailable/m,
                 @source)
    assert_includes @source, "CHAMBER CAMERA"
    assert_includes @source, "WAITING FOR CAMERA"
    assert_match(/text:\s*viewport\.emptyModelDetail\(\).*textFormat:\s*Text\.PlainText/m,
                 @source)
  end

  def test_simulated_nozzle_is_sampled_by_the_native_renderer
    refute_includes @source, "function drawNozzle"
    refute_includes @source, "function buildNozzlePath"
    refute_includes @source, "function nozzlePosition"
    assert_includes @source, "id: nozzleMarker"
    assert_match(/mapToView\.call\(item, world\[0\], world\[1\], world\[2\]\)/,
                 @source)
    assert_match(/running:.*viewport\.selectedSource === "gcode".*viewport\.rendererStatus === "ready".*viewport\.printing/m,
                 @source)
    assert_match(/function syncNozzleMarker\(\).*!viewport\.printing.*viewport\.selectedSource !== "gcode".*routeCamera\.dragging.*sampleAvailable = false/m,
                 @source)
    assert_includes @source, "readonly property real nozzleSpeed: 50"
    assert_match(/if \(viewport\.printing\).*nozzleDistance \+= elapsed \/ 1000 \* viewport\.nozzleSpeed/m,
                 @source)
    assert_match(/sampleNozzle\.call\(\s*item, viewport\.zCurrent, routeCamera\.nozzleDistance\)/,
                 @source)
    assert_includes @source, "property bool sampleAvailable: false"
  end

  def test_wheel_zoom_is_bounded_visible_and_documented_in_the_viewport
    assert_includes @source, "property real normalZoom: 1"
    assert_includes @source, "property real explodedZoom: 1"
    assert_includes @source, "property real wheelStepAccumulator: 0"
    assert_includes @source, "readonly property real maximumZoom: exploded ? 8 : 4"
    assert_includes @source, 'viewport.setMember(item, "zoom", routeCamera.zoom)'
    refute_includes @source, "explodedBaseZoom"
    refute_includes @source, "effectiveZoom"
    assert_match(/function wheelStepDelta\(angleDeltaY, pixelDeltaY\)/, @source)
    assert_match(/function wholeWheelSteps\(accumulatedSteps\)/, @source)
    assert_match(/function zoomAfterSteps\(currentZoom, steps, minimumZoom, maximumZoom\)/, @source)
    assert_match(/return Math\.max\(minimum, Math\.min\(limit, nextZoom\)\)/,
                 @source)
    assert_match(/onWheel: function\(wheel\).*wheelStepAccumulator \+=.*wholeWheelSteps.*if \(wholeSteps !== 0\).*setZoom\(routeCamera\.zoomAfterSteps\(\s*routeCamera\.zoom, wholeSteps, routeCamera\.minimumZoom,\s*routeCamera\.maximumZoom\)\).*wheelStepAccumulator -= wholeSteps.*wheel\.accepted = true/m,
                 @source)
    assert_includes @source, 'text: "ZOOM ×" + routeCamera.formatZoom(routeCamera.zoom)'
    assert_includes @source, "WHEEL TO ZOOM"
    assert_match(/onAccentChanged:\s*syncRouteItem\(\)/, @source)
    assert_match(/Row\s*{\s*id:\s*modelFooter.*width: Math\.max\(0, parent\.width - Style\.space\(20\)\).*clip:\s*true/m,
                 @source)
  end

  def test_wheel_zoom_multiplier_moves_both_directions_and_clamps
    delta = extract_function("wheelStepDelta")
    whole = extract_function("wholeWheelSteps")
    zoom = extract_function("zoomAfterSteps")
    format = extract_function("formatZoom")
    values = run_javascript(<<~JAVASCRIPT)
      #{delta}
      #{whole}
      #{zoom}
      #{format}
      console.log(JSON.stringify({
        deltas: [wheelStepDelta(120, 0), wheelStepDelta(-1, 0),
          wheelStepDelta(0, 15)],
        whole: [wholeWheelSteps(0.99), wholeWheelSteps(-0.99),
          wholeWheelSteps(1.01), wholeWheelSteps(-1.01)],
        zooms: [zoomAfterSteps(1, 1, 0.5, 4), zoomAfterSteps(1, -1, 0.5, 4),
          zoomAfterSteps(3.99, 10, 0.5, 4), zoomAfterSteps(0.51, -10, 0.5, 4),
          zoomAfterSteps(4, 100, 0.125, 8)],
        labels: [formatZoom(1), formatZoom(1.12), formatZoom(0.999999999)]
      }))
    JAVASCRIPT

    assert_equal [1, -1.0 / 120, 0.5], values.fetch("deltas")
    assert_equal [0, 0, 1, -1], values.fetch("whole")
    assert_operator values.fetch("zooms")[0], :>, 1
    assert_operator values.fetch("zooms")[1], :<, 1
    assert_equal 4, values.fetch("zooms")[2]
    assert_equal 0.5, values.fetch("zooms")[3]
    assert_equal 8, values.fetch("zooms")[4]
    assert_equal ["1", "1.12", "1"], values.fetch("labels")
  end

  def test_exploded_view_uses_bounded_factor_and_animated_progress
    assert_includes @source, "property real explosionFactor: 100"
    assert_match(/readonly property real explosionFactor: Math\.max\(0, Math\.min\(500,.*viewport\.explosionFactor.*100\)\)/m,
                 @source)
    assert_includes @source, "property bool exploded: false"
    assert_includes @source, "property real explosionProgress: exploded ? 1 : 0"
    assert_match(/Behavior on explosionProgress\s*{\s*NumberAnimation\s*{.*duration:\s*350.*easing\.type:\s*Easing\.InOutCubic/m,
                 @source)
    assert_includes @source, 'viewport.setMember(item, "explosionFactor", routeCamera.explosionFactor)'
    assert_includes @source, 'viewport.setMember(item, "explosionProgress", routeCamera.explosionProgress)'
  end

  def test_explode_button_is_above_the_z_footer_and_only_controls_gcode
    assert_match(/BambuButton\s*{\s*visible:\s*viewport\.selectedSource === "gcode".*anchors\.right:\s*parent\.right.*anchors\.bottom:\s*modelFooter\.top.*text:\s*routeCamera\.exploded \? "EXPLODE ON" : "EXPLODE OFF".*enabled:\s*viewport\.gcodeAvailable.*onClicked:\s*routeCamera\.exploded = !routeCamera\.exploded/m,
                 @source)
  end

  def test_print_preparation_and_error_states_are_explained_and_colored
    assert_includes @source, '"LOCATING PRINT FILE"'
    assert_includes @source, '"DOWNLOADING PRINT FILE"'
    assert_includes @source, '"PROCESSING PRINT DATA"'
    assert_includes @source, '"PRINT DATA NOT READY YET"'
    assert_includes @source,
                    '"Automatic retries are limited · use Reload preview to try again"'
    assert_match(/property color errorColor:/, @source)
    assert_match(/property bool errorActive:/, @source)
    assert_match(/var printed = viewport\.errorActive \? viewport\.errorColor : viewport\.accent/,
                 @source)
    assert_match(/text: "● PRINTED"\s*color: viewport\.errorActive \? viewport\.errorColor : viewport\.accent/m,
                 @source)
    assert_match(/text: "Z ".*color: viewport\.errorActive \? viewport\.errorColor : viewport\.accent/m,
                 @source)
    assert_match(/color: viewport\.errorColor.*visible: viewport\.modelError !== ""/m,
                 @source)
    assert_match(/onErrorActiveChanged:\s*syncRouteItem\(\)/, @source)
  end

  def test_empty_gcode_column_covers_compiling_unavailable_and_missing_segments
    assert_match(/visible:\s*viewport\.selectedSource === "preview"\s*\? !viewport\.previewAvailable\s*: \(viewport\.selectedSource === "camera"\s*\? !viewport\.cameraFrameAvailable\s*: \(viewport\.rendererStatus !== "ready" \|\| !viewport\.gcodeAvailable\)\)/m,
                 @source)
    assert_match(/function emptyModelTitle\(\).*rendererStatus === "compiling".*COMPILING ROUTE RENDERER.*rendererStatus === "unavailable".*ROUTE RENDERER UNAVAILABLE/m,
                 @source)
    assert_match(/function emptyModelDetail\(\).*rendererStatus === "unavailable".*Install cmake and g\+\+ · see Quickshell logs/m,
                 @source)
  end

  private

  def extract_function(name)
    start = @source.index("function #{name}(")
    refute_nil start, "missing function #{name}"
    opening = @source.index("{", start)
    depth = 0
    @source.each_char.with_index.drop(opening).each do |character, index|
      depth += 1 if character == "{"
      depth -= 1 if character == "}"
      return @source[start..index] if depth.zero?
    end
    flunk "unterminated function #{name}"
  end

  def run_javascript(script)
    output, error, status = Open3.capture3("node", "-e", script)
    assert status.success?, "JavaScript harness failed: #{error}"
    JSON.parse(output)
  end
end
