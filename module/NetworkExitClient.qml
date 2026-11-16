import QtQuick
import Quickshell
import qs.api

// An exit node per network, live (delivery step 5): follows the shell's networks (Api.networks,
// module API 1.3 — no polling) and the client's prefs and status; when the marked networks that
// are up change, NetworkExitRules.decide says what to do, once per set of networks ("lastKey",
// kept in the module's store so a restart on the same network does not act again). It acts only
// as an automatic change: plainly, as origin "network" — never a password prompt; not the
// operator → "Needs the operator" on the page, nothing run. While Tailscale is not Running (or
// its peers are not read yet) it waits, the key not taken, and acts once Tailscale is up.
QtObject {
    id: root

    property var client: null
    // The shell's networks (Main binds Api.networks; the suites set a list)
    property var networks: []
    // How long "no marked network up" must hold before it counts (the key taken): a Wi-Fi
    // reconnect passes through it for a few seconds, and taking it then would make the return
    // to the same network a new set — applying the choice again over a manual change made
    // since. A property so the suites can shorten it
    property int noneMarkedHoldMs: 30000

    readonly property bool running: client !== null && client.running && client.cli === "present"
    readonly property var store: client?.module?.store ?? null
    property var table: store?.get("exitByNetwork", ({})) ?? ({})
    property string lastKey: String(store?.get("exitByNetwork.lastKey", "") ?? "")
    readonly property var rows: NetworkExitRules.rows(table)
    // The last decision (for the page and the IPC)
    property var decision: ({ kind: "", key: "", text: "" })
    property int runs: 0

    // Everything decide reads, and busy: a switch deferred while another change runs is tried
    // again when that change ends
    readonly property string _inputs: running ? JSON.stringify([NetworkExitRules.activeKey(table, networks), client.prefs?.ok === true,
        client.prefs?.exitNodeId ?? "", client.exitNodes.count, client.canChange, client.status?.backendState ?? "",
        client.status?.peersRead === true, client.busy]) : ""
    on_InputsChanged: Qt.callLater(follow)

    // Started by the first "no marked network up"; when it fires, follow takes that key if it
    // still holds. Nothing polls: one shot per pass
    readonly property Timer _noneMarkedTimer: Timer {
        interval: root.noneMarkedHoldMs
        onTriggered: root.follow(true)
    }

    function setChoice(networkId, choice, label, name) {
        table = NetworkExitRules.withRow(table, networkId, choice, label, name);
        store?.set("exitByNetwork", table);
    }

    function removeNetwork(networkId) {
        setChoice(networkId, null);
    }

    // `settled`: called by the hold timer — "no marked network up" has lasted
    function follow(settled) {
        // No networks at all: the shell has not read them yet (a restart) — deciding now would
        // take "none up" and act again once they arrive
        if (!running || (networks ?? []).length === 0)
            return;
        const result = NetworkExitRules.decide({
            table: table, networks: networks, lastKey: lastKey, prefs: client.prefs, exitNodes: client.exitNodes,
            backendState: client.status?.backendState ?? "", peersRead: client.status?.peersRead === true,
            canChange: client.canChange, useProblem: TailscaleRules.exitNodeUseProblem(client.prefs)
        });
        if (result.kind === "wait")
            return;
        if (result.kind === "none-marked") {
            if (settled !== true) {
                if (!_noneMarkedTimer.running)
                    _noneMarkedTimer.start();
                return;
            }
        } else {
            // Back on a marked network (or still on it) before the hold ended: the short pass
            // through "none" never counted
            _noneMarkedTimer.stop();
        }
        if (result.kind === "same")
            return;
        if (result.kind === "run") {
            // Busy with another change: tried again when it ends (busy is one of the inputs)
            if (client.busy)
                return;
            const command = TailscaleRules.commandFor(result.name, result.args);
            if (!command.ok)
                return;
            runs++;
            client._runChange(command, "network", "exit-node", null, null, outcome => {
                decision = { kind: outcome.ok ? "applied" : "failed", key: result.key, text: outcome.ok ? "" : outcome.message };
            });
        } else {
            decision = { kind: result.kind, key: result.key, text: result.text };
        }
        lastKey = result.key;
        store?.set("exitByNetwork.lastKey", lastKey);
    }
}
