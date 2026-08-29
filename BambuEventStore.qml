pragma ComponentBehavior: Bound

import QtQuick

QtObject {
  id: store

  property var events: []
  property var activeAlerts: ({})
  property int nextEventId: 1
  property int unreadCount: 0
  property int unreadErrorCount: 0
  property int unreadWarningCount: 0
  property int activeErrorCount: 0
  property bool demoEventsLoaded: false
  readonly property int maximumEvents: 200
  property var acknowledgedAlertKeys: []
  readonly property int maximumAcknowledgedAlerts: 100

  function normalizedAlertKey(value) {
    var key = String(value || "").trim()
    if (!key) return ""
    return key.slice(0, 256)
  }

  function setAcknowledgedAlertKeys(values) {
    var source = Array.isArray(values) ? values : []
    var seen = ({})
    var normalized = []
    for (var index = 0; index < source.length; index++) {
      var key = store.normalizedAlertKey(source[index])
      if (!key || seen[key]) continue
      seen[key] = true
      normalized.push(key)
      if (normalized.length >= store.maximumAcknowledgedAlerts) break
    }
    if (JSON.stringify(normalized) !== JSON.stringify(store.acknowledgedAlertKeys))
      store.acknowledgedAlertKeys = normalized
  }

  function isAlertAcknowledged(value) {
    return store.acknowledgedAlertKeys.indexOf(
      store.normalizedAlertKey(value)) >= 0
  }

  function acknowledgeAlertKey(value) {
    var key = store.normalizedAlertKey(value)
    if (!key || store.isAlertAcknowledged(key)) return false
    var updated = [key].concat(store.acknowledgedAlertKeys)
    store.acknowledgedAlertKeys = updated.slice(
      0, store.maximumAcknowledgedAlerts)
    return true
  }

  function timestamp(value) {
    var parsed = new Date(String(value || ""))
    return isNaN(parsed.getTime()) ? new Date().toISOString() : parsed.toISOString()
  }

  function appendEvent(values) {
    values = values && typeof values === "object" ? values : ({})
    var record = {
      id: store.nextEventId++,
      timestamp: store.timestamp(values.timestamp),
      clearedAt: String(values.clearedAt || ""),
      category: String(values.category || "printer"),
      action: String(values.action || "event"),
      severity: String(values.severity || "info"),
      title: String(values.title || "Printer event"),
      summary: String(values.summary || ""),
      description: String(values.description || values.summary || ""),
      code: String(values.code || ""),
      alertKey: store.normalizedAlertKey(values.alertKey),
      source: String(values.source || "printer"),
      module: String(values.module || ""),
      severityName: String(values.severityName || ""),
      severityLevel: Number(values.severityLevel || 0),
      rawAttr: values.rawAttr === undefined ? null : values.rawAttr,
      rawCode: values.rawCode === undefined ? null : values.rawCode,
      jobName: String(values.jobName || ""),
      printerState: String(values.printerState || ""),
      printerName: String(values.printerName || ""),
      productName: String(values.productName || ""),
      firmwareVersion: String(values.firmwareVersion || ""),
      active: values.active === true,
      read: values.read === true
    }
    var updated = [record].concat(store.events)
    if (updated.length > store.maximumEvents)
      updated = updated.slice(0, store.maximumEvents)
    store.events = updated
    store.recount()
    return record.id
  }

  function replaceEvent(id, changes) {
    var changed = false
    var updated = store.events.map(function(event) {
      if (event.id !== id) return event
      var copy = ({})
      for (var key in event) copy[key] = event[key]
      for (var changeKey in changes) copy[changeKey] = changes[changeKey]
      changed = true
      return copy
    })
    if (changed) {
      store.events = updated
      store.recount()
    }
    return changed
  }

  function eventById(id) {
    for (var index = 0; index < store.events.length; index++) {
      if (store.events[index].id === id) return store.events[index]
    }
    return null
  }

  function markRead(id) {
    var event = store.eventById(id)
    if (!event || event.read) return false
    var changed = store.replaceEvent(id, { read: true })
    if (changed && event.category === "alert")
      store.acknowledgeAlertKey(event.alertKey)
    return changed
  }

  function markAllRead() {
    var changed = false
    var updated = store.events.map(function(event) {
      if (event.read) return event
      var copy = ({})
      for (var key in event) copy[key] = event[key]
      copy.read = true
      if (event.category === "alert")
        store.acknowledgeAlertKey(event.alertKey)
      changed = true
      return copy
    })
    if (changed) {
      store.events = updated
      store.recount()
    }
    return changed
  }

  function recount() {
    var unread = 0
    var unreadErrors = 0
    var unreadWarnings = 0
    for (var index = 0; index < store.events.length; index++) {
      var event = store.events[index]
      if (event.read) continue
      unread++
      if (event.severity === "error") unreadErrors++
      else if (event.severity === "warning") unreadWarnings++
    }
    var activeErrors = 0
    for (var key in store.activeAlerts) {
      var active = store.activeAlerts[key]
      if (active.severity === "error") activeErrors++
    }
    store.unreadCount = unread
    store.unreadErrorCount = unreadErrors
    store.unreadWarningCount = unreadWarnings
    store.activeErrorCount = activeErrors
  }

  function recordConnection(wasKnown, wasConnected, connected, context, at) {
    if (wasKnown && wasConnected === connected) return
    if (!wasKnown && !connected) return
    store.appendEvent({
      timestamp: at,
      category: "connection",
      action: connected ? "connected" : "disconnected",
      severity: "info",
      title: connected ? "Printer connected" : "Printer disconnected",
      summary: connected ? "Live printer reports are available."
        : "The live printer connection ended.",
      description: connected
        ? "Bambu Companion established its read-only monitoring connection."
        : "Bambu Companion is waiting to reconnect to the printer.",
      source: "connection",
      printerName: context.printerName,
      productName: context.productName,
      firmwareVersion: context.firmwareVersion,
      read: true
    })
  }

  function recordPrintTransition(previousState, nextState, previousJob, nextJob,
                                 context, at) {
    var before = String(previousState || "").toUpperCase()
    var after = String(nextState || "").toUpperCase()
    if (before === after) {
      if (after === "RUNNING" && !previousJob && nextJob) {
        store.appendEvent({
          timestamp: at, category: "print", action: "file",
          severity: "info", title: "Print file identified",
          summary: String(nextJob),
          description: "The printer supplied the file name for the active job.",
          jobName: nextJob, printerState: after,
          printerName: context.printerName,
          productName: context.productName,
          firmwareVersion: context.firmwareVersion,
          read: true
        })
      }
      return
    }

    var job = String(nextJob || previousJob || "")
    var values = null
    if (after === "RUNNING" && before === "PAUSE") {
      values = { action: "resumed", severity: "info", title: "Print resumed",
        summary: job || "The active print resumed." }
    } else if (after === "RUNNING") {
      values = { action: "started", severity: "info", title: "Print started",
        summary: job || "The printer started a new job." }
    } else if (after === "PAUSE" || after === "PAUSED") {
      values = { action: "paused", severity: "warning", title: "Print paused",
        summary: job || "The active print is paused." }
    } else if (["FINISH", "FINISHED", "COMPLETE", "COMPLETED"].indexOf(after) >= 0) {
      values = { action: "completed", severity: "success", title: "Print completed",
        summary: job || "The print completed successfully." }
    } else if (after === "FAILED" || after.indexOf("ERROR") >= 0) {
      values = { action: "failed", severity: "error", title: "Print failed",
        summary: job || "The printer entered an error state." }
    } else if ((before === "RUNNING" || before === "PREPARE") && after === "IDLE") {
      values = { action: "stopped", severity: "info", title: "Print stopped",
        summary: job || "The active print ended before completion." }
    }
    if (!values) return

    values.timestamp = at
    values.category = "print"
    values.description = values.summary
    values.jobName = job
    values.printerState = after
    values.printerName = context.printerName
    values.productName = context.productName
    values.firmwareVersion = context.firmwareVersion
    values.read = values.severity === "info" || values.severity === "success"
    store.appendEvent(values)
  }

  function reconcileAlerts(alerts, context, at) {
    var incoming = ({})
    var changed = false
    var list = Array.isArray(alerts) ? alerts : []
    for (var index = 0; index < list.length; index++) {
      var alert = list[index]
      if (!alert || typeof alert !== "object") continue
      var key = String(alert.id || alert.code || "")
      if (!key || incoming[key]) continue
      var severity = String(alert.kind || "warning") === "error" ? "error" : "warning"
      var existing = store.activeAlerts[key]
      if (existing) {
        incoming[key] = existing
        continue
      }
      var eventId = store.appendEvent({
        timestamp: at,
        category: "alert",
        action: "raised",
        severity: severity,
        title: String(alert.title || (severity === "error" ? "Printer error" : "Printer notice")),
        summary: String(alert.description || alert.code || "Printer alert"),
        description: String(alert.description || "No explanation was supplied by the printer."),
        code: String(alert.code || ""),
        alertKey: key,
        source: String(alert.source || "hms"),
        module: String(alert.module || ""),
        severityName: String(alert.severity || ""),
        severityLevel: Number(alert.severityLevel || 0),
        rawAttr: alert.rawAttr,
        rawCode: alert.rawCode,
        jobName: String(context.jobName || ""),
        printerState: String(context.printerState || ""),
        printerName: String(context.printerName || ""),
        productName: String(context.productName || ""),
        firmwareVersion: String(context.firmwareVersion || ""),
        active: true,
        read: store.isAlertAcknowledged(key)
      })
      incoming[key] = { eventId: eventId, severity: severity }
      changed = true
    }

    for (var activeKey in store.activeAlerts) {
      if (incoming[activeKey]) continue
      var prior = store.activeAlerts[activeKey]
      store.replaceEvent(prior.eventId, {
        active: false,
        clearedAt: store.timestamp(at)
      })
      changed = true
    }
    if (!changed) return
    store.activeAlerts = incoming
    store.recount()
  }

  function deactivateAlerts(at) {
    for (var key in store.activeAlerts) {
      store.replaceEvent(store.activeAlerts[key].eventId, {
        active: false,
        clearedAt: store.timestamp(at)
      })
    }
    store.activeAlerts = ({})
    store.recount()
  }

  function demoTimestamp(minutesAgo) {
    return new Date(Date.now() - Number(minutesAgo || 0) * 60000).toISOString()
  }

  function loadDemoEvents() {
    if (store.demoEventsLoaded) return false
    store.demoEventsLoaded = true

    var printer = "DEMO PRINTER"
    var product = "Demo event fixture"
    var firmware = "DEMO"
    var jobs = [
      "Demo-Benchy.gcode.3mf",
      "Demo-Desk-Hook.gcode.3mf",
      "Demo-Gear-Set.gcode.3mf",
      "Demo-Calibration-Cube.gcode.3mf"
    ]
    var templates = [
      { ago: 34, category: "connection", action: "connected", severity: "info",
        title: "Printer connected", summary: "Read-only monitoring session established.",
        description: "Demo connection event. No real printer connection was changed.",
        state: "", read: true },
      { ago: 31, category: "print", action: "started", severity: "info",
        title: "Print started", summary: "$JOB",
        description: "Demo print-start event for exploring the event log.",
        state: "RUNNING", read: true },
      { ago: 22, category: "print", action: "paused", severity: "warning",
        title: "Print paused", summary: "Filament change requested.",
        description: "Demo pause event. No real printer was paused.",
        state: "PAUSE", read: false },
      { ago: 20, category: "print", action: "resumed", severity: "info",
        title: "Print resumed", summary: "$JOB",
        description: "Demo resume event. No real printer was controlled.",
        state: "RUNNING", read: true },
      { ago: 14, category: "alert", action: "raised", severity: "warning",
        title: "Maintenance reminder",
        summary: "Routine lead-screw lubrication reminder.",
        description: "Demo maintenance notice. No real printer reported it.",
        state: "RUNNING", code: "DEMO_MAINTENANCE_001",
        module: "Maintenance", severityName: "common", severityLevel: 3,
        rawAttr: 0x07002300, rawCode: 0x00030001, active: true, read: false },
      { ago: 8, clearedAfter: 1, category: "print", action: "failed",
        severity: "error", title: "Print failed",
        summary: "Demo job entered FAILED state.",
        description: "Demo print-state transition. No real printer failed or stopped.",
        state: "FAILED", read: false },
      { ago: 3, clearedAfter: 1, category: "alert", action: "raised",
        severity: "error", title: "Printer error",
        summary: "Toolhead communication interruption.",
        description: "Demo error. No real printer reported a fault.",
        state: "FAILED", code: "DEMO_ERROR_001", module: "Toolhead",
        severityName: "serious", severityLevel: 2,
        rawAttr: 0x08000100, rawCode: 0x00020001, read: false }
    ]

    var maintenanceId = -1
    for (var archive = 3; archive >= 0; archive--) {
      var job = jobs[archive]
      var shift = archive * 60
      for (var index = 0; index < templates.length; index++) {
        var template = templates[index]
        var isCurrent = archive === 0
        var isActive = isCurrent && template.active === true
        var clearedAfter = Number(template.clearedAfter || 0)
        if (!isCurrent && template.active) clearedAfter = 5
        var id = store.appendEvent({
          timestamp: store.demoTimestamp(template.ago + shift),
          clearedAt: clearedAfter > 0
            ? store.demoTimestamp(template.ago + shift - clearedAfter) : "",
          category: template.category, action: template.action,
          severity: template.severity, title: template.title,
          summary: template.summary === "$JOB" ? job : template.summary,
          description: template.description,
          code: template.code
            ? template.code + (isCurrent ? "" : "-A" + archive) : "",
          source: "demo", module: String(template.module || ""),
          severityName: String(template.severityName || ""),
          severityLevel: Number(template.severityLevel || 0),
          rawAttr: template.rawAttr, rawCode: template.rawCode,
          jobName: template.category === "connection" ? "" : job,
          printerState: template.state, printerName: printer,
          productName: product, firmwareVersion: firmware,
          active: isActive, read: !isCurrent || template.read === true
        })
        if (isActive) maintenanceId = id
      }
    }
    store.activeAlerts = maintenanceId < 0 ? ({}) : ({
      "demo:maintenance": { eventId: maintenanceId, severity: "warning" }
    })
    store.recount()
    return true
  }

  function clearDemoEvents() {
    if (!store.demoEventsLoaded) return false
    store.events = store.events.filter(function(event) {
      return event.source !== "demo"
    })
    var remainingAlerts = ({})
    for (var key in store.activeAlerts) {
      if (key.indexOf("demo:") !== 0) remainingAlerts[key] = store.activeAlerts[key]
    }
    store.activeAlerts = remainingAlerts
    store.demoEventsLoaded = false
    store.recount()
    return true
  }
}
