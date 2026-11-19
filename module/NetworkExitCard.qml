import QtQuick
import QtQuick.Layouts
import qs.api

// The exit node for one saved network, in its opened card (the anchors
// settings.network_wifi.saved.card.settings and settings.network_ethernet.profiles.card.settings,
// module API 1.24): not set, no exit node, automatic, or one of this tailnet's exit nodes. The
// module sets it when the network connects (NetworkExitClient); only as the operator, an
// automatic change never asks for a password. The card's context names the network
// ({ networkId, name, kind, active }).
ColumnLayout {
    id: root
    objectName: "tailscaleNetworkExit"

    property var module: null
    property var context: null

    readonly property var client: module?.main?.client ?? null
    readonly property var exit: client?.networkExit ?? null
    readonly property string networkId: String(context?.networkId ?? "")
    readonly property var row: NetworkExitRules.rowFor(exit?.table ?? ({}), networkId)
    readonly property var options: NetworkExitRules.cardOptions(client?.exitNodes?.own ?? [], row)
    // Why this network's choice is not applied now, in the module's plain words (the last
    // decision, when it is about the networks up with this one among them)
    readonly property string problem: {
        const decision = exit?.decision ?? null;
        if (!decision || !["conflict", "unavailable", "refused", "failed"].includes(decision.kind ?? ""))
            return "";
        return String(decision.key ?? "").split(" ").includes(networkId) ? String(decision.text ?? "") : "";
    }

    // Tailscale not installed and nothing set for the network: nothing to choose from
    visible: exit !== null && NetworkExitRules.validId(networkId) && (client.cli === "present" || row !== null)
    Layout.fillWidth: true
    spacing: 4

    SettingsRow {
        label: "Tailscale exit node"
        hint: "Used when this network connects"

        Dropdown {
            objectName: "tailscaleNetworkExitChoice"
            options: root.options
            value: root.row?.choice ?? ""
            onPicked: value => {
                const option = root.options.find(item => item.value === value) ?? null;
                root.exit.setChoice(root.networkId, value === "" ? null : value, option?.name ?? "", String(root.context?.name ?? ""));
            }
        }
    }
    Hint {
        visible: root.row !== null && root.client !== null && !root.client.canChange
        text: "Needs the operator"
    }
    Text {
        objectName: "tailscaleNetworkExitProblem"
        visible: text !== ""
        Layout.fillWidth: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: root.problem
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.warning
    }
}
