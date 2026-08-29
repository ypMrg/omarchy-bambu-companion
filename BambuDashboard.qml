import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  BambuStyle { id: bambuStyle }

  required property var service
  required property real viewportHeight
  property bool surfaceActive: false
  property string cameraSurfaceRole: "popup"
  property bool showOpenAppButton: false
  property string viewMode: "setup"
  readonly property bool cameraSurfaceVisible: !!root.service
    && root.surfaceActive && root.viewMode === "status"
    && root.service.selectedViewportSource === "camera"
  property bool componentReady: false
  property alias focusTarget: keyCatcher

  readonly property color foreground: Color.foreground
  readonly property color accent: Color.accent
  readonly property color successColor: "#39FF88"
  readonly property color errorColor: "#ff5f56"
  readonly property color warningColor: "#ff9f43"
  readonly property color dim: Qt.rgba(foreground.r, foreground.g,
                                       foreground.b, 0.55)
  readonly property string fontFamily: bambuStyle.fontFamily
  readonly property real preferredViewportHeight:
    Math.max(Style.space(520), telemetryPane.implicitHeight)

  signal closeRequested()
  signal openAppRequested()

  function nextIdleView() {
    if (root.service && root.service.demoActive) return "status"
    if (!root.service || root.service.requiresInitialSetup) return "setup"
    if (root.service.printerStateKnown) return "status"
    return "connecting"
  }

  function open() {
    if (!root.service) return
    if (root.viewMode !== "settings") root.viewMode = root.nextIdleView()
    if (root.viewMode === "setup") settingsView.load(root.service.settingsDraft())
    root.focusPanelTop()
  }

  function close() {
    if (!root.service || root.service.disconnectPending) return
    root.service.cancelSecurityModal()
    settingsView.clearAccessCode()
    root.viewMode = root.nextIdleView()
  }

  function focusPanelTop() {
    Qt.callLater(function() {
      panelScroll.contentY = 0
      keyCatcher.forceActiveFocus()
    })
  }

  function enterConnecting() {
    settingsView.clearAccessCode()
    if (root.service.printerStateKnown)
      root.viewMode = "status"
    else
      root.viewMode = root.service.hasConnectionTarget ? "connecting" : "setup"
    root.focusPanelTop()
  }

  function openSettings(message) {
    settingsView.load(root.service.settingsDraft())
    settingsView.reportError(String(message || ""))
    root.viewMode = "settings"
    root.focusPanelTop()
  }

  function showAttention(mode, message) {
    var requestedMode = String(mode || "settings")
    if (requestedMode === "settings") {
      root.openSettings(message)
      return
    }
    root.viewMode = requestedMode
    if (requestedMode === "setup") settingsView.load(root.service.settingsDraft())
    if (message) settingsView.reportError(String(message))
    root.focusPanelTop()
  }

  function toggleSettings() {
    if (root.viewMode === "settings") root.backToStatus()
    else root.openSettings("")
  }

  function toggleEvents() {
    if (root.viewMode === "events") root.backToStatus()
    else {
      root.viewMode = "events"
      root.focusPanelTop()
    }
  }

  function backToStatus() {
    if (!root.service.demoActive && !root.service.requiresInitialSetup
        && !root.service.printerStateKnown) {
      root.enterConnecting()
      return
    }
    settingsView.clearAccessCode()
    root.viewMode = "status"
    root.focusPanelTop()
  }

  function applyOperationResult(result, preserveAccessCode) {
    var response = result && typeof result === "object" ? result : ({})
    if (response.ok !== true) {
      settingsView.reportError(String(response.error
        || "The requested change could not be applied"))
      return false
    }
    settingsView.reportError("")
    if (!preserveAccessCode) settingsView.clearAccessCode()
    if (response.mode && response.mode !== "settings") {
      if (response.mode === "connecting" && root.service.printerStateKnown)
        root.viewMode = "status"
      else
        root.viewMode = response.mode
      root.focusPanelTop()
    }
    return true
  }

  function reportCameraSurface() {
    if (!root.service) return
    if (root.cameraSurfaceRole === "window")
      root.service.windowCameraVisible = root.cameraSurfaceVisible
    else
      root.service.popupCameraVisible = root.cameraSurfaceVisible
  }

  onSurfaceActiveChanged: {
    if (!root.componentReady) return
    if (root.surfaceActive) root.open()
    else root.close()
  }

  onCameraSurfaceVisibleChanged: root.reportCameraSurface()
  Component.onDestruction: {
    if (!root.service) return
    if (root.cameraSurfaceRole === "window")
      root.service.windowCameraVisible = false
    else
      root.service.popupCameraVisible = false
  }

  Component.onCompleted: {
    root.componentReady = true
    root.viewMode = root.nextIdleView()
    if (root.surfaceActive) root.open()
  }

  Connections {
    target: root.service

    function onErrorReported(message) {
      if (root.surfaceActive && root.viewMode === "settings")
        settingsView.reportError(message)
    }

    function onStatusAvailable() {
      if (root.viewMode === "connecting") root.viewMode = "status"
    }

    function onPrinterStateKnownChanged() {
      if (root.service.printerStateKnown && root.viewMode === "connecting")
        root.viewMode = "status"
    }

    function onRequiresInitialSetupChanged() {
      if (!root.surfaceActive || !root.service.requiresInitialSetup
          || root.viewMode === "settings") return
      root.viewMode = "setup"
      settingsView.load(root.service.settingsDraft())
      root.focusPanelTop()
    }
  }

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    clip: true
    blocked: settingsView.inputActive || root.service.securityModalMode !== ""

    Rectangle {
      id: panelBackdrop
      anchors.fill: parent
      readonly property color baseColor: bambuStyle.popupBackground
      color: Qt.rgba(
        baseColor.r * 0.94 + root.foreground.r * 0.06,
        baseColor.g * 0.94 + root.foreground.g * 0.06,
        baseColor.b * 0.94 + root.foreground.b * 0.06,
        1.0)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g,
                            root.foreground.b, 0.18)
    }

    onCloseRequested: {
      if (root.service.securityModalMode !== "") {
        root.service.cancelSecurityModal()
        root.focusPanelTop()
      } else if (root.viewMode === "setup" || root.viewMode === "settings"
                 || root.viewMode === "events") {
        root.backToStatus()
      } else {
        root.closeRequested()
      }
    }

    Flickable {
      id: panelScroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: dashboard.height
      flickableDirection: Flickable.VerticalFlick
      boundsBehavior: Flickable.StopAtBounds
      interactive: !dashboard.wideLayout
      clip: true

      Item {
        id: dashboard
        width: panelScroll.width
        height: wideLayout ? root.viewportHeight
          : paneHeight * 2 + dashboardLayout.spacing
        readonly property bool wideLayout: width >= Style.space(640)
        readonly property real paneHeight: Style.space(500)
        readonly property real overlayX: wideLayout
          ? telemetryPane.width + dashboardLayout.spacing : 0
        readonly property real overlayY: wideLayout ? 0 : panelScroll.contentY
        readonly property real overlayWidth: wideLayout
          ? Math.max(0, width - overlayX) : width
        readonly property real overlayHeight: root.viewportHeight

        Grid {
          id: dashboardLayout
          anchors.fill: parent
          columns: dashboard.wideLayout ? 2 : 1
          spacing: 1

          BambuTelemetryPane {
            id: telemetryPane
            width: dashboard.wideLayout ? Style.space(300) : dashboard.width
            height: dashboard.wideLayout
              ? root.viewportHeight : dashboard.paneHeight
            foreground: root.foreground
            accent: root.accent
            dim: root.dim
            successColor: root.successColor
            errorColor: root.errorColor
            errorActive: root.service.errorActive
            modelErrorActive: root.service.modelErrorActive
            fontFamily: root.fontFamily
            printerIconSource: root.service.printerIconSource
            demoActive: root.service.demoActive
            printerName: root.service.demoActive
              ? "OMARCHY DEMO" : root.service.displayName
            online: root.service.connected && !root.service.stale
            printerState: root.service.displayGcodeState
            jobName: root.service.subtaskName || "NO ACTIVE PRINT"
            percent: root.service.percent
            remainingValue: root.service.formatDuration(root.service.remainingMinutes)
            dualNozzles: root.service.hasDualNozzles()
            nozzleLeftValue: root.service.formatNozzle(0)
            nozzleRightValue: root.service.formatNozzle(1)
            nozzleLeftActive: root.service.activeNozzle === 0
            nozzleRightActive: root.service.activeNozzle === 1
            bedValue: root.service.formatTempPair(
              root.service.bedTemp, root.service.bedTargetTemp)
            layerValue: (root.service.currentLayer || "--") + " / "
              + (root.service.totalLayers || "--")
            zValue: isFinite(root.service.zCurrent)
              ? root.service.zCurrent.toFixed(2) + " mm"
                + (root.service.zMode === "estimated" ? " EST." : "") : "--"
            speedValue: root.service.speedLabel()
            fanValue: "PART " + root.service.formatFan(root.service.coolingFanSpeed)
              + " · HOTEND " + root.service.formatFan(root.service.heatbreakFanSpeed)
            hostValue: root.service.demoActive ? "LOCAL ASSET" : root.service.host || "--"
            portsValue: root.service.demoActive ? "NO NETWORK"
              : "MQTT " + root.service.mqttPort + " · FTPS " + root.service.ftpsPort
            wifiValue: root.service.wifiSignal || "--"
            reportValue: root.service.formatLastUpdate()
            segmentValue: root.service.activeSegmentCount.toLocaleString(
              Qt.locale(), "f", 0) + " SEGMENTS"
            modelState: root.service.modelStatus.toUpperCase()
            dimensionsValue: root.service.formatDimensions()
            appVersion: root.service.currentVersion
            updateAvailable: root.service.pluginUpdateAvailable
            updateStatusKnown: root.service.pluginUpdateStatusKnown
            updateBusy: root.service.pluginUpdateBusy
            updateInstalling: root.service.pluginUpdateInstalling
            updateVersion: root.service.pluginUpdateVersion
            updateError: root.service.pluginUpdateError
            appButtonVisible: root.showOpenAppButton
            onSettingsRequested: root.toggleSettings()
            onAppRequested: root.openAppRequested()
            onUpdateRequested: root.service.installPluginUpdate()
          }

          BambuModelViewport {
            objectName: "bambuModelViewport"
            width: dashboard.wideLayout
              ? Math.max(0, dashboard.width - telemetryPane.width
                         - dashboardLayout.spacing) : dashboard.width
            height: dashboard.wideLayout
              ? root.viewportHeight : dashboard.paneHeight
            foreground: root.foreground
            accent: root.accent
            dim: root.dim
            errorColor: root.errorColor
            errorActive: root.service.errorActive || root.service.modelErrorActive
            fontFamily: root.fontFamily
            panelActive: root.surfaceActive && root.viewMode === "status"
            printerConfigured: root.service.hasConnectionTarget
              || root.service.demoActive
            daemonReady: root.service.daemonReady && root.service.backendRunning
            printing: root.service.demoActive
              || (root.service.connected && root.service.gcodeState === "RUNNING")
            eventsActive: root.viewMode === "events"
            unreadEventCount: root.service.unreadEventCount
            unreadErrorCount: root.service.unreadErrorCount
            unreadWarningCount: root.service.unreadWarningCount
            warningColor: root.warningColor
            previewAvailable: root.service.previewAvailable
            gcodeAvailable: root.service.gcodeGeometryAvailable
            cameraAvailable: root.service.cameraSelectable
            cameraFrameAvailable: root.service.cameraFrameAvailable
            cameraStatus: root.service.cameraStatus
            cameraStatusCode: root.service.cameraStatusCode
            cameraStatusMessage: root.service.cameraStatusMessage
            selectedSource: root.service.selectedViewportSource
            previewSource: root.service.previewAvailable
              ? root.service.geometryBundle.preview.url : ""
            cameraFrameSource: root.service.cameraFrameSource
            activeSegmentPath: root.service.activeSegmentPath
            activeBounds: root.service.activeBounds
            zCurrent: root.service.zCurrent
            autoRotateDefault: root.service.autoRotate
            explosionFactor: root.service.explosionFactor
            modelStatus: root.service.modelStatus
            modelError: root.service.modelError || root.service.processError
            modelLoadPhase: root.service.modelLoadPhase
            modelLoadProgress: root.service.modelLoadProgress
            modelLoadedBytes: root.service.modelLoadedBytes
            modelTotalBytes: root.service.modelTotalBytes
            rendererStatus: root.service.rendererStatus
            nativeRouteUrl: root.service.nativeRouteUrl
            onSourceRequested: function(source) {
              root.service.selectViewportSource(source)
            }
            onReloadRequested: {
              if (root.service.selectedViewportSource === "camera")
                root.service.snapshotCamera()
              else
                root.service.refreshModel()
            }
            onEventsRequested: root.toggleEvents()
            onRendererLoadFailed: root.service.markRendererUnavailable()
          }
        }

        Rectangle {
          visible: dashboard.wideLayout
          x: telemetryPane.width
          y: 0
          width: 1
          height: dashboard.height
          color: Qt.rgba(root.foreground.r, root.foreground.g,
                         root.foreground.b, 0.12)
        }

        Rectangle {
          visible: root.viewMode === "setup" || root.viewMode === "settings"
            || root.viewMode === "events"
          x: dashboard.overlayX
          y: dashboard.overlayY
          width: dashboard.overlayWidth
          height: dashboard.overlayHeight
          z: 20
          color: panelBackdrop.color
        }

        BambuSettingsView {
          id: settingsView
          visible: root.viewMode === "setup" || root.viewMode === "settings"
          x: dashboard.overlayX
          y: dashboard.overlayY
          width: dashboard.overlayWidth
          height: dashboard.overlayHeight
          z: 21
          foreground: root.foreground
          accent: root.accent
          errorColor: root.errorColor
          dim: root.dim
          fontFamily: root.fontFamily
          daemonReady: root.service.daemonReady && root.service.backendRunning
          allowBack: true
          canDisconnect: root.service.hasConnectionTarget || root.service.hasUsableSecret
          demoAvailable: root.service.requiresInitialSetup
          demoActive: root.service.demoActive
          requireAccessCode: !root.service.hasUsableSecret
          secretRequired: root.service.secretRequired
          secretStored: root.service.secretStored
          secretStatusKnown: root.service.secretStatusKnown
          onBackRequested: {
            root.backToStatus()
          }
          onBarSummaryToggled: function(enabled) {
            if (!root.service.persistBarSummary(enabled)) {
              settingsView.showBarSummary = root.service.showBarSummary
              settingsView.reportError("Bar summary setting could not be saved")
            }
          }
          onForgetCodeRequested: {
            if (root.service.clearSecret()) settingsView.clearAccessCode()
            else settingsView.reportError("LAN code could not be removed")
          }
          onDisconnectRequested: root.service.requestDisconnect()
          onDemoRequested: {
            if (root.service.demoActive) {
              root.service.stopDemo()
            } else if (root.service.startDemo()) {
              root.viewMode = "status"
              root.focusPanelTop()
            } else {
              settingsView.reportError("Demo could not be started")
            }
          }
          onInputFocusReleased: keyCatcher.forceActiveFocus()
          onSaveRequested: function(draft, accessCode) {
            var result = root.service.saveSettings(draft, accessCode)
            root.applyOperationResult(result, result && result.mode === "settings")
          }
          onTrustRequested: function(draft, accessCode) {
            root.applyOperationResult(
              root.service.trustAndConnect(draft, accessCode), false)
          }
        }

        BambuEventHistory {
          visible: root.viewMode === "events"
          x: dashboard.overlayX
          y: dashboard.overlayY
          width: dashboard.overlayWidth
          height: dashboard.overlayHeight
          z: 23
          service: root.service
          foreground: root.foreground
          accent: root.accent
          errorColor: root.errorColor
          warningColor: root.warningColor
          successColor: root.successColor
          dim: root.dim
          background: panelBackdrop.color
          fontFamily: root.fontFamily
          onCloseRequested: root.backToStatus()
        }

        Item {
          visible: root.viewMode === "connecting"
          x: dashboard.overlayX
          y: dashboard.overlayY
          width: dashboard.overlayWidth
          height: dashboard.overlayHeight
          z: 22

          Rectangle {
            anchors.fill: parent
            color: panelBackdrop.color
          }

          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Style.space(32), Style.space(320))
            spacing: Style.space(10)

            Item {
              width: Style.space(48)
              height: width
              anchors.horizontalCenter: parent.horizontalCenter

              BambuPrinterIcon {
                anchors.fill: parent
                source: root.service.printerIconSource
                tintColor: root.foreground
              }

              RotationAnimator on rotation {
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                running: root.surfaceActive && root.viewMode === "connecting"
              }
            }

            Text {
              width: parent.width
              text: "CONNECTING TO " + root.service.displayName.toUpperCase()
              color: root.foreground
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: bambuStyle.subtitleFontSize
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.service.processError || "Waiting for a fresh printer report…"
              color: root.service.processError ? root.errorColor : root.dim
              wrapMode: Text.Wrap
              horizontalAlignment: Text.AlignHCenter
              font.family: root.fontFamily
              font.pixelSize: bambuStyle.bodySmallFontSize
            }

            BambuButton {
              width: parent.width
              height: Style.space(34)
              clip: true
              text: "EDIT CONFIGURATION"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              onClicked: root.openSettings("")
            }
          }
        }

        BambuButton {
          visible: !root.service.demoActive && root.service.secretRequired
                   && root.viewMode === "status"
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(54)
          z: 24
          width: Math.min(parent.width - Style.space(24), Style.space(320))
          text: "ENTER LAN CODE IN SETTINGS"
          foreground: root.foreground
          accent: root.accent
          bordered: true
          onClicked: root.openSettings("")
        }
      }
    }

    BambuSecurityDialog {
      anchors.fill: parent
      z: 40
      mode: root.service.securityModalMode
      probing: root.service.tlsProbePending
      processing: root.service.disconnectPending
      mqttIdentity: root.service.mqttTlsIdentity
      ftpsIdentity: root.service.ftpsTlsIdentity
      foreground: root.foreground
      accent: root.accent
      errorColor: root.errorColor
      background: panelBackdrop.color
      fontFamily: root.fontFamily
      onCancelRequested: {
        root.service.cancelSecurityModal()
        root.focusPanelTop()
      }
      onTrustRequested: settingsView.submit(true)
      onDisconnectRequested: root.service.confirmDisconnect()
    }
  }
}
