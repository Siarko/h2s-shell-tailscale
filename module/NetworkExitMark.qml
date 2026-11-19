import QtQuick
import QtQuick.Controls
import qs.api

// On a saved network's name line, closed and open (the anchors
// settings.network_wifi.saved.card.title and settings.network_ethernet.profiles.card.title,
// module API 1.28): the exit-node glyph while an exit node is set for that network, its
// choice in a tooltip ("Exit node: home-server"). It takes no click: a click opens or closes
// the card, as on the name. The detail and the choice are in the opened card
// (NetworkExitCard).
Text {
    id: root
    objectName: "tailscaleNetworkExitMark"

    property var module: null
    property var context: null

    readonly property var exit: module?.main?.client?.networkExit ?? null
    readonly property var row: NetworkExitRules.rowFor(exit?.table ?? ({}), String(context?.networkId ?? ""))
    readonly property string label: NetworkExitRules.markLabel(row)

    visible: row !== null
    text: TailscaleWidgetRules.exitNodeMark
    textFormat: Text.PlainText
    verticalAlignment: Text.AlignVCenter
    font.family: Api.theme.fontFamily
    font.pixelSize: Api.theme.fontSizeBody
    // "No exit node" is a choice too, shown dimmer than a node in use
    color: row?.choice === "none" ? Api.theme.textMuted : Api.theme.textSecondary
    Accessible.name: label

    HoverHandler {
        id: _hover
    }

    ToolTip {
        id: _tip
        visible: _hover.hovered && root.label !== ""
        delay: 500
        padding: 0
        contentItem: Text {
            textFormat: Text.PlainText
            text: "Tailscale: " + root.label
            leftPadding: Api.theme.tooltip.horizontalPadding
            rightPadding: Api.theme.tooltip.horizontalPadding
            topPadding: Api.theme.tooltip.verticalPadding
            bottomPadding: Api.theme.tooltip.verticalPadding
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textPrimary
        }
        background: Rectangle {
            radius: Api.theme.tooltip.radius
            color: Api.theme.surface
            border.color: Api.theme.textDisabled
            border.width: Api.theme.border.width
        }
    }
}
