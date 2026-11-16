import QtQuick
import qs.tests
import ".."

// The exit node per network, live side (NetworkExitClient) against a stand-in client object
// (no processes: what it would run is recorded): the choice waits for Tailscale — network up
// first, Tailscale Running or its peers read later, or Tailscale off and turned on later by the
// user — and is then applied once; a switch deferred while another change runs is applied when
// it ends; a short pass through "no marked network" (a Wi-Fi reconnect) does not apply the
// choice again over a manual change, a lasting one does.
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
            function _runChange(command, origin, operationName, onSuccess, prepare, onEnd) {
                ran = ran.concat([command.argv.join(" ") + " (" + origin + ")"]);
                Qt.callLater(() => onEnd({ ok: true, dismissed: false, message: "" }));
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

    function step(waitMs, action) {
        _steps.push({ waitMs: waitMs, action: action });
    }

    property Timer _clock: Timer {
        onTriggered: suite._next()
    }

    function _next() {
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
        step(1, () => {});
        _clock.interval = 1;
        _clock.start();
    }

    Component.onCompleted: {
        if ("timeLimitMs" in suite)
            suite["timeLimitMs"] = 30000;
    }
}
