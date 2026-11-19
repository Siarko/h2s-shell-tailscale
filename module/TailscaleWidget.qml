import QtQuick
import qs.api
import qs.components

// Tailscale's bar widget (step 6): one glyph coloured by the client's state the way the
// network widget colours its links (dim: nothing to use; plain: off; accent: connected; the
// warning colour: something needs the user), a small globe beside it while an exit node
// carries the internet traffic, a badge while received Taildrop files wait, and optionally a
// short text (its preset: none, the state, the exit node's name). A click opens its popup
// (TailscalePopup), which the shell tells this entry's preset (its `opener`). It renders the
// live client's state (the module's main's: module.main?.client) and runs nothing:
// no timer, no process. Not on the bar by default — added in Settings → Bar like any widget.
PopupWidget {
    id: root
    objectName: "tailscaleWidget"
    widgetType: "tailscale"

    // Set by the bar: the module's handle, the bar entry's preset (the shell hands it to the
    // popup too, module API 1.15)
    property var module: null
    property string preset: ""

    // The live client (a test gives its own)
    property var client: module?.main?.client ?? null
    readonly property var summary: TailscaleWidgetRules.summaryOf(client)
    // Its preset's keys (module API 1.3: module.presetValue); on an older shell the defaults
    readonly property bool _presets: typeof module?.presetValue === "function"
    function _preset(key, fallback) {
        const value = _presets ? module.presetValue(widgetType, preset, key) : undefined;
        return value === undefined || value === null ? fallback : value;
    }
    readonly property string textMode: TailscaleWidgetRules.textMode(_preset("text", "none"))
    readonly property string barText: TailscaleWidgetRules.barText(summary, textMode, 16)
    readonly property var badge: TailscaleWidgetRules.badge(client?.taildrop?.waitingCount ?? 0, client?.taildrop?.busWaiting ?? false,
                                                            _preset("badge", true) !== false)

    function _tone(tone) {
        return tone === "accent" || tone === "pending" ? Api.theme.accent : tone === "warning" ? Api.theme.warning
            : tone === "primary" ? Api.theme.textPrimary : Api.theme.textDisabled;
    }

    BarRow {
        anchors.centerIn: parent
        spacing: 4

        Item {
            id: _iconBox
            implicitWidth: _icon.implicitWidth + (_mark.visible ? _mark.implicitWidth - 2 : 0)
            implicitHeight: _icon.implicitHeight

            Text {
                id: _icon
                objectName: "tailscaleWidgetIcon"
                text: TailscaleWidgetRules.glyph
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeHeading
                color: root._tone(root.summary.tone)
                // A change in progress: the accent, dimmed
                opacity: root.summary.tone === "pending" ? 0.55 : 1
                Behavior on color { ColorAnimation { duration: Api.theme.duration("state"); easing: Api.theme.curve("state") } }
            }
            // An exit node in use: a small globe at the glyph's lower right
            Text {
                id: _mark
                objectName: "tailscaleWidgetExitMark"
                visible: root.summary.mark
                x: _icon.implicitWidth - 2
                y: _icon.implicitHeight - implicitHeight + 1
                text: TailscaleWidgetRules.exitNodeMark
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: root._tone(root.summary.tone)
            }
            // Received files waiting (Taildrop): a count, or a dot when the count is not known
            Rectangle {
                objectName: "tailscaleWidgetBadge"
                visible: root.badge.shown
                x: _icon.implicitWidth - width / 2 - 1
                y: -height / 3
                height: root.badge.text === "" ? 7 : Math.max(12, _badgeText.implicitHeight)
                width: root.badge.text === "" ? 7 : Math.max(height, _badgeText.implicitWidth + 6)
                radius: height / 2
                color: Api.theme.accent
                Text {
                    id: _badgeText
                    anchors.centerIn: parent
                    text: root.badge.text
                    font.family: Api.theme.fontFamily
                    font.pixelSize: Math.round(Api.theme.fontSizeSmall * 0.85)
                    font.bold: true
                    color: Api.theme.onAccent
                }
            }
        }

        BarText {
            objectName: "tailscaleWidgetText"
            visible: root.barText !== ""
            text: root.barText
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeBodyLarge
            color: root._tone(root.summary.tone === "disabled" ? "disabled" : root.summary.tone === "warning" ? "warning" : "primary")
        }
    }

}
