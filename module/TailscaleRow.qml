import QtQuick
import QtQuick.Layouts
import qs.api
import qs.components

// Slot network.vpn.row: under Tailscale's row in the network popup — the exit-node chooser
// while connected, and the login link to copy while a login waits for the browser
ColumnLayout {
    id: root
    objectName: "tailscaleRowExtras"

    property var module: null
    // { slot, vpnId, entryId, vpn, provider, otherVpnsUp } (VpnManager.contextFor)
    property var context: null
    readonly property var client: context?.provider?.client ?? Tailscale.client
    // Conditions as properties: a child's `visible` reads false while its parent is hidden
    readonly property bool _choosing: client !== null && client.view.phase === "running" && client.exitNodes.count > 0
    readonly property bool _loggingIn: client !== null && client.authUrl !== ""

    spacing: 2
    visible: _choosing || _loggingIn

    ExitNodeChooser {
        Layout.fillWidth: true
        client: root.client
        collapsible: true
        visible: root._choosing
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Api.theme.row.horizontalPadding
        visible: root._loggingIn
        spacing: 6
        Text {
            Layout.fillWidth: true
            elide: Text.ElideMiddle
            text: "Log in at " + (root.client?.authUrl ?? "")
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textMuted
        }
        SmallButton {
            label: "Copy link"
            fontSize: Api.theme.fontSizeSmall
            onClicked: Api.copy(root.client.authUrl)
        }
        SmallButton {
            label: "Cancel"
            kind: "cancel"
            fontSize: Api.theme.fontSizeSmall
            onClicked: root.client.cancelLogin()
        }
    }
}
