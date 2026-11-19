import QtQuick
import QtQuick.Layouts
import qs.api

// The row under a device in the bar popup (TaildropRules.popupRow): the files picked for it
// with Send and "×", then the send's progress bar with Cancel, then how it ended with "×"; and
// under it why its chooser did not open, with "×". Everything it does is TaildropClient's.
// Public elements only; the bar is the module's own, drawn on the theme's tokens.
ColumnLayout {
    id: root

    // TaildropClient (or what a test gives) and the device's id
    property var taildrop: null
    property string deviceId: ""

    readonly property var row: TaildropRules.popupRow(taildrop?.popupChoices ?? null, taildrop?.send ?? null, deviceId, taildrop?.sending === true)
    readonly property string note: String(taildrop?.popupNotes?.[deviceId] ?? "")

    // Api.theme names no spacing or progress-bar size yet: both follow the small type until
    // the core's public progress bar and its tokens replace them (never a user's padding
    // setting: a button's padding of 0 would hide the bar)
    readonly property int _gap: Math.round(Api.theme.fontSizeSmall / 2)

    visible: row !== null || note !== ""
    spacing: Math.round(_gap / 3)

    component Line: Text {
        textFormat: Text.PlainText
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.textSecondary
    }

    RowLayout {
        visible: root.row !== null
        Layout.fillWidth: true
        spacing: root._gap
        Line {
            objectName: "taildropPopupFiles"
            Layout.fillWidth: true
            elide: Text.ElideMiddle
            text: root.row?.label ?? ""
            color: Api.theme.textPrimary
        }
        Line {
            objectName: "taildropPopupState"
            visible: text !== ""
            Layout.maximumWidth: root.width * 0.6
            text: root.row?.text ?? ""
            color: root.row?.tone === "success" ? Api.theme.success : root.row?.tone === "warning" ? Api.theme.warning
                : root.row?.tone === "muted" ? Api.theme.textMuted : Api.theme.textSecondary
        }
        SmallButton {
            objectName: "taildropPopupSend"
            visible: root.row?.kind === "choice"
            label: "Send"
            kind: "primary"
            size: "xs"
            tooltip: root.row?.names ?? ""
            available: root.row?.canSend === true
            onClicked: root.taildrop.sendChoice(root.deviceId)
        }
        SmallButton {
            objectName: "taildropPopupCancel"
            visible: root.row?.canCancel === true
            label: "Cancel"
            size: "xs"
            onClicked: root.taildrop.cancelSend()
        }
        SmallButton {
            objectName: "taildropPopupDrop"
            visible: root.row?.canDrop === true
            label: "×"
            size: "xs"
            tooltip: root.row?.kind === "choice" ? "Drop" : "Clear"
            onClicked: {
                if (root.row?.kind === "choice")
                    root.taildrop.dropChoice(root.deviceId);
                else
                    root.taildrop.dismissPopupSend(root.deviceId);
            }
        }
    }

    // The send's bytes so far over all its files; empty while no size is known yet
    Rectangle {
        id: _track
        objectName: "taildropPopupProgress"
        visible: root.row?.kind === "sending" || (root.row?.kind === "result" && root.row?.fraction === 1)
        Layout.fillWidth: true
        // A third of the small type: moves to the core's public progress bar (its own height
        // token) once the core has one
        implicitHeight: Math.round(Api.theme.fontSizeSmall / 3)
        radius: height / 2
        color: Api.theme.track

        readonly property real fraction: Math.max(0, root.row?.fraction ?? 0)

        Rectangle {
            width: _track.width * _track.fraction
            height: parent.height
            radius: parent.radius
            color: root.row?.kind === "result" ? Api.theme.success : Api.theme.accent
        }
    }

    // Why the chooser did not open (another one open, an error); the send's own refusal
    RowLayout {
        visible: root.note !== ""
        Layout.fillWidth: true
        spacing: root._gap
        Line {
            objectName: "taildropPopupNote"
            Layout.fillWidth: true
            text: root.note
            color: Api.theme.warning
        }
        SmallButton {
            objectName: "taildropPopupNoteDrop"
            label: "×"
            size: "xs"
            tooltip: "Clear"
            onClicked: root.taildrop.dropPopupNote(root.deviceId)
        }
    }
}
