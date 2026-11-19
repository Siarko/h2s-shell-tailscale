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
// what stopped it changes — never retried in a loop, never with a prompt. A choice made by hand
// "for now" holds the networks' choices off until "Default" or a wake, which go back to them —
// or, with no marked network up, to no exit node. The stand-in client runs one change at a
// time, as the client does (busy).
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
            // What a failed run says (the CLI's words: made plain before shown)
            property string failMessage: "Tailscale refused the change."
            property var notices: []
            // Serve's check after a Funnel (client.serve.checking)
            property QtObject serve: QtObject {
                property bool checking: false
            }
            // true: a run's end waits for finishRun() (a run still going when something changes)
            property bool holdRuns: false
            property var _heldEnd: null
            signal failed(string what, string reason)
            onFailed: (what, reason) => notices = notices.concat([reason])
            // As the client's: one change at a time — refused while busy (said through onEnd),
            // busy while it runs, cleared before its end is answered
            function _runChange(command, origin, operationName, onSuccess, prepare, onEnd) {
                if (busy) {
                    onEnd({ ok: false, dismissed: false, message: "Another Tailscale change is running." });
                    return false;
                }
                ran = ran.concat([command.argv.join(" ") + " (" + origin + ")"]);
                busy = true;
                const ok = !failRuns;
                const end = () => {
                    busy = false;
                    onEnd({ ok: ok, dismissed: false, message: ok ? "" : failMessage });
                };
                if (holdRuns)
                    _heldEnd = end;
                else
                    Qt.callLater(end);
                return true;
            }
            function finishRun() {
                const end = _heldEnd;
                _heldEnd = null;
                end?.();
            }
        }
    }
    // The module and its store, as the follower reaches them (client.module.store)
    property Component _moduleComponent: Component {
        QtObject {
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

    // A follower started again on the same client and store (a restart of the shell)
    function restart(s) {
        // Inert at once (destroy is deferred: it must not act on what the test changes next)
        s.follower.client = null;
        s.follower.destroy();
        s.follower = _followerComponent.createObject(suite, { client: s.fake, noneMarkedHoldMs: 400 });
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
        // An exit node picked outside the module (prefs only)
        const manualPrefs = Object.assign({}, prefs, { exitNodeId: "nManual" });
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

        // The shell's networks not read whole yet (Api.networksReady false, module API 1.16):
        // nothing decided, even with a network listed; read whole, the choice applies. Read
        // whole and none up: decided ("none up"), the key taken — never taken as "not read"
        step(1, () => {
            s = make(running, nodes, { module: _moduleComponent.createObject(suite) });
            s.follower.networksReady = false;
            s.follower.networks = cafeUp;
        });
        step(300, () => {
            same([s.fake.ran.length, s.follower.decision.kind, s.follower.lastKey], [0, "", ""], "networks not read whole: nothing decided, nothing run");
            s.follower.networksReady = true;
        });
        step(300, () => {
            same([s.fake.ran, s.follower.lastKey], [[wanted], "cafe-uuid"], "read whole: the choice applied once, the café taken");
            // A restart: no networks yet, and not read whole (the default while the list is empty)
            restart(s);
        });
        step(600, () => {
            same([s.follower.networksReady, s.follower.lastKey, s.fake.ran.length], [false, "cafe-uuid", 1],
                 "restarted, the networks not read yet: the café still taken, nothing done (not taken as \"none up\")");
            s.follower.networksReady = true;
        });
        until("read whole, none up: the drop taken once it lasted", () => s.follower.lastKey === "",
              () => assertEqual(s.fake.ran.length, 1, "… nothing run"));

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
        step(1, () => s = make(running, nodes, { failRuns: true, failMessage: "Tailscale <b>refused</b>\nthe change & more" }));
        step(1, () => s.follower.networks = cafeUp);
        until("the run failed", () => s.follower.decision.kind === "failed", () => {
            same([s.fake.ran.length, s.follower.lastKey, s.fake.notices], [1, "", ["Tailscale ‹b›refused‹/b› the change ＆ more"]], "failed: not taken, said once, as plain text");
            assertEqual(s.follower.decision.text, "Tailscale ‹b›refused‹/b› the change ＆ more", "… the page's line plain too");
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

        // Held (node offline), then an exit node picked by hand: the networks taken, and the
        // node coming back does not switch it
        step(1, () => s = make(running, offline));
        step(1, () => s.follower.networks = cafeUp);
        until("held: unavailable", () => s.follower.decision.kind === "unavailable", () => s.fake.prefs = manualPrefs);
        until("the pick by hand seen", () => s.follower.decision.kind === "manual", () => {
            assertEqual(s.follower.lastKey, "cafe-uuid", "a pick by hand while held: the networks taken");
            s.fake.exitNodes = nodes;
        });
        settled("the node back", () => same([s.fake.ran.length, s.fake.notices.length], [0, 1], "… the node back: the pick by hand stays"));

        // Needs the operator, a pick by hand, then made the operator: nothing switched
        step(1, () => s = make(running, nodes, { canChange: false }));
        step(1, () => s.follower.networks = cafeUp);
        until("held: needs-operator", () => s.follower.decision.kind === "needs-operator", () => s.fake.prefs = manualPrefs);
        until("the pick by hand seen", () => s.follower.decision.kind === "manual", () => s.fake.canChange = true);
        settled("made the operator", () => same([s.fake.ran.length, s.follower.lastKey], [0, "cafe-uuid"], "made the operator after a pick by hand: nothing run"));

        // A restart while held: the hold comes back from the store; a pick by hand made
        // meanwhile stays, and without one the choice is applied when the node is back
        step(1, () => s = make(running, offline, { module: _moduleComponent.createObject(suite) }));
        step(1, () => s.follower.networks = cafeUp);
        until("held before the restart", () => s.follower.decision.kind === "unavailable", () => {
            assertEqual(s.fake.module.store.get("exitByNetwork.held", null)?.kind, "unavailable", "the hold kept in the store");
        });
        settled("before the restart", () => {
            restart(s);
            s.fake.prefs = manualPrefs;
            s.fake.exitNodes = nodes;
            s.follower.networks = cafeUp;
        });
        until("after the restart: the pick by hand seen", () => s.follower.decision.kind === "manual", () => {
            same([s.fake.ran.length, s.fake.notices.length, s.follower.lastKey], [0, 1, "cafe-uuid"], "restarted: the pick by hand stays, no second notice");
            assertEqual(s.fake.module.store.get("exitByNetwork.held", null), null, "… the hold gone from the store");
        });
        step(1, () => s = make(running, offline, { module: _moduleComponent.createObject(suite) }));
        step(1, () => s.follower.networks = cafeUp);
        until("held before the restart", () => s.follower.decision.kind === "unavailable");
        settled("before the restart", () => {
            restart(s);
            s.follower.networks = cafeUp;
        });
        settled("restarted, the node still offline", () => {
            same([s.fake.ran.length, s.fake.notices.length], [0, 1], "restarted with the node offline: still held, no second notice");
            s.fake.exitNodes = nodes;
        });
        until("the node back after the restart", () => s.follower.decision.kind === "applied", () => assertEqual(s.fake.ran.length, 1, "applied once"));

        // Refused while this computer offers an exit node; offering stopped outside the
        // module: applied
        step(1, () => s = make(running, nodes, { prefs: Object.assign({}, prefs, { advertiseExitNode: true }) }));
        step(1, () => s.follower.networks = cafeUp);
        until("held: refused", () => s.follower.decision.kind === "refused", () => s.fake.prefs = prefs);
        until("offering stopped: applied", () => s.follower.decision.kind === "applied", () => assertEqual(s.fake.ran.length, 1, "applied once"));

        // Serve's check after a Funnel waits for the lock: no automatic change takes it
        step(1, () => s = make(running, nodes));
        step(1, () => {
            s.fake.serve.checking = true;
            s.follower.networks = cafeUp;
        });
        settled("Serve checking", () => {
            same([s.fake.ran.length, s.follower.lastKey], [0, ""], "deferred while Serve checks");
            s.fake.serve.checking = false;
        });
        until("Serve done: applied", () => s.follower.decision.kind === "applied", () => assertEqual(s.fake.ran.length, 1, "applied once"));

        // A choice made by hand "for now" (the chooser: chosenByHand) wins over the network's:
        // nothing applied while it lasts, whatever networks come and go; "Default" ends it and
        // the network's choice applies again
        step(1, () => s = make(running, nodes, { module: _moduleComponent.createObject(suite) }));
        step(1, () => s.follower.networks = cafeUp);
        until("applied on the network", () => s.follower.decision.kind === "applied", () => {
            assertEqual(s.follower.effect.kind, "", "applied, the prefs not read again yet: not called in effect");
            // The daemon's prefs after the change (the stand-in runs nothing)
            s.fake.prefs = Object.assign({}, prefs, { exitNodeId: online.id });
            same([s.follower.effect.kind, s.follower.effect.network], ["network", "Café"], "… read: the network's choice in effect, for Café");
            s.fake.prefs = manualPrefs;
            assertEqual(s.follower.effect.kind, "", "… changed outside the shell: not called the network's");
            s.fake.prefs = manualPrefs;
            s.follower.chosenByHand();
            same([s.follower.overridden, s.follower.lastKey, s.fake.module.store.get("exitByNetwork.lastKey", null), s.follower.effect.kind],
                 [true, "", "", "override"], "chosen by hand: for now, the networks left open (also in the store)");
            s.follower.networks = cafeDown;
        });
        step(700, () => s.follower.networks = cafeUp);
        settled("back on the network while the choice by hand lasts", () => {
            same([s.fake.ran.length, s.follower.decision.kind, s.follower.lastKey], [1, "override", ""], "the network again: the choice by hand stays, nothing run");
            assert(s.follower.dropOverride(), "\"Default\": the choice by hand dropped");
            assert(!s.follower.dropOverride(), "… once");
        });
        until("the network's choice applied again", () => s.follower.decision.kind === "applied", () => {
            same([s.fake.ran.length, s.follower.lastKey, s.follower.overridden], [2, "cafe-uuid", false], "\"Default\": the network's choice applied again, the network taken");
            same(s.fake.ran[1], wanted, "… the network's node");
        });

        // A restart during a choice by hand: it is gone (memory only), the network's applies
        step(1, () => {
            s.fake.prefs = manualPrefs;
            s.follower.chosenByHand();
        });
        settled("chosen by hand", () => {
            restart(s);
            s.follower.networks = cafeUp;
        });
        until("after the restart: the network's choice applied", () => s.follower.decision.kind === "applied", () => {
            same([s.follower.overridden, s.fake.ran.length], [false, 3], "restarted: no choice by hand, the network's applied");
        });

        // "for now" ended with no marked network up: no exit node. "Default" at once; a wake once
        // "no marked network up" lasted (the network often comes back after a wake), and the
        // network's choice when it does; not the operator: held and said, never a prompt; two
        // networks that differ: nothing
        const usingPrefs = Object.assign({}, prefs, { exitNodeId: "nManual" });
        const none = "tailscale set --exit-node= (network)";
        const endsWith = (list, line) => list.length > 0 && list[list.length - 1].endsWith(line);
        step(1, () => s = make(running, nodes, { prefs: usingPrefs, module: _moduleComponent.createObject(suite) }));
        step(1, () => s.follower.networks = cafeDown);
        settled("no marked network up", () => {
            same([s.fake.ran.length, s.follower.lastKey], [0, ""], "no marked network up: nothing run");
            s.follower.chosenByHand();
            assertEqual(s.follower.effect.kind, "override", "chosen by hand with no marked network up: \"for now\"");
            assertEqual(s.follower.effect.from, "none", "… \"Default\" brings back no exit node");
            assert(s.follower.dropOverride(), "\"Default\"");
        });
        until("\"Default\": the exit node turned off", () => s.follower.decision.kind === "applied", () => {
            same([s.fake.ran.length, endsWith(s.fake.ran, "--exit-node= (network)"), s.follower.lastKey], [1, true, ""], "\"Default\", no marked network up: no exit node, at once");
            s.fake.prefs = prefs;
            s.follower.follow();
        });
        settled("and then", () => assertEqual(s.fake.ran.length, 1, "… once"));
        // None in use already: nothing run
        step(1, () => {
            s.follower.chosenByHand();
            s.follower.dropOverride();
        });
        until("none in use: already", () => s.follower.decision.kind === "already", () => same([s.fake.ran.length, s.follower.lastKey], [1, ""], "none in use: nothing run"));
        // A wake: once it lasted
        step(1, () => {
            s.fake.prefs = usingPrefs;
            s.follower.chosenByHand();
            s.follower.dropOverride(true);
        });
        settled("woken", () => {
            same([s.fake.ran.length, s.follower.overridden, s.follower._noneMarkedTimer.running], [1, false, true], "a wake, no marked network up: waits for the networks first");
        });
        until("it lasted: turned off", () => s.fake.ran.length === 2, () => same([s.fake.ran[1], s.follower.decision.kind], [none, "applied"], "… then no exit node"));
        // A wake, then the network comes back with its choice: that choice, no "off" first
        step(1, () => {
            s.fake.prefs = usingPrefs;
            s.follower.chosenByHand();
            s.follower.dropOverride(true);
        });
        step(100, () => s.follower.networks = cafeUp);
        until("the network back after the wake", () => s.fake.ran.length === 3, () => {
            same([s.fake.ran[2], s.follower.lastKey], [wanted, "cafe-uuid"], "a wake, the network back within the hold: its choice, never \"off\" first");
        });
        settled("past the hold", () => assertEqual(s.fake.ran.length, 3, "… and nothing more"));
        // Not the operator
        step(1, () => s = make(running, nodes, { prefs: usingPrefs, canChange: false }));
        step(1, () => s.follower.networks = cafeDown);
        settled("no marked network up", () => {
            s.follower.chosenByHand();
            s.follower.dropOverride();
        });
        until("needs the operator", () => s.follower.decision.kind === "needs-operator", () => {
            same([s.fake.ran.length, s.fake.notices], [0, ["Needs the operator"]], "not the operator: nothing run, never a prompt, said once");
        });
        // Two marked networks up that differ: "Default" brings back nothing to apply
        step(1, () => {
            s = make(running, nodes, { prefs: usingPrefs });
            s.follower.setChoice("home-uuid", "none", "", "Home");
            s.follower.networks = cafeUp.concat([{ id: "home-uuid", name: "Home", kind: "ethernet", active: true }]);
        });
        until("conflict", () => s.follower.decision.kind === "conflict", () => {
            s.follower.chosenByHand();
            same([s.follower.effect.kind, s.follower.effect.from], ["override", "conflict"], "two networks that differ, chosen by hand: \"for now\", nothing to bring back");
            s.follower.dropOverride();
        });
        until("conflict again", () => s.follower.decision.kind === "conflict", () => assertEqual(s.fake.ran.length, 0, "\"Default\": nothing run"));

        step(1, () => {});
        _clock.interval = 1;
        _clock.start();
    }

    Component.onCompleted: {
        if ("timeLimitMs" in suite)
            suite["timeLimitMs"] = 30000;
    }
}
