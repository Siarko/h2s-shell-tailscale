import QtQuick
import Quickshell
import qs.api
import qs.tests
import ".."
import "liveSuites.js" as LiveSuites

// The live side (TailscaleClient) against the stand-ins (tests/stand-in): every scenario the
// stand-in tailscale supports, each with a client, a state directory and logs of its own, side
// by side. Asserts on what the client shows AND on what was run (the stand-ins log argv): `up`
// never has a flag, every change is a `set`, nothing privileged and no browser on origin
// "network"; every run as administrator with its `what` for the prompt. Nothing here reaches
// a real tailscale: each client's handle is a ScenarioHandle — the stand-ins as its programs,
// as the shell hands them over in module test mode, and the shell's own runs as administrator
// (its queue, the stand-in pkexec) with the scenario's environment.
TestCase {
    id: suite
    suiteName: "tailscale: the live side against the stand-ins"
    asynchronous: true
    // Many scenarios: more than the runner's 20 s default — the runner's cap. Set only where the
    // shell knows the property (TestCase.timeLimitMs), so the suite still compiles on an older one
    Component.onCompleted: {
        LiveSuites.register(suite);
        if ("timeLimitMs" in suite)
            suite["timeLimitMs"] = 60000;
    }
    // How many scenarios run at once. All of them at once (about fifty clients, each with its
    // stream, reads and stand-ins) starved the event loop: a scenario's set-up alone took up to
    // 7 s of a step's budget, and steps timed out in about one run of three. The other live
    // suites run beside this one.
    property int maxConcurrent: 16
    // How long a step waits for its condition (wall clock): a bound for a failure, not a delay —
    // a step goes on as soon as its condition holds
    property int stepTimeoutMs: 15000

    function _path(url) {
        return String(url).replace(/^file:\/\//, "").replace(/\/+$/, "");
    }

    readonly property string standIns: _path(Qt.resolvedUrl("stand-in"))
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
    property Component _moduleComponent: Component {
        ScenarioHandle {}
    }
    property Component _runnerComponent: Component {
        CommandRunner {}
    }

    // A scenario's runner that records what the client starts (s.runs: { argv, timeoutMs,
    // killAfterMs, maxOutputBytes, keepOutput, streamed (it reads the lines as they come),
    // environment, cancelled, answered (times done came), result }) and hands every run to a
    // real runner — or, where the scenario's `fakeRun(argv)` says so, answers it itself:
    // { result } (that result, frozen, soon after start returned) or { hold: true } (no
    // answer until the suite calls record.deliver(result), whatever happened since)
    function _recorder(s) {
        const real = _runnerComponent.createObject(suite);
        s.runs = [];
        return {
            start: (argv, options) => {
                const record = { argv: Array.from(argv ?? []), timeoutMs: options?.timeoutMs, killAfterMs: options?.killAfterMs,
                                 maxOutputBytes: options?.maxOutputBytes, keepOutput: options?.keepOutput !== false,
                                 streamed: typeof options?.onStdout === "function",
                                 environment: options?.environment ?? null, cancelled: false, answered: 0, result: null };
                s.runs.push(record);
                const fake = s.options.fakeRun?.(record.argv) ?? null;
                if (fake !== null) {
                    record.deliver = result => {
                        record.answered++;
                        record.result = Object.freeze(Object.assign({ ok: false, code: -1, stdout: "", stderr: "", timedOut: false, cancelled: false,
                                                                      failedToStart: false, truncated: false, durationMs: 0, error: "" }, result));
                        options?.done?.(record.result);
                    };
                    if (fake.result)
                        Qt.callLater(() => record.deliver(fake.result));
                    return {
                        get running() {
                            return record.answered === 0;
                        },
                        cancel: () => record.cancelled = true
                    };
                }
                const handle = real.start(argv, Object.assign({}, options, { done: result => {
                    record.answered++;
                    record.result = result;
                    options?.done?.(result);
                } }));
                return {
                    get running() {
                        return handle.running;
                    },
                    cancel: () => {
                        record.cancelled = true;
                        handle.cancel();
                    }
                };
            },
            cancelAll: () => {
                for (const record of s.runs)
                    if (record.answered === 0)
                        record.cancelled = true;
                real.cancelAll();
            }
        };
    }

    // ---- The scenario machinery ----

    // A scenario: its own directory, stand-in state and client. options: { state (the stand-in
    // scenario), daemonDown, holdStatus (the stand-in's `status` waits until the state
    // directory's status-hold is removed), env {}, fixedNow, loginTimeoutMs, emptyTools (no
    // program found), lateTools (none found until a recheck after install()), recheckMinMs,
    // without (that program not found), untrusted (that program judged untrusted), timeLimits,
    // setup (shell lines run once the state directory is made, $1 the scenario's directory),
    // forwarding ("<ipv4> <ipv6>", 1 or 0: what the system's facts read) }
    function scenario(name, options) {
        const dir = base + "/" + name;
        const s = { name: name, dir: dir, log: dir + "/log", pkexecLog: dir + "/pkexec.log", client: null, failures: [],
                    steps: [], waitedUntil: 0, started: false, logText: "", pkexecText: "", logsRead: false, options: options ?? {} };
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
            const lines = ["mkdir -p \"$1/state\"", ": > \"$1/log\"", ": > \"$1/pkexec.log\""];
            if (s.options.state)
                lines.push("printf '%s\\n' \"$2\" > \"$1/state/scenario\"");
            if (s.options.daemonDown)
                lines.push(": > \"$1/state/daemon-down\"");
            if (s.options.holdStatus)
                lines.push(": > \"$1/state/status-hold\"");
            lines.push("echo '{\"Health\":{\"Warnings\":{}}}' > \"$1/bus.jsonl\"");
            // Lines run after the state directory is made ($1 the scenario's directory)
            for (const line of s.options.setup ?? [])
                lines.push(line);
            if (s.options.busLines > 0)
                lines.push("i=0; while [ $i -lt " + s.options.busLines + " ]; do echo '{\"State\":6}'; i=$((i+1)); done > \"$1/bus.jsonl\"");
            _shell.run(["sh", "-c", lines.join(" && "), "sh", dir, s.options.state ?? ""], result => {
                if (!result.ok)
                    fail(name + ": set up failed: " + result.error);
                s.module = _moduleComponent.createObject(suite);
                s.module.programs = s.module.programsIn({ missing: s.options.emptyTools === true || s.options.lateTools === true,
                                                          without: s.options.without, untrusted: s.options.untrusted });
                // IP forwarding as the system's facts read it: "<ipv4> <ipv6>"
                const forwarding = (s.options.forwarding ?? "1 1").split(" ").map(value => value === "1");
                const recorded = s.options.recordRuns === true ? { runner: _recorder(s) } : {};
                s.client = _clientComponent.createObject(suite, Object.assign(recorded, {
                    // The OS's host name: the fixtures' own device's (as on a machine Tailscale is named after)
                    module: s.module, system: Object.assign({}, Api.system, { hostName: s.options.hostName ?? "self",
                                                                             readIpForwarding: () => ({ ipv4: forwarding[0], ipv6: forwarding[1] }) }),
                    environment: s.env, readDebounceMs: 100, streamBackoffMinMs: 200, streamBackoffMaxMs: 800, pollMs: s.options.pollMs ?? 2000,
                    loginTimeoutMs: s.options.loginTimeoutMs ?? 60000, fixedNow: s.options.fixedNow ?? 0,
                    timeLimits: s.options.timeLimits ?? {}, readRetryMinMs: 300, readRetryMaxMs: 1200, recheckMinMs: s.options.recheckMinMs ?? 5000
                }));
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
            /^debug derp-map$/, /^ping --c=1 --timeout=3s \S+$/, /^switch --list --json$/, /^lock status --json$/, /^serve status --json$/];
        return (s.logLines ?? []).filter(line => !line.startsWith("curl ") && !line.startsWith("xdg-open ") && !line.startsWith("systemctl ")
            && !reads.some(pattern => pattern.test(line)));
    }

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    function count(lines, pattern) {
        return (lines ?? []).filter(line => pattern.test(line)).length;
    }

    // A pkexec log line's pattern: pkexec, the shell's timeout (by absolute path) with its
    // limit, the stand-in tailscale, then `rest` (tab-separated)
    function elevatedLine(seconds, rest) {
        const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        return new RegExp("^pkexec\\t/[^\\t]*/timeout\\t-k\\t3\\t" + seconds + "\\t" + escape(standIns) + "/tailscale\\t" + rest + "$");
    }

    // Api.openUrl was asked to open `url` (in module test mode it records; any scenario's)
    function opened(url) {
        return (ModuleTestKit.opened ?? []).some(entry => entry.url === url);
    }

    // The runs as administrator the scenario's client asked for: [{ argv, what, timeoutMs }]
    function elevatedCalls(s) {
        return s.module?.privileged.calls ?? [];
    }

    // The `what` words of those runs, in order
    function whats(s) {
        return elevatedCalls(s).map(call => call.what);
    }

    // A step that runs `script` (sh -c, $1 = the scenario's directory) and stores its output's
    // first line in s[key]
    function thenShell(s, description, script, key, action) {
        then(s, description, () => s[key] !== undefined, () => action(s[key]), () => {
            s[key] = undefined;
            _shell.run(["sh", "-c", script, "sh", s.dir], result => s[key] = (result.lines[0] ?? "").trim());
        });
    }

    // A step that runs `script` (as thenShell) again and again (300 ms apart) until its first
    // line is `wanted` — waiting on a condition outside the client (a process gone, the
    // stand-in's state) — then action(the last line)
    function thenShellUntil(s, description, script, key, wanted, action) {
        const run = () => {
            s[key + "Running"] = true;
            s[key + "At"] = Date.now();
            _shell.run(["sh", "-c", script, "sh", s.dir], result => {
                s[key] = (result.lines[0] ?? "").trim();
                s[key + "Running"] = false;
            });
        };
        then(s, description, () => {
            if (s[key] === wanted)
                return true;
            if (!s[key + "Running"] && Date.now() - s[key + "At"] >= 300)
                run();
            return false;
        }, () => action(s[key]), () => {
            s[key] = undefined;
            run();
        });
    }

    // A script for thenShellUntil: how many of the scenario's processes (by the stand-ins' state
    // directory in their environment) have a command line matching `pattern` (grep -E). One
    // grep over every environ (a grep per process overran a step's time on a busy machine)
    function processesScript(pattern) {
        return "for f in $(grep -lzx \"TS_FAKE_STATE_DIR=$1/state\" /proc/[0-9]*/environ 2> /dev/null); do p=${f%/environ}; { tr '\\0' ' ' < \"$p/cmdline\"; } 2> /dev/null | grep -qE '"
            + pattern + "' && echo \"$p\"; done | wc -l";
    }

    property Timer _clock: Timer {
        interval: 40
        repeat: true
        onTriggered: {
            // Only the first maxConcurrent scenarios run; the rest wait their turn (a scenario
            // starts nothing before its first step)
            for (const s of suite._scenarios.slice(0, suite.maxConcurrent)) {
                const step = s.steps[0];
                if (!step)
                    continue;
                if (!s.started) {
                    s.started = true;
                    s.waitedUntil = Date.now() + suite.stepTimeoutMs;
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
            assertEqual(running.client.tailscalePath, standIns + "/tailscale", "running: tailscale by the absolute path its handle's programs give");
            assertEqual(running.client.curlPath, standIns + "/curl", "… curl too");
            running.client.suggest(() => running.suggested = true);
        });
        then(running, "exit-node suggest answered", () => running.suggested === true, () => {
            assert(running.client.exitNodes.suggested !== null || running.client.suggestedName !== "", "suggest: the suggestion is known");
            running.readsBefore = running.client.reads;
        });
        // The slow poll re-reads while the stream is up too (peers' online state)
        then(running, "the slow poll read again", () => running.client.reads > running.readsBefore, () => {
            assert(running.client.streamUp, "the slow poll read again, the stream still up");
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
            same(elevatedCalls(stopped), [{ argv: [standIns + "/tailscale", "up"], what: "Connect", timeoutMs: 60000 }],
                 "… asked of the shell as one run: tailscale by its trusted path, \"Connect\" for the prompt, the 60 s limit");
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
            assertEqual(login.client.opened, 0, "origin network: no browser");
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
            assertEqual(login.client.opened, 1, "the browser opened ONCE");
            assert(opened("https://login.tailscale.com/a/REDACTED"), "… with the login link, through Api.openUrl (recorded in module test mode)");
            same(whats(login), ["Log in"], "… the run as administrator says \"Log in\"");
            assertEqual(elevatedCalls(login)[0]?.timeoutMs, 60000, "… under the login's limit");
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
            assertEqual(approval.client.opened, 1, "attend: a link opened");
            assert(opened("https://login.tailscale.com/admin/machines"), "… the admin console");
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
            assert(!exitNode.client.networkExit.overridden, "no choice by hand yet");
            exitNode.client.setExitNode(peer4);
            assert(!exitNode.client.networkExit.overridden, "… not \"for now\" while its run goes on");
        });
        then(exitNode, "via peer4", () => /^Via /.test(_entry(exitNode).status) && !exitNode.client.busy, () => {
            assert(exitNode.client.networkExit.overridden, "… succeeded: \"for now\", over the networks' choices");
            assertEqual(_entry(exitNode).status, "Via peer4", "exit node set: \"Via peer4\"");
            assert(exitNode.client.exitNodes.current?.name === "peer4", "… current in the chooser");
            exitNode.client.setExitNode(null);
        });
        then(exitNode, "none", () => _entry(exitNode).status === "Tailnet only" && !exitNode.client.busy, () => {
            assert(exitNode.client.networkExit.overridden, "\"None\" chosen: for now too");
            // The computer woke (the handle's resumed(), as the shell sends it): the choice by
            // hand ends, the networks' choices apply again
            exitNode.module.resumed();
            assert(!exitNode.client.networkExit.overridden, "woken: the choice by hand dropped");
        });
        thenLogs(exitNode, "after the exit nodes", () => {
            assertEqual(count(exitNode.logLines, /^set --exit-node=100\.64\.0\.4$/), 1, "set --exit-node=<its IPv4>");
            assertEqual(count(exitNode.logLines, /^set --exit-node=$/), 1, "set --exit-node= (none)");
        });

        // ---- "for now" only once the pick succeeded: a dismissed prompt, a failed run, a time
        // limit, a refusal while another change runs leave the networks' choices as they were,
        // and the network's choice applies at the next network change ----
        const cafe = { id: "cafe-uuid", name: "Café", kind: "wifi", active: true };
        const work = { id: "work-uuid", name: "Work", kind: "wifi", active: true };
        // The café taken (its choice: none, in use), the work network's: peer4
        const onCafe = s => {
            const exit = s.client.networkExit;
            exit.setChoice("cafe-uuid", "none", "", "Café");
            exit.setChoice("work-uuid", "nPEER4CNTRL", "peer4", "Work");
            exit.lastKey = "cafe-uuid";
            exit.networks = [cafe];
        };
        const pickFails = (name, options, pick, checks) => {
            const s = scenario(name, Object.assign({ state: "running" }, options));
            then(s, "read", () => s.client.status !== null && s.client.prefs?.ok === true && s.client.exitNodes.count > 0, () => {
                onCafe(s);
                pick(s);
            });
            then(s, "the pick ended", () => !s.client.busy && s.client.operation === "", () => {
                const exit = s.client.networkExit;
                same([exit.overridden, exit.lastKey, exit.effect.kind], [false, "cafe-uuid", "network"], name + ": no \"for now\", the café still taken, its choice in effect");
                checks?.(s);
                exit.networks = [work];
            });
            // The prefs name no operator (canChange false): decided as "needs the operator",
            // never a prompt — not left waiting behind a "for now"
            then(s, "the next network change", () => ["applied", "needs-operator", "failed"].includes(s.client.networkExit.decision.kind) && !s.client.busy, () => {
                assertEqual(s.client.networkExit.decision.kind, "needs-operator", name + ": … the work network's choice decided");
            });
            return s;
        };
        const peer4Of = s => s.client.exitNodes.own.find(option => option.name === "peer4");
        pickFails("for-now-dismissed", { env: { TS_FAKE_PKEXEC: "dismiss" } }, s => assert(s.client.setExitNode(peer4Of(s)), "a pick, not the operator: asks"),
                  s => assertEqual(s.failures.length, 0, "… dismissed: silent"));
        pickFails("for-now-failed", { env: { TS_FAKE_OPERATOR: "1" } }, s => assert(s.client.setExitNode(Object.assign({}, peer4Of(s), { argument: "nosuch" })), "a pick that fails"),
                  s => assert(s.failures.length === 1, "… its failure said"));
        // Only the pick's run runs out of time (the first `set --exit-node`), the network's runs
        let timeoutsLeft = 1;
        pickFails("for-now-timeout", { env: { TS_FAKE_OPERATOR: "1" }, recordRuns: true,
                                       fakeRun: argv => argv[1] === "set" && argv[2] === "--exit-node=100.64.0.4" && timeoutsLeft-- > 0 ? { result: { ok: false, code: -1, timedOut: true } } : null },
                  s => assert(s.client.setExitNode(peer4Of(s)), "a pick that runs out of time"),
                  s => assert(/did not answer within/.test(s.failures[0]?.reason ?? ""), "… said: " + (s.failures[0]?.reason ?? "")));
        pickFails("for-now-busy", { env: { TS_FAKE_OPERATOR: "1" }, recordRuns: true,
                                                    fakeRun: argv => argv[1] === "set" && argv[2] === "--accept-routes=true" ? { hold: true } : null }, s => {
            assert(s.client.setAcceptRoutes(true), "another change runs");
            assert(!s.client.setExitNode(peer4Of(s)), "… a pick meanwhile: refused");
            assertEqual(s.client.networkExit.overridden, false, "… no \"for now\"");
            s.runs.find(run => run.argv[2] === "--accept-routes=true").deliver({ ok: true, code: 0 });
        });

        // ---- a wake while the user's pick runs: the pick, once it succeeds, is "for now" — the
        // network's choice (waiting for the change lock) never overwrites it ----
        // This user the operator (the prefs say so): the café's change can run plainly
        const wakeDuring = scenario("for-now-wake-during-pick", { state: "running", env: { TS_FAKE_OPERATOR: "1" }, recordRuns: true,
                                                                  setup: ["printf 'OperatorUser=%s\\n' '" + Api.system.userName + "' > \"$1/state/prefs\""],
                                                                  fakeRun: argv => argv[1] === "set" && argv[2] === "--exit-node=100.64.0.10" ? { hold: true } : null });
        then(wakeDuring, "read", () => wakeDuring.client.status !== null && wakeDuring.client.prefs?.ok === true && wakeDuring.client.exitNodes.count > 0, () => {
            assert(wakeDuring.client.canChange, "the operator");
            onCafe(wakeDuring);
            assert(wakeDuring.client.setExitNode(peer4Of(wakeDuring)), "a first pick: peer4");
        });
        // peer4 read back in the prefs: the café's "none" is a real change from here on
        then(wakeDuring, "for now", () => wakeDuring.client.networkExit.overridden && !wakeDuring.client.busy && wakeDuring.client.prefs?.exitNodeId === "nPEER4CNTRL", () => {
            const peer10 = wakeDuring.client.exitNodes.own.find(option => option.name === "peer10") ?? null;
            assert(peer10 !== null, "peer10 offered");
            assert(wakeDuring.client.setExitNode(Object.assign({}, peer10, { online: true, argument: "100.64.0.10" })), "a second pick, held in flight");
            wakeDuring.module.resumed();
            same([wakeDuring.client.networkExit.overridden, wakeDuring.client.busy], [false, true], "woken while it runs: the first pick's \"for now\" ended, the pick still running");
            assertEqual(wakeDuring.client.networkExit.lastKey, "", "… the café open: its \"none\" is due");
        });
        // The café's "none" is due (the first pick's peer4 in use) and waits for the change lock
        then(wakeDuring, "the café's choice waits for the lock", () => !wakeDuring.client.networkExit.overridden && wakeDuring.client.busy, () => {
            assertEqual(wakeDuring.runs.filter(run => run.argv[1] === "set" && run.argv[2] === "--exit-node=").length, 0, "… the café's \"none\" not run while the pick runs");
            wakeDuring.runs.find(run => run.argv[2] === "--exit-node=100.64.0.10").deliver({ ok: true, code: 0 });
            assert(wakeDuring.client.networkExit.overridden, "the pick succeeded: \"for now\"");
        });
        then(wakeDuring, "after it", () => !wakeDuring.client.busy && wakeDuring.client.reads > 0, () => {
            const exit = wakeDuring.client.networkExit;
            same([exit.overridden, exit.decision.kind, wakeDuring.runs.filter(run => run.argv[1] === "set" && run.argv[2] === "--exit-node=").length], [true, "override", 0],
                 "… the café's choice never ran over it");
            // "Default" now: the café's "none" runs (it was due, only the pick held it off)
            assert(exit.dropOverride(), "\"Default\"");
        });
        then(wakeDuring, "Default: the café's choice", () => wakeDuring.client.networkExit.decision.kind === "applied" && !wakeDuring.client.busy, () => {
            assertEqual(wakeDuring.runs.filter(run => run.argv[1] === "set" && run.argv[2] === "--exit-node=").length, 1, "… the café's \"none\" ran once");
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

        // The real clock: the grace ends by the client's one-shot timer, not at the next minute
        // of the shell's clock (Api.minuteNow) or the next read
        const graceClock = scenario("exit-node-offline-clock", { state: "exit-node-offline" });
        then(graceClock, "read", () => graceClock.client.status !== null && graceClock.client.exitNodeOfflineSince > 0, () => {
            assert(graceClock.client._graceTimer.running, "offline exit node, real clock: the grace timer runs");
            assert(graceClock.client._graceTimer.interval > TailscaleRules.exitNodeOfflineGraceMs, "… just past the grace");
            graceClock.momentBefore = graceClock.client.now;
            // Shortened here: what it does when it fires is what counts
            graceClock.client._graceTimer.interval = 100;
            graceClock.client._graceTimer.restart();
        });
        then(graceClock, "the timer fired", () => !graceClock.client._graceTimer.running, () => {
            assert(graceClock.client.now > graceClock.momentBefore, "… firing, it moves the time the state is derived at on");
            graceClock.client._graceTimer.interval = TailscaleRules.exitNodeOfflineGraceMs + 250;
            graceClock.client.running = false;
            same([graceClock.client.exitNodeOfflineSince, graceClock.client._graceTimer.running], [0, false],
                 "stopped: the offline moment forgotten with its timer (a restart counts the grace afresh)");
            graceClock.client.running = true;
        });
        then(graceClock, "read again", () => graceClock.client.exitNodeOfflineSince > 0, () => {
            assert(graceClock.client._graceTimer.running, "started again, the exit node still offline: the grace timer runs again, never a grace without its timer");
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
            assertEqual(_entry(missing).attention?.reason, "Tailscale isn't installed", "CLI missing: the entry says \"not installed\"");
            assertEqual(_entry(missing).status, "Not installed", "… its status");
            assert(missing.client.ready, "… ready (there is nothing to read)");
            assertEqual(_entry(missing).attention?.action, "Check again", "… its action looks again");
            assert(missing.client.connect("user"), "… Connect looks for it again (installed since?), nothing else");
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
            same(whats(dismissed), ["Block incoming connections"], "… the run said what for: \"Block incoming connections\"");
        });
        const noAgent = scenario("pkexec-no-agent", { state: "stopped", env: { TS_FAKE_PKEXEC: "no-agent" } });
        then(noAgent, "read", () => noAgent.client.status !== null, () => noAgent.client.connect("user"));
        then(noAgent, "failed", () => noAgent.client.failureText !== "" && !noAgent.client.busy, () => {
            // pkexec's 127 is the shell's `refused`, which the shell tells itself, once
            assertEqual(noAgent.failures.length, 0, "refused (no agent): not notified again by the module");
            assertEqual(_entry(noAgent).state, "", "… the state back to off");
            assertEqual(_entry(noAgent).status, "Not allowed.", "… and the entry's status line says it, where the click was");
            assertEqual(_entry(noAgent).attention, null, "… not as attention: Connect stays the button (and the shell may still connect it)");
            noAgent.firstFailure = noAgent.client.failure;
            assert(noAgent.client.connect("user"), "… Connect tries again");
        });
        then(noAgent, "tried again", () => elevatedCalls(noAgent).length === 2 && noAgent.client.failureText !== "" && !noAgent.client.busy, () => {
            assertEqual(_entry(noAgent).status, "Not allowed.", "the second failure said again");
        });
        thenLogs(noAgent, "both tries asked pkexec", () => assertEqual(count(noAgent.pkexecLines, elevatedLine(60, "up")), 2, "pkexec asked for `up` twice"));
        // A failed Connect leaves no attention: the shell's "VPN with a network" still connects
        // it (origin network, as the operator now), and the failure text goes
        const thenNetwork = scenario("failed-then-network-connect", { state: "stopped", env: { TS_FAKE_PKEXEC: "no-agent" } });
        then(thenNetwork, "read", () => thenNetwork.client.status !== null, () => thenNetwork.client.connect("user"));
        then(thenNetwork, "failed", () => thenNetwork.client.failureText !== "" && !thenNetwork.client.busy, () => {
            assertEqual(_entry(thenNetwork).attention, null, "failed Connect: no attention on the entry");
            assertEqual(thenNetwork.client.attentionKind, "", "… nor in what the IPC reports");
            // This user made the operator elsewhere: a network's connect needs no password
            thenNetwork.client.environment = Object.assign({}, thenNetwork.env, { TS_FAKE_USER: thenNetwork.client.userName });
        });
        thenShell(thenNetwork, "made the operator elsewhere", "printf 'OperatorUser=%s\\n' '" + Api.system.userName + "' >> \"$1/state/prefs\" && echo ok", "operatorSet",
                  () => thenNetwork.client.refresh());
        then(thenNetwork, "the operator", () => thenNetwork.client.canChange && !thenNetwork.client._reading, () => {
            assertEqual(thenNetwork.client.failureText, "Not allowed.", "the failure text still there (same phase)");
            assert(thenNetwork.client.connect("network"), "a network's connect goes ahead");
            assertEqual(thenNetwork.client.failureText, "", "… and the failure text is gone once it starts");
        });
        then(thenNetwork, "connected", () => _entry(thenNetwork).state === "activated" && !thenNetwork.client.busy, () => {
            assertEqual(_entry(thenNetwork).status, "Tailnet only", "connected: the normal status line");
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
            same(elevatedCalls(elevated), [{ argv: [standIns + "/tailscale", "set", "--accept-routes=false"], what: "Ignore routes", timeoutMs: 60000 }],
                 "… the run: the change by tailscale's trusted path, \"Ignore routes\", the change's limit");
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
            same(whats(become), ["Become the operator"], "… the run said \"Become the operator\"");
        });

        // ---- the stream dying and coming back ----
        const dying = scenario("stream-dies", { state: "running", env: { TS_FAKE_BUS_END: "die" } });
        then(dying, "restarted (and read: under the load of the other scenarios a read may come after the third start)", () => dying.client.streamStarts >= 3 && dying.client.status !== null && !dying.client._reading, () => {
            assert(dying.client.status !== null && _entry(dying).state === "activated", "a dying stream: the state still read");
        });

        // ---- a burst of 50 bus messages: a couple of reads ----
        // No slow poll here (pollMs very high): the read count then measures only the debouncing
        const burst = scenario("burst", { state: "running", busLines: 50, pollMs: 3600000, env: { TS_FAKE_BUS_FILE: base + "/burst/bus.jsonl" } });
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
            assertEqual(cancel.client.loginNote, "Close the login page in the browser: the login runs on as administrator until its time limit.",
                        "cancelled once it printed (it runs as root): it runs on, said");
        });
        then(cancel, "not busy", () => !cancel.client.busy, () => {
            assert(Date.now() - cancel.cancelledAt < 1000, "cancel: not busy within a second (" + (Date.now() - cancel.cancelledAt) + " ms) though the root login still runs");
            assertEqual(cancel.client.operation + "|" + cancel.client.authUrl, "|", "… operation and the login URL cleared");
            assert(cancel.client.connect("user"), "… connect works again (a new login starts)");
            assertEqual(cancel.client.operation, "login", "… busy with the new one");
            cancel.client.cancelLogin();
            assert(!cancel.client.busy, "… cancelled at once too (a plain login: ended)");
        });
        thenShellUntil(cancel, "the root login ended by itself", processesScript("tailscale login"), "loginsLeft", "0",
            left => assertEqual(left, "0", "the root login (pkexec, timeout, the login) ended by itself"));
        thenLogs(cancel, "after the old root login ended", () => {
            assertEqual(cancel.failures.length, 0, "the late exit (a failed login) changes nothing: no failure shown");
            assertEqual(cancel.client.operation + "|" + cancel.client.authUrl, "|", "… not busy, no URL");
            assertEqual(count(cancel.pkexecLines, elevatedLine(60, "login")), 1, "… pkexec ran once: timeout around the login, so it ends by itself");
        });

        // Cancelled while the run as administrator still asks for the password (the stand-in
        // pkexec "ask": nothing printed, nothing run): nothing runs as root, so the login was
        // simply cancelled — never "runs on as administrator"
        const cancelAsking = scenario("login-cancel-asking", { state: "needs-login", env: { TS_FAKE_PKEXEC: "ask" } });
        then(cancelAsking, "read", () => cancelAsking.client.status !== null, () => assert(cancelAsking.client.attend(), "attend: the login starts"));
        thenShellUntil(cancelAsking, "the run as administrator asks", "grep -c '^pkexec' \"$1/pkexec.log\"", "asking", "1", () => {
            assert(cancelAsking.client.loggingIn && cancelAsking.client._opPrivileged !== null, "the plain login refused: the run as administrator started");
            assert(!cancelAsking.client._loginElevated, "… nothing printed yet: not taken as running as root");
            cancelAsking.client.cancelLogin();
            assertEqual(cancelAsking.client.loginNote, "Login cancelled.", "cancelled while it asks: \"Login cancelled.\"");
            assert(!cancelAsking.client.busy, "… not busy");
        });
        thenShellUntil(cancelAsking, "the asking pkexec ended", processesScript("stand-in/pkexec|^sleep 30 $"), "askingLeft", "0",
            left => assertEqual(left, "0", "… the cancel ended the asking pkexec (and its wait)"));
        then(cancelAsking, "no failure", () => !cancelAsking.client.busy, () => {
            assertEqual(cancelAsking.failures.length, 0, "… and no failure notified");
            same(whats(cancelAsking), ["Log in"], "… one run as administrator, \"Log in\"");
        });

        // The shell answers "cancelled" for the login's run as administrator while the client
        // still waits for it (a cancel the client did not make itself): the login ends, not
        // busy, nothing said — never a login left waiting until its time limit
        const cancelledAnswer = scenario("login-cancelled-answer", { state: "needs-login", env: { TS_FAKE_PKEXEC: "ask" } });
        then(cancelledAnswer, "read", () => cancelledAnswer.client.status !== null, () => assert(cancelledAnswer.client.attend(), "attend: the login starts"));
        thenShellUntil(cancelledAnswer, "its run as administrator asks", "grep -c '^pkexec' \"$1/pkexec.log\"", "asking", "1", () => {
            assert(cancelledAnswer.client._opPrivileged !== null, "the run as administrator started");
            cancelledAnswer.client._opPrivileged.cancel();
        });
        then(cancelledAnswer, "the login ended", () => !cancelledAnswer.client.busy, () => {
            assertEqual(cancelledAnswer.client.operation + "|" + cancelledAnswer.client.loginNote, "|", "answered cancelled: the login ends, nothing said");
            assert(!cancelledAnswer.client._loginTimer.running, "… its time limit stopped");
            assertEqual(cancelledAnswer.failures.length, 0, "… no failure");
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
        // The ended processes go (waited for: on a loaded machine that takes a moment); a step's
        // time without that is the failure
        thenShellUntil(slowUp, "the pending `up` ended",
            processesScript("tailscale up|sleep 30"),
            "upLeft", "0", left => assertEqual(left, "0", "the plain `up` process (and its wait) ended, not left behind"));
        thenLogs(slowUp, "after the pending connect", () => {
            assertEqual(count(slowUp.logLines, /^up$/), 1, "bare `up` once");
            assertEqual(count(slowUp.logLines, /^down$/), 1, "… then `down` (the daemon would keep trying)");
            assertEqual(slowUp.client.opened, 1, "… the URL opened once (the user's connect)");
        });

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
            assertEqual(upTimeout.failures[0].reason, "Still connecting after 2 s. Disconnect to stop.",
                   "after its time limit: failed, saying the daemon keeps trying: " + upTimeout.failures[0].reason);
            assertEqual(upTimeout.client.authUrl, "", "… the URL cleared");
        });

        // ---- `up` that waits in vain while the daemon's health says why (it cannot make its
        // network device: a kernel updated without a reboot): the entry shows the daemon's words ----
        // No event stream here (no curl): the stand-in's bus replay would overwrite the health
        // injected below at a moment of its own; the slow poll reads instead
        const deviceGone = scenario("up-timeout-health", { state: "stopped", without: "curl", timeLimits: { up: 6 }, env: { TS_FAKE_OPERATOR: "1", TS_FAKE_UP_DELAY: "30" } });
        then(deviceGone, "read", () => deviceGone.client.status !== null, () => assert(deviceGone.client.connect("user"), "connect starts"));
        then(deviceGone, "the daemon trying", () => deviceGone.client.view.phase === "starting", () => {
            deviceGone.client._onBusMessage({ Health: { Warnings: {
                "update-available": { Severity: "low", Title: "Update available", Text: "An update is available.", ImpactsConnectivity: false },
                "network-device": { Severity: "high", Title: "No network device", Text: "Tailscale could not create its network device.", ImpactsConnectivity: true }
            } } });
        }, () => deviceGone.client._scheduleRead(true));
        then(deviceGone, "the connect given up", () => deviceGone.failures.length > 0 && !deviceGone.client.busy, () => {
            assertEqual(deviceGone.client.failureText, "Tailscale could not create its network device.",
                        "the daemon's own health message (the one that cuts the connection), not only \"still connecting\"");
            assertEqual(_entry(deviceGone).attention, null, "… no attention: Disconnect stays the button");
        });
        then(deviceGone, "shown once read", () => !deviceGone.client._reading && deviceGone.client.failure?.settling === false, () => {
            assert(_entry(deviceGone).status.startsWith("Tailscale could not create its network device."), "… on the entry's status line, still there after the read: " + _entry(deviceGone).status);
        });

        // ---- the service started, and gone again at once: said, not back to "Start" in silence ----
        const crashes = scenario("start-then-gone", { state: "running", daemonDown: true, env: { TS_FAKE_DAEMON: "down" } });
        then(crashes, "read", () => crashes.client.daemon === "not-running", () => assert(crashes.client.attend(), "Start"));
        then(crashes, "gone again", () => crashes.client.failureText !== "" && !crashes.client.busy, () => {
            assertEqual(_entry(crashes).status, "Tailscale stopped right after starting.", "said on the status line");
            assertEqual(_entry(crashes).attention?.action, "Start", "… the state's own \"Start\" stays");
        });

        // ---- the daemon down, read again and again: one log line, not one per read ----
        const quiet = scenario("log-once", { state: "running", daemonDown: true, recheckMinMs: 200, pollMs: 200 });
        then(quiet, "several failed reads", () => quiet.client.reads >= 5, () => {
            assertEqual(quiet.client.logCounts["status --json"], 1, quiet.client.reads + " failed reads: one log line");
            assert((quiet.client.logCounts["the event stream"] ?? 0) <= 1, "… the stream's failed restarts: at most one");
        });
        thenShell(quiet, "started elsewhere", "rm -f \"$1/state/daemon-down\" && echo ok", "quietStarted", () => {});
        then(quiet, "answers again", () => _entry(quiet).state === "activated", () => {
            assertEqual(quiet.client.logCounts["status --json"], 2, "the recovery: one more line");
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
        then(hung, "the click answered", () => hung.client.failureText !== "", () => {
            assertEqual(_entry(hung).status, "Tailscale did not answer within 1 s.", "the click while unknown: its read did not answer, said on the status line");
            assertEqual(_entry(hung).attention, null, "… no attention");
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
        then(noCurl, "the slow poll read instead", () => noCurl.client.reads > noCurl.readsBefore, () => {
            assertEqual(noCurl.client.streamStarts, 0, "no stream started (nothing that cannot start, restarted): the slow poll reads instead");
        });

        // ---- a tailscale this user could replace (the shell's verdict): nothing runs ----
        const untrusted = scenario("untrusted", { state: "running", untrusted: "tailscale" });
        then(untrusted, "judged", () => untrusted.client.cli !== "unknown", () => {
            assertEqual(untrusted.client.cli, "untrusted", "a tailscale the shell judged untrusted is not run");
            assertEqual(untrusted.client.tailscalePath, "", "… its path not taken");
            assertEqual(_entry(untrusted).status, "Not trusted", "the entry: \"Not trusted\"");
            assert(/isn't trusted/.test(_entry(untrusted).attention?.reason ?? ""), "… with the reason: " + _entry(untrusted).attention?.reason);
            assertEqual(_entry(untrusted).attention?.action, "Check again", "… its action looks again");
            assert(untrusted.client.connect("user"), "… Connect only looks at the programs again: nothing runs");
            assert(untrusted.client.ready, "… ready (nothing to read)");
        });
        waitMs(untrusted, 300);
        thenLogs(untrusted, "nothing ran", () => {
            assertEqual(untrusted.logLines.length, 0, "not trusted: nothing run at all");
            assertEqual(untrusted.pkexecLines.length, 0, "… nothing through pkexec");
            assertEqual(elevatedCalls(untrusted).length, 0, "… nothing asked of the shell as administrator");
            assert(untrusted.module.rechecks >= 1, "… Connect asked the shell to look the programs up again");
        });

        // ---- Tailscale installed while the shell runs: found without a restart ----
        // The shell's lookup finds the stand-ins only at the next recheckPrograms() after the
        // start, as a package installed meanwhile; the slow poll and the backoff kept out of the
        // way (an hour), so only what is under test can find it
        const install = s => then(s, "Tailscale installed meanwhile", () => true, () => {
            s.module.installed = s.module.programsIn({});
            assertEqual(s.client.cli, "missing", s.name + ": not found before the shell looks again");
        });
        // A view coming on screen (wake)
        const appears = scenario("cli-appears-wake", { state: "running", lateTools: true, pollMs: 3600000, recheckMinMs: 3600000 });
        then(appears, "not installed", () => appears.client.cli === "missing", () => {
            assert(appears.client.canLookAgain, "not installed: the page offers to look again");
            assert(appears.client._recheckTimer.running, "… and the backoff waits to look again");
        });
        install(appears);
        then(appears, "a view shown", () => true, () => assert(appears.client.wake(), "wake: looks, since something is missing"));
        then(appears, "found, read, streaming", () => appears.client.cli === "present" && _entry(appears).state === "activated" && appears.client.streamUp, () => {
            assertEqual(_entry(appears).attention, null, "found: no attention left");
            assert(!appears.client.canLookAgain && !appears.client._recheckTimer.running, "… nothing more to look for: the backoff stopped");
            assert(appears.client.devices.length > 0, "… the devices read");
            assert(!appears.client.wake(), "… a view shown now looks for nothing");
        });
        // The row's or the page's "Check again", on a daemon fresh from the package — then Connect
        // logs in (not the operator: through pkexec), the URL surfaces and opens once
        const checkAgain = scenario("cli-appears-check-again", { state: "fresh", lateTools: true, pollMs: 3600000, recheckMinMs: 3600000 });
        then(checkAgain, "not installed", () => checkAgain.client.cli === "missing", () => {});
        install(checkAgain);
        then(checkAgain, "Check again", () => true, () => {
            assertEqual(_entry(checkAgain).attention?.action, "Check again", "the entry's action: Check again");
            assert(checkAgain.client.attend(), "attend (the row's button): looks again");
        });
        then(checkAgain, "found: a fresh daemon", () => checkAgain.client.status !== null, () => {
            assertEqual(checkAgain.client.view.phase, "logged-out", "fresh NoState: logged out");
            assertEqual(_entry(checkAgain).attention?.action, "Log in", "… \"Log in\"");
            assert(checkAgain.client.connect("user"), "Connect (user): the login starts");
            assertEqual(checkAgain.client.operation, "login", "… busy logging in");
        });
        then(checkAgain, "the login URL surfaced", () => checkAgain.client.authUrl !== "", () => {});
        then(checkAgain, "connected", () => _entry(checkAgain).state === "activated" && !checkAgain.client.busy, () => {});
        thenLogs(checkAgain, "after the login", () => {
            assertEqual(count(checkAgain.logLines, /^login$/), 2, "bare `login`, denied, then as root");
            assertEqual(count(checkAgain.pkexecLines, elevatedLine(60, "login")), 1, "… through pkexec, the newly found tailscale by absolute path");
            same(elevatedCalls(checkAgain).map(call => call.argv), [[standIns + "/tailscale", "login"]], "… asked of the shell with that path");
            assertEqual(checkAgain.client.opened, 1, "the login page opened once");
        });
        // Nothing asked: the backoff finds it
        const backoff = scenario("cli-appears-backoff", { state: "running", lateTools: true, pollMs: 3600000, recheckMinMs: 300 });
        then(backoff, "not installed", () => backoff.client.cli === "missing", () => {});
        install(backoff);
        then(backoff, "found by the backoff", () => backoff.client.cli === "present" && _entry(backoff).state === "activated", () => {
            assert(!backoff.client._recheckTimer.running, "found: the backoff stopped");
        });

        // ---- a fresh install: every Connect leads to the login, a prompt or a message ----
        // NeedsLogin with no profile, not the operator: the attention's "Log in", no agent
        // answering: said on the entry, with "Log in" again
        const freshNoAgent = scenario("fresh-needs-login-no-agent", { state: "fresh-needs-login", env: { TS_FAKE_PKEXEC: "no-agent" } });
        then(freshNoAgent, "read", () => freshNoAgent.client.status !== null, () => {
            assertEqual(freshNoAgent.client.view.phase, "logged-out", "fresh NeedsLogin: logged out");
            assertEqual(_entry(freshNoAgent).attention?.action, "Log in", "… \"Log in\" in place of Connect");
            assert(freshNoAgent.client.connect("user"), "Connect (user): the login starts");
        });
        then(freshNoAgent, "failed", () => freshNoAgent.client.failureText !== "" && !freshNoAgent.client.busy, () => {
            assertEqual(_entry(freshNoAgent).status, "Not allowed.", "refused (no agent): said on the status line");
            assertEqual(freshNoAgent.failures.length, 0, "… not notified by the module (the shell tells it)");
            assertEqual(_entry(freshNoAgent).attention?.action, "Log in", "… \"Log in\" again as its action");
            assertEqual(_entry(freshNoAgent).state, "", "… off");
        });
        // The prompt dismissed: the prompt was the answer; the entry back to "Log in", no failure
        const freshDismissed = scenario("fresh-dismissed", { state: "fresh", env: { TS_FAKE_PKEXEC: "dismiss" } });
        then(freshDismissed, "read", () => freshDismissed.client.status !== null, () => assert(freshDismissed.client.connect("user"), "Connect: the login starts"));
        then(freshDismissed, "answered", () => !freshDismissed.client.busy, () => {});
        waitMs(freshDismissed, 300);
        thenLogs(freshDismissed, "dismissed", () => {
            assertEqual(freshDismissed.failures.length, 0, "dismissed: no failure");
            assertEqual(freshDismissed.client.failureText, "", "… no failure text");
            assertEqual(_entry(freshDismissed).attention?.action, "Log in", "… \"Log in\" as before");
            assertEqual(count(freshDismissed.pkexecLines, elevatedLine(60, "login")), 1, "… pkexec was asked");
        });
        // Not the operator, and the shell cannot run anything as administrator (no trusted
        // pkexec or timeout): said on the entry, nothing asked
        const noPrivileges = scenario("connect-no-privileges", { state: "stopped" });
        then(noPrivileges, "read", () => noPrivileges.client.status !== null, () => {
            noPrivileges.module.privilegedUnavailableReason = "no pkexec found";
            noPrivileges.module.privilegedAvailable = false;
            assert(noPrivileges.client.warnings.some(warning => warning.kind === "no-elevation"
                                                     && warning.text === "Changes that need an administrator are not offered: no pkexec found."),
                   "the card says changes as administrator are not offered, and why");
            assert(noPrivileges.client.connect("user"), "Connect: the plain `up` runs");
        });
        then(noPrivileges, "refused", () => noPrivileges.client.failureText !== "" && !noPrivileges.client.busy, () => {
            assertEqual(_entry(noPrivileges).status, "Can't ask for the password.", "no way to run as administrator: why, on the status line");
            assertEqual(_entry(noPrivileges).attention, null, "… no attention: Connect stays");
            assertEqual(elevatedCalls(noPrivileges).length, 0, "… nothing asked of the shell");
        });
        thenLogs(noPrivileges, "nothing as root", () => assertEqual(noPrivileges.pkexecLines.length, 0, "nothing through pkexec"));
        // No timeout(1) among the module's programs: nothing changes for its commands — their
        // limits are the shell's runner's — and a run as administrator still has the shell's
        const noTimeout = scenario("connect-without-timeout", { state: "stopped", without: "timeout" });
        then(noTimeout, "read", () => noTimeout.client.status !== null, () => {
            same(noTimeout.client.warnings.map(warning => warning.kind).filter(kind => kind.indexOf("timeout") >= 0), [], "no warning: the runner keeps the limits");
            assert(noTimeout.client.connect("user"), "Connect: the plain `up` runs");
        });
        then(noTimeout, "connected", () => _entry(noTimeout).state === "activated" && !noTimeout.client.busy, () => {});
        thenLogs(noTimeout, "as root with the shell's limit", () => {
            assertEqual(count(noTimeout.logLines, /^up$/), 2, "bare `up` plainly, then as root");
            same(whats(noTimeout), ["Connect"], "… the run as administrator asked of the shell all the same");
        });
        // The service cannot be started (systemd refuses): said on the entry, "Start" again
        const startFails = scenario("start-refused", { state: "running", daemonDown: true, env: { TS_FAKE_SYSTEMCTL: "fail" } });
        then(startFails, "read", () => startFails.client.daemon === "not-running", () => {
            assert(startFails.client.canLookAgain, "service not running: the page offers to look again too");
            assert(startFails.client.attend(), "Start");
        });
        then(startFails, "refused", () => startFails.client.failureText !== "" && !startFails.client.busy, () => {
            assertEqual(_entry(startFails).status, "Not started.", "refused (or the prompt cancelled: they look alike): said neutrally");
            assertEqual(_entry(startFails).attention?.action, "Start", "… the state's own \"Start\" stays");
        });
        // Started outside the shell: "Check again" reads at once
        thenShell(startFails, "started elsewhere", "rm -f \"$1/state/daemon-down\" && echo ok", "startedElsewhere", () => {
            assert(startFails.client.recheck(), "Check again: reads now");
            assertEqual(startFails.client.failureText, "", "… the old failure cleared");
        });
        then(startFails, "running", () => startFails.client.daemon === "running" && _entry(startFails).state === "activated", () => {});
        // A click before the first read has answered: kept, done once the state is known, not
        // dropped. The stand-in holds the first `status` until the click has been made (the read's
        // limit above a step's budget: a slow machine fails the step, never drops the click)
        const beforeRead = scenario("connect-before-read", { state: "stopped", holdStatus: true, timeLimits: { read: 60 } });
        then(beforeRead, "the first read under way, held", () => beforeRead.client.cli === "present" && beforeRead.client._reading, () => {
            assertEqual(beforeRead.client.status, null, "the first read has not answered");
            assert(!beforeRead.client.connect("user"), "Connect while the state is unknown: nothing started yet");
            assertEqual(beforeRead.client._readIntent, "connect", "… the click kept for after the read");
            assertEqual(beforeRead.client.operation, "", "… no operation under way");
        });
        // The read's process is started; its call shows in the stand-in's log a moment later
        thenShellUntil(beforeRead, "the read reached the stand-in", "grep -c '^status --json$' \"$1/log\"", "statusCalls", "1",
            calls => assertEqual(calls, "1", "the read reached Tailscale, no answer yet"));
        thenLogs(beforeRead, "nothing run blind", () => {
            assertEqual(changesIn(beforeRead).length, 0, "no `up` before the read has answered");
            assertEqual(beforeRead.pkexecLines.length, 0, "… nothing through pkexec");
            assertEqual(beforeRead.client.status, null, "… the read still held");
        });
        thenShell(beforeRead, "the read let go", "rm -f \"$1/state/status-hold\" && echo ok", "released", () => {});
        then(beforeRead, "connected", () => _entry(beforeRead).state === "activated" && !beforeRead.client.busy, () => {
            assertEqual(beforeRead.client._readIntent, "", "the kept click used up");
            assertEqual(beforeRead.failures.length, 0, "… no failure");
        });
        thenLogs(beforeRead, "one connect", () => assertEqual(count(beforeRead.pkexecLines, elevatedLine(60, "up")), 1, "the click ran `up` once (through pkexec)"));

        // ---- the shell's command runner: what is started, with which limit; cancelled when stopped ----
        const runs = scenario("runner", { state: "running", recordRuns: true, env: { TS_FAKE_OPERATOR: "1" } });
        then(runs, "read and streaming", () => runs.client.streamUp && runs.client.status !== null && !runs.client._reading, () => {
            const status = runs.runs.find(run => run.argv[1] === "status");
            same(status ? [status.argv, status.timeoutMs, status.killAfterMs] : null, [[standIns + "/tailscale", "status", "--json"], 15000, 5000],
                 "status --json: tailscale by its path, the read's 15 s, KILL 5 s after TERM");
            const prefs = runs.runs.find(run => run.argv[1] === "debug" && run.argv[2] === "prefs");
            same(prefs ? [prefs.argv.length, prefs.timeoutMs] : null, [3, 15000], "debug prefs: the read's limit");
            const streams = runs.runs.filter(run => run.argv[0] === standIns + "/curl" && /watch-ipn-bus/.test(run.argv[4] ?? ""));
            same(streams.map(run => [run.timeoutMs, run.streamed, run.keepOutput]), [[0, true, false]], "the stream: one run, no limit, its lines as they come, nothing kept");
            assert(runs.client.events >= 1, "… its lines read (" + runs.client.events + " messages)");
            assert(runs.runs.every(run => run.environment?.TS_FAKE_STATE_DIR === runs.env.TS_FAKE_STATE_DIR), "every run with the client's environment");
            same(runs.runs.filter(run => /\/(tailscale|curl)$/.test(run.argv[0]) && !run.argv[0].startsWith(standIns + "/")).length, 0,
                 "tailscale and curl: the stand-ins, by absolute path");
            assert(runs.client.setShieldsUp(true), "a change: starts");
        });
        then(runs, "changed", () => runs.client.prefs?.shieldsUp === true && !runs.client.busy, () => {
            const change = runs.runs.find(run => run.argv[1] === "set");
            same(change ? [change.argv.slice(1), change.timeoutMs, change.result?.ok, change.result?.timedOut, change.result?.cancelled] : null,
                 [["set", "--shields-up=true"], 60000, true, false, false], "the change: a set, the change's 60 s; its result the runner's");
            runs.startsAtStop = runs.client.streamStarts;
            runs.readsAtStop = runs.client.reads;
            runs.client.running = false;
            assert(runs.runs.some(run => run.cancelled && run.argv[0] === standIns + "/curl"), "stopped: the stream is cancelled");
        });
        then(runs, "every run answered", () => runs.runs.every(run => run.answered === 1), () => {
            assert(runs.runs.filter(run => run.result?.cancelled).length >= 1, "… the stream's answer: cancelled");
            assertEqual(runs.client.streamStarts, runs.startsAtStop, "… and nothing came of it: no stream started again");
            assertEqual(runs.client.reads, runs.readsAtStop, "… no read");
            assert(!runs.client._streamRestart.running && !runs.client.streamUp, "… no restart waiting");
        });
        // A run past its limit: the runner ends it, its answer says so (timedOut)
        const overLimit = scenario("runner-limit", { state: "running", recordRuns: true, timeLimits: { read: 1 }, env: { TS_FAKE_STATUS_HANG: "8" } });
        then(overLimit, "the read timed out", () => overLimit.client.stale, () => {
            const status = overLimit.runs.find(run => run.argv[1] === "status" && run.answered === 1);
            same(status ? [status.timeoutMs, status.result.timedOut, status.result.ok] : null, [1000, true, false], "status --json: 1 s, ended by the runner, timedOut");
        });

        // An answer cut by the runner (a large tailnet's status): a failed read, said as such,
        // never parsed as a whole one
        const cut = scenario("runner-cut", { state: "running", recordRuns: true,
                                             fakeRun: argv => argv[1] === "status" ? { result: { ok: true, code: 0, stdout: "{\"Version\": \"1.10", truncated: true } } : null });
        then(cut, "the read failed", () => cut.client._statusFailing && !cut.client._reading, () => {
            const status = cut.runs.find(run => run.argv[1] === "status");
            assertEqual(status?.maxOutputBytes, TailscaleRules.maxAnswerChars, "status --json: cut only past the module's cap, not the runner's 1 MB");
            assert(cut.runs.filter(run => run.argv[0] === standIns + "/tailscale").every(run => run.maxOutputBytes === TailscaleRules.maxAnswerChars),
                   "… and so every tailscale run");
            same(cut.module.logged.filter(line => line.key === "status --json").map(line => line.level + ": " + line.text),
                 ["warn: status --json failed: The answer was too long."], "the cut answer: logged as too long, once (module.log)");
            assertEqual(cut.client.status, null, "… nothing of it taken");
        });

        // Answers that come after the client stopped (a run the runner refused, or could not
        // start, is answered later and is not cancelled): none of them acts
        const late = scenario("runner-late", { state: "running", recordRuns: true,
                                               fakeRun: argv => argv[1] === "version" || argv[1] === "ping" ? { hold: true } : null });
        then(late, "read", () => late.client.status !== null && !late.client._reading, () => {
            const device = late.client.devices.find(device => device.online);
            late.pinged = device.id;
            assert(late.client.runDiagnostics(), "diagnostics: start");
            assert(late.client.ping(device), "ping: starts");
        });
        then(late, "both held", () => late.runs.some(run => run.argv[1] === "version") && late.runs.some(run => run.argv[1] === "ping"), () => {
            late.client.running = false;
            late.runsAtStop = late.runs.length;
            late.runs.find(run => run.argv[1] === "version").deliver({ ok: true, code: 0, stdout: "{\"long\": \"1.104.4-t1\", \"short\": \"1.104.4\"}" });
            late.runs.find(run => run.argv[1] === "ping").deliver({ ok: true, code: 0, stdout: "pong from laptop (100.64.0.2) via 192.168.1.20:41641 in 4ms\n" });
        });
        // Delivered in place: whatever they would start or set is there already
        then(late, "nothing acted", () => true, () => {
            assertEqual(late.runs.length, late.runsAtStop, "the late diagnostics answer: no next step started");
            assert(!late.client.diagnostics.running && late.client.diagnostics.clientVersion === "", "… diagnostics stay stopped, nothing taken");
            same(late.client.pings, {}, "the late ping answer: no entry");
        });

        // ---- switched off: the stream process gone, nothing acts ----
        const off = scenario("off", { state: "running" });
        then(off, "streaming", () => off.client.streamUp && !off.client._reading, () => {
            off.client.running = false;
            off.readsAtOff = off.client.reads;
            off.startsAtOff = off.client.streamStarts;
        });
        // Its processes go (waited for), then a while with nothing new
        thenShellUntil(off, "processes gone",
            "grep -lzx \"TS_FAKE_STATE_DIR=$1/state\" /proc/[0-9]*/environ 2> /dev/null | grep -vx \"/proc/$$/environ\" | wc -l",
            "processes", "0", left => assertEqual(left, "0", "off: no process of its own left (the stream ended)"));
        waitMs(off, 1000);
        then(off, "nothing since", () => true, () => {
            assertEqual(off.client.reads, off.readsAtOff, "off: no read since");
            assertEqual(off.client.streamStarts, off.startsAtOff, "off: no stream started since");
            assert(!off.client.connect("user") && off.client.operation === "", "off: an action does nothing");
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
            same(whats(accounts), ["List accounts", "Switch account", "Remove an account", "Add an account"], "… each run said what for");
            same(elevatedCalls(accounts).map(call => call.timeoutMs), [15000, 60000, 60000, 60000], "… each under its own limit");
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
        // The way back comes with the first read after the cancel (the state decides, not what was
        // seen): "logged-out" may show a moment before it
        then(interrupted, "cancelled: logged out, on an empty profile, the next read done", () => !interrupted.client.busy && interrupted.client.view.phase === "logged-out"
                && interrupted.client.loginInterrupted !== null, () => {
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
        then(hostname, "renamed", () => !hostname.client.busy && hostname.client.device?.hostName === "box" && hostname.client.device?.statusName === "box", () => {
            assertEqual(hostname.client.device.customHostname, "box", "… set here (prefs)");
            assertEqual(hostname.client.device.dnsName, "box.example-tailnet.ts.net", "… its MagicDNS name follows");
            assert(hostname.client.setNickname("home"), "nickname: starts");
        });
        then(hostname, "nicknamed", () => !hostname.client.busy, () => assertEqual(hostname.failures.length, 0, "no failure"));
        thenLogs(hostname, "after renaming", () => {
            assertEqual(count(hostname.pkexecLines, elevatedLine(60, "set\\t--hostname=box")), 1, "rename: `set --hostname=box` through pkexec");
            assertEqual(count(hostname.pkexecLines, elevatedLine(60, "set\\t--nickname=home")), 1, "nickname: `set --nickname=home` through pkexec");
            assertEqual(count(hostname.logLines, /bad\.name/), 0, "the refused name never ran");
            same(whats(hostname), ["Rename this device", "Name the account"], "… the runs said what for, never the names");
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
        // The stand-in login has moved to the empty profile (its URL comes only after 8 s)
        thenShellUntil(early, "the login moved to the empty profile", "cat \"$1/state/scenario\"", "moved", "login-pending", () => {});
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
        then(refusedBefore, "dismissed", () => !refusedBefore.client.busy, () => refusedBefore.readsAtDismiss = refusedBefore.client.reads);
        then(refusedBefore, "read again: nothing moved", () => refusedBefore.client.reads > refusedBefore.readsAtDismiss && !refusedBefore.client._reading, () => {
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
        then(sameAccount, "logged in again", () => !sameAccount.client.busy && sameAccount.client.view.phase === "running" && sameAccount.client.device?.customHostname === ""
            // status read after the login too (a read in flight may pair the old status with the new prefs)
            && sameAccount.client.device?.statusName === "self", () => {
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

        // ---- step 3: offering routes and the exit node (through pkexec), approval, SSH ----
        const sharing = scenario("sharing", { state: "running", forwarding: "0 1" });
        then(sharing, "read", () => sharing.client.prefs !== null && sharing.client.status !== null, () => {
            assertEqual(sharing.client.sharing.offersAny, false, "nothing offered yet");
            assert(!sharing.client.addRoute("192.168.7.5/24"), "a route with host bits: refused before anything runs");
            assert(/Host bits/.test(sharing.failures[0]?.reason ?? ""), "… saying why: " + sharing.failures[0]?.reason);
            sharing.failures = [];
            assert(sharing.client.addRoute("192.168.7.0/24"), "offer 192.168.7.0/24: starts");
        });
        then(sharing, "route offered", () => !sharing.client.busy && sharing.client.sharing.routes.length === 1 && sharing.client.forwarding.readAt > 0, () => {
            same(sharing.client.sharing.routes.map(route => route.route + " " + route.state), ["192.168.7.0/24 pending"], "the route, waiting for an admin's approval");
            same([sharing.client.forwarding.ipv4, sharing.client.forwarding.ipv6], [false, true], "forwarding read from the system's facts after offering");
            assert(sharing.client.forwardingWarning !== null && /IPv4/.test(sharing.client.forwardingWarning.text), "… IPv4 off: the warning");
            assert(sharing.client.setAdvertiseExitNode(true), "offer the exit node: starts");
        });
        then(sharing, "exit node offered", () => !sharing.client.busy && sharing.client.sharing.exitNode.offered, () => {
            same(sharing.client.prefs.advertiseRoutes, ["192.168.7.0/24"], "the route kept (set --advertise-exit-node alone keeps the routes)");
            assertEqual(sharing.client.sharing.exitNode.state, "pending", "… the exit node waiting for approval");
            assert(!sharing.client.setExitNode({ argument: "peer4" }), "using an exit node while offering one: refused before it runs");
            assert(/Stop offering/.test(sharing.failures[0]?.reason ?? ""), "… saying why");
        });
        thenLogs(sharing, "what ran", () => {
            assertEqual(count(sharing.pkexecLines, elevatedLine(60, "set\\t--advertise-routes=192\\.168\\.7\\.0/24")), 1, "`set --advertise-routes=192.168.7.0/24` through pkexec");
            assertEqual(count(sharing.pkexecLines, elevatedLine(60, "set\\t--advertise-exit-node=true")), 1, "`set --advertise-exit-node=true` alone");
            assertEqual(count(sharing.logLines, /advertise-routes.*advertise-exit-node|advertise-exit-node.*advertise-routes/), 0, "never both flags in one command");
            assertEqual(count(sharing.logLines, /192\.168\.7\.5|exit-node=peer4/), 0, "the refused ones never ran");
            same(whats(sharing), ["Change offered routes", "Offer an exit node"], "… the runs said what for, never the routes");
        });

        // Approval and removal on the sharing fixtures (an exit node and three routes offered);
        // the operator, so no pkexec (beside the first scenario: the suite has 20 s)
        const routeApproval = scenario("sharing-approval", { state: "sharing", env: { TS_FAKE_OPERATOR: "1" } });
        then(routeApproval, "read", () => routeApproval.client.prefs !== null && routeApproval.client.status !== null, () => {
            same(routeApproval.client.sharing.routes.map(route => route.state), ["standby", "approved", "pending"], "the fixture's routes: standby, approved, pending");
        });
        thenShell(routeApproval, "an admin approves the IPv6 route", "printf '2001:db8:1::/48\\n' > \"$1/state/approved\"; echo ok", "approvedWritten", () => routeApproval.client.refresh());
        then(routeApproval, "approved", () => routeApproval.client.sharing.routes[2]?.state !== "pending", () => {
            assertEqual(routeApproval.client.sharing.exitNode.state, "pending", "the exit node still pending (not approved)");
            assert(routeApproval.client.removeRoute("10.20.0.0/16"), "remove a route: starts");
        });
        then(routeApproval, "route removed", () => !routeApproval.client.busy && routeApproval.client.sharing.routes.length === 2, () => {
            assert(routeApproval.client.sharing.exitNode.offered, "the exit node still offered (--advertise-routes alone keeps it)");
        });
        thenLogs(routeApproval, "what ran", () => {
            assertEqual(count(routeApproval.logLines, /^set --advertise-routes=192\.168\.50\.0\/24,2001:db8:1::\/48$/), 1, "the remaining routes, no /0");
        });

        // SSH and the peer relay
        const sshOn = scenario("sharing-ssh", { state: "running", env: { TS_FAKE_OPERATOR: "1" } });
        then(sshOn, "read", () => sshOn.client.prefs !== null && sshOn.client.status !== null, () => assert(sshOn.client.setSwitch("ssh", true), "turn on Tailscale SSH: starts"));
        then(sshOn, "SSH on", () => !sshOn.client.busy && sshOn.client.sshServer.on, () => assert(sshOn.client.setRelayServerPort("40000"), "a peer relay: starts"));
        then(sshOn, "relay on", () => !sshOn.client.busy && sshOn.client.sharing.relayServerPort === 40000, () => assertEqual(sshOn.failures.length, 0, "no failure"));
        thenLogs(sshOn, "what ran", () => {
            assertEqual(count(sshOn.logLines, /^set --ssh=true$/), 1, "`set --ssh=true`, no --accept-risk");
            assertEqual(count(sshOn.logLines, /^set --relay-server-port=40000$/), 1, "`set --relay-server-port=40000`");
        });

        // ---- step 3 review: route edits never built from stale or foreign prefs ----
        // Prefs not read (status hangs, so prefs never come): both edits refused, nothing run
        const unread = scenario("routes-unread", { state: "running", env: { TS_FAKE_STATUS_HANG: "8" } });
        then(unread, "tools found", () => unread.client.cli === "present", () => {
            assertEqual(unread.client.prefs, null, "prefs not read yet");
            assert(!unread.client.addRoute("192.168.7.0/24"), "add while prefs are unknown: refused");
            assert(!unread.client.removeRoute("192.168.7.0/24"), "remove while prefs are unknown: refused");
            assert(unread.failures.length === 2 && unread.failures.every(failure => /not read yet/.test(failure.reason)), "… saying why: " + JSON.stringify(unread.failures));
        });
        thenLogs(unread, "nothing sent", () => assertEqual(count(unread.logLines, /^set /), 0, "no `set` at all"));

        // Two adds in a row with no event stream (no curl): the second builds on the first
        const addAdd = scenario("routes-add-add", { state: "running", without: "curl", env: { TS_FAKE_OPERATOR: "1" } });
        then(addAdd, "read", () => addAdd.client.prefsCurrent, () => assert(addAdd.client.addRoute("192.168.7.0/24"), "add A: starts"));
        then(addAdd, "A sent", () => !addAdd.client.busy && (addAdd.client.prefs?.advertiseRoutes ?? []).includes("192.168.7.0/24"), () => {
            assert(addAdd.client.addRoute("192.168.8.0/24"), "add B at once (no read landed yet): starts");
        });
        then(addAdd, "B sent", () => !addAdd.client.busy && (addAdd.client.prefs?.advertiseRoutes ?? []).length === 2, () => {});
        thenLogs(addAdd, "both kept", () => {
            assertEqual(count(addAdd.logLines, /^set --advertise-routes=192\.168\.7\.0\/24,192\.168\.8\.0\/24$/), 1, "B's command holds A too");
            assertEqual(count(addAdd.logLines, /^set --advertise-routes=192\.168\.8\.0\/24$/), 0, "A never dropped");
        });

        // Right after switching accounts: refused until the new profile's prefs are read
        const switchAdd = scenario("routes-switch-add", { state: "running", env: { TS_FAKE_OPERATOR: "1" } });
        then(switchAdd, "read", () => switchAdd.client.prefsCurrent, () => assert(switchAdd.client.addRoute("192.168.7.0/24"), "a route on the first account"));
        then(switchAdd, "added", () => !switchAdd.client.busy && switchAdd.client.prefsCurrent, () => assert(switchAdd.client.switchAccount("c3d4"), "switch: starts"));
        then(switchAdd, "switched", () => !switchAdd.client.busy, () => {
            assert(!switchAdd.client.addRoute("10.9.0.0/16"), "add at once after the switch: refused (prefs not read again)");
            assert(/read again/.test(switchAdd.failures[0]?.reason ?? ""), "… saying why: " + switchAdd.failures[0]?.reason);
        });
        then(switchAdd, "new profile read", () => switchAdd.client.prefsCurrent && switchAdd.client.currentAccount.loginName === "user1@example.org", () => {
            same(switchAdd.client.prefs.advertiseRoutes, [], "the new profile offers nothing");
            assert(switchAdd.client.addRoute("10.9.0.0/16"), "add now: starts");
        });
        then(switchAdd, "added there", () => !switchAdd.client.busy && (switchAdd.client.prefs?.advertiseRoutes ?? []).length === 1, () => {});
        thenLogs(switchAdd, "no route carried over", () => assertEqual(count(switchAdd.logLines, /^set --advertise-routes=10\.9\.0\.0\/16$/), 1, "only its own route (the other account's not written into it)"));

        // Changed elsewhere between the click and the retry through pkexec (the stand-in's
        // on-deny hook): the retry is planned from prefs read again
        const meanwhile = scenario("routes-meanwhile", { state: "running" });
        thenShell(meanwhile, "a route added elsewhere when the plain try is denied",
            "printf '%s\\n' \"printf 'AdvertiseRoutes=10.9.0.0/16\\\\n' >> \\\"\\$1/prefs\\\"\" > \"$1/state/on-deny\"; echo ok", "hookWritten", () => {});
        then(meanwhile, "read", () => meanwhile.client.prefsCurrent, () => assert(meanwhile.client.addRoute("192.168.7.0/24"), "add: starts"));
        then(meanwhile, "added", () => !meanwhile.client.busy, () => assertEqual(meanwhile.failures.length, 0, "no failure"));
        thenLogs(meanwhile, "the retry kept the other route", () => {
            assertEqual(count(meanwhile.pkexecLines, elevatedLine(60, "set\\t--advertise-routes=10\\.9\\.0\\.0/16,192\\.168\\.7\\.0/24")), 1, "through pkexec: both routes");
        });
        const otherProfile = scenario("routes-profile-meanwhile", { state: "running" });
        thenShell(otherProfile, "the account switched elsewhere when the plain try is denied",
            "printf '%s\\n' \"printf 'c3d4\\\\n' > \\\"\\$1/current\\\"\" > \"$1/state/on-deny\"; echo ok", "hookWritten", () => {});
        then(otherProfile, "read", () => otherProfile.client.prefsCurrent, () => assert(otherProfile.client.addRoute("192.168.7.0/24"), "add: starts"));
        then(otherProfile, "aborted", () => !otherProfile.client.busy && otherProfile.failures.length > 0, () => {
            assert(/Changed meanwhile/.test(otherProfile.failures[0].reason), "the profile changed: \"Changed meanwhile, try again\": " + otherProfile.failures[0].reason);
        });
        thenLogs(otherProfile, "nothing written into the other profile", () => assertEqual(count(otherProfile.pkexecLines, /advertise-routes/), 0, "no pkexec `set`"));

        // ---- step 3: Tailscale's own refusals, shown as it says them ----
        const refusals = scenario("sharing-refusals", { state: "exit-node", env: { TS_FAKE_OPERATOR: "1", TS_FAKE_SSH_CAP: "0" } });
        then(refusals, "read", () => refusals.client.prefs !== null && refusals.client.status !== null, () => {
            assert(refusals.client.sharing.exitNode.problem !== "", "using an exit node: offering one is not possible, said on the section");
            assert(!refusals.client.setAdvertiseExitNode(true), "… refused before it runs");
            refusals.failures = [];
            assert(refusals.client.setSwitch("ssh", true), "SSH (the tailnet does not allow it, status does not say so): runs");
        });
        then(refusals, "SSH refused", () => !refusals.client.busy && refusals.failures.length > 0, () => {
            assertEqual(refusals.failures[0].reason, "Unable to enable local Tailscale SSH server; not enabled on Tailnet. See https://tailscale.com/s/ssh", "Tailscale's refusal, as it says it");
            assertEqual(refusals.client.sshServer.on, false, "… still off");
            assert(refusals.client.setSwitch("autoUpdate", true), "auto-update (not detected as Nix-managed here): runs");
        });
        then(refusals, "auto-update refused", () => !refusals.client.busy && refusals.failures.length > 1, () => {
            assertEqual(refusals.failures[1].reason, "Auto-updates are not supported on this platform.", "the daemon's refusal (NixOS) shown plainly");
            assertEqual(refusals.client.busy, false, "nothing left busy");
        });

        // ---- the coordinator's bug 1: a name set while disconnected ----
        const renameStopped = scenario("rename-stopped", { state: "stopped", env: { TS_FAKE_OPERATOR: "1" } });
        then(renameStopped, "read", () => renameStopped.client.prefs !== null && renameStopped.client.device !== null, () => {
            assert(renameStopped.client.setHostname("framework"), "rename while off: starts");
        });
        then(renameStopped, "renamed", () => !renameStopped.client.busy && renameStopped.client.device?.customHostname === "framework", () => {
            same([renameStopped.client.device.hostName, renameStopped.client.device.statusName, renameStopped.client.device.namePending, renameStopped.client.device.nameNote],
                 ["framework", "self", true, "the tailnet shows it after connecting"], "the new name shown; the tailnet still has the old one, said so");
            renameStopped.client.connect("user");
        });
        then(renameStopped, "connected", () => !renameStopped.client.busy && renameStopped.client.view.phase === "running" && renameStopped.client.device?.namePending === false, () => {
            same([renameStopped.client.device.hostName, renameStopped.client.device.statusName, renameStopped.client.device.dnsName],
                 ["framework", "framework", "framework.example-tailnet.ts.net"], "connected: the tailnet has it");
        });
        thenLogs(ipcOrigin, "no prompt", () => {
            assertEqual(ipcOrigin.pkexecLines.length, 0, "origin network: nothing through pkexec");
            assertEqual(count(ipcOrigin.logLines, /^switch c3d4$/), 1, "… the plain switch tried once");
        });

        _clock.start();
    }
}
