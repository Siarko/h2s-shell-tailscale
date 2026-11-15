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
    // scenario), daemonDown, env {}, toolsDir, fixedNow, loginTimeoutMs, emptyTools }
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
            if (s.options.busLines > 0)
                lines.push("i=0; while [ $i -lt " + s.options.busLines + " ]; do echo '{\"State\":6}'; i=$((i+1)); done > \"$1/bus.jsonl\"");
            _shell.run(["sh", "-c", lines.join(" && "), "sh", dir, s.options.state ?? ""], result => {
                if (!result.ok)
                    fail(name + ": set up failed: " + result.error);
                s.client = _clientComponent.createObject(suite, {
                    toolsDir: s.options.emptyTools ? dir + "/empty-tools" : standIns,
                    environment: s.env, readDebounceMs: 100, streamBackoffMinMs: 200, streamBackoffMaxMs: 800, pollMs: 2000,
                    loginTimeoutMs: s.options.loginTimeoutMs ?? 60000, fixedNow: s.options.fixedNow ?? 0
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
        const reads = [/^status --json$/, /^debug prefs$/, /^exit-node suggest$/, /^version$/];
        return (s.logLines ?? []).filter(line => !line.startsWith("curl ") && !line.startsWith("xdg-open ") && !line.startsWith("systemctl ")
            && !reads.some(pattern => pattern.test(line)));
    }

    function count(lines, pattern) {
        return (lines ?? []).filter(line => pattern.test(line)).length;
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
            const others = changes.filter(line => !/^(set |up$|down$|login$|logout$)/.test(line));
            assertEqual(others.join(" | "), "", s.name + ": every change is a `set` (or bare up/down/login/logout)");
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
            assert(_entry(running).name.startsWith("Tailscale · "), "running: named after the tailnet: " + _entry(running).name);
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
            assertEqual(count(stopped.pkexecLines, /^pkexec\t\/\S+\/tailscale\tup$/), 1, "… through pkexec by tailscale's absolute path");
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
            assertEqual(count(login.pkexecLines, /\tlogin$/), 1, "… through pkexec");
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
            assert(_entry(operator).name.startsWith("Tailscale · "), "… the tailnet's name remembered");
        });
        thenLogs(operator, "after logout", () => {
            assertEqual(count(operator.logLines, /^logout$/), 1, "logout: run once, plainly");
            assertEqual(operator.pkexecLines.length, 0, "operator: no pkexec at all");
        });

        // ---- key expiring / expired ----
        const expiring = scenario("key-expiring", { state: "key-expiring", fixedNow: fixedNow });
        then(expiring, "read", () => expiring.client.status !== null, () => {
            assert(expiring.client.warnings.some(warning => warning.kind === "key-expiring"), "key expiring: a warning");
            assertEqual(_entry(expiring).attention, null, "… not attention");
            assertEqual(expiring.client.keyExpiry?.days, 3, "… in 3 days");
        });
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
        then(dying, "restarted", () => dying.client.streamStarts >= 3, () => {
            assert(dying.client.status !== null && _entry(dying).state === "activated", "a dying stream: the state still read");
        });

        // ---- a burst of 50 bus messages: a couple of reads ----
        const burst = scenario("burst", { state: "running", busLines: 50, env: { TS_FAKE_BUS_FILE: base + "/burst/bus.jsonl" } });
        then(burst, "50 messages read", () => burst.client.events >= 50 && !burst.client._reading && !burst.client._readTimer.running, () => {
            assert(burst.client.reads <= 3, "50 bus messages: at most 3 reads (" + burst.client.reads + ")");
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

        _clock.start();
    }
}
