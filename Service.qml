import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  // The reader only arms once the user has actually touched the lock screen.
  // Arming automatically at lock time starts a verify ~1s before suspend; the
  // lid-close kills it mid-flight, ReleaseDevice fails, and the single-client
  // match-on-chip sensor stays claimed so every later attempt returns code 9.
  property bool fingerprintArmed: false
  // The idle face gives way on the first deliberate input, the same
  // gesture that arms the reader.
  property bool idleFaceVisible: true
  // The keypress that wakes the machine should not also dismiss the idle face:
  // the user has not seen it yet. Input is ignored for a moment after a resume
  // so the clock is actually shown before the password field takes over.
  property double resumeGuardUntil: 0
  readonly property int resumeGraceMs: 900
  // Settings owned by the zeroge.lockface panel. Defaults here match its
  // Config.js, so the lock behaves sanely before the file exists.
  property bool cfgFingerprintEnabled: true
  property bool cfgFaceEnabled: false
  property bool faceConfigured: false
  property bool faceAuthenticating: false
  property bool cfgArmOnInput: true
  property string weatherIcon: ""
  property string weatherTemperature: ""
  property string weatherLocation: ""
  property int batteryPercent: -1
  property string batteryState: ""
  property string networkName: ""
  property string networkType: ""
  property string lockBackground: ""
  property string sessionBackgroundPath: ""
  // Output that should carry the lock interface, captured when locking starts.
  property string lockScreenName: ""

  // The probe can name a screen that disappears moments later (a lid close
  // locks before the output is dropped), so resolve it against what is live.
  property string lockScreenFallback: ""

  function screenExists(name) {
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++)
      if (screens[i] && screens[i].name === name) return true
    return false
  }

  readonly property string activeLockScreen: {
    var screens = Quickshell.screens || []
    if (screens.length === 0) return ""
    if (lockScreenName.length > 0 && screenExists(lockScreenName)) return lockScreenName
    // The internal panel is gone (lid shut, or docked): use the screen that
    // had focus rather than an arbitrary array position.
    if (lockScreenFallback.length > 0 && screenExists(lockScreenFallback)) return lockScreenFallback
    return screens[0].name
  }
  property int lockBlur: 64
  property bool cfgShowWeather: true
  property bool cfgShowDate: true
  property bool cfgShowBattery: true
  property bool cfgShowNetwork: true
  property bool cfgShowHint: true
  property string cfgLockDisplay: "internal"
  property string cfgLockFallback: "focused"
  // Latest prompt from pam_fprintd ("Place your finger…", "Failed to
  // match"), surfaced so a touch is not silently ignored.
  property string fingerprintMessage: ""
  property bool fingerprintRejected: false
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early is an orphan behind Hyprland's failsafe. Outputs
  // are often still absent here, so ask until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (locked || lockRequested) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    fingerprintArmed = false
    faceAuthenticating = false
    if (facePam.active) facePam.abort()
    idleFaceVisible = true
    fingerprintMessage = ""
    fingerprintRejected = false
    fingerprintRejectTimer.stop()
    failureClearTimer.stop()
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintRetryTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
  }

  // Remember which output was focused, so the interface lands there rather
  // than on whichever screen happens to be first.
  function captureLockScreen() {
    if (!focusedScreenProc.running) focusedScreenProc.running = true
  }

  function beginLock() {
    captureLockScreen()
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
    })

    return true
  }

  function finishUnlock() {
    if (!root.locked && !lockRequested) return

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  // An explicit background from the settings panel wins; otherwise the lock
  // follows whatever the session is showing.
  function applyBackground() {
    var next = lockBackground.length > 0 ? lockBackground : sessionBackgroundPath
    if (next === backgroundPath) return
    backgroundPath = next
    backgroundVersion += 1
  }

  onLockBackgroundChanged: applyBackground()

  function runWake() {
    if (!wakeProcess.running) wakeProcess.running = true
    if (lockRequested) armBlankTimer()
  }

  function runBlank() {
    if (!blankProcess.running) blankProcess.running = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    failureClearTimer.restart()
    runWake()
  }

  // Return to the idle face and stand the readers down, so a dismissed
  // unlock does not leave a scan running against nobody.
  function dismissToIdle() {
    if (idleFaceVisible) return
    idleFaceVisible = true
    fingerprintArmed = false
    fingerprintMessage = ""
    fingerprintRejected = false
    fingerprintRetryTimer.stop()
    enteredPassword = ""
    failureMessage = ""
    if (fingerprintPam.active) fingerprintPam.abort()
    if (facePam.active) facePam.abort()
    fingerprintAuthenticating = false
    faceAuthenticating = false
    logEvent("dismissed-to-idle")
  }

  function armFingerprint() {
    // Swallow the wake keystroke, and let the next one through.
    if (Date.now() < resumeGuardUntil) {
      resumeGuardUntil = 0
      return
    }
    idleFaceVisible = false
    if (fingerprintArmed) return
    fingerprintArmed = true
    startFingerprint()
    startFace()
  }

  function startFace() {
    if (!lockRequested || !sessionLock.secure) return
    if (!cfgFaceEnabled || !faceConfigured) return
    if (facePam.active || faceAuthenticating) return

    faceAuthenticating = true
    if (!facePam.start()) faceAuthenticating = false
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured) return
    if (!cfgFingerprintEnabled) return
    if (!fingerprintArmed) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    if (!fingerprintPam.start()) {
      fingerprintAuthenticating = false
    }
  }

  function handleFingerprintFinished(result) {
    fingerprintAuthenticating = false

    if (!lockRequested) return
    if (result === PamResult.Success) {
      finishUnlock()
    } else if (fingerprintConfigured) {
      fingerprintRetryTimer.restart()
    }
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        resumeWatch.lastTick = Date.now()
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        if (!root.cfgArmOnInput) root.armFingerprint()
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      color: Color.background

      // Which output carries the interface. Preferring the focused screen at
      // lock time puts it where the user was already looking; the first screen
      // is the fallback when that is unknown.
      readonly property bool primary:
        root.cfgLockDisplay === "all" ? true
          : (screen && screen.name === root.activeLockScreen)

      LockView {
        id: lockView
        anchors.fill: parent
        // Secondary outputs show the background only: no clock, no password
        // field, nothing to type into by accident.
        showInterface: lockSurface.primary
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        fingerprintArmed: root.fingerprintArmed
        showIdleFace: root.idleFaceVisible
        weatherIcon: root.cfgShowWeather ? root.weatherIcon : ""
        weatherTemperature: root.cfgShowWeather ? root.weatherTemperature : ""
        weatherLocation: root.cfgShowWeather ? root.weatherLocation : ""
        showDate: root.cfgShowDate
        batteryPercent: root.cfgShowBattery ? root.batteryPercent : -1
        batteryState: root.batteryState
        networkName: root.cfgShowNetwork ? root.networkName : ""
        networkType: root.networkType
        showHint: root.cfgShowHint
        backgroundBlur: root.lockBlur
        fingerprintScanning: root.fingerprintAuthenticating
        faceScanning: root.faceAuthenticating
        fingerprintMessage: root.fingerprintMessage
        fingerprintRejected: root.fingerprintRejected
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        passwordText: root.enteredPassword
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
        onUserInputReceived: root.armFingerprint()
        onDismissRequested: root.dismissToIdle()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      passwordText: ""
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onPamMessage: {
      if (!root.lockRequested || !root.fingerprintArmed) return
      var text = String(fingerprintPam.message || "").trim()
      if (text.length === 0) return
      root.fingerprintMessage = text
      fingerprintMessageTimer.restart()
      if (fingerprintPam.messageIsError) {
        root.fingerprintRejected = true
        fingerprintRejectTimer.restart()
      }
    }

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.fingerprintAuthenticating = false
      if (root.lockRequested && root.fingerprintConfigured) fingerprintRetryTimer.restart()
    }
  }

  PamContext {
    id: facePam
    config: "omarchy-lock-face"
    user: root.userName

    onPamMessage: {
      if (!root.lockRequested || !root.fingerprintArmed) return
      var t = String(facePam.message || "").trim()
      if (t.length > 0) root.fingerprintMessage = t
    }

    onCompleted: function(result) {
      root.faceAuthenticating = false
      if (!root.lockRequested) return
      if (result === PamResult.Success) { root.finishUnlock(); return }
      // Distinguish "the camera saw nothing" from an ordinary non-match.
      if (!faceDarkProbe.running) faceDarkProbe.running = true
      // No retry loop: howdy holds the camera for its own timeout, and
      // re-running it in a loop would pin the device the way the fingerprint
      // retries once did.
    }

    onError: function(error) {
      root.faceAuthenticating = false
    }
  }

  // Exit 2 from the check client means every frame was essentially black.
  // A covered lens and an unlit room are indistinguishable here, so the
  // message offers the shutter as a possibility rather than a diagnosis.
  Process {
    id: faceDarkProbe
    command: ["bash", "-c",
      "test -x /usr/local/bin/omarchy-lock-face-check || exit 1; " +
      "/usr/local/bin/omarchy-lock-face-check; echo $?"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.lockRequested || !root.fingerprintArmed) return
        if (String(text || "").trim() === "2") {
          root.fingerprintMessage = "Camera sees nothing — is it covered?"
          root.fingerprintRejected = true
          fingerprintRejectTimer.restart()
        }
      }
    }
  }

  FileView {
    id: facePamCheck
    path: "/etc/pam.d/omarchy-lock-face"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.faceConfigured = true
    onLoadFailed: root.faceConfigured = false
  }

  // Watches wall-clock time to notice a suspend: on resume the lock returns to
  // the idle face, so the user sees the clock rather than whatever state the
  // screen was left in before it slept.
  Connections {
    target: Quickshell
    function onScreensChanged() {
      if (root.lockRequested) screenSettleTimer.restart()
    }
  }

  // Outputs arrive and vanish in bursts on a lid close or a resume; settle
  // first, then ask once.
  Timer {
    id: screenSettleTimer
    interval: 600
    repeat: false
    onTriggered: if (root.lockRequested) root.captureLockScreen()
  }

  Timer {
    id: resumeWatch
    interval: 2000
    repeat: true
    running: root.lockRequested
    property double lastTick: Date.now()
    onTriggered: {
      var now = Date.now()
      var gap = now - lastTick
      lastTick = now
      // A gap well past the interval means time passed without ticks.
      if (gap > interval + 4000 && root.lockRequested) {
        root.logEvent("resumed after " + Math.round(gap / 1000) + "s")
        root.resumeGuardUntil = now + root.resumeGraceMs
        root.dismissToIdle()
      }
    }
  }

  Timer {
    id: failureClearTimer
    interval: 4000
    repeat: false
    onTriggered: root.failureMessage = ""
  }

  Timer {
    id: fingerprintRejectTimer
    interval: 1200
    repeat: false
    onTriggered: root.fingerprintRejected = false
  }

  // Clear a scanner message once it has been read, so the toast does not sit
  // there after the reader has moved on.
  Timer {
    id: fingerprintMessageTimer
    interval: 3500
    repeat: false
    onTriggered: root.fingerprintMessage = ""
  }

  Timer {
    id: fingerprintRetryTimer
    interval: 250
    repeat: false
    onTriggered: root.startFingerprint()
  }

  Process {
    id: focusedScreenProc
    // The laptop panel is where the user physically is, and where the
    // fingerprint reader and IR camera are. Prefer it whenever the lid is open
    // (a closed lid disables the output, so it simply will not be listed);
    // otherwise fall back to the focused screen, then to any screen at all.
    command: ["bash", "-c",
      "m=$(hyprctl -j monitors 2>/dev/null); " +
      "want=\"" + root.cfgLockDisplay + "\"; " +
      "n=''; " +
      "[ \"$want\" = internal ] && n=$(printf '%s' \"$m\" | jq -r '[.[] | select(.name | test(\"^(eDP|LVDS|DSI)\"; \"i\"))][0].name // empty'); " +
      "fb=\"" + root.cfgLockFallback + "\"; " +
      "[ -z \"$n\" ] && [ \"$fb\" != focused ] && n=$(printf '%s' \"$m\" | jq -r --arg d \"$fb\" '[.[] | select((.description // .name) == $d)][0].name // empty'); " +
      "[ -z \"$n\" ] && n=$(printf '%s' \"$m\" | jq -r '[.[] | select(.focused)][0].name // empty'); " +
      "f=$(printf '%s' \"$m\" | jq -r '[.[] | select(.focused)][0].name // empty'); " +
      "[ -z \"$n\" ] && n=$f; " +
      "[ -z \"$n\" ] && n=$(printf '%s' \"$m\" | jq -r '.[0].name // empty'); " +
      "printf '%s;%s' \"$n\" \"$f\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text || "").trim().split(";")
        if (parts[0] && parts[0].length > 0) root.lockScreenName = parts[0]
        if (parts[1] && parts[1].length > 0) root.lockScreenFallback = parts[1]
      }
    }
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.sessionBackgroundPath = String(text || "").trim()
        root.applyBackground()
      }
    }
  }

  // wttr.in resolves location by IP, matching the stock weather widget when
  // none is configured. Failures stay silent: a lock screen that cannot reach
  // the network should still show its clock.
  Process {
    id: statusProc
    command: ["bash", "-c",
      'bat=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1); ' +
      'cap=""; st=""; ' +
      'if [[ -n $bat ]]; then cap=$(cat "$bat/capacity" 2>/dev/null); st=$(cat "$bat/status" 2>/dev/null); fi; ' +
      'net=$(nmcli -t -f TYPE,STATE,CONNECTION device status 2>/dev/null | ' +
      '  awk -F: \'$2=="connected" && $1!="loopback" {print $1"|"$3; exit}\'); ' +
      'printf \'%s;%s;%s\\n\' "$cap" "$st" "$net"']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text || "").trim().split(";")
        var cap = parseInt(parts[0])
        root.batteryPercent = isNaN(cap) ? -1 : cap
        root.batteryState = String(parts[1] || "")
        var net = String(parts[2] || "").split("|")
        root.networkType = String(net[0] || "")
        root.networkName = String(net[1] || "")
      }
    }
  }

  Timer {
    interval: 30000
    running: root.cfgShowBattery || root.cfgShowNetwork
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }

  Process {
    id: weatherProc
    command: ["bash", "-lc",
      'curl -fsS --max-time 8 "https://wttr.in/?format=j1" | jq -c \'' +
      '.current_condition[0] as $c | .nearest_area[0] as $a | ($c.weatherCode|tonumber) as $w | ' +
      '(if $w==113 then (if $c.isdaytime=="yes" then "" else "" end) ' +
      ' elif $w==116 or $w==119 then "" ' +
      ' elif $w>=176 and $w<=202 then "" ' +
      ' elif $w>=203 and $w<=230 then "" ' +
      ' elif $w>=293 and $w<=314 then "" ' +
      ' elif $w>=317 and $w<=350 then "" ' +
      ' elif $w>=353 and $w<=365 then "" ' +
      ' elif $w>=368 and $w<=395 then "" ' +
      ' else "" end) as $icon | ' +
      '{icon:$icon, temperature:($c.temp_C+"°C"), location:($a.areaName[0].value)}\'']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "").trim())
          root.weatherIcon = String(d.icon || "")
          root.weatherTemperature = String(d.temperature || "")
          root.weatherLocation = String(d.location || "")
        } catch (e) {
          // Keep the last good reading rather than blanking the row.
        }
      }
    }
  }

  Timer {
    interval: 15 * 60 * 1000
    running: root.cfgShowWeather
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!weatherProc.running) weatherProc.running = true
  }

  FileView {
    id: lockfaceSettings
    path: Quickshell.env("HOME") + "/.config/omarchy/lockface.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (typeof d.fingerprintEnabled === "boolean") root.cfgFingerprintEnabled = d.fingerprintEnabled
        if (typeof d.faceEnabled === "boolean") root.cfgFaceEnabled = d.faceEnabled
        if (typeof d.armOnInput === "boolean") root.cfgArmOnInput = d.armOnInput
        if (typeof d.showWeather === "boolean") root.cfgShowWeather = d.showWeather
        if (typeof d.showDate === "boolean") root.cfgShowDate = d.showDate
        if (typeof d.showBattery === "boolean") root.cfgShowBattery = d.showBattery
        if (typeof d.showNetwork === "boolean") root.cfgShowNetwork = d.showNetwork
        if (typeof d.showHint === "boolean") root.cfgShowHint = d.showHint
        if (d.lockDisplay === "internal" || d.lockDisplay === "focused"
            || d.lockDisplay === "all")
          root.cfgLockDisplay = d.lockDisplay
        if (typeof d.lockFallback === "string") root.cfgLockFallback = d.lockFallback
        if (typeof d.background === "string") root.lockBackground = d.background
        var b = parseInt(d.blur)
        if (!isNaN(b)) root.lockBlur = Math.max(0, Math.min(128, b))
      } catch (e) {
        // Keep the defaults rather than half-applying a broken file.
      }
    }
  }

  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1 && fprintd-list \"$USER\" 2>/dev/null | grep -qi finger; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: {
      root.fingerprintConfigured = String(fingerprintCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.fingerprintConfigured) root.startFingerprint()
      else if (!root.fingerprintConfigured && fingerprintPam.active) fingerprintPam.abort()
    }
  }

  Process {
    id: strandedLockCheckProc
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  Timer {
    id: idleBlankTimer
    // 30s rather than the stock 5s: the idle face (clock and weather) needs to
    // stay readable, and slower monitors do not finish waking inside 5s.
    interval: 30000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    refreshBackground()
    refreshFingerprintStatus()
    checkStrandedLock()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }
}
