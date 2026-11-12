import QtQuick

QtObject {
  id: assembler

  property int maxSegments: 1000000
  property int maxPreviewBytes: 524288
  property int maxPreviewPixels: 4194304
  property int maxPreviewChunkChars: 49152
  required property string segmentDirectory
  property int modelGeneration: -1
  property var geometryBundle: ({})
  property string selectedGeometrySource: "gcode"
  property var pendingGeometry: ({})

  readonly property bool previewAvailable:
    !!geometryBundle.preview
      && String(geometryBundle.preview.url || "").startsWith("data:image/png;base64,")
  readonly property bool gcodeAvailable:
    !!geometryBundle.gcode && String(geometryBundle.gcode.path || "").length > 0

  function objectOrEmpty(value) {
    return value && typeof value === "object" && !Array.isArray(value) ? value : ({})
  }

  function isNonNegativeInteger(value) {
    return typeof value === "number" && isFinite(value)
      && value >= 0 && Math.floor(value) === value
  }

  function validPreview(preview) {
    preview = objectOrEmpty(preview)
    if (!isNonNegativeInteger(preview.byteCount) || preview.byteCount < 1
        || preview.byteCount > assembler.maxPreviewBytes
        || !isNonNegativeInteger(preview.width) || preview.width < 1
        || !isNonNegativeInteger(preview.height) || preview.height < 1
        || preview.width * preview.height > assembler.maxPreviewPixels
        || preview.mimeType !== "image/png") return false
    var expectedLength = 4 * Math.ceil(preview.byteCount / 3)
    return isNonNegativeInteger(preview.encodedLength)
      && preview.encodedLength === expectedLength
  }

  function validSegmentPath(path) {
    if (typeof path !== "string" || path.length < 5 || path.length > 4096) return false
    var directory = String(assembler.segmentDirectory || "")
    if (directory.length < 2 || directory.charAt(0) !== "/"
        || directory.endsWith("/") || path.indexOf("\0") !== -1) return false
    var prefix = directory + "/route-"
    if (!path.startsWith(prefix)) return false
    return /^\d+\.f32$/.test(path.slice(prefix.length))
  }

  function selectSource(source) {
    if ((source === "preview" && assembler.previewAvailable)
        || (source === "gcode" && assembler.gcodeAvailable)) {
      selectedGeometrySource = source
      return true
    }
    return false
  }

  function clearPending() {
    pendingGeometry = ({})
  }

  function reset(generation) {
    modelGeneration = generation
    geometryBundle = ({})
    selectedGeometrySource = "gcode"
    clearPending()
  }

  function setGeneration(generation) {
    if (generation === modelGeneration) return false
    reset(generation)
    return true
  }

  function handleGeometry(message) {
    message = objectOrEmpty(message)
    var event = String(message.event || "")
    if (!isNonNegativeInteger(message.generation)) return
    var generation = message.generation
    if (generation !== modelGeneration) return
    if (event === "geometry_begin") beginGeometry(message, generation)
    else if (event === "geometry_preview_chunk") appendPreviewChunk(message, generation)
    else if (event === "geometry_end") finishGeometry(message, generation)
  }

  function beginGeometry(message, generation) {
    if (!isNonNegativeInteger(message.segmentCount)
        || message.segmentCount > assembler.maxSegments) {
      clearPending()
      return
    }
    var hasGcode = message.gcode !== null && message.gcode !== undefined
    var hasPreview = message.preview !== null && message.preview !== undefined
    var gcode = objectOrEmpty(message.gcode)
    if (hasGcode && (!isNonNegativeInteger(gcode.segmentCount)
        || gcode.segmentCount < 1 || gcode.segmentCount !== message.segmentCount)) {
      clearPending()
      return
    }
    if (!hasGcode && message.segmentCount !== 0) {
      clearPending()
      return
    }
    if (hasPreview && !validPreview(message.preview)) {
      clearPending()
      return
    }
    if (!hasGcode && !hasPreview) {
      clearPending()
      return
    }
    var packedPath = hasGcode ? String(gcode.path || "") : ""
    if (hasGcode && !validSegmentPath(packedPath)) {
      clearPending()
      return
    }
    pendingGeometry = {
      generation: generation,
      gcode: hasGcode ? {
        expectedSegments: gcode.segmentCount,
        bounds: objectOrEmpty(gcode.bounds),
        path: packedPath
      } : null,
      preview: hasPreview ? {
        byteCount: message.preview.byteCount,
        encodedLength: message.preview.encodedLength,
        width: message.preview.width,
        height: message.preview.height,
        parts: [],
        receivedLength: 0,
        nextChunk: 0
      } : null
    }
  }

  function appendPreviewChunk(message, generation) {
    var transaction = objectOrEmpty(pendingGeometry)
    if (generation !== transaction.generation) return
    var slot = transaction.preview
    var data = message.data
    if (message.source !== "preview" || !slot
        || !isNonNegativeInteger(message.index)
        || message.index !== slot.nextChunk
        || typeof data !== "string" || data.length < 1
        || data.length > assembler.maxPreviewChunkChars
        || slot.receivedLength + data.length > slot.encodedLength
        || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)
        || (data.indexOf("=") >= 0
          && slot.receivedLength + data.length !== slot.encodedLength)) {
      clearPending()
      return
    }
    slot.parts.push(data)
    slot.receivedLength += data.length
    slot.nextChunk += 1
  }

  function finishGeometry(message, generation) {
    var transaction = objectOrEmpty(pendingGeometry)
    if (generation !== transaction.generation) return
    var expected = []
    if (transaction.gcode) expected.push("gcode")
    if (transaction.preview) expected.push("preview")
    var announced = message.sources
    var chunks = objectOrEmpty(message.chunks)
    if (!Array.isArray(announced) || announced.length !== expected.length
        || Object.keys(chunks).length !== expected.length) {
      clearPending()
      return
    }
    for (let index = 0; index < expected.length; index++) {
      if (announced[index] !== expected[index]) {
        clearPending()
        return
      }
    }
    var slot = transaction.gcode
    if (slot && chunks.gcode !== 0) {
      clearPending()
      return
    }
    var preview = transaction.preview
    if (preview && (!isNonNegativeInteger(chunks.preview)
        || preview.nextChunk !== chunks.preview
        || preview.receivedLength !== preview.encodedLength)) {
      clearPending()
      return
    }
    var nextBundle = ({})
    if (slot) nextBundle.gcode = {
      bounds: slot.bounds,
      path: slot.path,
      segmentCount: slot.expectedSegments
    }
    if (preview) {
      let encoded = preview.parts.join("")
      let expectedPadding = preview.byteCount % 3 === 0
        ? 0 : 3 - preview.byteCount % 3
      let suffix = expectedPadding === 0 ? "" : (expectedPadding === 1 ? "=" : "==")
      if (!encoded.endsWith(suffix)
          || (expectedPadding > 0
            && encoded[encoded.length - expectedPadding - 1] === "=")) {
        clearPending()
        return
      }
      nextBundle.preview = {
        url: "data:image/png;base64," + encoded,
        width: preview.width,
        height: preview.height
      }
    }
    geometryBundle = nextBundle
    selectedGeometrySource = nextBundle.gcode ? "gcode" : "preview"
    clearPending()
  }
}
