pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.Commons

Item {
  id: pane

  BambuStyle { id: bambuStyle }

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  property color successColor: "#39FF88"
  property color errorColor: Color.accent
  property bool errorActive: false
  property bool modelErrorActive: false
  property bool demoActive: false
  property string fontFamily: bambuStyle.fontFamily
  property url printerIconSource

  property string printerName: "3D Printer"
  property bool online: false
  property string printerState: "OFFLINE"
  property string jobName: "NO ACTIVE PRINT"
  property int percent: 0
  property string remainingValue: "--"
  property bool dualNozzles: false
  property string nozzleLeftValue: "--°"
  property string nozzleRightValue: "--°"
  property bool nozzleLeftActive: false
  property bool nozzleRightActive: false
  property string bedValue: "--°"
  property string layerValue: "-- / --"
  property string zValue: "--"
  property string speedValue: "--"
  property string fanValue: "--"
  property string hostValue: "--"
  property string portsValue: "--"
  property string wifiValue: "--"
  property string reportValue: "--"
  property string segmentValue: "0 SEGMENTS"
  property string modelState: "IDLE"
  property string dimensionsValue: "--"
  property string appVersion: "unknown"
  property bool updateAvailable: false
  property bool updateStatusKnown: false
  property bool updateBusy: false
  property bool updateInstalling: false
  property string updateVersion: ""
  property string updateError: ""
  property bool appButtonVisible: false

  signal settingsRequested()
  signal appRequested()
  signal updateRequested()

  readonly property color surface: Qt.rgba(
    foreground.r, foreground.g, foreground.b, 0.035)
  readonly property int inset: Style.space(12)
  implicitHeight: telemetryContent.implicitHeight + pane.inset * 2
    + Style.space(8) + actionRow.height

  component SectionTitle: Item {
    width: parent ? parent.width : implicitWidth
    height: Style.space(22)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: Qt.rgba(pane.foreground.r, pane.foreground.g,
                     pane.foreground.b, 0.12)
    }

    Text {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      text: parent.objectName
      color: pane.dim
      font.family: pane.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
      font.bold: true
      font.letterSpacing: 1
    }
  }

  component MetricRow: Item {
    id: metric
    property string label: ""
    property string value: ""
    property color valueColor: pane.foreground

    width: parent ? parent.width : implicitWidth
    height: Math.max(metricLabel.implicitHeight, metricValue.implicitHeight)

    Text {
      id: metricLabel
      width: parent.width * 0.42
      text: metric.label
      color: pane.dim
      elide: Text.ElideRight
      font.family: pane.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
    }

    Text {
      id: metricValue
      anchors.left: metricLabel.right
      anchors.right: parent.right
      text: metric.value
      color: metric.valueColor
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      font.family: pane.fontFamily
      font.pixelSize: bambuStyle.bodySmallFontSize
    }
  }

  component SidebarPrinterIcon: Item {
    implicitWidth: bambuStyle.barIconCanvas
    implicitHeight: bambuStyle.barIconCanvas

    Image {
      id: sourceImage
      anchors.fill: parent
      source: pane.printerIconSource
      fillMode: Image.PreserveAspectFit
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: sourceImage
      source: sourceImage
      colorization: 1.0
      colorizationColor: pane.foreground
    }
  }

  Rectangle {
    anchors.fill: parent
    color: pane.surface
  }

  Flickable {
    id: telemetryScroll
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: actionRow.top
    anchors.margins: pane.inset
    anchors.bottomMargin: Style.space(8)
    contentWidth: width
    contentHeight: telemetryContent.implicitHeight
    flickableDirection: Flickable.VerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height + 1
    clip: true

    Column {
      id: telemetryContent
      width: telemetryScroll.width
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: (pane.demoActive ? "◆ DEMO"
          : (pane.online ? "● ONLINE" : "○ OFFLINE"))
          + "  ·  " + pane.printerState
        color: pane.demoActive ? pane.accent
          : (pane.errorActive ? pane.errorColor
            : (pane.online ? pane.successColor : pane.dim))
        elide: Text.ElideRight
        font.family: pane.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
        font.bold: true
      }

      Row {
        width: parent.width
        height: Math.max(statusIcon.implicitHeight, printerNameText.implicitHeight)
        spacing: Style.space(6)

        SidebarPrinterIcon {
          id: statusIcon
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: printerNameText
          width: Math.max(0, parent.width - statusIcon.width - parent.spacing)
          height: parent.height
          text: pane.printerName.toUpperCase()
          color: pane.foreground
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
          font.family: pane.fontFamily
          font.pixelSize: bambuStyle.subtitleFontSize
          font.bold: true
        }
      }

      Text {
        width: parent.width
        text: pane.jobName
        color: pane.dim
        elide: Text.ElideMiddle
        font.family: pane.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
      }

      Rectangle {
        width: parent.width
        height: Style.space(8)
        color: Qt.rgba(pane.foreground.r, pane.foreground.g,
                       pane.foreground.b, 0.05)
        border.width: 1
        border.color: Qt.rgba(pane.foreground.r, pane.foreground.g,
                              pane.foreground.b, 0.12)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.margins: 2
          width: Math.max(0, (parent.width - 4) * pane.percent / 100)
          color: pane.accent
        }
      }

      Item {
        width: parent.width
        height: Math.max(progressText.implicitHeight, remainingText.implicitHeight)
        Text {
          id: progressText
          anchors.left: parent.left
          text: pane.percent + "% COMPLETE"
          color: pane.accent
          font.family: pane.fontFamily
          font.pixelSize: bambuStyle.bodySmallFontSize
          font.bold: true
        }
        Text {
          id: remainingText
          anchors.right: parent.right
          text: pane.remainingValue + " LEFT"
          color: pane.dim
          font.family: pane.fontFamily
          font.pixelSize: bambuStyle.captionFontSize
        }
      }

      SectionTitle { objectName: "TEMPERATURES" }
      MetricRow {
        label: pane.dualNozzles ? "NOZZLE LEFT" : "NOZZLE"
        value: pane.nozzleLeftValue
        valueColor: pane.nozzleLeftActive ? pane.accent : pane.foreground
      }
      MetricRow {
        visible: pane.dualNozzles
        label: "NOZZLE RIGHT"
        value: pane.nozzleRightValue
        valueColor: pane.nozzleRightActive ? pane.accent : pane.foreground
      }
      MetricRow { label: "BED"; value: pane.bedValue }

      SectionTitle { objectName: "PRINT METRICS" }
      MetricRow { label: "LAYER"; value: pane.layerValue }
      MetricRow { label: "Z HEIGHT"; value: pane.zValue; valueColor: pane.accent }
      MetricRow { label: "REMAINING"; value: pane.remainingValue }
      MetricRow { label: "SPEED"; value: pane.speedValue }
      MetricRow { label: "FANS"; value: pane.fanValue }

      SectionTitle { objectName: "CONNECTION" }
      MetricRow { label: "ADDRESS"; value: pane.hostValue }
      MetricRow { label: "PORTS"; value: pane.portsValue }
      MetricRow { label: "WI-FI"; value: pane.wifiValue; valueColor: pane.accent }
      MetricRow { label: "REPORT"; value: pane.reportValue }

      SectionTitle { objectName: "MODEL DATA" }
      MetricRow { label: "GEOMETRY"; value: pane.segmentValue }
      MetricRow { label: "STATUS"; value: pane.modelState; valueColor: (pane.errorActive || pane.modelErrorActive) ? pane.errorColor : (pane.modelState === "READY" ? pane.successColor : pane.foreground) }
      MetricRow { label: "SIZE"; value: pane.dimensionsValue }

      SectionTitle { objectName: "APPLICATION" }

      Item {
        width: parent.width
        height: Math.max(versionText.implicitHeight,
                         updateButton.visible ? updateButton.height : 0)

        Rectangle {
          id: versionIndicator
          anchors.left: parent.left
          anchors.verticalCenter: versionText.verticalCenter
          width: Style.space(6)
          height: width
          radius: width / 2
          color: pane.updateError !== "" ? pane.errorColor
            : (pane.updateBusy || pane.updateAvailable ? pane.accent
              : (pane.updateStatusKnown ? pane.successColor : pane.dim))
        }

        Text {
          id: versionText
          anchors.left: versionIndicator.right
          anchors.leftMargin: Style.space(6)
          anchors.top: parent.top
          text: "v" + pane.appVersion
          color: pane.foreground
          font.family: pane.fontFamily
          font.pixelSize: bambuStyle.bodySmallFontSize
        }

        BambuButton {
          id: updateButton
          visible: pane.updateAvailable
          enabled: !pane.updateBusy
          anchors.right: parent.right
          anchors.verticalCenter: versionText.verticalCenter
          width: Style.space(30)
          height: Style.space(28)
          text: "\uf019"
          tooltipText: pane.updateError !== "" ? pane.updateError
            : "UPDATE TO v" + pane.updateVersion
          foreground: enabled ? pane.accent : pane.dim
          accent: pane.accent
          bordered: true
          horizontalPadding: 0
          onClicked: pane.updateRequested()
        }

        Text {
          anchors.left: versionText.right
          anchors.leftMargin: Style.space(8)
          anchors.right: updateButton.visible ? updateButton.left : parent.right
          anchors.rightMargin: updateButton.visible ? Style.space(6) : 0
          anchors.verticalCenter: versionText.verticalCenter
          text: pane.updateInstalling ? "UPDATING"
            : (pane.updateBusy ? "CHECKING"
              : (pane.updateError !== "" ? "UPDATE FAILED"
                : (pane.updateAvailable ? "v" + pane.updateVersion + " AVAILABLE"
                  : (pane.updateStatusKnown ? "CURRENT" : ""))))
          color: pane.updateError !== "" ? pane.errorColor
            : (pane.updateAvailable ? pane.accent : pane.dim)
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideRight
          font.family: pane.fontFamily
          font.pixelSize: bambuStyle.captionFontSize
          font.bold: pane.updateAvailable
        }
      }
    }
  }

  Row {
    id: actionRow
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: pane.inset
    height: Style.space(36)
    spacing: Style.space(8)

    BambuButton {
      width: pane.appButtonVisible
        ? Math.max(0, (parent.width - parent.spacing) / 2) : parent.width
      height: parent.height
      clip: true
      text: "SETTINGS"
      foreground: pane.foreground
      accent: pane.accent
      bordered: true
      onClicked: pane.settingsRequested()
    }

    BambuButton {
      visible: pane.appButtonVisible
      width: Math.max(0, (parent.width - parent.spacing) / 2)
      height: parent.height
      clip: true
      text: "OPEN APP"
      foreground: pane.foreground
      accent: pane.accent
      bordered: true
      onClicked: pane.appRequested()
    }
  }
}
