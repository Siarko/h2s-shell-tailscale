import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// The page's "Serve" (delivery step 5), collapsed until opened: what this computer shares with
// the tailnet or, with Funnel, the internet (ServeClient, ServeRules); add a local port, a TCP
// forward, Funnel per entry, remove one, stop all. Files and folders are listed, never added
// (tailscaled would read them as root). The config is read when the section is opened on screen.
ColumnLayout {
    id: root

    property var client: null
    property string need: ""
    property bool shown: false

    readonly property var serve: client?.serve ?? null
    readonly property var ready: serve?.ready ?? null
    readonly property bool _free: client !== null && !client.busy
    property bool open: false
    property string _kind: "proxy"
    property int _port: 443
    property bool _funnel: false

    visible: client !== null && client.cli === "present" && client.prefs !== null
    Layout.fillWidth: true
    spacing: 4

    onOpenChanged: _maybeRead()
    onShownChanged: _maybeRead()
    function _maybeRead() {
        if (open && shown)
            serve?.read();
    }

    RowLayout {
        Layout.topMargin: 16
        Layout.fillWidth: true
        spacing: 8
        SectionTitle {
            Layout.topMargin: 0
            Layout.bottomMargin: 0
            Layout.fillWidth: true
            text: "Serve" + ((root.serve?.entries.length ?? 0) > 0 ? " (" + root.serve.entries.length + ")" : "")
        }
        SmallButton {
            objectName: "tailscaleServeToggle"
            label: root.open ? "Hide" : "Show"
            onClicked: root.open = !root.open
        }
    }

    ColumnLayout {
        objectName: "tailscaleServe"
        visible: root.open
        Layout.fillWidth: true
        spacing: 4

        // What is missing, each with where it is fixed
        Repeater {
            model: ScriptModel {
                values: (root.ready?.problems ?? []).concat(root.ready?.connected && root.ready?.https ? root.ready.funnelProblems : [])
                objectProp: "kind"
            }
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    text: parent.modelData.text
                    font.family: Api.theme.fontFamily
                    font.pixelSize: Api.theme.fontSizeSmall
                    color: Api.theme.warning
                }
                SmallButton {
                    visible: parent.modelData.url !== ""
                    label: "Admin console"
                    onClicked: root.client.openUrl(parent.modelData.url)
                }
            }
        }

        Hint {
            visible: root.serve?.config !== null && (root.serve?.entries.length ?? 0) === 0
            text: "Nothing shared"
        }

        Repeater {
            model: ScriptModel {
                values: root.serve?.entries ?? []
                objectProp: "key"
            }
            ColumnLayout {
                id: _entry
                required property var modelData
                objectName: "tailscaleServeEntry"
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: _entry.modelData.type.toUpperCase() + " " + _entry.modelData.port + (_entry.modelData.mount && _entry.modelData.mount !== "/" ? " " + _entry.modelData.mount : "")
                            + " → " + ServeRules.targetLabel(_entry.modelData)
                        font.family: Api.theme.fontFamily
                        font.pixelSize: Api.theme.fontSizeBody
                        color: Api.theme.textPrimary
                    }
                    Text {
                        objectName: "tailscaleServePublic"
                        visible: _entry.modelData.funnel
                        textFormat: Text.PlainText
                        text: "Public"
                        font.family: Api.theme.fontFamily
                        font.pixelSize: Api.theme.fontSizeSmall
                        font.bold: true
                        color: Api.theme.warning
                    }
                    SmallButton {
                        visible: _entry.modelData.type === "https"
                        label: _entry.modelData.funnel ? "Funnel off" : "Funnel on"
                        tooltip: _entry.modelData.funnel ? "" : "Public on the internet"
                        available: root._free && (_entry.modelData.funnel || (root.ready?.canFunnel ?? false))
                        onClicked: root.serve.setFunnel(_entry.modelData.key, !_entry.modelData.funnel)
                    }
                    PrivilegedMark {
                        visible: root.need !== ""
                        need: root.need
                    }
                    DeleteButton {
                        label: "Remove"
                        confirmLabel: "Remove?"
                        available: root._free
                        onConfirmed: root.serve.remove(_entry.modelData.key)
                    }
                }
                CopyChips {
                    Layout.fillWidth: true
                    texts: _entry.modelData.urls
                }
            }
        }

        Hint {
            visible: (root.serve?.config?.foreground ?? 0) > 0 || (root.serve?.config?.services ?? 0) > 0
            text: "More is shared from a terminal or as a service"
        }

        // Adding
        RowLayout {
            Layout.topMargin: 8
            Layout.fillWidth: true
            spacing: 8
            Dropdown {
                objectName: "tailscaleServeKind"
                Layout.preferredWidth: 110
                options: [{ value: "proxy", label: "HTTPS" }, { value: "tcp", label: "TCP" }]
                value: root._kind
                onPicked: value => root._kind = value
            }
            Dropdown {
                visible: root._kind === "proxy"
                Layout.preferredWidth: 90
                options: ServeRules.httpsPorts.map(port => ({ value: port, label: String(port) }))
                value: root._port
                onPicked: value => root._port = value
            }
            InputField {
                id: _listen
                visible: root._kind === "tcp"
                Layout.preferredWidth: 90
                placeholder: "Port"
            }
            InputField {
                id: _local
                objectName: "tailscaleServeLocalPort"
                Layout.preferredWidth: 110
                placeholder: "Local port"
            }
            InputField {
                id: _path
                visible: root._kind === "proxy"
                Layout.fillWidth: true
                placeholder: "Path (optional)"
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Checkbox {
                visible: root._kind === "proxy"
                label: "Funnel"
                checked: root._funnel
                enabled: root.ready?.canFunnel ?? false
                onToggled: root._funnel = !root._funnel
            }
            Item { Layout.fillWidth: true }
            SmallButton {
                objectName: "tailscaleServeAdd"
                label: "Share"
                available: root._free && (root.ready?.connected ?? false) && ServeRules.localPort(_local.text) > 0
                onClicked: root.serve.add(root._kind === "tcp"
                    ? { kind: "tcp", port: ServeRules.localPort(_listen.text), localPort: _local.text }
                    : { kind: "proxy", port: root._port, localPort: _local.text, path: _path.text, funnel: root._funnel })
            }
            PrivilegedMark {
                visible: root.need !== ""
                need: root.need
            }
        }
        Hint {
            visible: root._funnel && root._kind === "proxy"
            text: "Public on the internet"
        }
        Text {
            objectName: "tailscaleServeMessage"
            visible: text !== ""
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.serve?.message || root.serve?.readError || ""
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.warning
        }
        RowLayout {
            visible: (root.serve?.entries.length ?? 0) > 0
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            DeleteButton {
                label: "Stop all"
                confirmLabel: "Stop all?"
                available: root._free
                onConfirmed: root.serve.reset()
            }
        }
    }
}
