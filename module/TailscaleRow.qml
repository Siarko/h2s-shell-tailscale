import QtQuick
import QtQuick.Layouts
import qs.api

// At popup.network.connections.vpn.row ("after", own-provider; module API 1.23): under
// Tailscale's row in the network popup — the exit-node chooser while connected, and the login
// link to copy while a login waits for the browser
ColumnLayout {
    id: root
    objectName: "tailscaleRowExtras"

    property var module: null
    // { anchor, placement, vpnId, entryId, vpn, provider, otherVpnsUp, otherVpns } (the place's)
    property var context: null
    // The live client: the module's main's (module API 1.15), null while the module is off
    readonly property var client: module?.main?.client ?? null
    // Conditions as properties: a child's `visible` reads false while its parent is hidden
    readonly property bool _choosing: client !== null && client.view.phase === "running" && client.exitNodes.count > 0
    readonly property bool _loggingIn: client !== null && client.authUrl !== ""

    spacing: 2
    visible: _choosing || _loggingIn

    // Made each time the network popup opens: Tailscale may have been installed or started
    // since the last look (the client looks only while something is missing)
    onClientChanged: _wake()
    Component.onCompleted: _wake()
    function _wake() {
        if (typeof client?.wake === "function")
            client.wake();
    }

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
            textFormat: Text.PlainText
            Layout.fillWidth: true
            elide: Text.ElideMiddle
            text: "Log in at " + (root.client?.authUrl ?? "")
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.textMuted
        }
        SmallButton {
            label: "Copy link"
            size: "s"
            onClicked: Api.copy(root.client.authUrl)
        }
        SmallButton {
            label: "Cancel"
            kind: "secondary"
            size: "s"
            onClicked: root.client.cancelLogin()
        }
    }
}
