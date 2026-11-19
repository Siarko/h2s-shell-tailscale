import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api

// The bar widget's popup (step 6): what one does daily. The state and Connect / Disconnect
// (or the attention's own action: Log in, Start…), the account; the exit node (the chooser
// the network popup's row uses); this device's addresses to copy; the devices, online ones
// first, capped (the widget's preset), with "Send file…" for the operator (the shell's file
// chooser, then a row under the device: Send, the send's progress, its result); received files
// waiting with Save; Settings… and the admin console. Everything is the live client's state
// and actions (the module's main's, module API 1.15: module.main?.client) — the same the page
// and the network popup's row show; built by the popup from Qt.callLater like every panel,
// gone when it closes.
Item {
    id: root
    objectName: "tailscalePopup"

    property var module: null
    // The bar widget that opened it (module API 1.15: { widgetType, preset, edge, byTouch },
    // set by the shell; null when no widget opened it)
    property var opener: null

    // The live client (a test gives its own)
    property var client: module?.main?.client ?? null
    readonly property var view: client?.view ?? null
    readonly property var entry: client?.entry ?? null
    readonly property var taildrop: client?.taildrop ?? null
    readonly property string need: client && !client.canChange ? "auth" : ""
    readonly property bool _free: client !== null && !client.busy
    readonly property bool _running: view?.phase === "running"
    readonly property bool _loggedIn: view !== null && ["running", "starting", "stopped", "needs-approval"].includes(view.phase)
    readonly property var summary: TailscaleWidgetRules.summaryOf(client)

    // The device cap of the widget that opened it (its preset; module API 1.3)
    readonly property int deviceCap: {
        const value = typeof module?.presetValue === "function" ? module.presetValue("tailscale", String(opener?.preset ?? ""), "devices") : undefined;
        return TailscaleWidgetRules.deviceCap(value);
    }
    // Past the cap too: a device with Taildrop's work in the popup (files picked, a send, its
    // result), until that is cleared
    readonly property var deviceList: TailscaleWidgetRules.deviceList(_loggedIn ? (client?.devices ?? []) : [], deviceCap, taildrop?.popupKept ?? [])

    implicitWidth: Api.theme.popupWidth("tailscale", 320)
    // The most height the panel may take before it must scroll (module API 1.15, kept current
    // by the shell); past it the panel scrolls — 20 devices and an open exit-node chooser still
    // fit a small screen
    property real availableHeight: Infinity
    implicitHeight: Math.min(_column.implicitHeight, availableHeight)

    // Repeaters built after the panel itself (a second line of defence: "The Repeater crash")
    property bool _ready: false
    Component.onCompleted: {
        Qt.callLater(() => root._ready = true);
        // Opened: Tailscale may have been installed or started since the last look
        if (typeof client?.wake === "function")
            client.wake();
    }

    component SectionLabel: Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        Layout.topMargin: 4
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeBody
        color: Api.theme.textSecondary
    }
    component Line: Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        font.family: Api.theme.fontFamily
        font.pixelSize: Api.theme.fontSizeSmall
        color: Api.theme.textMuted
    }

    Flickable {
        id: _scroll
        objectName: "tailscalePopupScroll"
        anchors.fill: parent
        contentWidth: width
        contentHeight: _column.implicitHeight
        clip: contentHeight > height
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: _column
            width: _scroll.width
            spacing: 6

            // ── Header: the state, the switch ──
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: TailscaleWidgetRules.glyph
                    font.family: Api.theme.fontFamily
                    font.pixelSize: Api.theme.fontSizeTitle
                    color: root.summary.tone === "accent" || root.summary.tone === "pending" ? Api.theme.accent
                        : root.summary.tone === "warning" ? Api.theme.warning
                        : root.summary.tone === "primary" ? Api.theme.textPrimary : Api.theme.textDisabled
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        text: "Tailscale"
                        font.family: Api.theme.fontFamily
                        font.pixelSize: Api.theme.fontSizeSection
                        color: Api.theme.textPrimary
                    }
                    Text {
                        objectName: "tailscalePopupStatus"
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        // The entry's own line (as the network popup's row); without a client, why
                        text: root.client === null ? "Not available" : (root.entry?.status || root.summary.word || "")
                        font.family: Api.theme.fontFamily
                        font.pixelSize: Api.theme.fontSizeSmall
                        color: root.summary.tone === "accent" ? Api.theme.accent : root.summary.tone === "warning" ? Api.theme.warning : Api.theme.textMuted
                    }
                }
                PrivilegedMark {
                    objectName: "tailscalePopupMark"
                    // Beside the buttons only: with none of them shown, nothing to mark (the mark hides itself)
                    need: _connect.visible || _disconnect.visible || _attend.visible ? root.need : ""
                }
                SmallButton {
                    id: _connect
                    objectName: "tailscalePopupConnect"
                    visible: root.view !== null && ["stopped", "unknown"].includes(root.view.phase) && root.client.cli === "present"
                             && (root.entry?.attention?.action ?? "") === ""
                    label: "Connect"
                    kind: "primary"
                    available: root._free
                    onClicked: root.client.connect("user")
                }
                SmallButton {
                    id: _disconnect
                    objectName: "tailscalePopupDisconnect"
                    visible: root.view !== null && ["running", "starting"].includes(root.view.phase)
                    label: "Disconnect"
                    kind: "danger"
                    available: root._free
                    onClicked: root.client.disconnect("user")
                }
                SmallButton {
                    id: _attend
                    objectName: "tailscalePopupAttend"
                    visible: (root.entry?.attention?.action ?? "") !== "" && !_disconnect.visible
                    label: root.entry?.attention?.action ?? ""
                    available: root._free
                    onClicked: root.client.attend()
                }
            }
            // The account and its tailnet (as the page's Connection section)
            Line {
                objectName: "tailscalePopupAccount"
                visible: text !== "" && root._loggedIn
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                text: root.client ? [root.client.currentAccount.loginName, root.client.currentAccount.tailnet].filter(part => part !== "").join(" · ") : ""
            }
            Line {
                visible: text !== ""
                text: root.entry?.attention?.reason ?? ""
                color: Api.theme.warning
            }
            // A login waiting for the browser: the link to copy (as the network popup's row)
            RowLayout {
                visible: (root.client?.authUrl ?? "") !== ""
                Layout.fillWidth: true
                spacing: 6
                Line {
                    elide: Text.ElideMiddle
                    wrapMode: Text.NoWrap
                    text: root.client?.authUrl ?? ""
                }
                SmallButton {
                    label: "Copy link"
                    size: "s"
                    onClicked: Api.copy(root.client.authUrl)
                }
            }

            // ── Exit node: the network popup row's chooser ──
            ExitNodeChooser {
                Layout.fillWidth: true
                client: root.client
                collapsible: true
                visible: root._running && (root.client?.exitNodes.count ?? 0) > 0
            }

            // ── This device ──
            SectionLabel {
                visible: _self.visible
                text: "This device"
            }
            CopyChips {
                id: _self
                objectName: "tailscalePopupSelf"
                Layout.fillWidth: true
                visible: root._loggedIn && (root.client?.device ?? null) !== null && texts.length > 0
                texts: root.client?.device ? [root.client.device.ipv4, root.client.device.ipv6]
                    .concat(root.client.device.namePending ? [] : [root.client.device.dnsName]).filter(text => !!text) : []
            }

            // ── Devices ──
            SectionLabel {
                visible: root.deviceList.shown.length > 0
                text: "Devices"
            }
            Repeater {
                model: ScriptModel {
                    values: root._ready ? root.deviceList.shown : []
                    objectProp: "id"
                }
                Rectangle {
                    id: _deviceRow
                    required property var modelData
                    objectName: "tailscalePopupDevice"
                    Layout.fillWidth: true
                    implicitHeight: _deviceColumn.implicitHeight + 8
                    radius: Api.theme.row.radius
                    color: Api.theme.surface

                    ColumnLayout {
                        id: _deviceColumn
                        x: Api.theme.row.horizontalPadding
                        width: parent.width - 2 * Api.theme.row.horizontalPadding
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4

                        RowLayout {
                            id: _deviceLine
                            Layout.fillWidth: true
                            spacing: 6
                            Rectangle {
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: 4
                                color: _deviceRow.modelData.online ? Api.theme.success : Api.theme.textDisabled
                            }
                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: _deviceRow.modelData.name ?? ""
                                font.family: Api.theme.fontFamily
                                font.pixelSize: Api.theme.fontSizeBody
                                color: _deviceRow.modelData.online ? Api.theme.textPrimary : Api.theme.textMuted
                            }
                            CopyChips {
                                chipMaxWidth: 140
                                texts: _deviceRow.modelData.ipv4 ? [_deviceRow.modelData.ipv4] : []
                            }
                            SmallButton {
                                objectName: "tailscalePopupSend"
                                visible: TailscaleWidgetRules.canSendTo(_deviceRow.modelData, root.view?.phase, root.taildrop?.isOperator)
                                label: "Send file…"
                                size: "xs"
                                // The shell's chooser; the files picked show in the row below
                                onClicked: root.taildrop.chooseForPopup(_deviceRow.modelData.id)
                            }
                        }
                        // Taildrop: the files picked for this device, Send, then the send's progress
                        TaildropSendRow {
                            objectName: "tailscalePopupSendRow"
                            Layout.fillWidth: true
                            taildrop: root.taildrop
                            deviceId: String(_deviceRow.modelData.id ?? "")
                        }
                    }
                }
            }
            SmallButton {
                objectName: "tailscalePopupAllDevices"
                visible: root.deviceList.more > 0
                label: "All devices…"
                size: "s"
                onClicked: root.module?.openSettings("")
            }

            // ── Taildrop: received files ──
            RowLayout {
                visible: _waiting.text !== ""
                Layout.fillWidth: true
                spacing: 6
                Line {
                    id: _waiting
                    objectName: "tailscalePopupWaiting"
                    text: root.taildrop?.statusText ?? ""
                    color: Api.theme.textPrimary
                }
                SmallButton {
                    objectName: "tailscalePopupSave"
                    visible: root.taildrop?.canSave === true
                    label: "Save"
                    size: "s"
                    available: root._free && (root.taildrop?.waitingCount ?? 0) > 0
                    onClicked: root.taildrop.save("user")
                }
            }
            // The last save's result (the list is newest first)
            Line {
                objectName: "tailscalePopupSaved"
                readonly property var last: (root.taildrop?.saved ?? []).length > 0 ? root.taildrop.saved[0] : null
                visible: text !== ""
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                text: last === null ? (root.taildrop?.saveError ?? "")
                    : last.outcome === "saved" ? "Saved " + last.savedAs : "Not saved " + last.name
                color: last === null || last.outcome !== "saved" ? Api.theme.warning : Api.theme.textSecondary
            }

            // ── Footer ──
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 6
                SmallButton {
                    objectName: "tailscalePopupSettings"
                    label: "Settings…"
                    size: "s"
                    onClicked: root.module?.openSettings("")
                }
                Item {
                    Layout.fillWidth: true
                }
                SmallButton {
                    objectName: "tailscalePopupAdmin"
                    visible: root._loggedIn
                    label: "Admin console"
                    size: "s"
                    onClicked: root.client.openUrl(TailscaleRules.adminMachinesUrl)
                }
            }
        }
    }
}
