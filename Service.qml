import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// SRT Replay service: owns the receive pipeline, the player, the recorder,
// and the pop-out window, so everything outlives the bar popup.
//
//   srt-live-transmit  SRT socket (listener/caller), stats JSON on stdout
//        | udp 127.0.0.1:P0
//   ffmpeg fanout      -c copy, tee to four loopback feeds
//        | P1 MediaPlayer (preview)
//        | P2 ffmpeg recorder (-c copy -> .mkv, on demand)
//        | P3 ffmpeg astats (audio meters)
//        | P4 ffmpeg segmenter (replay buffer for clips)
//
// Control from a terminal or keybinding:
//   omarchy-shell srt-replay toggle|start|stop|record|snapshot|popout|dock|play|status
//   omarchy-shell srt-replay clip <seconds>
Item {
  id: root

  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------ settings
  property var settings: ({})
  readonly property string home: Quickshell.env("HOME")
  readonly property string mode: settings.mode === "caller" ? "caller" : "listener"
  readonly property int port: clampInt(settings.port, 1, 65535, 9000)
  readonly property int latency: clampInt(settings.latency, 20, 8000, 120)
  readonly property string callerHost: String(settings.callerHost || "").trim()
  readonly property string recordDir: expandPath(settings.recordDir) || home + "/Videos/SRT"
  readonly property string snapshotDir: expandPath(settings.snapshotDir) || home + "/Pictures/SRT"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  // ------------------------------------------------------------ state
  property bool active: false
  property bool stopping: false
  property bool restartAfterStop: false
  property bool autoStarted: false
  property string error: ""
  property bool connected: false
  property int sessionCount: 0
  property string sessionId: ""
  property double sessionStartedAt: 0
  property double lastDataAt: 0
  property double now: Date.now()
  property string lanAddress: ""
  property int basePort: 0
  property string lastIngestLine: ""

  property bool wantPlay: true
  property bool muted: false
  property real volume: 1.0
  property string frozenFrame: ""

  property bool recordArmed: false
  property bool recording: false
  property bool recordStopping: false
  property string recordFile: ""
  property double recordStartedAt: 0
  property string recordError: ""

  property bool poppedOut: false
  property bool pinned: true
  property bool showStats: false
  property bool keepControls: false

  // Stats (SRT from srt-live-transmit, stream info from the fanout probe).
  property real rttMs: 0
  property real mbps: 0
  property real bufMs: 0
  property real tsbpdMs: 0
  property int lostTotal: 0
  property int dropTotal: 0
  property string videoCodec: ""
  property string resolution: ""
  property string fps: ""
  property string audioInfo: ""

  // Views register their VideoOutput; the player renders into whichever is shown.
  property Item dockOutput: null
  readonly property Item activeOutput: poppedOut ? floatingPlayer.videoOutput : dockOutput
  readonly property bool fullscreen: floatWin.fullscreen

  readonly property bool stalled: connected && lastDataAt > 0 && now - lastDataAt > 3000
  readonly property int recordSeconds: recording ? Math.max(0, Math.floor((now - recordStartedAt) / 1000)) : 0
  readonly property int sessionSeconds: connected ? Math.max(0, Math.floor((now - sessionStartedAt) / 1000)) : 0
  readonly property string status: error !== "" ? "error"
    : !active ? "idle"
    : connected ? (stalled ? "stalled" : "live")
    : "waiting"
  readonly property string endpoint: mode === "caller"
    ? "srt://" + (callerHost || "?") + ":" + port
    : "srt://" + (lanAddress || "0.0.0.0") + ":" + port
  readonly property string statusText: status === "error" ? error
    : status === "idle" ? "Off"
    : status === "live" ? "Live"
    : status === "stalled" ? "No data"
    : mode === "caller" ? "Connecting to " + endpoint
    : "Waiting on " + endpoint

  signal snapshotTaken(string path)

  // ------------------------------------------------------------ helpers
  function clampInt(value, lo, hi, fallback) {
    var n = parseInt(value, 10)
    if (!isFinite(n)) return fallback
    return Math.max(lo, Math.min(hi, n))
  }

  function expandPath(value) {
    var s = String(value || "").trim()
    if (s === "") return ""
    if (s === "~") return home
    if (s.indexOf("~/") === 0) return home + s.substr(1)
    return s.replace(/\/$/, "")
  }

  function stamp() {
    return Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss")
  }

  function notify(summary, body, icon) {
    Quickshell.execDetached(["notify-send", "-a", "SRT Replay", "-i", icon || "video-x-generic",
      summary, body || ""])
  }

  function udp(portNumber) {
    return "udp://127.0.0.1:" + portNumber + "?fifo_size=1000000&overrun_nonfatal=1"
  }

  readonly property string playUrl: basePort > 0 ? udp(basePort + 1) : ""

  // ------------------------------------------------------------ settings intake
  function applySettings(next) {
    var prev = root.settings || {}
    root.settings = next || {}
    var keys = ["mode", "port", "latency", "callerHost"]
    var changed = false
    for (var i = 0; i < keys.length; i++)
      if (String(prev[keys[i]]) !== String(root.settings[keys[i]])) changed = true
    if (changed && root.active) configRestart.restart()
    if (!root.autoStarted && root.settings.autoStart === "On") {
      root.autoStarted = true
      Qt.callLater(root.start)
    }
  }

  // Debounced so typing a port doesn't bounce the listener per keystroke.
  // A running recording is never interrupted; the change applies after it.
  Timer {
    id: configRestart
    interval: 700
    onTriggered: {
      if (!root.active) return
      if (root.recordArmed) { restart(); return }
      root.restartPipeline()
    }
  }

  // ------------------------------------------------------------ pipeline
  function start() {
    if (root.active) return
    if (ingest.running || fanout.running) {
      root.restartAfterStop = true
      return
    }
    if (root.mode === "caller" && root.callerHost === "") {
      root.error = "Set a remote host for caller mode"
      return
    }
    root.error = ""
    root.lastIngestLine = ""
    // P0 ingest, P1 player, P2 recorder, P3 audio meters, P4 replay buffer.
    root.basePort = 30000 + Math.floor(Math.random() * 6000) * 5
    root.sessionCount = 0
    root._replayStuckNotified = false
    root.resetStats()
    root.refreshLanAddress()
    ensureDirs.command = ["mkdir", "-p", root.recordDir, root.snapshotDir]
    ensureDirs.running = true

    var srtUrl = root.mode === "caller"
      ? "srt://" + root.callerHost + ":" + root.port + "?mode=caller&latency=" + root.latency
      : "srt://:" + root.port + "?mode=listener&latency=" + root.latency
    ingest.command = ["srt-live-transmit", "-s:200", "-pf:json", srtUrl,
      "udp://127.0.0.1:" + root.basePort]
    ingest.running = true
    root.active = true
    root.startFanout()
    root.startMeter()
    root.startReplay()
    if (root.wantPlay) root.startPlayer()
  }

  function stop() {
    if (!root.active && !ingest.running && !fanout.running) return
    root.stopping = true
    root.active = false
    root.connected = false
    root.recordArmed = false
    root.stopRecorder()
    root.stopPlayer()
    root.stopMeter()
    root.stopReplay()
    root.frozenFrame = ""
    if (ingest.running) ingest.signal(15)
    if (fanout.running) fanout.signal(9)
    reaper.restart()
    root.resetStats()
  }

  function restartPipeline() {
    root.restartAfterStop = true
    root.stop()
  }

  function toggleActive() {
    if (root.active) root.stop()
    else root.start()
  }

  function processesSettled() {
    if (ingest.running || fanout.running) return
    reaper.stop()
    root.stopping = false
    if (root.restartAfterStop) {
      root.restartAfterStop = false
      root.start()
    }
  }

  // srt-live-transmit closes its socket on SIGTERM; anything still alive
  // after this grace period gets SIGKILL.
  Timer {
    id: reaper
    interval: 1500
    onTriggered: {
      if (ingest.running) ingest.signal(9)
      if (fanout.running) fanout.signal(9)
    }
  }

  function startFanout() {
    if (fanout.running) {
      fanout.restartPending = true
      fanout.signal(9)
      return
    }
    root.videoCodec = ""
    root.resolution = ""
    root.fps = ""
    root.audioInfo = ""
    var p = root.basePort
    // Default probing on purpose: a capped probe can pass an audio track on
    // with unknown parameters ("0 channels"), which crashes Qt's resampler.
    fanout.command = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "info", "-nostats",
      "-progress", "pipe:1", "-stats_period", "0.5", "-fflags", "+discardcorrupt",
      "-f", "mpegts", "-i", root.udp(p),
      "-map", "0:v?", "-map", "0:a?", "-c", "copy", "-f", "tee",
      "[f=mpegts:onfail=ignore]udp://127.0.0.1:" + (p + 1) + "?pkt_size=1316"
        + "|[f=mpegts:onfail=ignore]udp://127.0.0.1:" + (p + 2) + "?pkt_size=1316"
        // Audio-only copy for the meters. A source without audio just fails
        // this slave; the other two keep running.
        + "|[f=mpegts:select=a:onfail=ignore]udp://127.0.0.1:" + (p + 3) + "?pkt_size=1316"
        + "|[f=mpegts:onfail=ignore]udp://127.0.0.1:" + (p + 4) + "?pkt_size=1316"]
    fanout.running = true
  }

  function resetStats() {
    root.rttMs = 0
    root.mbps = 0
    root.bufMs = 0
    root.tsbpdMs = 0
    root.lostTotal = 0
    root.dropTotal = 0
    root.lastDataAt = 0
    root.sessionId = ""
  }

  function onConnected() {
    if (root.connected) return
    root.connected = true
    root.sessionStartedAt = Date.now()
    root.lastDataAt = Date.now()
    root.sessionCount += 1
    root._replayStuckNotified = false
    // A new caller restarts timestamps; give the fanout and player a clean start.
    if (root.sessionCount > 1) {
      root.startFanout()
      root.restartMeter()
      root.restartReplay()
      if (root.wantPlay) root.restartPlayer()
    }
    if (root.recordArmed) recorderDelay.restart()
  }

  function onDisconnected() {
    if (!root.connected) return
    root.connected = false
    root.resetStats()
    // The next caller may send something else; the fanout re-probes on reconnect.
    root.videoCodec = ""
    root.resolution = ""
    root.fps = ""
    root.audioInfo = ""
    root.resetMeters()
    // Close the current file cleanly; an armed recording resumes into a new
    // file when the next caller connects.
    root.stopRecorder()
  }

  function onStatsLine(line) {
    var j
    try { j = JSON.parse(line) } catch (e) { return }
    if (!j || !j.recv) return
    root.lastDataAt = Date.now()
    if (!root.connected) root.onConnected()
    root.sessionId = String(j.sid || "")
    root.rttMs = Number(j.link && j.link.rtt) || 0
    root.mbps = Number(j.recv.mbitRate) || 0
    root.bufMs = Number(j.recv.msBuf) || 0
    root.tsbpdMs = Number(j.recv.msTsbPdDelay) || 0
    root.lostTotal += Number(j.recv.packetsLost) || 0
    root.dropTotal += Number(j.recv.packetsDropped) || 0
  }

  function onIngestLine(line) {
    var s = String(line || "").trim()
    if (s === "") return
    if (/disconnected/i.test(s)) root.onDisconnected()
    else if (/accepted|connected/i.test(s)) root.onConnected()
    else if (/error/i.test(s)) root.lastIngestLine = s
  }

  function onFanoutLine(line) {
    var video = line.match(/Stream #\d+:\d+.*?: Video: (\w+)[^,]*,.*?(\d{2,5}x\d{2,5})(?:.*?([\d.]+) fps)?/)
    if (video) {
      root.videoCodec = video[1].toUpperCase()
      root.resolution = video[2]
      root.fps = video[3] || ""
      return
    }
    var audio = line.match(/Stream #\d+:\d+.*?: Audio: (\w+)[^,]*, (\d+) Hz, ([^,]+)/)
    if (audio && root.audioInfo === "")
      root.audioInfo = audio[1].toUpperCase() + " " + Math.round(Number(audio[2]) / 100) / 10 + " kHz " + audio[3].trim()
  }

  Process {
    id: ingest
    stdout: SplitParser { onRead: function(data) { root.onStatsLine(data) } }
    stderr: SplitParser { onRead: function(data) { root.onIngestLine(data) } }
    onExited: function(exitCode) {
      if (root.active && !root.stopping) {
        var detail = root.lastIngestLine
        root.stop()
        root.error = /bind|configure SRT socket/i.test(detail)
          ? "Port " + root.port + " is busy or unavailable"
          : (detail || "srt-live-transmit exited (" + exitCode + ")")
      }
      root.processesSettled()
    }
  }

  Process {
    id: fanout
    property bool restartPending: false
    stdout: SplitParser {
      onRead: function(data) {
        if (data.indexOf("out_time_us=") === 0) root.lastDataAt = Date.now()
      }
    }
    stderr: SplitParser { onRead: function(data) { root.onFanoutLine(data) } }
    onExited: function() {
      var again = restartPending || (root.active && !root.stopping)
      restartPending = false
      if (again && root.active) fanoutRetry.restart()
      root.processesSettled()
    }
  }

  Timer {
    id: fanoutRetry
    interval: 150
    onTriggered: if (root.active && !fanout.running) root.startFanout()
  }

  // The address shown in the listener URL: the source address of the default
  // route, or the first global IPv4 address when there's no default route.
  // Looked up when the service loads, on start, and whenever the panel opens,
  // so the URL is right before SRT is switched on and after network changes.
  function refreshLanAddress() {
    if (!lanQuery.running) lanQuery.running = true
  }

  Process {
    id: lanQuery
    running: true
    command: ["sh", "-c",
      "ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == \"src\") { print $(i + 1); exit }}' | grep . "
        + "|| ip -4 -o addr show scope global 2>/dev/null | awk '{ split($4, a, \"/\"); print a[1]; exit }'"]
    stdout: StdioCollector {
      onStreamFinished: {
        var ip = String(text || "").trim()
        if (ip !== "") root.lanAddress = ip
      }
    }
  }

  Process { id: ensureDirs }

  // ------------------------------------------------------------ audio meters
  // The fanout's audio-only copy (P3) is decoded by its own ffmpeg, which
  // prints per-channel peak level every 2048 samples (~23 Hz at 48 kHz).
  // It is separate from the player and recorder, so a meter failure can't
  // touch either. Levels are measured at the live edge, slightly ahead of
  // the player's buffered picture.
  property bool showMeters: true
  property var meterChannels: []   // [{ level, hold, clip }] in dBFS, for the UI
  property var _meterWindow: []    // per-channel peaks of the window being parsed
  property var _meterState: []     // ballistics per channel
  property double _meterAt: 0
  readonly property real meterFallDbPerSec: 12
  readonly property int meterHoldMs: 1500
  readonly property int meterClipMs: 2000
  readonly property bool metersWanted: active && showMeters

  onMetersWantedChanged: metersWanted ? startMeter() : stopMeter()

  function startMeter() {
    if (meter.running || !root.metersWanted || root.basePort === 0) return
    meter.command = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-nostats",
      "-f", "mpegts", "-i", root.udp(root.basePort + 3), "-map", "0:a:0", "-vn",
      "-af", "asetnsamples=n=2048:p=0,astats=metadata=1:reset=1:measure_perchannel=Peak_level:measure_overall=none,"
        // direct=1: without it ffmpeg buffers ~32 KB of prints, so levels
        // would arrive in bursts seconds apart instead of per window.
        + "ametadata=mode=print:direct=1:file=/dev/stdout",
      "-f", "null", "-"]
    meter.running = true
  }

  function stopMeter() {
    meterRetry.stop()
    if (meter.running) meter.signal(9)
    root.resetMeters()
  }

  function restartMeter() {
    root.resetMeters()
    if (meter.running) {
      meter.restartPending = true
      meter.signal(9)
    } else {
      root.startMeter()
    }
  }

  function resetMeters() {
    root._meterWindow = []
    root._meterState = []
    root._meterAt = 0
    root.meterChannels = []
  }

  // Levels to the floor, channel layout kept (audio paused, not gone).
  function silenceMeters() {
    var out = []
    for (var i = 0; i < root.meterChannels.length; i++) out.push({ level: -120, hold: -120, clip: false })
    root._meterState = []
    root._meterAt = 0
    root.meterChannels = out
  }

  function toggleMeters() { root.showMeters = !root.showMeters }

  // "frame:" opens a new window, so it closes the previous one.
  function onMeterLine(line) {
    if (line.indexOf("frame:") === 0) {
      root.commitMeterWindow()
      return
    }
    var m = line.match(/^lavfi\.astats\.(\d+)\.Peak_level=(.+)$/)
    if (!m) return
    var db = parseFloat(m[2])
    root._meterWindow[parseInt(m[1], 10) - 1] = isFinite(db) ? db : -120
  }

  // Peak-programme ballistics: instant rise, steady fall, a held peak marker,
  // and a clip lamp latched at full scale.
  function commitMeterWindow() {
    var peaks = root._meterWindow
    root._meterWindow = []
    if (peaks.length === 0) return
    var now = Date.now()
    var dt = root._meterAt > 0 ? Math.min(0.5, (now - root._meterAt) / 1000) : 0
    root._meterAt = now
    var fall = root.meterFallDbPerSec * dt
    var state = root._meterState
    var out = []
    for (var i = 0; i < peaks.length; i++) {
      var p = peaks[i] === undefined ? -120 : peaks[i]
      var s = state[i] || { level: -120, hold: -120, holdUntil: 0, clipUntil: 0 }
      s.level = Math.max(p, s.level - fall)
      if (p >= s.hold) {
        s.hold = p
        s.holdUntil = now + root.meterHoldMs
      } else if (now > s.holdUntil) {
        s.hold = Math.max(s.level, s.hold - fall)
      }
      if (p >= -0.1) s.clipUntil = now + root.meterClipMs
      state[i] = s
      out.push({ level: s.level, hold: s.hold, clip: now < s.clipUntil })
    }
    root._meterState = state
    root.meterChannels = out
  }

  Process {
    id: meter
    property bool restartPending: false
    stdout: SplitParser { onRead: function(data) { root.onMeterLine(data) } }
    onExited: function() {
      var again = restartPending
      restartPending = false
      // A source without audio makes ffmpeg exit on "-map 0:a:0"; retry slowly.
      if (root.metersWanted && !root.stopping) meterRetry.interval = again ? 150 : 3000
      if (root.metersWanted && !root.stopping) meterRetry.restart()
    }
  }

  Timer {
    id: meterRetry
    interval: 3000
    onTriggered: root.startMeter()
  }

  // Drop the bars to the floor when audio stops arriving (stream stalled).
  Timer {
    interval: 250
    repeat: true
    running: root.metersWanted && root._meterAt > 0
    onTriggered: if (Date.now() - root._meterAt > 600) root.silenceMeters()
  }

  // ------------------------------------------------------------ replay buffer + clips
  // The fanout's P4 copy is cut by ffmpeg's segment muxer into ~1 s MPEG-TS
  // segments, each starting on a keyframe, in a RAM-backed runtime dir.
  // bin/srt-replay prunes it to the last replayKeepSeconds and remuxes the
  // newest segments into an MKV on demand. It runs whether or not a
  // recording is armed. The buffer outlives a caller disconnecting (so the
  // end of a stream can still be clipped); a new session or stopping SRT
  // clears it. If the segment being written can never close (the stream
  // stopped sending keyframes), prune reports it stuck and the buffer is
  // reset, so it can't grow in RAM without limit.
  readonly property bool replayEnabled: settings.replayBuffer !== "Off"
  readonly property int replayKeepSeconds: 75
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/srt-replay"
  readonly property string replayDir: runtimeDir + "/replay"
  readonly property string clipDir: recordDir + "/Clips"
  readonly property string replayTool: pluginDir + "/bin/srt-replay"
  readonly property bool replayWanted: active && replayEnabled
  property int replaySeconds: 0     // buffered duration, refreshed by each prune
  property string replayError: ""
  property var clipQueue: []
  property bool clipping: false
  property string lastClip: ""
  property int _lastClipLength: 0
  property double _lastClipAt: 0
  property bool _replayStuckNotified: false

  onReplayWantedChanged: replayWanted ? startReplay() : stopReplay()

  function startReplay() {
    if (replay.running || !root.replayWanted || root.basePort === 0) return
    var dir = root.replayDir
    root.replaySeconds = 0
    root.replayError = ""
    // Default probing on purpose: the segment muxer refuses an audio track
    // whose parameters weren't found.
    replay.command = ["sh", "-c", "rm -rf \"$0\" && mkdir -p \"$0\" && exec \"$@\"", dir,
      "ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error", "-nostats",
      "-f", "mpegts", "-i", root.udp(root.basePort + 4),
      "-map", "0:v?", "-map", "0:a?", "-c", "copy",
      "-f", "segment", "-segment_time", "1", "-segment_format", "mpegts",
      "-segment_list", dir + "/list.csv", "-segment_list_type", "csv", "-segment_list_size", "200",
      dir + "/seg%08d.ts"]
    replay.running = true
  }

  // Stopping SRT frees the buffer's RAM.
  function stopReplay() {
    replayRetry.stop()
    if (replay.running) replay.signal(9)
    root.replaySeconds = 0
    Quickshell.execDetached(["rm", "-rf", root.replayDir])
  }

  function onReplayStuck() {
    if (!root._replayStuckNotified) {
      root._replayStuckNotified = true
      root.notify("Clip buffer reset",
        "The stream stopped sending keyframes, so the replay buffer was cleared to keep it from growing in RAM.",
        "dialog-warning")
    }
    root.restartReplay()
  }

  function restartReplay() {
    if (replay.running) {
      replay.restartPending = true
      replay.signal(9)
    } else {
      root.startReplay()
    }
  }

  function clipLabel(seconds) {
    return seconds % 60 === 0 ? (seconds / 60) + "m" : seconds + "s"
  }

  function clip(seconds) {
    var s = root.clampInt(seconds, 1, root.replayKeepSeconds - 10, 30)
    if (!root.replayEnabled) return "replay buffer is off"
    if (root.replaySeconds <= 0 && !root.active) return "replay buffer is empty"
    // Ignore an accidental double-click of the same length.
    var now = Date.now()
    if (s === root._lastClipLength && now - root._lastClipAt < 1500) return "already saving"
    root._lastClipLength = s
    root._lastClipAt = now
    root.clipQueue = root.clipQueue.concat([s])
    root.runNextClip()
    return "saving last " + root.clipLabel(s)
  }

  function runNextClip() {
    if (clipper.running || root.clipQueue.length === 0) return
    var s = root.clipQueue[0]
    root.clipQueue = root.clipQueue.slice(1)
    clipper.requested = s
    clipper.saved = ""
    clipper.err = ""
    clipper.command = [root.replayTool, "clip", root.replayDir, String(s),
      root.clipDir + "/srt-clip-" + root.stamp() + "-" + root.clipLabel(s) + ".mkv"]
    root.clipping = true
    clipper.running = true
  }

  Process {
    id: replay
    property bool restartPending: false
    stderr: SplitParser { onRead: function(data) { if (String(data).trim() !== "") root.replayError = String(data).trim() } }
    onExited: function() {
      var again = restartPending
      restartPending = false
      if (root.replayWanted && !root.stopping) {
        replayRetry.interval = again ? 150 : 3000
        replayRetry.restart()
      }
    }
  }

  Timer {
    id: replayRetry
    interval: 3000
    onTriggered: root.startReplay()
  }

  Process {
    id: replayPrune
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = String(text || "").trim().split(/\s+/)
        var n = parseInt(parts[0], 10)
        if (isFinite(n)) root.replaySeconds = n
        if (parts[1] === "1" && replay.running) root.onReplayStuck()
      }
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.replayWanted
    onTriggered: {
      if (replayPrune.running) return
      replayPrune.command = [root.replayTool, "prune", root.replayDir, String(root.replayKeepSeconds)]
      replayPrune.running = true
    }
  }

  // The helper prints "<path> <seconds>" on success. Success is reported from
  // stdout and failure from the exit code, so neither depends on the order
  // Quickshell delivers output and exit.
  Process {
    id: clipper
    property int requested: 0
    property string saved: ""
    property string err: ""
    stdout: SplitParser {
      onRead: function(data) {
        var m = String(data).match(/^(.*\.mkv) ([\d.]+)$/)
        if (!m) return
        clipper.saved = m[1]
        root.lastClip = m[1]
        var secs = Math.round(parseFloat(m[2]) * 10) / 10
        root.notify("Clip saved (" + secs + " s)", m[1], "video-x-generic")
      }
    }
    stderr: SplitParser { onRead: function(data) { if (String(data).trim() !== "") clipper.err = String(data).trim() } }
    onExited: function(exitCode) {
      if (exitCode !== 0 && clipper.saved === "")
        root.notify("Clip failed", clipper.err || ("Could not save the last " + root.clipLabel(clipper.requested)), "dialog-error")
      root.clipping = false
      root.runNextClip()
    }
  }

  // ------------------------------------------------------------ clip hotkeys
  // Keys 1/2/3/6 clip the last 10 s/20 s/30 s/1 min. They're bound in
  // Hyprland at runtime (hyprctl eval) only while enabled in the panel and a
  // caller is connected, and they consume the key: the digit doesn't reach
  // the focused app while armed. hl.unbind removes by key, so any other
  // unmodified binding on these digits would be removed along with ours.
  readonly property var hotkeyMap: [["1", 10], ["2", 20], ["3", 30], ["6", 60]]
  readonly property string hotkeyTag: "SRT Replay: clip"
  // Absolute: Hyprland's launch environment doesn't have Omarchy's bin on PATH.
  readonly property string omarchyShell: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/bin/omarchy-shell"
  readonly property bool hotkeysEnabled: settings.clipHotkeys === "On"
  readonly property bool hotkeysArmed: hotkeysEnabled && replayEnabled && connected
  property bool hotkeysBound: false
  property bool hotkeysFailed: false
  property bool _hotkeysMaybeBound: false
  property bool _hotkeySyncPending: false

  onHotkeysArmedChanged: syncHotkeys()

  function hotkeyLua(bind) {
    var parts = []
    for (var i = 0; i < root.hotkeyMap.length; i++)
      parts.push('hl.unbind("' + root.hotkeyMap[i][0] + '")')
    if (bind) {
      for (var j = 0; j < root.hotkeyMap.length; j++) {
        var key = root.hotkeyMap[j][0]
        var secs = root.hotkeyMap[j][1]
        parts.push('hl.bind("' + key + '", hl.dsp.exec_cmd("' + root.omarchyShell + ' srt-replay clip ' + secs
          + '"), { description = "' + root.hotkeyTag + ' last ' + root.clipLabel(secs) + '" })')
      }
    }
    return parts.join("; ")
  }

  // Applies the current armed state, then counts the binds actually present:
  // hyprctl eval answers "ok" even for a bind it didn't accept.
  function syncHotkeys() {
    if (hotkeyProc.running) {
      root._hotkeySyncPending = true
      return
    }
    var bind = root.hotkeysArmed
    if (bind) {
      root._hotkeysMaybeBound = true
    } else if (!root._hotkeysMaybeBound) {
      root.hotkeysBound = false
      root.hotkeysFailed = false
      return
    }
    hotkeyProc.command = ["sh", "-c",
      "hyprctl eval \"$0\" >/dev/null 2>&1; hyprctl binds -j | jq --arg t \"$1\" "
        + "'[.[] | select(.modmask == 0 and ((.description // \"\") | startswith($t)))] | length'",
      root.hotkeyLua(bind), root.hotkeyTag]
    hotkeyProc.running = true
  }

  // Persisted like the panel toggle, so IPC and the panel stay in step.
  function setHotkeysEnabled(on) {
    var next = {}
    for (var k in root.settings) if (k !== "id") next[k] = root.settings[k]
    next.clipHotkeys = on ? "On" : "Off"
    root.applySettings(next)
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline((root.manifest && root.manifest.id) || "io.github.chachizr.srt-replay", next)
  }

  Process {
    id: hotkeyProc
    stdout: StdioCollector {
      onStreamFinished: {
        var n = parseInt(text, 10)
        root.hotkeysBound = n === root.hotkeyMap.length
        root.hotkeysFailed = root.hotkeysArmed && n !== root.hotkeyMap.length
        if (n === 0) root._hotkeysMaybeBound = false
      }
    }
    onExited: {
      if (root._hotkeySyncPending) {
        root._hotkeySyncPending = false
        root.syncHotkeys()
      }
    }
  }

  // After a shell crash our binds would stay behind and keep swallowing the
  // digits. On startup, remove them if any are still registered.
  Process {
    running: true
    command: ["sh", "-c",
      "hyprctl binds -j | jq -e --arg t \"$1\" 'any(.[]; (.description // \"\") | startswith($t))' >/dev/null "
        + "&& hyprctl eval \"$0\" >/dev/null 2>&1; true",
      root.hotkeyLua(false), root.hotkeyTag]
  }

  // A Hyprland config reload rebuilds binds and window rules from the config
  // files and drops ours, so register them again once it has settled.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") hyprResync.restart()
    }
  }

  Timer {
    id: hyprResync
    interval: 300
    onTriggered: {
      root.registerWindowRule()
      if (root.hotkeysArmed) root.syncHotkeys()
    }
  }

  // ------------------------------------------------------------ window rule
  // Floats, pins, sizes, and places the pop-out player. Registered with
  // Hyprland at runtime instead of in the user's config: added when the
  // service loads, re-added after a config reload, removed on unload. Rules
  // live in a Lua table keyed per service instance, so a plugin reload can't
  // disable the new instance's rule, and registering clears rules left behind
  // by an instance that never unloaded (a shell crash).
  readonly property string windowRuleKey: String(Date.now()) + String(Math.floor(Math.random() * 1000000))
  readonly property string windowRuleLua: "srt_replay_rules = srt_replay_rules or {}; "
    + "for k, r in pairs(srt_replay_rules) do r:set_enabled(false); srt_replay_rules[k] = nil end; "
    + "srt_replay_rules[\"" + windowRuleKey + "\"] = hl.window_rule({ "
    + "match = { class = \"^org.quickshell$\", title = \"^SRT Replay$\" }, "
    + "tag = \"-default-opacity\", float = true, pin = true, size = { 960, 540 }, keep_aspect_ratio = true, "
    + "opacity = \"1 1\", move = { \"(monitor_w-window_w-40)\", \"(monitor_h*0.06)\" } })"
  readonly property string windowRuleRemoveLua: "if srt_replay_rules and srt_replay_rules[\"" + windowRuleKey + "\"] then "
    + "srt_replay_rules[\"" + windowRuleKey + "\"]:set_enabled(false); srt_replay_rules[\"" + windowRuleKey + "\"] = nil end"

  function registerWindowRule() {
    Quickshell.execDetached(["hyprctl", "eval", root.windowRuleLua])
  }

  Component.onCompleted: registerWindowRule()

  // ------------------------------------------------------------ player
  function startPlayer() {
    if (!root.active || root.playUrl === "") return
    player.source = root.playUrl
    player.play()
  }

  function stopPlayer() {
    playerRetry.stop()
    player.stop()
    player.source = ""
  }

  function restartPlayer() {
    root.stopPlayer()
    playerRetry.restart()
  }

  // Live streams can't really pause: freeze the last frame on screen, drop
  // the decoder, and rejoin at the live edge on resume. Recording continues.
  function togglePlay() {
    if (!root.active) { root.wantPlay = true; root.start(); return }
    if (root.wantPlay) {
      root.wantPlay = false
      var out = root.activeOutput
      if (out && out.visible && root.connected) {
        out.grabToImage(function(result) {
          if (!root.wantPlay) root.frozenFrame = result.url
        })
      }
      root.stopPlayer()
    } else {
      root.wantPlay = true
      root.startPlayer()
    }
  }

  // Parks the player while no view is on screen. Detaching the video output
  // entirely makes Qt tear down its renderer and rebuild the playback
  // session on reattach (~2 s of black on every dock/pop-out/panel open);
  // swapping between two sinks is instant.
  VideoSink { id: idleSink }

  MediaPlayer {
    id: player
    videoOutput: root.activeOutput ? root.activeOutput : idleSink
    audioOutput: AudioOutput {
      muted: root.muted
      volume: root.volume
    }
    playbackOptions.playbackIntent: PlaybackOptions.LowLatencyStreaming

    onMediaStatusChanged: {
      if (mediaStatus === MediaPlayer.BufferedMedia) root.frozenFrame = ""
      if (mediaStatus === MediaPlayer.EndOfMedia || mediaStatus === MediaPlayer.InvalidMedia)
        if (root.active && root.wantPlay) root.restartPlayer()
    }
    onErrorOccurred: if (root.active && root.wantPlay) root.restartPlayer()
  }

  // Frame pacing, measured where frames land: decoded frames reaching the
  // visible sink vs. frames the hosting window actually presented.
  property int decodedFrames: 0
  property int renderedFrames: 0
  property real decodeFps: 0
  property real renderFps: 0
  property int hitches: 0
  property double lastFrameAt: 0
  property real frameIntervalMs: 0

  function resetPacing() {
    root.decodedFrames = 0
    root.renderedFrames = 0
    root.decodeFps = 0
    root.renderFps = 0
    root.hitches = 0
    root.lastFrameAt = 0
    root.frameIntervalMs = 0
  }

  function samplePacing() {
    root.decodeFps = root.decodedFrames
    root.renderFps = root.renderedFrames
    root.decodedFrames = 0
    root.renderedFrames = 0
  }

  Connections {
    target: root.activeOutput ? root.activeOutput.videoSink : null
    function onVideoFrameChanged() {
      var t = Date.now()
      if (root.lastFrameAt > 0) {
        var dt = t - root.lastFrameAt
        if (root.frameIntervalMs > 0 && dt > root.frameIntervalMs * 2.5) root.hitches += 1
        root.frameIntervalMs = root.frameIntervalMs > 0 ? root.frameIntervalMs * 0.95 + dt * 0.05 : dt
      }
      root.lastFrameAt = t
      root.decodedFrames += 1
    }
  }

  Connections {
    target: root.activeOutput ? root.activeOutput.Window.window : null
    function onFrameSwapped() { root.renderedFrames += 1 }
  }

  Timer {
    id: playerRetry
    interval: 400
    onTriggered: if (root.active && root.wantPlay) root.startPlayer()
  }

  function toggleMute() { root.muted = !root.muted }

  function setVolume(v) {
    root.volume = Math.max(0, Math.min(1, v))
    if (root.volume > 0) root.muted = false
  }

  // ------------------------------------------------------------ recording
  function toggleRecord() {
    if (root.recordArmed) {
      root.recordArmed = false
      root.stopRecorder()
      return
    }
    root.recordArmed = true
    if (!root.active) root.start()
    else if (root.connected) root.startRecorder()
  }

  function startRecorder() {
    if (recorder.running || !root.recordArmed || !root.connected) return
    root.recordError = ""
    root.recordFile = root.recordDir + "/srt-" + root.stamp() + ".mkv"
    recorder.command = ["sh", "-c", "mkdir -p \"$0\" && exec \"$@\"", root.recordDir,
      "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostats",
      "-f", "mpegts", "-i", root.udp(root.basePort + 2),
      "-map", "0:v?", "-map", "0:a?", "-c", "copy", "-f", "matroska", root.recordFile]
    recorder.running = true
    root.recording = true
    root.recordStartedAt = Date.now()
  }

  // "q" lets ffmpeg write the Matroska cues/duration; signals are fallbacks.
  function stopRecorder() {
    recorderDelay.stop()
    if (!recorder.running) return
    root.recordStopping = true
    recorder.write("q\n")
    recordReaper.stage = 0
    recordReaper.restart()
  }

  Timer {
    id: recorderDelay
    interval: 700
    onTriggered: root.startRecorder()
  }

  Timer {
    id: recordReaper
    property int stage: 0
    interval: 3000
    onTriggered: {
      if (!recorder.running) return
      recorder.signal(stage === 0 ? 2 : 9)
      stage += 1
      if (stage < 2) restart()
    }
  }

  Process {
    id: recorder
    stdinEnabled: true
    stderr: SplitParser { onRead: function(data) { if (String(data).trim() !== "") root.recordError = String(data).trim() } }
    onExited: function(exitCode) {
      var expected = root.recordStopping
      var seconds = Math.floor((Date.now() - root.recordStartedAt) / 1000)
      recordReaper.stop()
      root.recording = false
      root.recordStopping = false
      if (expected || exitCode === 0) {
        if (seconds >= 1) root.notify("Recording saved", root.recordFile + " (" + root.formatDuration(seconds) + ")", "media-record")
      } else {
        root.recordArmed = false
        root.notify("Recording failed", root.recordError || ("ffmpeg exited with " + exitCode), "dialog-error")
      }
    }
  }

  function formatDuration(total) {
    var h = Math.floor(total / 3600)
    var m = Math.floor((total % 3600) / 60)
    var s = total % 60
    function two(n) { return n < 10 ? "0" + n : String(n) }
    return (h > 0 ? h + ":" : "") + two(m) + ":" + two(s)
  }

  // ------------------------------------------------------------ snapshot
  function snapshot() {
    var out = root.activeOutput
    if (!out || !out.visible) return "no visible player"
    var src = out.sourceRect
    var size = src && src.width > 0 ? Qt.size(src.width, src.height) : Qt.size(out.width, out.height)
    var file = root.snapshotDir + "/srt-" + root.stamp() + ".png"
    out.grabToImage(function(result) {
      if (result.saveToFile(file)) {
        root.snapshotTaken(file)
        root.notify("Snapshot saved", file, "camera-photo")
      } else {
        root.notify("Snapshot failed", "Could not write " + file, "dialog-error")
      }
    }, size)
    return file
  }

  // ------------------------------------------------------------ window
  function popOut() { root.poppedOut = true }

  function dock() {
    floatWin.fullscreen = false
    root.poppedOut = false
  }

  function toggleFullscreen() {
    if (!root.poppedOut) {
      root.poppedOut = true
      fullscreenLater.restart()
      return
    }
    floatWin.fullscreen = !floatWin.fullscreen
  }

  Timer {
    id: fullscreenLater
    interval: 250
    onTriggered: floatWin.fullscreen = true
  }

  function togglePin() {
    pinProc.command = [root.pluginDir + "/bin/srt-window", "toggle-pin"]
    pinProc.running = true
  }

  function toggleStats() { root.showStats = !root.showStats }

  Process {
    id: pinProc
    stdout: StdioCollector {
      onStreamFinished: {
        var v = String(text || "").trim()
        if (v === "true" || v === "false") root.pinned = v === "true"
      }
    }
  }

  // The runtime window rule floats and pins it; read back the real pin state
  // once Hyprland has mapped the window.
  Timer {
    id: pinQuery
    interval: 500
    onTriggered: {
      pinProc.command = [root.pluginDir + "/bin/srt-window", "pinned"]
      pinProc.running = true
    }
  }

  FloatingWindow {
    id: floatWin
    visible: root.poppedOut
    title: "SRT Replay"
    color: "black"
    implicitWidth: 960
    implicitHeight: 540
    minimumSize: Qt.size(320, 180)

    onVisibleChanged: {
      if (visible) pinQuery.restart()
      else if (root.poppedOut) root.poppedOut = false
    }

    PlayerView {
      id: floatingPlayer
      anchors.fill: parent
      service: root
      floating: true
      hostWindow: floatWin
      focus: true
    }
  }

  // ------------------------------------------------------------ clock + IPC
  Timer {
    interval: 1000
    repeat: true
    running: root.active || root.recording
    onTriggered: {
      root.now = Date.now()
      root.samplePacing()
    }
  }

  // Every function returns a string: qmllint aborts on IpcHandler functions
  // declared `: void`.
  IpcHandler {
    target: "srt-replay"

    function start(): string { root.start(); return "ok" }
    function stop(): string { root.stop(); return "ok" }
    function toggle(): string { root.toggleActive(); return "ok" }
    function record(): string { root.toggleRecord(); return "ok" }
    function play(): string { root.togglePlay(); return "ok" }
    function mute(): string { root.toggleMute(); return "ok" }
    function snapshot(): string { return root.snapshot() }
    function popout(): string { root.popOut(); return "ok" }
    function dock(): string { root.dock(); return "ok" }
    function fullscreen(): string { root.toggleFullscreen(); return "ok" }
    function stats(): string { root.toggleStats(); return "ok" }
    function meters(): string { root.toggleMeters(); return "ok" }
    function clip(seconds: int): string { return root.clip(seconds) }
    function hotkeys(): string {
      root.setHotkeysEnabled(!root.hotkeysEnabled)
      return root.hotkeysEnabled ? "on" : "off"
    }
    function controls(): string {
      root.keepControls = !root.keepControls
      return root.keepControls ? "always shown" : "auto-hide"
    }
    function status(): string {
      return JSON.stringify({
        status: root.status, text: root.statusText, endpoint: root.endpoint,
        recording: root.recording, file: root.recording ? root.recordFile : "",
        video: [root.videoCodec, root.resolution, root.fps ? root.fps + " fps" : ""].join(" ").trim(),
        mbps: Math.round(root.mbps * 100) / 100, rttMs: root.rttMs, lost: root.lostTotal,
        decodeFps: root.decodeFps, renderFps: root.renderFps, hitches: root.hitches,
        replaySeconds: root.replaySeconds, lastClip: root.lastClip,
        hotkeys: !root.hotkeysEnabled ? "off" : root.hotkeysFailed ? "failed"
          : root.hotkeysBound ? "active" : "ready",
        output: root.activeOutput ? (root.poppedOut ? "floating" : "docked") : "none"
      })
    }
  }

  Component.onDestruction: {
    if (recorder.running) recorder.write("q\n")
    if (meter.running) meter.signal(9)
    if (replay.running) replay.signal(9)
    Quickshell.execDetached(["rm", "-rf", root.runtimeDir])
    if (root._hotkeysMaybeBound) Quickshell.execDetached(["hyprctl", "eval", root.hotkeyLua(false)])
    Quickshell.execDetached(["hyprctl", "eval", root.windowRuleRemoveLua])
    if (ingest.running) ingest.signal(9)
    if (fanout.running) fanout.signal(9)
  }
}
