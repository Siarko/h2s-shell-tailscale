import QtQuick
import qs.api

// On a saved network's name line, closed and open (the anchors
// settings.network_wifi.saved.card.title and settings.network_ethernet.profiles.card.title,
// module API 1.28): the exit-node glyph while the network routes through an exit node (a
// node, or automatic; not "No exit node"), its choice in the shell's tooltip ("Exit node:
// home-server", HoverTip, module API 1.31). It takes no click: a click opens or closes the
// card, as on the name. The detail and the choice are in the opened card (NetworkExitCard).
Text {
    id: root
    objectName: "tailscaleNetworkExitMark"

    property var module: null
    property var context: null

    readonly property var exit: module?.main?.client?.networkExit ?? null
    readonly property var row: NetworkExitRules.rowFor(exit?.table ?? ({}), String(context?.networkId ?? ""))
    readonly property string label: NetworkExitRules.markLabel(row)

    visible: label !== ""
    text: TailscaleWidgetRules.exitNodeMark
    textFormat: Text.PlainText
    verticalAlignment: Text.AlignVCenter
    font.family: Api.theme.fontFamily
    font.pixelSize: Api.theme.fontSizeBody
    color: Api.theme.textSecondary
    Accessible.name: label

    HoverTip {
        objectName: "tailscaleNetworkExitTip"
        text: root.label !== "" ? "Tailscale: " + root.label : ""
    }
}
