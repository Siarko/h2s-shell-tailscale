import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// Inside the page's "Exit node" (delivery step 5): "Network → exit node", set by the module
// when the marked networks that are up change (NetworkExitClient). Only for the operator: an
// automatic change never asks for a password.
ColumnLayout {
    id: root

    property var client: null

    readonly property var exit: client?.networkExit ?? null
    readonly property var networks: exit?.networks ?? []
    readonly property var _choices: [{ value: "none", label: "No exit node" }, { value: "auto", label: "Automatic" }]
        .concat((client?.exitNodes?.own ?? []).map(option => ({ value: option.id, label: option.name })))
    property string _network: ""

    visible: client !== null && client.prefs !== null && (networks.length > 0 || (exit?.rows.length ?? 0) > 0)
    Layout.fillWidth: true
    spacing: 4

    Text {
        Layout.topMargin: 8
        textFormat: Text.PlainText
        text: "By network"
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeBody
        font.bold: true
        color: Api.theme.textPrimary
    }
    Hint {
        visible: root.client !== null && !root.client.canChange
        text: "Needs the operator"
    }
    Repeater {
        model: ScriptModel {
            values: root.exit?.rows ?? []
            objectProp: "id"
        }
        RowLayout {
            id: _row
            required property var modelData
            readonly property var network: root.networks.find(item => item.id === modelData.id) ?? null
            Layout.fillWidth: true
            spacing: 8
            Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: (_row.network?.name || _row.modelData.name || _row.modelData.id) + (_row.network?.active ? " · up" : "")
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeBody
                color: Api.theme.textPrimary
            }
            Dropdown {
                Layout.preferredWidth: 180
                options: root._choices.some(option => option.value === _row.modelData.choice) ? root._choices
                    : root._choices.concat([{ value: _row.modelData.choice, label: NetworkExitRules.choiceLabel(_row.modelData) }])
                value: _row.modelData.choice
                onPicked: value => root.exit.setChoice(_row.modelData.id, value, root._choices.find(option => option.value === value)?.label ?? "",
                                                       _row.network?.name ?? _row.modelData.name)
            }
            DeleteButton {
                label: "Remove"
                confirmLabel: "Remove?"
                onConfirmed: root.exit.removeNetwork(_row.modelData.id)
            }
        }
    }
    RowLayout {
        readonly property var _unmarked: root.networks.filter(network => !(root.exit?.rows ?? []).some(row => row.id === network.id))
        visible: _unmarked.length > 0
        Layout.fillWidth: true
        spacing: 8
        Dropdown {
            Layout.fillWidth: true
            placeholder: "Add a network"
            options: parent._unmarked.map(network => ({ value: network.id, label: network.name + (network.active ? " · up" : "") }))
            value: root._network
            onPicked: value => root._network = value
        }
        SmallButton {
            label: "Add"
            available: root._network !== ""
            onClicked: {
                const network = root.networks.find(item => item.id === root._network);
                root.exit.setChoice(root._network, "none", "", network?.name ?? "");
                root._network = "";
            }
        }
    }
    Text {
        visible: text !== ""
        Layout.fillWidth: true
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: ["conflict", "unavailable", "refused", "failed"].includes(root.exit?.decision?.kind ?? "") ? (root.exit.decision.text ?? "") : ""
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.warning
    }
}
