pragma Singleton

import QtQuick
import Quickshell

// Where the module's files find the live client (TailscaleClient) without a context to carry
// it — the settings page opened from the sidebar, the IPC. It holds a reference only: the
// client itself lives under the module's main (Main.qml), so turning the module off ends
// everything it runs, as the module API's lifetime rule asks; Main sets and clears this.
// A slot contribution reaches the same client as `context.provider.client`.
Singleton {
    property var client: null
}
