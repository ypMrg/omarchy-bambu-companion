pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

Item {
  id: dialog

  BambuStyle { id: bambuStyle }

  property string mode: ""
  property bool probing: false
  property bool processing: false
  property var mqttIdentity: ({})
  property var ftpsIdentity: ({})
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color errorColor: Color.accent
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  property color background: bambuStyle.popupBackground
  property string fontFamily: bambuStyle.fontFamily

  readonly property bool certificateMode: mode === "certificate"
  readonly property bool disconnectMode: mode === "disconnect"
  readonly property bool sharedTlsCertificate:
    tlsFingerprint(mqttIdentity) !== ""
      && tlsFingerprint(mqttIdentity) === tlsFingerprint(ftpsIdentity)

  signal cancelRequested()
  signal trustRequested()
  signal disconnectRequested()

  visible: mode !== ""
  enabled: visible
  focus: visible
  activeFocusOnTab: true

  Keys.priority: Keys.BeforeItem
  Keys.onEscapePressed: function(event) {
    if (!dialog.processing) cancelRequested()
    event.accepted = true
  }

  onVisibleChanged: {
    if (visible) Qt.callLater(function() { dialog.forceActiveFocus() })
  }

  function tlsFingerprint(identity) {
    var raw = identity && typeof identity === "object"
      ? String(identity.fingerprint || "") : ""
    return raw.replace(/(..)(?=.)/g, "$1:")
  }

  function tlsDescription(identity) {
    if (!identity || typeof identity !== "object") return ""
    var name = String(identity.commonName || "UNKNOWN")
    var expiry = String(identity.notAfter || "").slice(0, 10)
    return "CN " + name + (expiry ? " · EXPIRES " + expiry : "")
  }

  component IdentityBlock: Column {
    required property var identity
    required property string title

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(4)

    Text {
      width: parent.width
      text: parent.title
      color: dialog.foreground
      font.family: dialog.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
      font.bold: true
    }

    Text {
      width: parent.width
      text: dialog.tlsFingerprint(parent.identity)
      textFormat: Text.PlainText
      color: dialog.foreground
      wrapMode: Text.WrapAnywhere
      font.family: dialog.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
    }

    Text {
      width: parent.width
      text: dialog.tlsDescription(parent.identity)
      textFormat: Text.PlainText
      color: dialog.dim
      elide: Text.ElideRight
      font.family: dialog.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.68)
  }

  MouseArea {
    anchors.fill: parent
    onClicked: {
      if (!dialog.processing) dialog.cancelRequested()
    }
    onWheel: function(wheel) { wheel.accepted = true }
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.min(Math.max(0, parent.width - Style.space(32)), Style.space(520))
    height: Math.min(Math.max(0, parent.height - Style.space(32)),
                     Style.space(dialog.certificateMode ? 360 : 240))
    color: dialog.background
    border.width: 1
    border.color: Qt.rgba(dialog.foreground.r, dialog.foreground.g,
                          dialog.foreground.b, 0.28)
    clip: true

    MouseArea {
      anchors.fill: parent
      onClicked: function(mouse) { mouse.accepted = true }
      onWheel: function(wheel) { wheel.accepted = true }
    }

    Rectangle {
      id: dialogHeader
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Style.space(42)
      color: Qt.rgba(dialog.foreground.r, dialog.foreground.g,
                     dialog.foreground.b, 0.035)

      Text {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: dialog.certificateMode
          ? (dialog.probing ? "CHECKING PRINTER CERTIFICATE" : "TRUST PRINTER CERTIFICATE")
          : (dialog.processing ? "DISCONNECTING PRINTER" : "DISCONNECT PRINTER")
        color: dialog.foreground
        elide: Text.ElideRight
        font.family: dialog.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
        font.bold: true
        font.letterSpacing: 1
      }
    }

    Flickable {
      id: dialogBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: dialogHeader.bottom
      anchors.bottom: dialogFooter.top
      contentWidth: width
      contentHeight: bodyContent.implicitHeight + Style.space(24)
      flickableDirection: Flickable.VerticalFlick
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      clip: true

      Column {
        id: bodyContent
        x: Style.space(12)
        y: Style.space(12)
        width: Math.max(0, dialogBody.width - Style.space(24))
        spacing: Style.space(10)

        Text {
          visible: dialog.certificateMode && dialog.probing
          width: parent.width
          text: "CHECKING MQTT AND FTPS CERTIFICATES…"
          color: dialog.dim
          wrapMode: Text.Wrap
          horizontalAlignment: Text.AlignHCenter
          font.family: dialog.fontFamily
          font.pixelSize: bambuStyle.bodySmallFontSize
          font.bold: true
        }

        IdentityBlock {
          visible: dialog.certificateMode && !dialog.probing
          identity: dialog.mqttIdentity
          title: dialog.sharedTlsCertificate ? "MQTT + FTPS" : "MQTT"
        }

        IdentityBlock {
          visible: dialog.certificateMode && !dialog.probing
            && !dialog.sharedTlsCertificate
          identity: dialog.ftpsIdentity
          title: "FTPS"
        }

        Text {
          visible: dialog.certificateMode && !dialog.probing
          width: parent.width
          text: "Approve only if this is the printer you configured. A future certificate change will be blocked."
          color: dialog.accent
          wrapMode: Text.Wrap
          font.family: dialog.fontFamily
          font.pixelSize: bambuStyle.captionFontSize
          font.bold: true
        }

        Text {
          visible: dialog.disconnectMode
          width: parent.width
          text: dialog.processing
            ? "Removing the saved LAN code and printer identity…"
            : "This removes the printer address, serial number, trusted certificates and LAN access code. Visual preferences are preserved."
          color: dialog.foreground
          wrapMode: Text.Wrap
          font.family: dialog.fontFamily
          font.pixelSize: bambuStyle.bodySmallFontSize
        }
      }
    }

    Rectangle {
      id: dialogFooter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(60)
      color: Qt.rgba(dialog.foreground.r, dialog.foreground.g,
                     dialog.foreground.b, 0.025)

      Row {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(8)

        BambuButton {
          width: actionButton.visible
            ? Math.max(0, (parent.width - parent.spacing) / 2) : parent.width
          height: parent.height
          text: "CANCEL"
          enabled: !dialog.processing
          foreground: dialog.foreground
          accent: dialog.accent
          bordered: true
          onClicked: dialog.cancelRequested()
        }

        BambuButton {
          id: actionButton
          visible: !dialog.probing && !dialog.processing
          width: Math.max(0, (parent.width - parent.spacing) / 2)
          height: parent.height
          text: dialog.certificateMode ? "TRUST & CONNECT" : "DISCONNECT"
          foreground: dialog.disconnectMode ? dialog.errorColor : dialog.foreground
          accent: dialog.disconnectMode ? dialog.errorColor : dialog.accent
          bordered: true
          onClicked: {
            if (dialog.certificateMode) dialog.trustRequested()
            else dialog.disconnectRequested()
          }
        }
      }
    }
  }
}
