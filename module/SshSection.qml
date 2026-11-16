import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// The page's "SSH": Tailscale's SSH server on this computer (`tailscale set --ssh`), who may
// log in (the tailnet's access rules, linked), Tailscale's own warnings about it; logging in to
// another device is the device rows' "Copy ssh command".
ColumnLayout {
    id: root

    property var client: null
    property string need: ""

    readonly property var ssh: client?.sshServer ?? null
    readonly property bool _free: client !== null && !client.busy
    // Tailscale's health texts about its SSH server ("Tailscale SSH is on, but …")
    readonly property var _sshHealth: (client?.health ?? []).filter(warning => /\bSSH\b/.test(warning.title + " " + warning.text))

    visible: ssh !== null && client?.prefs !== null && client?.prefs !== undefined
    Layout.fillWidth: true
    spacing: 4

    SectionTitle {
        text: "SSH"
    }
    SwitchRow {
        objectName: "tailscaleSshServer"
        label: "Tailscale SSH server"
        hint: "Other devices of the tailnet log in to this computer through Tailscale"
        checked: root.ssh?.on === true
        need: !checked && root.ssh?.canTurnOn === false ? "no" : root.need
        onToggled: root._free && root.client.setSwitch("ssh", !checked)
    }
    RowLayout {
        visible: root.ssh?.on === true
        Layout.fillWidth: true
        spacing: 8
        Text {
            objectName: "tailscaleSshOn"
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "On — who may log in is decided by the tailnet's access rules (ACLs)."
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textSecondary
        }
        SmallButton {
            visible: (root.client?.sharing?.adminUrl ?? "") !== ""
            label: "Open the access rules"
            onClicked: root.client.openUrl(TailscaleRules.adminAclsUrl)
        }
    }
    Text {
        textFormat: Text.PlainText
        visible: text !== "" && root.ssh?.on !== true
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.ssh?.problem ?? ""
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.warning
    }
    Repeater {
        model: ScriptModel {
            values: root._sshHealth.map(warning => ({ key: warning.title + "\n" + warning.text, text: [warning.title, warning.text].filter(part => part !== "").join(": ") }))
            objectProp: "key"
        }
        Text {
            required property var modelData
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: modelData.text
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.warning
        }
    }
    Hint {
        text: "While on, port 22 on this computer's Tailscale addresses is Tailscale SSH: the system's sshd is no longer reachable over the tailnet (other networks unchanged)."
    }
    Hint {
        text: "To log in to another device: \"Copy ssh command\" on its row below (plain ssh works over the tailnet)."
    }
}
