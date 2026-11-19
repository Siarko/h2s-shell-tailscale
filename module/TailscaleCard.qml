import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api

// At settings.network_vpn.vpns.card.settings ("prepend", own-provider; module API 1.23): in
// Tailscale's opened card in Settings → System → Network → VPN — the tailnet and account, this
// computer's name and addresses, the key's expiry, the exit node, the warnings (health, an
// accepted route that covers the local network, two VPNs up), and that the shell's blocking
// does not support Tailscale. The state, its attention with the
// action and "Settings…" (the module's page) are the core card's own.
ColumnLayout {
    id: root
    objectName: "tailscaleCardExtras"

    property var module: null
    // { anchor, placement, vpnId, entryId, vpn, provider, otherVpnsUp, otherVpns: the other VPNs
    // up as Api.vpnsUp's rows } (the place's)
    property var context: null
    // The live client: the module's main's (module API 1.15), null while the module is off
    readonly property var client: module?.main?.client ?? null
    readonly property var status: client?.status ?? null
    readonly property var self: client?.self ?? null

    readonly property string _twoVpns: TailscaleRules.twoVpnsNote({
        tailscaleUp: client?.entry.state === "activated", exitNode: client?.view.exitNode?.name ?? "",
        acceptDns: client?.prefs?.acceptDns !== false, routes: client?.entry.routes ?? null, otherVpns: context?.otherVpns ?? []
    })
    readonly property var _warnings: (client?.warnings ?? []).map(warning => warning.text).concat(_twoVpns !== "" ? [_twoVpns] : [])

    function _date(ms) {
        return ms > 0 ? new Date(ms).toLocaleDateString(Qt.locale(), Locale.ShortFormat) : "";
    }

    spacing: 4
    visible: client !== null

    // Opened: Tailscale may have been installed or started since the last look
    onClientChanged: _wake()
    Component.onCompleted: _wake()
    function _wake() {
        if (typeof client?.wake === "function")
            client.wake();
    }

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
        // While a new name has not reached the tailnet, that name (and why the old one still
        // shows), never the old MagicDNS name as if current (TailscaleRules.thisDevice)
        value: !root.self ? "" : (root.client?.device?.namePending
            ? root.client.device.hostName + " (" + root.client.device.nameNote + ")"
            : (root.self.dnsName || root.self.hostName))
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
        Notice {
            required property var modelData
            text: modelData.text
        }
    }

    Hint {
        text: "Not let through when traffic outside a VPN is blocked."
    }
}
