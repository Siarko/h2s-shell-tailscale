import QtQuick
import QtQuick.Layouts
import qs.api

// The row under a device in the bar popup (TaildropRules.popupRow): the files picked for it
// with Send and "×", then the send's progress bar with Cancel, then how it ended with "×".
// Everything it does is TaildropClient's. Public elements only; the bar is the module's own,
// drawn on the theme's tokens.
ColumnLayout {
    id: root

    // TaildropClient (or what a test gives) and the device's id
    property var taildrop: null
    property string deviceId: ""

    readonly property var row: TaildropRules.popupRow(taildrop?.popupChoice ?? null, taildrop?.send ?? null, deviceId, taildrop?.sending === true)

    visible: row !== null
    spacing: 2

    component Line: Text {
        textFormat: Text.PlainText
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.textSecondary
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
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
            onClicked: root.taildrop.sendChoice()
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
                    root.taildrop.dropChoice();
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
        implicitHeight: Api.theme.button.verticalPadding
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
}
