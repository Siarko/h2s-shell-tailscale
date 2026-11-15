import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// One device of the tailnet on the page's list (TailscaleRules.peers' entry): its name, owner
// and system, online or last seen, how traffic goes (direct, relayed), its addresses with
// copy, its traffic while the page is open, and a mark when it can be an exit node
Rectangle {
    id: root

    property var device: null
    // Show the bytes (the page watches: the counters are re-read)
    property bool showTraffic: false
    property string _copied: ""

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
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.device?.name ?? ""
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeBody
                color: root.device?.online ? Api.theme.textPrimary : Api.theme.textMuted
            }
            Text {
                visible: root.device?.exitNodeOption === true
                text: root.device?.isExitNode ? "exit node in use" : "exit node"
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeXSmall
                color: root.device?.isExitNode ? Api.theme.accent : Api.theme.textMuted
            }
            Text {
                text: root.device?.online ? (root._connection || "online") : ("last seen " + (root.device?.lastSeenText ?? "never"))
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeXSmall
                color: root.device?.connection === "relayed" ? Api.theme.warning : Api.theme.textMuted
            }
        }
        Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: [root.device?.owner || (root.device?.tags ?? []).join(", "), root.device?.os ?? "", root.device?.sharedIn ? "shared in" : "",
                   root.device?.keyExpired ? "key expired" : ""].filter(part => part !== "").join(" · ")
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: root.device?.keyExpired ? Api.theme.warning : Api.theme.textMuted
        }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: ScriptModel {
                    values: (root.device?.addresses ?? []).concat(root.device?.dnsName ? [root.device.dnsName] : []).map(text => ({ text: text }))
                    objectProp: "text"
                }
                Rectangle {
                    required property var modelData
                    implicitWidth: _address.implicitWidth + 10
                    implicitHeight: _address.implicitHeight + 4
                    radius: Api.theme.row.radius
                    color: _copyArea.lit ? Api.theme.surfaceHover : Api.theme.surfaceSunken
                    Text {
                        id: _address
                        anchors.centerIn: parent
                        text: root._copied === parent.modelData.text ? "Copied" : parent.modelData.text
                        font.family: Api.theme.fontFamily
                        font.pixelSize: Api.theme.fontSizeXSmall
                        color: Api.theme.textSecondary
                    }
                    PointerArea {
                        id: _copyArea
                        anchors.fill: parent
                        centred: false
                        onClicked: {
                            Api.copy(parent.modelData.text);
                            root._copied = parent.modelData.text;
                        }
                    }
                }
            }
        }
        Text {
            visible: root.showTraffic && root.device !== null && (root.device.rxBytes > 0 || root.device.txBytes > 0)
            text: "Received " + TailscaleRules.bytes(root.device?.rxBytes ?? 0) + " · sent " + TailscaleRules.bytes(root.device?.txBytes ?? 0)
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeXSmall
            color: Api.theme.textMuted
        }
    }
}
