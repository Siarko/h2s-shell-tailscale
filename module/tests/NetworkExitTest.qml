import QtQuick
import qs.tests
import ".."

// The exit node per network, live side (NetworkExitClient) against a stand-in client object
// (no processes: what it would run is recorded): the choice waits for Tailscale — network up
// first, Tailscale Running or its peers read later, or Tailscale off and turned on later by the
// user — and is then applied once; a switch deferred while another change runs is applied when
// it ends; a short pass through "no marked network" (a Wi-Fi reconnect) does not apply the
// choice again over a manual change, a lasting one does. A choice not applied (the node offline,
// not the operator, a failed run) leaves the network open, is notified once, and is applied when
// what stopped it changes — never retried in a loop, never with a prompt.
TestCase {
    id: suite
    suiteName: "tailscale: exit node per network, waiting for Tailscale"
    asynchronous: true

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
    readonly property var running: TailscaleRules.parseStatus(fixture("status-rich.json"))
    readonly property var stopped: Object.assign({}, running, { backendState: "Stopped" })
    readonly property var noPeers: Object.assign({}, running, { peers: [], peersRead: false })
    readonly property var nodes: TailscaleRules.exitNodes(running, prefs, "")
    readonly property var online: nodes.own.concat(...nodes.countries.map(country => [].concat(...country.cities.map(city => city.nodes)))).find(option => option.online)
    readonly property var cafeUp: [{ id: "cafe-uuid", name: "Café", kind: "wifi", active: true }]
    readonly property var cafeDown: [{ id: "cafe-uuid", name: "Café", kind: "wifi", active: false }]

    property Component _fakeComponent: Component {
        QtObject {
            property bool running: true
            property string cli: "present"
            property var prefs: null
            property var status: null
            property var exitNodes: ({ own: [], countries: [], count: 0 })
            property bool canChange: true
            property bool busy: false
            property var module: null
            property var ran: []
            // true: every run fails as a refused change would
            property bool failRuns: false
            property var notices: []
            signal failed(string what, string reason)
            onFailed: (what, reason) => notices = notices.concat([reason])
            function _runChange(command, origin, operationName, onSuccess, prepare, onEnd) {
                ran = ran.concat([command.argv.join(" ") + " (" + origin + ")"]);
                const ok = !failRuns;
                Qt.callLater(() => onEnd({ ok: ok, dismissed: false, message: ok ? "" : "Tailscale refused the change." }));
                return true;
            }
        }
    }
    property Component _followerComponent: Component {
        NetworkExitClient {}
    }

    property var _steps: []

    function make(status, exitNodes, extra) {
        const fake = _fakeComponent.createObject(suite, Object.assign({ prefs: prefs, status: status, exitNodes: exitNodes }, extra ?? {}));
        const follower = _followerComponent.createObject(suite, { client: fake, noneMarkedHoldMs: 400 });
        follower.setChoice("cafe-uuid", online.id, online.name, "Café");
        return { fake: fake, follower: follower };
    }

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    function step(waitMs, action) {
        _steps.push({ waitMs: waitMs, action: action });
    }

    // A step that waits for `condition` (checked every 20 ms, at most 5 s), then acts
    function until(description, condition, action) {
        _steps.push({ waitMs: 1, condition: condition, description: description, action: action ?? (() => {}) });
    }

    // A step that acts once everything queued by the change before it has run: the follower
    // reacts to its inputs through Qt.callLater, and a marker queued after them fires after them
    function settled(description, action) {
        let marker = false;
        _steps.push({ waitMs: 1, start: () => Qt.callLater(() => marker = true), condition: () => marker, description: description, action: action });
    }

    property Timer _clock: Timer {
        onTriggered: suite._next()
    }

    property var _waiting: null
    property double _waitingUntil: 0

    function _next() {
        if (_waiting === null && _steps.length > 0 && _steps[0].condition) {
            _waiting = _steps[0];
            _waitingUntil = Date.now() + 5000;
            _waiting.start?.();
        }
        if (_waiting !== null) {
            let ready = false;
            try {
                ready = _waiting.condition();
            } catch (error) {}
            if (!ready && Date.now() < _waitingUntil) {
                _clock.interval = 20;
                _clock.start();
                return;
            }
            _waiting = null;
            if (!ready) {
                fail("timed out waiting: " + _steps[0].description);
                _steps = [];
                finish();
                return;
            }
        }
        const current = _steps.shift();
        if (!current) {
            finish();
            return;
        }
        try {
            current.action();
        } catch (error) {
            fail("threw: " + error);
        }
        _clock.interval = _steps.length > 0 ? _steps[0].waitMs : 1;
        _clock.start();
    }

    function runAsync() {
        const wanted = "tailscale set --exit-node=" + online.argument + " (network)";
        let s = null;

        // Tailscale off when the network comes up; the user turns it on later on the same network
        step(1, () => s = make(stopped, nodes));
        step(1, () => s.follower.networks = cafeUp);
        step(300, () => {
            assertEqual(s.fake.ran.length, 0, "Tailscale off: nothing run (never brought up)");
            assertEqual(s.follower.lastKey, "", "… the network not taken");
            s.fake.status = running;
        });
        step(300, () => {
            assertEqual(JSON.stringify(s.fake.ran), JSON.stringify([wanted]), "turned on later: the choice applied once");
            assertEqual(s.follower.lastKey, "cafe-uuid", "… the network taken");
            s.follower.follow();
        });
        step(200, () => assertEqual(s.fake.ran.length, 1, "… and not again"));

        // Network up first, Tailscale Running but its peers not read yet
        step(1, () => s = make(noPeers, TailscaleRules.exitNodes(noPeers, prefs, "")));
        step(1, () => s.follower.networks = cafeUp);
        step(300, () => {
            assertEqual(s.fake.ran.length, 0, "no peer list yet: waits (the node is not known to be gone)");
            assertEqual(s.follower.decision.kind, "", "… not called unavailable");
            s.fake.exitNodes = nodes;
            s.fake.status = running;
        });
        step(300, () => assertEqual(JSON.stringify(s.fake.ran), JSON.stringify([wanted]), "peers read: applied once"));

        // Another change running: deferred, applied when it ends
        step(1, () => s = make(running, nodes, { busy: true }));
        step(1, () => s.follower.networks = cafeUp);
        step(300, () => {
            assertEqual(s.fake.ran.length, 0, "busy: deferred");
            assertEqual(s.follower.lastKey, "", "… the network not taken");
            s.fake.busy = false;
        });
        step(300, () => assertEqual(JSON.stringify(s.fake.ran), JSON.stringify([wanted]), "the other change ended: applied"));

        // A reconnect (a short pass through no marked network) after a manual change
        step(1, () => s = make(running, nodes));
        step(1, () => s.follower.networks = cafeUp);
        step(300, () => {
            assertEqual(s.fake.ran.length, 1, "applied on the network");
            s.fake.prefs = Object.assign({}, prefs, { exitNodeId: "nManual" });
        });
        step(100, () => s.follower.networks = cafeDown);
        step(100, () => s.follower.networks = cafeUp);
        step(700, () => {
            assertEqual(s.fake.ran.length, 1, "a short drop: the manual choice stays");
            assertEqual(s.follower.lastKey, "cafe-uuid", "… the network still the one acted on");
            s.follower.networks = cafeDown;
        });
        step(700, () => {
            assertEqual(s.follower.lastKey, "", "a lasting drop: taken");
            assertEqual(s.follower.decision.kind, "none-marked", "… as no marked network");
            s.follower.networks = cafeUp;
        });
        step(300, () => assertEqual(s.fake.ran.length, 2, "back after that: applied again"));

        // The chosen node offline when the network comes up: not taken, said once; applied when
        // it comes back
        const offline = { own: nodes.own.map(option => option.id === online.id ? Object.assign({}, option, { online: false }) : option),
                          countries: nodes.countries.map(country => Object.assign({}, country, { cities: country.cities.map(city => Object.assign({}, city, {
                              nodes: city.nodes.map(option => option.id === online.id ? Object.assign({}, option, { online: false }) : option) })) })),
                          count: nodes.count };
        step(1, () => s = make(running, offline));
        step(1, () => s.follower.networks = cafeUp);
        until("decided unavailable", () => s.follower.decision.kind === "unavailable", () => {
            same([s.fake.ran.length, s.follower.lastKey, s.fake.notices.length], [0, "", 1], "node offline: nothing run, the network not taken, said once");
            s.follower.follow();
            s.fake.busy = true;
        });
        settled("inputs changed, the same networks", () => {
            s.fake.busy = false;
        });
        settled("… and back", () => same([s.fake.ran.length, s.fake.notices.length], [0, 1], "asked again: no run, no second notice"));
        step(1, () => s.fake.exitNodes = nodes);
        until("the node back: applied", () => s.follower.decision.kind === "applied", () => {
            same([JSON.stringify(s.fake.ran), s.follower.lastKey, s.fake.notices.length], [JSON.stringify([wanted]), "cafe-uuid", 1], "applied once it came back, the network taken");
        });

        // Not the operator: held and said once; made the operator: applied
        step(1, () => s = make(running, nodes, { canChange: false }));
        step(1, () => s.follower.networks = cafeUp);
        until("decided needs-operator", () => s.follower.decision.kind === "needs-operator", () => {
            same([s.fake.ran.length, s.follower.lastKey, s.fake.notices.length], [0, "", 1], "needs the operator: nothing run, never a prompt, said once");
            s.fake.canChange = true;
        });
        until("applied as the operator", () => s.follower.decision.kind === "applied", () => {
            same([s.fake.ran.length, s.follower.lastKey], [1, "cafe-uuid"], "made the operator: applied");
            assert(s.fake.ran[0].endsWith("(network)"), "… as an automatic change");
        });

        // A run that fails: not taken, said once, not retried in a loop; a new pass on the
        // network tries again
        step(1, () => s = make(running, nodes, { failRuns: true }));
        step(1, () => s.follower.networks = cafeUp);
        until("the run failed", () => s.follower.decision.kind === "failed", () => {
            same([s.fake.ran.length, s.follower.lastKey, s.fake.notices], [1, "", ["Tailscale refused the change."]], "failed: not taken, said once");
            s.fake.busy = true;
        });
        settled("busy", () => s.fake.busy = false);
        settled("not busy again", () => {
            s.follower.follow();
            same([s.fake.ran.length, s.fake.notices.length], [1, 1], "not retried for the same networks, no second notice");
            s.fake.failRuns = false;
            s.follower.networks = cafeDown;
        });
        until("a lasting drop taken", () => s.follower.decision.kind === "none-marked", () => s.follower.networks = cafeUp);
        until("back: tried again", () => s.follower.decision.kind === "applied", () => {
            same([s.fake.ran.length, s.follower.lastKey], [2, "cafe-uuid"], "a new pass on the network: applied");
        });
        step(1, () => {});
        _clock.interval = 1;
        _clock.start();
    }

    Component.onCompleted: {
        if ("timeLimitMs" in suite)
            suite["timeLimitMs"] = 30000;
    }
}
