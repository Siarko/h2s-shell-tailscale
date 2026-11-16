import QtQuick
import Quickshell
import qs.api

// Tailnet lock's live side (delivery step 5): status only. `tailscale lock status --json` (any
// user may) is read at start, when Tailscale's state or this computer's key changes, when the
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
    // What triggers a read: the backend state and this computer's node key
    readonly property string _trigger: running ? (client.status?.backendState === "Running" ? "running" : "other") + "|" + (client.status?.self?.key ?? "") : ""

    // Read a while after the state settles: never in the burst of reads a start or a
    // reconnect brings (lockSettleMs; the page reads at once when shown)
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
        const generation = client._generation;
        const seconds = client._limit("read");
        client._spawn(client._timedArgv({ argv: ["tailscale", "lock", "status", "--json"] }, seconds), client._watchdogMs(seconds), result => {
            reading = false;
            if (!client._alive(generation))
                return;
            reads++;
            if (result.ok) {
                const parsed = LockRules.parse(result.out);
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
