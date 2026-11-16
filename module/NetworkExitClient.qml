import QtQuick
import Quickshell
import qs.api

// An exit node per network, live (delivery step 5): follows the shell's networks (Api.networks,
// module API 1.3 — no polling) and the client's prefs; when the marked networks that are up
// change, NetworkExitRules.decide says what to do, once per set of networks ("lastKey", kept in
// the module's store so a restart on the same network does not act again). It acts only as an
// automatic change: plainly, as origin "network" — never a password prompt; not the operator →
// "Needs the operator" on the page, nothing run.
QtObject {
    id: root

    property var client: null
    // The shell's networks (Main binds Api.networks; the suites set a list)
    property var networks: []

    readonly property bool running: client !== null && client.running && client.cli === "present"
    readonly property var store: client?.module?.store ?? null
    property var table: store?.get("exitByNetwork", ({})) ?? ({})
    property string lastKey: String(store?.get("exitByNetwork.lastKey", "") ?? "")
    readonly property var rows: NetworkExitRules.rows(table)
    // The last decision (for the page and the IPC)
    property var decision: ({ kind: "", key: "", text: "" })
    property int runs: 0

    readonly property string _inputs: running ? JSON.stringify([NetworkExitRules.activeKey(table, networks), client.prefs?.ok === true,
        client.prefs?.exitNodeId ?? "", client.exitNodes.count, client.canChange]) : ""
    on_InputsChanged: Qt.callLater(follow)

    function setChoice(networkId, choice, label, name) {
        table = NetworkExitRules.withRow(table, networkId, choice, label, name);
        store?.set("exitByNetwork", table);
    }

    function removeNetwork(networkId) {
        setChoice(networkId, null);
    }

    function follow() {
        // No networks at all: the shell has not read them yet (a restart) — deciding now would
        // take "none up" and act again once they arrive
        if (!running || (networks ?? []).length === 0)
            return;
        const result = NetworkExitRules.decide({
            table: table, networks: networks, lastKey: lastKey, prefs: client.prefs, exitNodes: client.exitNodes,
            canChange: client.canChange, useProblem: TailscaleRules.exitNodeUseProblem(client.prefs)
        });
        if (result.kind === "wait" || result.kind === "same")
            return;
        if (result.kind === "run") {
            // Busy with another change: tried again when it ends (the inputs change then)
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
