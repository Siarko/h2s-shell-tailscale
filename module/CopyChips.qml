import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// Texts to copy with a click (addresses, a MagicDNS name): each a small chip that says
// "Copied" after the click — the device rows' and the page's "This device". Shown as plain
// text: they come from the tailnet.
Flow {
    id: root

    // [string]
    property var texts: []
    property string _copied: ""

    spacing: 6

    Repeater {
        model: ScriptModel {
            values: (root.texts ?? []).filter(text => typeof text === "string" && text !== "").map(text => ({ text: text }))
            objectProp: "text"
        }
        Rectangle {
            required property var modelData
            implicitWidth: _label.implicitWidth + 10
            implicitHeight: _label.implicitHeight + 4
            radius: Api.theme.row.radius
            color: _copyArea.lit ? Api.theme.surfaceHover : Api.theme.surfaceSunken
            Text {
                id: _label
                textFormat: Text.PlainText
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
