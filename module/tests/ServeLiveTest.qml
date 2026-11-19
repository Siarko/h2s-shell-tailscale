import QtQuick
import Quickshell
import qs.api
import qs.tests
import ".."
import "liveSuites.js" as LiveSuites

// Delivery step 5 live (ServeClient, CertClient, LockClient, NetworkExitClient on the client's
// runner) against the stand-ins: sharing a port through pkexec and seeing it with its link,
// Funnel on (the public mark), HTTPS off refused before anything runs, a certificate got by the
// operator into a private folder (and refused for anyone else), locked out by tailnet lock
// (attention), an exit node set for a network as the operator and not otherwise.
TestCase {
    id: suite
    suiteName: "tailscale: serve, certificates, lock, exit node per network against the stand-ins"
    asynchronous: true
    Component.onCompleted: {
        LiveSuites.register(suite);
        if ("timeLimitMs" in suite)
            suite["timeLimitMs"] = 120000;
    }

    function _path(url) {
        return String(url).replace(/^file:\/\//, "").replace(/\/+$/, "");
    }

    readonly property string standIns: _path(Qt.resolvedUrl("stand-in"))
    readonly property string fixtures: _path(Qt.resolvedUrl("../../fixtures"))
    readonly property string base: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ts-serve-" + Date.now()

    property var _scenarios: []
    property var _all: []
    property Component _clientComponent: Component {
        TailscaleClient {}
    }
    property CommandAction _shell: CommandAction {}
    property Component _moduleComponent: Component {
        ScenarioHandle {}
    }

    // options: { env {}, setup (sh lines, $1 the scenario's directory) }
    function scenario(name, options) {
        const dir = base + "/" + name;
        const s = { name: name, dir: dir, log: dir + "/log", pkexecLog: dir + "/pkexec.log", client: null, failures: [], steps: [], started: false,
                    options: options ?? {} };
        s.env = Object.assign({
            TS_FAKE_STATE_DIR: dir + "/state", TS_FAKE_LOG: s.log, TS_FAKE_PKEXEC_LOG: s.pkexecLog, TS_FAKE_USER: "tester",
            TS_FAKE_FIXTURES: fixtures, TS_FAKE_BUS_FILE: dir + "/bus.jsonl", TS_FAKE_BUS_FOLLOW: "1", TS_FAKE_BUS_HOLD: "28"
        }, s.options.env ?? {});
        _scenarios.push(s);
        _all.push(s);
        then(s, "set up", () => s.ready === true, () => {});
        s.steps[0].start = () => {
            const lines = ["mkdir -p \"$1/state/inbox\" \"$1/downloads\" \"$1/files\"", ": > \"$1/log\"", ": > \"$1/pkexec.log\"",
                "printf 'running\\n' > \"$1/state/scenario\"", "echo '{\"Health\":{\"Warnings\":{}}}' > \"$1/bus.jsonl\""].concat(s.options.setup ?? []);
            _shell.run(["sh", "-c", lines.join(" && "), "sh", dir], result => {
                if (!result.ok)
                    fail(name + ": set up failed: " + result.error);
                s.module = _moduleComponent.createObject(suite);
                s.client = _clientComponent.createObject(suite, {
                    module: s.module, environment: s.env, readDebounceMs: 100, streamBackoffMinMs: 200, streamBackoffMaxMs: 800, pollMs: 5000,
                    readRetryMinMs: 300, readRetryMaxMs: 1200
                });
                s.client.cert.certDir = dir + "/certs";
                s.client.tailnetLock.lockSettleMs = 1500;
                s.client.failed.connect((what, reason) => s.failures.push({ what: what, reason: reason }));
                s.client.running = true;
                s.ready = true;
            });
        };
        return s;
    }

    // timeoutMs: how long the step may wait for its condition (12 s when not given)
    function then(s, description, condition, action, start, timeoutMs) {
        s.steps.push({ description: description, condition: condition, action: action, start: start ?? null, timeoutMs: timeoutMs ?? 12000 });
    }

    // Runs `script` (sh -c, $1 the scenario's directory) and stores its output's lines in s[key]
    function thenShell(s, description, script, key, action) {
        then(s, description, () => s[key] !== undefined, () => action(s[key]), () => {
            s[key] = undefined;
            _shell.run(["sh", "-c", script, "sh", s.dir], result => s[key] = result.lines.map(line => line.trim()).filter(line => line !== ""));
        });
    }

    function logs(s, description, action) {
        thenShell(s, description + " (logs read)", "cat \"$1/log\"; echo '----'; cat \"$1/pkexec.log\"", "_logLines", lines => {
            const cut = lines.indexOf("----");
            s.logLines = lines.slice(0, cut);
            s.pkexecLines = lines.slice(cut + 1);
            action();
        });
    }

    function waitMs(s, ms) {
        let until = 0;
        then(s, "wait " + ms + " ms", () => Date.now() >= until, () => {}, () => until = Date.now() + ms);
    }

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    function count(lines, pattern) {
        return (lines ?? []).filter(line => pattern.test(line)).length;
    }

    function rx(text) {
        return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    function busReady(s) {
        return s.client.streamUp && s.client.status !== null && !s.client._reading;
    }

    property Timer _clock: Timer {
        interval: 40
        repeat: true
        onTriggered: {
            for (const s of suite._scenarios) {
                const step = s.steps[0];
                if (!step)
                    continue;
                if (!s.started) {
                    s.started = true;
                    s.waitedUntil = Date.now() + step.timeoutMs;
                    try {
                        step.start?.();
                    } catch (error) {
                        suite.fail(s.name + ": threw starting \"" + step.description + "\": " + error);
                    }
                }
                let ready = false;
                try {
                    ready = step.condition();
                } catch (error) {}
                if (!ready && Date.now() < s.waitedUntil)
                    continue;
                s.steps.shift();
                s.started = false;
                if (!ready) {
                    suite.fail(s.name + ": timed out waiting: " + step.description);
                    s.steps = [];
                    continue;
                }
                try {
                    step.action();
                } catch (error) {
                    suite.fail(s.name + ": threw in \"" + step.description + "\": " + error);
                }
            }
            suite._scenarios = suite._scenarios.filter(s => s.steps.length > 0);
            if (suite._scenarios.length === 0) {
                stop();
                suite._finishAll();
            }
        }
    }

    function _finishAll() {
        for (const s of _all)
            s.client?.destroy();
        _shell.run(["rm", "-rf", "--", base], () => suite.finish());
    }

    function runAsync() {
        const operatorPrefs = "printf 'OperatorUser=%s\\n' \"$(id -un)\" > \"$1/state/prefs\"";
        const serveScenario = "printf 'serve\\n' > \"$1/state/scenario\"";
        const exitScenario = "printf 'exit-node\\n' > \"$1/state/scenario\"";
        const home = [{ id: "home-uuid", name: "Home", kind: "wifi", active: true }];

        // ---- Not the operator: share a port through pkexec, see it with its link; Funnel on; no
        // certificate ----
        const share = scenario("share", { setup: [serveScenario] });
        then(share, "status read", () => busReady(share) && share.client.serve.ready.canFunnel, () => {
            assertEqual(share.client.cert.problem, "Needs the operator", "certificate: not the operator");
            assert(!share.client.cert.get(), "… refused");
            assert(share.client.serve.read(), "the config is read");
        });
        then(share, "config read", () => share.client.serve.config !== null && !share.client.serve.reading, () => {
            assertEqual(share.client.serve.entries.length, 0, "nothing shared yet");
            assert(share.client.serve.add({ kind: "proxy", port: 443, localPort: "3000", path: "" }), "share port 3000");
        });
        then(share, "shared", () => !share.client.busy && share.client.serve.entries.length === 1 && !share.client.serve.reading, () => {
            const entry = share.client.serve.entries[0];
            same([entry.type, entry.port, entry.what, entry.funnel, entry.url], ["https", 443, "proxy", false, "https://self.example-tailnet.ts.net/"], "listed with its link");
            assert(share.client.serve.setFunnel(entry.key, true), "Funnel on");
        });
        // The stand-in is a long shell script; beside the other live suites a root run of it has
        // been seen to take ten seconds: this step gets more than the usual 12 s
        then(share, "public", () => !share.client.busy && share.client.serve.entries[0]?.funnel === true && !share.client.serve.reading, () => {
            assertEqual(share.client.serve.message, "", "no message");
        }, null, 18000);
        logs(share, "what ran", () => {
            assertEqual(count(share.pkexecLines, new RegExp("\\tserve\\t--bg\\t--yes\\t--https=443\\thttp://127\\.0\\.0\\.1:3000$")), 1, "root ran the module's own argv");
            assertEqual(count(share.pkexecLines, new RegExp("\\tfunnel\\t--bg\\t--yes\\t--https=443\\thttp://127\\.0\\.0\\.1:3000$")), 1, "Funnel on: the same handler with funnel");
            assert(count(share.logLines, /^serve status --json$/) >= 3, "the config read again under the lock before each change");
            assertEqual(count(share.logLines, /^cert /), 0, "no certificate for someone else");
            assertEqual(share.failures.length, 0, "no failure notified");
            same(share.module.privileged.calls.map(call => call.what), ["Share a port", "Turn on Funnel"], "each run as administrator said what for");
            same(share.module.privileged.calls.map(call => call.argv[0]), [standIns + "/tailscale", standIns + "/tailscale"], "… tailscale by its trusted path");
        });

        // One scenario after another (not side by side): the shell's other live suites run at the
        // same time, and three more clients at once made their timing flaky
        then(share, "next", () => true, () => operatorScenario());
        _clock.start();
    }

    function operatorScenario() {
        const operatorPrefs = "printf 'OperatorUser=%s\\n' \"$(id -un)\" > \"$1/state/prefs\"";
        const exitScenario = "printf 'exit-node\\n' > \"$1/state/scenario\"";
        const home = [{ id: "home-uuid", name: "Home", kind: "wifi", active: true }];
        // ---- The operator: a certificate into a private folder; the exit node set for a network ----
        const operator = scenario("operator", { env: { TS_FAKE_OPERATOR: "1" }, setup: [exitScenario, operatorPrefs,
            "printf 'self.example-tailnet.ts.net\\n' > \"$1/state/cert-domains\""] });
        then(operator, "status read", () => busReady(operator) && operator.client.canChange && operator.client.cert.problem === ""
             && (operator.client.prefs?.exitNodeId ?? "") !== "", () => {
            assertEqual(operator.client.cert.domain, "self.example-tailnet.ts.net", "its own name");
            assert(operator.client.cert.get(), "get a certificate");
        });
        then(operator, "got", () => !operator.client.busy && operator.client.cert.current !== null, () => {
            same([operator.client.cert.current.present, operator.client.cert.message], [true, ""], "written");
            assertEqual(operator.client.cert.current.expires, Date.UTC(2027, 1, 14, 12, 0, 0), "its end date");
            operator.client.networkExit.setChoice("home-uuid", "none", "", "Home");
            operator.client.networkExit.networks = home;
        });
        thenShell(operator, "modes", "stat -c '%a' \"$1/certs\" \"$1/certs/self.example-tailnet.ts.net.crt\" \"$1/certs/self.example-tailnet.ts.net.key\"", "_modes", lines => {
            same(lines, ["700", "644", "600"], "folder 700, certificate 644, key 600");
        });
        then(operator, "exit node cleared for the network", () => operator.client.networkExit.decision.kind === "applied" && !operator.client.busy, () => {
            assertEqual(operator.client.networkExit.runs, 1, "one change");
        });
        waitMs(operator, 600);
        logs(operator, "as the user", () => {
            assertEqual(count(operator.logLines, /^cert --cert-file=.*self\.example-tailnet\.ts\.net$/), 1, "`tailscale cert` with the module's files");
            assertEqual(count(operator.logLines, /^set --exit-node=$/), 1, "`set --exit-node=` once (not again after the read)");
            assertEqual(operator.pkexecLines.length, 0, "never through pkexec");
        });

        then(operator, "next", () => true, () => pathPortScenario());
    }

    function pathPortScenario() {
        const serveScenario = "printf 'serve\\n' > \"$1/state/scenario\"";
        const proxyOnly = "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"self.example-tailnet.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"}}}}}";
        const withPath = "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"self.example-tailnet.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"},\"/files\":{\"Path\":\"/srv/share\"}}}}}";
        // ---- Funnel is per port: `/` is ours, then a path handler appears on 443 behind the
        // module's back → "Funnel on" for `/` is refused by the planning on the fresh config,
        // before anything runs — never retried through pkexec (root would publish /files) ----
        const pathPort = scenario("path-port", { setup: [serveScenario, "printf '%s\\n' '" + proxyOnly + "' > \"$1/state/serve.json\""] });
        then(pathPort, "status read", () => busReady(pathPort) && pathPort.client.serve.ready.canFunnel, () => assert(pathPort.client.serve.read(), "the config is read"));
        then(pathPort, "config read", () => pathPort.client.serve.config !== null && !pathPort.client.serve.reading, () => {
            assertEqual(pathPort.client.serve.entries.length, 1, "only `/` shared");
        });
        thenShell(pathPort, "a path handler added on 443", "printf '%s\\n' '" + withPath + "' > \"$1/state/serve.json\" && echo done", "_seeded", () => {
            assert(pathPort.client.serve.setFunnel(pathPort.client.serve.entries[0].key, true), "Funnel on, planned on the config read before");
        });
        then(pathPort, "refused on the fresh config", () => !pathPort.client.busy && pathPort.client.serve.message !== "", () => {
            assertEqual(pathPort.client.serve.message, "Change this one in a terminal", "the fresh config holds a path on the port: refused");
            assertEqual(pathPort.client.serve.entries.length, 2, "… the path now listed");
            assert(!pathPort.client.serve.setFunnel(pathPort.client.serve.entries.find(entry => entry.mount === "/").key, true), "asked again: refused at once");
        });
        logs(pathPort, "nothing ran", () => {
            assertEqual(count(pathPort.logLines, /^funnel /), 0, "no `funnel` run");
            assertEqual(pathPort.pkexecLines.length, 0, "nothing through pkexec");
        });

        then(pathPort, "next", () => true, () => raceScenario());
    }

    function raceScenario() {
        const serveScenario = "printf 'serve\\n' > \"$1/state/scenario\"";
        const proxyOnly = "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"self.example-tailnet.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"}}}}}";
        const withPath = "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"self.example-tailnet.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"},\"/files\":{\"Path\":\"/srv/share\"}}}}}";
        // ---- Funnel on through pkexec, and a path handler lands on 443 while the password
        // dialog is open (the stand-in's serve-next.json: after the module's last read, before
        // the CLI's own) → read again after the change, Funnel turned off at once, the user told ----
        const race = scenario("race", { setup: [serveScenario, "printf '%s\\n' '" + proxyOnly + "' > \"$1/state/serve.json\"",
                                                "printf '%s\\n' '" + withPath + "' > \"$1/state/serve-next.json\""] });
        then(race, "status read", () => busReady(race) && race.client.serve.ready.canFunnel, () => assert(race.client.serve.read(), "the config is read"));
        then(race, "config read", () => race.client.serve.config !== null && !race.client.serve.reading, () => {
            assertEqual(race.client.serve.entries.length, 1, "only `/` shared");
            assert(race.client.serve.setFunnel(race.client.serve.entries[0].key, true), "Funnel on: allowed on what is read");
        });
        then(race, "Funnel went on", () => race.client.serve.checking || race.client.serve.message !== "", () => {});
        then(race, "checked and turned off", () => race.client.serve.message !== "" && !race.client.serve.checking && !race.client.busy && !race.client.serve.reading, () => {
            assertEqual(race.client.serve.message, "Funnel off. Something else is on port 443.", "the user told on the page");
            same(race.failures.map(failure => [failure.what, failure.reason]), [["Funnel", "Funnel off. Something else is on port 443."]], "… and by a notification");
            same(race.client.serve.entries.map(entry => [entry.mount, entry.what, entry.funnel]), [["/", "proxy", false], ["/files", "path", false]], "the port is private again");
            assert(!ServeRules.portPublic(race.client.serve.config, 443, race.client.status), "… Funnel off for 443");
        });
        logs(race, "what ran", () => {
            assertEqual(count(race.pkexecLines, /\tfunnel\t--bg\t--yes\t--https=443\thttp:\/\/127\.0\.0\.1:3000$/), 1, "Funnel on, as root");
            assertEqual(count(race.pkexecLines, /\tserve\t--bg\t--yes\t--https=443\thttp:\/\/127\.0\.0\.1:3000$/), 1, "then off again with serve");
            assertEqual(race.pkexecLines.length, 2, "nothing else as root");
            same(race.module.privileged.calls.map(call => call.what), ["Turn on Funnel", "Turn off Funnel"], "… said: Funnel on, then off");
        });

        then(race, "next", () => true, () => dismissedScenario());
    }

    function dismissedScenario() {
        const serveScenario = "printf 'serve\\n' > \"$1/state/scenario\"";
        const proxyOnly = "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"self.example-tailnet.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"}}}}}";
        const withPath = "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"self.example-tailnet.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"},\"/files\":{\"Path\":\"/srv/share\"}}}}}";
        // ---- The race again, and the password prompt for turning Funnel off right after the
        // click is dismissed → nothing told (a dismissed prompt is silent), "Turn off Funnel"
        // offered on the page ----
        const dismissed = scenario("dismissed", { setup: [serveScenario, "printf '%s\\n' '" + proxyOnly + "' > \"$1/state/serve.json\"",
                                                          "printf '%s\\n' '" + withPath + "' > \"$1/state/serve-next.json\""] });
        then(dismissed, "status read", () => busReady(dismissed) && dismissed.client.serve.ready.canFunnel, () => assert(dismissed.client.serve.read(), "the config is read"));
        then(dismissed, "config read", () => dismissed.client.serve.config !== null && !dismissed.client.serve.reading, () => {
            // Funnel on goes through; the prompt for turning it off again is dismissed
            dismissed.client.serve.checkingChanged.connect(() => {
                if (dismissed.client.serve.checking)
                    dismissed.client.environment = Object.assign({}, dismissed.env, { TS_FAKE_PKEXEC: "dismiss" });
            });
            assert(dismissed.client.serve.setFunnel(dismissed.client.serve.entries[0].key, true), "Funnel on");
        });
        then(dismissed, "checked, the prompt dismissed", () => dismissed.client.serve.funnelOffNeeded !== null && !dismissed.client.serve.checking && !dismissed.client.busy, () => {
            assertEqual(dismissed.client.serve.message, "", "dismissed: nothing on the page");
            same(dismissed.failures, [], "… no notification");
            same(dismissed.client.serve.funnelOffNeeded, { port: 443 }, "… \"Turn off Funnel\" offered");
        });
        logs(dismissed, "what ran", () => {
            const order = dismissed.pkexecLines.map(line => /\tfunnel\t/.test(line) ? "funnel" : /\tserve\t/.test(line) ? "serve" : line);
            same(order, ["funnel", "serve"], "Funnel on, then Funnel off asked right after the click (dismissed)");
        });

        then(dismissed, "next", () => true, () => lockScenario());
    }

    function lockScenario() {
        const serveScenario = "printf 'serve\\n' > \"$1/state/scenario\"";
        const proxyOnly = "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"self.example-tailnet.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"}}}}}";
        const withPath = "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"self.example-tailnet.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:3000\"},\"/files\":{\"Path\":\"/srv/share\"}}}}}";
        // ---- The same race, but the `funnel` run fails after its write reached the daemon (as
        // one ended by its time limit), and another change takes the lock the moment the check
        // starts → checked anyway, the revert waits for that change and then runs ----
        const lock = scenario("lock", { setup: [serveScenario, "printf '%s\\n' '" + proxyOnly + "' > \"$1/state/serve.json\"",
                                                "printf '%s\\n' '" + withPath + "' > \"$1/state/serve-next.json\"", ": > \"$1/state/serve-fail-after-write\""] });
        then(lock, "status read", () => busReady(lock) && lock.client.serve.ready.canFunnel, () => assert(lock.client.serve.read(), "the config is read"));
        then(lock, "config read", () => lock.client.serve.config !== null && !lock.client.serve.reading, () => {
            lock.grabbed = false;
            lock.client.serve.checkingChanged.connect(() => {
                if (lock.client.serve.checking && !lock.grabbed) {
                    lock.grabbed = true;
                    lock.busyAtCheck = lock.client.busy;
                    lock.grabbedOk = lock.client.setAllowLan(true);
                }
            });
            assert(lock.client.serve.setFunnel(lock.client.serve.entries[0].key, true), "Funnel on");
        });
        then(lock, "the check started, another change took the lock", () => lock.grabbed === true, () => {
            same([lock.busyAtCheck, lock.grabbedOk], [false, true], "the lock was free and the other change took it");
        });
        // The click is over once the check waited: it may not ask for a password any more, so
        // it tries without one (refused: not the operator) and says so, with a button
        then(lock, "checked, needs the user", () => lock.client.serve.message !== "" && !lock.client.serve.checking && !lock.client.busy && !lock.client.serve.reading, () => {
            assertEqual(lock.client.serve.message, "Port 443 is public with something else on it. Turn Funnel off on Tailscale's page.",
                        "the check after the other change: no password asked, the user told what to do");
            same(lock.client.serve.funnelOffNeeded, { port: 443 }, "… \"Turn off Funnel\" offered on the page");
            assert(ServeRules.portPublic(lock.client.serve.config, 443, lock.client.status), "… Funnel still on for 443");
            same(lock.failures.map(failure => failure.reason).filter(reason => /443/.test(reason)),
                 ["Port 443 is public with something else on it. Turn Funnel off on Tailscale's page."], "… and a notification says it");
        });
        logs(lock, "no prompt after the wait", () => {
            const order = lock.pkexecLines.map(line => /\tfunnel\t/.test(line) ? "funnel" : /\tset\t/.test(line) ? "set" : /\tserve\t/.test(line) ? "serve" : line);
            same(order, ["funnel", "set"], "Funnel on (failed after its write), the other change — and no password asked for Funnel off");
            assertEqual(count(lock.logLines, /^serve --bg --yes --https=443 http:\/\/127\.0\.0\.1:3000$/), 1, "… tried once without one");
            // A dismissed prompt at the user's click: silent, the button stays
            lock.client.environment = Object.assign({}, lock.env, { TS_FAKE_PKEXEC: "dismiss" });
            lock.failuresBefore = lock.failures.length;
            assert(lock.client.serve.turnFunnelOff(), "\"Turn off Funnel\" clicked");
            assertEqual(lock.client.serve.funnelOffNeeded, null, "… the offer taken");
        });
        then(lock, "the click's prompt dismissed", () => !lock.client.serve.checking && !lock.client.busy && lock.client.serve.funnelOffNeeded !== null, () => {
            assertEqual(lock.client.serve.message, "", "dismissed: nothing on the page");
            assertEqual(lock.failures.length, lock.failuresBefore, "… no notification");
            same(lock.client.serve.funnelOffNeeded, { port: 443 }, "… the button stays");
            lock.client.environment = lock.env;
            assert(lock.client.serve.turnFunnelOff(), "clicked again");
        });
        then(lock, "turned off at the click", () => lock.client.serve.message !== "" && !lock.client.serve.checking && !lock.client.busy && !lock.client.serve.reading, () => {
            assertEqual(lock.client.serve.message, "Funnel off. Something else is on port 443.", "the click's password: Funnel off");
            assertEqual(lock.client.serve.funnelOffNeeded, null, "… nothing offered any more");
            assert(!ServeRules.portPublic(lock.client.serve.config, 443, lock.client.status), "… Funnel off for 443");
        });
        logs(lock, "what ran", () => {
            const order = lock.pkexecLines.map(line => /\tfunnel\t/.test(line) ? "funnel" : /\tset\t/.test(line) ? "set" : /\tserve\t/.test(line) ? "serve" : line);
            same(order, ["funnel", "set", "serve", "serve"], "… then Funnel off at each click (the first dismissed)");
            same(lock.module.privileged.calls.map(call => call.what).slice(-2), ["Turn off Funnel", "Turn off Funnel"], "… each said what for");
        });

        then(lock, "next", () => true, () => plainScenario());
    }

    function plainScenario() {
        const exitScenario = "printf 'exit-node\\n' > \"$1/state/scenario\"";
        const home = [{ id: "home-uuid", name: "Home", kind: "wifi", active: true }];
        // ---- Not the operator, HTTPS off, locked out: nothing runs; attention ----
        const plain = scenario("plain", { setup: [exitScenario, "cp \"" + fixtures + "/lock-locked-out.json\" \"$1/state/lock.json\""] });
        then(plain, "status read", () => busReady(plain) && (plain.client.prefs?.exitNodeId ?? "") !== "", () => plain.client.serve.read());
        then(plain, "config read", () => plain.client.serve.config !== null, () => {
            assert(!plain.client.serve.add({ kind: "proxy", port: 443, localPort: 3000 }), "HTTPS off: refused");
            assertEqual(plain.client.serve.message, "HTTPS certificates are off for this tailnet", "… said plainly");
            assertEqual(plain.client.serve.ready.problems[0]?.url, ServeRules.adminDnsUrl, "… with the admin console");
            plain.client.networkExit.setChoice("home-uuid", "none", "", "Home");
            plain.client.networkExit.networks = home;
        });
        then(plain, "decided", () => plain.client.networkExit.decision.kind !== "", () => {
            assertEqual(plain.client.networkExit.decision.kind, "needs-operator", "exit node by network: needs the operator");
        });
        then(plain, "lock read", () => plain.client.tailnetLock.lock?.lockedOut === true, () => {
            assert(/Locked out by tailnet lock/.test(plain.client.entry.attention?.reason ?? ""), "locked out: the entry asks for the user");
            assertEqual(plain.client.entry.attention?.action, "Open admin console", "… its action");
            const before = plain.client.opened;
            plain.client.attend();
            assertEqual(plain.client.opened, before + 1, "… attend opens the admin console");
        });
        logs(plain, "nothing ran", () => {
            assertEqual(count(plain.logLines, /^serve --bg|^set /), 0, "no serve change, no set");
            assertEqual(plain.pkexecLines.length, 0, "no prompt");
        });
    }
}
