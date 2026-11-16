import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// Slot network.vpn.card: on Tailscale's card in Settings → System → Network → VPN — the
// tailnet and account, this computer's name and addresses, the key's expiry, the exit node,
// the warnings (health, an accepted route that covers the local network, two VPNs up), and
// that the shell's blocking does not support Tailscale. The state, its attention with the
// action and "Settings…" (the module's page) are the core card's own.
ColumnLayout {
    id: root
    objectName: "tailscaleCardExtras"

    property var module: null
    // { slot, vpnId, entryId, vpn, provider, otherVpnsUp, open }
    property var context: null
    readonly property var client: context?.provider?.client ?? Tailscale.client
    readonly property var status: client?.status ?? null
    readonly property var self: client?.self ?? null

    readonly property string _twoVpns: TailscaleRules.twoVpnsNote({
        tailscaleUp: client?.entry.state === "activated", exitNode: client?.view.exitNode?.name ?? "",
        acceptDns: client?.prefs?.acceptDns !== false, otherVpns: context?.otherVpnsUp ?? []
    })
    readonly property var _warnings: (client?.warnings ?? []).map(warning => warning.text).concat(_twoVpns !== "" ? [_twoVpns] : [])

    function _date(ms) {
        return ms > 0 ? new Date(ms).toLocaleDateString(Qt.locale(), Locale.ShortFormat) : "";
    }

    spacing: 4
    visible: client !== null

    DetailRow {
        label: "Tailnet"
        value: TailscaleRules.tailnetName(root.status, { lastTailnet: root.client?.lastTailnet ?? "" })
    }
    DetailRow {
        label: "Account"
        value: root.client?.prefs?.loginName ?? ""
    }
    DetailRow {
        label: "This computer"
        value: root.self ? (root.self.dnsName || root.self.hostName) : ""
    }
    DetailRow {
        label: "Its addresses"
        value: (root.status?.addresses ?? []).join(", ")
    }
    DetailRow {
        label: "Exit node"
        value: root.client?.view.phase === "running" ? (root.client.view.exitNode ? root.client.view.exitNode.name + (root.client.view.exitNode.online ? "" : " (offline)") : "None") : ""
    }
    DetailRow {
        label: "Key"
        value: !root.self ? "" : (root.self.keyExpiry > 0 ? root._date(root.self.keyExpiry) + " — " : "") + (root.client.keyState?.text ?? "")
    }

    Repeater {
        model: ScriptModel {
            values: root._warnings.map(text => ({ text: text }))
            objectProp: "text"
        }
        Text {
            textFormat: Text.PlainText
            required property var modelData
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: modelData.text
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.warning
        }
    }

    Hint {
        text: "Not let through when traffic outside a VPN is blocked."
    }
}
