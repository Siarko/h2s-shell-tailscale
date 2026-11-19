import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api

// The page's "Tailnet lock" (delivery step 5): its state only (LockClient, LockRules) — one line
// while off; on: whether this device is signed, its keys to copy, the trusted keys' count. A
// locked-out device also shows on the entry (attention). Changing the lock is not offered.
ColumnLayout {
    id: root

    property var client: null
    property bool shown: false

    readonly property var lock: client?.tailnetLock?.lock ?? null

    visible: lock !== null
    Layout.fillWidth: true
    spacing: 4

    onShownChanged: {
        if (shown)
            client?.tailnetLock?.read();
    }
    Component.onCompleted: {
        if (shown)
            client?.tailnetLock?.read();
    }

    SectionTitle {
        text: "Tailnet lock"
    }
    DetailRow {
        objectName: "tailscaleLockState"
        label: "State"
        value: LockRules.summary(root.lock)
    }
    RowLayout {
        visible: root.lock?.lockedOut === true
        Layout.fillWidth: true
        spacing: 8
        Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "A trusted device must sign this one"
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.warning
        }
        SmallButton {
            label: "Admin console"
            onClicked: root.client.attend()
        }
    }
    DetailRow {
        visible: root.lock?.enabled === true
        label: "Trusted keys"
        value: String(root.lock?.trustedKeys ?? 0)
    }
    CopyChips {
        visible: root.lock?.enabled === true
        Layout.fillWidth: true
        texts: [root.lock?.nodeKey ?? "", root.lock?.publicKey ?? ""].filter(key => key !== "")
    }
}
