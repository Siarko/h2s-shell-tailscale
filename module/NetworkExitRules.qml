pragma Singleton

import QtQuick
import Quickshell

// An exit node per network (delivery step 5), pure. The user marks networks ("Café Wi-Fi → use
// exit node X", "Home → none"); when the set of marked networks that are up changes, the module
// sets or clears the exit node once — and, once that applied, never again for the same set, so a
// choice made by hand afterwards stays until the networks change. A choice that could not be
// applied (X offline, not the operator) is tried again when that changes, and said once. The networks come from the shell
// (Api.networks, module API 1.3: NetworkManager's saved Wi-Fi and Ethernet profiles by UUID,
// the key system.vpnWithNetworks uses too). The change is an automatic one: it runs only when
// no password is needed (the operator), never through pkexec.
//
// The table (the module's store, "exitByNetwork"): { <network id>: { choice, label, name } } —
// choice "none" | "auto" | a node's stable id; label the node's name when chosen, name the
// network's name when marked (shown while the network is not in the list).
Singleton {
    id: root

    readonly property int maxNetworks: 32

    function _isObject(value) {
        return value !== null && typeof value === "object" && !Array.isArray(value);
    }

    // A network id as NetworkManager gives it (a UUID; anything plain and short)
    function validId(id) {
        return typeof id === "string" && /^[A-Za-z0-9-]{1,64}$/.test(id) && !["__proto__", "constructor", "prototype"].includes(id);
    }

    function validChoice(choice) {
        return choice === "none" || choice === "auto" || (typeof choice === "string" && /^[A-Za-z0-9]{1,64}$/.test(choice));
    }

    // A node's or a network's name as shown and kept: one line, capped (TailscaleRules.oneLine:
    // names come from other people's devices and from NetworkManager)
    function _name(value) {
        return TailscaleRules.oneLine(value, 100);
    }

    // The stored table, cleaned: [{ id, choice, label, name }]
    function rows(table) {
        if (!_isObject(table))
            return [];
        return Object.keys(table).filter(id => validId(id) && _isObject(table[id]) && validChoice(table[id].choice)).slice(0, maxNetworks)
            .map(id => ({ id: id, choice: table[id].choice, label: _name(table[id].label), name: _name(table[id].name) }));
    }

    function withRow(table, id, choice, label, name) {
        const next = {};
        for (const row of rows(table))
            next[row.id] = { choice: row.choice, label: row.label, name: row.name };
        if (!validId(id))
            return next;
        if (choice === null || choice === undefined)
            delete next[id];
        else if (validChoice(choice) && (id in next || Object.keys(next).length < maxNetworks))
            next[id] = { choice: choice, label: _name(label), name: _name(name) };
        return next;
    }

    // The set of marked networks that are up: their ids, sorted, joined ("" none)
    function activeKey(table, networks) {
        const marked = rows(table).map(row => row.id);
        return (Array.isArray(networks) ? networks : []).filter(network => network && network.active === true && marked.includes(network.id))
            .map(network => network.id).sort().join(" ");
    }

    // Every exit node of TailscaleRules.exitNodes, flat
    function _allNodes(nodes) {
        return (nodes?.own ?? []).concat(...(nodes?.countries ?? []).map(country => [].concat(...(country.cities ?? []).map(city => city.nodes ?? []))));
    }

    // What the marked networks that are up want: their choices, sorted, joined by "," ("" none)
    function wanted(table, networks) {
        const key = activeKey(table, networks);
        const marked = rows(table);
        return key === "" ? "" : [...new Set(key.split(" ").map(id => marked.find(row => row.id === id)?.choice ?? ""))].sort().join(",");
    }

    // The state of the nodes those networks want, as one string: changes when one appears, goes
    // offline or comes back (the exit node count alone may not)
    function wantedNodes(table, networks, exitNodes) {
        const all = _allNodes(exitNodes);
        return wanted(table, networks).split(",").filter(choice => choice !== "" && choice !== "none" && choice !== "auto").map(choice => {
            const node = all.find(option => option.id === choice) ?? null;
            return choice + (node === null ? ":gone" : node.online && node.argument !== "" ? ":up" : ":down");
        }).join(" ");
    }

    // What to do now: decide({ table, networks, lastKey, prefs, backendState, peersRead (status
    // .backendState, .peersRead), exitNodes (TailscaleRules.exitNodes), canChange, useProblem
    // (TailscaleRules.exitNodeUseProblem), clearUnmarked }) → { kind, key, choice (wanted),
    // command name and args, text }. `clearUnmarked`: a choice made "for now" just ended
    // (NetworkExitClient.dropOverride) — with no marked network up there is no choice to go
    // back to, so no exit node is used: decided as a choice of "none" for the key "" (already,
    // needs-operator or run), never "same" or "none-marked":
    //   "wait"            prefs not read yet, Tailscale not Running (off, starting: at boot or
    //                     resume the network is often up first), or the chosen node not among
    //                     the exit nodes while no peer list has been read: decide later (the key
    //                     is not taken — so the choice is applied once Tailscale is up; it never
    //                     brings Tailscale up itself)
    //   "same"            the marked networks up are the ones acted on last: nothing (a manual
    //                     choice since then is left alone)
    //   "none-marked"     no marked network is up: nothing (the key is taken)
    //   "conflict"        two marked networks up want different exit nodes: nothing
    //   "unavailable"     the chosen node is not an exit node now (gone, offline), with
    //                     Tailscale Running and its peers read
    //   "already"         the exit node is already as wanted
    //   "needs-operator"  a change, but it needs a password: nothing (one line on the page)
    //   "refused"         this computer offers an exit node: using one is refused (text)
    //   "run"             name "exitNode" (args { node }), "exitNodeAuto" or "exitNodeNone"
    // Only "already" and "none-marked" take the key by themselves, "run" once it succeeded; the
    // rest leave it open (react says when to try again)
    function decide(input) {
        let current = "";
        const result = (kind, extra) => Object.assign({ kind: kind, key: "", choice: "", current: current, name: "", args: {}, text: "" }, extra ?? {});
        const prefs = input?.prefs ?? null;
        if (prefs?.ok !== true || input?.backendState !== "Running")
            return result("wait");
        // The exit node in use now (id and address), for react: a change by hand while held
        current = String(prefs.exitNodeId ?? "") + "|" + String(prefs.exitNodeIp ?? "");
        const key = activeKey(input?.table, input?.networks);
        const clearing = key === "" && input?.clearUnmarked === true;
        if (!clearing && key === String(input?.lastKey ?? ""))
            return result("same", { key: key });
        if (!clearing && key === "")
            return result("none-marked", { key: key });
        const wants = clearing ? "none" : wanted(input?.table, input?.networks);
        const choices = wants.split(",");
        if (choices.length !== 1)
            return result("conflict", { key: key, choice: wants, text: "Two networks want different exit nodes" });
        const choice = choices[0];
        const using = String(prefs.exitNodeId ?? "") !== "" || String(prefs.exitNodeIp ?? "") !== "";
        let name = "exitNodeNone";
        let args = {};
        if (choice === "none") {
            if (!using)
                return result("already", { key: key, choice: choice });
        } else if (choice === "auto") {
            name = "exitNodeAuto";
        } else {
            const node = _allNodes(input?.exitNodes).find(option => option.id === choice) ?? null;
            if (node === null && input?.peersRead !== true)
                return result("wait");
            if (node === null || !node.online || node.argument === "")
                return result("unavailable", { key: key, choice: choice, text: "The chosen exit node is not available" });
            if (String(prefs.exitNodeId ?? "") === choice)
                return result("already", { key: key, choice: choice });
            name = "exitNode";
            args = { node: node.argument };
        }
        if (name !== "exitNodeNone" && String(input?.useProblem ?? "") !== "")
            return result("refused", { key: key, choice: choice, text: String(input.useProblem) });
        if (input?.canChange !== true)
            return result("needs-operator", { key: key, choice: choice, text: "Needs the operator" });
        return result("run", { key: key, choice: choice, name: name, args: args });
    }

    // The change a decision is about: the networks up and what they want. A notice is given once
    // per change (the same networks wanting the same thing again say nothing new)
    function noticeKey(result) {
        return String(result?.key ?? "") + "|" + String(result?.choice ?? "");
    }

    // What the live side does with a decision, given what is held open (null, or { key, choice,
    // kind } of the last decision that did not apply the choice; kind "failed": its run failed)
    // and the notice key last notified → { act, held, notify }:
    //   "none"  nothing (waiting, the same networks as last time, or held already for the same
    //           reason: nothing new to try or say)
    //   "take"  the networks are done with ("already", lasting "none-marked"): the key stored
    //   "run"   run the command; the key is stored only once it succeeded
    //   "release" back on the networks last done with (often none up, the key ""): what was
    //           held is dropped, so the next pass on its networks is a new change
    //   "hold"  not applied (unavailable, needs the operator, refused, conflict): the key stays
    //           open, so a later decision on the same networks is tried again — an exit node
    //           that comes back, the operator set — but never retried for the same reason
    // A run that failed is not tried again for the same networks and choice (no loop over a
    // failing command); new networks or another choice try again. `notify`: a hold whose change
    // was not notified yet (a privacy choice not applied must not go unnoticed)
    function react(result, held, noticed) {
        const kind = result?.kind ?? "";
        const same = held !== null && held !== undefined && held.key === result?.key && held.choice === result?.choice;
        // The exit node changed by hand on the held networks (another one than when the hold
        // began): a choice made by hand stays until the networks change — the networks taken
        if (held !== null && held !== undefined && kind !== "wait" && held.key === result?.key && typeof held.seen === "string"
                && typeof result?.current === "string" && result.current !== held.seen)
            return { act: "take", held: null, notify: false, manual: true };
        if (kind === "same" && held !== null && held !== undefined && held.key !== result?.key)
            return { act: "release", held: null, notify: false };
        if (kind === "wait" || kind === "same" || kind === "")
            return { act: "none", held: held ?? null, notify: false };
        if (kind === "none-marked" || kind === "already")
            return { act: "take", held: null, notify: false };
        if (kind === "run")
            return same && held.kind === "failed" ? { act: "none", held: held, notify: false } : { act: "run", held: held ?? null, notify: false };
        if (same && held.kind === kind)
            return { act: "none", held: held, notify: false };
        return { act: "hold", held: { key: result.key, choice: result.choice, kind: kind, seen: String(result.current ?? "") },
                 notify: noticeKey(result) !== String(noticed ?? "") };
    }

    // A hold as kept in the module's store (so a restart keeps "a choice made by hand stays")
    // → the hold, or null when it is not one. A failed run is tried once more after a restart
    // (kind "restart"); the exit node seen when it began still guards a choice made by hand
    function restoredHold(stored) {
        if (!_isObject(stored) || typeof stored.key !== "string" || stored.key === "" || typeof stored.choice !== "string"
                || typeof stored.kind !== "string" || typeof stored.seen !== "string")
            return null;
        return { key: stored.key.slice(0, 2000), choice: stored.choice.slice(0, 2000), kind: stored.kind === "failed" ? "restart" : stored.kind.slice(0, 32),
                 seen: stored.seen.slice(0, 200) };
    }

    // The label of a choice, on one line
    function choiceLabel(row) {
        if (!row)
            return "";
        return row.choice === "none" ? "No exit node" : row.choice === "auto" ? "Automatic" : _name(row.label !== "" ? row.label : row.choice);
    }

    // One network's row of the table, or null when it is not marked
    function rowFor(table, networkId) {
        return rows(table).find(row => row.id === networkId) ?? null;
    }

    // The choices on a network's card: [{ value, label, name }] — "Not set" (value "": the mark
    // removed), no exit node, automatic, this tailnet's own exit nodes (`own`: TailscaleRules
    // .exitNodes' own), and the network's choice when it is none of them (a node gone or not
    // read yet, by the name kept with it). `name` is what setChoice keeps as the node's label
    function cardOptions(own, row) {
        const options = [{ value: "", label: "Not set", name: "" }, { value: "none", label: "No exit node", name: "" },
                         { value: "auto", label: "Automatic", name: "" }];
        for (const option of own && typeof own.length === "number" ? Array.from(own) : []) {
            if (option && validChoice(option.id) && option.id !== "none" && option.id !== "auto" && !options.some(known => known.value === option.id))
                options.push({ value: option.id, label: _name(option.name || option.id), name: _name(option.name) });
        }
        if (row && !options.some(option => option.value === row.choice))
            options.push({ value: row.choice, label: choiceLabel(row), name: row.label });
        return options;
    }

    // What the mark on a network's name line says (its tooltip and accessible name): "" for no
    // mark — a network not marked, or set to "No exit node" (only a network that routes through
    // an exit node is marked)
    function markLabel(row) {
        if (!row || row.choice === "none")
            return "";
        return row.choice === "auto" ? "Exit node: automatic" : "Exit node: " + TailscaleRules.oneLine(choiceLabel(row), 40);
    }

    // Whether the exit node in use (prefs: TailscaleRules.parsePrefs) is what `choice` asks for:
    // "none" none in use, a node's id that node, "auto" any (the prefs do not say which was
    // picked automatically). Prefs not read: false (unknown is not "as wanted")
    function _inUse(prefs, choice) {
        if (prefs?.ok !== true)
            return false;
        const id = String(prefs.exitNodeId ?? "");
        const using = id !== "" || String(prefs.exitNodeIp ?? "") !== "";
        return choice === "none" ? !using : choice === "auto" ? using : id === choice;
    }

    // What decides the exit node now, for the chooser: effect({ table, networks, overridden (a
    // choice made by hand "for now", NetworkExitClient), lastKey, decisionKind, held, prefs (the
    // exit node in use) }) → { kind, from, network (its name), label (its choice's) }:
    //   "override"  a choice made by hand "for now": "Default" ends it and brings back `from`:
    //               "network" the choice of the networks up (`network`, `label`), "none" no exit
    //               node (no marked network up: `label` "No exit node"), "conflict" two networks
    //               up that want different nodes (nothing applied: `label` "")
    //   "network"   the networks up have one choice, applied (the networks taken, nothing held)
    //               and still in use (the prefs: not changed outside the shell since)
    //   ""          none of these: no choice for the networks up, two that differ, one not
    //               applied (its reason is on the network's card), or the exit node changed
    //               since by something else (the `tailscale` command), or not read
    function effect(input) {
        const none = { kind: "", from: "", network: "", label: "" };
        const key = activeKey(input?.table, input?.networks);
        const wants = wanted(input?.table, input?.networks);
        if (input?.overridden === true && key === "")
            return { kind: "override", from: "none", network: "", label: "No exit node" };
        if (input?.overridden === true && wants.includes(","))
            return { kind: "override", from: "conflict", network: "", label: "" };
        if (key === "" || wants === "" || wants.includes(","))
            return none;
        const firstId = key.split(" ")[0];
        const row = rowFor(input?.table, firstId);
        const network = (Array.isArray(input?.networks) ? input.networks : []).find(item => item && item.id === firstId) ?? null;
        const found = { from: "network", network: TailscaleRules.oneLine(network?.name || row?.name || "", 40), label: choiceLabel(row) };
        if (input?.overridden === true)
            return Object.assign({ kind: "override" }, found);
        const notApplied = ["conflict", "unavailable", "refused", "needs-operator", "failed", "manual", "override"];
        if (input?.held === true || String(input?.lastKey ?? "") !== key || notApplied.includes(String(input?.decisionKind ?? "")))
            return none;
        if (!_inUse(input?.prefs, wants))
            return none;
        return Object.assign({ kind: "network" }, found);
    }

    // The chooser's words for it, beside the exit node in use: "for now", "for Café", ""
    function effectText(effect) {
        if (effect?.kind === "override")
            return "for now";
        if (effect?.kind === "network")
            return effect.network !== "" ? "for " + effect.network : "for this network";
        return "";
    }

    // What "Default" brings back: "Café: home-server", "No exit node"; "" for two networks that
    // differ (their cards say so)
    function defaultDetail(effect) {
        if (effect?.kind !== "override" || effect.from === "conflict")
            return "";
        if (effect.from === "none")
            return "No exit node";
        return TailscaleRules.oneLine((effect.network !== "" ? effect.network : "This network") + ": " + effect.label, 80);
    }
}
