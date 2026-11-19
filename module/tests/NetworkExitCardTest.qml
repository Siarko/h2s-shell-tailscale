import QtQuick
import qs.tests
import ".."

// The exit node per network on the network cards: the element in an opened saved network's
// card (NetworkExitCard) sets and clears that network's choice in the table the live side
// follows (NetworkExitClient); the mark on the card's name line (NetworkExitMark) shows while
// a choice is set, with the choice as its tooltip.
// Against a stand-in client (it runs nothing) and a store in memory.
TestCase {
    id: suite
    suiteName: "tailscale: exit node per network on the network cards"

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
             ["", "No exit node", "Exit node: automatic", "Exit node: home-server"], "the mark's words");
        assertEqual(NetworkExitRules.markLabel({ choice: "nA1", label: "x".repeat(90) }).length, "Exit node: ".length + 40, "… a long name cut");
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

        dropdown.picked("none");
        same([setup.exit.rows[0].choice, cafeMark.visible, cafeMark.label], ["none", true, "No exit node"], "no exit node: a choice too, marked");

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

    function run() {
        rules();
        cardSetsAndClears();
        withoutClient();
    }
}
