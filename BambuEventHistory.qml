pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

Rectangle {
  id: history

  BambuStyle { id: bambuStyle }

  required property var service
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color errorColor: "#ff5f56"
  property color warningColor: "#ff9f43"
  property color successColor: "#39FF88"
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  property color background: bambuStyle.popupBackground
  property string fontFamily: bambuStyle.fontFamily
  property string logFontFamily: "monospace"
  property int selectedEventId: -1
  readonly property var eventRecords: history.service
    ? history.service.eventHistory : []
  readonly property int unreadCount: history.service
    ? history.service.unreadEventCount : 0
  readonly property int unreadErrorCount: history.service
    ? history.service.unreadErrorCount : 0
  readonly property int unreadWarningCount: history.service
    ? history.service.unreadWarningCount : 0
  readonly property var selectedEvent: {
    if (history.selectedEventId < 0) return null
    for (let index = 0; index < history.eventRecords.length; index++) {
      let event = history.eventRecords[index]
      if (event.id === history.selectedEventId) return event
    }
    return null
  }

  signal closeRequested()

  component DetailRow: Item {
    id: detailRow
    required property string label
    required property string value
    property color valueColor: history.foreground

    width: parent ? parent.width : 0
    height: visible ? Math.max(detailLabel.implicitHeight,
                               detailValue.implicitHeight) : 0
    visible: value !== ""

    Text {
      id: detailLabel
      anchors.left: parent.left
      anchors.top: parent.top
      width: Style.space(82)
      text: detailRow.label
      color: history.dim
      font.family: history.logFontFamily
      font.pixelSize: bambuStyle.captionFontSize
      font.bold: true
    }

    Text {
      id: detailValue
      anchors.left: detailLabel.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.top: parent.top
      text: detailRow.value
      color: detailRow.valueColor
      wrapMode: Text.WrapAnywhere
      font.family: history.logFontFamily
      font.pixelSize: bambuStyle.captionFontSize
    }
  }

  component DetailSection: Rectangle {
    id: detailSection
    required property string title
    default property alias rows: detailRows.data

    width: parent ? parent.width : 0
    height: visible ? sectionContent.implicitHeight + Style.space(24) : 0
    color: Qt.rgba(history.foreground.r, history.foreground.g,
                   history.foreground.b, 0.025)
    border.width: 1
    border.color: Qt.rgba(history.foreground.r, history.foreground.g,
                          history.foreground.b, 0.12)

    Column {
      id: sectionContent
      x: Style.space(12)
      y: Style.space(12)
      width: Math.max(0, parent.width - Style.space(24))
      spacing: Style.space(8)

      Text {
        text: detailSection.title
        color: history.foreground
        font.family: history.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
        font.bold: true
        font.letterSpacing: 1
      }

      Column {
        id: detailRows
        width: parent.width
        spacing: Style.space(8)
      }
    }
  }

  color: history.background
  border.width: 1
  border.color: Qt.rgba(history.foreground.r, history.foreground.g,
                        history.foreground.b, 0.16)
  clip: true

  function eventColor(event) {
    if (!event) return history.dim
    if (event.severity === "error") return history.errorColor
    if (event.severity === "warning") return history.warningColor
    if (event.severity === "success") return history.successColor
    return history.accent
  }

  function eventLevel(event) {
    if (!event) return "INF"
    if (event.severity === "error") return "ERR"
    if (event.severity === "warning") return "WRN"
    if (event.severity === "success") return "OK"
    return "INF"
  }

  function eventChannel(event) {
    if (!event) return "[SYS]"
    var source = String(event.source || "").toLowerCase()
    var category = String(event.category || "").toLowerCase()
    if (source === "demo") return "[DEMO]"
    if (source === "hms") return "[HMS]"
    if (source === "print_error" || source === "mc_print_error_code") return "[PRINT]"
    if (category === "connection") return "[LINK]"
    if (category === "print") return "[JOB]"
    if (category === "alert") return "[ALERT]"
    return "[SYS]"
  }

  function eventMessage(event) {
    if (!event) return ""
    var title = String(event.title || "Printer event")
    var summary = String(event.summary || "")
    var code = String(event.code || "")
    if (code) return title + " · " + code
    if (summary && summary !== title) return title + " · " + summary
    return title
  }

  function formatTimestamp(value, detailed) {
    var date = new Date(String(value || ""))
    if (isNaN(date.getTime())) return String(value || "--")
    return Qt.formatDateTime(date, detailed
      ? "yyyy-MM-dd HH:mm:ss" : "HH:mm:ss")
  }

  function rawHex(value) {
    if (value === null || value === undefined || value === "") return "--"
    var number = Number(value)
    if (!isFinite(number)) return String(value)
    var unsigned = number < 0 ? number + 4294967296 : number
    return "0x" + Math.floor(unsigned).toString(16).toUpperCase().padStart(8, "0")
  }

  function hasContext(event) {
    return event && (event.jobName || event.printerState || event.code
      || event.module || event.severityName || event.productName
      || event.printerName || event.firmwareVersion)
  }

  function openEvent(event) {
    if (!event || !history.service) return
    history.service.markEventRead(event.id)
    history.selectedEventId = event.id
  }

  function closeDetails() {
    history.selectedEventId = -1
  }

  onVisibleChanged: {
    if (!visible) history.closeDetails()
  }

  Item {
    id: historyHeader
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(36)

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(history.foreground.r, history.foreground.g,
                     history.foreground.b, 0.025)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: Qt.rgba(history.foreground.r, history.foreground.g,
                     history.foreground.b, 0.12)
    }

    BambuButton {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(64)
      height: Style.space(30)
      text: "BACK"
      tooltipText: "BACK TO PRINTER"
      foreground: history.foreground
      accent: history.accent
      bordered: true
      onClicked: history.closeRequested()
    }

    Text {
      anchors.centerIn: parent
      text: "PRINTER EVENT LOG"
      color: history.foreground
      font.family: history.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
      font.bold: true
      font.letterSpacing: 1
    }

    BambuButton {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(82)
      height: Style.space(30)
      text: "READ ALL"
      tooltipText: "MARK EVERY EVENT AS READ"
      foreground: history.unreadCount > 0
        ? history.accent : history.dim
      accent: history.accent
      bordered: true
      enabled: history.unreadCount > 0
      onClicked: {
        if (history.service) history.service.markAllEventsRead()
      }
    }
  }

  Item {
    id: eventSummary
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: historyHeader.bottom
    height: Style.space(42)

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      text: history.eventRecords.length + " LOG ENTRIES"
      color: history.dim
      font.family: history.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
      font.bold: true
    }

    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      text: history.unreadCount > 0
        ? history.unreadCount + " UNREAD" : "ALL READ"
      color: history.unreadErrorCount > 0 ? history.errorColor
        : (history.unreadWarningCount > 0 ? history.warningColor : history.dim)
      font.family: history.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
      font.bold: true
    }
  }

  ListView {
    id: eventList
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: eventSummary.bottom
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(10)
    anchors.topMargin: 0
    spacing: 0
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: history.eventRecords

    delegate: Rectangle {
      id: eventDelegate
      required property var modelData

      width: eventList.width
      height: Style.space(32)
      color: eventMouse.containsMouse
        ? Qt.rgba(history.foreground.r, history.foreground.g,
                  history.foreground.b, 0.07)
        : Qt.rgba(history.foreground.r, history.foreground.g,
                  history.foreground.b, modelData.read ? 0.015 : 0.045)

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.space(2)
        color: history.eventColor(eventDelegate.modelData)
      }

      Text {
        id: logTime
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: implicitWidth
        text: history.formatTimestamp(eventDelegate.modelData.timestamp, false)
        color: history.dim
        font.family: history.logFontFamily
        font.pixelSize: bambuStyle.captionFontSize
      }

      Text {
        id: logLevel
        anchors.left: logTime.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: implicitWidth
        text: history.eventLevel(eventDelegate.modelData)
        color: history.eventColor(eventDelegate.modelData)
        font.family: history.logFontFamily
        font.pixelSize: bambuStyle.captionFontSize
        font.bold: true
      }

      Text {
        id: logChannel
        anchors.left: logLevel.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: implicitWidth
        text: history.eventChannel(eventDelegate.modelData)
        color: eventDelegate.modelData.source === "demo"
          ? history.warningColor : history.accent
        font.family: history.logFontFamily
        font.pixelSize: bambuStyle.captionFontSize
      }

      Text {
        anchors.left: logChannel.right
        anchors.leftMargin: Style.space(8)
        anchors.right: unreadMarker.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: history.eventMessage(eventDelegate.modelData)
        color: eventDelegate.modelData.read ? history.dim : history.foreground
        elide: Text.ElideRight
        font.family: history.logFontFamily
        font.pixelSize: bambuStyle.captionFontSize
        font.bold: !eventDelegate.modelData.read
      }

      Text {
        id: unreadMarker
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(8)
        text: eventDelegate.modelData.read ? "" : "•"
        color: history.eventColor(eventDelegate.modelData)
        font.family: history.logFontFamily
        font.pixelSize: bambuStyle.bodySmallFontSize
        font.bold: true
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Qt.rgba(history.foreground.r, history.foreground.g,
                       history.foreground.b, 0.08)
      }

      Timer {
        interval: 500
        repeat: false
        running: eventMouse.containsMouse && !eventDelegate.modelData.read
        onTriggered: {
          if (history.service)
            history.service.markEventRead(eventDelegate.modelData.id)
        }
      }

      MouseArea {
        id: eventMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: history.openEvent(eventDelegate.modelData)
      }
    }

    Text {
      anchors.centerIn: parent
      visible: history.eventRecords.length === 0
      width: Math.max(0, parent.width - Style.space(48))
      text: "NO LOG ENTRIES\n\nPrinter telemetry will appear here as it is observed."
      color: history.dim
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      font.family: history.logFontFamily
      font.pixelSize: bambuStyle.bodySmallFontSize
    }
  }

  Rectangle {
    anchors.fill: parent
    z: 20
    visible: history.selectedEvent !== null
    color: history.background

    Item {
      id: detailsHeader
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Style.space(36)

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(history.foreground.r, history.foreground.g,
                       history.foreground.b, 0.025)
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Qt.rgba(history.foreground.r, history.foreground.g,
                       history.foreground.b, 0.12)
      }

      BambuButton {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(64)
        height: Style.space(30)
        text: "BACK"
        tooltipText: "BACK TO EVENT LOG"
        foreground: history.foreground
        accent: history.accent
        bordered: true
        onClicked: history.closeDetails()
      }

      Text {
        anchors.centerIn: parent
        text: "LOG RECORD"
        color: history.foreground
        font.family: history.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
        font.bold: true
        font.letterSpacing: 1
      }

    }

    Flickable {
      id: detailsScroll
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: detailsHeader.bottom
      anchors.bottom: parent.bottom
      contentWidth: width
      contentHeight: detailsContent.implicitHeight + Style.space(28)
      flickableDirection: Flickable.VerticalFlick
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      clip: true

      Column {
        id: detailsContent
        x: Style.space(16)
        y: Style.space(14)
        width: Math.max(0, detailsScroll.width - Style.space(32))
        spacing: Style.space(12)

        Rectangle {
          width: parent.width
          height: detailSummary.implicitHeight + Style.space(24)
          color: {
            var tone = history.eventColor(history.selectedEvent)
            return Qt.rgba(tone.r, tone.g, tone.b, 0.075)
          }
          border.width: 1
          border.color: {
            var tone = history.eventColor(history.selectedEvent)
            return Qt.rgba(tone.r, tone.g, tone.b, 0.32)
          }

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(3)
            color: history.eventColor(history.selectedEvent)
          }

          Column {
            id: detailSummary
            x: Style.space(14)
            y: Style.space(12)
            width: Math.max(0, parent.width - Style.space(28))
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: history.eventLevel(history.selectedEvent) + "  "
                + history.eventChannel(history.selectedEvent)
              color: history.eventColor(history.selectedEvent)
              font.family: history.logFontFamily
              font.pixelSize: bambuStyle.captionFontSize
              font.bold: true
            }

            Text {
              width: parent.width
              text: history.selectedEvent
                ? String(history.selectedEvent.title || "Printer event") : ""
              color: history.foreground
              wrapMode: Text.Wrap
              font.family: history.fontFamily
              font.pixelSize: bambuStyle.subtitleFontSize
              font.bold: true
            }

            Text {
              width: parent.width
              text: history.selectedEvent ? history.selectedEvent.description : ""
              color: history.dim
              wrapMode: Text.Wrap
              font.family: history.fontFamily
              font.pixelSize: bambuStyle.bodySmallFontSize
            }
          }
        }

        DetailSection {
          title: "TIMELINE"

          DetailRow {
            label: "OBSERVED"
            value: history.selectedEvent
              ? history.formatTimestamp(history.selectedEvent.timestamp, true) : ""
          }

          DetailRow {
            label: "STATUS"
            value: !history.selectedEvent ? ""
              : (history.selectedEvent.active ? "ACTIVE"
                : (history.selectedEvent.clearedAt !== "" ? "CLEARED" : "RECORDED"))
            valueColor: history.selectedEvent && history.selectedEvent.active
              ? history.eventColor(history.selectedEvent)
              : (history.selectedEvent && history.selectedEvent.clearedAt !== ""
                ? history.successColor : history.dim)
          }

          DetailRow {
            label: "CLEARED"
            value: history.selectedEvent && history.selectedEvent.clearedAt !== ""
              ? history.formatTimestamp(history.selectedEvent.clearedAt, true) : ""
            valueColor: history.successColor
          }
        }

        DetailSection {
          title: "CONTEXT"
          visible: history.hasContext(history.selectedEvent)

          DetailRow {
            label: "FILE"
            value: history.selectedEvent ? history.selectedEvent.jobName : ""
          }
          DetailRow {
            label: "STATE"
            value: history.selectedEvent ? history.selectedEvent.printerState : ""
          }
          DetailRow {
            label: "CODE"
            value: history.selectedEvent ? history.selectedEvent.code : ""
            valueColor: history.eventColor(history.selectedEvent)
          }
          DetailRow {
            label: "MODULE"
            value: history.selectedEvent ? history.selectedEvent.module : ""
          }
          DetailRow {
            label: "SEVERITY"
            value: history.selectedEvent && history.selectedEvent.severityName !== ""
              ? String(history.selectedEvent.severityName).toUpperCase()
                + (history.selectedEvent.severityLevel > 0
                  ? " (" + history.selectedEvent.severityLevel + ")" : "") : ""
            valueColor: history.eventColor(history.selectedEvent)
          }
          DetailRow {
            label: "DEVICE"
            value: !history.selectedEvent ? ""
              : String(history.selectedEvent.productName
                || history.selectedEvent.printerName || "")
          }
          DetailRow {
            label: "FIRMWARE"
            value: history.selectedEvent ? history.selectedEvent.firmwareVersion : ""
          }
        }

        DetailSection {
          title: "RAW EVENT"

          DetailRow {
            label: "SOURCE"
            value: history.selectedEvent
              ? String(history.selectedEvent.source || "printer").toUpperCase() : ""
          }
          DetailRow {
            label: "TYPE"
            value: !history.selectedEvent ? ""
              : String(history.selectedEvent.category || "event").toUpperCase()
                + "." + String(history.selectedEvent.action || "observed").toUpperCase()
          }
          DetailRow {
            label: "RAW ATTR"
            value: history.selectedEvent && history.selectedEvent.rawAttr !== null
              ? history.rawHex(history.selectedEvent.rawAttr) : ""
          }
          DetailRow {
            label: "RAW CODE"
            value: history.selectedEvent && history.selectedEvent.rawCode !== null
              ? history.rawHex(history.selectedEvent.rawCode) : ""
          }
        }

        Rectangle {
          width: parent.width
          height: ambiguityNote.implicitHeight + Style.space(20)
          visible: history.selectedEvent && history.selectedEvent.category === "alert"
          color: Qt.rgba(history.warningColor.r, history.warningColor.g,
                         history.warningColor.b, 0.07)
          border.width: 1
          border.color: Qt.rgba(history.warningColor.r, history.warningColor.g,
                                history.warningColor.b, 0.28)

          Text {
            id: ambiguityNote
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            text: "Exact printer values are preserved above. Explanatory text may be generic when Bambu does not expose a documented meaning for the reported code."
            color: history.warningColor
            wrapMode: Text.Wrap
            font.family: history.fontFamily
            font.pixelSize: bambuStyle.captionFontSize
          }
        }

      }
    }
  }
}
