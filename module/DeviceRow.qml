import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// One device of the tailnet on the page's list (TailscaleRules.peers' entry): its name, owner
// and system, online or last seen, how traffic goes (direct, relayed), its addresses with
// copy, its traffic while the page is open, a mark when it can be an exit node, and "Ping"
// (one Tailscale ping: direct or relayed, the time)
Rectangle {
    id: root

    property var device: null
    // Show the bytes (the page watches: the counters are re-read)
    property bool showTraffic: false
    // TailscaleClient, for "Ping" (null: no button)
    property var client: null
    readonly property var _ping: client && device ? (client.pings[device.id] ?? null) : null

    implicitHeight: _column.implicitHeight + 12
    radius: Api.theme.row.radius
    color: Api.theme.surface

    readonly property string _connection: ({ direct: "direct", relayed: "relayed (DERP)", "peer-relay": "via a peer relay",
        idle: "idle", offline: "" })[device?.connection ?? "offline"] ?? ""

    ColumnLayout {
        id: _column
        x: Api.theme.row.horizontalPadding
        y: 6
        width: root.width - 2 * Api.theme.row.horizontalPadding
        spacing: 2

        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Rectangle {
                implicitWidth: 8
                implicitHeight: 8
                radius: 4
                color: root.device?.online ? Api.theme.success : Api.theme.textDisabled
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.device?.name ?? ""
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeBody
                color: root.device?.online ? Api.theme.textPrimary : Api.theme.textMuted
            }
            Text {
                textFormat: Text.PlainText
                visible: root.device?.exitNodeOption === true
                text: root.device?.isExitNode ? "exit node in use" : "exit node"
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeXSmall
                color: root.device?.isExitNode ? Api.theme.accent : Api.theme.textMuted
            }
            Text {
                textFormat: Text.PlainText
                objectName: "tailscalePingResult"
                visible: root._ping !== null
                text: "ping: " + (root._ping?.text ?? "")
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeXSmall
                color: root._ping?.ok === false && root._ping?.running === false ? Api.theme.warning : Api.theme.textSecondary
            }
            Text {
                textFormat: Text.PlainText
                text: root.device?.online ? (root._connection || "online") : ("last seen " + (root.device?.lastSeenText ?? "never"))
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeXSmall
                color: root.device?.connection === "relayed" ? Api.theme.warning : Api.theme.textMuted
            }
            // Taildrop (the operator's): this device as the target, then the shell's file chooser
            SmallButton {
                objectName: "taildropDeviceSend"
                visible: root.client !== null && TailscaleWidgetRules.canSendTo(root.device, root.client.view?.phase, root.client.taildrop?.isOperator)
                label: "Send file…"
                fontSize: Api.theme.fontSizeXSmall
                onClicked: root.client.taildrop.chooseFor(root.device.id)
            }
            // `tailscale ping --c=1 --timeout=3s`: how a packet gets there now (direct or relayed)
            SmallButton {
                objectName: "tailscalePing"
                visible: root.client !== null && root.device?.online === true
                label: "Ping"
                fontSize: Api.theme.fontSizeXSmall
                available: !(root._ping?.running ?? false)
                onClicked: root.client.ping(root.device)
            }
        }
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: [root.device?.owner || (root.device?.tags ?? []).join(", "), root.device?.os ?? "", root.device?.sharedIn ? "shared in" : "",
                   root.device?.keyExpired ? "key expired" : ""].filter(part => part !== "").join(" · ")
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: root.device?.keyExpired ? Api.theme.warning : Api.theme.textMuted
        }
        CopyChips {
            Layout.fillWidth: true
            // A device that runs Tailscale SSH: its ssh command to copy (TailscaleRules.sshCommand)
            texts: (root.device?.addresses ?? []).concat(root.device?.dnsName ? [root.device.dnsName] : [],
                (root.device?.sshCommand ?? "") !== "" ? [{ label: "Copy ssh command", text: root.device.sshCommand }] : [])
        }
        Text {
            textFormat: Text.PlainText
            visible: root.showTraffic && root.device !== null && (root.device.rxBytes > 0 || root.device.txBytes > 0)
            text: "Received " + Api.format.bytes(root.device?.rxBytes ?? 0) + " · sent " + Api.format.bytes(root.device?.txBytes ?? 0)
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeXSmall
            color: Api.theme.textMuted
        }
    }
}
