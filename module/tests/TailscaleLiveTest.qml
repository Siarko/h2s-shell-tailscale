import QtQuick
import Quickshell
import qs.api
import qs.tests
import ".."

// The live side (TailscaleClient) against the stand-ins (tools/stand-in), through its tools
// seam: every scenario the stand-in tailscale supports, each with a client, a state directory
// and logs of its own, side by side. Asserts on what the client shows AND on what was run
// (the stand-ins log argv): `up` never has a flag, every change is a `set`, nothing
// privileged and no browser on origin "network". Nothing here reaches a real tailscale: the
// client's toolsDir is the stand-ins' directory (and the shell's module test runner would
// give it those anyway).
TestCase {
    id: suite
    suiteName: "tailscale: the live side against the stand-ins"
    asynchronous: true

    function _path(url) {
        return String(url).replace(/^file:\/\//, "").replace(/\/+$/, "");
    }

    readonly property string standIns: _path(Qt.resolvedUrl("../../tools/stand-in"))
    readonly property string fixtures: _path(Qt.resolvedUrl("../../fixtures"))
    readonly property string base: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ts-live-" + Date.now()
    // "now" as the key-expiry fixtures have it
    readonly property real fixedNow: Date.UTC(2026, 10, 15, 12, 0, 0)

    property var _scenarios: []
    property var _all: []
    property Component _clientComponent: Component {
        TailscaleClient {}
    }
    property CommandAction _shell: CommandAction {}

    // ---- The scenario machinery ----

    // A scenario: its own directory, stand-in state and client. options: { state (the stand-in
    // scenario), daemonDown, env {}, toolsDir, fixedNow, loginTimeoutMs, emptyTools, without
    // (a copy of the stand-ins without this one), timeLimits, checkTrust }
    function scenario(name, options) {
        const dir = base + "/" + name;
        const s = { name: name, dir: dir, log: dir + "/log", pkexecLog: dir + "/pkexec.log", client: null, failures: [],
                    steps: [], waited: 0, started: false, logText: "", pkexecText: "", logsRead: false, options: options ?? {} };
        s.env = Object.assign({
            TS_FAKE_STATE_DIR: dir + "/state", TS_FAKE_LOG: s.log, TS_FAKE_PKEXEC_LOG: s.pkexecLog, TS_FAKE_LOGIN_DELAY: "1",
            TS_FAKE_USER: "tester", TS_FAKE_FIXTURES: fixtures, TS_FAKE_BUS_END: "hold", TS_FAKE_BUS_HOLD: "25",
            // A neutral message by default (one trigger); the fixture's whole bus where asked
            TS_FAKE_BUS_FILE: s.options.fixtureBus ? fixtures + "/bus-lines.jsonl" : dir + "/bus.jsonl"
        }, s.options.env ?? {});
        _scenarios.push(s);
        _all.push(s);
        // Set up, then the client
        then(s, "set up", () => true, () => {});
        s.steps[0].start = () => {
            const lines = ["mkdir -p \"$1/state\" \"$1/empty-tools\"", ": > \"$1/log\"", ": > \"$1/pkexec.log\""];
            if (s.options.state)
                lines.push("printf '%s\\n' \"$2\" > \"$1/state/scenario\"");
            if (s.options.daemonDown)
                lines.push(": > \"$1/state/daemon-down\"");
            lines.push("echo '{\"Health\":{\"Warnings\":{}}}' > \"$1/bus.jsonl\"");
            if (s.options.without)
                lines.push("mkdir -p \"$1/tools\" && cp \"$3\"/* \"$1/tools/\" && rm -f \"$1/tools/$4\"");
            if (s.options.busLines > 0)
                lines.push("i=0; while [ $i -lt " + s.options.busLines + " ]; do echo '{\"State\":6}'; i=$((i+1)); done > \"$1/bus.jsonl\"");
            _shell.run(["sh", "-c", lines.join(" && "), "sh", dir, s.options.state ?? "", standIns, s.options.without ?? ""], result => {
                if (!result.ok)
                    fail(name + ": set up failed: " + result.error);
                s.client = _clientComponent.createObject(suite, {
                    toolsDir: s.options.emptyTools ? dir + "/empty-tools" : (s.options.without ? dir + "/tools" : standIns),
                    environment: s.env, readDebounceMs: 100, streamBackoffMinMs: 200, streamBackoffMaxMs: 800, pollMs: 2000,
                    loginTimeoutMs: s.options.loginTimeoutMs ?? 60000, fixedNow: s.options.fixedNow ?? 0,
                    timeLimits: s.options.timeLimits ?? {}, readRetryMinMs: 300, readRetryMaxMs: 1200, checkTrust: s.options.checkTrust === true
                });
                s.client.failed.connect((what, reason) => s.failures.push({ what: what, reason: reason }));
                s.client.running = true;
                s.ready = true;
            });
        };
        s.steps[0].condition = () => s.ready === true;
        return s;
    }

    function then(s, description, condition, action, start) {
        s.steps.push({ description: description, condition: condition, action: action, start: start ?? null });
    }

    // A step that reads the scenario's logs first (s.logText, s.pkexecText, s.logLines)
    function thenLogs(s, description, action) {
        then(s, description + " (logs read)", () => s.logsRead, action, () => {
            s.logsRead = false;
            _shell.run(["sh", "-c", "cat \"$1\"; echo '----'; cat \"$2\"", "sh", s.log, s.pkexecLog], result => {
                const text = result.lines.join("\n");
                const cut = text.indexOf("----");
                s.logText = cut >= 0 ? text.slice(0, cut) : text;
                s.pkexecText = cut >= 0 ? text.slice(cut + 4) : "";
                s.logLines = s.logText.split("\n").map(line => line.trim()).filter(line => line !== "");
                s.pkexecLines = s.pkexecText.split("\n").map(line => line.trim()).filter(line => line !== "");
                s.logsRead = true;
            });
        });
    }

    function waitMs(s, ms) {
        let until = 0;
        then(s, "wait " + ms + " ms", () => Date.now() >= until, () => {}, () => until = Date.now() + ms);
    }

    // Lines of the stand-in tailscale's log that are not reads
    function changesIn(s) {
        const reads = [/^status --json$/, /^debug prefs$/, /^exit-node suggest$/, /^version( --json)?$/, /^netcheck --format=json$/, /^dns status --json$/,
            /^debug derp-map$/, /^ping --c=1 --timeout=3s \S+$/, /^switch --list --json$/];
        return (s.logLines ?? []).filter(line => !line.startsWith("curl ") && !line.startsWith("xdg-open ") && !line.startsWith("systemctl ")
            && !reads.some(pattern => pattern.test(line)));
    }

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    function count(lines, pattern) {
        return (lines ?? []).filter(line => pattern.test(line)).length;
    }

    // A pkexec log line's pattern: pkexec, the stand-in timeout with its limit, the stand-in
    // tailscale, then `rest` (tab-separated)
    function elevatedLine(seconds, rest) {
        const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        return new RegExp("^pkexec\\t" + escape(standIns) + "/timeout\\t-k\\t5\\t" + seconds + "\\t" + escape(standIns) + "/tailscale\\t" + rest + "$");
    }

    // A step that runs `script` (sh -c, $1 = the scenario's directory) and stores its output's
    // first line in s[key]
    function thenShell(s, description, script, key, action) {
        then(s, description, () => s[key] !== undefined, () => action(s[key]), () => {
            s[key] = undefined;
            _shell.run(["sh", "-c", script, "sh", s.dir], result => s[key] = (result.lines[0] ?? "").trim());
        });
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
                    s.waited = 0;
                    try {
                        step.start?.();
                    } catch (error) {
                        suite.fail(s.name + ": threw starting \"" + step.description + "\": " + error);
                    }
                }
                s.waited += interval;
                let ready = false;
                try {
                    ready = step.condition();
                } catch (error) {}
                if (!ready && s.waited < 9000)
                    continue;
                s.steps.shift();
                s.started = false;
                if (!ready)
                    suite.fail(s.name + ": timed out waiting: " + step.description);
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
        // What was run, over every scenario: `up` bare, changes are `set`s
        for (const s of _all) {
            const changes = changesIn(s);
            assertEqual(changes.filter(line => /^up\b/.test(line) && line !== "up").length, 0, s.name + ": `up` never with a flag");
            const others = changes.filter(line => !/^(set |up$|down$|login$|logout$|switch [A-Za-z0-9]|switch remove [A-Za-z0-9])/.test(line));
            assertEqual(others.join(" | "), "", s.name + ": every change is a `set` (or bare up/down/login/logout, switch <id>, switch remove <id>)");
            s.client?.destroy();
        }
        _shell.run(["rm", "-rf", "--", base], () => suite.finish());
    }

    function _entry(s) {
        return s.client?.entry ?? {};
    }

    function runAsync() {
        // ---- running ----
        const running = scenario("running", { state: "running", fixtureBus: true });
        then(running, "read: running, the whole fixture bus digested", () => running.client.events >= 15 && !running.client._reading && !running.client._readTimer.running, () => {
            assert(running.client.warnings.some(warning => warning.kind === "error"), "the bus's ErrMessage shown as a warning");
            assertEqual(running.client.busAuthUrl, "", "a BrowseToURL while not logging in: shown until the bus's LoginFinished, never opened");
            assertEqual(running.client.opened, 0, "… nothing opened");
            assertEqual(running.client.suggestedId, "nMULL21CNTRL", "the bus's SuggestedExitNode taken");
            assertEqual(_entry(running).state, "activated", "running: the entry is activated");
            assertEqual(_entry(running).status, "Tailnet only", "running: \"Tailnet only\"");
            assertEqual(_entry(running).name, "Tailscale", "running: a personal tailnet (an e-mail address): the entry is just \"Tailscale\"");
            assert(running.client.ready && running.client.cli === "present" && running.client.daemon === "running", "running: ready, CLI present, daemon running");
            assert(running.client.devices.length > 0, "running: devices listed (" + running.client.devices.length + ")");
            assert(running.client.exitNodes.count >= 2, "running: exit nodes listed");
            assert(running.client.events > 0, "running: bus messages read from the stream");
            assertEqual(running.client.toolsMode, "owner", "running: the tools seam given by the owner");
            assert(running.client.tailscalePath === standIns + "/tailscale", "running: tailscale by the seam's absolute path");
            running.client.suggest(() => running.suggested = true);
        });
        then(running, "exit-node suggest answered", () => running.suggested === true, () => {
            assert(running.client.exitNodes.suggested !== null || running.client.suggestedName !== "", "suggest: the suggestion is known");
            running.readsBefore = running.client.reads;
        });
        waitMs(running, 2600);
        then(running, "the slow poll", () => true, () => {
            assert(running.client.streamUp, "the stream still up");
            assert(running.client.reads > running.readsBefore, "the slow poll re-reads while the stream is up too (peers' online state)");
        });
        thenLogs(running, "reads only", () => {
            assertEqual(changesIn(running).length, 0, "running: nothing changed by just watching");
            assert(count(running.logLines, /^curl -sN --unix-socket \/var\/run\/tailscale\/tailscaled.sock http:\/\/local-tailscaled.sock\/localapi\/v0\/watch-ipn-bus\?mask=\d+$/) >= 1,
                   "running: ONE stream through curl on the LocalAPI socket, with the rules' mask");
        });

        // ---- stopped → connect, not operator: denied → pkexec ----
        const stopped = scenario("stopped", { state: "stopped" });
        then(stopped, "read: stopped", () => stopped.client.status !== null, () => {
            assertEqual(_entry(stopped).state + "|" + _entry(stopped).status, "|Off", "stopped: off");
            assert(!stopped.client.canChange, "stopped: not the operator — changes are privileged");
            assert(stopped.client.connect("user"), "connect (user) starts");
            assertEqual(_entry(stopped).state, "activating", "… activating at once");
            assert(_entry(stopped).busy, "… busy");
        });
        then(stopped, "connected", () => _entry(stopped).state === "activated" && !stopped.client.busy, () => {});
        thenLogs(stopped, "after connect", () => {
            assertEqual(count(stopped.logLines, /^up$/), 2, "connect: bare `up` plainly, denied, then as root");
            assertEqual(count(stopped.pkexecLines, elevatedLine(60, "up")), 1, "… through pkexec: timeout 60 s around tailscale up, both by absolute path");
            assertEqual(stopped.pkexecLines.length, 1, "… and nothing else as root");
            assertEqual(stopped.failures.length, 0, "… no failure");
        });

        // ---- starting ----
        const starting = scenario("starting", { state: "starting" });
        then(starting, "read: starting", () => starting.client.status !== null, () => {
            assertEqual(_entry(starting).state + "|" + starting.client.view.phase, "activating|starting", "starting: activating, phase starting");
            assertEqual(_entry(starting).attention, null, "starting: no attention (transient)");
        });

        // ---- needs-login: network never logs in, the user does ----
        const login = scenario("needs-login", { state: "needs-login" });
        then(login, "read: needs-login", () => login.client.status !== null, () => {
            assertEqual(_entry(login).attention?.action, "Log in", "needs-login: attention, \"Log in\"");
            assert(!login.client.connect("network"), "connect (network): nothing started");
            assertEqual(_entry(login).attention?.action, "Log in", "… attention kept");
        });
        waitMs(login, 300);
        thenLogs(login, "network did nothing", () => {
            assertEqual(changesIn(login).length, 0, "origin network: nothing run");
            assertEqual(count(login.logLines, /^xdg-open /), 0, "origin network: no browser");
            assertEqual(login.pkexecLines.length, 0, "origin network: no pkexec");
            assert(login.client.connect("user"), "connect (user): the login starts");
        });
        then(login, "the login URL surfaced", () => login.client.authUrl !== "", () => {
            assertEqual(login.client.authUrl, "https://login.tailscale.com/a/REDACTED", "the URL from the login's output");
            assertEqual(_entry(login).state, "activating", "… the entry activating meanwhile");
            assertEqual(_entry(login).attention, null, "… no attention while logging in");
        });
        then(login, "logged in", () => _entry(login).state === "activated" && !login.client.busy, () => {
            assertEqual(login.client.authUrl, "", "the URL cleared");
        });
        thenLogs(login, "after the login", () => {
            assertEqual(count(login.logLines, /^login$/), 2, "bare `login`, denied, then as root");
            assertEqual(count(login.pkexecLines, elevatedLine(60, "login")), 1, "… through pkexec, under timeout (the login's limit: it ends by itself)");
            assertEqual(count(login.logLines, /^xdg-open https:\/\/login\.tailscale\.com\/a\/REDACTED$/), 1, "the browser opened ONCE, through the seam's xdg-open");
            assertEqual(login.client.opened, 1, "… counted once");
        });

        // ---- a login that is never finished: the module ends it ----
        const slowLogin = scenario("login-timeout", { state: "needs-login", loginTimeoutMs: 700, env: { TS_FAKE_LOGIN_DELAY: "6", TS_FAKE_OPERATOR: "1" } });
        then(slowLogin, "read", () => slowLogin.client.status !== null, () => slowLogin.client.attend());
        then(slowLogin, "the login ended by the module", () => slowLogin.failures.length > 0 && !slowLogin.client.busy, () => {
            assert(/not finished within/.test(slowLogin.failures[0].reason), "timeout: failed, saying so: " + slowLogin.failures[0].reason);
            assertEqual(slowLogin.client.authUrl, "", "… the URL cleared");
            assertEqual(slowLogin.client.loggingIn, false, "… the process ended");
        });

        // ---- needs approval ----
        const approval = scenario("needs-approval", { state: "needs-machine-auth" });
        then(approval, "read", () => approval.client.status !== null, () => {
            assertEqual(_entry(approval).attention?.action, "Approve…", "needs-approval: attention");
            assert(approval.client.attend(), "attend: opens the admin page");
        });
        thenLogs(approval, "the admin page", () => {
            assertEqual(count(approval.logLines, /^xdg-open https:\/\/login\.tailscale\.com\/admin\/machines$/), 1, "attend: the admin console opened");
        });

        // ---- operator: log out with no pkexec at all ----
        const operator = scenario("operator-logout", { state: "running", env: { TS_FAKE_OPERATOR: "1" } });
        then(operator, "read", () => operator.client.status !== null, () => operator.client.logout());
        then(operator, "logged out", () => operator.client.view.phase === "logged-out" && !operator.client.busy, () => {
            assertEqual(_entry(operator).attention?.action, "Log in", "logged out: attention \"Log in\"");
            assertEqual(_entry(operator).state, "", "… off");
            assertEqual(_entry(operator).name, "Tailscale", "… still \"Tailscale\" (no e-mail address remembered)");
            assertEqual(operator.client.lastTailnet, "", "… nothing e-mail-like kept as the last tailnet");
        });
        thenLogs(operator, "after logout", () => {
            assertEqual(count(operator.logLines, /^logout$/), 1, "logout: run once, plainly");
            assertEqual(operator.pkexecLines.length, 0, "operator: no pkexec at all");
        });

        // ---- key about to expire: a warning and the status line, no attention, nothing run ----
        const expiring = scenario("key-expiring", { state: "key-expiring", fixedNow: fixedNow });
        then(expiring, "read", () => expiring.client.status !== null, () => {
            assertEqual(_entry(expiring).attention, null, "key expiring in 3 days: no attention (nothing renews it without harm)");
            assertEqual(_entry(expiring).status, "Tailnet only · key expires in 3 days", "… the status line says it");
            assert(expiring.client.warnings.some(warning => warning.kind === "key-expiring"), "… a warning");
            assertEqual(expiring.client.keyState.state, "soon", "… the key's state: soon");
            assert(!expiring.client.attend(), "attend: nothing to do");
        });
        thenLogs(expiring, "nothing run", () => assertEqual(changesIn(expiring).length, 0, "no login, no change"));
        const expired = scenario("key-expired", { state: "key-expired", fixedNow: fixedNow });
        then(expired, "read", () => expired.client.status !== null, () => {
            assertEqual(expired.client.view.attention?.kind, "key-expired", "key expired: attention");
            assertEqual(_entry(expired).attention?.action, "Log in", "… \"Log in\"");
        });

        // ---- exit node set and cleared (operator) ----
        const exitNode = scenario("exit-node", { state: "running", env: { TS_FAKE_OPERATOR: "1" } });
        then(exitNode, "read", () => exitNode.client.status !== null, () => {
            const peer4 = exitNode.client.exitNodes.own.find(option => option.name === "peer4");
            assert(peer4 !== undefined, "exit nodes: peer4 offered");
            exitNode.client.setExitNode(peer4);
        });
        then(exitNode, "via peer4", () => /^Via /.test(_entry(exitNode).status) && !exitNode.client.busy, () => {
            assertEqual(_entry(exitNode).status, "Via peer4", "exit node set: \"Via peer4\"");
            assert(exitNode.client.exitNodes.current?.name === "peer4", "… current in the chooser");
            exitNode.client.setExitNode(null);
        });
        then(exitNode, "none", () => _entry(exitNode).status === "Tailnet only" && !exitNode.client.busy, () => {});
        thenLogs(exitNode, "after the exit nodes", () => {
            assertEqual(count(exitNode.logLines, /^set --exit-node=100\.64\.0\.4$/), 1, "set --exit-node=<its IPv4>");
            assertEqual(count(exitNode.logLines, /^set --exit-node=$/), 1, "set --exit-node= (none)");
        });

        // ---- exit node offline: a grace, then attention ----
        const offline = scenario("exit-node-offline", { state: "exit-node-offline", fixedNow: fixedNow });
        then(offline, "read", () => offline.client.status !== null, () => {
            assert(offline.client.warnings.some(warning => warning.kind === "exit-node-offline"), "offline exit node: a warning first");
            assertEqual(_entry(offline).attention, null, "… no attention within the grace");
            offline.client.fixedNow = fixedNow + 61000;
        });
        then(offline, "after the grace", () => offline.client.view.attention !== null, () => {
            assertEqual(offline.client.view.attention.kind, "exit-node-offline", "after a minute: attention");
            assertEqual(_entry(offline).attention?.action, "Use none", "… \"Use none\"");
        });

        // ---- daemon down → Start → up ----
        const daemon = scenario("daemon-down", { state: "running", daemonDown: true });
        then(daemon, "read", () => daemon.client.daemon === "not-running", () => {
            assertEqual(_entry(daemon).attention?.action, "Start", "daemon down: attention \"Start\"");
            assert(_entry(daemon).name.startsWith("Tailscale"), "… the entry still there");
            assert(!daemon.client.streamUp, "… no stream");
            assert(daemon.client.attend(), "attend: starts the service");
        });
        then(daemon, "up again", () => daemon.client.daemon === "running" && _entry(daemon).state === "activated", () => {});
        then(daemon, "the stream back", () => daemon.client.streamUp, () => {});
        thenLogs(daemon, "after start", () => {
            assertEqual(count(daemon.logLines, /^systemctl start tailscaled\.service$/), 1, "systemctl start tailscaled.service, once");
            assertEqual(daemon.pkexecLines.length, 0, "… not through pkexec (systemd asks polkit itself)");
        });

        // ---- CLI missing ----
        const missing = scenario("cli-missing", { emptyTools: true });
        then(missing, "resolved", () => missing.client.cli === "missing", () => {
            assertEqual(_entry(missing).attention?.reason, "Tailscale is not installed on this computer", "CLI missing: the entry says \"not installed\"");
            assertEqual(_entry(missing).status, "Not installed", "… its status");
            assert(missing.client.ready, "… ready (there is nothing to read)");
            assert(!missing.client.connect("user"), "… connect does nothing");
        });
        thenLogs(missing, "nothing ran", () => assertEqual(missing.logLines.length, 0, "CLI missing: nothing run"));

        // ---- not operator: dismissed / no agent / ok ----
        const dismissed = scenario("pkexec-dismissed", { state: "running", env: { TS_FAKE_PKEXEC: "dismiss" } });
        then(dismissed, "read", () => dismissed.client.prefs !== null, () => {
            dismissed.shieldsBefore = dismissed.client.prefs.shieldsUp;
            dismissed.client.setShieldsUp(true);
        });
        then(dismissed, "answered", () => !dismissed.client.busy, () => {});
        waitMs(dismissed, 300);
        thenLogs(dismissed, "dismissed", () => {
            assertEqual(dismissed.failures.length, 0, "dismissed: nothing shown");
            assertEqual(dismissed.client.prefs.shieldsUp, dismissed.shieldsBefore, "… nothing changed");
            assertEqual(_entry(dismissed).state, "activated", "… the state as it was");
            assertEqual(count(dismissed.pkexecLines, /\tset\t--shields-up=true$/), 1, "… pkexec was asked (by absolute path)");
        });
        const noAgent = scenario("pkexec-no-agent", { state: "stopped", env: { TS_FAKE_PKEXEC: "no-agent" } });
        then(noAgent, "read", () => noAgent.client.status !== null, () => noAgent.client.connect("user"));
        then(noAgent, "failed", () => noAgent.failures.length > 0 && !noAgent.client.busy, () => {
            assertEqual(noAgent.failures[0].reason, "No authentication agent answered.", "no agent: failed with the contract's sentence");
            assertEqual(noAgent.failures[0].what, "Connecting Tailscale", "… what: the command table's description");
            assertEqual(_entry(noAgent).state, "", "… the state back to off");
        });
        const elevated = scenario("pkexec-ok", { state: "running" });
        then(elevated, "read", () => elevated.client.prefs !== null, () => {
            assert(elevated.client.prefs.acceptRoutes, "routes accepted before");
            elevated.client.setAcceptRoutes(false);
        });
        then(elevated, "changed", () => elevated.client.prefs?.acceptRoutes === false && !elevated.client.busy, () => {});
        thenLogs(elevated, "pkexec ok", () => {
            assertEqual(count(elevated.pkexecLines, /\tset\t--accept-routes=false$/), 1, "a denied change by the user: through pkexec");
            assertEqual(elevated.failures.length, 0, "… no failure");
        });

        // ---- not operator, origin network: no prompt — attention ----
        const unattended = scenario("network-not-operator", { state: "stopped" });
        then(unattended, "read", () => unattended.client.status !== null, () => {
            assert(!unattended.client.connect("network"), "connect (network) as not the operator: nothing started");
            assertEqual(unattended.client.pendingAttention?.kind, "needs-privilege", "… attention instead");
            assertEqual(_entry(unattended).attention?.action, "Connect", "… on the entry, with the action");
            assertEqual(_entry(unattended).state, "", "… off");
            unattended.client.disconnect("unknown-origin");
        });
        waitMs(unattended, 300);
        thenLogs(unattended, "network did nothing", () => {
            assertEqual(changesIn(unattended).length, 0, "origin network: nothing run");
            assertEqual(unattended.pkexecLines.length, 0, "origin network: nothing privileged");
        });

        // ---- becoming the operator, then no pkexec ----
        const become = scenario("become-operator", { state: "running" });
        then(become, "read, identity known", () => become.client.prefs !== null && become.client.userName !== "", () => {
            become.client.environment = Object.assign({}, become.env, { TS_FAKE_USER: become.client.userName });
            become.client.becomeOperator();
        });
        then(become, "operator", () => become.client.canChange && !become.client.busy, () => become.client.setShieldsUp(true));
        then(become, "shields up", () => become.client.prefs?.shieldsUp === true && !become.client.busy, () => {});
        thenLogs(become, "after becoming the operator", () => {
            assertEqual(count(become.pkexecLines, new RegExp("\\tset\\t--operator=" + become.client.userName + "$")), 1, "become operator: pkexec set --operator=<this user>");
            assertEqual(become.pkexecLines.length, 1, "… and then no pkexec for a change");
        });

        // ---- the stream dying and coming back ----
        const dying = scenario("stream-dies", { state: "running", env: { TS_FAKE_BUS_END: "die" } });
        then(dying, "restarted (and read: under the load of the other scenarios a read may come after the third start)", () => dying.client.streamStarts >= 3 && dying.client.status !== null && !dying.client._reading, () => {
            assert(dying.client.status !== null && _entry(dying).state === "activated", "a dying stream: the state still read");
        });

        // ---- a burst of 50 bus messages: a couple of reads ----
        const burst = scenario("burst", { state: "running", busLines: 50, env: { TS_FAKE_BUS_FILE: base + "/burst/bus.jsonl" } });
        then(burst, "50 messages read", () => burst.client.events >= 50 && !burst.client._reading && !burst.client._readTimer.running, () => {
            assert(burst.client.reads <= 3, "50 bus messages: at most 3 reads (" + burst.client.reads + ")");
        });

        // ---- A1: cancelling a login run through pkexec (a root process: it cannot be signalled) ----
        const cancel = scenario("login-cancel-unkillable", { state: "needs-login",
            env: { TS_FAKE_PKEXEC: "unkillable", TS_FAKE_UNKILLABLE_SECONDS: "4", TS_FAKE_LOGIN_DELAY: "1", TS_FAKE_LOGIN_RESULT: "fail" } });
        then(cancel, "read", () => cancel.client.status !== null, () => assert(cancel.client.attend(), "attend: the login starts"));
        then(cancel, "the elevated login waits for the browser", () => cancel.client.authUrl !== "" && cancel.client._loginElevated, () => {
            cancel.cancelledAt = Date.now();
            cancel.client.cancelLogin();
        });
        then(cancel, "not busy", () => !cancel.client.busy, () => {
            assert(Date.now() - cancel.cancelledAt < 1000, "cancel: not busy within a second (" + (Date.now() - cancel.cancelledAt) + " ms) though the root login still runs");
            assertEqual(cancel.client.operation + "|" + cancel.client.authUrl, "|", "… operation and the login URL cleared");
            assert(cancel.client.connect("user"), "… connect works again (a new login starts)");
            assertEqual(cancel.client.operation, "login", "… busy with the new one");
            cancel.client.cancelLogin();
            assert(!cancel.client.busy, "… cancelled at once too (a plain login: ended)");
        });
        waitMs(cancel, 4500);
        thenLogs(cancel, "the old root login ended by itself", () => {
            assertEqual(cancel.failures.length, 0, "the late exit (a failed login) changes nothing: no failure shown");
            assertEqual(cancel.client.operation + "|" + cancel.client.authUrl, "|", "… not busy, no URL");
            assertEqual(count(cancel.pkexecLines, elevatedLine(60, "login")), 1, "… pkexec ran once: timeout around the login, so it ends by itself");
        });

        // ---- A2: a bare `up` that waits (offline, captive portal): its URL, Disconnect ends it ----
        const slowUp = scenario("slow-up-disconnect", { state: "stopped", env: { TS_FAKE_OPERATOR: "1", TS_FAKE_UP_DELAY: "30", TS_FAKE_UP_URL: "1" } });
        then(slowUp, "read", () => slowUp.client.status !== null, () => assert(slowUp.client.connect("user"), "connect starts"));
        then(slowUp, "the login URL while `up` still waits", () => slowUp.client.authUrl !== "", () => {
            assertEqual(slowUp.client.operation, "connect", "… the connect still pending");
            assertEqual(_entry(slowUp).state, "activating", "… the entry activating");
            assert(slowUp.client.disconnect("user"), "Disconnect is accepted while the connect is pending");
        });
        then(slowUp, "disconnected", () => !slowUp.client.busy && slowUp.client.view.phase === "stopped", () => {
            assertEqual(_entry(slowUp).state, "", "… off");
            assertEqual(slowUp.failures.length, 0, "… no failure");
        });
        waitMs(slowUp, 500);
        thenLogs(slowUp, "after the pending connect", () => {
            assertEqual(count(slowUp.logLines, /^up$/), 1, "bare `up` once");
            assertEqual(count(slowUp.logLines, /^down$/), 1, "… then `down` (the daemon would keep trying)");
            assertEqual(count(slowUp.logLines, /^xdg-open https:\/\/login\.tailscale\.com\/a\/REDACTED$/), 1, "… the URL opened once (the user's connect)");
        });
        thenShell(slowUp, "the pending `up` ended",
            "for p in /proc/[0-9]*; do grep -qzx \"TS_FAKE_STATE_DIR=$1/state\" \"$p/environ\" 2> /dev/null && tr '\\0' ' ' < \"$p/cmdline\" 2> /dev/null | grep -qE 'tailscale up|sleep 30' && echo \"$p\"; done | wc -l",
            "upLeft", left => assertEqual(left, "0", "the plain `up` process (and its wait) ended, not left behind"));

        // ---- A2: `up` past its time limit; a URL from the bus while it waits ----
        const upTimeout = scenario("up-timeout", { state: "stopped", timeLimits: { up: 2 }, env: { TS_FAKE_OPERATOR: "1", TS_FAKE_UP_DELAY: "30" } });
        then(upTimeout, "read", () => upTimeout.client.status !== null, () => {
            upTimeout.client.environment = Object.assign({}, upTimeout.env);
            assert(upTimeout.client.connect("user"), "connect starts");
            upTimeout.client._onBusMessage({ BrowseToURL: "https://login.tailscale.com/a/REDACTED" });
            assertEqual(upTimeout.client.authUrl, "https://login.tailscale.com/a/REDACTED", "a BrowseToURL from the bus shows while `up` waits");
            assertEqual(_entry(upTimeout).status, "Connecting…", "… \"Connecting…\"");
        });
        then(upTimeout, "the connect given up", () => upTimeout.failures.length > 0 && !upTimeout.client.busy, () => {
            assert(/did not connect within 2 s\. It keeps trying by itself; Disconnect stops it\./.test(upTimeout.failures[0].reason),
                   "after its time limit: failed, saying the daemon keeps trying: " + upTimeout.failures[0].reason);
            assertEqual(upTimeout.client.authUrl, "", "… the URL cleared");
        });

        // ---- A2: a `status --json` that hangs: stale, retried, back ----
        const hung = scenario("status-hung", { state: "running", timeLimits: { read: 1 } });
        then(hung, "read", () => _entry(hung).state === "activated" && !hung.client._reading, () => {}, null);
        thenShell(hung, "the daemon stops answering", "echo 30 > \"$1/state/status-hang\"; echo ok", "hangSet", () => hung.client.refresh());
        then(hung, "the read timed out", () => hung.client.stale, () => {
            assertEqual(_entry(hung).state, "", "stale: the entry no longer says connected");
            assertEqual(_entry(hung).status, "Not answering — state unknown", "… it says the state is unknown");
            assertEqual(_entry(hung).name, "Tailscale", "… still listed");
            assert(!hung.client._reading, "… the read no longer blocks the next ones");
            assert(!hung.client.connect("user"), "… connect does nothing blind (the state is re-read first)");
        });
        thenLogs(hung, "nothing run blind", () => assertEqual(changesIn(hung).length, 0, "no `up` while the state is unknown"));
        thenShell(hung, "the daemon answers again", "rm -f \"$1/state/status-hang\"; echo ok", "hangCleared", () => {});
        then(hung, "back", () => !hung.client.stale && _entry(hung).state === "activated", () => {
            assert(hung.client.readTimeouts >= 1, "retried with a backoff after " + hung.client.readTimeouts + " timeout(s)");
        });

        // ---- curl missing: said once, the slow poll instead of restarting it ----
        const noCurl = scenario("curl-missing", { state: "running", without: "curl" });
        then(noCurl, "read", () => noCurl.client.status !== null, () => {
            assertEqual(_entry(noCurl).status, "Tailnet only · live updates need curl", "the entry says live updates need curl");
            assert(noCurl.client.warnings.some(warning => warning.kind === "curl-missing"), "… and the card");
            noCurl.readsBefore = noCurl.client.reads;
        });
        waitMs(noCurl, 2600);
        then(noCurl, "polled", () => true, () => {
            assertEqual(noCurl.client.streamStarts, 0, "no stream started (nothing that cannot start, restarted)");
            assert(noCurl.client.reads > noCurl.readsBefore, "… the slow poll reads instead");
        });

        // ---- programs this user could replace: not trusted, nothing runs ----
        const untrusted = scenario("untrusted", { state: "running", checkTrust: true });
        then(untrusted, "judged", () => untrusted.client.cli !== "unknown", () => {
            assertEqual(untrusted.client.cli, "untrusted", "the stand-ins (owned by this user, not in the Nix store) are not trusted");
            assertEqual(_entry(untrusted).status, "Not trusted", "the entry: \"Not trusted\"");
            assert(/not trusted/.test(_entry(untrusted).attention?.reason ?? ""), "… with the reason: " + _entry(untrusted).attention?.reason);
            assert(!untrusted.client.connect("user"), "… connect does nothing");
            assert(untrusted.client.ready, "… ready (nothing to read)");
        });
        waitMs(untrusted, 300);
        thenLogs(untrusted, "nothing ran", () => {
            assertEqual(untrusted.logLines.length, 0, "not trusted: nothing run at all");
            assertEqual(untrusted.pkexecLines.length, 0, "… nothing through pkexec");
        });

        // ---- switched off: the stream process gone, nothing acts ----
        const off = scenario("off", { state: "running" });
        then(off, "streaming", () => off.client.streamUp && !off.client._reading, () => {
            off.client.running = false;
            off.readsAtOff = off.client.reads;
            off.startsAtOff = off.client.streamStarts;
        });
        waitMs(off, 1500);
        then(off, "processes listed", () => off.listed === true, () => {
            assertEqual(off.processes, 0, "off: no process of its own left (the stream ended)");
            assertEqual(off.client.reads, off.readsAtOff, "off: no read since");
            assertEqual(off.client.streamStarts, off.startsAtOff, "off: no stream started since");
            assert(!off.client.connect("user") && off.client.operation === "", "off: an action does nothing");
        }, () => {
            _shell.run(["sh", "-c", "grep -lzx \"TS_FAKE_STATE_DIR=$1\" /proc/[0-9]*/environ 2> /dev/null | grep -vx \"/proc/$$/environ\" | wc -l", "sh", off.dir + "/state"], result => {
                off.processes = Number(result.lines[0] ?? -1);
                off.listed = true;
            });
        });

        // ---- accounts: read (denied → pkexec), switch, add, remove; the page follows ----
        const accounts = scenario("accounts", { state: "running" });
        then(accounts, "read", () => accounts.client.status !== null, () => {
            assertEqual(accounts.client.accounts, null, "accounts: not read by themselves (the list needs a password)");
            assertEqual(accounts.client.currentAccount.loginName, "user1@example.com", "… the account in use known anyway (prefs)");
            assertEqual(accounts.client.currentAccount.tailnet, "example-tailnet.ts.net", "… its tailnet by the MagicDNS suffix");
            assert(accounts.client.readAccounts(), "Show accounts: starts");
        });
        then(accounts, "listed", () => accounts.client.accounts !== null && !accounts.client.busy, () => {
            assertEqual(accounts.client.accounts.map(account => account.id + (account.selected ? "*" : "")).join(" "), "a1b2* c3d4", "the two accounts, the one in use marked");
            assert(!accounts.client.accountsOutdated, "… matching the account in use");
            assert(accounts.client.switchAccount("c3d4"), "switch to c3d4: starts");
        });
        then(accounts, "switched, the state follows", () => !accounts.client.busy && accounts.client.currentAccount.loginName === "user1@example.org"
                && accounts.client.currentAccount.tailnet === "example.org", () => {
            assertEqual(accounts.client.accounts.find(account => account.selected)?.id, "c3d4", "the list updated in place (no second prompt)");
            assertEqual(_entry(accounts).name, "Tailscale · example.org", "the entry names the organisation's tailnet");
            assertEqual(accounts.client.currentAccount.tailnet, "example.org", "… and the page's account line");
            assert(!accounts.client.accountsOutdated, "… the list still matches");
            assert(!accounts.client.removeAccount("c3d4"), "the account in use cannot be removed");
            assert(accounts.failures.some(failure => /cannot be removed/.test(failure.reason)), "… said so");
            accounts.failures = [];
            assert(accounts.client.removeAccount("a1b2"), "remove a1b2: starts");
        });
        then(accounts, "removed", () => !accounts.client.busy && accounts.client.accounts.length === 1, () => {
            assertEqual(accounts.client.accounts[0].id, "c3d4", "the list without it");
            assert(accounts.client.addAccount(), "add account: starts a login");
        });
        then(accounts, "the new account's login URL", () => accounts.client.authUrl !== "", () => {
            assertEqual(accounts.client.operation, "login", "adding: a login");
        });
        then(accounts, "added", () => !accounts.client.busy && accounts.client.currentAccount.loginName === "user2@example.net", () => {
            assert(accounts.client.accountsOutdated, "after adding: the list is out of date (a new account in use)");
            assertEqual(accounts.failures.length, 0, "no failure");
        });
        thenLogs(accounts, "after the accounts", () => {
            assertEqual(count(accounts.pkexecLines, elevatedLine(15, "switch\\t--list\\t--json")), 1, "the list through pkexec, ONCE, under the read limit");
            assertEqual(count(accounts.pkexecLines, elevatedLine(60, "switch\\tc3d4")), 1, "switch through pkexec");
            assertEqual(count(accounts.pkexecLines, elevatedLine(60, "switch\\tremove\\ta1b2")), 1, "remove through pkexec");
            assertEqual(count(accounts.logLines, /^switch remove c3d4$/), 0, "the account in use never removed");
            assertEqual(count(accounts.pkexecLines, elevatedLine(60, "login")), 1, "add: a bare login through pkexec");
        });

        // ---- the operator: the list re-read by itself after a change (no prompt) ----
        const accountsOperator = scenario("accounts-operator", { state: "running" });
        then(accountsOperator, "read", () => accountsOperator.client.status !== null && accountsOperator.client.userName !== "", () => {
            accountsOperator.client.environment = Object.assign({}, accountsOperator.env, { TS_FAKE_USER: accountsOperator.client.userName });
            accountsOperator.client.becomeOperator();
        });
        then(accountsOperator, "the operator", () => accountsOperator.client.canChange && !accountsOperator.client.busy, () => accountsOperator.client.readAccounts());
        then(accountsOperator, "listed", () => accountsOperator.client.accounts !== null && !accountsOperator.client.busy, () => accountsOperator.client.removeAccount("c3d4"));
        then(accountsOperator, "removed, the list read again by itself", () => !accountsOperator.client.busy && accountsOperator.client.accounts.length === 1
                && accountsOperator.readCount === 2, () => {}, () => {
            accountsOperator.readCount = 0;
            const poll = () => _shell.run(["sh", "-c", "grep -c '^switch --list --json$' \"$1\" || true", "sh", accountsOperator.log], result => {
                accountsOperator.readCount = Number(result.lines[0] ?? 0);
                if (accountsOperator.readCount < 2 && accountsOperator.steps.length > 0)
                    Qt.callLater(poll);
            });
            poll();
        });
        then(accountsOperator, "an account added", () => accountsOperator.client.addAccount(), () => {});
        then(accountsOperator, "added", () => !accountsOperator.client.busy && accountsOperator.client.currentAccount.loginName === "user2@example.net", () => {
            // The operator is a setting of the profile: the new account's has none (truthful)
            assert(!accountsOperator.client.canChange, "the new account's profile: no operator (a per-profile setting)");
            assert(accountsOperator.client.accountsOutdated, "… so the list is not read by itself: out of date");
        });
        thenLogs(accountsOperator, "one pkexec", () => assertEqual(accountsOperator.pkexecLines.length, 1, "operator: nothing through pkexec but becoming it"));

        // ---- a login to add an account, cancelled after its URL: the way back ----
        const interrupted = scenario("login-interrupted", { state: "running", env: { TS_FAKE_OPERATOR: "1", TS_FAKE_LOGIN_DELAY: "8" } });
        then(interrupted, "read", () => interrupted.client.status !== null, () => interrupted.client.readAccounts());
        then(interrupted, "listed", () => interrupted.client.accounts !== null && !interrupted.client.busy, () => interrupted.client.addAccount());
        then(interrupted, "the URL", () => interrupted.client.authUrl !== "", () => interrupted.client.cancelLogin());
        then(interrupted, "cancelled: logged out, on an empty profile", () => !interrupted.client.busy && interrupted.client.view.phase === "logged-out", () => {
            same(interrupted.client.loginInterrupted, { id: "a1b2", title: "example-tailnet.ts.net" }, "the way back offered: the account before");
            assertEqual(interrupted.failures.length, 0, "cancelling is not a failure");
            assert(interrupted.client.switchAccount("a1b2"), "Back to it: starts");
        });
        then(interrupted, "back", () => !interrupted.client.busy && interrupted.client.view.phase === "running", () => {
            assertEqual(interrupted.client.loginInterrupted, null, "back: nothing to offer any more");
        });

        // ---- dismissed prompt while reading the accounts: nothing shown, nothing stuck ----
        const accountsDismissed = scenario("accounts-dismissed", { state: "running", env: { TS_FAKE_PKEXEC: "dismiss" } });
        then(accountsDismissed, "read", () => accountsDismissed.client.status !== null, () => accountsDismissed.client.readAccounts());
        then(accountsDismissed, "answered", () => !accountsDismissed.client.busy, () => {
            assertEqual(accountsDismissed.client.accounts, null, "dismissed: still not read");
            assertEqual(accountsDismissed.failures.length, 0, "… no failure shown");
            assertEqual(accountsDismissed.client.operation, "", "… not busy");
        });

        // ---- hostname and nickname: `set`, the page follows ----
        const hostname = scenario("hostname", { state: "running" });
        then(hostname, "read", () => hostname.client.status !== null, () => {
            assertEqual(hostname.client.device.hostName, "self", "this device: its name");
            assertEqual(hostname.client.device.customHostname, "", "… the system's");
            assert(!hostname.client.setHostname("bad.name"), "a name with a dot: refused before anything runs");
            assert(hostname.failures.some(failure => /dots/.test(failure.reason)), "… saying why");
            hostname.failures = [];
            assert(hostname.client.setHostname("box"), "rename to box: starts");
        });
        then(hostname, "renamed", () => !hostname.client.busy && hostname.client.device?.hostName === "box", () => {
            assertEqual(hostname.client.device.customHostname, "box", "… set here (prefs)");
            assertEqual(hostname.client.device.dnsName, "box.example-tailnet.ts.net", "… its MagicDNS name follows");
            assert(hostname.client.setNickname("home"), "nickname: starts");
        });
        then(hostname, "nicknamed", () => !hostname.client.busy, () => assertEqual(hostname.failures.length, 0, "no failure"));
        thenLogs(hostname, "after renaming", () => {
            assertEqual(count(hostname.pkexecLines, elevatedLine(60, "set\\t--hostname=box")), 1, "rename: `set --hostname=box` through pkexec");
            assertEqual(count(hostname.pkexecLines, elevatedLine(60, "set\\t--nickname=home")), 1, "nickname: `set --nickname=home` through pkexec");
            assertEqual(count(hostname.logLines, /bad\.name/), 0, "the refused name never ran");
        });

        // ---- diagnostics: on demand only; ping a device ----
        const diagnostics = scenario("diagnostics", { state: "running", fixtureBus: true });
        then(diagnostics, "read", () => diagnostics.client.status !== null && diagnostics.client.events >= 15, () => {
            assertEqual(diagnostics.client.diagnostics.ranAt, 0, "diagnostics: nothing run at start");
            assert(Array.isArray(diagnostics.client.busHealth), "health: the bus's list taken (its last message: none)");
            assertEqual(diagnostics.client.health.length, 0, "… so no warnings, even though status has none either");
            assert(diagnostics.client.runDiagnostics(), "run: starts");
            assert(!diagnostics.client.runDiagnostics(), "… not twice at once");
            assert(!diagnostics.client.busy, "… not the operation lock: changes stay possible");
            const laptop = diagnostics.client.devices.find(device => device.online);
            diagnostics.pinged = laptop.id;
            assert(diagnostics.client.ping(laptop), "ping a device: starts");
        });
        then(diagnostics, "ran", () => diagnostics.client.diagnostics.ranAt > 0 && !diagnostics.client.pings[diagnostics.pinged]?.running, () => {
            const result = diagnostics.client.diagnostics;
            assertEqual(result.errors.join(" | "), "", "no errors");
            assertEqual(result.clientVersion, "1.104.4", "the client's version");
            assertEqual(result.nearest?.code, "ams", "the nearest relay, named from the relay map");
            assert(result.netcheck.length >= 6 && result.dns.length >= 4, "netcheck and DNS rows");
            assertEqual(diagnostics.client.pings[diagnostics.pinged].text, "direct, 4 ms", "ping: direct, its time");
            const report = diagnostics.client.diagnosticsReport;
            assert(report.indexOf("Amsterdam (ams)") >= 0 && report.indexOf("MagicDNS: on") >= 0, "the report to copy holds the checks");
            assert(!/https?:\/\//.test(report) && report.indexOf("198.51.100") < 0, "… no links, no public address");
        });
        thenLogs(diagnostics, "after the checks", () => {
            assertEqual(count(diagnostics.logLines, /^netcheck --format=json$/), 1, "netcheck once");
            assertEqual(count(diagnostics.logLines, /^dns status --json$/), 1, "dns status once");
            assertEqual(count(diagnostics.logLines, /^debug derp-map$/), 1, "the relay map once");
            assertEqual(count(diagnostics.logLines, /^ping --c=1 --timeout=3s 100\.64\.0\.\d+$/), 1, "ping: one, 3 s, by address");
            assertEqual(diagnostics.pkexecLines.length, 0, "nothing of it through pkexec");
        });

        // ---- a netcheck that fails: said, not stuck ----
        const netcheckFails = scenario("netcheck-fails", { state: "running", env: { TS_FAKE_NETCHECK: "fail", TS_FAKE_PING: "timeout" } });
        then(netcheckFails, "read", () => netcheckFails.client.status !== null, () => {
            netcheckFails.client.runDiagnostics();
            const device = netcheckFails.client.devices.find(item => item.online);
            netcheckFails.pinged = device.id;
            netcheckFails.client.ping(device);
        });
        then(netcheckFails, "ran", () => netcheckFails.client.diagnostics.ranAt > 0 && !netcheckFails.client.pings[netcheckFails.pinged]?.running, () => {
            assert(netcheckFails.client.diagnostics.errors.some(error => /^netcheck/.test(error)), "netcheck's failure said: " + netcheckFails.client.diagnostics.errors.join(" | "));
            assert(netcheckFails.client.diagnostics.dns.length > 0, "… the other checks still ran");
            assertEqual(netcheckFails.client.pings[netcheckFails.pinged].text, "no reply", "ping without a reply: \"no reply\"");
        });

        // ---- a login moves to the empty profile BEFORE its URL: cancelled before the URL ----
        const early = scenario("login-cancelled-early", { state: "running", env: { TS_FAKE_OPERATOR: "1", TS_FAKE_LOGIN_URL_DELAY: "8" } });
        then(early, "read", () => early.client.status !== null, () => early.client.readAccounts());
        then(early, "listed", () => early.client.accounts !== null && !early.client.busy, () => early.client.addAccount());
        waitMs(early, 700);
        then(early, "still no URL", () => early.client.authUrl === "", () => early.client.cancelLogin());
        then(early, "the next read: no login → Switch back", () => early.client.loginInterrupted !== null, () => {
            same(early.client.loginInterrupted, { id: "a1b2", title: "example-tailnet.ts.net" }, "offered without a URL ever seen: the state decided");
            assertEqual(early.failures.length, 0, "cancelling is not a failure");
        });

        // ---- the plain login moved, then was refused; the password prompt dismissed ----
        const refusedAfter = scenario("login-dismissed-after-move", { state: "running", env: { TS_FAKE_OPERATOR: "1", TS_FAKE_LOGIN_DENY_AFTER_SWITCH: "1", TS_FAKE_PKEXEC: "dismiss" } });
        then(refusedAfter, "read", () => refusedAfter.client.status !== null, () => refusedAfter.client.addAccount());
        then(refusedAfter, "dismissed, then read", () => !refusedAfter.client.busy && refusedAfter.client.loginInterrupted !== null, () => {
            same(refusedAfter.client.loginInterrupted, { id: "", title: "" }, "Switch back offered (the list not read: Show accounts)");
            assertEqual(refusedAfter.failures.length, 0, "dismissed: nothing shown");
            assertEqual(refusedAfter.client.view.phase, "logged-out", "… the daemon on the empty profile");
        });

        // ---- the plain login refused before any move (not the operator), prompt dismissed ----
        const refusedBefore = scenario("login-dismissed-no-move", { state: "running", env: { TS_FAKE_PKEXEC: "dismiss" } });
        then(refusedBefore, "read", () => refusedBefore.client.status !== null, () => refusedBefore.client.addAccount());
        then(refusedBefore, "dismissed", () => !refusedBefore.client.busy, () => {});
        waitMs(refusedBefore, 600);
        then(refusedBefore, "nothing moved", () => !refusedBefore.client._reading, () => {
            assertEqual(refusedBefore.client.loginInterrupted, null, "still on the account: nothing offered");
            assertEqual(refusedBefore.client.view.phase, "running", "… still connected");
        });

        // ---- the same account again: merged, with login's default settings ----
        const sameAccount = scenario("login-same-account", { state: "running", env: { TS_FAKE_OPERATOR: "1", TS_FAKE_LOGIN_SAME: "1" } });
        then(sameAccount, "read", () => sameAccount.client.prefs !== null, () => sameAccount.client.setHostname("box"));
        then(sameAccount, "renamed", () => !sameAccount.client.busy && sameAccount.client.device?.customHostname === "box", () => {
            assert(sameAccount.client.prefs.acceptRoutes, "before: routes accepted (the fixture)");
            sameAccount.client.addAccount();
        });
        then(sameAccount, "logged in again", () => !sameAccount.client.busy && sameAccount.client.view.phase === "running" && sameAccount.client.device?.customHostname === "", () => {
            assertEqual(sameAccount.client.currentAccount.loginName, "user1@example.com", "the same account");
            assertEqual(sameAccount.client.prefs.acceptRoutes, false, "its settings reset: routes no longer accepted (documents the reset)");
            assertEqual(sameAccount.client.device.hostName, "self", "… the name set here gone");
            assertEqual(sameAccount.client.loginInterrupted, null, "nothing interrupted");
        });

        // ---- the IPC's origin: a denial is a failure, never a prompt ----
        const ipcOrigin = scenario("ipc-origin", { state: "running" });
        then(ipcOrigin, "read", () => ipcOrigin.client.status !== null, () => {
            assert(ipcOrigin.client.switchAccount("c3d4", "network"), "switch (origin network): runs plainly");
        });
        then(ipcOrigin, "denied", () => !ipcOrigin.client.busy && ipcOrigin.failures.length > 0, () => {
            assert(/no password prompt/.test(ipcOrigin.failures[0].reason), "a failure saying so: " + ipcOrigin.failures[0].reason);
            assertEqual(ipcOrigin.client.pendingAttention, null, "… no attention");
            ipcOrigin.client.setHostname("box", "network");
        });
        then(ipcOrigin, "denied again", () => !ipcOrigin.client.busy && ipcOrigin.failures.length > 1, () => {});
        thenLogs(ipcOrigin, "no prompt", () => {
            assertEqual(ipcOrigin.pkexecLines.length, 0, "origin network: nothing through pkexec");
            assertEqual(count(ipcOrigin.logLines, /^switch c3d4$/), 1, "… the plain switch tried once");
        });

        _clock.start();
    }
}
