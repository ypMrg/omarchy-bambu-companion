import QtQuick
import Quickshell
import "plugin" as BambuPlugin

ShellRoot {
  id: root

  property int stage: 0
  property real initialYaw: 0
  property double deadline: Date.now() + 30000
  property bool verifiedStartupAcknowledgement: false

  function finishFailure(message) {
    console.error("BAMBU_SMOKE_FAIL: " + message)
    Qt.quit()
  }

  function finishSuccess() {
    console.log("BAMBU_SMOKE_PASS")
    Qt.quit()
  }

  function findObject(parent, name) {
    if (!parent) return null
    if (parent.objectName === name) return parent
    var children = parent.children || []
    for (var index = 0; index < children.length; index++) {
      var result = findObject(children[index], name)
      if (result) return result
    }
    return null
  }

  QtObject {
    id: fakeShell
    property var shellConfig: ({
      bar: { layout: { left: [], center: [], right: [{
        id: "io.github.ypmrg.bambu-companion",
        acknowledgedAlerts: ["hms:persistent"]
      }] } }
    })
    function updateEntryInline(_, __) {}
  }

  BambuPlugin.BambuService {
    id: service
    shell: fakeShell
    manifest: ({ version: "test" })
  }

  BambuPlugin.BambuDashboard {
    id: dashboard
    width: 1200
    height: 900
    viewportHeight: 760
    service: service
    surfaceActive: true
  }

  Timer {
    interval: 50
    repeat: true
    running: true
    onTriggered: {
      if (Date.now() > root.deadline) {
        root.finishFailure("timeout at stage " + root.stage)
        return
      }
      if (!service.requiresInitialSetup || service.hasConnectionTarget) {
        root.finishFailure("empty configuration unexpectedly targets a printer")
        return
      }
      if (service.cameraSessionRequested) {
        root.finishFailure("offline demo requested a camera session")
        return
      }

      if (root.stage === 0) {
        if (!service.daemonReady || !service.backendRunning) return
        if (!root.verifiedStartupAcknowledgement) {
          service.handleState({ printer: {
            connected: true, stale: true, lastUpdate: "", alerts: []
          }, model: {} })
          service.handleState({ printer: {
            connected: true, stale: false,
            lastUpdate: "2026-08-29T12:00:00Z",
            alerts: [{ id: "hms:persistent", kind: "warning",
              title: "Mainboard notice", description: "Persistent HMS",
              code: "HMS_0500_0200_0003_000A" }]
          }, model: {} })
          var alert = service.eventHistory.find(function(event) {
            return event.alertKey === "hms:persistent"
          })
          if (!alert || !alert.read || service.unreadWarningCount !== 0) {
            root.finishFailure("startup state discarded an HMS acknowledgement")
            return
          }
          root.verifiedStartupAcknowledgement = true
        }
        if (!service.startDemo()) {
          root.finishFailure("demo did not start")
          return
        }
        dashboard.open()
        if (dashboard.viewMode !== "status") {
          root.finishFailure("dashboard did not enter status mode")
          return
        }
        root.stage = 1
        return
      }

      if (root.stage === 1) {
        if (service.modelStatus !== "ready" || !service.gcodeGeometryAvailable
            || service.rendererStatus !== "ready") return
        if (service.selectedViewportSource !== "gcode"
            || service.activeSegmentCount <= 0
            || service.activeSegmentPath === "") {
          root.finishFailure("demo geometry is incomplete")
          return
        }
        var viewport = root.findObject(dashboard, "bambuModelViewport")
        if (!viewport || !viewport.routeItemReady) return
        root.initialYaw = viewport.routeYaw
        root.stage = 2
        return
      }

      var activeViewport = root.findObject(dashboard, "bambuModelViewport")
      if (!activeViewport || !activeViewport.routeItemReady) {
        root.finishFailure("native route item disappeared")
        return
      }
      if (Math.abs(activeViewport.routeYaw - root.initialYaw) <= 0.0001) return
      if (service.demoActive) service.stopDemo()
      root.finishSuccess()
    }
  }
}
