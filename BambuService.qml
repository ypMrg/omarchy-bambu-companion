import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  visible: false

  readonly property string moduleName: "io.github.ypmrg.bambu-companion"
  property var shell: null
  property var manifest: null
  property var settings: ({})
  property bool componentReady: false
  property bool installationIdentified: false
  property string installationId: ""
  property alias daemonReady: backendSession.daemonReady
  readonly property bool backendRunning: backendSession.running
  property bool connected: false
  property bool printerStateKnown: false
  property bool stale: true
  property bool secretRequired: false
  property bool secretStored: false
  property bool secretStatusKnown: false
  readonly property bool hasUsableSecret: root.secretStored
    || (root.secretStatusKnown && !root.secretRequired)
  property string gcodeState: "OFFLINE"
  property bool finishGraceExpired: false
  readonly property string displayGcodeState:
    root.finishGraceExpired && root.isFinishedState(root.gcodeState)
      ? "READY" : root.gcodeState
  property string subtaskName: ""
  property int percent: 0
  property real nozzleTemp: NaN
  property real nozzleTargetTemp: NaN
  property var nozzles: []
  property int activeNozzle: -1
  property real bedTemp: NaN
  property real bedTargetTemp: NaN
  property int currentLayer: 0
  property int totalLayers: 0
  property int remainingMinutes: -1
  property int speedLevel: 0
  property int speedMagnitude: 0
  property string wifiSignal: ""
  property real coolingFanSpeed: NaN
  property real heatbreakFanSpeed: NaN
  property string lastUpdate: ""
  property string productName: ""
  property string firmwareVersion: ""
  property string modelStatus: "idle"
  property string modelErrorCode: ""
  property string modelError: ""
  property string modelLoadPhase: ""
  property int modelLoadProgress: -1
  property real modelLoadedBytes: 0
  property real modelTotalBytes: 0
  property real zCurrent: NaN
  property string zMode: "unknown"
  property string processError: ""
  property string processErrorReportUpdate: ""
  property bool processErrorAffectsBar: false
  property bool pendingSecretWrite: false
  property bool persistingSettings: false
  property bool tlsProbePending: false
  property bool tlsApprovalRequired: false
  property bool tlsRejected: false
  property bool disconnectConfirmationOpen: false
  property bool disconnectPending: false
  property int disconnectRequestId: 0
  property int tlsProbeRequestId: 0
  property var pendingTlsDraft: ({})
  property var mqttTlsIdentity: ({})
  property var ftpsTlsIdentity: ({})
  property bool demoActive: false
  property int demoSessionId: 0

  property alias eventHistory: eventStore.events
  property alias unreadEventCount: eventStore.unreadCount
  property alias unreadErrorCount: eventStore.unreadErrorCount
  property alias unreadWarningCount: eventStore.unreadWarningCount
  property alias activePrinterErrorCount: eventStore.activeErrorCount

  readonly property string currentVersion: root.manifest && root.manifest.version
    ? String(root.manifest.version) : "unknown"
  property bool pluginUpdateAvailable: false
  property bool pluginUpdateStatusKnown: false
  readonly property bool pluginUpdateBusy: pluginUpdateProcess.running
  readonly property bool pluginUpdateInstalling: root.pluginUpdateBusy
    && pluginUpdateProcess.action === "update"
  property string pluginUpdateVersion: ""
  property string pluginUpdateError: ""

  signal attentionRequested(string mode, string message)
  signal errorReported(string message)
  signal statusAvailable()

  property alias geometryBundle: geometryAssembler.geometryBundle
  property alias selectedGeometrySource: geometryAssembler.selectedGeometrySource
  property string selectedViewportSource: "gcode"
  readonly property bool previewAvailable: geometryAssembler.previewAvailable
  readonly property bool gcodeGeometryAvailable: geometryAssembler.gcodeAvailable
  property bool popupCameraVisible: false
  property bool windowCameraVisible: false
  property bool cameraPresent: false
  property string cameraTransport: "none"
  property bool cameraLiveviewEnabled: false
  property bool cameraFfmpegAvailable: false
  property string cameraStatus: "idle"
  property string cameraStatusCode: ""
  property string cameraStatusMessage: ""
  property string cameraFramePath: ""
  property int cameraFrameGeneration: 0
  property bool cameraSessionRequested: false
  readonly property bool cameraSelectable: !root.demoActive && root.connected
    && root.cameraPresent
    && (root.cameraTransport === "jpeg_tcp"
      || (root.cameraTransport === "rtsps" && root.cameraLiveviewEnabled
        && root.cameraFfmpegAvailable))
  readonly property bool cameraDesired: root.selectedViewportSource === "camera"
    && root.cameraSelectable
    && (root.popupCameraVisible || root.windowCameraVisible)
  readonly property bool cameraFrameAvailable: root.cameraFramePath !== ""
  readonly property url cameraFrameSource: root.cameraFrameAvailable
    ? Qt.resolvedUrl("file://" + root.cameraFramePath + "?g="
      + root.cameraFrameGeneration) : ""
  readonly property int activeSegmentCount: {
    var geometry = root.geometryBundle.gcode
    if (!geometry) return 0
    var count = Number(geometry.segmentCount)
    return isNonNegativeInteger(count) ? count : 0
  }
  readonly property string activeSegmentPath: {
    var geometry = root.geometryBundle.gcode
    return geometry ? String(geometry.path || "") : ""
  }
  readonly property var activeBounds: {
    var geometry = root.geometryBundle.gcode
    return geometry && geometry.bounds ? geometry.bounds : ({})
  }
  property alias modelGeneration: geometryAssembler.modelGeneration

  readonly property string printerName: String(setting("printerName", "3D Printer"))
  readonly property string host: String(setting("host", ""))
  readonly property int mqttPort: Number(setting("mqttPort", 8883))
  readonly property int ftpsPort: Number(setting("ftpsPort", 990))
  readonly property string serial: String(setting("serial", ""))
  readonly property string username: String(setting("username", "bblp"))
  readonly property int maxSegments: Number(setting("maxSegments", 500000))
  readonly property int explosionFactor: Math.max(0, Math.min(500,
    Math.round(finiteNumber(Number(setting("explosionFactor", 100)), 100))))
  readonly property bool autoRotate: setting("autoRotate", true) !== false
  readonly property bool showBarSummary: setting("showBarSummary", true) !== false
  readonly property string mqttTlsFingerprint:
    String(setting("mqttTlsFingerprint", ""))
  readonly property string ftpsTlsFingerprint:
    String(setting("ftpsTlsFingerprint", ""))
  readonly property bool hasConnectionTarget: String(root.host).trim() !== ""
    && String(root.serial).trim() !== ""
  readonly property bool hasTrustedTlsPins:
    root.validTlsFingerprint(root.mqttTlsFingerprint)
      && root.validTlsFingerprint(root.ftpsTlsFingerprint)
  readonly property bool requiresInitialSetup: !root.hasConnectionTarget
  readonly property string securityModalMode:
    (root.disconnectConfirmationOpen || root.disconnectPending) ? "disconnect"
      : ((root.tlsProbePending || root.tlsApprovalRequired) ? "certificate" : "")
  readonly property string displayName: {
    var name = String(root.printerName || "").trim()
    return name || "3D Printer"
  }
  readonly property string backendConfigurationFingerprint: JSON.stringify(root.configuration())
  readonly property url printerIconSource: Qt.resolvedUrl("assets/printer-open-frame.svg")
  readonly property string backendPath: decodeURIComponent(
    String(Qt.resolvedUrl("bambu-companion")).replace(/^file:\/\//, "")
  )
  readonly property string nativeBuildPath: decodeURIComponent(
    String(Qt.resolvedUrl("native/build")).replace(/^file:\/\//, "")
  )
  readonly property string pluginUpdateCheckPath: decodeURIComponent(
    String(Qt.resolvedUrl("bambu-companion-update-check")).replace(/^file:\/\//, "")
  )
  readonly property string nativeDataRoot: {
    var home = Quickshell.env("XDG_DATA_HOME")
    if (!home || home === "") home = Quickshell.env("HOME") + "/.local/share"
    return home + "/io.github.ypmrg.bambu-companion"
  }
  readonly property string nativeRoutePath:
    nativeDataRoot + "/qml/native/RouteHost.qml"
  readonly property string geometryDirectory: nativeDataRoot + "/geometry"
  readonly property string cameraDirectory: nativeDataRoot + "/camera"
  property string rendererStatus: "compiling"
  readonly property url nativeRouteUrl: Qt.resolvedUrl("file://" + nativeRoutePath)
  property bool nativeBuildStarted: false
  readonly property bool errorActive: root.printerHasError()
    || root.activePrinterErrorCount > 0
    || root.processError !== ""
  readonly property bool barErrorActive: root.printerHasError()
    || root.activePrinterErrorCount > 0 || root.unreadErrorCount > 0
    || root.processErrorAffectsBar
  readonly property bool modelErrorActive: root.modelStatus === "error"
    && root.modelError !== ""
  readonly property bool barFinishActive: root.connected && !root.stale
    && root.isFinishedState(root.displayGcodeState)
  function settingsDraft() {
    return {
      printerName: root.printerName,
      host: root.host,
      mqttPort: root.mqttPort,
      ftpsPort: root.ftpsPort,
      serial: root.serial,
      username: root.username,
      maxSegments: root.maxSegments,
      explosionFactor: root.explosionFactor,
      autoRotate: root.autoRotate,
      showBarSummary: root.showBarSummary,
      mqttTlsFingerprint: root.mqttTlsFingerprint,
      ftpsTlsFingerprint: root.ftpsTlsFingerprint
    }
  }

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function settingsFromShell() {
    var config = root.shell ? root.shell.shellConfig : null
    var layout = config && config.bar ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    for (var sectionIndex = 0; layout && sectionIndex < sections.length; sectionIndex++) {
      var entries = layout[sections[sectionIndex]]
      if (!Array.isArray(entries)) continue
      for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
        var entry = entries[entryIndex]
        if (entry && String(entry.id || "") === root.moduleName)
          return JSON.parse(JSON.stringify(entry))
      }
    }
    return { id: root.moduleName }
  }

  function refreshSettings() {
    var next = root.settingsFromShell()
    if (JSON.stringify(next) !== JSON.stringify(root.settings)) root.settings = next
    eventStore.setAcknowledgedAlertKeys(next.acknowledgedAlerts)
  }

  function initialize() {
    if (root.componentReady || !root.shell) return
    root.componentReady = true
    root.refreshSettings()
    backendSession.start()
    nativeBuild.running = true
    root.refreshPluginUpdate()
    if (!nativeBuild.running && !root.nativeBuildStarted)
      root.markRendererUnavailable()
  }

  function commitSettingsEntry(entry) {
    if (!root.shell || typeof root.shell.updateEntryInline !== "function") return false
    persistingSettings = true
    root.settings = entry
    root.shell.updateEntryInline(root.moduleName, entry)
    persistingSettings = false
    return true
  }

  function persistSettings(draft) {
    var entry = { id: root.moduleName }
    entry.printerName = draft.printerName
    entry.host = draft.host
    entry.mqttPort = draft.mqttPort
    entry.ftpsPort = draft.ftpsPort
    entry.serial = draft.serial
    entry.username = draft.username
    entry.maxSegments = draft.maxSegments
    entry.explosionFactor = draft.explosionFactor
    entry.autoRotate = draft.autoRotate
    entry.showBarSummary = draft.showBarSummary
    entry.mqttTlsFingerprint = String(draft.mqttTlsFingerprint || "")
    entry.ftpsTlsFingerprint = String(draft.ftpsTlsFingerprint || "")
    entry.installationId = draft.installationId === undefined
      ? root.installationId : String(draft.installationId || "")
    return root.commitSettingsEntry(entry)
  }

  // The immediate toggle must not save partially edited printer credentials
  // or restart the printer session.
  function persistBarSummary(enabled) {
    var current = root.settings && typeof root.settings === "object"
      ? root.settings : ({})
    var entry = { id: root.moduleName }
    for (var key in current) {
      if (key !== "id") entry[key] = current[key]
    }
    entry["showBarSummary"] = enabled === true
    return root.commitSettingsEntry(entry)
  }

  function backendSettingsChanged(draft) {
    return String(draft.host) !== root.host
      || Number(draft.mqttPort) !== root.mqttPort
      || Number(draft.ftpsPort) !== root.ftpsPort
      || String(draft.serial) !== root.serial
      || String(draft.username) !== root.username
      || Number(draft.maxSegments) !== root.segmentLimit()
      || String(draft.mqttTlsFingerprint || "") !== root.mqttTlsFingerprint
      || String(draft.ftpsTlsFingerprint || "") !== root.ftpsTlsFingerprint
  }

  function saveSettings(draft, accessCode) {
    var replacement = String(accessCode || "")
    if (!replacement && !root.hasUsableSecret) {
      return { ok: false, error: "Enter the LAN access code to connect" }
    }
    if (replacement && (!root.daemonReady || !backendSession.running)) {
      return { ok: false, error: "Backend is not ready for the LAN code" }
    }
    if (root.requiresTlsProbe(draft)) {
      return root.beginTlsProbe(draft)
    }
    draft.mqttTlsFingerprint = root.mqttTlsFingerprint
    draft.ftpsTlsFingerprint = root.ftpsTlsFingerprint
    var backendChanged = backendSettingsChanged(draft)
    pendingSecretWrite = !!replacement
    if (!persistSettings(draft)) {
      pendingSecretWrite = false
      return { ok: false, error: "Settings could not be saved by Omarchy Shell" }
    }
    if (!backendChanged && !replacement) {
      return { ok: true, mode: root.printerStateKnown ? "status" : "connecting" }
    }
    if (backendChanged) sendConfiguration(draft)
    if (!replacement) return { ok: true, mode: "connecting" }
    Qt.callLater(function() {
      if (!setSecret(replacement)) {
        recoverSecretWrite("LAN code could not be sent. Enter it again")
      }
    })
    return { ok: true, mode: "connecting" }
  }

  function tlsTarget(draft) {
    return JSON.stringify({
      host: String(draft.host || "").trim(),
      mqttPort: Number(draft.mqttPort),
      ftpsPort: Number(draft.ftpsPort),
      serial: String(draft.serial || "").trim()
    })
  }

  function requiresTlsProbe(draft) {
    if (root.tlsRejected || !root.hasTrustedTlsPins) return true
    return root.tlsTarget(draft) !== root.tlsTarget(root.settingsDraft())
  }

  function clearTlsProbeState() {
    root.tlsProbePending = false
    root.tlsApprovalRequired = false
    root.pendingTlsDraft = ({})
    root.mqttTlsIdentity = ({})
    root.ftpsTlsIdentity = ({})
  }

  function cancelTlsApproval() {
    root.tlsProbeRequestId = (root.tlsProbeRequestId + 1) % 2147483647
    root.clearTlsProbeState()
  }

  function cancelSecurityModal() {
    if (root.disconnectConfirmationOpen) {
      root.disconnectConfirmationOpen = false
    } else if (root.tlsProbePending || root.tlsApprovalRequired) {
      root.cancelTlsApproval()
    }
  }

  function beginTlsProbe(draft) {
    if (!root.daemonReady || !backendSession.running) {
      return { ok: false, error: "Backend is not ready to check the certificate" }
    }
    root.stopDemo()
    root.tlsProbeRequestId = (root.tlsProbeRequestId + 1) % 2147483647
    root.clearTlsProbeState()
    root.pendingTlsDraft = JSON.parse(JSON.stringify(draft))
    root.tlsProbePending = true
    var probeConfig = root.configurationForDraft(draft)
    probeConfig.mqttTlsFingerprint = ""
    probeConfig.ftpsTlsFingerprint = ""
    var written = root.writeCommand({
      "op": "probe_tls", "protocol": 1,
      "requestId": root.tlsProbeRequestId, "config": probeConfig
    })
    if (!written) {
      root.tlsProbePending = false
      return { ok: false, error: "Certificate check could not be started" }
    }
    return { ok: true, mode: "settings" }
  }

  function trustAndConnect(draft, accessCode) {
    if (!root.tlsApprovalRequired)
      return { ok: false, error: "Certificate approval is no longer active" }
    if (root.tlsTarget(draft) !== root.tlsTarget(root.pendingTlsDraft)) {
      root.clearTlsProbeState()
      return root.saveSettings(draft, accessCode)
    }
    var trusted = JSON.parse(JSON.stringify(draft))
    trusted.mqttTlsFingerprint = String(root.mqttTlsIdentity.fingerprint || "")
    trusted.ftpsTlsFingerprint = String(root.ftpsTlsIdentity.fingerprint || "")
    var replacement = String(accessCode || "")
    var backendChanged = backendSettingsChanged(trusted)
    pendingSecretWrite = !!replacement
    if (!persistSettings(trusted)) {
      pendingSecretWrite = false
      return { ok: false, error: "Settings could not be saved by Omarchy Shell" }
    }
    root.clearTlsProbeState()
    root.tlsRejected = false
    root.reportProcessError("")
    if (backendChanged) sendConfiguration(trusted)
    if (!replacement) return { ok: true, mode: "connecting" }
    Qt.callLater(function() {
      if (!setSecret(replacement)) {
        recoverSecretWrite("LAN code could not be sent. Enter it again")
      }
    })
    return { ok: true, mode: "connecting" }
  }

  function handleTlsMismatch(message) {
    if (root.tlsRejected) return
    root.tlsRejected = true
    root.clearTlsProbeState()
    root.attentionRequested("settings", message)
  }

  // The non-secret address/identity settings remain useful when a printer is
  // temporarily offline. If the secret handoff itself fails, return to those
  // saved values and require the user to enter the code again.
  function recoverSecretWrite(message) {
    if (!root.pendingSecretWrite) return false
    pendingSecretWrite = false
    root.attentionRequested("settings", message)
    return true
  }

  function handleAuthenticationFailure(message) {
    // A rejection from the previous session may arrive while a replacement is
    // already queued. Let that write complete; a rejection from the restarted
    // session will arrive after secret_status and reopen the form if necessary.
    if (root.pendingSecretWrite) return false
    pendingSecretWrite = false
    secretRequired = true
    secretStored = false
    secretStatusKnown = true
    root.attentionRequested("settings", message)
    return true
  }

  function runPluginUpdateAction(action) {
    if (root.pluginUpdateBusy) return false
    pluginUpdateProcess.action = action
    root.pluginUpdateError = ""
    pluginUpdateProcess.output = ""
    pluginUpdateProcess.errorOutput = ""
    pluginUpdateProcess.command = action === "check"
      ? [root.pluginUpdateCheckPath]
      : ["omarchy", "plugin", "update", root.moduleName, "--yes"]
    pluginUpdateProcess.running = true
    if (!pluginUpdateProcess.running) {
      pluginUpdateProcess.action = ""
      if (action === "update")
        root.pluginUpdateError = "Plugin update could not be started"
      return false
    }
    return true
  }

  function refreshPluginUpdate() {
    return root.runPluginUpdateAction("check")
  }

  function installPluginUpdate() {
    return root.runPluginUpdateAction("update")
  }

  function objectOrEmpty(value) {
    return value && typeof value === "object" && !Array.isArray(value) ? value : ({})
  }

  function finiteNumber(value, fallback) {
    if (value === null || value === undefined || value === "") return fallback
    var number = Number(value)
    return isFinite(number) ? number : fallback
  }

  function isNonNegativeInteger(value) {
    return typeof value === "number" && isFinite(value)
      && value >= 0 && Math.floor(value) === value
  }

  function selectViewportSource(source) {
    if (source === "camera") {
      if (!root.cameraSelectable) return false
      selectedViewportSource = "camera"
      return true
    }
    if (source !== "gcode" && source !== "preview") return false
    geometryAssembler.selectSource(source)
    selectedViewportSource = source
    return true
  }

  function snapshotCamera() {
    return writeCommand({ "op": "camera_snapshot" })
  }

  function syncCameraSession() {
    if (root.cameraDesired) {
      if (root.cameraSessionRequested) return
      if (root.writeCommand({ "op": "camera_start" }))
        root.cameraSessionRequested = true
      return
    }
    if (!root.cameraSessionRequested) return
    root.writeCommand({ "op": "camera_stop" })
    root.cameraSessionRequested = false
  }

  function validCameraPath(path) {
    return path === root.cameraDirectory + "/snapshot.jpg"
  }

  function validTlsFingerprint(value) {
    return /^[0-9A-Fa-f]{64}$/.test(String(value || ""))
  }

  function isFinishedState(state) {
    var value = String(state || "").toUpperCase()
    return value === "FINISH" || value === "FINISHED"
      || value === "COMPLETE" || value === "COMPLETED"
  }

  function printerHasError() {
    var state = String(root.gcodeState || "").toUpperCase()
    return state === "ERROR" || state === "FAILED" || state.indexOf("ERROR") >= 0
  }

  function segmentLimit() {
    var configured = finiteNumber(root.maxSegments, 500000)
    return Math.max(0, Math.min(1000000, Math.floor(configured)))
  }

  function markRendererReady() {
    rendererStatus = "ready"
  }
  function markRendererUnavailable() {
    rendererStatus = "unavailable"
  }

  function handleNativeBuildRunningChanged() {
    if (nativeBuild.running) return
    if (componentReady && !nativeBuildStarted)
      root.markRendererUnavailable()
  }

  function formatTemp(value) {
    return isFinite(Number(value)) ? Math.round(Number(value)) + "°" : "--°"
  }

  function formatTempPair(current, target) {
    var currentText = root.formatTemp(current)
    if (!isFinite(Number(target))) return currentText
    return currentText + " / " + root.formatTemp(target)
  }

  function hasDualNozzles() {
    return Array.isArray(root.nozzles) && root.nozzles.length >= 2
  }

  function nozzleById(id) {
    if (!Array.isArray(root.nozzles)) return null
    for (var index = 0; index < root.nozzles.length; index++) {
      var nozzle = root.objectOrEmpty(root.nozzles[index])
      var nozzleId = Math.max(0,
        Math.floor(root.finiteNumber(nozzle.id, index)))
      if (nozzleId === id) return nozzle
    }
    return null
  }

  function formatNozzle(id) {
    if (!root.hasDualNozzles())
      return root.formatTempPair(root.nozzleTemp, root.nozzleTargetTemp)
    var nozzle = root.nozzleById(id)
    return nozzle ? root.formatTempPair(nozzle.temp, nozzle.targetTemp) : "--° / --°"
  }

  function formatDuration(minutes) {
    var value = Math.floor(root.finiteNumber(minutes, -1))
    if (value < 0) return "--"
    var hours = Math.floor(value / 60)
    var rest = value % 60
    if (hours <= 0) return rest + " min"
    return hours + " h " + (rest < 10 ? "0" : "") + rest + " min"
  }

  function speedLabel() {
    var labels = ["UNKNOWN", "SILENT", "STANDARD", "SPORT", "LUDICROUS"]
    var level = Math.floor(root.finiteNumber(root.speedLevel, 0))
    var label = level >= 1 && level <= 4 ? labels[level] : "CUSTOM"
    return label + (root.speedMagnitude > 0 ? " · " + root.speedMagnitude + "%" : "")
  }

  function formatFan(value) {
    var level = root.finiteNumber(value, NaN)
    if (!isFinite(level)) return "--"
    return Math.round(Math.max(0, Math.min(15, level)) / 15 * 100) + "%"
  }

  function formatLastUpdate() {
    if (!root.lastUpdate) return "--"
    var timestamp = new Date(root.lastUpdate)
    return isNaN(timestamp.getTime()) ? root.lastUpdate
      : Qt.formatDateTime(timestamp, "HH:mm:ss")
  }

  function formatDimensions() {
    var bounds = root.activeBounds || ({})
    var width = root.finiteNumber(bounds.maxX, NaN) - root.finiteNumber(bounds.minX, NaN)
    var depth = root.finiteNumber(bounds.maxY, NaN) - root.finiteNumber(bounds.minY, NaN)
    var height = root.finiteNumber(bounds.maxZ, NaN) - root.finiteNumber(bounds.minZ, NaN)
    if (![width, depth, height].every(function(value) { return isFinite(value) && value >= 0 }))
      return "--"
    return width.toFixed(1) + " × " + depth.toFixed(1) + " × " + height.toFixed(1) + " mm"
  }

  function statusSummary(separator) {
    if (!root.hasConnectionTarget) return "SETUP"
    if (!root.printerStateKnown) return "CONNECTING"
    if (root.barErrorActive) return "ERROR"
    if (!root.connected) return "OFFLINE"
    var gap = separator === undefined ? " " : String(separator)
    return root.displayGcodeState + gap + root.percent + "%" + gap
      + root.formatTemp(root.nozzleTemp) + "/" + root.formatTemp(root.bedTemp)
  }

  function configuration() {
    return {
      "host": root.host, "mqttPort": root.mqttPort,
      "ftpsPort": root.ftpsPort, "serial": root.serial,
      "username": root.username, "maxSegments": root.segmentLimit(),
      "mqttTlsFingerprint": root.mqttTlsFingerprint,
      "ftpsTlsFingerprint": root.ftpsTlsFingerprint
    }
  }

  function configurationForDraft(draft) {
    return {
      "host": String(draft.host || ""), "mqttPort": Number(draft.mqttPort),
      "ftpsPort": Number(draft.ftpsPort), "serial": String(draft.serial || ""),
      "username": String(draft.username || ""), "maxSegments": Number(draft.maxSegments),
      "mqttTlsFingerprint": String(draft.mqttTlsFingerprint || ""),
      "ftpsTlsFingerprint": String(draft.ftpsTlsFingerprint || "")
    }
  }

  function reportProcessError(message, hideInBar) {
    processError = String(message || "")
    processErrorReportUpdate = processError === "" ? "" : lastUpdate
    processErrorAffectsBar = processError !== "" && hideInBar !== true
  }

  function markEventRead(id) {
    var changed = eventStore.markRead(id)
    if (changed) root.persistEventAcknowledgements()
    return changed
  }

  function markAllEventsRead() {
    var changed = eventStore.markAllRead()
    if (changed) root.persistEventAcknowledgements()
    return changed
  }

  function persistEventAcknowledgements() {
    var current = root.settings && typeof root.settings === "object"
      ? root.settings : ({})
    var entry = { id: root.moduleName }
    for (var key in current) {
      if (key !== "id") entry[key] = current[key]
    }
    entry.acknowledgedAlerts = eventStore.acknowledgedAlertKeys
    return root.commitSettingsEntry(entry)
  }

  function writeCommand(command) {
    return backendSession.writeCommand(command)
  }

  function sendConfiguration(draft) {
    if (!daemonReady || !root.hasConnectionTarget) return
    if (root.demoActive) root.stopDemo()
    var config = draft && typeof draft === "object"
      ? configurationForDraft(draft) : configuration()
    writeCommand({ "op": "configure", "protocol": 1, "config": config })
  }

  function setSecret(value) {
    var replacement = String(value || "")
    if (!replacement) return false
    return writeCommand({
      "op": "set_secret", "accessCode": replacement, "persist": true
    })
  }

  function clearSecret() {
    return writeCommand({ "op": "clear_secret" })
  }

  function requestDisconnect() {
    if (!root.hasConnectionTarget && !root.hasUsableSecret) return
    root.disconnectConfirmationOpen = true
  }

  function failDisconnect(message) {
    root.disconnectPending = false
    root.attentionRequested("settings", message)
  }

  function confirmDisconnect() {
    root.disconnectConfirmationOpen = false
    if (!root.daemonReady || !backendSession.running) {
      root.errorReported("Backend is not ready to disconnect the printer")
      return false
    }
    root.disconnectRequestId = (root.disconnectRequestId + 1) % 2147483647
    root.disconnectPending = true
    if (!root.writeCommand({
      "op": "clear_secret", "requestId": root.disconnectRequestId
    })) {
      root.failDisconnect("Printer could not be disconnected")
      return false
    }
    return true
  }

  function completeDisconnect() {
    if (!root.disconnectPending) return
    var reset = {
      printerName: root.printerName,
      host: "",
      mqttPort: 8883,
      ftpsPort: 990,
      serial: "",
      username: "bblp",
      maxSegments: root.segmentLimit(),
      explosionFactor: root.explosionFactor,
      autoRotate: root.autoRotate,
      showBarSummary: root.showBarSummary,
      mqttTlsFingerprint: "",
      ftpsTlsFingerprint: "",
      installationId: ""
    }
    if (!root.persistSettings(reset)) {
      root.failDisconnect("Disconnected, but Omarchy Shell could not reset the settings")
      return
    }
    root.disconnectPending = false
    root.pendingSecretWrite = false
    root.tlsRejected = false
    root.resetOperationalState()
    root.attentionRequested("setup", "")
  }

  function refreshModel() {
    writeCommand({ "op": "refresh_model" })
  }

  function startDemo() {
    if (!root.requiresInitialSetup || !root.daemonReady || !backendSession.running)
      return false
    var nextId = root.demoSessionId % 2147483646 + 1
    root.resetOperationalState()
    root.demoSessionId = nextId
    root.demoActive = true
    eventStore.loadDemoEvents()
    if (root.writeCommand({
      "op": "start_demo", "protocol": 1,
      "requestId": nextId
    })) return true
    root.resetDemoState()
    return false
  }

  function stopDemo() {
    if (!root.demoActive) return true
    var requestId = root.demoSessionId
    var written = !root.daemonReady || !backendSession.running
      || root.writeCommand({
        "op": "stop_demo", "protocol": 1, "requestId": requestId
      })
    root.resetDemoState()
    return written
  }

  function resetDemoState() {
    eventStore.clearDemoEvents()
    root.demoActive = false
    root.resetOperationalState()
  }

  function handleBackendStopped() {
    resetDemoState()
    if (root.disconnectPending) {
      root.failDisconnect("Backend stopped before disconnecting the printer")
    }
    recoverSecretWrite("Backend stopped before accepting the LAN code. Enter it again")
  }

  function handleErrorLine(line) {
    var message = String(line || "").trim()
    if (message) reportProcessError(message)
  }

  function handleState(message) {
    message = objectOrEmpty(message)
    var printer = objectOrEmpty(message.printer)
    var model = objectOrEmpty(message.model)
    var stateWasUnknown = !root.printerStateKnown
    var wasConnected = root.connected
    var previousGcodeState = root.gcodeState
    var previousSubtaskName = root.subtaskName
    var nextGeneration = isNonNegativeInteger(model.generation) ? model.generation : -1
    geometryAssembler.setGeneration(nextGeneration)
    printerStateKnown = true
    connected = printer.connected === true
    stale = printer.stale !== false
    var reportUpdate = String(printer.lastUpdate || "")
    var hasFreshReport = connected && printer.stale === false
      && reportUpdate !== ""
    if (hasFreshReport) {
      if (processError !== "" && reportUpdate !== processErrorReportUpdate) {
        root.reportProcessError("")
      }
    }
    gcodeState = String(printer.gcodeState || (connected ? "IDLE" : "OFFLINE"))
    subtaskName = String(printer.subtaskName || "")
    percent = Math.max(0, Math.min(100, Math.floor(finiteNumber(printer.percent, 0))))
    nozzleTemp = finiteNumber(printer.nozzleTemp, NaN)
    nozzleTargetTemp = finiteNumber(printer.nozzleTargetTemp, NaN)
    nozzles = Array.isArray(printer.nozzles) ? printer.nozzles : []
    activeNozzle = Math.floor(finiteNumber(printer.activeNozzle, -1))
    bedTemp = finiteNumber(printer.bedTemp, NaN)
    bedTargetTemp = finiteNumber(printer.bedTargetTemp, NaN)
    currentLayer = Math.max(0, Math.floor(finiteNumber(printer.layer, 0)))
    totalLayers = Math.max(0, Math.floor(finiteNumber(printer.totalLayers, 0)))
    remainingMinutes = Math.floor(finiteNumber(printer.remainingMinutes, -1))
    speedLevel = Math.max(0, Math.floor(finiteNumber(printer.speedLevel, 0)))
    speedMagnitude = Math.max(0, Math.floor(finiteNumber(printer.speedMagnitude, 0)))
    wifiSignal = String(printer.wifiSignal || "")
    coolingFanSpeed = finiteNumber(printer.coolingFanSpeed, NaN)
    heatbreakFanSpeed = finiteNumber(printer.heatbreakFanSpeed, NaN)
    lastUpdate = reportUpdate
    productName = String(printer.productName || root.productName || "")
    var camera = objectOrEmpty(printer.camera)
    cameraPresent = camera.present === true
    cameraTransport = String(camera.transport || "none")
    cameraLiveviewEnabled = camera.liveviewEnabled === true
    cameraFfmpegAvailable = camera.ffmpegAvailable === true
    if (root.selectedViewportSource === "camera" && !root.cameraSelectable)
      selectedViewportSource = geometryAssembler.selectedGeometrySource
    firmwareVersion = String(printer.firmwareVersion || root.firmwareVersion || "")
    modelStatus = String(model.status || "idle")
    modelLoadPhase = String(model.loadPhase || "")
    modelLoadProgress = Math.max(-1, Math.min(100,
      Math.floor(finiteNumber(model.loadProgress, -1))))
    modelLoadedBytes = Math.max(0, finiteNumber(model.loadedBytes, 0))
    modelTotalBytes = Math.max(0, finiteNumber(model.totalBytes, 0))
    zCurrent = finiteNumber(model.zCurrent, NaN)
    zMode = String(model.zMode || "unknown")
    var error = objectOrEmpty(model.error)
    modelErrorCode = error.code === null || error.code === undefined
      ? "" : String(error.code)
    modelError = error.message === null || error.message === undefined
      ? "" : String(error.message)
    if (modelErrorCode === "certificate_changed") {
      handleTlsMismatch("FTPS certificate changed. Check and approve the printer again.")
    }
    if (!root.demoActive) {
      var eventContext = {
        printerName: root.displayName,
        productName: root.productName,
        firmwareVersion: root.firmwareVersion,
        jobName: root.subtaskName,
        printerState: root.gcodeState
      }
      eventStore.recordConnection(!stateWasUnknown, wasConnected, root.connected,
                                  eventContext, reportUpdate)
      if (hasFreshReport) {
        eventStore.recordPrintTransition(
          previousGcodeState, root.gcodeState,
          previousSubtaskName, root.subtaskName,
          eventContext, reportUpdate)
        var acknowledgementsBefore = JSON.stringify(
          eventStore.acknowledgedAlertKeys)
        eventStore.reconcileAlerts(printer.alerts, eventContext, reportUpdate)
        if (acknowledgementsBefore !== JSON.stringify(
            eventStore.acknowledgedAlertKeys))
          root.persistEventAcknowledgements()
      }
    }
    if (stateWasUnknown) root.statusAvailable()
  }

  function handleDemoState(message) {
    if (!root.demoActive || message.demoSession !== root.demoSessionId) return
    root.handleState(message)
  }

  function resetOperationalState() {
    finishReadyTimer.stop()
    finishGraceExpired = false
    connected = false
    printerStateKnown = false
    stale = true
    gcodeState = "OFFLINE"
    subtaskName = ""
    percent = 0
    nozzleTemp = NaN
    nozzleTargetTemp = NaN
    nozzles = []
    activeNozzle = -1
    bedTemp = NaN
    bedTargetTemp = NaN
    currentLayer = 0
    totalLayers = 0
    remainingMinutes = -1
    speedLevel = 0
    speedMagnitude = 0
    wifiSignal = ""
    coolingFanSpeed = NaN
    heatbreakFanSpeed = NaN
    lastUpdate = ""
    productName = ""
    firmwareVersion = ""
    modelStatus = "idle"
    modelErrorCode = ""
    modelError = ""
    modelLoadPhase = ""
    modelLoadProgress = -1
    modelLoadedBytes = 0
    modelTotalBytes = 0
    zCurrent = NaN
    zMode = "unknown"
    root.reportProcessError("")
    secretRequired = false
    secretStored = false
    secretStatusKnown = false
    clearTlsProbeState()
    eventStore.deactivateAlerts(new Date().toISOString())
    geometryAssembler.reset(-1)
    selectedViewportSource = "gcode"
    cameraPresent = false
    cameraTransport = "none"
    cameraLiveviewEnabled = false
    cameraFfmpegAvailable = false
    cameraStatus = "idle"
    cameraStatusCode = ""
    cameraStatusMessage = ""
    cameraFramePath = ""
    cameraFrameGeneration = 0
    if (root.cameraSessionRequested) {
      root.writeCommand({ "op": "camera_stop" })
      root.cameraSessionRequested = false
    }
  }

  function handleLine(line) {
    var message
    try {
      message = JSON.parse(String(line || ""))
    } catch (error) {
      return
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) return
    if (message.event === "hello") {
      daemonReady = Number(message.protocol) === 1
      installationId = String(message.installationId || "")
      installationIdentified = installationId !== ""
      geometryAssembler.clearPending()
      if (!daemonReady || !installationIdentified) {
        resetOperationalState()
        root.reportProcessError("Unsupported backend protocol")
        return
      }
      backendSession.markReady()
      root.resetDemoState()
      root.reportProcessError("")
      sendConfiguration()
      return
    }
    if (!daemonReady) return
    if (message.event === "secret_required") {
      if (root.disconnectPending
          && message.requestId === root.disconnectRequestId) {
        root.completeDisconnect()
        return
      }
      secretRequired = true
      secretStored = false
      secretStatusKnown = false
      if (!root.pendingSecretWrite)
        root.attentionRequested("settings", "Enter the LAN access code to connect")
    } else if (message.event === "secret_status") {
      pendingSecretWrite = false
      if (root.disconnectPending
          && message.requestId === root.disconnectRequestId
          && message.stored === false) {
        root.completeDisconnect()
        return
      }
      secretRequired = false
      secretStored = message.stored === true
      secretStatusKnown = true
    } else if (message.event === "tls_required") {
      tlsRejected = !root.hasTrustedTlsPins
      root.attentionRequested("settings",
        "Approve the printer certificate before connecting")
    } else if (message.event === "tls_identity") {
      if (message.requestId !== root.tlsProbeRequestId) return
      var mqttIdentity = objectOrEmpty(message.mqtt)
      var ftpsIdentity = objectOrEmpty(message.ftps)
      if (!root.validTlsFingerprint(mqttIdentity.fingerprint)
          || !root.validTlsFingerprint(ftpsIdentity.fingerprint)) {
        root.clearTlsProbeState()
        root.errorReported("Printer returned an invalid certificate identity")
        return
      }
      root.tlsProbePending = false
      root.tlsApprovalRequired = true
      root.mqttTlsIdentity = mqttIdentity
      root.ftpsTlsIdentity = ftpsIdentity
      root.errorReported("")
    } else if (message.event === "state") {
      if (!root.demoActive) handleState(message)
    } else if (message.event === "demo_state") {
      handleDemoState(message)
    } else if (message.event === "camera_frame") {
      if (!root.validCameraPath(message.path)) return
      cameraFramePath = String(message.path)
      cameraFrameGeneration = isNonNegativeInteger(message.generation)
        ? message.generation : root.cameraFrameGeneration + 1
      cameraStatus = "streaming"
    } else if (message.event === "camera_status") {
      cameraStatus = String(message.state || "idle")
      cameraStatusCode = String(message.code || "")
      cameraStatusMessage = String(message.message || "")
    } else if (String(message.event || "").indexOf("geometry_") === 0) {
      var demoGeometry = message.demoSession !== undefined
      if ((demoGeometry && root.demoActive
           && message.demoSession === root.demoSessionId)
          || (!demoGeometry && !root.demoActive))
        geometryAssembler.handleGeometry(message)
    } else if (message.event === "error") {
      if (message.scope === "demo") {
        if (root.demoActive && message.demoSession === root.demoSessionId) {
          root.modelStatus = "error"
          root.modelErrorCode = String(message.code || "start_failed")
          root.modelError = String(message.message || "Demo could not be started")
          geometryAssembler.setGeneration(-1)
        }
        return
      }
      if (root.disconnectPending
          && message.requestId === root.disconnectRequestId
          && message.scope === "secret") {
        if (message.code === "clear_failed") {
          root.failDisconnect("LAN access code could not be removed")
        } else {
          root.failDisconnect("Printer could not be disconnected")
        }
        Qt.callLater(root.sendConfiguration)
        return
      }
      if (message.scope === "tls" && message.code === "probe_failed") {
        if (message.requestId !== root.tlsProbeRequestId) return
        root.clearTlsProbeState()
        root.errorReported("Unable to read the printer certificate")
        return
      }
      reportProcessError(message.message,
        message.scope === "mqtt" && message.code === "connection")
      if (message.scope === "tls" && message.code === "certificate_changed") {
        handleTlsMismatch("Printer certificate changed. Check it before reconnecting.")
      } else if (message.scope === "mqtt" && message.code === "authentication") {
        handleAuthenticationFailure("LAN access code was rejected. Enter it again")
      } else {
        recoverSecretWrite("LAN code was rejected. Enter it again")
      }
    }
  }

  onGcodeStateChanged: {
    if (root.isFinishedState(root.gcodeState)) {
      if (!finishReadyTimer.running && !root.finishGraceExpired)
        finishReadyTimer.start()
      return
    }
    finishReadyTimer.stop()
    finishGraceExpired = false
  }
  onBackendConfigurationFingerprintChanged: {
    if (!componentReady || persistingSettings) return
    if (root.demoActive) root.stopDemo()
    else resetOperationalState()
    sendConfiguration()
  }
  onShellChanged: root.initialize()

  Connections {
    target: root.shell
    function onShellConfigChanged() { root.refreshSettings() }
  }

  Component.onCompleted: root.initialize()

  onCameraDesiredChanged: root.syncCameraSession()
  onDaemonReadyChanged: root.syncCameraSession()

  BambuGeometryAssembler {
    id: geometryAssembler
    maxSegments: root.segmentLimit()
    segmentDirectory: root.geometryDirectory
    onSelectedGeometrySourceChanged: {
      if (root.selectedViewportSource !== "camera")
        root.selectedViewportSource = geometryAssembler.selectedGeometrySource
    }
  }

  BambuEventStore {
    id: eventStore
  }

  BambuBackendSession {
    id: backendSession
    executable: root.backendPath
    onLineReceived: function(line) { root.handleLine(line) }
    onErrorLineReceived: function(line) { root.handleErrorLine(line) }
    onStopped: root.handleBackendStopped()
    onWriteFailed: root.reportProcessError("Backend command failed")
  }

  Process {
    id: nativeBuild
    command: [root.nativeBuildPath]
    running: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(_) {}
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { console.warn(String(chunk).trim()) }
    }
    onStarted: root.nativeBuildStarted = true
    onExited: function(exitCode) { // qmllint disable signal-handler-parameters
      if (exitCode === 0)
        root.markRendererReady()
      else
        root.markRendererUnavailable()
    }
    onRunningChanged: root.handleNativeBuildRunningChanged()
  }

  Process {
    id: pluginUpdateProcess
    property string action: ""
    property string output: ""
    property string errorOutput: ""
    command: [root.pluginUpdateCheckPath]
    running: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { pluginUpdateProcess.output += String(chunk || "") }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        pluginUpdateProcess.errorOutput += String(chunk || "")
      }
    }
    onExited: function(exitCode) { // qmllint disable signal-handler-parameters
      var action = pluginUpdateProcess.action
      if (action === "check") {
        root.pluginUpdateStatusKnown = exitCode === 0 || exitCode === 1
        root.pluginUpdateAvailable = exitCode === 0
        root.pluginUpdateVersion = exitCode === 0
          ? pluginUpdateProcess.output.trim() : ""
      } else if (exitCode === 0) {
        root.pluginUpdateAvailable = false
        root.pluginUpdateStatusKnown = true
        root.pluginUpdateVersion = ""
        shellRestartProcess.running = true
        if (!shellRestartProcess.running)
          root.pluginUpdateError = "Updated. Run omarchy restart shell to load it"
      } else {
        root.pluginUpdateError = pluginUpdateProcess.errorOutput.trim()
          || "Bambu Companion could not be updated"
      }
      pluginUpdateProcess.action = ""
      pluginUpdateProcess.output = ""
      pluginUpdateProcess.errorOutput = ""
    }
  }

  Process {
    id: shellRestartProcess
    command: ["setsid", "-f", "omarchy", "restart", "shell"]
    running: false
    onExited: function(exitCode) { // qmllint disable signal-handler-parameters
      if (exitCode !== 0)
        root.pluginUpdateError = "Updated. Run omarchy restart shell to load it"
    }
  }

  Timer {
    id: finishReadyTimer
    interval: 60000
    repeat: false
    onTriggered: {
      if (root.isFinishedState(root.gcodeState))
        root.finishGraceExpired = true
    }
  }

  Timer {
    interval: 21600000
    running: root.componentReady
    repeat: true
    onTriggered: root.refreshPluginUpdate()
  }

}
