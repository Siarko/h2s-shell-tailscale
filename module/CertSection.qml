import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api
import qs.components

// The page's "Certificates" (delivery step 5), collapsed until opened: a TLS certificate for
// this computer's MagicDNS name, got by the operator as the user into the module's own folder
// (CertClient, CertRules). Not the operator: one line and the existing way to become it.
ColumnLayout {
    id: root

    property var client: null
    property bool shown: false

    readonly property var cert: client?.cert ?? null
    readonly property bool _free: client !== null && !client.busy
    property bool open: false

    visible: client !== null && client.cli === "present" && client.prefs !== null
    Layout.fillWidth: true
    spacing: 4

    onOpenChanged: _maybeCheck()
    onShownChanged: _maybeCheck()
    function _maybeCheck() {
        if (open && shown)
            cert?.check();
    }

    RowLayout {
        Layout.topMargin: 16
        Layout.fillWidth: true
        spacing: 8
        SectionTitle {
            Layout.topMargin: 0
            Layout.bottomMargin: 0
            Layout.fillWidth: true
            text: "Certificates"
        }
        SmallButton {
            objectName: "tailscaleCertToggle"
            label: root.open ? "Hide" : "Show"
            onClicked: root.open = !root.open
        }
    }

    ColumnLayout {
        visible: root.open
        Layout.fillWidth: true
        spacing: 4

        DetailRow {
            visible: (root.cert?.domain ?? "") !== ""
            label: "Name"
            value: root.cert?.domain ?? ""
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                visible: (root.cert?.problem ?? "") !== ""
                Layout.fillWidth: true
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.cert?.problem ?? ""
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: Api.theme.textSecondary
            }
            SmallButton {
                visible: root.cert?.problem === "Needs the operator"
                label: "Let this user manage Tailscale without a password"
                available: root._free
                onClicked: root.client.becomeOperator()
            }
            SmallButton {
                visible: root.cert?.problem === "HTTPS certificates are off for this tailnet"
                label: "Admin console"
                onClicked: root.client.openUrl(ServeRules.adminDnsUrl)
            }
        }
        RowLayout {
            visible: (root.cert?.problem ?? "x") === ""
            spacing: 8
            SmallButton {
                objectName: "tailscaleCertGet"
                label: root.cert?.getting ? "Getting…" : "Get certificate"
                available: root._free
                onClicked: root.cert.get()
            }
        }
        DetailRow {
            visible: (root.cert?.current?.expires ?? 0) > 0
            label: "Valid until"
            value: new Date(root.cert?.current?.expires ?? 0).toLocaleDateString(Qt.locale(), Locale.ShortFormat)
        }
        CopyChips {
            visible: root.cert?.current?.present === true && root.cert?.files !== null
            Layout.fillWidth: true
            texts: root.cert?.files ? [root.cert.files.cert, root.cert.files.key] : []
        }
        Hint {
            visible: root.cert?.current?.present === true
            text: "Not renewed by itself"
        }
        Text {
            visible: text !== ""
            Layout.fillWidth: true
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.cert?.message ?? ""
            font.family: Api.theme.fontFamily
            font.pixelSize: Api.theme.fontSizeSmall
            color: Api.theme.warning
        }
    }
}
