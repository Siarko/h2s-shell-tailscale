import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api

// Tailscale's own page: the settings page "tailscale" under System → Network (its manifest's
// settingsPages), where its VPN card's "Settings…" leads (the provider's settingsPage) — the
// left list has VPN right beside it, the way back. A plain column at the page's width,
// scrolled by its implicitHeight. It still takes a `context` should a shell frame it as a
// provider page (network.vpn.page), but the module no longer contributes that slot.
// Sections: Connection (the account in use under the state), Accounts, This device, Exit node,
// Network, Sharing and SSH (step 3: SharingSection.qml, SshSection.qml), Devices, Diagnostics
// (collapsed, run only when asked), Administration, About. The devices' traffic is read only
// while this page is on screen (`shown`, module API 1.2: client.watch() / unwatch()).
ColumnLayout {
    id: root
    objectName: "tailscalePage"

    property var module: null
    // Only when framed as a provider page (not contributed now): { slot, vpnId, entryId, vpn,
    // provider, otherVpnsUp, close }; as a settings page null
    property var context: null
    // The live client: the module's main's (module API 1.15), null while the module is off
    readonly property var client: module?.main?.client ?? null
    readonly property var view: client?.view ?? null
    readonly property var prefs: client?.prefs ?? null
    readonly property string need: client && !client.canChange ? "auth" : ""
    readonly property bool _running: view?.phase === "running"
    readonly property bool _loggedIn: view !== null && ["running", "starting", "stopped", "needs-approval"].includes(view.phase)
    readonly property bool _free: client !== null && !client.busy
    readonly property string _operatorLine: "services.tailscale.extraSetFlags = [ \"--operator=" + (client?.userName || "<user>") + "\" ];"
    property string _deviceFilter: ""
    readonly property bool _present: client !== null && client.cli === "present"
    readonly property var device: client?.device ?? null
    property bool _diagnosticsOpen: false
    readonly property string _nicknameNow: client?.currentAccount?.nickname ?? ""
    // On screen (given and kept current by the core: module API 1.2)
    property bool shown: false
    property var _watched: null

    spacing: 4

    function _date(ms) {
        return ms > 0 ? new Date(ms).toLocaleDateString(Qt.locale(), Locale.ShortFormat) : "";
    }

    // The traffic counters are read while the page is on screen
    onClientChanged: _follow()
    onShownChanged: _follow()
    Component.onCompleted: _follow()
    Component.onDestruction: {
        _watched?.unwatch();
        _watched = null;
    }
    function _follow() {
        const wanted = shown ? client : null;
        if (_watched === wanted)
            return;
        _watched?.unwatch();
        _watched = wanted;
        _watched?.watch();
        // On screen: Tailscale may have been installed or started since the last look
        if (typeof _watched?.wake === "function")
            _watched.wake();
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
            textFormat: Text.PlainText
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
            // Not beside an attention's own action (Log in, Start, a failure's): that one acts
            visible: root.view !== null && ["stopped", "unknown"].includes(root.view.phase)
                     && (root.client?.entry.attention?.action ?? "") === ""
            label: "Connect"
            kind: "primary"
            available: root._free
            onClicked: root.client.connect("user")
        }
        SmallButton {
            visible: root.view !== null && ["running", "starting"].includes(root.view.phase)
            label: "Disconnect"
            kind: "danger"
            available: root._free
            onClicked: root.client.disconnect("user")
        }
        SmallButton {
            objectName: "tailscaleAttend"
            visible: (root.client?.entry.attention?.action ?? "") !== ""
            label: root.client?.entry.attention?.action ?? ""
            available: root._free
            onClicked: root.client.attend()
        }
        // Installed or started outside the shell: look again now (the attention's own action
        // says it already while Tailscale is not found)
        SmallButton {
            objectName: "tailscaleCheckAgain"
            visible: root.client?.canLookAgain === true && (root.client.entry.attention?.action ?? "") !== "Check again"
            label: "Check again"
            available: root._free
            onClicked: root.client.recheck()
        }
        SmallButton {
            kind: "danger"
            confirm: true
            size: "s"
            visible: root._loggedIn
            label: "Log out"
            confirmLabel: "Log out?"
            cancelTip: "Cancel — stay logged in"
            available: root._free
            onClicked: root.client.logout()
        }
    }
    // The account in use and its tailnet (TailscaleRules.tailnetName: a personal tailnet by
    // its MagicDNS suffix, not by the e-mail address it is named after)
    Text {
        textFormat: Text.PlainText
        objectName: "tailscaleCurrentAccount"
        visible: text !== "" && root._loggedIn
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: root.client ? [root.client.currentAccount.loginName, root.client.currentAccount.tailnet].filter(part => part !== "").join(" · ") : ""
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.textMuted
    }
    Text {
        textFormat: Text.PlainText
        visible: text !== ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root.client?.entry.attention?.reason ?? ""
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.warning
    }
    // Logging in with the same account merges into the old profile with login's defaults
    // (ipnlocal/profiles.go): said where the button is
    Hint {
        objectName: "tailscaleLoginResets"
        visible: root.view?.attention?.kind === "key-expired"
        text: "Logging in again resets this device's Tailscale settings (exit node, routes, name)."
    }
    Hint {
        visible: (root.client?.loginNote ?? "") !== ""
        text: root.client?.loginNote ?? ""
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
            visible: root.client?.operation === "login" || root.client?.operation === "connect"
            label: "Cancel"
            kind: "secondary"
            onClicked: root.client.cancelLogin()
        }
    }
    Hint {
        visible: root.client?.operation === "login" && root.client._loginElevated
        text: "Logging in as administrator: it stops by itself after "
            + Math.round((root.client?.loginTimeoutMs ?? 0) / 60000) + " minutes if not finished."
    }
    Hint {
        visible: (root.client?.elevationProblem ?? "") !== ""
        text: root.client?.elevationProblem ?? ""
    }
    SwitchRow {
        label: "Open the login page in the browser"
        hint: "Off: the link is only shown, here and in the network popup"
        checked: root.module ? root.module.value("openLoginInBrowser") !== false : true
        onToggled: root.module?.setValue("openLoginInBrowser", !checked)
    }


    // ── Accounts ──
    // The list needs root or the operator (switch --list): read when asked, kept in memory
    SectionTitle {
        visible: root._present
        text: "Accounts"
    }
    Text {
        textFormat: Text.PlainText
        objectName: "tailscaleLoginInterrupted"
        visible: root.client?.loginInterrupted != null
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "The login was not finished: Tailscale is now on a new, empty profile"
            + ((root.client?.loginInterrupted?.title ?? "") !== "" ? " (before: " + root.client.loginInterrupted.title + ")." : ".")
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.warning
    }
    RowLayout {
        visible: root._present && (root.client.accounts === null || root.client.accountsOutdated || (root.client.loginInterrupted?.id ?? "") !== "")
        spacing: 8
        PrivilegedMark {
            need: root.need
        }
        SmallButton {
            objectName: "tailscaleBackToAccount"
            visible: (root.client?.loginInterrupted?.id ?? "") !== ""
            // No name in the label: a button's text is not plain (the warning above names it)
            label: "Switch back"
            available: root._free
            onClicked: root.client.switchAccount(root.client.loginInterrupted.id)
        }
        SmallButton {
            objectName: "tailscaleReadAccounts"
            visible: root.client?.accounts === null || root.client?.accountsOutdated === true
            label: root.client?.accounts === null ? "Show accounts" : "Read again"
            available: root._free
            onClicked: root.client.readAccounts()
        }
        Text {
            textFormat: Text.PlainText
            visible: root.client?.accountsOutdated === true
            text: "The list is out of date."
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textMuted
        }
    }
    Repeater {
        model: ScriptModel {
            objectProp: "id"
            values: TailscaleRules.accountRows(root.client?.accounts ?? [])
        }
        RowLayout {
            id: _account
            required property var modelData
            objectName: "tailscaleAccount-" + modelData.id
            Layout.fillWidth: true
            spacing: 8
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: _account.modelData.title
                    font.family: Api.theme.fontFamily
                    font.pixelSize: Api.theme.fontSizeBody
                    font.bold: _account.modelData.selected
                    color: Api.theme.textPrimary
                }
                Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: _account.modelData.subtitle
                    font.family: Api.theme.fontFamily
                    font.pixelSize: Api.theme.fontSizeSmall
                    color: Api.theme.textMuted
                }
            }
            Text {
                textFormat: Text.PlainText
                visible: _account.modelData.selected
                text: "in use"
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: Api.theme.accent
            }
            PrivilegedMark {
                objectName: "tailscaleAccountMark-" + _account.modelData.id
                // The account in use is not switched to: nothing to mark
                need: _account.modelData.selected ? "" : root.need
            }
            SmallButton {
                objectName: "tailscaleSwitch-" + _account.modelData.id
                visible: !_account.modelData.selected
                label: "Switch"
                available: root._free
                onClicked: root.client.switchAccount(_account.modelData.id)
            }
            SmallButton {
                kind: "danger"
                confirm: true
                size: "s"
                visible: _account.modelData.removable
                label: "Remove"
                confirmLabel: "Remove?"
                cancelTip: "Cancel — keep the account"
                available: root._free
                onClicked: root.client.removeAccount(_account.modelData.id)
            }
        }
    }
    RowLayout {
        visible: root._present && root._loggedIn
        spacing: 8
        PrivilegedMark {
            need: root.need
        }
        SmallButton {
            objectName: "tailscaleAddAccount"
            label: "Add account"
            available: root._free
            onClicked: root.client.addAccount()
        }
        Hint {
            Layout.fillWidth: true
            text: "Disconnects until the new login is done; this account is kept."
        }
    }
    RowLayout {
        visible: root._present && root._loggedIn
        Layout.fillWidth: true
        spacing: 8
        InputField {
            id: _nickname
            Layout.fillWidth: true
            placeholder: "Nickname of this account"
            // The one it has (prefs' ProfileName), set again whenever that changes
            text: root._nicknameNow
            problem: TailscaleRules.nicknameProblem(text) !== ""
        }
        PrivilegedMark {
            need: root.need
        }
        SmallButton {
            label: "Set"
            available: root._free && !_nickname.problem && _nickname.text.trim() !== root._nicknameNow
            onClicked: root.client.setNickname(_nickname.text)
        }
    }

    // ── This device ──
    SectionTitle {
        visible: root.device !== null
        text: "This device"
    }
    // The label/value rows together, so their label column reads as one (a lone "Name" row
    // above the field and the chips showed DetailRow's 110 px label column as a gap)
    DetailRow {
        objectName: "tailscaleDeviceName"
        label: "Name"
        // The name it HAS (prefs' --hostname when set): status's Self follows only once the
        // control plane has it (TailscaleRules.thisDevice)
        value: root.device ? root.device.hostName + " (" + (root.device.customHostname !== "" ? "set here" : "the system's")
            + (root.device.nameNote !== "" ? "; " + root.device.nameNote : "") + ")" : ""
    }
    DetailRow {
        label: "MagicDNS"
        value: !root.device ? "" : root.device.dnsName + (root.device.namePending && root.device.dnsName !== "" ? " (the old name, until the tailnet has the new one)" : "")
    }
    DetailRow {
        label: "Connection"
        value: !root.device ? "" : (root.device.online ? "online" : "offline") + (root.device.relay !== "" ? " · home relay " + root.device.relay : "")
    }
    DetailRow {
        label: "Key"
        value: !root.device ? "" : (root.device.keyExpiry > 0 ? root._date(root.device.keyExpiry) + " — " : "") + root.device.key.text
    }
    RowLayout {
        visible: root.device !== null
        Layout.fillWidth: true
        spacing: 8
        InputField {
            id: _hostname
            objectName: "tailscaleHostnameField"
            Layout.fillWidth: true
            placeholder: "New name: letters, digits, dashes"
            problem: TailscaleRules.hostnameProblem(text.trim()) !== ""
        }
        PrivilegedMark {
            need: root.need
        }
        SmallButton {
            objectName: "tailscaleRename"
            label: "Rename"
            available: root._free && _hostname.text.trim() !== "" && !_hostname.problem
            onClicked: root.client.setHostname(_hostname.text)
        }
        SmallButton {
            visible: (root.device?.customHostname ?? "") !== ""
            label: "Use the system's"
            available: root._free
            onClicked: root.client.setHostname("")
        }
    }
    Text {
        textFormat: Text.PlainText
        visible: text !== ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: TailscaleRules.hostnameProblem(_hostname.text.trim())
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.warning
    }
    // The MagicDNS name only while it is the current one (else it is in the row above, marked)
    CopyChips {
        visible: root.device !== null
        Layout.fillWidth: true
        texts: root.device ? [root.device.ipv4, root.device.ipv6].concat(root.device.namePending ? [] : [root.device.dnsName]) : []
    }
    // No button renews the key here: a bare `login` would drop the connection and reset this
    // device's settings (tailscale.md §8 step 2) — the admin console renews it, or turns it off
    RowLayout {
        visible: ["warning", "soon", "expired"].includes(root.device?.key.state ?? "")
        Layout.fillWidth: true
        spacing: 8
        Hint {
            Layout.fillWidth: true
            text: "Key expiry can be renewed or turned off in the admin console."
        }
        SmallButton {
            objectName: "tailscaleAdminConsole"
            label: "Open the admin console"
            onClicked: root.client.openUrl(TailscaleRules.adminMachinesUrl)
        }
    }

    // ── Exit node ──
    SectionTitle {
        visible: root._running
        text: "Exit node"
    }
    Hint {
        visible: root._running
        text: "It carries this computer's internet traffic; the tailnet is reached either way."
    }
    Hint {
        visible: root._running && TailscaleRules.exitNodeUseProblem(root.prefs) !== ""
        text: TailscaleRules.exitNodeUseProblem(root.prefs)
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
        hint: "Printers, shares and the router, while an exit node is in use"
        checked: root.prefs?.exitNodeAllowLan === true
        need: root.need
        onToggled: root._free && root.client.setAllowLan(!checked)
    }
    // Another VPN up beside the exit node that takes all traffic too, or may (both want it;
    // Tailscale's wins), or one whose routes overlap the tailnet or the subnet routes Tailscale
    // carries (Api.vpnsUp's fullTunnel and routes, module API 1.16). A split one beside them
    // does not count.
    Hint {
        objectName: "tailscaleOtherVpnHint"
        visible: root._running && ((root.view?.exitNode !== null
                && TailscaleRules.fullTunnelVpns(Api.vpnsUp, root.module?.moduleId ?? "tailscale").length > 0)
            || TailscaleRules.overlappingVpns(Api.vpnsUp, root.module?.moduleId ?? "tailscale", root.client?.entry.routes ?? null).length > 0)
        text: "Another VPN is also on"
    }

    // ── Network ──
    SectionTitle {
        visible: root.prefs !== null
        text: "Network"
    }
    SwitchRow {
        visible: root.prefs !== null
        label: "Use routes from other devices"
        hint: "Subnets that other devices of the tailnet offer"
        checked: root.prefs?.acceptRoutes === true
        need: root.need
        onToggled: root._free && root.client.setAcceptRoutes(!checked)
    }
    SwitchRow {
        visible: root.prefs !== null
        label: "Use Tailscale's DNS"
        hint: "MagicDNS names and the tailnet's DNS settings"
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

    // ── Sharing, SSH (step 3) ──
    SharingSection {
        Layout.fillWidth: true
        client: root.client
        need: root.need
        shown: root.shown
    }
    SshSection {
        Layout.fillWidth: true
        client: root.client
        need: root.need
    }

    // ── Taildrop (step 4) ──
    TaildropSection {
        Layout.fillWidth: true
        client: root.client
        need: root.need
    }

    // ── Serve and Funnel, certificates, tailnet lock (step 5) ──
    ServeSection {
        Layout.fillWidth: true
        client: root.client
        need: root.need
        shown: root.shown
    }
    CertSection {
        Layout.fillWidth: true
        client: root.client
        shown: root.shown
    }
    LockSection {
        Layout.fillWidth: true
        client: root.client
        shown: root.shown
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
            client: root.client
        }
    }


    // ── Diagnostics (collapsed; run only when asked) ──
    RowLayout {
        visible: root._present
        Layout.topMargin: 16
        Layout.fillWidth: true
        spacing: 8
        SectionTitle {
            Layout.topMargin: 0
            Layout.bottomMargin: 0
            Layout.fillWidth: true
            text: "Diagnostics"
        }
        SmallButton {
            objectName: "tailscaleDiagnosticsToggle"
            label: root._diagnosticsOpen ? "Hide" : "Show"
            onClicked: root._diagnosticsOpen = !root._diagnosticsOpen
        }
    }
    ColumnLayout {
        objectName: "tailscaleDiagnostics"
        visible: root._present && root._diagnosticsOpen
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            spacing: 8
            SmallButton {
                objectName: "tailscaleRunDiagnostics"
                label: root.client?.diagnostics.running ? "Checking…" : (root.client?.diagnostics.ranAt > 0 ? "Check again" : "Check the network")
                available: root.client !== null && !root.client.diagnostics.running
                onClicked: root.client.runDiagnostics()
            }
            SmallButton {
                label: "Copy diagnostics"
                tooltip: "Versions, the checks above (with the tailnet's DNS name, resolver addresses, domains), health — no keys, no links"
                onClicked: Api.copy(root.client.diagnosticsReport)
            }
        }
        DetailRow {
            label: "Client version"
            value: root.client?.diagnostics.clientVersion ?? ""
        }
        Text {
            textFormat: Text.PlainText
            text: "Health"
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            font.bold: true
            color: Api.theme.textPrimary
        }
        Hint {
            visible: (root.client?.health.length ?? 0) === 0
            text: "No warnings."
        }
        Repeater {
            model: ScriptModel {
                values: (root.client?.health ?? []).map(warning => ({ key: warning.title + "\n" + warning.text, title: warning.title, text: warning.text }))
                objectProp: "key"
            }
            Text {
                required property var modelData
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: [modelData.title, modelData.text].filter(part => part !== "").join(": ")
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: Api.theme.warning
            }
        }
        Text {
            textFormat: Text.PlainText
            visible: (root.client?.diagnostics.netcheck.length ?? 0) > 0
            text: "Network (netcheck)"
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            font.bold: true
            color: Api.theme.textPrimary
        }
        Repeater {
            model: ScriptModel {
                values: root.client?.diagnostics.netcheck ?? []
                objectProp: "label"
            }
            DetailRow {
                required property var modelData
                label: modelData.label
                value: modelData.value
            }
        }
        Text {
            textFormat: Text.PlainText
            visible: (root.client?.diagnostics.dns.length ?? 0) > 0
            text: "DNS"
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            font.bold: true
            color: Api.theme.textPrimary
        }
        Repeater {
            model: ScriptModel {
                values: root.client?.diagnostics.dns ?? []
                objectProp: "label"
            }
            DetailRow {
                required property var modelData
                label: modelData.label
                value: modelData.value
            }
        }
        Repeater {
            model: ScriptModel {
                values: (root.client?.diagnostics.errors ?? []).map(text => ({ text: text }))
                objectProp: "text"
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
            text: "Not offered: tailscale bugreport — it uploads logs to Tailscale."
        }
    }

    // ── Administration ──
    SectionTitle {
        visible: root.client !== null && root.client.cli === "present"
        text: "Administration"
    }
    Text {
        textFormat: Text.PlainText
        visible: root.client !== null && root.client.cli === "present" && root.client.canChange
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "This user changes Tailscale without a password" + (root.prefs?.operatorUser ? " (it is Tailscale's operator for this account)." : ".")
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeBody
        color: Api.theme.textPrimary
    }
    Hint {
        visible: root.client !== null && root.client.cli === "present" && !root.client.canChange
        text: "Each change asks for an administrator's password; making this user the operator asks once. An operator may then, without a password, "
            + "turn on Tailscale's SSH server, offer this computer as an exit node or its networks as routes, change its DNS, log it out or into another account, "
            + "send files and save received ones (Taildrop). It is set per account: logging in again with the same account resets it."
    }
    // The operator may give it up (no password: an operator may change Tailscale)
    RowLayout {
        visible: root.client !== null && root.client.cli === "present" && root.client.canChange && (root.prefs?.operatorUser ?? "") !== ""
            && root.prefs.operatorUser === root.client.userName
        spacing: 8
        SmallButton {
            objectName: "tailscaleGiveUpOperator"
            label: "Stop being the operator"
            tooltip: "Changes then ask for an administrator's password again, and received files can no longer be saved"
            available: root._free
            onClicked: root.client.giveUpOperator()
        }
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
        text: "On NixOS, to set it in the system's configuration too:"
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
        // Not beside an update warning, which says the same
        visible: root.client?.updateManagedBySystem === true && !(root.client?.warnings ?? []).some(warning => warning.kind === "update")
        text: "Tailscale is updated with the NixOS system, not here."
    }
    SwitchRow {
        visible: root.prefs !== null
        label: "Tell me about Tailscale updates"
        hint: "Tailscale checks for a newer version"
        checked: root.client?.sharing?.updateCheck !== false
        need: root.need
        onToggled: root._free && root.client.setSwitch("updateCheck", !checked)
    }
    SwitchRow {
        visible: root.prefs !== null
        label: "Update Tailscale automatically"
        // Refused by the daemon where it cannot update itself (NixOS): off, with the reason
        hint: (root.client?.autoUpdateProblem ?? "") !== "" ? root.client.autoUpdateProblem : "Tailscale installs new versions by itself"
        checked: root.client?.sharing?.autoUpdate === true
        need: !checked && (root.client?.autoUpdateProblem ?? "") !== "" ? "no" : root.need
        onToggled: root._free && root.client.setSwitch("autoUpdate", !checked)
    }
}
