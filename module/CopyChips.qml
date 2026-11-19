import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api

// Texts to copy with a click (addresses, a MagicDNS name): each a small chip that says
// "Copied" after the click — the device rows' and the page's "This device". Shown as plain
// text: they come from the tailnet.
Flow {
    id: root

    // [string], or { label, text }: the chip shows the label and copies the text
    property var texts: []
    // The widest a chip may be: a longer label (a long MagicDNS name) is cut in the middle. Its
    // own width by default; set it where the chips do not get a width from their parent
    property real chipMaxWidth: width
    property string _copied: ""

    spacing: 6

    Repeater {
        model: ScriptModel {
            values: (root.texts ?? []).map(item => typeof item === "string" ? { text: item, label: item } : (item && typeof item.text === "string" ? { text: item.text, label: String(item.label ?? item.text) } : null))
                .filter(item => item !== null && item.text !== "")
            objectProp: "text"
        }
        Rectangle {
            required property var modelData
            implicitWidth: _label.width + 10
            implicitHeight: _label.implicitHeight + 4
            radius: Api.theme.row.radius
            color: _copyArea.lit ? Api.theme.surfaceHover : Api.theme.surfaceSunken
            Text {
                id: _label
                textFormat: Text.PlainText
                anchors.centerIn: parent
                width: Math.min(implicitWidth, Math.max(24, root.chipMaxWidth - 10))
                elide: Text.ElideMiddle
                text: root._copied === parent.modelData.text ? "Copied" : parent.modelData.label
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
