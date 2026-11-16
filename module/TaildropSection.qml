import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell
import qs.api
import qs.components

// The page's "Taildrop" (step 4). Taildrop needs this user to be Tailscale's operator (the
// LocalAPI's write access; nothing of it runs through pkexec): not the operator, the section
// says so and offers becoming it. The operator sends files (the file chooser, pasted absolute
// paths, or dropped here — the last two work without the dialog) to a device that can receive,
// with per-file progress, Cancel and results; and saves received files into a folder. Anyone
// sees that files arrived. Everything it does is TaildropClient's.
ColumnLayout {
    id: root

    property var client: null
    // Kept for the page's interface: Taildrop never asks for a password
    property string need: ""

    readonly property var taildrop: client?.taildrop ?? null
    readonly property bool _connected: client?.view?.phase === "running"
    readonly property bool _operator: taildrop?.isOperator ?? false
    readonly property bool _free: client !== null && !client.busy
    readonly property var _send: taildrop?.send ?? ({ state: "", files: [], message: "" })

    visible: taildrop !== null && client.cli === "present"
    Layout.fillWidth: true
    spacing: 4

    component Line: Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.textSecondary
    }

    SectionTitle {
        text: "Taildrop"
    }
    Line {
        visible: !root._connected
        text: "Works while connected"
        color: Api.theme.textMuted
    }

    // ── Not the operator: one line, one button ──
    Line {
        objectName: "taildropNeedsOperator"
        visible: !root._operator
        text: "Sending and saving files needs the operator"
        color: Api.theme.textMuted
    }
    RowLayout {
        visible: !root._operator
        spacing: 8
        PrivilegedMark {
            need: "auth"
        }
        SmallButton {
            objectName: "taildropBecomeOperator"
            label: "Let this user manage Tailscale without a password"
            available: root._free && (root.client?.userName ?? "") !== ""
            onClicked: root.client.becomeOperator()
        }
    }

    // ── Send ──
    Line {
        visible: root._connected && root._operator && (root.taildrop?.targets.length ?? 0) === 0
        text: "No device can receive files"
        color: Api.theme.textMuted
    }
    Flow {
        objectName: "taildropTargets"
        visible: root._connected && root._operator && (root.taildrop?.targets.length ?? 0) > 0
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: ScriptModel {
                values: root.taildrop?.targets ?? []
                objectProp: "id"
            }
            Pill {
                required property var modelData
                objectName: "taildropTarget"
                label: modelData.name + (modelData.note !== "" ? " · " + modelData.note : "")
                picked: root.taildrop?.targetId === modelData.id
                enabled: modelData.available
                opacity: modelData.available ? 1 : 0.5
                onClicked: root.taildrop.targetId = modelData.id
            }
        }
    }

    // The files: the chooser, pasted paths, or dropped here
    DropArea {
        id: _drop
        visible: root._connected && root._operator
        Layout.fillWidth: true
        implicitHeight: _files.implicitHeight
        onDropped: drop => {
            if (drop.hasUrls) {
                root.taildrop.addPaths(drop.urls.map(url => String(url)));
                drop.acceptProposedAction();
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: Api.theme.row.radius
            color: _drop.containsDrag ? Api.theme.surface : "transparent"
            border.width: _drop.containsDrag ? Api.theme.border.width : 0
            border.color: Api.theme.accent
        }

        ColumnLayout {
            id: _files
            width: parent.width
            spacing: 4

            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                SmallButton {
                    objectName: "taildropChooseFiles"
                    label: "Choose files…"
                    onClicked: _fileDialog.open()
                }
                InputField {
                    id: _pathField
                    objectName: "taildropPathField"
                    Layout.fillWidth: true
                    placeholder: "Paste paths or drop files"
                    onAccepted: {
                        if (root.taildrop.addPaths(text) > 0)
                            text = "";
                    }
                }
                SmallButton {
                    label: "Add"
                    available: _pathField.text.trim() !== ""
                    onClicked: {
                        if (root.taildrop.addPaths(_pathField.text) > 0)
                            _pathField.text = "";
                    }
                }
            }
            Repeater {
                model: ScriptModel {
                    values: (root.taildrop?.inputProblems ?? []).map((item, index) => ({ key: index + "\n" + item.text + "\n" + item.problem, text: item.text, problem: item.problem }))
                    objectProp: "key"
                }
                Line {
                    required property var modelData
                    text: [modelData.text, modelData.problem].filter(part => part !== "").join(" · ")
                    color: Api.theme.warning
                }
            }
            Repeater {
                model: ScriptModel {
                    values: (root.taildrop?.chosen ?? []).map(path => ({ path: path }))
                    objectProp: "path"
                }
                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 6
                    Line {
                        objectName: "taildropChosen"
                        elide: Text.ElideMiddle
                        wrapMode: Text.NoWrap
                        text: modelData.path
                        color: Api.theme.textPrimary
                    }
                    SmallButton {
                        label: "×"
                        tooltip: "Remove"
                        available: !(root.taildrop?.sending ?? false)
                        onClicked: root.taildrop.removePath(modelData.path)
                    }
                }
            }
        }
    }
    RowLayout {
        visible: root._connected && root._operator
        spacing: 8
        SmallButton {
            objectName: "taildropSend"
            label: root.taildrop?.target ? "Send to " + root.taildrop.target.name : "Send"
            available: root.taildrop?.target?.available === true && (root.taildrop?.chosen.length ?? 0) > 0 && !(root.taildrop?.sending ?? false)
            onClicked: root.taildrop.sendFiles()
        }
        SmallButton {
            objectName: "taildropCancel"
            visible: root.taildrop?.sending ?? false
            label: "Cancel"
            onClicked: root.taildrop.cancelSend()
        }
        SmallButton {
            visible: !(root.taildrop?.sending ?? true) && root._send.state !== ""
            label: "Clear"
            onClicked: root.taildrop.dismissSend()
        }
    }
    Line {
        objectName: "taildropSendState"
        visible: text !== "" && root._operator
        text: {
            const send = root._send;
            const state = { checking: "Checking…", sending: "Sending to " + send.targetName + "…", done: "Sent to " + send.targetName }[send.state] ?? "";
            return [state, send.message].filter(part => part !== "").join(" · ");
        }
        color: root._send.state === "failed" ? Api.theme.warning : Api.theme.textSecondary
    }
    Repeater {
        model: ScriptModel {
            values: root._send.files ?? []
            objectProp: "path"
        }
        RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: 6
            Line {
                objectName: "taildropSendFile"
                elide: Text.ElideMiddle
                wrapMode: Text.NoWrap
                text: modelData.name
                color: Api.theme.textPrimary
            }
            Line {
                Layout.fillWidth: false
                wrapMode: Text.NoWrap
                text: modelData.problem !== "" ? modelData.problem
                    : modelData.outcome === "sending" || modelData.outcome === "" ? (modelData.percent >= 0 ? modelData.percent + " %" : TailscaleRules.bytes(modelData.sent))
                    : modelData.outcome
                color: modelData.problem !== "" || modelData.outcome === "failed" || modelData.outcome === "not sent" ? Api.theme.warning
                    : modelData.outcome === "sent" ? Api.theme.success : Api.theme.textSecondary
            }
        }
    }

    // ── Receive ──
    Line {
        objectName: "taildropIncoming"
        visible: (root.taildrop?.incoming.length ?? 0) > 0
        text: "Receiving " + (root.taildrop?.incoming ?? []).map(item => item.name + (item.size > 0 ? " " + TaildropRules.percent(item.received, item.size) + " %" : "")).join(", ")
    }
    Line {
        objectName: "taildropWaiting"
        visible: text !== ""
        text: {
            const count = root.taildrop?.waitingCount ?? -1;
            if (count > 0)
                return (count === 1 ? "1 file waiting · " : count + " files waiting · ") + root.taildrop.waiting.map(file => file.shown).join(", ");
            return count < 0 && root.taildrop?.busWaiting ? "Files waiting" : "";
        }
        color: Api.theme.textPrimary
    }
    RowLayout {
        visible: root._operator
        Layout.fillWidth: true
        spacing: 6
        SmallButton {
            objectName: "taildropSave"
            label: "Save"
            available: root._free && (root.taildrop?.waitingCount ?? 0) > 0
            onClicked: root.taildrop.save("user")
        }
        SmallButton {
            objectName: "taildropOpenFolder"
            label: "Open folder"
            available: (root.taildrop?.folder ?? "") !== ""
            onClicked: root.taildrop.openFolder()
        }
    }
    Line {
        visible: text !== ""
        text: root.taildrop?.saveError ?? ""
        color: Api.theme.warning
    }
    Repeater {
        model: ScriptModel {
            values: (root.taildrop?.saved ?? []).map((item, index) => Object.assign({ key: index + "\n" + item.name + "\n" + item.savedAs + "\n" + item.outcome }, item))
            objectProp: "key"
        }
        Line {
            required property var modelData
            objectName: "taildropSaved"
            text: modelData.outcome === "saved" ? "Saved " + modelData.savedAs + (modelData.savedAs !== modelData.name ? " · sent as " + modelData.name : "")
                : (modelData.outcome === "skipped" ? "Left waiting " : "Not saved ") + modelData.name + " · " + modelData.reason
            color: modelData.outcome === "saved" ? Api.theme.textSecondary : Api.theme.warning
        }
    }

    // ── Where and how (the operator's) ──
    RowLayout {
        visible: root._operator
        Layout.fillWidth: true
        spacing: 6
        Line {
            Layout.fillWidth: false
            wrapMode: Text.NoWrap
            text: "Save to"
        }
        Line {
            objectName: "taildropFolder"
            elide: Text.ElideMiddle
            wrapMode: Text.NoWrap
            text: (root.taildrop?.folder ?? "") || "No folder"
            color: Api.theme.textPrimary
        }
        SmallButton {
            label: "Choose…"
            onClicked: _folderDialog.open()
        }
        SmallButton {
            visible: !(root.taildrop?.folderIsDefault ?? true)
            label: "Default"
            onClicked: root.taildrop.resetFolder()
        }
    }
    RowLayout {
        visible: root._operator
        Layout.fillWidth: true
        spacing: 6
        Line {
            Layout.fillWidth: false
            wrapMode: Text.NoWrap
            text: "If the name is taken"
        }
        Dropdown {
            objectName: "taildropConflict"
            Layout.preferredWidth: 160
            options: TaildropRules.conflictPolicies.map(policy => ({ value: policy, label: TaildropRules.conflictLabels[policy] }))
            value: root.taildrop?.conflict ?? TaildropRules.defaultConflict
            onPicked: value => root.taildrop.setConflict(value)
        }
    }
    SwitchRow {
        visible: root._operator
        objectName: "taildropAutoSave"
        label: "Save incoming files automatically"
        hint: ""
        checked: root.taildrop?.autoSave === true
        need: root.taildrop?.canSave ? "" : "no"
        onToggled: root.taildrop?.canSave && root.taildrop.setAutoSave(!checked)
    }
    Line {
        objectName: "taildropAutoKeepsBoth"
        visible: root._operator && root.taildrop?.autoSave === true && root.taildrop?.conflict === "overwrite"
        text: "Auto-save keeps both"
        color: Api.theme.textMuted
    }

    FileDialog {
        id: _fileDialog
        title: "Files to send"
        fileMode: FileDialog.OpenFiles
        currentFolder: TaildropRules.folderUrl(Quickshell.env("HOME") ?? "")
        onAccepted: root.taildrop.addPaths(selectedFiles.map(url => String(url)))
    }
    FolderDialog {
        id: _folderDialog
        title: "Save received files to"
        currentFolder: TaildropRules.folderUrl(root.taildrop?.folder ?? "") || TaildropRules.folderUrl(Quickshell.env("HOME") ?? "")
        onAccepted: {
            const match = /^file:\/\/(\/[^?#]*)$/.exec(String(selectedFolder));
            if (match)
                root.taildrop.setFolder(decodeURIComponent(match[1]));
        }
    }
    Connections {
        target: root.taildrop
        function onChooseFilesRequested() {
            _fileDialog.open();
        }
    }
}
