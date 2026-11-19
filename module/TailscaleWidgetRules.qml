pragma Singleton

import Quickshell
import QtQuick

// The bar widget's and its popup's decisions (step 6) — pure, so module/tests/ check them
// with plain objects: what the icon shows for the client's state, the text beside it, the
// Taildrop badge, which devices the popup lists. They read only what the live
// client (TailscaleClient) already computes — its view, entry and Taildrop state — so the
// widget, the popup, the page and the network popup's row tell one story; nothing here
// decides a state of its own.
Singleton {
    id: root

    // The widget's preset keys and their defaults (module.json presetDefaults says the same)
    readonly property var textModes: ["none", "state", "exitNode"]
    readonly property var deviceCaps: [3, 5, 10, 20]
    readonly property int defaultDeviceCap: 5

    // The icon: one glyph from the shell's icon font (Nerd Font, Material Design: "vpn", the
    // provider's own glyph in the network widget), and a small mark for an exit node in use
    readonly property string glyph: "󰖂"
    readonly property string exitNodeMark: "󰇧"

    // The word for an attention kind (TailscaleRules' attention kinds), beside the icon
    readonly property var _attentionWords: ({
        "login": "Log in",
        "key-expired": "Key expired",
        "approval": "Needs approval",
        "exit-node-offline": "Exit node offline",
        "read-denied": "No access",
        "other-user": "Other user",
        "service-not-running": "Stopped",
        "not-installed": "Not installed",
        "untrusted": "Not trusted"
    })

    // The client's state as the bar shows it → { kind, tone, mark, word, exitNode }.
    //   kind: absent (no client: the module's main is not there), missing, not-running, unknown,
    //         off, connecting, disconnecting, connected, exit-node, attention
    //   tone: the colour token's role — disabled, primary, pending, accent, warning
    //   mark: true when the exit-node mark shows
    // `client`: TailscaleClient, or a plain object with the same fields (view, entry, cli)
    function summaryOf(client) {
        const result = { kind: "absent", tone: "disabled", mark: false, word: "", exitNode: "" };
        if (!client || !client.view || !client.entry)
            return result;
        const view = client.view;
        const entry = client.entry;
        const phase = String(view.phase ?? "unknown");
        const state = String(entry.state ?? "");
        // The view's attention, else the one an action found (the client holds it: the entry's
        // attention then has no kind of its own)
        const attentionKind = String(view.attention?.kind ?? client.pendingAttention?.kind ?? (entry.attention ? "other" : ""));
        const exitNode = view.exitNode && typeof view.exitNode.name === "string" ? view.exitNode.name : "";
        const set = (kind, tone, word) => Object.assign(result, { kind: kind, tone: tone, word: word });

        if (phase === "missing" || client.cli === "missing")
            return set("missing", "disabled", "Not installed");
        if (phase === "not-running")
            return set("not-running", "disabled", "Stopped");
        // A change in progress first: it says what is happening now
        if (state === "activating")
            return set("connecting", "pending", "Connecting");
        if (state === "deactivating")
            return set("disconnecting", "pending", "Disconnecting");
        if (attentionKind !== "") {
            set("attention", "warning", _attentionWords[attentionKind] ?? "Check");
            result.exitNode = exitNode;
            result.mark = exitNode !== "";
            return result;
        }
        if (state === "activated" && exitNode !== "") {
            set("exit-node", "accent", "On");
            result.exitNode = exitNode;
            result.mark = true;
            return result;
        }
        if (state === "activated")
            return set("connected", "accent", "On");
        if (phase === "unknown")
            return set("unknown", "disabled", "");
        return set("off", "primary", "Off");
    }

    // The text beside the icon: "none" → "", "state" → the word, "exitNode" → the exit node's
    // name (nothing without one). Long names cut at `limit` characters with "…"
    function barText(summary, mode, limit) {
        const most = limit > 0 ? limit : 16;
        let text = "";
        if (mode === "state")
            text = String(summary?.word ?? "");
        else if (mode === "exitNode")
            text = String(summary?.exitNode ?? "");
        return text.length > most ? text.slice(0, most - 1) + "…" : text;
    }

    // A preset's text mode, checked ("none" for anything unknown)
    function textMode(value) {
        return textModes.includes(value) ? value : "none";
    }

    // A preset's device cap, checked (whole, 1–50; the default otherwise)
    function deviceCap(value) {
        const number = Number(value);
        return Number.isInteger(number) && number >= 1 && number <= 50 ? number : defaultDeviceCap;
    }

    // The Taildrop badge → { shown, text }: the count of received files waiting ("9+" past 9),
    // or a dot ("") when files wait but only the bus said so (not the operator: no count)
    function badge(waitingCount, busWaiting, enabled) {
        if (enabled === false)
            return { shown: false, text: "" };
        const count = Number(waitingCount);
        if (count > 0)
            return { shown: true, text: count > 9 ? "9+" : String(count) };
        if (count < 0 && busWaiting === true)
            return { shown: true, text: "" };
        return { shown: false, text: "" };
    }

    // The popup's devices → { shown: [device], more (how many left out), online }: online ones
    // first (the list's own order kept within each group), at most `cap`
    function deviceList(devices, cap) {
        const list = Array.isArray(devices) ? devices.filter(device => device && typeof device === "object") : [];
        const online = list.filter(device => device.online === true);
        const ordered = online.concat(list.filter(device => device.online !== true));
        const most = deviceCap(cap);
        return { shown: ordered.slice(0, most), more: Math.max(0, ordered.length - most), online: online.length };
    }

    // Whether "Send file…" is offered for a device: Taildrop sends only as the operator, while
    // connected, to a device that can receive (the page's device rows and the popup's)
    function canSendTo(device, phase, isOperator) {
        return device?.canReceiveFiles === true && phase === "running" && isOperator === true;
    }
}
