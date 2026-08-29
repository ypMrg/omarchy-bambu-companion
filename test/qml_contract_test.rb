# frozen_string_literal: true

require_relative "test_helper"
require "json"

class QmlContractTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
    @widget_source = File.read(File.join(@root, "BambuWidget.qml"))
    @service_source = File.read(File.join(@root, "BambuService.qml"))
    @dashboard_source = File.read(File.join(@root, "BambuDashboard.qml"))
    @source = [@widget_source, @service_source, @dashboard_source].join("\n")
    @settings_source = File.read(File.join(@root, "BambuSettingsView.qml"))
    @telemetry_source = File.read(File.join(@root, "BambuTelemetryPane.qml"))
    @viewport_source = File.read(File.join(@root, "BambuModelViewport.qml"))
    @button_source = File.read(File.join(@root, "BambuButton.qml"))
    @printer_icon_source = File.read(File.join(@root, "BambuPrinterIcon.qml"))
    @geometry_source = File.read(File.join(@root, "BambuGeometryAssembler.qml"))
    @backend_source = File.read(File.join(@root, "BambuBackendSession.qml"))
    @event_store_source = File.read(File.join(@root, "BambuEventStore.qml"))
    @event_history_source = File.read(File.join(@root, "BambuEventHistory.qml"))
    @event_button_source = File.read(File.join(@root, "BambuEventButton.qml"))
    manifest = JSON.parse(File.read(File.join(@root, "manifest.json")))
    @widget_defaults = manifest.fetch("barWidget").fetch("defaults")
    @widget_schema = manifest.fetch("barWidget").fetch("schema")
  end

  def test_button_wrapper_exposes_only_options_used_by_the_plugin
    refute_match(/property bool selected:/, @button_source)
    refute_match(/property bool focusable:/, @button_source)
    assert_match(/^\s*selected: false$/m, @button_source)
    assert_match(/^\s*focusable: false$/m, @button_source)
  end

  def test_qml_ids_are_referenced_in_their_component
    Dir[File.join(@root, "Bambu*.qml")].each do |path|
      source = File.read(path)
      source.scan(/^\s*id:\s*([A-Za-z_]\w*)/).flatten.each do |id|
        references = source.scan(/\b#{Regexp.escape(id)}\b/).length
        assert_operator references, :>, 1,
                        "#{File.basename(path)} declares unused id #{id}"
      end
    end
  end

  def test_widget_does_not_keep_unused_panel_margin_state
    refute_includes @source, "panelHorizontalMargin"
  end

  def test_quattro_widget_and_process_contract
    assert_includes @source, "BarWidget {"
    assert_includes @source, 'moduleName: "io.github.ypmrg.bambu-companion"'
    assert_match(/function open\(\)/, @source)
    assert_match(/function close\(\)/, @source)
    assert_includes @source, "readonly property bool opened"
    assert_includes @source, "BambuBackendSession {"
    assert_includes @backend_source, "property Process sessionProcess: Process {"
    assert_includes @backend_source, "stdout: SplitParser"
    assert_includes @backend_source, "stdinEnabled: true"
    assert_includes @backend_source, "command: [backend.executable]"
    assert_includes @source, "implicitWidth: button.implicitWidth"
    assert_includes @source, "implicitHeight: button.implicitHeight"
    assert_match(/restartDelay = Math\.min\(60000, restartDelay \* 2\)/,
                 @backend_source)
    assert_includes @backend_source, "restartTimer.restart()"
  end

  def test_widget_does_not_override_qquickitem_final_layer_property
    refute_match(/^\s*property\s+\w+\s+layer\s*:/, @source)
    assert_includes @source, "property int currentLayer: 0"
    assert_match(/currentLayer = Math\.max\(0, Math\.floor\(finiteNumber\(printer\.layer, 0\)\)\)/,
                 @source)
    assert_match(/layerValue:\s*\(root\.service\.currentLayer \|\| "--"\) \+ " \/ "\s*\+ \(root\.service\.totalLayers \|\| "--"\)/,
                 @dashboard_source)
  end

  def test_process_lifecycle_resets_state_and_schedules_one_restart
    assert_includes @backend_source, "property bool restartScheduled: false"
    assert_includes @backend_source, "function resetBuffers()"
    assert_match(/function handleRunningChanged\(\).*if \(sessionProcess\.running\).*restartScheduled = false.*return.*if \(!started\) return.*daemonReady = false.*if \(restartScheduled\) return.*resetBuffers\(\).*stopped\(\).*restartScheduled = true.*restartTimer\.restart\(\)/m,
                 @backend_source)
    assert_includes @backend_source,
                    "onRunningChanged: backend.handleRunningChanged()"
    refute_includes @backend_source, "onExited:"
    assert_match(/onTriggered:.*backend\.restartScheduled = false.*backend\.sessionProcess\.running = true/m,
                 @backend_source)
    assert_match(/function handleBackendStopped\(\).*resetOperationalState\(\).*recoverSecretWrite\(/m,
                 @source)
  end

  def test_native_build_process_compiles_the_route_renderer
    assert_includes @source, "id: nativeBuild"
    assert_includes @source, "readonly property string nativeBuildPath"
    assert_includes @source, 'Qt.resolvedUrl("native/build")'
    assert_includes @source, "readonly property string nativeRoutePath"
    assert_includes @source, 'Quickshell.env("XDG_DATA_HOME")'
    assert_includes @source,
                    'nativeDataRoot + "/qml/native/RouteHost.qml"'
    assert_includes @source, 'property string rendererStatus: "compiling"'
    assert_includes @source, "readonly property url nativeRouteUrl"
    assert_includes @source, "function markRendererReady()"
    assert_includes @source, "function markRendererUnavailable()"
    native_build = @source[/Process \{\s*id: nativeBuild.*?\n  \}/m]
    refute_nil native_build
    assert_match(/command: \[root\.nativeBuildPath\]/, native_build)
    assert_includes native_build, "running: false"
    assert_match(/stdout: SplitParser\s*\{\s*splitMarker: ""\s*onRead: function\(_\) \{\}/m,
                 native_build)
    assert_match(/stderr: SplitParser\s*\{\s*splitMarker: ""\s*onRead: function\(chunk\) \{\s*console\.warn\(String\(chunk\)\.trim\(\)\)\s*\}/m,
                 native_build)
    assert_match(/onExited: function\(exitCode\).*exitCode === 0.*root\.markRendererReady\(\).*root\.markRendererUnavailable\(\)/m,
                 native_build)
    assert_match(/onStarted:.*nativeBuildStarted = true/m, native_build)
    assert_match(/onRunningChanged:.*handleNativeBuildRunningChanged/m, native_build)
    assert_match(/function handleNativeBuildRunningChanged\(\).*if \(nativeBuild\.running\).*return.*if \(componentReady && !nativeBuildStarted\).*root\.markRendererUnavailable\(\)/m,
                 @service_source)
    assert_match(/function initialize\(\).*componentReady = true.*backendSession\.start\(\).*nativeBuild\.running = true.*if \(!nativeBuild\.running && !root\.nativeBuildStarted\).*root\.markRendererUnavailable\(\)/m,
                 @service_source)
    assert_match(/BambuModelViewport\s*\{.*rendererStatus: root\.service\.rendererStatus.*nativeRouteUrl: root\.service\.nativeRouteUrl.*onRendererLoadFailed: root\.service\.markRendererUnavailable\(\)/m,
                 @dashboard_source)
    assert_match(/function segmentLimit\(\).*finiteNumber\(root\.maxSegments, 500000\)/m,
                 @source)
  end

  def test_finished_status_settles_to_ready_after_one_minute
    assert_includes @source, "property bool finishGraceExpired: false"
    assert_match(/function isFinishedState\(state\).*FINISH.*FINISHED.*COMPLETE.*COMPLETED/m,
                 @source)
    assert_match(/readonly property string displayGcodeState:.*finishGraceExpired.*isFinishedState\(root\.gcodeState\).*\? "READY" : root\.gcodeState/m,
                 @source)
    assert_match(/onGcodeStateChanged:.*if \(root\.isFinishedState\(root\.gcodeState\)\).*if \(!finishReadyTimer\.running && !root\.finishGraceExpired\).*finishReadyTimer\.start\(\).*return.*finishReadyTimer\.stop\(\).*finishGraceExpired = false/m,
                 @source)
    assert_match(/Timer \{\s*id: finishReadyTimer\s*interval: 60000\s*repeat: false\s*onTriggered:.*if \(root\.isFinishedState\(root\.gcodeState\)\).*root\.finishGraceExpired = true/m,
                 @source)

    assert_match(/function statusSummary\(separator\).*if \(!root\.connected\) return "OFFLINE".*root\.displayGcodeState/m,
                 @source)
    assert_match(/function tooltipText\(\).*root\.service\.statusSummary\(" · "\)/m,
                 @widget_source)
    assert_match(/printerState: root\.service\.displayGcodeState/, @dashboard_source)
    assert_match(/function resetOperationalState\(\).*finishReadyTimer\.stop\(\).*finishGraceExpired = false/m,
                 @source)
  end

  def test_configuration_is_sent_only_after_hello
    assert_match(/function sendConfiguration\(draft\)\s*{\s*if \(!daemonReady \|\| !root\.hasConnectionTarget\) return/m, @source)
    assert_match(/message\.event === "hello".*daemonReady = Number\(message\.protocol\) === 1.*installationId = String\(message\.installationId \|\| ""\).*sendConfiguration\(\)/m,
                 @source)
    assert_includes @source, '"op": "configure"'
    assert_match(/message\.event === "hello".*if \(!daemonReady \|\| !installationIdentified\).*resetOperationalState\(\).*reportProcessError\("Unsupported backend protocol"\).*return.*backendSession\.markReady\(\).*sendConfiguration\(\).*if \(!daemonReady\) return/m,
                 @source)
  end

  def test_only_backend_configuration_changes_reset_and_reconfigure
    configuration = @source[/function configuration\(\)\s*{.*?\n  }/m]
    refute_nil configuration
    refute_includes configuration, "printerName"
    assert_includes @source,
                    "readonly property string backendConfigurationFingerprint: JSON.stringify(root.configuration())"
    assert_includes @source, "property bool componentReady: false"
    assert_match(/function initialize\(\).*componentReady = true.*refreshSettings\(\).*backendSession\.start\(\)/m,
                 @service_source)
    assert_match(/function close\(\).*settingsView\.clearAccessCode\(\).*root\.viewMode = root\.nextIdleView\(\)/m,
                 @dashboard_source)
    refute_includes @source, "onSettingsChanged:"
    assert_match(/onBackendConfigurationFingerprintChanged:.*if \(!componentReady \|\| persistingSettings\) return.*resetOperationalState\(\).*sendConfiguration\(\)/m,
                 @source)
    assert_match(/function resetOperationalState\(\).*connected = false.*gcodeState = "OFFLINE".*percent = 0.*nozzleTemp = NaN.*modelError = "".*reportProcessError\(""\).*secretRequired = false.*secretStored = false.*secretStatusKnown = false.*geometryAssembler\.reset\(-1\)/m,
                 @service_source)
  end

  def test_raw_process_chunks_are_reassembled_with_a_hard_line_limit
    match = @backend_source.match(/property int maxLineChars:\s*(\d+)/)
    refute_nil match
    assert_operator match[1].to_i, :>=, 262_144
    assert_operator match[1].to_i, :<=, 4_194_304
    assert_includes @backend_source, 'property string stdoutBuffer: ""'
    assert_includes @backend_source, "property bool stdoutDiscarding: false"
    assert_includes @backend_source, 'property string stderrBuffer: ""'
    assert_includes @backend_source, "property bool stderrDiscarding: false"
    assert_includes @backend_source, "function consumeChunk(chunk, stdoutStream)"
    assert_match(/buffer\.length \+ part\.length > maxLineChars.*buffer = "".*discarding = true/m,
                 @backend_source)
    assert_match(/newlineIndex < 0\) break.*if \(!discarding\).*lineReceived/m,
                 @backend_source)
    assert_match(/discarding = false.*offset = newlineIndex \+ 1/m,
                 @backend_source)
    plugin_update_process = @service_source[/Process \{\s*id: pluginUpdateProcess.*?\n  \}/m]
    refute_nil plugin_update_process
    assert_match(/stdout: SplitParser.*stderr: SplitParser/m, plugin_update_process)
  end

  def test_in_plugin_update_restarts_the_shell_after_a_successful_pull
    assert_match(
      /function runPluginUpdateAction\(action\).*command = action === "check".*pluginUpdateCheckPath.*"omarchy", "plugin", "update", root\.moduleName, "--yes"/m,
      @service_source
    )
    assert_match(
      /Process \{\s*id: shellRestartProcess\s*command: \["setsid", "-f", "omarchy", "restart", "shell"\]/m,
      @service_source
    )
    assert_match(
      /exitCode === 0.*shellRestartProcess\.running = true/m,
      @service_source
    )
  end

  def test_secret_and_geometry_safety_contract
    refute_match(/command:\s*\[[^\]]*accessCode/m, @source)
    refute_match(/setting\("(?:accessCode|password|secret)"/, @source)
    refute_match(/(?:accessCode|password|secret)\s*[:=]\s*"12345678"/i, @source)
    assert_includes @source, '"op": "set_secret"'
    assert_includes @settings_source, "password: true"
    assert_includes @settings_source, "maximumLength: 256"
    assert_includes @source, "geometryBundle"
    assert_includes @source, "activeSegmentPath"
    assert_includes @source, "activeSegmentCount"
    assert_includes @source, "BambuGeometryAssembler {"
    assert_includes @geometry_source, "pendingGeometry"
    assert_includes @geometry_source, "geometry_begin"
    assert_includes @geometry_source, "geometry_end"
    assert_includes @geometry_source, "validSegmentPath"
    assert_includes @geometry_source, "required property string segmentDirectory"
    assert_includes @source, "segmentDirectory: root.geometryDirectory"
  end

  def test_actions_require_a_ready_process_and_clear_secret_only_after_accepted_write
    assert_match(/function writeCommand\(command\).*if \(!daemonReady \|\| !sessionProcess\.running\) return false.*try.*sessionProcess\.write.*return true.*catch \(error\).*return false/m,
                 @backend_source)
    assert_match(/function setSecret\(value\).*writeCommand\(\{.*"op": "set_secret"/m,
                 @source)
    assert_match(/function clearSecret\(\).*writeCommand\(\{ "op": "clear_secret" \}\)/m,
                 @source)
    assert_match(/function refreshModel\(\)\s*{\s*writeCommand\(\{ "op": "refresh_model" \}\)\s*}/m,
                 @source)
    assert_match(/onReloadRequested: \{.*selectedViewportSource === "camera".*snapshotCamera\(\).*refreshModel\(\)/m,
                 @dashboard_source)
    assert_match(/BambuModelViewport\s*{.*daemonReady: root\.service\.daemonReady && root\.service\.backendRunning/m,
                 @dashboard_source)
    assert_includes @viewport_source, "enabled: viewport.daemonReady"
  end

  def test_geometry_is_transactional_ordered_and_bounded
    assert_includes @geometry_source, "function clearPending()"
    assert_includes @geometry_source, "function validPreview(preview)"
    assert_includes @geometry_source, "property int maxPreviewBytes: 524288"
    assert_includes @geometry_source, "property int maxPreviewChunkChars: 49152"
    assert_includes @geometry_source,
                    'else if (event === "geometry_preview_chunk") appendPreviewChunk(message, generation)'
    assert_includes @geometry_source, "message.segmentCount > assembler.maxSegments"
    assert_includes @geometry_source, "Object.keys(chunks).length !== expected.length"
    refute_includes @geometry_source, "appendGeometryChunk"
    refute_includes @geometry_source, 'event === "geometry_chunk"'
    refute_includes @source, "function beginGeometry"
  end

  def test_geometry_is_scoped_to_the_generation_announced_by_state
    assert_includes @source, "property alias modelGeneration: geometryAssembler.modelGeneration"
    assert_match(/function handleState\(message\).*var nextGeneration = isNonNegativeInteger\(model\.generation\).*geometryAssembler\.setGeneration\(nextGeneration\)/m,
                 @source)
    assert_includes @source, "geometryAssembler.handleGeometry(message)"
    assert_match(/function handleGeometry\(message\).*if \(!isNonNegativeInteger\(message\.generation\)\) return.*if \(generation !== modelGeneration\) return/m,
                 @geometry_source)
  end

  def test_model_download_progress_is_bounded_reset_and_passed_to_the_viewport
    assert_includes @source, 'property string modelLoadPhase: ""'
    assert_includes @source, "property int modelLoadProgress: -1"
    assert_match(/function handleState\(message\).*modelLoadPhase = String\(model\.loadPhase \|\| ""\).*modelLoadProgress = Math\.max\(-1, Math\.min\(100,.*model\.loadProgress/m,
                 @source)
    assert_match(/function resetOperationalState\(\).*modelLoadPhase = "".*modelLoadProgress = -1.*modelLoadedBytes = 0.*modelTotalBytes = 0/m,
                 @source)
    assert_match(/BambuModelViewport\s*\{.*modelLoadPhase: root\.service\.modelLoadPhase.*modelLoadProgress: root\.service\.modelLoadProgress.*modelLoadedBytes: root\.service\.modelLoadedBytes.*modelTotalBytes: root\.service\.modelTotalBytes/m,
                 @dashboard_source)
  end

  def test_fresh_printer_report_clears_recovered_process_error
    assert_includes @source, 'property string processErrorReportUpdate: ""'
    assert_match(/function reportProcessError\(message, hideInBar\).*processError = String\(message \|\| ""\).*processErrorReportUpdate = processError === "" \? "" : lastUpdate.*processErrorAffectsBar = processError !== "" && hideInBar !== true/m,
                 @source)
    assert_match(/var reportUpdate = String\(printer\.lastUpdate \|\| ""\).*if \(hasFreshReport\) \{.*if \(processError !== "" && reportUpdate !== processErrorReportUpdate\).*reportProcessError\(""\)/m,
                 @service_source)
  end

  def test_geometry_source_selection_uses_only_complete_available_sources
    assert_includes @source,
                    "property alias selectedGeometrySource: geometryAssembler.selectedGeometrySource"
    assert_includes @source, "readonly property bool previewAvailable: geometryAssembler.previewAvailable"
    assert_includes @source, "readonly property bool gcodeGeometryAvailable: geometryAssembler.gcodeAvailable"
    assert_match(/function selectViewportSource\(source\)[\s\S]*source === "camera"[\s\S]*cameraSelectable[\s\S]*selectedViewportSource = "camera"[\s\S]*source !== "gcode" && source !== "preview"[\s\S]*geometryAssembler\.selectSource\(source\)[\s\S]*selectedViewportSource = source/m,
                 @source)
    assert_match(/readonly property bool cameraDesired:[\s\S]*selectedViewportSource === "camera"[\s\S]*cameraSelectable[\s\S]*popupCameraVisible \|\| root\.windowCameraVisible/m,
                 @source)
    assert_match(/function syncCameraSession\(\)[\s\S]*cameraDesired[\s\S]*camera_start[\s\S]*camera_stop/m,
                 @source)
    assert_match(/readonly property string activeSegmentPath:.*geometryBundle\.gcode.*geometry\.path/m,
                 @source)
    assert_match(/segmentValue:\s*root\.service\.activeSegmentCount\.toLocaleString/m,
                 @dashboard_source)
    assert_match(/BambuModelViewport\s*\{[\s\S]*previewAvailable: root\.service\.previewAvailable[\s\S]*gcodeAvailable: root\.service\.gcodeGeometryAvailable[\s\S]*cameraAvailable: root\.service\.cameraSelectable[\s\S]*selectedSource: root\.service\.selectedViewportSource[\s\S]*previewSource: root\.service\.previewAvailable[\s\S]*onSourceRequested: function\(source\)[\s\S]*root\.service\.selectViewportSource\(source\)/m,
                 @dashboard_source)
  end

  def test_state_and_json_line_parsing_are_null_safe
    assert_includes @source, "function objectOrEmpty(value)"
    assert_match(/JSON\.parse.*if \(!message \|\| typeof message !== "object"/m,
                 @source)
    assert_match(/var printer = objectOrEmpty\(message\.printer\)/, @source)
    assert_match(/var model = objectOrEmpty\(message\.model\)/, @source)
  end

  def test_detailed_status_panel_consumes_all_exposed_live_telemetry
    %w[nozzleTargetTemp bedTargetTemp remainingMinutes speedLevel speedMagnitude
       wifiSignal coolingFanSpeed heatbreakFanSpeed lastUpdate].each do |property|
      assert_match(/property\s+\w+\s+#{property}:/, @source)
    end
    %w[nozzleTargetTemp bedTargetTemp remainingMinutes speedLevel speedMagnitude
       wifiSignal coolingFanSpeed heatbreakFanSpeed].each do |field|
      assert_match(/#{field}\s*=.*printer\.#{field}/, @source)
    end
    assert_match(/var reportUpdate = String\(printer\.lastUpdate \|\| ""\).*lastUpdate = reportUpdate/m,
                 @source)
    assert_includes @telemetry_source, 'objectName: "TEMPERATURES"'
    assert_includes @telemetry_source, 'objectName: "PRINT METRICS"'
    assert_includes @telemetry_source, 'objectName: "CONNECTION"'
    assert_includes @telemetry_source, 'objectName: "MODEL DATA"'
  end

  def test_service_formats_dual_nozzle_telemetry
    assert_includes @source, "property var nozzles: []"
    assert_includes @source, "property int activeNozzle: -1"
    assert_match(/function hasDualNozzles\(\).*nozzles\.length >= 2/m,
                 @source)
    assert_match(/function nozzleById\(id\).*nozzleId === id/m, @source)
    assert_match(/nozzleLeftValue:\s*root\.service\.formatNozzle\(0\)/,
                 @dashboard_source)
    assert_match(/nozzleRightValue:\s*root\.service\.formatNozzle\(1\)/,
                 @dashboard_source)
    assert_includes @telemetry_source, 'label: pane.dualNozzles ? "NOZZLE LEFT" : "NOZZLE"'
    assert_includes @telemetry_source, 'label: "NOZZLE RIGHT"'
  end

  def test_active_alert_acknowledgements_are_bounded_and_persisted
    assert_includes @event_store_source, "property var acknowledgedAlertKeys: []"
    assert_includes @event_store_source, "readonly property int maximumAcknowledgedAlerts: 100"
    assert_match(/function markRead\(id\).*acknowledgeAlertKey\(event\.alertKey\)/m,
                 @event_store_source)
    assert_match(/read:\s*store\.isAlertAcknowledged\(key\)/,
                 @event_store_source)
    assert_match(/function persistEventAcknowledgements\(\).*acknowledgedAlerts.*commitSettingsEntry/m,
                 @service_source)
    assert_match(/function refreshSettings\(\).*setAcknowledgedAlertKeys/m,
                 @service_source)
  end

  def test_status_panel_is_landscape_and_reflows_before_it_can_overflow
    assert_match(/contentWidth:\s*fittedContentWidth\(Style\.space\(860\)\)/, @source)
    assert_includes @source, "id: dashboardLayout"
    assert_match(/columns:\s*dashboard\.wideLayout \? 2 : 1/, @source)
    assert_match(/readonly property bool wideLayout:\s*width >= Style\.space\(640\)/,
                 @source)
    assert_includes @source, "id: telemetryPane"
    assert_includes @source, "BambuModelViewport {"
    assert_match(/width:\s*dashboard\.wideLayout\s*\? Style\.space\(300\)\s*:\s*dashboard\.width/m,
                 @source)
    assert_match(/width:\s*dashboard\.wideLayout\s*\? Math\.max\(0, dashboard\.width - telemetryPane\.width\s*- dashboardLayout\.spacing\)\s*:\s*dashboard\.width/m,
                 @source)
  end

  def test_original_printer_svg_is_safe_and_symbolic
    path = File.join(@root, "assets", "printer-open-frame.svg")
    assert File.file?(path), "expected an original printer SVG at #{path}"

    svg = File.read(path)
    root_tag = svg[/\A<svg\b[^>]*>/m]
    refute_nil root_tag
    assert_match(/\bxmlns="http:\/\/www\.w3\.org\/2000\/svg"/, root_tag)
    assert_match(/\bviewBox="0 0 24 24"/, root_tag)
    assert_match(/\bfill="none"/, root_tag)
    assert_match(/\bstroke="#ffffff"/i, root_tag)
    refute_match(/\bstroke="(?:black|#000(?:000)?)"/i, root_tag)
    refute_match(/\bstroke="currentColor"/i, root_tag)
    assert_match(/\bstroke-linecap="round"/, root_tag)
    assert_match(/\bstroke-linejoin="round"/, root_tag)
    assert_match(%r{</svg>\s*\z}, svg)
    paths = svg.scan(/<path\b[^>]*>/m)
    assert_operator paths.length, :>=, 4
    paths.each { |tag| assert_match(%r{/\s*>\z}, tag) }
    refute_match(/<(?:script|text|image|foreignObject)\b/i, svg)
    refute_match(/\b(?:href|xlink:href)\s*=|url\s*\(/i, svg)
    refute_match(/bambu|bbl/i, svg)
  end

  def test_symbolic_printer_icon_participates_in_bar_layout
    assert_includes @printer_icon_source, "import QtQuick.Effects"
    assert_includes @service_source,
                    'readonly property url printerIconSource: Qt.resolvedUrl("assets/printer-open-frame.svg")'
    refute_includes @source, "function isSuccessPrintState"
    refute_includes @source, "barPrintActive"
    assert_match(/readonly property bool barFinishActive: root\.connected && !root\.stale\s*&& root\.isFinishedState\(root\.displayGcodeState\)/m,
                 @service_source)
    assert_match(/readonly property color printerIconColor: !root\.service \? root\.foreground\s*: \(root\.service\.barErrorActive \? root\.errorColor\s*: \(root\.service\.barFinishActive \? root\.successColor : root\.foreground\)\)/m,
                 @widget_source)
    assert_match(/Image\s*{.*id: sourceImage.*source: icon\.source.*visible: false.*layer\.enabled: true/m,
                 @printer_icon_source)
    assert_match(/MultiEffect\s*{.*source: sourceImage.*colorization: 1\.0.*colorizationColor: icon\.tintColor/m,
                 @printer_icon_source)
    assert_match(/WidgetButton\s*{.*id: button.*text: "".*labelVisible: false.*hasVisualContent: true.*fixedWidth: root\.vertical \? barSize\s*: buttonContent\.implicitWidth \+ scaledHorizontalMargin \* 2.*fixedHeight: barSize/m,
                 @widget_source)
    assert_match(/Row\s*{.*id: buttonContent.*height: button\.fixedHeight.*BambuPrinterIcon\s*{.*anchors\.verticalCenter: parent\.verticalCenter.*tintColor: root\.printerIconColor.*Text\s*{.*height: parent\.height.*verticalAlignment: Text\.AlignVCenter.*visible: !root\.vertical.*text: root\.compactLabel\(\)/m,
                 @widget_source)
    assert_operator @source.scan("BambuPrinterIcon {").length, :>=, 2
    refute_includes @source, "󰐫"
  end


  def test_status_identity_and_error_semantics_are_visually_explicit
    assert_match(/property color errorColor:/, @telemetry_source)
    assert_includes @telemetry_source, "property bool errorActive: false"
    assert_includes @telemetry_source, "property bool modelErrorActive: false"
    assert_match(/Column\s*{\s*id: telemetryContent.*Text\s*{.*pane\.demoActive \? "◆ DEMO".*pane\.online \? "● ONLINE" : "○ OFFLINE".*Row\s*{.*SidebarPrinterIcon\s*{.*anchors\.verticalCenter: parent\.verticalCenter.*Text\s*{\s*id: printerNameText.*verticalAlignment: Text\.AlignVCenter/m,
                 @telemetry_source)
    assert_match(/text: \(pane\.demoActive \? "◆ DEMO".*color: pane\.demoActive \? pane\.accent.*pane\.errorActive \? pane\.errorColor/m,
                 @telemetry_source)
    assert_match(/text: \(pane\.demoActive \? "◆ DEMO".*pane\.online \? pane\.successColor : pane\.dim/m,
                 @telemetry_source)
    assert_match(/function printerHasError\(\).*state === "ERROR".*state === "FAILED"/m,
                 @source)
    assert_match(/printerState: root\.service\.displayGcodeState/, @dashboard_source)
    assert_match(/label: "STATUS"; value: pane\.modelState; valueColor: \(pane\.errorActive \|\| pane\.modelErrorActive\) \? pane\.errorColor/m,
                 @telemetry_source)

    assert_includes @dashboard_source, 'readonly property color errorColor: "#ff5f56"'
    assert_includes @dashboard_source, 'readonly property color successColor: "#39FF88"'
    assert_match(/readonly property bool errorActive: root\.printerHasError\(\)\s*\|\| root\.activePrinterErrorCount > 0\s*\|\| root\.processError !== ""/m,
                 @service_source)
    assert_match(/readonly property bool barErrorActive: root\.printerHasError\(\)\s*\|\| root\.activePrinterErrorCount > 0 \|\| root\.unreadErrorCount > 0\s*\|\| root\.processErrorAffectsBar/m,
                 @service_source)
    assert_match(/reportProcessError\(message\.message,\s*message\.scope === "mqtt" && message\.code === "connection"\)/m,
                 @service_source)
    global_error_definition = @service_source[
      /readonly property bool errorActive:.*?(?=\n  readonly property)/m
    ]
    refute_nil global_error_definition
    refute_includes global_error_definition, "modelStatus"
    assert_includes @service_source,
                    'readonly property bool modelErrorActive: root.modelStatus === "error"'
    assert_match(/BambuTelemetryPane\s*{.*errorColor: root\.errorColor.*errorActive: root\.service\.errorActive.*modelErrorActive: root\.service\.modelErrorActive/m,
                 @dashboard_source)
    assert_match(/BambuTelemetryPane\s*{.*successColor: root\.successColor/m,
                 @dashboard_source)
    assert_match(/BambuModelViewport\s*{.*errorColor: root\.errorColor.*errorActive: root\.service\.errorActive \|\| root\.service\.modelErrorActive.*printing: root\.service\.demoActive\s*\|\| \(root\.service\.connected && root\.service\.gcodeState === "RUNNING"\)/m,
                 @dashboard_source)
    assert_match(/BambuSettingsView\s*{.*errorColor: root\.errorColor/m,
                 @dashboard_source)
    assert_match(/text: root\.service\.processError \|\| "Waiting for a fresh printer report…".*color: root\.service\.processError \? root\.errorColor : root\.dim/m,
                 @dashboard_source)
    assert_match(/text: form\.validationError\s*color: form\.errorColor/m,
                 @settings_source)
  end

  def test_vertical_bar_is_icon_only
    assert_match(/function statusSummary\(separator\).*if \(!root\.hasConnectionTarget\) return "SETUP".*if \(!root\.printerStateKnown\) return "CONNECTING".*if \(root\.barErrorActive\) return "ERROR".*if \(!root\.connected\) return "OFFLINE"/m,
                 @service_source)
    refute_includes @service_source, 'return "WAIT"'
    assert_match(/Text\s*{.*height: parent\.height.*verticalAlignment: Text\.AlignVCenter.*visible: !root\.vertical && \(!root\.service \|\| root\.service\.showBarSummary\)\s*width: Math\.min\(implicitWidth, Style\.space\(220\)\)\s*text: root\.compactLabel\(\)/m,
                 @widget_source)
    assert_match(/formatTemp\(root\.nozzleTemp\).*formatTemp\(root\.bedTemp\)/m,
                 @service_source)
    assert_match(/function compactLabel\(\).*service\.statusSummary\(" "\).*function tooltipText\(\).*service\.statusSummary\(" · "\)/m,
                 @widget_source)
  end


  def test_event_history_is_live_bounded_and_tracks_print_transitions
    assert_includes @service_source, "BambuEventStore {"
    assert_includes @service_source, "property alias eventHistory: eventStore.events"
    assert_match(/function startDemo\(\).*root\.demoActive = true\s*eventStore\.loadDemoEvents\(\).*"op": "start_demo"/m,
                 @service_source)
    assert_match(/function resetDemoState\(\)\s*{\s*eventStore\.clearDemoEvents\(\)/m,
                 @service_source)
    refute_match(/Component\.onCompleted:.*loadDemoEvents/m, @service_source)
    assert_match(
      /function handleState\(message\).*if \(hasFreshReport\) \{.*eventStore\.recordPrintTransition\(.*acknowledgementsBefore.*eventStore\.reconcileAlerts\(printer\.alerts.*persistEventAcknowledgements\(\).*\}/m,
      @service_source
    )
    assert_includes @event_store_source, "readonly property int maximumEvents: 200"
    transition = @event_store_source[/function recordPrintTransition\(.*?\n  }/m]
    refute_nil transition
    %w[started resumed paused completed failed].each do |state|
      assert_includes transition, "Print #{state}"
    end
    assert_match(/function appendEvent\(values\).*updated\.slice\(0, store\.maximumEvents\)/m,
                 @event_store_source)
  end

  def test_printer_alerts_have_distinct_error_and_maintenance_semantics
    assert_match(/var severity = String\(alert\.kind \|\| "warning"\) === "error" \? "error" : "warning"/,
                 @event_store_source)
    assert_match(/readonly property bool errorActive: root\.printerHasError\(\).*root\.activePrinterErrorCount > 0/m,
                 @service_source)
    error_definitions = @service_source[/readonly property bool errorActive:.*?readonly property bool modelErrorActive:/m]
    refute_nil error_definitions
    refute_includes error_definitions, "activePrinterWarningCount"
    assert_match(/unreadWarningCount: root\.service\.unreadWarningCount/m,
                 @dashboard_source)
    assert_match(/eventColor: root\.unreadErrorCount > 0 \? root\.errorColor\s*: root\.unreadWarningCount > 0 \? root\.warningColor\s*: root\.active \? root\.accent : root\.foreground/m,
                 @event_button_source)
    refute_includes @source, "activePrinterWarningCount"
    refute_includes @source, "eventWarningActive"
  end

  def test_event_notifications_support_read_all_click_and_half_second_hover_read
    assert_match(/function markRead\(id\)/, @event_store_source)
    assert_match(/function markAllRead\(\)/, @event_store_source)
    assert_match(/text: "READ ALL".*onClicked:.*history\.service\.markAllEventsRead\(\)/m,
                 @event_history_source)
    assert_match(/Timer \{\s*interval: 500\s*repeat: false\s*running: eventMouse\.containsMouse && !eventDelegate\.modelData\.read\s*onTriggered:.*history\.service\.markEventRead/m,
                 @event_history_source)
    assert_match(/onClicked: history\.openEvent\(eventDelegate\.modelData\)/,
                 @event_history_source)
    assert_includes @event_history_source, 'property string logFontFamily: "monospace"'
    assert_match(/id: logTime.*width: implicitWidth.*history\.formatTimestamp\(eventDelegate\.modelData\.timestamp, false\)/m,
                 @event_history_source)
    assert_match(/id: logLevel.*width: implicitWidth.*history\.eventLevel\(eventDelegate\.modelData\)/m,
                 @event_history_source)
    assert_match(/id: logChannel.*width: implicitWidth.*history\.eventChannel\(eventDelegate\.modelData\)/m,
                 @event_history_source)
    assert_match(/anchors\.left: logChannel\.right.*history\.eventMessage\(eventDelegate\.modelData\)/m,
                 @event_history_source)
  end

  def test_event_button_moved_from_telemetry_to_viewport_source_rail
    refute_includes @telemetry_source, "BambuEventButton"
    assert_match(
      /BambuModelViewport\s*{.*eventsActive: root\.viewMode === "events".*unreadEventCount: root\.service\.unreadEventCount.*unreadErrorCount: root\.service\.unreadErrorCount.*unreadWarningCount: root\.service\.unreadWarningCount.*onEventsRequested: root\.toggleEvents\(\)/m,
      @dashboard_source
    )
    assert_match(/iconSource:.*assets\/list-restart\.svg.*BambuButton\s*{.*text: "".*width: Style\.space\(5\)/m,
                 @event_button_source)
  end

  def test_unread_errors_pulse_and_take_over_the_optional_bar_summary
    assert_match(/SequentialAnimation on opacity \{\s*running: root\.unreadErrorCount > 0\s*loops: Animation\.Infinite/m,
                 @event_button_source)
    assert_match(/unreadErrorCount: root\.service\.unreadErrorCount/,
                 @dashboard_source)
    assert_match(/readonly property bool barErrorActive:.*root\.unreadErrorCount > 0/m,
                 @service_source)
    refute_includes @source, "eventErrorAttention"
    assert_match(/function statusSummary\(separator\).*if \(root\.barErrorActive\) return "ERROR"/m,
                 @service_source)
    assert_match(/visible: !root\.vertical && \(!root\.service \|\| root\.service\.showBarSummary\)/,
                 @widget_source)
  end

  def test_event_details_open_inside_the_dashboard_overlay
    assert_match(/BambuEventHistory \{\s*visible: root\.viewMode === "events".*width: dashboard\.overlayWidth.*height: dashboard\.overlayHeight/m,
                 @dashboard_source)
    assert_includes @event_history_source, 'text: "LOG RECORD"'
    %w[TIMELINE CONTEXT].each do |section|
      assert_includes @event_history_source, "title: \"#{section}\""
    end
    assert_includes @event_history_source, 'title: "RAW EVENT"'
    refute_includes @event_history_source, "Qt.openUrlExternally"
    refute_includes @source, "supportUrl"
  end

  def test_overlay_navigation_uses_explicit_back_buttons
    assert_match(/id: historyHeader.*height: Style\.space\(36\).*BambuButton\s*{\s*anchors\.left: parent\.left.*text: "BACK".*onClicked: history\.closeRequested\(\).*Text\s*{\s*anchors\.centerIn: parent\s*text: "PRINTER EVENT LOG".*BambuButton\s*{\s*anchors\.right: parent\.right.*text: "READ ALL"/m,
                 @event_history_source)
    assert_match(/id: detailsHeader.*height: Style\.space\(36\).*BambuButton\s*{\s*anchors\.left: parent\.left.*text: "BACK".*tooltipText: "BACK TO EVENT LOG".*onClicked: history\.closeDetails\(\).*Text\s*{\s*anchors\.centerIn: parent\s*text: "LOG RECORD"/m,
                 @event_history_source)
    assert_equal 2, @event_history_source.scan('text: "BACK"').length
    assert_match(/id: settingsHeader.*height: Style\.space\(36\).*BambuButton\s*{\s*visible: form\.allowBack.*anchors\.left: parent\.left.*text: "BACK".*onClicked: form\.backRequested\(\).*Text\s*{\s*anchors\.centerIn: parent\s*text: "SETTINGS"/m,
                 @settings_source)
    refute_includes @event_history_source, "BambuCloseButton"
    refute_includes @settings_source, "BambuCloseButton"
  end

  def test_key_catcher_uses_the_panels_inset_content_area
    assert_match(/PanelKeyCatcher\s*{.*anchors\.fill: parent.*clip: true/m, @source)
    refute_match(/PanelKeyCatcher\s*{.*width: panel\.contentWidth/m, @source)
    refute_match(/PanelKeyCatcher\s*{.*height: panel\.contentHeight/m, @source)
  end

  def test_panel_views_stay_inside_horizontal_margins
    assert_match(/contentWidth:\s*(?:panel\.)?fittedContentWidth\(Style\.space\(860\)\)/m,
                 @source)
    assert_match(/contentHeight:\s*(?:panel\.)?fittedContentHeight\(dashboard\.preferredViewportHeight\)/m,
                 @source)
    assert_match(/preferredViewportHeight:\s*Math\.max\(Style\.space\(520\), telemetryPane\.implicitHeight\)/m,
                 @dashboard_source)
    assert_match(/implicitHeight: telemetryContent\.implicitHeight \+ pane\.inset \* 2\s*\+ Style\.space\(8\) \+ actionRow\.height/m,
                 @telemetry_source)
    assert_match(/Flickable\s*{.*id: panelScroll.*flickableDirection: Flickable\.VerticalFlick.*clip: true/m,
                 @source)
    assert_match(/BambuTelemetryPane\s*{.*id: telemetryPane.*onSettingsRequested: root\.toggleSettings\(\)/m,
                 @source)
    assert_match(/BambuSettingsView\s*{.*width: dashboard\.overlayWidth.*height: dashboard\.overlayHeight/m,
                 @source)
    refute_match(/parent\.width - Style\.bar\.iconCanvas/m, @source)
  end

  def test_keyboard_panel_has_a_themed_content_backdrop_for_quickshell_composition
    assert_match(/KeyboardPanel\s*{.*padding:\s*0/m, @source)
    assert_match(/PanelKeyCatcher\s*{.*Rectangle\s*{\s*id: panelBackdrop\s*anchors\.fill: parent\s*readonly property color baseColor: bambuStyle\.popupBackground\s*color: Qt\.rgba\(\s*baseColor\.r \* 0\.94 \+ root\.foreground\.r \* 0\.06,.*1\.0\)/m,
                 @source)
  end

  def test_manifest_exposes_only_non_secret_widget_settings
    settings = @widget_schema.map { |entry| entry.fetch("key") }

    assert_equal %w[printerName host mqttPort ftpsPort serial username maxSegments explosionFactor autoRotate showBarSummary
                    mqttTlsFingerprint ftpsTlsFingerprint], settings
    refute(settings.any? { |key| key.match?(/access|code|password|secret/i) })
    settings.each { |key| assert_includes @source, "setting(\"#{key}\"," }
  end

  def test_qml_setting_fallbacks_match_manifest_defaults
    @widget_defaults.each do |key, value|
      literal = value.is_a?(String) ? value.inspect : value.to_s
      assert_includes @source, "setting(\"#{key}\", #{literal})"
    end
  end

  def test_blank_legacy_printer_name_uses_the_generic_default
    assert_match(/readonly property string displayName:.*return name \|\| "3D Printer"/m,
                 @source)
  end
  def test_visual_accent_always_uses_the_live_theme_accent
    sources = @source + @telemetry_source
    sources += File.read(File.join(@root, "BambuModelViewport.qml"))

    assert_match(/readonly property color accent: Color\.accent/, @source)
    assert_match(/BambuTelemetryPane\s*\{.*accent: root\.accent/m, @source)
    assert_match(/BambuModelViewport\s*\{.*accent: root\.accent/m, @source)
    refute_match(/\bneon\b/, sources)
  end

  def test_printer_states_use_semantic_colors_not_the_user_accent
    assert_match(/fixedHeight: barSize\s*foreground: root\.foreground/, @source)
    assert_match(/text: root\.compactLabel\(\)\s*color: root\.foreground/, @source)
    refute_match(/text: root\.compactLabel\(\)\s*color: root\.printerIconColor/,
                 @source)
    assert_match(/width: Math\.max\(0, \(parent\.width - 4\) \* pane\.percent \/ 100\)\s*color: pane\.accent/m,
                 @telemetry_source)
    assert_match(/text: pane\.percent \+ "% COMPLETE"\s*color: pane\.accent/m,
                 @telemetry_source)
    assert_match(/label: "Z HEIGHT"; value: pane\.zValue; valueColor: pane\.accent/,
                 @telemetry_source)
    assert_match(/label: "WI-FI"; value: pane\.wifiValue; valueColor: pane\.accent/,
                 @telemetry_source)
    assert_match(/label: "STATUS"; value: pane\.modelState; valueColor: \(pane\.errorActive \|\| pane\.modelErrorActive\) \? pane\.errorColor : \(pane\.modelState === "READY" \? pane\.successColor : pane\.foreground\)/,
                 @telemetry_source)
    refute_match(/root\.gcodeState === "RUNNING" \? root\.accent/,
                 @source + @telemetry_source)
  end

  def test_panel_identity_uses_the_fixed_foreground_color
    assert_match(/colorizationColor: pane\.foreground/, @telemetry_source)
    assert_match(/id: printerNameText.*color: pane\.foreground/m,
                 @telemetry_source)
  end

  def test_explosion_factor_is_a_local_persisted_view_preference
    explode_schema = @widget_schema.find { |entry| entry["key"] == "explosionFactor" }

    assert_equal 100, @widget_defaults["explosionFactor"]
    assert_equal "integer", explode_schema&.fetch("type")
    assert_equal 0, explode_schema&.fetch("min")
    assert_equal 500, explode_schema&.fetch("max")
    assert_match(/readonly property int explosionFactor: Math\.max\(0, Math\.min\(500,\s*Math\.round\(finiteNumber\(Number\(setting\("explosionFactor", 100\)\), 100\)\)\)\)/m,
                 @source)
    assert_match(/function settingsDraft\(\).*explosionFactor: root\.explosionFactor/m,
                 @source)
    assert_match(/function persistSettings\(draft\).*entry\.explosionFactor = draft\.explosionFactor/m,
                 @source)
    assert_match(/BambuModelViewport\s*\{.*explosionFactor: root\.service\.explosionFactor/m,
                 @dashboard_source)

    assert_local_only("explosionFactor")
  end

  def test_auto_rotate_default_is_a_local_persisted_view_preference
    rotate_schema = @widget_schema.find { |entry| entry["key"] == "autoRotate" }

    assert_equal true, @widget_defaults["autoRotate"]
    assert_equal "boolean", rotate_schema&.fetch("type")
    assert_includes @source, 'setting("autoRotate", true) !== false'
    assert_match(/function settingsDraft\(\).*autoRotate: root\.autoRotate/m,
                 @source)
    assert_match(/function persistSettings\(draft\).*entry\.autoRotate = draft\.autoRotate/m,
                 @source)
    assert_match(/BambuModelViewport\s*\{.*autoRotateDefault: root\.service\.autoRotate/m,
                 @dashboard_source)

    assert_local_only("autoRotate")
  end

  def test_bar_summary_setting_hides_only_the_horizontal_recap
    assert_equal true, @widget_defaults["showBarSummary"]
    summary_schema = @widget_schema.find { |entry| entry["key"] == "showBarSummary" }
    assert_equal "boolean", summary_schema&.fetch("type")
    assert_includes @source, 'readonly property bool showBarSummary: setting("showBarSummary", true) !== false'
    assert_match(/function settingsDraft\(\).*showBarSummary: root\.showBarSummary/m, @source)
    assert_match(/function persistSettings\(draft\).*entry\.showBarSummary = draft\.showBarSummary/m,
                 @source)
    assert_match(/Text\s*\{.*visible: !root\.vertical && \(!root\.service \|\| root\.service\.showBarSummary\).*text: root\.compactLabel\(\)/m,
                 @widget_source)
    assert_match(/BambuPrinterIcon\s*\{\s*anchors\.verticalCenter: parent\.verticalCenter/m,
                 @widget_source)
  end

  private

  def assert_local_only(key)
    %w[backendSettingsChanged configuration configurationForDraft].each do |name|
      body = @source[/function #{name}\([^)]*\) \{.*?\n  \}/m]
      refute_nil body
      refute_includes body, key
    end
  end
end
