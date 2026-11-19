import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api

// The bar widget's preset (the bar section editor's settings pane): the text beside the
// icon, the Taildrop badge, how many devices the popup lists. Read and written through the
// module's handle (module API 1.3: presetValue / setPresetValue — WidgetPresets, with the
// manifest's presetDefaults).
Item {
    id: root
    objectName: "tailscaleWidgetSettings"

    property var module: null
    property string presetName: ""
    property string widgetType: "tailscale"

    implicitHeight: _column.implicitHeight

    function _value(key, fallback) {
        const value = module?.presetValue(widgetType, presetName, key);
        return value === undefined || value === null ? fallback : value;
    }
    function _set(key, value) {
        if (presetName !== "")
            module?.setPresetValue(widgetType, presetName, key, value);
    }
    readonly property string _text: TailscaleWidgetRules.textMode(_value("text", "none"))
    readonly property bool _badge: _value("badge", true) !== false
    readonly property int _devices: TailscaleWidgetRules.deviceCap(_value("devices", TailscaleWidgetRules.defaultDeviceCap))

    component Label: Text {
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeBody
        color: Api.theme.textSecondary
        Layout.preferredWidth: 80
        elide: Text.ElideRight
    }

    ColumnLayout {
        id: _column
        width: parent.width
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 8
            Label { text: "Text" }
            Flow {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: ScriptModel {
                        values: [{ value: "none", label: "None" }, { value: "state", label: "State" }, { value: "exitNode", label: "Exit node" }]
                    }
                    Pill {
                        required property var modelData
                        objectName: "tailscaleWidgetText-" + modelData.value
                        label: modelData.label
                        picked: modelData.value === root._text
                        size: "m"
                        textSize: "body"
                        onClicked: root._set("text", modelData.value)
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Label { text: "Badge" }
            Text {
                Layout.fillWidth: true
                text: "Files received"
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: Api.theme.textMuted
            }
            ToggleSwitch {
                objectName: "tailscaleWidgetBadgeSwitch"
                checked: root._badge
                onToggled: root._set("badge", !root._badge)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Label { text: "Devices" }
            Flow {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: ScriptModel {
                        values: TailscaleWidgetRules.deviceCaps
                    }
                    Pill {
                        required property var modelData
                        objectName: "tailscaleWidgetDevices-" + modelData
                        label: String(modelData)
                        picked: modelData === root._devices
                        size: "m"
                        textSize: "body"
                        onClicked: root._set("devices", modelData)
                    }
                }
            }
        }
    }
}
