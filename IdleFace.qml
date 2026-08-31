import QtQuick
import QtQuick.Effects
import qs.Commons

// The lock screen's resting state: large clock, date, and current weather,
// shown until the first keypress hands over to the password field.
//
// Weather and date come from the lock service as plain properties; an empty
// temperature simply means no weather row, and the clock stands on its own.
Item {
  id: root

  property string weatherIcon: ""
  property string temperature: ""
  property string locationName: ""
  property bool showDate: true
  property int batteryPercent: -1
  property string batteryState: ""
  property string networkName: ""
  property string networkType: ""
  property bool showHint: true

  readonly property bool charging: batteryState === "Charging" || batteryState === "Full"

  function batteryIcon() {
    if (batteryPercent < 0) return ""
    if (charging) return "\uf0e7"
    if (batteryPercent >= 90) return "\uf240"
    if (batteryPercent >= 65) return "\uf241"
    if (batteryPercent >= 40) return "\uf242"
    if (batteryPercent >= 15) return "\uf243"
    return "\uf244"
  }

  function networkIcon() {
    if (networkName.length === 0) return "\uf127"
    return networkType === "wifi" ? "\uf1eb" : "\uf6ff"
  }
  readonly property bool weatherReady: temperature.length > 0

  Column {
    id: face
    anchors.centerIn: parent
    spacing: 16
    layer.enabled: true
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: Qt.rgba(0, 0, 0, 0.65)
      shadowBlur: 0.7
      shadowVerticalOffset: 2
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: Qt.formatDateTime(tick.now, "HH:mm")
      color: Color.lock.text
      font.family: Style.font.family
      // Outsized on purpose: meant to read from across a room.
      font.pixelSize: Math.round(Style.font.heading * 4.5)
      font.letterSpacing: -2
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.showDate
      text: Qt.formatDateTime(tick.now, "dddd d MMMM")
      color: Color.lock.text
      opacity: 0.92
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.heading * 1.15)
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 22
      visible: root.batteryPercent >= 0 || root.networkName.length > 0
      topPadding: 4

      Row {
        spacing: 8
        visible: root.batteryPercent >= 0
        Text {
          text: root.batteryIcon()
          color: root.batteryPercent <= 15 && !root.charging
            ? Color.lock.textError : Color.lock.text
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.heading * 1.05)
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          text: root.batteryPercent + "%"
          color: Color.lock.text
          opacity: 0.92
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.heading * 1.05)
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Row {
        spacing: 8
        visible: root.networkName.length > 0
        Text {
          text: root.networkIcon()
          color: Color.lock.text
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.heading * 1.05)
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          text: root.networkName
          color: Color.lock.text
          opacity: 0.92
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.heading * 1.05)
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 10
      visible: root.weatherReady

      Text {
        text: root.weatherIcon
        color: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.heading * 1.25)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: root.temperature + (root.locationName.length > 0 ? "  ·  " + root.locationName : "")
        color: Color.lock.text
        opacity: 0.92
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.heading * 1.15)
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 90
    visible: root.showHint
    text: "Press any key to unlock"
    color: Color.lock.placeholder
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    SequentialAnimation on opacity {
      loops: Animation.Infinite
      NumberAnimation { to: 0.25; duration: 1800; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 0.6; duration: 1800; easing.type: Easing.InOutQuad }
    }
  }

  QtObject {
    id: tick
    property date now: new Date()
  }

  Timer {
    interval: 1000
    running: root.visible
    repeat: true
    onTriggered: tick.now = new Date()
  }

}
