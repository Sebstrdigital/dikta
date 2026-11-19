import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: window
    width: 620
    height: 640
    minimumWidth: 420
    minimumHeight: 420
    visible: false
    title: qsTr("Dikta")
    color: "#111113"
    Material.theme: Material.Dark
    Material.accent: theme.accent

    Shortcut {
        sequence: "Space"
        context: Qt.WindowShortcut
        onActivated: if (!backend.busy) backend.toggle()
    }
    Shortcut {
        sequence: "Ctrl+Q"
        context: Qt.WindowShortcut
        onActivated: Qt.quit()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 28
        spacing: 18

        Label {
            text: qsTr("Dikta")
            font.pixelSize: 30
            font.bold: true
        }
        Label {
            Layout.fillWidth: true
            text: backend.status
            wrapMode: Text.Wrap
            color: backend.recording ? theme.accent : "#c4c4c8"
            font.pixelSize: 15
        }
        Button {
            Layout.fillWidth: true
            text: backend.recording ? qsTr("Stop recording") : qsTr("Start recording")
            enabled: !backend.busy
            highlighted: true
            onClicked: backend.toggle()
        }
        Label {
            text: qsTr("Recent dictations")
            font.pixelSize: 19
            font.bold: true
            topPadding: 12
        }
        Label {
            visible: backend.history.length === 0
            text: qsTr("Your recent dictations will appear here.")
            color: "#a4a4aa"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        ListView {
            id: historyList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            model: backend.history.slice(0, 5)
            ScrollBar.vertical: ScrollBar { }
            delegate: Rectangle {
                required property int index
                required property string modelData
                width: historyList.width
                height: row.implicitHeight + 24
                color: "#202023"
                radius: 4
                RowLayout {
                    id: row
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 12
                    Label {
                        Layout.fillWidth: true
                        text: modelData
                        wrapMode: Text.Wrap
                        maximumLineCount: 4
                        elide: Text.ElideRight
                    }
                    Button {
                        text: qsTr("Copy")
                        Accessible.name: qsTr("Copy dictation")
                        onClicked: backend.copyHistory(index)
                    }
                }
            }
        }
        Label {
            Layout.fillWidth: true
            text: qsTr("In your target app, press %1 to start and stop. Ctrl+Q: quit").arg(hotkey.current)
            color: "#8f8f96"
            wrapMode: Text.Wrap
        }
    }
}
