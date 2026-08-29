pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.Commons

Item {
  id: viewport

  BambuStyle { id: bambuStyle }

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  property color errorColor: Color.accent
  property color warningColor: "#ff9f43"
  property bool errorActive: false
  property string fontFamily: bambuStyle.fontFamily
  property bool panelActive: false
  property bool printerConfigured: false
  property bool daemonReady: false
  property bool printing: false
  property bool eventsActive: false
  property int unreadEventCount: 0
  property int unreadErrorCount: 0
  property int unreadWarningCount: 0
  readonly property real nozzleSpeed: 50
  property bool previewAvailable: false
  property bool gcodeAvailable: false
  property bool cameraAvailable: false
  property bool cameraFrameAvailable: false
  property string cameraStatus: "idle"
  property string cameraStatusCode: ""
  property string cameraStatusMessage: ""
  property bool autoRotateDefault: true
  property string selectedSource: "gcode"
  property url previewSource: ""
  property url cameraFrameSource: ""
  property string activeSegmentPath: ""
  property var activeBounds: ({})
  property real zCurrent: NaN
  property real explosionFactor: 100
  property string modelStatus: "idle"
  property string modelError: ""
  property string modelLoadPhase: ""
  property int modelLoadProgress: -1
  property real modelLoadedBytes: 0
  property real modelTotalBytes: 0
  property string rendererStatus: "compiling"
  property url nativeRouteUrl: ""
  readonly property real routeYaw: routeCamera.yaw
  readonly property bool routeItemReady: !!routeLoader.item

  signal reloadRequested()
  signal sourceRequested(string source)
  signal eventsRequested()
  signal rendererLoadFailed()

  readonly property color surface: Qt.rgba(
    foreground.r, foreground.g, foreground.b, 0.025)
  readonly property bool downloadProgressVisible:
    viewport.modelStatus === "loading"
      && viewport.modelLoadPhase === "downloading"
      && viewport.modelLoadProgress >= 0
      && viewport.modelTotalBytes > 0

  function coordinateOverlay() {
    var bounds = viewport.activeBounds || ({})
    var minX = Number(bounds.minX), maxX = Number(bounds.maxX)
    var minY = Number(bounds.minY), maxY = Number(bounds.maxY)
    var x = isFinite(minX) && isFinite(maxX) ? (minX + maxX) / 2 : NaN
    var y = isFinite(minY) && isFinite(maxY) ? (minY + maxY) / 2 : NaN
    return "X:" + (isFinite(x) ? x.toFixed(1) : "--")
      + "  Y:" + (isFinite(y) ? y.toFixed(1) : "--")
      + "  Z:" + (isFinite(viewport.zCurrent) ? viewport.zCurrent.toFixed(1) : "--")
  }

  function emptyModelTitle() {
    if (!viewport.printerConfigured) return "NO PRINTER CONFIGURED"
    if (viewport.selectedSource === "camera") {
      if (viewport.cameraStatusCode === "certificate_changed")
        return "CAMERA CERTIFICATE CHANGED"
      if (viewport.cameraStatus === "connecting"
          || viewport.cameraStatus === "idle") return "WAITING FOR CAMERA"
      return "CAMERA UNAVAILABLE"
    }
    if (viewport.modelStatus === "loading") {
      if (viewport.modelLoadPhase === "downloading") return "DOWNLOADING PRINT FILE"
      if (viewport.modelLoadPhase === "processing") return "PROCESSING PRINT DATA"
      return "LOCATING PRINT FILE"
    }
    if (viewport.selectedSource === "gcode"
        && viewport.rendererStatus === "compiling") return "COMPILING ROUTE RENDERER"
    if (viewport.selectedSource === "gcode"
        && viewport.rendererStatus === "unavailable") return "ROUTE RENDERER UNAVAILABLE"
    if (viewport.printing && viewport.modelStatus === "error")
      return "PRINT DATA NOT READY YET"
    if (viewport.printing) return "WAITING FOR PRINT DATA"
    return "PREVIEW AVAILABLE DURING A PRINT"
  }

  function emptyModelDetail() {
    if (!viewport.printerConfigured)
      return "OPEN SETTINGS TO CONFIGURE A PRINTER"
    if (viewport.selectedSource === "camera")
      return viewport.cameraStatusMessage
    if (viewport.modelStatus === "loading"
        && viewport.modelLoadPhase === "downloading") {
      var loaded = formatBytes(viewport.modelLoadedBytes)
      if (viewport.modelTotalBytes > 0) {
        return loaded + " / " + formatBytes(viewport.modelTotalBytes)
          + " · " + viewport.modelLoadProgress + "%"
      }
      return loaded
    }
    if (viewport.modelStatus === "loading"
        && viewport.modelLoadPhase === "processing")
      return "EXTRACTING AND PARSING G-CODE"
    if (viewport.selectedSource === "gcode"
        && viewport.rendererStatus === "unavailable")
      return "Install cmake and g++ · see Quickshell logs"
    if (viewport.printing
        && (viewport.modelStatus === "loading" || viewport.modelStatus === "error")) {
      return "Automatic retries are limited · use Reload preview to try again"
    }
    return ""
  }

  function cameraUnavailableTooltip() {
    if (!viewport.printerConfigured) return "Camera unavailable until a printer is connected"
    if (viewport.cameraStatusCode === "ffmpeg_missing")
      return "Install ffmpeg to view the camera"
    if (viewport.cameraStatusCode === "liveview_disabled")
      return "Enable LAN Mode Liveview on the printer"
    return "Chamber camera unavailable"
  }

  function formatBytes(value) {
    var bytes = Math.max(0, Number(value))
    if (!isFinite(bytes)) bytes = 0
    if (bytes < 1024) return Math.floor(bytes) + " B"
    var units = ["KB", "MB", "GB"]
    var amount = bytes
    var unit = -1
    do {
      amount /= 1024
      unit += 1
    } while (amount >= 1024 && unit < units.length - 1)
    return amount.toFixed(amount >= 100 ? 0 : 1) + " " + units[unit]
  }

  function objectMember(object, name) {
    return object ? object[name] : undefined
  }

  function syncRouteGeometry() {
    var item = routeLoader.item
    if (!item) return
    item.segmentPath = viewport.activeSegmentPath
    item.bounds = viewport.activeBounds
  }

  function syncRouteItem() {
    var item = routeLoader.item
    if (!item) return
    item.yaw = routeCamera.yaw
    item.pitch = routeCamera.pitch
    item.zoom = routeCamera.zoom
    item.explosionProgress = routeCamera.explosionProgress
    item.explosionFactor = routeCamera.explosionFactor
    item.cutoffZ = viewport.zCurrent
    item.padding = Math.max(Style.space(12), Math.min(routeCamera.width, routeCamera.height) * 0.07)
    var printed = viewport.errorActive ? viewport.errorColor : viewport.accent
    item.printedColor = Qt.rgba(printed.r, printed.g, printed.b, 0.74)
    item.remainingColor = Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                                  viewport.foreground.b, 0.10)
    item.plateColor = Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                              viewport.foreground.b, 0.07)
    syncNozzleMarker()
  }

  function syncNozzleMarker() {
    var item = routeLoader.item
    if (!item || !viewport.printing || viewport.selectedSource !== "gcode"
        || routeCamera.dragging) {
      nozzleMarker.sampleAvailable = false
      return
    }
    var sampleNozzle = viewport.objectMember(item, "sampleNozzle")
    var mapToView = viewport.objectMember(item, "mapToView")
    if (typeof sampleNozzle !== "function" || typeof mapToView !== "function") {
      nozzleMarker.sampleAvailable = false
      return
    }
    var world = sampleNozzle.call(
      item, viewport.zCurrent, routeCamera.nozzleDistance)
    if (!world || world.length !== 3) {
      nozzleMarker.sampleAvailable = false
      return
    }
    var point = mapToView.call(item, world[0], world[1], world[2])
    if (!point || !isFinite(point.x) || !isFinite(point.y)) {
      nozzleMarker.sampleAvailable = false
      return
    }
    nozzleMarker.x = point.x - nozzleMarker.width / 2
    nozzleMarker.y = point.y - nozzleMarker.height / 2
    nozzleMarker.sampleAvailable = true
  }

  Rectangle {
    anchors.fill: parent
    color: viewport.surface
  }

  Rectangle {
    id: viewportHeader
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(36)
    color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                   viewport.foreground.b, 0.025)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                     viewport.foreground.b, 0.12)
    }

    Text {
      id: viewportTitle
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: "PRINT PREVIEW"
      color: viewport.foreground
      font.family: viewport.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
      font.bold: true
      font.letterSpacing: 1
    }

    Text {
      anchors.left: viewportTitle.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: viewport.selectedSource === "gcode"
        ? "DRAG TO ROTATE · WHEEL TO ZOOM · HOLD TO PAUSE"
        : (viewport.selectedSource === "camera" ? "CHAMBER CAMERA" : "2D SLICER PREVIEW")
      color: viewport.dim
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      font.family: viewport.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
    }
  }

  Item {
    id: viewportFrame
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: viewportHeader.bottom
    anchors.bottom: parent.bottom
    clip: true

    Item {
      id: routeCamera
      anchors.fill: parent
      visible: viewport.selectedSource === "gcode"
      property real yaw: 0
      property real pitch: -0.28
      property real normalZoom: 1
      property real explodedZoom: 1
      property real wheelStepAccumulator: 0
      property bool autoRotate: viewport.autoRotateDefault
      property bool exploded: false
      readonly property real zoom: exploded ? explodedZoom : normalZoom
      readonly property real minimumZoom: exploded ? 0.125 : 0.5
      readonly property real maximumZoom: exploded ? 8 : 4
      readonly property real explosionFactor: Math.max(0, Math.min(500,
        isFinite(Number(viewport.explosionFactor)) ? Number(viewport.explosionFactor) : 100))
      property real explosionProgress: exploded ? 1 : 0
      property bool dragging: false
      property real lastDragX: 0
      property real lastDragY: 0
      property double lastFrameTimestamp: 0
      property real nozzleDistance: 0

      Behavior on explosionProgress {
        NumberAnimation {
          duration: 350
          easing.type: Easing.InOutCubic
        }
      }

      function normalizeAngle(value) {
        var turn = Math.PI * 2
        var normalized = value % turn
        return normalized < 0 ? normalized + turn : normalized
      }

      function normalizeSignedAngle(value) {
        var normalized = normalizeAngle(value)
        return normalized >= Math.PI ? normalized - Math.PI * 2 : normalized
      }

      function orientationAfterDrag(startYaw, startPitch, deltaX, deltaY,
                                    viewportWidth, viewportHeight) {
        if (!isFinite(viewportWidth) || viewportWidth <= 0
            || !isFinite(viewportHeight) || viewportHeight <= 0) {
          return {
            yaw: normalizeAngle(startYaw),
            pitch: normalizeSignedAngle(startPitch)
          }
        }
        return {
          yaw: normalizeAngle(startYaw + deltaX / viewportWidth * Math.PI * 2),
          pitch: normalizeSignedAngle(
            startPitch + deltaY / viewportHeight * Math.PI)
        }
      }

      function wheelStepDelta(angleDeltaY, pixelDeltaY) {
        var angle = Number(angleDeltaY)
        var pixel = Number(pixelDeltaY)
        if (isFinite(angle) && angle !== 0) return angle / 120
        return isFinite(pixel) ? pixel / 30 : 0
      }

      function wholeWheelSteps(accumulatedSteps) {
        var accumulated = Number(accumulatedSteps)
        if (!isFinite(accumulated)) return 0
        return accumulated < 0 ? Math.ceil(accumulated) : Math.floor(accumulated)
      }

      function zoomAfterSteps(currentZoom, steps, minimumZoom, maximumZoom) {
        var current = Number(currentZoom)
        if (!isFinite(current) || current <= 0) current = 1
        var wholeSteps = Number(steps)
        if (!isFinite(wholeSteps)) wholeSteps = 0
        var limit = Number(maximumZoom)
        if (!isFinite(limit) || limit < 1) limit = 4
        var minimum = Number(minimumZoom)
        if (!isFinite(minimum) || minimum <= 0 || minimum > limit) minimum = 0.5
        var nextZoom = current * Math.pow(1.12, wholeSteps)
        return Math.max(minimum, Math.min(limit, nextZoom))
      }

      function setZoom(value) {
        if (exploded) explodedZoom = value
        else normalZoom = value
      }

      function formatZoom(value) {
        var number = Number(value)
        if (!isFinite(number) || number <= 0 || Math.abs(number - 1) < 0.000001)
          return "1"
        return number.toFixed(2).replace(/\.?0+$/, "")
      }

      function advanceAutoRotation(timestamp) {
        var now = Number(timestamp)
        if (!isFinite(now)) return
        if (lastFrameTimestamp <= 0) {
          lastFrameTimestamp = now
          return
        }
        var elapsed = Math.max(0, Math.min(250, now - lastFrameTimestamp))
        lastFrameTimestamp = now
        if (dragging) return
        if (autoRotate) {
          yaw = normalizeAngle(yaw + elapsed / 14000 * Math.PI * 2)
        }
        if (viewport.printing) {
          nozzleDistance += elapsed / 1000 * viewport.nozzleSpeed
        }
      }

      onYawChanged: viewport.syncRouteItem()
      onPitchChanged: viewport.syncRouteItem()
      onZoomChanged: viewport.syncRouteItem()
      onMaximumZoomChanged: setZoom(Math.min(zoom, maximumZoom))
      onMinimumZoomChanged: setZoom(Math.max(zoom, minimumZoom))
      onExplosionProgressChanged: viewport.syncRouteItem()
      onDraggingChanged: viewport.syncNozzleMarker()
      onWidthChanged: viewport.syncRouteItem()
      onHeightChanged: viewport.syncRouteItem()
      onNozzleDistanceChanged: viewport.syncNozzleMarker()
    }

    Loader {
      id: routeLoader
      anchors.fill: parent
      // Stay visible while ready so hiding the popup or switching to the
      // 2D image does not drop the GPU node unless Qt hides the window.
      visible: viewport.rendererStatus === "ready"
      opacity: viewport.selectedSource === "gcode" ? 1 : 0
      active: viewport.rendererStatus === "ready" && viewport.nativeRouteUrl !== ""
      source: active ? viewport.nativeRouteUrl : ""
      onStatusChanged: {
        if (status === Loader.Error) viewport.rendererLoadFailed()
      }
      onLoaded: {
        viewport.syncRouteGeometry()
        viewport.syncRouteItem()
      }
    }

    Image {
      anchors.fill: parent
      anchors.margins: Style.space(32)
      source: viewport.previewSource
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: false
      smooth: true
      visible: viewport.selectedSource === "preview" && viewport.previewAvailable
    }

    Image {
      anchors.fill: parent
      anchors.margins: Style.space(12)
      source: viewport.cameraFrameSource
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: false
      smooth: true
      visible: viewport.selectedSource === "camera" && viewport.cameraFrameAvailable
    }

    Item {
      id: nozzleMarker
      width: 10
      height: 10
      property bool sampleAvailable: false
      visible: viewport.selectedSource === "gcode"
        && viewport.rendererStatus === "ready"
        && viewport.printing
        && nozzleMarker.sampleAvailable
        && !routeCamera.dragging
      z: 1
      readonly property color nozzleColor: viewport.errorActive
        ? viewport.errorColor : viewport.accent

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Qt.rgba(nozzleMarker.nozzleColor.r, nozzleMarker.nozzleColor.g,
                       nozzleMarker.nozzleColor.b, 0.20)
      }

      Rectangle {
        anchors.centerIn: parent
        width: 4.4
        height: 4.4
        radius: width / 2
        color: nozzleMarker.nozzleColor
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: viewport.selectedSource === "gcode"
      acceptedButtons: Qt.LeftButton
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      onWheel: function(wheel) {
        routeCamera.wheelStepAccumulator += routeCamera.wheelStepDelta(
          wheel.angleDelta ? wheel.angleDelta.y : 0,
          wheel.pixelDelta ? wheel.pixelDelta.y : 0)
        var wholeSteps = routeCamera.wholeWheelSteps(routeCamera.wheelStepAccumulator)
        if (wholeSteps !== 0) {
          routeCamera.setZoom(routeCamera.zoomAfterSteps(
            routeCamera.zoom, wholeSteps, routeCamera.minimumZoom,
            routeCamera.maximumZoom))
          routeCamera.wheelStepAccumulator -= wholeSteps
        }
        wheel.accepted = true
      }
      onPressed: function(mouse) {
        routeCamera.dragging = true
        routeCamera.lastDragX = mouse.x
        routeCamera.lastDragY = mouse.y
        routeCamera.lastFrameTimestamp = Date.now()
      }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        var orientation = routeCamera.orientationAfterDrag(
          routeCamera.yaw, routeCamera.pitch,
          mouse.x - routeCamera.lastDragX, mouse.y - routeCamera.lastDragY,
          width, height)
        routeCamera.yaw = orientation.yaw
        routeCamera.pitch = orientation.pitch
        routeCamera.lastDragX = mouse.x
        routeCamera.lastDragY = mouse.y
      }
      onReleased: {
        routeCamera.dragging = false
        routeCamera.lastFrameTimestamp = Date.now()
      }
      onCanceled: {
        routeCamera.dragging = false
        routeCamera.lastFrameTimestamp = Date.now()
      }
    }

    Timer {
      interval: 16
      repeat: true
      running: viewport.panelActive
        && viewport.selectedSource === "gcode"
        && viewport.rendererStatus === "ready"
        && viewport.gcodeAvailable
        && (routeCamera.autoRotate || viewport.printing)
      onTriggered: routeCamera.advanceAutoRotation(Date.now())
    }

    Row {
      id: modelControls
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      width: Math.max(0, Math.min(Style.space(290),
        coordinateBadge.visible
          ? coordinateBadge.x - x - Style.space(10)
          : parent.width - x - Style.space(10)))
      height: Style.space(30)
      spacing: Style.space(8)

      BambuButton {
        width: Math.max(0, (modelControls.width - modelControls.spacing) / 2)
        height: modelControls.height
        clip: true
        enabled: viewport.selectedSource === "gcode" && viewport.gcodeAvailable
        text: routeCamera.autoRotate ? "AUTO-ROTATE ON" : "AUTO-ROTATE OFF"
        foreground: routeCamera.autoRotate ? viewport.accent : viewport.foreground
        accent: viewport.accent
        bordered: true
        onClicked: {
          routeCamera.autoRotate = !routeCamera.autoRotate
          routeCamera.lastFrameTimestamp = Date.now()
        }
      }

      BambuButton {
        width: Math.max(0, (modelControls.width - modelControls.spacing) / 2)
        height: modelControls.height
        clip: true
        enabled: viewport.daemonReady
        text: "RELOAD PREVIEW"
        foreground: viewport.foreground
        accent: viewport.accent
        bordered: true
        onClicked: viewport.reloadRequested()
      }
    }

    component SourceIconButton: BambuButton {
      id: sourceButton

      required property string sourceName
      required property bool available
      required property string sourceLabel
      required property url iconSource

      enabled: sourceName === "camera" ? available : true
      active: viewport.selectedSource === sourceName
      property string availableTooltip: "Show sliced " + sourceLabel
      property string unavailableTooltip: sourceLabel + " unavailable for this print"
      tooltipText: available ? availableTooltip : unavailableTooltip
      foreground: active ? viewport.accent
        : (enabled ? viewport.foreground : viewport.dim)
      accent: viewport.accent
      bordered: true
      onClicked: viewport.sourceRequested(sourceName)

      Image {
        id: sourceIconImage
        anchors.centerIn: parent
        width: Style.space(16)
        height: width
        source: sourceButton.iconSource
        sourceSize.width: width
        sourceSize.height: height
        visible: false
        layer.enabled: true
      }

      MultiEffect {
        anchors.fill: sourceIconImage
        source: sourceIconImage
        colorization: 1
        colorizationColor: sourceButton.foreground
      }
    }

    Column {
      id: sourceButtons
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.top: coordinateBadge.bottom
      anchors.topMargin: Style.space(8)
      width: Style.space(30)
      spacing: Style.space(6)
      z: 2

      SourceIconButton {
        width: sourceButtons.width
        height: width
        sourceName: "gcode"
        available: viewport.gcodeAvailable
        sourceLabel: "G-code route"
        iconSource: Qt.resolvedUrl("assets/route.svg")
      }

      SourceIconButton {
        width: sourceButtons.width
        height: width
        sourceName: "camera"
        available: viewport.cameraAvailable
        sourceLabel: "chamber camera"
        iconSource: Qt.resolvedUrl("assets/camera.svg")
        availableTooltip: "Show chamber camera"
        unavailableTooltip: viewport.cameraUnavailableTooltip()
      }

      SourceIconButton {
        width: sourceButtons.width
        height: width
        sourceName: "preview"
        available: viewport.previewAvailable
        sourceLabel: "2D preview"
        iconSource: Qt.resolvedUrl("assets/image.svg")
      }

      Item {
        width: sourceButtons.width
        height: Style.space(7)

        Rectangle {
          anchors.centerIn: parent
          width: Style.space(18)
          height: 1
          color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                         viewport.foreground.b, 0.22)
        }
      }

      BambuEventButton {
        width: sourceButtons.width
        height: width
        foreground: viewport.foreground
        accent: viewport.accent
        errorColor: viewport.errorColor
        warningColor: viewport.warningColor
        active: viewport.eventsActive
        unreadCount: viewport.unreadEventCount
        unreadErrorCount: viewport.unreadErrorCount
        unreadWarningCount: viewport.unreadWarningCount
        onClicked: viewport.eventsRequested()
      }
    }

    Rectangle {
      id: coordinateBadge
      visible: viewportFrame.width >= Style.space(480)
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      width: coordinateText.implicitWidth + Style.space(12)
      height: Style.space(30)
      color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                     viewport.foreground.b, 0.045)
      border.width: 1
      border.color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                            viewport.foreground.b, 0.12)
      Text {
        id: coordinateText
        anchors.centerIn: parent
        text: viewport.coordinateOverlay()
        color: viewport.dim
        font.family: viewport.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
      }
    }

    BambuButton {
      visible: viewport.selectedSource === "gcode"
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.bottom: modelFooter.top
      anchors.bottomMargin: Style.space(8)
      width: Style.space(132)
      height: Style.space(30)
      z: 2
      text: routeCamera.exploded ? "EXPLODE ON" : "EXPLODE OFF"
      enabled: viewport.gcodeAvailable
      active: routeCamera.exploded
      foreground: routeCamera.exploded ? viewport.accent : viewport.foreground
      accent: viewport.accent
      bordered: true
      onClicked: routeCamera.exploded = !routeCamera.exploded
    }

    Row {
      id: modelFooter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(10)
      width: Math.max(0, parent.width - Style.space(20))
      height: Style.space(18)
      spacing: Style.space(6)
      clip: true
      readonly property real cellWidth: Math.max(0,
        (width - spacing * 2) / 3)

      Item {
        width: modelFooter.cellWidth
        height: modelFooter.height
        clip: true
        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)
          Text {
            text: "● PRINTED"
            color: viewport.errorActive ? viewport.errorColor : viewport.accent
            font.family: viewport.fontFamily
            font.pixelSize: bambuStyle.captionFontSize
          }
          Text {
            text: "● REMAINING"
            color: viewport.dim
            font.family: viewport.fontFamily
            font.pixelSize: bambuStyle.captionFontSize
          }
        }
      }

      Text {
        width: modelFooter.cellWidth
        height: modelFooter.height
        text: "ZOOM ×" + routeCamera.formatZoom(routeCamera.zoom)
        color: viewport.dim
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.family: viewport.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
        font.bold: true
      }

      Text {
        width: modelFooter.cellWidth
        height: modelFooter.height
        text: "Z " + (isFinite(viewport.zCurrent)
          ? viewport.zCurrent.toFixed(2) + " mm" : "--")
        color: viewport.errorActive ? viewport.errorColor : viewport.accent
        elide: Text.ElideLeft
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        font.family: viewport.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
        font.bold: true
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(30)
      width: Math.max(0, parent.width - Style.space(40))
      text: viewport.modelError
      color: viewport.errorColor
      visible: viewport.modelError !== ""
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      font.family: viewport.fontFamily
      font.pixelSize: bambuStyle.captionFontSize
    }

    Column {
      anchors.centerIn: parent
      width: Math.max(0, parent.width - Style.space(48))
      spacing: Style.space(5)
      visible: viewport.selectedSource === "preview"
        ? !viewport.previewAvailable
        : (viewport.selectedSource === "camera"
          ? !viewport.cameraFrameAvailable
          : (viewport.rendererStatus !== "ready" || !viewport.gcodeAvailable))

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        height: Math.max(loadingTitle.implicitHeight, Style.space(12))
        spacing: Style.space(6)

        Text {
          id: loadingTitle
          anchors.verticalCenter: parent.verticalCenter
          text: viewport.emptyModelTitle()
          color: viewport.errorActive ? viewport.errorColor : viewport.dim
          font.family: viewport.fontFamily
          font.pixelSize: bambuStyle.captionFontSize
          font.bold: true
        }

        Item {
          id: loadingIndicator
          anchors.verticalCenter: parent.verticalCenter
          width: loadingDots.width
          height: Style.space(12)
          visible: viewport.printerConfigured
            && (viewport.rendererStatus === "compiling"
              || (viewport.modelStatus === "loading"
                && !viewport.downloadProgressVisible))

          Row {
            id: loadingDots
            anchors.centerIn: parent
            spacing: Style.space(3)

            Repeater {
              model: 3

              Rectangle {
                id: loadingDot
                required property int index
                property int phaseDelay: index * 120
                width: Style.space(3)
                height: width
                radius: width / 2
                color: viewport.accent

                transform: Translate { id: bounceOffset }

                SequentialAnimation {
                  running: viewport.panelActive && loadingIndicator.visible
                  loops: Animation.Infinite
                  PauseAnimation { duration: loadingDot.phaseDelay }
                  NumberAnimation {
                    target: bounceOffset
                    property: "y"
                    from: 0
                    to: -Style.space(3)
                    duration: 160
                    easing.type: Easing.OutQuad
                  }
                  NumberAnimation {
                    target: bounceOffset
                    property: "y"
                    to: 0
                    duration: 220
                    easing.type: Easing.InQuad
                  }
                  PauseAnimation {
                    duration: 720 - loadingDot.phaseDelay
                  }
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: downloadProgressTrack
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width, Style.space(240))
        height: Style.space(4)
        radius: height / 2
        visible: viewport.downloadProgressVisible
        color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                       viewport.foreground.b, 0.12)

        Rectangle {
          width: downloadProgressTrack.width * viewport.modelLoadProgress / 100
          height: downloadProgressTrack.height
          radius: downloadProgressTrack.radius
          color: viewport.accent

          Behavior on width {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
          }
        }
      }

      Text {
        width: parent.width
        text: viewport.emptyModelDetail()
        visible: text !== ""
        textFormat: Text.PlainText
        color: viewport.dim
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        font.family: viewport.fontFamily
        font.pixelSize: bambuStyle.captionFontSize
      }
    }
  }

  onActiveSegmentPathChanged: {
    syncRouteGeometry()
    syncNozzleMarker()
  }
  onActiveBoundsChanged: syncRouteGeometry()
  onZCurrentChanged: {
    syncRouteItem()
  }
  onPrintingChanged: syncNozzleMarker()
  onSelectedSourceChanged: {
    routeCamera.lastFrameTimestamp = 0
    syncRouteItem()
  }
  onAccentChanged: syncRouteItem()
  onForegroundChanged: syncRouteItem()
  onAutoRotateDefaultChanged: {
    routeCamera.autoRotate = viewport.autoRotateDefault
    routeCamera.lastFrameTimestamp = 0
  }
  onExplosionFactorChanged: syncRouteItem()
  onErrorActiveChanged: syncRouteItem()
  onErrorColorChanged: syncRouteItem()
  onPanelActiveChanged: {
    routeCamera.lastFrameTimestamp = 0
    if (viewport.panelActive) syncRouteItem()
  }
}
