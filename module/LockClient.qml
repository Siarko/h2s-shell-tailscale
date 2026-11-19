import QtQuick
import Quickshell
import qs.api

// Tailnet lock's live side (delivery step 5): status only. `tailscale lock status --json` (any
// user may) is read once Tailscale runs and when this computer's key changes while it runs, when the
// page shows it, and after the computer slept — never on a clock. Nothing here changes the lock.
QtObject {
    id: root

    property var client: null

    readonly property bool running: client !== null && client.running && client.cli === "present"
    // LockRules.parse's, null: not read
    property var lock: null
    property bool reading: false
    property bool _again: false
    property int reads: 0
    readonly property var attention: LockRules.attention(lock)
    // What triggers a read: Tailscale becoming Running, or this computer's node key changing
    // while it runs. The status matters only while connected (the entry's attention is shown
    // only then, TailscaleClient.entry), so nothing is read while stopped, logged out or
    // starting; the value read last is kept for the page.
    readonly property string _trigger: running && client.status?.backendState === "Running" ? "running|" + (client.status?.self?.key ?? "") : ""

    // Read once the state has settled: a connect, a reconnect or an account switch brings a
    // burst of reads and state changes, and a debounce makes them one lock read, after the
    // burst (lockSettleMs; the page reads at once when shown, resume reads at once). The
    // attention it may raise is about something lasting (this device not signed), so a few
    // seconds' delay costs nothing.
    property int lockSettleMs: 8000
    on_TriggerChanged: {
        if (_trigger !== "")
            _settle.restart();
        else
            _settle.stop();
    }
    readonly property Timer _settle: Timer {
        interval: root.lockSettleMs
        onTriggered: root.read()
    }

    function read() {
        if (!running)
            return false;
        if (reading) {
            _again = true;
            return false;
        }
        reading = true;
        // Not answered when the client stopped meanwhile (its _life below resets `reading`)
        client._run(client._tailscaleArgv({ argv: ["tailscale", "lock", "status", "--json"] }), client._limitMs("read"), result => {
            reading = false;
            reads++;
            if (result.ok) {
                const parsed = LockRules.parse(result.stdout);
                if (parsed.ok)
                    lock = parsed;
            }
            if (_again) {
                _again = false;
                Qt.callLater(read);
            }
        });
        return true;
    }

    readonly property Connections _life: Connections {
        target: root.client
        function onRunningChanged() {
            if (!root.client.running) {
                root.lock = null;
                root.reading = false;
                root._again = false;
            }
        }
    }
}
