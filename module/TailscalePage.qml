import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// Tailscale's own page: slot network.vpn.page (opened from its card's "Settings…", in the
// core's frame: Back, title, scrolling) and the settings page "tailscale" under System →
// Network (its manifest's settingsPages) — the same file. A plain column at the page's width,
// scrolled by its implicitHeight. Sections: Connection, Exit node, Network, Devices,
// Administration, About. The devices' traffic is read only while this page exists
// (client.watch() / unwatch()).
ColumnLayout {
    id: root
    objectName: "tailscalePage"

    property var module: null
    // In the VPN page's frame: { slot, vpnId, entryId, vpn, provider, otherVpnsUp, close }
    property var context: null
    readonly property var client: context?.provider?.client ?? Tailscale.client
    readonly property var view: client?.view ?? null
    readonly property var prefs: client?.prefs ?? null
    readonly property string need: client && !client.canChange ? "auth" : ""
    readonly property bool _running: view?.phase === "running"
    readonly property bool _loggedIn: view !== null && ["running", "starting", "stopped", "needs-approval"].includes(view.phase)
    readonly property bool _free: client !== null && !client.busy
    readonly property string _operatorLine: "services.tailscale.extraSetFlags = [ \"--operator=" + (client?.userName || "<user>") + "\" ];"
    property string _deviceFilter: ""
    property var _watched: null

    spacing: 4

    // The traffic counters are read while the page is there
    onClientChanged: _follow()
    Component.onCompleted: _follow()
    Component.onDestruction: {
        _watched?.unwatch();
        _watched = null;
    }
    function _follow() {
        if (_watched === client)
            return;
        _watched?.unwatch();
        _watched = client;
        _watched?.watch();
    }

    Hint {
        visible: root.client === null
        text: "Tailscale's module is not running."
    }

    // ── Connection ──
    SectionTitle {
        Layout.topMargin: 0
        text: "Connection"
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.client ? [root.client.entry.state === "activated" ? "Connected" : root.client.entry.state === "activating" ? "Connecting…"
                : root.client.entry.state === "deactivating" ? "Disconnecting…" : "Off", root.client.entry.status].filter(part => part !== "").join(" · ") : ""
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeBody
            color: root.client?.entry.state === "activated" ? Api.theme.accent : Api.theme.textPrimary
        }
        PrivilegedMark {
            need: root.need
        }
        SmallButton {
            objectName: "tailscaleConnect"
            visible: root.view !== null && ["stopped", "unknown"].includes(root.view.phase)
            label: "Connect"
            kind: "save"
            available: root._free
            onClicked: root.client.connect("user")
        }
        SmallButton {
            visible: root.view !== null && ["running", "starting"].includes(root.view.phase)
            label: "Disconnect"
            kind: "delete"
            available: root._free
            onClicked: root.client.disconnect("user")
        }
        SmallButton {
            visible: (root.client?.entry.attention?.action ?? "") !== ""
            label: root.client?.entry.attention?.action ?? ""
            available: root._free
            onClicked: root.client.attend()
        }
        DeleteButton {
            visible: root._loggedIn
            label: "Log out"
            confirmLabel: "Log out?"
            cancelTip: "Cancel — stay logged in"
            available: root._free
            onConfirmed: root.client.logout()
        }
    }
    Text {
        visible: text !== ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.client?.entry.attention?.reason ?? ""
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.warning
    }
    // The login link while a login waits for the browser (or one the daemon offers)
    RowLayout {
        readonly property string url: root.client ? (root.client.authUrl || root.client.busAuthUrl) : ""
        visible: url !== ""
        Layout.fillWidth: true
        spacing: 6
        TextEdit {
            Layout.fillWidth: true
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.WrapAnywhere
            text: parent.url
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textSecondary
            selectionColor: Api.theme.selection
            selectedTextColor: Api.theme.selectedText
        }
        SmallButton {
            label: "Open"
            onClicked: root.client.openUrl(parent.url)
        }
        SmallButton {
            label: "Copy"
            onClicked: Api.copy(parent.url)
        }
        SmallButton {
            visible: root.client?.operation === "login"
            label: "Cancel"
            kind: "cancel"
            onClicked: root.client.cancelLogin()
        }
    }
    SwitchRow {
        label: "Open the login page in the browser"
        hint: "Off: the link is only shown here and under Tailscale's row in the network popup, to copy"
        checked: root.module ? root.module.value("openLoginInBrowser") !== false : true
        onToggled: root.module?.setValue("openLoginInBrowser", !checked)
    }

    // ── Exit node ──
    SectionTitle {
        visible: root._running
        text: "Exit node"
    }
    Hint {
        visible: root._running
        text: "An exit node carries this computer's internet traffic; the tailnet is reached either way."
    }
    ExitNodeChooser {
        visible: root._running
        Layout.fillWidth: true
        client: root.client
        collapsible: false
    }
    SwitchRow {
        visible: root._running
        label: "Allow the local network"
        hint: "Printers, shares and the router stay reachable while an exit node is in use"
        checked: root.prefs?.exitNodeAllowLan === true
        need: root.need
        onToggled: root._free && root.client.setAllowLan(!checked)
    }

    // ── Network ──
    SectionTitle {
        visible: root.prefs !== null
        text: "Network"
    }
    SwitchRow {
        visible: root.prefs !== null
        label: "Use routes from other devices"
        hint: "Subnets other devices of the tailnet offer are reached through them"
        checked: root.prefs?.acceptRoutes === true
        need: root.need
        onToggled: root._free && root.client.setAcceptRoutes(!checked)
    }
    SwitchRow {
        visible: root.prefs !== null
        label: "Use Tailscale's DNS"
        hint: "Names of the tailnet (MagicDNS) and the tailnet's DNS settings"
        checked: root.prefs?.acceptDns !== false
        need: root.need
        onToggled: root._free && root.client.setAcceptDns(!checked)
    }
    SwitchRow {
        visible: root.prefs !== null
        label: "Block incoming connections"
        hint: "Shields up: other devices cannot reach this computer through Tailscale"
        checked: root.prefs?.shieldsUp === true
        need: root.need
        onToggled: root._free && root.client.setShieldsUp(!checked)
    }

    // ── Devices ──
    SectionTitle {
        visible: (root.client?.devices.length ?? 0) > 0
        text: "Devices (" + (root.client?.devices.length ?? 0) + ")"
    }
    InputField {
        visible: (root.client?.devices.length ?? 0) > 6
        Layout.fillWidth: true
        placeholder: "Filter: a name, an owner, a system, an address"
        onTextEdited: root._deviceFilter = text
    }
    Repeater {
        model: ScriptModel {
            objectProp: "id"
            values: {
                const wanted = root._deviceFilter.trim().toLowerCase();
                const all = root.client?.devices ?? [];
                return wanted === "" ? all : all.filter(device => [device.name, device.dnsName, device.owner, device.os].concat(device.addresses)
                    .some(text => String(text).toLowerCase().includes(wanted)));
            }
        }
        DeviceRow {
            required property var modelData
            Layout.fillWidth: true
            device: modelData
            showTraffic: true
        }
    }

    // ── Administration ──
    SectionTitle {
        visible: root.client !== null && root.client.cli === "present"
        text: "Administration"
    }
    Text {
        visible: root.client !== null && root.client.cli === "present" && root.client.canChange
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "This user changes Tailscale without a password" + (root.prefs?.operatorUser ? " (it is Tailscale's operator)." : ".")
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeBody
        color: Api.theme.textPrimary
    }
    Hint {
        visible: root.client !== null && root.client.cli === "present" && !root.client.canChange
        text: "Every change asks for an administrator's password. Making this user Tailscale's operator asks once instead — but an operator "
            + "may then do nearly anything with Tailscale without a password: turn on its SSH server, offer this computer as an exit node "
            + "or its networks as routes, change its DNS, log it out or into another account."
    }
    RowLayout {
        visible: root.client !== null && root.client.cli === "present" && !root.client.canChange
        spacing: 8
        PrivilegedMark {
            need: "auth"
        }
        SmallButton {
            label: "Make " + (root.client?.userName || "this user") + " the operator"
            available: root._free && (root.client?.userName ?? "") !== ""
            onClicked: root.client.becomeOperator()
        }
    }
    Hint {
        visible: root.client !== null && root.client.cli === "present" && root.client.updateManagedBySystem
        text: "On NixOS, the same lasts in the system's configuration (the setting above is Tailscale's own and also stays):"
    }
    RowLayout {
        visible: root.client !== null && root.client.cli === "present" && root.client.updateManagedBySystem
        Layout.fillWidth: true
        spacing: 6
        TextEdit {
            Layout.fillWidth: true
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.WrapAnywhere
            text: root._operatorLine
            font.family: "monospace"
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textSecondary
            selectionColor: Api.theme.selection
            selectedTextColor: Api.theme.selectedText
        }
        SmallButton {
            label: "Copy"
            onClicked: Api.copy(root._operatorLine)
        }
    }

    // ── About ──
    SectionTitle {
        text: "About"
    }
    DetailRow {
        label: "Tailscale"
        value: root.client?.status?.version ?? ""
    }
    DetailRow {
        label: "Program"
        value: root.client ? (root.client.cli === "missing" ? "not installed" : root.client.tailscalePath) : ""
    }
    DetailRow {
        label: "Module"
        value: root.module?.version ?? ""
    }
    Repeater {
        model: ScriptModel {
            values: (root.client?.warnings ?? []).filter(warning => warning.kind === "update").map(warning => ({ text: warning.text }))
            objectProp: "text"
        }
        Hint {
            required property var modelData
            text: modelData.text + ((root.client?.updateManagedBySystem ?? false) ? "" : ".")
        }
    }
    Hint {
        visible: root.client?.updateManagedBySystem === true
        text: "Tailscale's version is managed by your NixOS configuration: it is updated with the system, not here."
    }
}
