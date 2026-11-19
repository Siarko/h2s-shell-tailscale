import QtQuick
import Quickshell
import qs.api

// An exit node per network, live (delivery step 5): follows the shell's networks (Api.networks,
// module API 1.3 — no polling) and the client's prefs and status; when the marked networks that
// are up change, NetworkExitRules.decide says what to do and NetworkExitRules.react whether to
// act. "lastKey" (kept in the module's store, so a restart on the same network does not act
// again) is the set of networks done with: stored only once the choice applied (or nothing was
// needed). A choice not applied stays open and is tried again when what stopped it changes —
// the chosen node appears or comes back online, this user becomes the operator — and the user is
// notified once per change (a privacy choice). An exit node picked by hand while a choice is held
// ends the hold (the networks taken): a choice made by hand stays until the networks change, also
// across a restart (the hold is kept in the store with the exit node seen when it began). It
// acts only as an automatic change: plainly, as origin "network" — never a password prompt; not
// the operator → "Needs the operator" on the page, nothing run. While Tailscale is not Running
// (or its peers are not read yet) it waits, the key not taken, and acts once Tailscale is up.
//
// A choice made by hand in the shell (the exit-node chooser) is "for now" once its run
// succeeded (TailscaleClient.setExitNode → chosenByHand; a run that failed, was dismissed or
// refused changes nothing here). It overrides the networks' choices until "Default"
// (dropOverride), a wake from sleep (the client's resumed()) or anything that builds the
// module's main again (a restart of the shell, a reload, the module re-enabled) — it lives only
// in memory. While it lasts nothing is applied, whatever networks come and go; when it ends,
// the choice of the networks up then is applied again (the networks are a new set: the key
// cleared, also in the store, so a restart during it applies them too) — and with no marked
// network up, no exit node is used (NetworkExitRules.decide's clearUnmarked). A pick whose run
// was still going when "for now" ended (a wake while it ran) is "for now" when it succeeds: it
// is the user's latest word, and no network run can start while it runs (one change at a time).
QtObject {
    id: root

    property var client: null
    // The shell's networks (Main binds Api.networks; the suites set a list)
    property var networks: []
    // They have been read whole (Main binds Api.networksReady, module API 1.16): an empty list
    // then means none. A suite that sets only a list: read once it holds one
    property bool networksReady: (networks ?? []).length > 0
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
    // The last decision that did not apply the choice (NetworkExitRules.react), null none. Kept
    // in the store: after a restart an exit node chosen by hand meanwhile is still left alone
    property var _held: NetworkExitRules.restoredHold(store?.get("exitByNetwork.held", null) ?? null)
    // The change last notified (NetworkExitRules.noticeKey): a restored hold was notified already
    property string _noticed: _held !== null ? NetworkExitRules.noticeKey(_held) : ""
    property bool _inFlight: false
    // A choice made by hand "for now" (in memory only). A network run never overlaps it: one
    // runs only while there is none, and a pick runs (and becomes one) only while no other
    // change runs
    property bool overridden: false
    // "for now" just ended (dropOverride): with no marked network up, the exit node is turned
    // off. "" no, "now" ("Default": at once), "settled" (a wake: once "no marked network up"
    // lasted, as the networks often come back after a wake)
    property string _clearing: ""
    // What decides the exit node now, for the chooser (NetworkExitRules.effect)
    readonly property var effect: NetworkExitRules.effect({ table: table, networks: networks, overridden: overridden, lastKey: lastKey,
                                                            decisionKind: decision.kind, held: _held !== null, prefs: client?.prefs ?? null })
    // Serve's check after a Funnel is waiting for the change lock: no automatic change takes it
    readonly property bool _serveChecking: client?.serve?.checking === true

    // Everything decide reads, and busy: a switch deferred while another change runs is tried
    // again when that change ends; the wanted nodes' state, so one coming back is tried again;
    // why using an exit node is refused, so the end of that is noticed
    readonly property string _inputs: running ? JSON.stringify([networksReady, NetworkExitRules.activeKey(table, networks), client.prefs?.ok === true,
        client.prefs?.exitNodeId ?? "", client.prefs?.exitNodeIp ?? "", client.exitNodes.count, client.canChange, client.status?.backendState ?? "",
        client.status?.peersRead === true, client.busy, _serveChecking, overridden, NetworkExitRules.wanted(table, networks),
        NetworkExitRules.wantedNodes(table, networks, client.exitNodes), TailscaleRules.exitNodeUseProblem(client.prefs)]) : ""
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

    // An exit node chosen by hand in the shell, its run succeeded: the networks' choices wait
    // until dropOverride. The networks up are left open (the key cleared), so they are applied
    // again when it ends
    function chosenByHand() {
        overridden = true;
        _clearing = "";
        _noneMarkedTimer.stop();
        _setHeld(null);
        _noticed = "";
        lastKey = "";
        store?.set("exitByNetwork.lastKey", lastKey);
        decision = { kind: "override", key: "", text: "" };
    }

    // "Default", or a wake (`afterWake`): the choice made by hand ends, the networks' choice
    // applies again — none marked up: no exit node. false when there was none
    function dropOverride(afterWake) {
        if (!overridden)
            return false;
        overridden = false;
        _clearing = afterWake === true ? "settled" : "now";
        _setHeld(null);
        _noticed = "";
        lastKey = "";
        store?.set("exitByNetwork.lastKey", lastKey);
        decision = { kind: "", key: "", text: "" };
        Qt.callLater(follow);
        return true;
    }

    // The networks done with: a later return to them is a new change (notified again if needed)
    function _take(key) {
        _setHeld(null);
        _noticed = "";
        lastKey = key;
        store?.set("exitByNetwork.lastKey", lastKey);
    }

    function _setHeld(held) {
        _held = held;
        store?.set("exitByNetwork.held", held ?? undefined);
    }

    // A choice not applied, told once per change (never a text with the node's address: the
    // client's notification path strips addresses)
    function _notify(result, text) {
        _noticed = NetworkExitRules.noticeKey(result);
        client.failed("Exit node for this network", text);
    }

    // `settled`: called by the hold timer — "no marked network up" has lasted
    function follow(settled) {
        // The networks not read whole yet (a restart, NetworkManager not answering): deciding now
        // would take "none up" and act again once they arrive
        if (!running || _inFlight || !networksReady || overridden)
            return;
        const result = NetworkExitRules.decide({
            table: table, networks: networks, lastKey: lastKey, prefs: client.prefs, exitNodes: client.exitNodes,
            backendState: client.status?.backendState ?? "", peersRead: client.status?.peersRead === true,
            canChange: client.canChange, useProblem: TailscaleRules.exitNodeUseProblem(client.prefs), clearUnmarked: _clearing !== ""
        });
        if (result.kind === "wait")
            return;
        // Off the held networks with none up counts only once it lasted, as "none-marked" does
        // (and the exit node turned off after a wake)
        const leaving = result.kind === "same" && _held !== null && result.key !== _held.key;
        const clearing = _clearing !== "" && result.key === "";
        if (result.kind === "none-marked" || (leaving && result.key === "") || (clearing && _clearing === "settled")) {
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
        const step = NetworkExitRules.react(result, _held, _noticed);
        // The end of "for now" is decided: done with, unless its run waits (below)
        if (step.act !== "run")
            _clearing = "";
        switch (step.act) {
        case "take":
            decision = { kind: step.manual === true ? "manual" : result.kind, key: result.key, text: step.manual === true ? "" : result.text };
            _take(result.key);
            return;
        case "hold":
            _setHeld(step.held);
            decision = { kind: result.kind, key: result.key, text: result.text };
            if (step.notify)
                _notify(result, result.text);
            return;
        case "release":
            _setHeld(null);
            _noticed = "";
            if (result.key === "")
                decision = { kind: "none-marked", key: "", text: "" };
            return;
        case "run":
            break;
        default:
            return;
        }
        // Busy with another change, or Serve's check waiting for the lock: tried again when it
        // ends (both are inputs)
        if (client.busy || _serveChecking)
            return;
        const command = TailscaleRules.commandFor(result.name, result.args);
        if (!command.ok)
            return;
        runs++;
        _inFlight = true;
        _clearing = "";
        client._runChange(command, "network", "exit-node", null, null, outcome => {
            _inFlight = false;
            // The CLI's words as plain text (TailscaleRules.plainText), as on the entry
            const reason = outcome.ok ? "" : TailscaleRules.plainText(outcome.message, 300);
            decision = { kind: outcome.ok ? "applied" : "failed", key: result.key, text: reason };
            if (outcome.ok) {
                _take(result.key);
                return;
            }
            // Asked before the hold is set: _noticed follows a restored hold until first assigned
            const fresh = NetworkExitRules.noticeKey(result) !== _noticed;
            _setHeld({ key: result.key, choice: result.choice, kind: "failed", seen: result.current });
            if (fresh)
                _notify(result, reason);
        });
    }
}
