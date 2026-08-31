import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool fingerprintArmed: false
  property bool fingerprintScanning: false
  property string fingerprintMessage: ""
  property bool fingerprintRejected: false
  // Until the user touches anything, the lock shows the idle face rather
  // than a password box demanding input.
  property bool showIdleFace: true
  property string weatherIcon: ""
  property string weatherTemperature: ""
  property string weatherLocation: ""
  property bool showDate: true
  property int batteryPercent: -1
  property string batteryState: ""
  property string networkName: ""
  property string networkType: ""
  property bool showHint: true
  // 0-128, from the settings panel; 0 leaves the wallpaper sharp.
  property int backgroundBlur: 64
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false

  readonly property string placeholderText: "Enter Password"
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, root.outlineThickness, "border-alpha")

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()
  // Emitted only on deliberate input (key or click), never on pointer
  // motion, so the fingerprint reader is armed on intent rather than drift.
  signal userInputReceived()
  // Escape backs out of the password field to the idle face.
  signal dismissRequested()

  // Cache-busts the lock background by appending `?v=`. Adding a query
  // string keeps Image's loader happy while forcing it to reload when the
  // user picks a new background mid-session.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + backgroundVersion
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.loadBackground ? root.fileUrl(root.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && wallpaper.status === Image.Ready && root.backgroundBlur > 0
      // Ramps from sharp to the configured radius as the idle face gives way,
      // so the clock stays legible and the password field gets the focus.
      blur: root.showIdleFace ? 0.0 : 1.0
      Behavior on blur { NumberAnimation { duration: 320; easing.type: Easing.OutQuad } }
      blurMax: root.backgroundBlur
      blurMultiplier: 1.25
      contrast: -0.08
    }

    Rectangle {
      anchors.fill: parent
      visible: opacity > 0
      opacity: root.showIdleFace ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.30) }
        GradientStop { position: 0.42; color: Qt.rgba(0, 0, 0, 0.62) }
        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.34) }
      }
    }

    IdleFace {
      anchors.fill: parent
      weatherIcon: root.weatherIcon
      temperature: root.weatherTemperature
      locationName: root.weatherLocation
      showDate: root.showDate
      batteryPercent: root.batteryPercent
      batteryState: root.batteryState
      networkName: root.networkName
      networkType: root.networkType
      showHint: root.showHint
      visible: opacity > 0
      opacity: root.showIdleFace ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.userInputReceived(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    BorderSurface {
      id: inputField
      width: root.fieldWidth
      height: root.fieldHeight
      anchors.centerIn: parent
      visible: opacity > 0
      opacity: root.showIdleFace ? 0 : 1
      Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }
      color: Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "\u25CF"
        passwordMaskDelay: 0
        color: Color.lock.text
        selectionColor: Color.lock.selection
        selectedTextColor: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          root.passwordTextEdited("")
          if (submitted.length > 0) root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()

          if (event.key === Qt.Key_Escape) {
            // With text typed, Escape clears it; on an empty field it returns
            // to the idle face rather than sitting on a blank prompt.
            if (passwordInput.text.length > 0) root.passwordTextEdited("")
            else root.dismissRequested()
            event.accepted = true
            return
          }

          if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U) {
            root.passwordTextEdited("")
            event.accepted = true
            return
          }

          // Escape must not count as intent, or backing out would immediately
          // re-arm the reader it just dismissed.
          root.userInputReceived()
        }
      }

      Text {
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? "Checking…"
            : (root.failureMessage.length > 0 ? root.failureMessage
            : (root.fingerprintMessage.length > 0 ? root.fingerprintMessage : root.placeholderText))
        visible: passwordInput.text.length === 0
        color: root.authenticatingPassword ? Color.lock.text
            : ((root.failureMessage.length > 0 || root.fingerprintRejected) ? Color.lock.textError
            : Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      // Matches hyprlock, which draws its fingerprint icon in the same spot.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        // Dimmed until a keypress arms the reader, and red on a rejected
        // touch, so the icon reflects whether a scan will be read.
        color: root.fingerprintRejected ? Color.lock.textError : Color.lock.placeholder
        opacity: root.fingerprintArmed ? 1.0 : 0.4
        Behavior on opacity { NumberAnimation { duration: 150 } }
        Behavior on color { ColorAnimation { duration: 120 } }

        // Breathing while a scan is in flight, so a touch visibly registers.
        SequentialAnimation on scale {
          running: root.fingerprintScanning && !root.fingerprintRejected
          loops: Animation.Infinite
          onStopped: fingerprintIcon.scale = 1
          NumberAnimation { to: 1.18; duration: 700; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
        }
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
