pragma Singleton

import QtQuick
import Quickshell

// An exit node per network (delivery step 5), pure. The user marks networks ("Café Wi-Fi → use
// exit node X", "Home → none"); when the set of marked networks that are up changes, the module
// sets or clears the exit node once — and never again for the same set, so a choice made by
// hand afterwards stays until the networks change. The networks come from the shell
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

    // The stored table, cleaned: [{ id, choice, label, name }]
    function rows(table) {
        if (!_isObject(table))
            return [];
        return Object.keys(table).filter(id => validId(id) && _isObject(table[id]) && validChoice(table[id].choice)).slice(0, maxNetworks)
            .map(id => ({ id: id, choice: table[id].choice, label: String(table[id].label ?? "").slice(0, 100), name: String(table[id].name ?? "").slice(0, 100) }));
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
            next[id] = { choice: choice, label: String(label ?? "").slice(0, 100), name: String(name ?? "").slice(0, 100) };
        return next;
    }

    // The set of marked networks that are up: their ids, sorted, joined ("" none)
    function activeKey(table, networks) {
        const marked = rows(table).map(row => row.id);
        return (Array.isArray(networks) ? networks : []).filter(network => network && network.active === true && marked.includes(network.id))
            .map(network => network.id).sort().join(" ");
    }

    // What to do now: decide({ table, networks, lastKey, prefs, backendState, peersRead (status
    // .backendState, .peersRead), exitNodes (TailscaleRules.exitNodes), canChange, useProblem
    // (TailscaleRules.exitNodeUseProblem) }) → { kind, key, command name and args, text }:
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
    function decide(input) {
        const result = (kind, extra) => Object.assign({ kind: kind, key: "", name: "", args: {}, text: "" }, extra ?? {});
        const prefs = input?.prefs ?? null;
        if (prefs?.ok !== true || input?.backendState !== "Running")
            return result("wait");
        const key = activeKey(input?.table, input?.networks);
        if (key === String(input?.lastKey ?? ""))
            return result("same", { key: key });
        if (key === "")
            return result("none-marked", { key: key });
        const table = rows(input?.table);
        const choices = [...new Set(key.split(" ").map(id => table.find(row => row.id === id)?.choice ?? ""))];
        if (choices.length !== 1)
            return result("conflict", { key: key, text: "Two networks want different exit nodes" });
        const choice = choices[0];
        const using = String(prefs.exitNodeId ?? "") !== "" || String(prefs.exitNodeIp ?? "") !== "";
        let name = "exitNodeNone";
        let args = {};
        if (choice === "none") {
            if (!using)
                return result("already", { key: key });
        } else if (choice === "auto") {
            name = "exitNodeAuto";
        } else {
            const nodes = input?.exitNodes ?? {};
            const all = (nodes.own ?? []).concat(...(nodes.countries ?? []).map(country => [].concat(...(country.cities ?? []).map(city => city.nodes ?? []))));
            const node = all.find(option => option.id === choice) ?? null;
            if (node === null && input?.peersRead !== true)
                return result("wait");
            if (node === null || !node.online || node.argument === "")
                return result("unavailable", { key: key, text: "The chosen exit node is not available" });
            if (String(prefs.exitNodeId ?? "") === choice)
                return result("already", { key: key });
            name = "exitNode";
            args = { node: node.argument };
        }
        if (name !== "exitNodeNone" && String(input?.useProblem ?? "") !== "")
            return result("refused", { key: key, text: String(input.useProblem) });
        if (input?.canChange !== true)
            return result("needs-operator", { key: key, text: "Needs the operator" });
        return result("run", { key: key, name: name, args: args });
    }

    // The label of a choice
    function choiceLabel(row) {
        if (!row)
            return "";
        return row.choice === "none" ? "No exit node" : row.choice === "auto" ? "Automatic" : (row.label !== "" ? row.label : row.choice);
    }
}
