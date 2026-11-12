import QtQuick
import Quickshell.Io

QtObject {
  id: backend

  required property string executable
  property int maxLineChars: 1048576
  property bool daemonReady: false
  readonly property bool running: sessionProcess.running

  property int restartDelay: 1000
  property bool restartScheduled: false
  property bool started: false
  property string stdoutBuffer: ""
  property bool stdoutDiscarding: false
  property string stderrBuffer: ""
  property bool stderrDiscarding: false

  signal lineReceived(string line)
  signal errorLineReceived(string line)
  signal stopped()
  signal writeFailed()

  function start() {
    if (started) return
    started = true
    sessionProcess.running = true
  }

  function markReady() {
    daemonReady = true
    restartDelay = 1000
  }

  function writeCommand(command) {
    if (!daemonReady || !sessionProcess.running) return false
    try {
      sessionProcess.write(JSON.stringify(command) + "\n")
      return true
    } catch (error) {
      writeFailed()
      return false
    }
  }

  function resetBuffers() {
    stdoutBuffer = ""
    stdoutDiscarding = false
    stderrBuffer = ""
    stderrDiscarding = false
  }

  function consumeChunk(chunk, stdoutStream) {
    var buffer = stdoutStream ? stdoutBuffer : stderrBuffer
    var discarding = stdoutStream ? stdoutDiscarding : stderrDiscarding
    var text = String(chunk === null || chunk === undefined ? "" : chunk)
    var offset = 0
    while (offset < text.length) {
      let newlineIndex = text.indexOf("\n", offset)
      let end = newlineIndex < 0 ? text.length : newlineIndex
      let part = text.slice(offset, end)
      if (!discarding) {
        if (buffer.length + part.length > maxLineChars) {
          buffer = ""
          discarding = true
        } else {
          buffer += part
        }
      }
      if (newlineIndex < 0) break
      if (!discarding) {
        let line = buffer.endsWith("\r") ? buffer.slice(0, -1) : buffer
        if (stdoutStream) lineReceived(line)
        else errorLineReceived(line)
      }
      buffer = ""
      discarding = false
      offset = newlineIndex + 1
    }
    if (stdoutStream) {
      stdoutBuffer = buffer
      stdoutDiscarding = discarding
    } else {
      stderrBuffer = buffer
      stderrDiscarding = discarding
    }
  }

  function handleRunningChanged() {
    if (sessionProcess.running) {
      restartScheduled = false
      return
    }
    if (!started) return
    daemonReady = false
    if (restartScheduled) return
    resetBuffers()
    stopped()
    restartScheduled = true
    restartTimer.interval = restartDelay
    restartDelay = Math.min(60000, restartDelay * 2)
    restartTimer.restart()
  }

  property Process sessionProcess: Process {
    command: [backend.executable]
    stdinEnabled: true
    running: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { backend.consumeChunk(chunk, true) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { backend.consumeChunk(chunk, false) }
    }
    onRunningChanged: backend.handleRunningChanged()
  }

  property Timer restartTimer: Timer {
    interval: 1000
    repeat: false
    onTriggered: {
      backend.restartScheduled = false
      if (!backend.sessionProcess.running) backend.sessionProcess.running = true
    }
  }
}
