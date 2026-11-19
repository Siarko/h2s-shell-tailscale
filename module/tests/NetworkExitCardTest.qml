import QtQuick
import qs.tests
import ".."

// The exit node per network on the network cards: the element in an opened saved network's
// card (NetworkExitCard) sets and clears that network's choice in the table the live side
// follows (NetworkExitClient); the mark on the card's name line (NetworkExitMark) shows while
// the network routes through an exit node, with the choice as its tooltip (the shell's
// HoverTip), the same on the network popup's rows. The exit-node chooser says which choice is in effect ("for now", "for Café") and
// offers "Default" while one made by hand lasts.
// Against a stand-in client (it runs nothing) and a store in memory.
TestCase {
    id: suite
    suiteName: "tailscale: exit node per network on the network cards and in the chooser"

    function fixture(name) {
        const view = Qt.createQmlObject("import Quickshell.Io\nFileView { blockLoading: true }", suite, "fixture");
        view.path = Qt.resolvedUrl("../../fixtures/" + name);
        const text = view.text();
        view.destroy();
        if (!text)
            fail("fixture " + name + " is empty or missing");
        return text;
    }

    readonly property var prefs: TailscaleRules.parsePrefs(fixture("prefs-running.json"))
    readonly property var status: TailscaleRules.parseStatus(fixture("status-rich.json"))
    readonly property var nodes: TailscaleRules.exitNodes(status, prefs, "")

    property Component _clientComponent: Component {
        QtObject {
            // Not running: the live side decides nothing here (NetworkExitTest has that)
            property bool running: false
            property string cli: "present"
            property var prefs: null
            property var status: null
            property var exitNodes: ({ own: [], countries: [], count: 0 })
            property bool canChange: true
            property bool busy: false
            property var networkExit: null
            property QtObject serve: QtObject {
                property bool checking: false
            }
            property QtObject module: QtObject {
                property QtObject store: QtObject {
                    property var data: ({})
                    function get(key, fallback) {
                        return Object.prototype.hasOwnProperty.call(data, key) ? data[key] : fallback;
                    }
                    function set(key, value) {
                        const next = Object.assign({}, data);
                        if (value === undefined)
                            delete next[key];
                        else
                            next[key] = JSON.parse(JSON.stringify(value));
                        data = next;
                        return true;
                    }
                }
            }
            signal failed(string what, string reason)
        }
    }
    property Component _followerComponent: Component {
        NetworkExitClient {}
    }
    property Component _cardComponent: Component {
        NetworkExitCard {
            width: 500
        }
    }
    property Component _markComponent: Component {
        NetworkExitMark {}
    }
    property Component _chooserComponent: Component {
        ExitNodeChooser {
            width: 500
        }
    }
    // The live side as the chooser reads it: what is in effect, and "Default"
    property Component _effectComponent: Component {
        QtObject {
            property var effect: ({ kind: "override", from: "network", network: "Café", label: "No exit node" })
            property int drops: 0
            function dropOverride() {
                drops++;
                effect = { kind: "network", from: "network", network: "Café", label: "No exit node" };
                return true;
            }
        }
    }
    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    function findNamed(item, name) {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (const child of item.children ?? []) {
            const found = findNamed(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function textsWith(item, needle) {
        const found = [];
        const walk = node => {
            if (!node)
                return;
            if (node instanceof Text && String(node.text).indexOf(needle) >= 0)
                found.push(node);
            for (const child of node.children ?? [])
                walk(child);
        };
        walk(item);
        return found;
    }

    function make(extra) {
        const client = _clientComponent.createObject(suite, Object.assign({ prefs: prefs, status: status, exitNodes: nodes }, extra ?? {}));
        client.networkExit = _followerComponent.createObject(suite, { client: client });
        const module = { main: { client: client } };
        return { client: client, exit: client.networkExit, module: module };
    }

    // A parent for the views: an item without one stays hidden once it was hidden
    property Item _holder: Item {}

    function card(setup, networkId, name) {
        return _cardComponent.createObject(_holder, { module: setup.module, context: { networkId: networkId, name: name, kind: "wifi", active: false } });
    }

    function mark(setup, networkId, name) {
        return _markComponent.createObject(_holder, { module: setup.module, context: { networkId: networkId, name: name, kind: "wifi", active: false } });
    }

    function rules() {
        const own = [{ id: "nA1", name: "home-server", label: "home-server (x)" }, { id: "none", name: "bad" }, { id: "bad id!", name: "bad" }];
        same(NetworkExitRules.cardOptions(own, null).map(option => option.value), ["", "none", "auto", "nA1"],
             "the card's choices: not set, none, automatic, the tailnet's own nodes (odd ids left out)");
        assertEqual(NetworkExitRules.cardOptions(own, null)[3].label, "home-server", "… a node by its name");
        same(NetworkExitRules.cardOptions(own, { id: "x", choice: "nGONE", label: "old-node", name: "Café" }).slice(-1),
             [{ value: "nGONE", label: "old-node", name: "old-node" }], "a chosen node no longer listed: kept, by its name");
        same(NetworkExitRules.rowFor({ "cafe-uuid": { choice: "auto" } }, "cafe-uuid"), { id: "cafe-uuid", choice: "auto", label: "", name: "" }, "one network's row");
        assertEqual(NetworkExitRules.rowFor({ "cafe-uuid": { choice: "auto" } }, "home-uuid"), null, "… null when not marked");
        same([NetworkExitRules.markLabel(null), NetworkExitRules.markLabel({ choice: "none", label: "" }), NetworkExitRules.markLabel({ choice: "auto", label: "" }),
              NetworkExitRules.markLabel({ choice: "nA1", label: "home-server" })],
             ["", "", "Exit node: automatic", "Exit node: home-server"], "the mark's words: none for \"No exit node\" (no mark)");
        assertEqual(NetworkExitRules.markLabel({ choice: "nA1", label: "x".repeat(90) }).length, "Exit node: ".length + 40, "… a long name cut");

        // Names from other devices on one line: control and bidi characters gone, capped
        const odd = "home\n\u202eserver\u0007\u200b " + "y".repeat(120);
        const oddRow = NetworkExitRules.rows({ "cafe-uuid": { choice: "nA1", label: odd, name: "Caf\u00e9\r\nWi-Fi\u2066" } })[0];
        same([oddRow.label.indexOf("\n"), oddRow.label.indexOf("\u202e"), oddRow.label.indexOf("\u200b"), oddRow.label.length <= 100, oddRow.name],
             [-1, -1, -1, true, "Café Wi-Fi"], "a stored node's label and network's name: one line, no control or bidi characters, capped");
        assert(oddRow.label.startsWith("home server "), "… the words kept: " + oddRow.label);
        assert(!/[\u0000-\u001f\u202a-\u202e]/.test(NetworkExitRules.choiceLabel({ choice: "nA1", label: "a\nb\u202ec" })), "a choice's label on one line");
        assert(!/[\u0000-\u001f\u202a-\u202e]/.test(NetworkExitRules.markLabel({ choice: "nA1", label: "a\nb\u202ec" })), "… and the mark's");
        same(NetworkExitRules.cardOptions([{ id: "nA1", name: "a\n\u202eb" }], null)[3], { value: "nA1", label: "a b", name: "a b" }, "… and the card's options");
        same(NetworkExitRules.defaultDetail({ kind: "override", from: "network", network: "Café", label: "x\ny" }), "Café: x y", "… and \"Default\"'s detail");
        const oddStatus = JSON.parse(fixture("status-rich.json"));
        const exitPeer = Object.keys(oddStatus.Peer ?? {}).find(key => oddStatus.Peer[key].ExitNodeOption === true && !(oddStatus.Peer[key].Location));
        if (exitPeer !== undefined) {
            oddStatus.Peer[exitPeer].DNSName = "";
            oddStatus.Peer[exitPeer].HostName = "evil\n\u202ehost";
            const parsed = TailscaleRules.exitNodes(TailscaleRules.parseStatus(JSON.stringify(oddStatus)), prefs, "");
            const option = parsed.own.find(item => item.name.indexOf("evil") === 0);
            same([option?.name, option?.label], ["evil host", "evil host"], "an exit node named by a raw host name: on one line in the chooser");
        } else {
            fail("the fixture has an exit node of its own");
        }
    }

    function cardSetsAndClears() {
        const setup = make();
        const online = nodes.own.find(option => option.online);
        assert(online !== undefined, "the fixture has an online exit node of its own");
        const view = card(setup, "cafe-uuid", "Café");
        const other = card(setup, "home-uuid", "Home");
        const cafeMark = mark(setup, "cafe-uuid", "Café");
        const homeMark = mark(setup, "home-uuid", "Home");
        assert(view.visible, "the card's element shows");
        const dropdown = findNamed(view, "tailscaleNetworkExitChoice");
        assert(dropdown !== null, "… with its dropdown");
        same(dropdown.options.slice(0, 3).map(option => option.value), ["", "none", "auto"], "… not set, none, automatic first");
        assert(dropdown.options.some(option => option.value === online.id), "… then the tailnet's exit nodes");
        assertEqual(dropdown.value, "", "nothing set: \"Not set\"");
        same([cafeMark.visible, cafeMark.label], [false, ""], "nothing set: no mark on the name line");

        dropdown.picked(online.id);
        same(NetworkExitRules.rows(setup.exit.table), [{ id: "cafe-uuid", choice: online.id, label: online.name, name: "Café" }],
             "a node picked: the network marked with it, its name and the network's kept");
        same(setup.client.module.store.get("exitByNetwork", null), { "cafe-uuid": { choice: online.id, label: online.name, name: "Café" } }, "… in the module's store");
        assertEqual(dropdown.value, online.id, "… the dropdown shows it");
        same([cafeMark.visible, cafeMark.label, cafeMark.Accessible.name], [true, "Exit node: " + online.name, "Exit node: " + online.name],
             "… the mark on the network's name line, the node in its tooltip and accessible name");
        same([homeMark.visible, findNamed(other, "tailscaleNetworkExitChoice").value], [false, ""], "… another network untouched");

        const tip = findNamed(cafeMark, "tailscaleNetworkExitTip");
        same([tip !== null, tip?.text, tip?.target === cafeMark], [true, "Tailscale: Exit node: " + online.name, true], "… the tooltip: the shell's HoverTip on the mark");

        dropdown.picked("none");
        same([setup.exit.rows[0].choice, cafeMark.visible, cafeMark.label, tip.text], ["none", false, "", ""],
             "no exit node: a choice (the dropdown keeps it), but no mark on the name line");
        assertEqual(dropdown.value, "none", "… the dropdown shows it");

        dropdown.picked("");
        same([setup.exit.rows.length, cafeMark.visible, dropdown.value], [0, false, ""], "\"Not set\": the mark removed, the mark gone");

        // Not the operator: said under the choice
        const hint = textsWith(view, "Needs the operator")[0];
        assert(hint !== undefined, "an operator hint exists");
        setup.client.canChange = false;
        assertEqual(hint.visible, false, "not the operator, nothing set: no hint");
        dropdown.picked("auto");
        assertEqual(hint.visible, true, "… set: \"Needs the operator\"");

        // Why the choice is not applied, when the last decision is about this network
        const problem = findNamed(view, "tailscaleNetworkExitProblem");
        setup.exit.decision = { kind: "unavailable", key: "cafe-uuid home-uuid", text: "The chosen exit node is not available" };
        same([problem.visible, problem.text, problem.textFormat], [true, "The chosen exit node is not available", Text.PlainText], "the reason, plain");
        assertEqual(findNamed(other, "tailscaleNetworkExitProblem").text, "The chosen exit node is not available", "… on each card of those networks");
        setup.exit.decision = { kind: "unavailable", key: "work-uuid", text: "The chosen exit node is not available" };
        assertEqual(problem.visible, false, "… not on a card of another network");

        // Tailscale not installed: only a network with a choice shows it
        setup.client.cli = "missing";
        same([view.visible, other.visible], [true, false], "Tailscale missing: the set network's choice shown, the others' element hidden");
        for (const item of [view, other, cafeMark, homeMark])
            item.destroy();
    }

    function withoutClient() {
        const view = _cardComponent.createObject(null, { module: { main: null }, context: null });
        const markItem = _markComponent.createObject(null, { module: null, context: null });
        same([view.visible, markItem.visible], [false, false], "the module off (no main), no context: nothing shown, nothing thrown");
        view.destroy();
        markItem.destroy();
    }

    function chooserDefault() {
        const exit = _effectComponent.createObject(suite);
        const picked = [];
        const client = { busy: false, canChange: true, view: { phase: "running", exitNode: null }, exitNodes: nodes, networkExit: exit,
                         setExitNode: option => picked.push(option) };
        const chooser = _chooserComponent.createObject(_holder, { client: client });
        const effectText = findNamed(chooser, "tailscaleExitNodeEffect");
        same([effectText?.visible, effectText?.text, effectText?.textFormat], [true, "for now", Text.PlainText], "chosen by hand: the header says \"for now\"");
        // With no choice for the networks up, "Default" is offered too: it turns the exit node off
        exit.effect = { kind: "override", from: "none", network: "", label: "No exit node" };
        same([chooser._rows[0].key, chooser._rows[0].detail], ["default", "No exit node"], "no network's choice up: \"Default\" offered, bringing back no exit node");
        exit.effect = { kind: "override", from: "network", network: "Café", label: "No exit node" };
        same([chooser._rows[0].key, chooser._rows[0].label, chooser._rows[0].detail, chooser._rows[1].key], ["default", "Default", "Café: No exit node", "none"],
             "… the list starts with \"Default\", naming what it brings back, then \"None\"");
        chooser.expanded = true;
        const row = findNamed(chooser, "tailscaleExitNode-0");
        const area = Array.from(row?.children ?? []).find(child => child instanceof MouseArea) ?? null;
        assert(area !== null, "… its row is shown, with its pointer area");
        area?.clicked(null);
        same([exit.drops, picked.length, chooser.expanded], [1, 0, false], "\"Default\" clicked: the choice by hand dropped, no exit node set by the chooser, the list closed");
        same([effectText.text, chooser._rows[0].key], ["for Café", "none"], "… then \"for Café\", no \"Default\" any more");
        exit.effect = { kind: "", from: "", network: "", label: "" };
        assertEqual(effectText.visible, false, "nothing in effect: no words");
        chooser.destroy();
        exit.destroy();
    }

    // The network popup's rows (module API 1.32): the same mark on a Wi-Fi network in range
    // and on the wired line, with the context the shell gives there. A saved network: its
    // profile's id; a Wi-Fi network not saved, or the wired line with no profile up: id ""
    function popupRows() {
        const setup = make();
        const online = nodes.own.find(option => option.online);
        const popupMark = (networkId, name, kind) => _markComponent.createObject(_holder, {
            module: setup.module, context: { networkId: networkId, name: name, kind: kind, active: true } });
        const wifi = popupMark("cafe-uuid", "Café", "wifi");
        const wired = popupMark("wired-uuid", "Wired connection 1", "ethernet");
        const unsaved = popupMark("", "Café", "wifi");
        const noProfile = popupMark("", "", "ethernet");
        setup.exit.setChoice("cafe-uuid", online.id, online.name, "Café");
        setup.exit.setChoice("wired-uuid", "auto", "", "Wired connection 1");
        same([wifi.visible, wifi.label, wired.visible, wired.label], [true, "Exit node: " + online.name, true, "Exit node: automatic"],
             "popup: a saved Wi-Fi row and the wired line, each with an exit node set, marked");
        same([unsaved.visible, unsaved.label, noProfile.visible], [false, "", false],
             "… a Wi-Fi network in range that is not saved (networkId \"\"), and the wired line with no profile up: no mark");
        setup.exit.setChoice("cafe-uuid", "none", "", "Café");
        setup.exit.setChoice("wired-uuid", "none", "", "Wired connection 1");
        same([wifi.visible, wired.visible], [false, false], "… \"No exit node\" on both: no mark");
        for (const item of [wifi, wired, unsaved, noProfile])
            item.destroy();
    }

    function run() {
        rules();
        cardSetsAndClears();
        popupRows();
        withoutClient();
        chooserDefault();
    }
}
