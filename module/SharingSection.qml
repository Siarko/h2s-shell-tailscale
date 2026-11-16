import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// The page's "Sharing": what this computer offers to the tailnet — itself as an exit node, its
// networks as subnet routes (each with an admin's approval), IP forwarding when it is off, the
// web interface; the rarer switches collapsed under "More". Every change is a `tailscale set`
// (TailscaleClient's sharing functions; the rules decide what is valid: TailscaleRules,
// "Sharing this computer"). Routes are the user's own networks; tags come from the tailnet:
// all shown as plain text.
ColumnLayout {
    id: root

    property var client: null
    // polkit's answer for a change ("auth": each asks for a password)
    property string need: ""
    // The page is on screen: IP forwarding is read then (only while something is offered)
    property bool shown: false
    property bool _moreOpen: false

    readonly property var sharing: client?.sharing ?? null
    readonly property bool _free: client !== null && !client.busy
    readonly property var _routeCheck: TailscaleRules.routeProblem(_route.text, client?.prefs?.advertiseRoutes ?? [])
    readonly property var _warning: client?.forwardingWarning ?? null
    readonly property string _forwardingLines: (_warning?.nixosLines ?? []).join("\n")

    visible: sharing !== null && sharing.known === true
    Layout.fillWidth: true
    spacing: 4

    function _check() {
        if (shown && sharing?.offersAny === true)
            client?.readForwarding?.();
    }
    onShownChanged: _check()
    // Offering something for the first time (or again): read it then too
    readonly property bool _offers: sharing?.offersAny === true
    on_OffersChanged: _check()
    Component.onCompleted: _check()

    SectionTitle {
        text: "Sharing"
    }
    Hint {
        text: "What this computer offers to the other devices of the tailnet."
    }

    // ── Exit node ──
    SwitchRow {
        objectName: "tailscaleOfferExitNode"
        label: "Offer this computer as an exit node"
        hint: "Other devices may send their internet traffic through it"
        checked: root.sharing?.exitNode.offered === true
        // Refused by the daemon while it uses an exit node itself (turning it off stays possible)
        need: !checked && (root.sharing?.exitNode.problem ?? "") !== "" ? "no" : root.need
        onToggled: root._free && root.client.setAdvertiseExitNode(!checked)
    }
    RowLayout {
        visible: root.sharing?.exitNode.offered === true
        Layout.fillWidth: true
        spacing: 8
        Text {
            objectName: "tailscaleExitNodeApproval"
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Exit node: " + (root.sharing?.exitNode.text ?? "")
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: root.sharing?.exitNode.state === "pending" ? Api.theme.warning : Api.theme.textMuted
        }
    }
    RowLayout {
        visible: root.sharing?.exitNode.offered !== true && (root.sharing?.exitNode.problem ?? "") !== ""
        Layout.fillWidth: true
        spacing: 8
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.sharing?.exitNode.problem ?? ""
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textMuted
        }
        PrivilegedMark {
            need: root.need
        }
        SmallButton {
            label: "Stop using it"
            available: root._free
            onClicked: root.client.setExitNode(null)
        }
    }

    // ── Subnet routes ──
    Text {
        textFormat: Text.PlainText
        Layout.topMargin: 6
        text: "Networks offered (subnet routes)"
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeBody
        color: Api.theme.textPrimary
    }
    Hint {
        visible: (root.sharing?.routes.length ?? 0) === 0
        text: "None. Other devices reach a network offered here through this computer."
    }
    Repeater {
        model: ScriptModel {
            objectProp: "route"
            values: root.sharing?.routes ?? []
        }
        RowLayout {
            id: _routeRow
            required property var modelData
            objectName: "tailscaleRoute-" + modelData.route
            Layout.fillWidth: true
            spacing: 8
            Text {
                textFormat: Text.PlainText
                text: _routeRow.modelData.route
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeBody
                color: Api.theme.textPrimary
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: _routeRow.modelData.text
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: _routeRow.modelData.state === "pending" ? Api.theme.warning : Api.theme.textMuted
            }
            PrivilegedMark {
                need: root.need
            }
            DeleteButton {
                label: "Remove"
                confirmLabel: "Remove?"
                cancelTip: "Cancel — keep offering it"
                available: root._free
                onConfirmed: root.client.removeRoute(_routeRow.modelData.route)
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        InputField {
            id: _route
            objectName: "tailscaleRouteField"
            Layout.fillWidth: true
            placeholder: "Network to offer, e.g. 192.168.1.0/24"
            problem: text.trim() !== "" && root._routeCheck.error !== ""
        }
        PrivilegedMark {
            need: root.need
        }
        SmallButton {
            objectName: "tailscaleOfferRoute"
            label: "Offer"
            available: root._free && _route.text.trim() !== "" && root._routeCheck.error === ""
            onClicked: {
                if (root.client.addRoute(_route.text))
                    _route.text = "";
            }
        }
    }
    Text {
        textFormat: Text.PlainText
        visible: _route.text.trim() !== "" && text !== ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: root._routeCheck.error !== "" ? root._routeCheck.error : root._routeCheck.warning
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.warning
    }
    RowLayout {
        visible: (root.sharing?.pendingCount ?? 0) > 0 && (root.sharing?.adminUrl ?? "") !== ""
        Layout.fillWidth: true
        spacing: 8
        Hint {
            Layout.fillWidth: true
            text: "An admin of the tailnet approves what is offered, in the admin console."
        }
        SmallButton {
            objectName: "tailscaleApproveInConsole"
            label: "Open the admin console"
            onClicked: root.client.openUrl(root.sharing.adminUrl)
        }
    }

    // ── IP forwarding (read from /proc; the module changes no sysctl) ──
    ColumnLayout {
        objectName: "tailscaleForwardingWarning"
        visible: root._warning !== null
        Layout.fillWidth: true
        spacing: 2
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root._warning?.text ?? ""
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.warning
        }
        Text {
            textFormat: Text.PlainText
            visible: text !== "" && text !== root._warning?.text
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: (root._warning?.tailscaleSays ?? "") !== "" ? "Tailscale says: " + root._warning.tailscaleSays : ""
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textMuted
        }
        Hint {
            text: root.client?.updateManagedBySystem ? "To turn it on, in the NixOS configuration:" : "To turn it on, as sysctl settings:"
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            TextEdit {
                Layout.fillWidth: true
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                textFormat: TextEdit.PlainText
                text: root._forwardingLines
                font.family: "monospace"
                font.pixelSize: Api.theme.fontSizeSmall
                color: Api.theme.textSecondary
                selectionColor: Api.theme.selection
                selectedTextColor: Api.theme.selectedText
            }
            SmallButton {
                label: "Copy"
                onClicked: Api.copy(root._forwardingLines)
            }
        }
    }

    // ── The web interface ──
    SwitchRow {
        Layout.topMargin: 6
        label: "Web interface"
        hint: "Devices of the tailnet can view this computer's Tailscale settings on port " + TailscaleRules.webClientPort + " and, after logging in, change them"
        checked: root.sharing?.webClient === true
        need: root.need
        onToggled: root._free && root.client.setSwitch("webClient", !checked)
    }
    RowLayout {
        visible: (root.sharing?.webClientUrl ?? "") !== ""
        Layout.fillWidth: true
        spacing: 6
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: root.sharing?.webClientUrl ?? ""
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textSecondary
        }
        SmallButton {
            label: "Open"
            onClicked: root.client.openUrl(root.sharing.webClientUrl)
        }
        SmallButton {
            label: "Copy"
            onClicked: Api.copy(root.sharing.webClientUrl)
        }
    }

    // ── More (collapsed) ──
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: "More: app connector, NAT, filtering, peer relay, posture, tags"
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textMuted
        }
        SmallButton {
            objectName: "tailscaleSharingMore"
            label: root._moreOpen ? "Hide" : "Show"
            onClicked: root._moreOpen = !root._moreOpen
        }
    }
    ColumnLayout {
        objectName: "tailscaleSharingAdvanced"
        visible: root._moreOpen
        Layout.fillWidth: true
        spacing: 4
        SwitchRow {
            label: "App connector"
            hint: "Carries traffic for the domains the tailnet's admin assigns to it"
            checked: root.sharing?.connector === true
            need: root.need
            onToggled: root._free && root.client.setSwitch("connector", !checked)
        }
        SwitchRow {
            label: "Source NAT for offered networks"
            hint: root.sharing?.exitNode.offered ? "Off breaks the exit node: its traffic needs it" : "On: devices in those networks see this computer as the sender"
            checked: root.sharing?.snat !== false
            need: root.need
            onToggled: root._free && root.client.setSwitch("snat", !checked)
        }
        SwitchRow {
            label: "Stateful filtering"
            hint: "Forwarded packets only for connections started from the tailnet side" + (root.sharing?.statefulFiltering === null ? " (not set: Tailscale's default)" : "")
            checked: root.sharing?.statefulFiltering === true
            need: root.need
            onToggled: root._free && root.client.setSwitch("statefulFiltering", !checked)
        }
        DetailRow {
            label: "Peer relay"
            value: root.sharing ? (root.sharing.relayServerPort === null ? "off" : (root.sharing.relayServerPort === 0 ? "on, any free UDP port" : "on, UDP port " + root.sharing.relayServerPort)) : ""
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            InputField {
                id: _relayPort
                Layout.fillWidth: true
                placeholder: "UDP port for relaying (0: any free port)"
                problem: TailscaleRules.relayPortProblem(text.trim()) !== ""
            }
            PrivilegedMark {
                need: root.need
            }
            SmallButton {
                label: "Relay"
                available: root._free && _relayPort.text.trim() !== "" && !_relayPort.problem
                onClicked: root.client.setRelayServerPort(_relayPort.text)
            }
            SmallButton {
                visible: root.sharing?.relayServerPort !== null && root.sharing?.relayServerPort !== undefined
                label: "Turn off"
                available: root._free
                onClicked: root.client.setRelayServerPort("")
            }
        }
        Hint {
            text: "Other devices may relay their connections through this one; the tailnet's policy must allow it."
        }
        SwitchRow {
            label: "Report device posture"
            hint: "The tailnet's admin may collect this device's posture information"
            checked: root.sharing?.postureChecking === true
            need: root.need
            onToggled: root._free && root.client.setSwitch("posture", !checked)
        }
        DetailRow {
            label: "Netfilter mode"
            value: root.sharing?.netfilterMode ?? ""
        }
        DetailRow {
            label: "Tags"
            value: root.sharing ? ((root.sharing.tagsApplied.length > 0 ? root.sharing.tagsApplied.join(", ") : "none")
                + (root.sharing.tagsRequested.join(",") !== root.sharing.tagsApplied.join(",") && root.sharing.tagsRequested.length > 0
                    ? " (asked for: " + root.sharing.tagsRequested.join(", ") + ")" : "")) : ""
        }
        Hint {
            text: "Tags and the netfilter mode are not changed here: tags only with `tailscale up --advertise-tags`, which logs in again."
        }
    }
}
