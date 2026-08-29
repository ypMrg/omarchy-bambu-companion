import QtQuick
import Quickshell

ShellRoot {
  id: root

  function fail(message) {
    console.error("BAMBU_EVENT_STORE_FAIL: " + message)
    Qt.quit()
  }

  function check(value, message) {
    if (!value) throw new Error(message)
  }

  function compare(actual, expected, message) {
    if (actual !== expected) {
      throw new Error(message + ": expected " + expected + ", got " + actual)
    }
  }

  function resetStore() {
    store.events = []
    store.activeAlerts = ({})
    store.nextEventId = 1
    store.demoEventsLoaded = false
    store.recount()
  }

  function context() {
    return {
      printerName: "Workshop",
      productName: "Bambu Lab P1S",
      firmwareVersion: "1.2.3",
      jobName: "benchy.gcode.3mf",
      printerState: "RUNNING"
    }
  }

  function verifyPrintTimeline() {
    resetStore()
    store.recordPrintTransition("IDLE", "RUNNING", "", "benchy.gcode.3mf",
                                context(), "2026-08-21T12:00:00Z")
    compare(store.events.length, 1, "started event count")
    compare(store.events[0].title, "Print started", "started event title")
    check(store.events[0].read, "started event should be read")

    store.recordPrintTransition("RUNNING", "PAUSE", "benchy.gcode.3mf",
                                "benchy.gcode.3mf", context(),
                                "2026-08-21T12:01:00Z")
    compare(store.unreadWarningCount, 1, "pause warning count")
    compare(store.unreadErrorCount, 0, "pause error count")
  }

  function verifyAlerts() {
    resetStore()
    store.reconcileAlerts([{ id: "maintenance", kind: "warning",
      title: "Maintenance", description: "Lubricate", code: "HMS_TEST" }],
      context(), "2026-08-21T12:00:00Z")
    compare(store.activeErrorCount, 0, "maintenance active errors")
    compare(store.unreadWarningCount, 1, "maintenance unread warnings")
    check(store.events[0].active, "maintenance should be active")

    var maintenanceId = store.events[0].id
    store.reconcileAlerts([{ id: "maintenance", kind: "warning",
      title: "Maintenance", description: "Lubricate", code: "HMS_TEST" }],
      context(), "2026-08-21T12:00:30Z")
    compare(store.events.length, 1, "duplicate maintenance event")
    compare(store.events[0].id, maintenanceId, "maintenance identity")

    store.reconcileAlerts([{ id: "fault", kind: "error",
      title: "Print error", description: "Stopped", code: "0x12345678" }],
      context(), "2026-08-21T12:01:00Z")
    compare(store.activeErrorCount, 1, "fault active errors")
    compare(store.unreadErrorCount, 1, "fault unread errors")
    check(store.events[1].clearedAt !== "", "maintenance should be cleared")

    check(store.markRead(store.events[0].id), "markRead should change state")
    compare(store.unreadErrorCount, 0, "unread errors after markRead")
    check(store.markAllRead(), "markAllRead should change state")
    compare(store.unreadCount, 0, "unread count after markAllRead")

    store.reconcileAlerts([], context(), "2026-08-21T12:02:00Z")
    compare(store.activeErrorCount, 0, "active errors after clear")
    check(store.events[0].clearedAt !== "", "fault should be cleared")
  }

  function verifyDemoFixture() {
    resetStore()
    check(store.loadDemoEvents(), "demo fixture should load")
    compare(store.events.length, 28, "demo event count")
    compare(store.unreadErrorCount, 2, "demo unread errors")
    compare(store.unreadWarningCount, 2, "demo unread warnings")
    compare(store.activeErrorCount, 0, "demo active errors")
    compare(store.events[0].source, "demo", "demo source")
    compare(store.events[0].title, "Printer error", "demo title")
    check(store.events[0].description.indexOf("No real printer") >= 0,
          "demo disclosure")
    check(store.events[2].active, "demo warning should be active")
    compare(store.events[2].severity, "warning", "demo warning severity")
    check(store.events[27].read, "oldest demo event should be read")
    check(store.events[27].timestamp < store.events[0].timestamp,
          "demo events should be ordered")
    check(!store.loadDemoEvents(), "demo fixture should be idempotent")
    compare(store.events.length, 28, "idempotent demo event count")
    check(store.clearDemoEvents(), "demo fixture should clear")
    compare(store.events.length, 0, "cleared demo event count")
    compare(store.unreadCount, 0, "cleared demo unread count")
    compare(store.activeErrorCount, 0, "cleared demo active errors")
  }

  function verifyAcknowledgementPersistence() {
    resetStore()
    store.setAcknowledgedAlertKeys([])
    var alert = { id: "hms:persistent", kind: "warning",
      title: "Mainboard notice", description: "Persistent HMS",
      code: "HMS_0500_0200_0003_000A" }
    store.reconcileAlerts([alert], context(), "2026-08-21T12:00:00Z")
    check(store.markRead(store.events[0].id), "persistent alert should be marked read")
    var saved = JSON.parse(JSON.stringify(store.acknowledgedAlertKeys))
    compare(saved.length, 1, "saved acknowledgement count")

    resetStore()
    store.setAcknowledgedAlertKeys(saved)
    store.reconcileAlerts([alert], context(), "2026-08-21T12:01:00Z")
    check(store.events[0].read, "acknowledged alert should remain read after restart")
    compare(store.unreadWarningCount, 0, "restored unread warning count")

    store.reconcileAlerts([], context(), "2026-08-21T12:02:00Z")
    compare(store.acknowledgedAlertKeys.length, 1,
            "resolved alert acknowledgement should remain persistent")

    resetStore()
    store.setAcknowledgedAlertKeys(saved)
    store.reconcileAlerts([alert], context(), "2026-08-22T12:00:00Z")
    check(store.events[0].read,
          "recurring alert code should remain acknowledged after restart")
  }

  BambuEventStore { id: store }

  Component.onCompleted: Qt.callLater(function() {
    try {
      root.verifyPrintTimeline()
      root.verifyAlerts()
      root.verifyAcknowledgementPersistence()
      root.verifyDemoFixture()
      console.log("BAMBU_EVENT_STORE_PASS")
      Qt.quit()
    } catch (error) {
      root.fail(String(error))
    }
  })
}
