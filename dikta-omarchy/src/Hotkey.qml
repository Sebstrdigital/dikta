import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: window
    width: 480
    height: 280
    minimumWidth: 380
    minimumHeight: 240
    visible: false
    title: qsTr("Global shortcut")
    color: "#111113"
    Material.theme: Material.Dark
    Material.accent: theme.accent

    onVisibleChanged: if (visible) capture.forceActiveFocus()

    Item {
        id: capture
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
            event.accepted = true
            if (event.isAutoRepeat)
                return
            if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier) {
                window.close()
                return
            }
            if (event.key === Qt.Key_Control || event.key === Qt.Key_Alt
                    || event.key === Qt.Key_Shift || event.key === Qt.Key_Meta
                    || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R)
                return
            if (hotkey.setShortcut(event.key, event.modifiers))
                window.close()
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 16

            Label {
                text: qsTr("Global shortcut")
                font.pixelSize: 24
                font.bold: true
            }
            Label {
                Layout.fillWidth: true
                text: hotkey.current.length ? qsTr("Current: %1").arg(hotkey.current)
                                            : qsTr("No shortcut configured")
                wrapMode: Text.Wrap
            }
            Label {
                Layout.fillWidth: true
                text: qsTr("Press a key with Ctrl, Alt, Shift, or Super. Press Escape to cancel.")
                color: "#c4c4c8"
                wrapMode: Text.Wrap
            }
            Label {
                Layout.fillWidth: true
                visible: hotkey.error.length > 0
                text: hotkey.error
                color: "#ff9999"
                wrapMode: Text.Wrap
            }
            Item { Layout.fillHeight: true }
            Button {
                text: qsTr("Cancel")
                Layout.alignment: Qt.AlignRight
                onClicked: window.close()
            }
        }
    }
}
