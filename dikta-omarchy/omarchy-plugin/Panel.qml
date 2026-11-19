import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

Panel {
  id: root
  moduleName: "dikta.panel"
  ipcTarget: "dikta.panel"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property string uid: ""
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  readonly property string stateDir: runtimeDir && uid ? runtimeDir + "/dikta-" + uid : ""
  readonly property string statePath: stateDir ? stateDir + "/panel.json" : ""
  property var state: null
  property int cursor: 0
  property bool cursorActive: false
  property string deferredAction: ""

  function fileUrl(path) {
    return path ? "file://" + path.split("/").map(encodeURIComponent).join("/") : ""
  }

  function readState(raw) {
    try {
      if (!raw || raw.length > 1048576) throw new Error("Invalid state size")
      var data = JSON.parse(raw)
      if (!data || typeof data.status !== "string" || typeof data.recording !== "boolean"
          || typeof data.busy !== "boolean" || typeof data.notifications !== "boolean"
          || typeof data.hotkey !== "string" || !Array.isArray(data.history))
        throw new Error("Invalid state")
      root.state = data
    } catch (e) {
      root.state = null
    }
  }

  function preview(value) {
    return typeof value === "string" ? value.replace(/\s+/g, " ").slice(0, 120) : ""
  }

  readonly property var actions: {
    if (!state) return [{ label: strings.t("startApp"), action: "start" }]
    var result = []
    for (var i = 0; i < Math.min(5, state.history.length); ++i) {
      if (typeof state.history[i] === "string")
        result.push({ label: preview(state.history[i]), action: "copy:" + i, history: true })
    }
    result.push({ label: state.hotkey ? strings.t("hotkey").arg(preview(state.hotkey)) : strings.t("hotkeyUnknown"), action: "hotkey" })
    result.push({ label: state.notifications ? strings.t("notificationsOn") : strings.t("notificationsOff"), action: "notifications" })
    result.push({ label: strings.t("open"), action: "show" })
    result.push({ label: strings.t("quit"), action: "quit" })
    return result
  }

  function runAction(entry) {
    if (!entry || entry.enabled === false) return
    if (entry.action === "show" || entry.action === "hotkey" || entry.action === "start") {
      // Let the keyboard panel release focus before opening another window.
      root.close()
      deferredAction = entry.action
      actionDelay.restart()
    } else {
      Quickshell.execDetached(["dikta", "--panel-action", entry.action])
      if (entry.action === "quit") root.close()
    }
  }

  function moveCursor(delta) {
    if (!actions.length) return
    cursorActive = true
    cursor = Math.max(0, Math.min(actions.length - 1, cursor + delta))
    if (panel.loadedContent) panel.loadedContent.revealCursor()
  }

  onOpenedChanged: {
    if (opened) {
      cursor = 0
      cursorActive = false
      if (statePath) stateFile.reload()
    }
  }
  onActionsChanged: cursor = Math.min(cursor, Math.max(0, actions.length - 1))

  Timer {
    id: actionDelay
    interval: 250
    repeat: false
    onTriggered: {
      var action = root.deferredAction
      root.deferredAction = ""
      if (action === "start") Quickshell.execDetached(["dikta"])
      else if (action) Quickshell.execDetached(["dikta", "--panel-action", action])
    }
  }

  Process {
    command: ["id", "-u"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = text.trim()
        if (/^[0-9]+$/.test(value)) root.uid = value
      }
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readState(text())
    onLoadFailed: root.state = null
  }

  // FileView watches replacements in the state directory. These directory
  // watches also recover when Dikta creates its directory after the shell starts.
  FolderListModel {
    folder: root.fileUrl(root.runtimeDir)
    showDirs: true
    showFiles: false
    showDotAndDotDot: false
    onCountChanged: if (root.statePath) stateFile.reload()
  }
  FolderListModel {
    folder: root.fileUrl(root.stateDir)
    showDirs: false
    showFiles: true
    nameFilters: ["panel.json"]
    onCountChanged: if (root.statePath) stateFile.reload()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.state && root.state.busy ? "󰔟" : "󰍬"
    active: !!root.state && (root.state.recording || root.state.busy)
    dimmed: !root.state
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(350))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: Math.min(column.implicitHeight, Style.space(440))
      onMoveRequested: function(dx, dy) { root.moveCursor(dy || dx) }
      onActivateRequested: root.runAction(root.actions[root.cursor])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      function revealCursor() {
        var item = repeater.itemAt(root.cursor)
        if (!item) return
        var top = column.y + item.y + rows.y
        if (top < scroller.contentY) scroller.contentY = top
        else if (top + item.height > scroller.contentY + scroller.height)
          scroller.contentY = Math.min(scroller.contentHeight - scroller.height, top + item.height - scroller.height)
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: column.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(14)
            Text {
              textFormat: Text.PlainText
              text: "󰍬"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.verticalCenter: parent.verticalCenter
            }
            Column {
              width: parent.width - parent.children[0].implicitWidth - parent.spacing
              spacing: Style.space(2)
              Text {
                textFormat: Text.PlainText
                text: "Dikta"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.state ? root.preview(root.state.status) : strings.t("unavailable")
                color: root.bar.foreground
                opacity: 0.65
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Text {
            visible: !!root.state
            textFormat: Text.PlainText
            text: strings.t("history")
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            visible: !!root.state && root.state.history.length === 0
            textFormat: Text.PlainText
            text: strings.t("empty")
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            id: rows
            width: parent.width
            spacing: Style.space(3)
            Repeater {
              id: repeater
              model: root.actions
              delegate: Item {
                required property var modelData
                required property int index
                width: rows.width
                height: rowButton.implicitHeight
                Button {
                  id: rowButton
                  y: 0
                  width: parent.width
                  text: modelData.label
                  iconText: modelData.history ? "󰆏" : ""
                  leftAlign: true
                  bordered: !modelData.history
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  enabled: modelData.enabled !== false
                  opacity: enabled ? 1 : 0.5
                  hasCursor: root.cursorActive && root.cursor === index
                  onClicked: root.runAction(modelData)
                  onHovered: function(h) { if (h) { root.cursorActive = true; root.cursor = index } }
                }
              }
            }
          }
        }
      }
    }
  }
}
