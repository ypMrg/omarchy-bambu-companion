# frozen_string_literal: true

require_relative "test_helper"
require "json"

class QmlSettingsContractTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
    @path = File.join(@root, "BambuSettingsView.qml")
  end

  def application_source
    %w[BambuService.qml BambuDashboard.qml BambuWidget.qml].map do |name|
      File.read(File.join(@root, name))
    end.join("\n")
  end

  def service_source
    File.read(File.join(@root, "BambuService.qml"))
  end

  def dashboard_source
    File.read(File.join(@root, "BambuDashboard.qml"))
  end

  def widget_source
    File.read(File.join(@root, "BambuWidget.qml"))
  end

  def test_dedicated_component_exposes_a_small_parent_interface
    source = settings_source

    assert_includes source, "signal backRequested()"
    assert_includes source, "signal saveRequested(var draft, string accessCode)"
    assert_includes source, "property bool allowBack: true"
    assert_includes source, "property bool requireAccessCode: false"
    assert_includes source, "property bool canDisconnect: false"
    assert_includes source, 'text: "SETTINGS"'
    refute_includes source, "OMARCHY QUATTRO // CONFIG"
    assert_includes source, "signal forgetCodeRequested()"
    assert_includes source, "signal inputFocusReleased()"
    assert_includes source, "signal trustRequested(var draft, string accessCode)"
    assert_includes source, "signal disconnectRequested()"
    assert_includes source, "function load(draft)"
    assert_includes source, "function clearAccessCode()"
    assert_includes source, "readonly property bool inputActive:"
    assert_match(/Keys\.onEscapePressed:.*inputFocusReleased\(\)/m, source)
  end

  def test_security_dialog_is_centered_bounded_and_modal
    path = File.join(@root, "BambuSecurityDialog.qml")

    assert File.exist?(path), "BambuSecurityDialog.qml must exist"
    source = File.read(path)
    assert_includes source, 'property string mode: ""'
    assert_includes source, "property bool probing: false"
    assert_includes source, "property bool processing: false"
    assert_includes source, "signal cancelRequested()"
    assert_includes source, "signal trustRequested()"
    assert_includes source, "signal disconnectRequested()"
    assert_match(/Keys\.onEscapePressed:.*cancelRequested\(\).*event\.accepted = true/m,
                 source)
    assert_match(/MouseArea\s*{\s*anchors\.fill: parent.*onClicked:.*dialog\.cancelRequested\(\)/m,
                 source)
    assert_match(/Rectangle\s*{\s*anchors\.centerIn: parent.*width: Math\.min\(.*parent\.width.*height: Math\.min\(.*parent\.height/m,
                 source)
    assert_match(/id: dialogBody.*Flickable\.VerticalFlick.*clip: true/m, source)
    assert_match(/Rectangle\s*{\s*anchors\.centerIn: parent.*MouseArea\s*{\s*anchors\.fill: parent.*onClicked: function\(mouse\).*mouse\.accepted = true/m,
                 source)
    assert_includes source,
                    'text: dialog.certificateMode ? "TRUST & CONNECT" : "DISCONNECT"'
    assert_includes source, "identity: dialog.mqttIdentity"
    assert_includes source, "identity: dialog.ftpsIdentity"
    assert_match(/Keys\.onEscapePressed:.*if \(!dialog\.processing\) cancelRequested\(\)/m,
                 source)
    assert_match(/MouseArea\s*{\s*anchors\.fill: parent.*if \(!dialog\.processing\) dialog\.cancelRequested\(\)/m,
                 source)
    assert_match(/id: actionButton.*visible: !dialog\.probing && !dialog\.processing/m,
                 source)
  end

  def test_tls_identity_requires_an_explicit_trust_action
    settings = settings_source
    widget = application_source

    refute_includes settings, "tlsIdentityPanel"
    refute_includes settings, 'text: "PRINTER CERTIFICATE"'
    assert_match(/trustCertificate === true.*trustRequested\(draft, String\(accessCodeInput\.text \|\| ""\)\)/m,
                 settings)

    assert_includes widget, 'property string mqttTlsFingerprint:'
    assert_includes widget, 'property string ftpsTlsFingerprint:'
    assert_match(/function beginTlsProbe\(draft\).*"op": "probe_tls".*"requestId":.*"config":/m,
                 widget)
    probe_body = widget[/function beginTlsProbe\(draft\) \{.*?\n  \}/m]
    refute_nil probe_body
    refute_match(/accessCode|password|secret/i, probe_body)
    assert_match(/message\.event === "tls_identity".*tlsApprovalRequired = true/m,
                 widget)
    assert_match(/function trustAndConnect\(draft, accessCode\).*mqttTlsFingerprint.*ftpsTlsFingerprint.*persistSettings/m,
                 widget)
    assert_match(/BambuSecurityDialog\s*\{.*mode: root\.service\.securityModalMode.*onTrustRequested: settingsView\.submit\(true\)/m,
                 widget)
  end

  def test_tls_identity_rows_share_one_bounded_presentation_component
    source = File.read(File.join(@root, "BambuSecurityDialog.qml"))
    component = source[/component IdentityBlock: Column \{.*?\n  \}\n\n  Rectangle/m]
    instances = source.scan(/^\s{8}IdentityBlock \{.*?^\s{8}\}/m)

    refute_nil component
    assert_includes component, "required property var identity"
    assert_includes component, "required property string title"
    assert_includes component, "width: parent ? parent.width : implicitWidth"
    assert_includes component, "dialog.tlsFingerprint(parent.identity)"
    assert_includes component, "dialog.tlsDescription(parent.identity)"
    assert_equal 2, instances.length
    assert_includes instances.fetch(0), "identity: dialog.mqttIdentity"
    assert_includes instances.fetch(0),
                    'title: dialog.sharedTlsCertificate ? "MQTT + FTPS" : "MQTT"'
    assert_includes instances.fetch(1),
                    "visible: dialog.certificateMode && !dialog.probing"
    assert_includes instances.fetch(1), "identity: dialog.ftpsIdentity"
    assert_includes instances.fetch(1), 'title: "FTPS"'
  end

  def test_unpinned_or_rejected_certificate_requires_probe_without_forcing_initial_setup
    source = application_source

    assert_includes source, "readonly property bool hasTrustedTlsPins:"
    assert_equal "readonly property bool requiresInitialSetup: !root.hasConnectionTarget",
                 source[/readonly property bool requiresInitialSetup:[^\n]*/]
    assert_match(/function saveSettings\(draft, accessCode\).*requiresTlsProbe\(draft\).*beginTlsProbe\(draft\).*return/m,
                 source)
    assert_match(/message\.scope === "tls".*message\.code === "certificate_changed".*handleTlsMismatch/m,
                 source)
    refute_match(/message\.event === "tls_identity".*persistSettings/m, source)
  end

  def test_repeated_ftps_mismatch_does_not_reload_the_form_while_user_reapproves
    source = application_source
    body = source[/function handleTlsMismatch\(message\) \{.*?\n  \}/m]

    refute_nil body
    assert_includes body, "if (root.tlsRejected) return"
  end

  def test_editing_the_target_after_a_probe_discards_the_stale_approval
    source = application_source
    body = source[/function trustAndConnect\(draft, accessCode\) \{.*?\n  \}/m]

    refute_nil body
    assert_includes body,
                    "root.tlsTarget(draft) !== root.tlsTarget(root.pendingTlsDraft)"
    assert_operator body.index("clearTlsProbeState()"), :<,
                    body.index("saveSettings(draft, accessCode)")
  end

  def test_runtime_reset_cancels_transient_certificate_probe_state
    source = application_source
    helper = source[/function clearTlsProbeState\(\) \{.*?\n  \}/m]
    reset = source[/function resetOperationalState\(\) \{.*?\n  \}/m]

    refute_nil helper
    assert_includes helper, "tlsProbePending = false"
    assert_includes helper, "tlsApprovalRequired = false"
    assert_includes helper, "mqttTlsIdentity = ({})"
    assert_includes helper, "ftpsTlsIdentity = ({})"
    assert_includes helper, "pendingTlsDraft = ({})"
    refute_includes helper, "tlsRejected = false"
    assert_includes reset, "clearTlsProbeState()"
    assert_operator source.scan("clearTlsProbeState()").length, :>=, 5
  end

  def test_secret_status_is_explicit_and_replacement_never_reads_the_saved_code
    source = settings_source

    assert_includes source, '"● CODE SAVED IN GNOME KEYRING"'
    assert_includes source, '"● CODE ACTIVE FOR THIS SESSION"'
    assert_includes source, '"○ NO LAN CODE SAVED"'
    assert_includes source, '"Leave blank to keep the current code"'
    assert_includes source, "password: true"
    assert_includes source, "maximumLength: 256"
    assert_match(/saveRequested\(draft, String\(accessCodeInput\.text \|\| ""\)\)/, source)
    refute_match(/accessCodeInput\.text\s*=\s*(?:root\.)?(?:secret|accessCode)/, source)
  end

  def test_address_is_free_form_while_ports_are_bounded
    source = settings_source

    assert_match(/var nextHost = String\(hostInput\.text \|\| ""\)\.trim\(\)/, source)
    assert_match(/nextHost\.length > 255/, source)
    assert_match(%r{/\[\\x00-\\x1f\\x7f\]/\.test\(nextHost\)}, source)
    refute_match(/(?:IPv4|IPv6|ipAddress|octet).*test\(nextHost\)/i, source)
    assert_match(/function parseInteger\(text, label, minimum, maximum\).*number < minimum \|\| number > maximum.*label \+ " must be between " \+ minimum \+ " and " \+ maximum/m,
                 source)
    assert_match(/parseInteger\(mqttPortInput\.text, "MQTT port", 1, 65535\)/,
                 source)
    assert_match(/parseInteger\(ftpsPortInput\.text, "FTPS port", 1, 65535\)/,
                 source)
    assert_match(/!\/\^\\d\+\$\/\.test\(raw\)/, source)
  end

  def test_form_is_sectionless_and_uses_a_logical_field_order
    source = settings_source

    refute_includes source, "advancedOpen"
    refute_includes source, "component DrawerSection"
    refute_includes source, 'objectName: "NETWORK"'
    refute_includes source, 'objectName: "ADVANCED"'
    ids = %w[printerNameInput hostInput serialInput mqttPortInput ftpsPortInput
             usernameInput accessCodeInput maxSegmentsInput explosionFactorInput]
    ids.each do |id|
      assert_match(/id:\s*#{Regexp.escape(id)}\b/, source)
    end
    positions = ids.map { |id| source.index("id: #{id}") }
    assert_equal positions.sort, positions
    assert_match(/id: networkGrid.*id: mqttPortInput.*id: ftpsPortInput.*id: usernameInput/m,
                 source)
    assert_match(/function load\(draft\).*usernameInput\.text = String\(values\.username \|\| "bblp"\)/m,
                 source)
    assert_match(/id: usernameInput.*placeholderText: "bblp"/m, source)
    refute_includes source, "demoToggle"
    refute_match(/demoMode|Offline demo/i, source)
    assert_match(/id:\s*serialInput\b/, source)
    assert_match(/parseInteger\(\s*maxSegmentsInput\.text, "Wireframe limit", 1000, 1000000\)/,
                 source)
    assert_match(/id: maxSegmentsInput.*maximumLength: 7.*inputMethodHints: Qt\.ImhDigitsOnly/m,
                 source)
    assert_match(/parseInteger\(\s*explosionFactorInput\.text, "Explode factor", 0, 500\)/,
                 source)
    assert_match(/explosionFactor:\s*nextExplosionFactor/, source)
    assert_match(/function load\(draft\).*printerNameInput\.text = String\(values\.printerName \|\| "3D Printer"\)/m,
                 source)
  end

  def test_settings_copy_and_controls_are_width_bound
    source = settings_source

    assert_match(/import QtQuick\s+import QtQuick\.Controls/, source)
    assert_includes source, "clip: true"
    assert_match(/id: settingsScroll\s*anchors\.left: parent\.left\s*anchors\.right: parent\.right.*contentHeight: settingsContent\.implicitHeight/m,
                 source)
    assert_match(/ScrollBar\.vertical: ScrollBar \{\s*policy: settingsScroll\.interactive\s*\? ScrollBar\.AlwaysOn : ScrollBar\.AlwaysOff\s*\}/m,
                 source)
    assert_match(/id: settingsHeader\s*anchors\.left: parent\.left\s*anchors\.right: parent\.right.*BambuButton\s*\{\s*visible: form\.allowBack.*anchors\.left: parent\.left.*width: Style\.space\(64\).*text: "BACK".*tooltipText: "BACK TO PRINTER".*Text\s*\{\s*anchors\.centerIn: parent\s*text: "SETTINGS"/m,
                 source)
    refute_includes source, 'text: "×"'
    assert_match(/BambuTextField\s*\{.*id: hostInput/m, source)
    assert_match(/BambuButton\s*\{\s*visible: form\.allowBack.*text: "BACK"/m, source)
    assert_match(/component FieldLabel: Text \{.*width: parent \? parent\.width : implicitWidth/m, source)
    assert_includes source, "wrapMode: Text.Wrap"
    assert_match(/form\.secretRequired \? "○ NO LAN CODE SAVED"/m, source)
    assert_match(/id: networkGrid\s*width: parent\.width.*columns: width >= Style\.space\(420\) \? 3 : \(width >= Style\.space\(260\) \? 2 : 1\).*readonly property real cellWidth:/m,
                 source)
    assert_operator source.scan(/TextField\s*\{.*?clip: true/m).length, :>=, 7
    assert_match(/Row\s*{\s*width: parent\.width.*id: accessCodeInput.*id: forgetCodeInline.*text: "FORGET CODE"/m,
                 source)
    assert_match(/id: preferencesGrid.*id: maxSegmentsInput.*id: explosionFactorInput.*text: "AUTO-ROTATE BY DEFAULT"/m,
                 source)
    assert_match(/id: preferencesGrid.*text: "BAR SUMMARY"/m,
                 source)
    assert_match(/id: settingsFooter.*Row\s*\{.*BambuButton\s*\{.*form\.demoActive \? "EXIT DEMO" : "TRY DEMO".*"DISCONNECT PRINTER".*BambuButton\s*\{.*text: "SAVE & CONNECT"/m,
                 source)
    refute_match(/id: settingsFooter.*ToggleSwitch/m, source)
    refute_match(/parent\.width - \(form\.allowBack \? parent\.spacing \+ Style\.space\(70\) : 0\)/m, source)
  end

  def test_widget_forces_only_initial_setup_and_accepts_an_offline_snapshot
    service = service_source
    dashboard = dashboard_source

    assert_includes service, "property bool printerStateKnown: false"
    assert_match(/function nextIdleView\(\).*root\.service\.requiresInitialSetup.*return "setup".*root\.service\.printerStateKnown.*return "status".*return "connecting"/m,
                 dashboard)
    assert_match(/function handleState\(message\).*var stateWasUnknown = !root\.printerStateKnown.*printerStateKnown = true.*connected = printer\.connected === true.*if \(stateWasUnknown\) root\.statusAvailable\(\)/m,
                 service)
    assert_match(/function resetOperationalState\(\).*printerStateKnown = false/m,
                 service)
    assert_match(/Component\.onCompleted:.*componentReady = true.*viewMode = root\.nextIdleView\(\)/m,
                 dashboard)
    assert_match(/function onStatusAvailable\(\).*viewMode === "connecting".*viewMode = "status"/m,
                 dashboard)
    assert_match(/function onPrinterStateKnownChanged\(\).*printerStateKnown.*viewMode === "connecting".*viewMode = "status"/m,
                 dashboard)
    assert_match(/function applyOperationResult\(.*response\.mode === "connecting" && root\.service\.printerStateKnown.*viewMode = "status"/m,
                 dashboard)
    assert_match(/function backToStatus\(\).*!root\.service\.demoActive && !root\.service\.requiresInitialSetup.*!root\.service\.printerStateKnown.*enterConnecting\(\).*return.*viewMode = "status"/m,
                 dashboard)
  end

  def test_forced_first_run_setup_remains_dismissible
    widget = widget_source
    dashboard = dashboard_source
    close_function = widget[/function close\(\).*?\n  \}/m]
    close_handler = dashboard[/onCloseRequested: \{.*?\n    \}/m]

    assert_match(/root\.service\.disconnectPending.*root\.popupOpen = false/m,
                 close_function)
    assert_match(/onSurfaceActiveChanged:.*!root\.componentReady.*root\.surfaceActive.*root\.open\(\).*root\.close\(\)/m,
                 dashboard)
    refute_match(/requiresInitialSetup.*popupOpen = true/m, widget)
    refute_match(/requiresInitialSetup.*popupOpen = true/m, close_handler)
    assert_match(/root\.viewMode === "setup" \|\| root\.viewMode === "settings".*root\.backToStatus\(\).*root\.closeRequested\(\)/m,
                 close_handler)
    assert_match(/allowBack: true/m, dashboard)
    assert_match(/onBackRequested:\s*\{\s*root\.backToStatus\(\)/m,
                 dashboard)
    assert_match(/BambuModelViewport\s*\{.*printerConfigured: root\.service\.hasConnectionTarget\s*\|\| root\.service\.demoActive/m,
                 dashboard)
  end

  def test_first_run_demo_is_explicit_local_and_does_not_replace_bar_state
    service = service_source
    dashboard = dashboard_source
    settings = settings_source

    assert_match(/function startDemo\(\).*root\.requiresInitialSetup.*"op": "start_demo".*"requestId": nextId/m,
                 service)
    assert_match(/function stopDemo\(\).*"op": "stop_demo".*resetDemoState\(\)/m,
                 service)
    assert_match(/function sendConfiguration\(draft\).*root\.demoActive.*root\.stopDemo\(\).*"op": "configure"/m,
                 service)
    assert_match(/function statusSummary\(separator\).*if \(!root\.hasConnectionTarget\) return "SETUP"/m,
                 service)
    assert_match(/function nextIdleView\(\).*service\.demoActive.*return "status".*requiresInitialSetup.*return "setup"/m,
                 dashboard)
    assert_includes settings, 'property bool demoAvailable: false'
    assert_includes settings, 'form.demoActive ? "EXIT DEMO" : "TRY DEMO"'
    assert_match(/onDemoRequested:.*service\.demoActive.*service\.stopDemo\(\).*service\.startDemo\(\).*viewMode = "status"/m,
                 dashboard)
    assert_match(/visible: !root\.service\.demoActive && root\.service\.secretRequired.*root\.viewMode === "status"/m,
                 dashboard)
    assert_match(/message\.event === "state".*!root\.demoActive.*handleState\(message\).*message\.event === "demo_state".*handleDemoState\(message\).*geometry_.*demoGeometry.*message\.demoSession === root\.demoSessionId/m,
                 service)
    assert_match(/function resetDemoState\(\).*root\.demoActive = false.*root\.resetOperationalState\(\)/m,
                 service)
    assert_match(/message\.scope === "demo".*message\.demoSession === root\.demoSessionId.*root\.modelStatus = "error".*return/m,
                 service)
  end

  def test_late_quattro_settings_injection_and_runtime_resets_cannot_show_stale_status
    service = service_source
    dashboard = dashboard_source
    widget = widget_source

    assert_match(/function open\(\).*popupOpen = true/m,
                 widget)
    refute_match(/function open\(\).*dashboard\.open\(\)/m, widget)
    assert_match(/function open\(\).*root\.viewMode !== "settings".*root\.viewMode = root\.nextIdleView\(\)/m,
                 dashboard)
    assert_match(/function resetOperationalState\(\).*printerStateKnown = false/m,
                 service)
    assert_match(/onBackendConfigurationFingerprintChanged:.*resetOperationalState\(\).*sendConfiguration\(\)/m,
                 service)
  end

  def test_connecting_view_has_a_real_loader_and_every_panel_view_is_bounded
    source = application_source

    assert_match(/Item\s*{\s*width: Style\.space\(48\).*RotationAnimator on rotation.*loops: Animation\.Infinite.*running: root\.surfaceActive && root\.viewMode === "connecting"/m,
                 source)
    assert_match(/contentWidth: fittedContentWidth\(Style\.space\(860\)\)/m,
                 source)
    assert_match(/Item\s*{\s*visible: root\.viewMode === "connecting".*width: dashboard\.overlayWidth.*height: dashboard\.overlayHeight/m,
                 source)
    assert_match(/BambuTelemetryPane\s*{.*width: dashboard\.wideLayout.*Style\.space\(300\).*onSettingsRequested: root\.toggleSettings\(\)/m,
                 source)
    assert_match(/BambuModelViewport\s*{.*width: dashboard\.wideLayout.*dashboard\.width - telemetryPane\.width/m,
                 source)
    assert_match(/BambuSettingsView\s*{.*width: dashboard\.overlayWidth.*height: dashboard\.overlayHeight/m,
                 source)
  end

  def test_identity_fields_are_rejected_before_persistence_if_backend_would_reject_them
    source = settings_source

    assert_match(%r{!/\^\[A-Za-z0-9_-\]\+\$/\.test\(nextSerial\)}, source)
    assert_match(%r{!/\^\[A-Za-z0-9_\.:-\]\+\$/\.test\(nextUsername\)}, source)
    assert_match(/nextSerial\.length > 128/, source)
    assert_match(/nextUsername\.length > 128/, source)
  end

  def test_manifest_persists_no_secret_setting
    manifest = JSON.parse(File.read(File.join(@root, "manifest.json")))
    bar_widget = manifest.fetch("barWidget")
    keys = bar_widget.fetch("schema").map { |entry| entry.fetch("key") }

    refute(keys.any? { |key| key.match?(/access|code|password|secret/i) })
    refute secret_values(bar_widget).any?
    assert_includes keys, "mqttTlsFingerprint"
    assert_includes keys, "ftpsTlsFingerprint"
  end

  def test_widget_integrates_navigation_and_atomic_quattro_persistence
    service = service_source
    dashboard = dashboard_source

    assert_includes dashboard, 'property string viewMode: "setup"'
    assert_includes service, "readonly property bool hasConnectionTarget:"
    assert_includes dashboard, 'visible: root.viewMode === "connecting"'
    assert_includes dashboard, 'visible: root.viewMode === "setup" || root.viewMode === "settings"'
    assert_match(/function openSettings\(message\).*settingsView\.load\(root\.service\.settingsDraft\(\)\).*root\.viewMode = "settings"/m,
                 dashboard)
    focus_helper = dashboard[/function focusPanelTop\(\) \{.*?\n  \}/m]
    refute_nil focus_helper
    assert_includes focus_helper, "Qt.callLater"
    assert_includes focus_helper, "panelScroll.contentY = 0"
    assert_includes focus_helper, "keyCatcher.forceActiveFocus()"
    assert_match(/function openSettings\(message\).*root\.focusPanelTop\(\)/m,
                 dashboard)
    assert_match(/function close\(\).*settingsView\.clearAccessCode\(\).*root\.viewMode = root\.nextIdleView\(\)/m,
                 dashboard)
    writer = service[/function commitSettingsEntry\(entry\) \{.*?\n  \}/m]
    refute_nil writer
    assert_match(/persistingSettings = true.*root\.settings = entry.*root\.shell\.updateEntryInline\(root\.moduleName, entry\).*persistingSettings = false/m,
                 writer)
    assert_match(/function persistSettings\(draft, clearAcknowledgements\).*var entry = \{ id: root\.moduleName \}.*root\.commitSettingsEntry\(entry\).*return true/m,
                 service)
    assert_match(/function saveSettings\(draft, accessCode\).*backendSettingsChanged\(draft\).*persistSettings\(draft\).*return \{ ok: true, mode:/m,
                 service)
    assert_match(/BambuSettingsView\s*\{.*id: settingsView.*onSaveRequested: function\(draft, accessCode\).*root\.service\.saveSettings/m,
                 dashboard)
    assert_match(/blocked: settingsView\.inputActive/, dashboard)
    assert_match(/onInputFocusReleased: keyCatcher\.forceActiveFocus\(\)/, dashboard)
    refute_match(/entry\[[^\]]*(?:secret|accessCode|password)/i, service)
  end

  def test_telemetry_settings_button_toggles_the_settings_panel
    source = application_source

    assert_match(/function toggleSettings\(\).*if \(root\.viewMode === "settings"\).*root\.backToStatus\(\).*root\.openSettings\(""\)/m,
                 source)
    assert_match(/BambuTelemetryPane\s*\{.*onSettingsRequested: root\.toggleSettings\(\)/m,
                 source)
  end

  def test_settings_form_has_no_decorative_section_separators
    source = settings_source

    refute_includes source, "component DrawerSection"
    refute_includes source, 'objectName: "NETWORK"'
    refute_includes source, 'objectName: "ADVANCED"'
  end

  def test_network_contains_compact_inline_lan_authentication
    source = settings_source

    refute_includes source, 'DrawerSection { objectName: "LAN AUTHENTICATION" }'
    assert_match(/id: networkGrid.*id: usernameInput.*text: form\.requireAccessCode.*id: accessCodeInput.*id: forgetCodeInline/m,
                 source)
  end

  def test_in_form_summary_switch_applies_immediately_without_save
    source = settings_source

    assert_includes source, "property bool showBarSummary: true"
    assert_includes source, "signal barSummaryToggled(bool enabled)"
    assert_match(/function load\(draft\).*showBarSummary = values\.showBarSummary !== false/m,
                 source)
    assert_match(/var draft = \{.*showBarSummary: form\.showBarSummary/m,
                 source)
    assert_match(/id: settingsContent.*id: preferencesGrid.*text: "BAR SUMMARY".*ToggleSwitch\s*\{.*checked: form\.showBarSummary.*onToggled:.*form\.showBarSummary = !form\.showBarSummary.*form\.barSummaryToggled\(form\.showBarSummary\).*id: settingsFooter.*"SAVE & CONNECT"/m,
                 source)

    widget = application_source
    assert_match(/function persistBarSummary\(enabled\).*var current = root\.settings.*entry\["showBarSummary"\] = enabled === true.*commitSettingsEntry\(entry\)/m,
                 widget)
    assert_match(/BambuSettingsView\s*\{.*onBarSummaryToggled: function\(enabled\).*root\.service\.persistBarSummary\(enabled\)/m,
                 widget)
  end

  def test_explosion_factor_is_loaded_validated_and_saved_with_the_form
    source = settings_source

    assert_match(/readonly property bool inputActive:.*explosionFactorInput\.activeFocus/m,
                 source)
    assert_match(/function load\(draft\).*explosionFactorInput\.text = String\(values\.explosionFactor === undefined\s*\? 100 : values\.explosionFactor\)/m,
                 source)
    assert_match(/id: explosionFactorInput.*maximumLength: 3.*inputMethodHints: Qt\.ImhDigitsOnly.*placeholderText: "100"/m,
                 source)
    assert_match(/var nextExplosionFactor = parseInteger\(\s*explosionFactorInput\.text, "Explode factor", 0, 500\).*if \(nextExplosionFactor < 0\) return/m,
                 source)
    assert_match(/var draft = \{.*maxSegments: nextSegments.*explosionFactor: nextExplosionFactor.*autoRotate: form\.autoRotate/m,
                 source)
  end

  def test_auto_rotate_default_is_loaded_and_saved_with_the_form
    source = settings_source

    assert_includes source, "property bool autoRotate: true"
    assert_match(/function load\(draft\).*autoRotate = values\.autoRotate !== false/m,
                 source)
    assert_match(/var draft = \{.*autoRotate: form\.autoRotate/m, source)
    assert_match(/text: "AUTO-ROTATE BY DEFAULT"\s*\}\s*ToggleSwitch\s*\{.*checked: form\.autoRotate.*onToggled: form\.autoRotate = !form\.autoRotate.*text: "BAR SUMMARY"/m,
                 source)
  end

  def test_local_toggles_are_plain_native_controls_on_dedicated_rows
    source = settings_source

    assert_match(/id: settingsContent\s*width: Math\.max\(0, settingsScroll\.width\s*- \(settingsScroll\.interactive \? Style\.space\(20\) : 0\)\)\s*spacing: Style\.space\(8\)/,
                 source)
    assert_match(/Column\s*\{\s*width: parent\.width\s*spacing: Style\.space\(4\)\s*FieldLabel \{ text: "AUTO-ROTATE BY DEFAULT" \}\s*ToggleSwitch\s*\{\s*cursorPad: 0.*Column\s*\{\s*width: parent\.width\s*spacing: Style\.space\(4\)\s*FieldLabel \{ text: "BAR SUMMARY" \}\s*ToggleSwitch\s*\{\s*cursorPad: 0/m,
                 source)
    refute_match(/Item\s*\{\s*width: parent\.width\s*height: (?:autoRotate|barSummary)Switch\.trackHeight/m,
                 source)
    refute_includes source, "id: barSummaryRow"
    refute_includes source, "id: barSummaryField"
    refute_includes source, 'text: form.showBarSummary ? "SHOWN" : "HIDDEN"'
  end

  def test_settings_are_grouped_into_breathable_printer_network_and_display_sections
    source = settings_source

    assert_match(/component SectionLabel: Text \{.*height: implicitHeight \+ Style\.space\(8\).*verticalAlignment: Text\.AlignBottom.*color: form\.accent.*font\.letterSpacing: 1/m,
                 source)
    assert_match(/id: settingsContent.*spacing: Style\.space\(8\).*SectionLabel \{ text: "PRINTER" \}.*id: printerNameInput.*id: identityGrid.*id: hostInput.*id: serialInput.*SectionLabel \{ text: "NETWORK" \}.*id: networkGrid.*id: mqttPortInput.*id: ftpsPortInput.*id: usernameInput.*text: form\.requireAccessCode.*id: accessCodeInput.*SectionLabel \{ text: "DISPLAY" \}.*id: preferencesGrid.*id: explosionFactorInput.*text: "AUTO-ROTATE BY DEFAULT"/m,
                 source)

    widget = application_source
    assert_match(/BambuSettingsView\s*\{.*accent: root\.accent/m,
                 widget)
  end

  def test_settings_chrome_matches_the_dashboard_proportions
    settings = settings_source
    widget = application_source
    viewport = File.read(File.join(@root, "BambuModelViewport.qml"))
    telemetry = File.read(File.join(@root, "BambuTelemetryPane.qml"))

    assert_match(/id: dashboard\s*width: panelScroll\.width\s*height: wideLayout \? root\.viewportHeight/m,
                 widget)
    assert_match(/id: viewportHeader.*height: Style\.space\(36\).*id: viewportTitle.*font\.pixelSize: bambuStyle\.captionFontSize/m,
                 viewport)
    assert_match(/id: settingsHeader.*height: Style\.space\(36\).*text: "SETTINGS".*font\.pixelSize: bambuStyle\.captionFontSize/m,
                 settings)

    assert_match(/id: actionRow.*anchors\.bottom: parent\.bottom.*anchors\.margins: pane\.inset.*height: Style\.space\(36\)/m,
                 telemetry)
    assert_match(/id: settingsFooter.*height: Style\.space\(60\).*Row\s*\{.*anchors\.fill: parent.*anchors\.margins: Style\.space\(12\).*"DISCONNECT PRINTER".*height: parent\.height.*text: "SAVE & CONNECT"/m,
                 settings)
  end

  def test_security_modal_cancellation_invalidates_late_tls_probe_results
    service = service_source
    dashboard = dashboard_source

    assert_includes service, 'readonly property string securityModalMode:'
    assert_match(/securityModalMode:.*disconnectConfirmationOpen \|\| root\.disconnectPending/m,
                 service)
    assert_match(/function cancelTlsApproval\(\).*tlsProbeRequestId = \(root\.tlsProbeRequestId \+ 1\).*clearTlsProbeState\(\)/m,
                 service)
    assert_match(/function cancelSecurityModal\(\).*disconnectConfirmationOpen.*cancelTlsApproval\(\)/m,
                 service)
    assert_match(/function close\(\).*root\.service\.disconnectPending.*root\.service\.cancelSecurityModal\(\)/m,
                 dashboard)
    assert_match(/BambuSecurityDialog\s*\{.*anchors\.fill: parent.*z: 40.*onCancelRequested:.*root\.service\.cancelSecurityModal\(\)/m,
                 dashboard)
    assert_match(/BambuSecurityDialog\s*\{.*processing: root\.service\.disconnectPending/m,
                 dashboard)
  end

  def test_disconnect_confirmation_clears_connection_identity_but_preserves_preferences
    source = service_source

    assert_includes source, "property int disconnectRequestId: 0"
    assert_match(/function confirmDisconnect\(\).*disconnectRequestId = \(root\.disconnectRequestId \+ 1\).*disconnectPending = true.*"op": "clear_secret".*"requestId": root\.disconnectRequestId/m,
                 source)
    body = source[/function completeDisconnect\(\).*?\n  \}/m]
    refute_nil body
    assert_includes body, 'printerName: root.printerName'
    assert_includes body, 'host: ""'
    assert_includes body, "mqttPort: 8883"
    assert_includes body, "ftpsPort: 990"
    assert_includes body, 'serial: ""'
    assert_includes body, 'username: "bblp"'
    assert_includes body, "maxSegments: root.segmentLimit()"
    assert_includes body, "autoRotate: root.autoRotate"
    assert_includes body, "showBarSummary: root.showBarSummary"
    assert_includes body, 'mqttTlsFingerprint: ""'
    assert_includes body, 'ftpsTlsFingerprint: ""'
    assert_includes body, 'installationId: ""'
    assert_operator body.index("persistSettings(reset, true)"), :<,
                    body.index('attentionRequested("setup", "")')
    assert_match(/message\.event === "secret_status".*disconnectPending.*message\.requestId === root\.disconnectRequestId.*message\.stored === false.*completeDisconnect\(\)/m,
                 source)
    assert_match(/message\.event === "secret_required".*disconnectPending.*message\.requestId === root\.disconnectRequestId.*completeDisconnect\(\)/m,
                 source)
    assert_match(/message\.event === "error".*root\.disconnectPending.*message\.requestId === root\.disconnectRequestId.*message\.scope === "secret".*message\.code === "clear_failed".*failDisconnect\("LAN access code could not be removed"\)/m,
                 source)
    assert_match(/message\.event === "error".*root\.disconnectPending.*message\.requestId === root\.disconnectRequestId.*message\.scope === "secret".*failDisconnect\(/m,
                 source)
    assert_match(/function persistSettings\(draft, clearAcknowledgements\).*draft\.installationId === undefined.*root\.installationId.*String\(draft\.installationId \|\| ""\)/m,
                 source)
    failure = source[/function failDisconnect\(message\) \{.*?\n  \}/m]
    refute_nil failure
    assert_includes failure, 'attentionRequested("settings", message)'
  end

  def test_panel_close_request_cancels_the_active_security_modal_first
    source = dashboard_source
    handler = source[/onCloseRequested: \{.*?\n    \}\n\n    Flickable/m]

    refute_nil handler
    assert_match(/if \(root\.service\.securityModalMode !== ""\).*root\.service\.cancelSecurityModal\(\)/m,
                 handler)
    assert_operator handler.index("service.securityModalMode"), :<,
                    handler.index('viewMode === "settings"')
  end

  def test_only_a_missing_printer_target_forces_initial_setup
    service = service_source
    dashboard = dashboard_source

    assert_match(/readonly property bool requiresInitialSetup: !root\.hasConnectionTarget/,
                 service)
    refute_includes service, "storedInstallationId"
    assert_match(/function nextIdleView\(\).*service\.requiresInitialSetup.*return "setup"/m,
                 dashboard)
    hello = service[/if \(message\.event === "hello"\) \{.*?\n      return\n    \}/m]
    refute_nil hello
    assert_match(/installationId = String\(message\.installationId \|\| ""\).*installationIdentified = installationId !== "".*sendConfiguration\(\).*return/m,
                 hello)
    refute_match(/popupOpen\s*=\s*true/, hello)
    refute_match(/openSettings\(\)/, hello)
    assert_match(/function persistSettings\(draft, clearAcknowledgements\).*entry\.installationId = draft\.installationId === undefined.*root\.installationId/m,
                 service)
    assert_match(/function onRequiresInitialSetupChanged\(\).*root\.surfaceActive.*root\.service\.requiresInitialSetup.*root\.viewMode = "setup".*settingsView\.load/m,
                 dashboard)
    assert_match(/function commitSettingsEntry\(entry\).*persistingSettings = true.*root\.settings = entry.*updateEntryInline.*persistingSettings = false/m,
                 service)
    assert_match(/onBackendConfigurationFingerprintChanged:.*if \(!componentReady \|\| persistingSettings\) return/m,
                 service)
  end

  def test_empty_code_preserves_secret_and_non_empty_code_is_sent_after_config
    source = application_source

    assert_match(/function setSecret\(value\).*String\(value \|\| ""\).*"op": "set_secret"/m,
                 source)
    assert_includes source, "readonly property bool hasUsableSecret:"
    assert_match(/function saveSettings\(draft, accessCode\).*var replacement = String\(accessCode \|\| ""\).*if \(!replacement && !root\.hasUsableSecret\).*Enter the LAN access code.*persistSettings\(draft\).*if \(!backendChanged && !replacement\).*return \{ ok: true, mode:.*Qt\.callLater.*setSecret\(replacement\)/m,
                 source)
    body = source[/function saveSettings\(draft, accessCode\) \{.*?\n  \}/m]
    refute_nil body
    assert_operator body.index("Enter the LAN access code"), :<, body.index("persistSettings(draft)")
    assert_operator body.downcase.index("backend is not ready"), :<,
                    body.index("persistSettings(draft)")
    assert_operator body.index("pendingSecretWrite = !!replacement"), :<,
                    body.index("persistSettings(draft)")
    assert_match(/if \(!persistSettings\(draft\)\).*pendingSecretWrite = false.*Settings could not be saved/m,
                 body)
    assert_match(/requireAccessCode: !root\.service\.hasUsableSecret/, source)
  end

  def test_display_only_save_does_not_restart_the_backend_runtime
    source = application_source

    backend_change = source[/function backendSettingsChanged\(draft\) \{.*?\n  \}/m]
    refute_nil backend_change
    assert_match(/host.*mqttPort.*ftpsPort.*serial.*username.*maxSegments/m,
                 backend_change)
    refute_match(/explosionFactor/, backend_change)
    refute_match(/autoRotate/, backend_change)
    assert_match(/function saveSettings\(draft, accessCode\).*requiresTlsProbe\(draft\).*mqttTlsFingerprint = root\.mqttTlsFingerprint.*var backendChanged = backendSettingsChanged\(draft\).*persistSettings\(draft\).*if \(!backendChanged && !replacement\).*return \{ ok: true, mode:.*if \(backendChanged\) sendConfiguration\(draft\)/m,
                 source)
  end

  def test_failed_lan_code_write_forces_the_settings_form_back_open
    source = application_source

    assert_match(/function recoverSecretWrite\(message\).*if \(!root\.pendingSecretWrite\) return false.*pendingSecretWrite = false.*attentionRequested\("settings", message\).*return true/m,
                 source)
    assert_match(/function saveSettings\(draft, accessCode\).*if \(!setSecret\(replacement\)\).*recoverSecretWrite\(/m,
                 source)
    assert_match(/function handleBackendStopped\(\).*resetOperationalState\(\).*recoverSecretWrite\(/m,
                 source)
    assert_match(/message\.event === "error".*reportProcessError\(message\.message,\s*message\.scope === "mqtt" && message\.code === "connection"\).*recoverSecretWrite\(/m,
                 source)
    assert_match(/message\.event === "secret_status".*pendingSecretWrite = false/m,
                 source)
  end

  def test_mqtt_authentication_rejection_always_forces_the_settings_form_open
    source = application_source

    assert_match(/function handleAuthenticationFailure\(message\).*if \(root\.pendingSecretWrite\) return false.*pendingSecretWrite = false.*secretRequired = true.*secretStored = false.*secretStatusKnown = true.*attentionRequested\("settings", message\).*return true/m,
                 source)
    assert_match(/message\.event === "error".*message\.scope === "mqtt".*message\.code === "authentication".*handleAuthenticationFailure/m,
                 source)
  end

  def test_readme_documents_the_dedicated_settings_and_secret_replacement_flow
    readme = File.read(File.join(@root, "README.md"))

    assert_match(/panel stays closed.*plugin reloads|reloads.*other plugins/im, readme)
    refute_match(/automatically opens.*setup panel/im, readme)
    assert_match(/address.*serial.*LAN access code/im, readme)
    assert_match(/connection loader.*first fresh status\s+report/im, readme)
    assert_match(/reflow.*inside the panel margins/im, readme)
    assert_match(/leave.*code.*blank.*keep/im, readme)
    assert_match(/replace/im, readme)
    assert_match(/Disconnect printer.*confirmation.*preserv.*visual preferences/im,
                 readme)
  end

  private

  def settings_source
    assert File.file?(@path), "expected a dedicated settings component at #{@path}"
    File.read(@path)
  end

  def secret_values(value, secret_context = false)
    case value
    when Hash
      value.flat_map do |key, child|
        secret_values(child, secret_context || key.match?(/access|code|password|secret/i))
      end
    when Array
      value.flat_map { |child| secret_values(child, secret_context) }
    else
      secret_context ? [value] : []
    end
  end
end
