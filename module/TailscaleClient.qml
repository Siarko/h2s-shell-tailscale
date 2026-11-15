import QtQuick
import Quickshell
import Quickshell.Io
import qs.api

// The live side of the Tailscale module: I/O only — every decision is TailscaleRules'. One of
// these is made by the module's main (Main.qml) and lives exactly as long as it, so turning
// the module off (the module API's lifetime rule) ends its stream, its timers and anything it
// runs; the module's suites make their own, each with its own stand-in tools and state.
//
// STAYING CURRENT
//   - ONE long-running reader of tailscaled's event bus: `curl -sN --unix-socket <socket>
//     http://local-tailscaled.sock/localapi/v0/watch-ipn-bus?mask=<TailscaleRules.watchMask>`
//     (readable by any user; the socket the first of TailscaleRules.localApiSockets that
//     exists), split by TailscaleRules.jsonFeed and read by notifyDigest. A message's State,
//     BrowseToURL, LoginFinished, ErrMessage, Prefs and SuggestedExitNode are taken from it at
//     once; every message is also a TRIGGER to re-read `status --json` and `debug prefs` —
//     debounced (readDebounceMs) and coalesced: never more than one read in flight, a trigger
//     during a read gives one more read after it.
//   - The stream ends (daemon stopped or restarted): an immediate re-read (which finds "not
//     running" if so), and the stream is started again after a backoff (1 s, doubling to
//     streamBackoffMaxMs; back to 1 s after a stream that lived 10 s). curl not installed: no
//     stream at all (the entry says "live updates need curl"), the slow poll only.
//   - A slow poll (pollMs, 60 s) re-reads AT ALL TIMES — with the bus's current mask a peer
//     going offline may send no message (to be confirmed on the real machine) — and looks
//     for the CLI again while it is missing or not trusted.
//   - Resume from sleep: the module handle's resumed() (API 1.2) re-reads and restarts the
//     stream.
//   - Byte counters (devices' traffic) are in `status --json`: re-read every watchPollMs only
//     while something watches (the devices page while it is shown: watch() / unwatch()).
//
// TIME LIMITS: every command runs under coreutils' timeout (TailscaleRules.timed, the limits
// in TailscaleRules.timeLimits; a suite may shorten them with `timeLimits`), and the client
// also stops waiting for it a little after (a watchdog, for a timeout that was not found).
// A read that times out marks the state stale (the entry: "Not answering — state unknown")
// and is retried with a backoff (readRetryMinMs, doubling to readRetryMaxMs).
//
// THE TOOLS SEAM — the one place that decides which tailscale, timeout, curl, pkexec,
// systemctl and xdg-open run (`tool(name)`):
//   - `toolsDir` set by the owner (the suites): programs from there;
//   - else H2S_TAILSCALE_TOOLS in the shell's environment (an absolute directory): from there
//     (the module's lock-bed test);
//   - else, under the shell's module test runner (H2S_TEST_MODULES is set): the stand-ins next
//     to the module (../tools/stand-in) — a module test can never reach the real tailscale;
//     when they are not there nothing runs (the CLI counts as missing);
//   - else (inert): the names, found on PATH, by absolute path resolved once with `command -v`
//     (kept as found — on NixOS /run/current-system/sw/bin/tailscale, a link that survives
//     updates) — and CHECKED (TailscaleRules.toolsProbe): a tailscale, timeout or pkexec this
//     user could replace (not owned by root, not in the Nix store) is not trusted, and then
//     nothing runs; a link is opened with Api.openUrl.
// With the seam in use a link is opened by the seam's xdg-open (never Api.openUrl's).
//
// ACTIONS run one at a time (`busy`, `operation`): planned by TailscaleRules (planConnect,
// planDisconnect, planAttend, commandFor), run plainly by absolute path; when Tailscale
// answers "Access denied" and ONLY when the user asked (origin "user"), run again through
// the API's PrivilegedAction (pkexec, TailscaleRules.privileged: under timeout, so a root
// process ends by itself). Origin "network" never prompts and never opens a browser: it sets
// `attention` instead. pkexec 126 (dismissed) shows nothing; 127 is `failed` with the
// contract's sentence; any other failure is `failed(what, reason)` with the rules' sentence.
// A pending connect (a bare `up` waits for Running) shows a login URL from its output or the
// bus at once, and Disconnect ends it (stops waiting, ends the plain process, runs `down`).
// `tailscale login` runs as a process of its own (its URL is read while it waits); cancelled
// (cancelLogin) or after loginTimeoutMs the module STOPS WAITING at once — a login token: a
// late exit of the old process is ignored — and ends the plain process; one run through
// pkexec (root: it cannot be signalled) ends by itself, at its timeout.
QtObject {
    id: root

    // ---- Set by the owner ----

    // Acts only while true (Main binds it to module.active); false ends everything
    property bool running: false
    // The module's handle (its store, its settings, resumed()), or null (a suite's client)
    property var module: null
    // The tools seam (above): "" = decided at start from the environment
    property string toolsDir: ""
    // Judge the programs as on PATH even with a tools directory (the suites' trust test)
    property bool checkTrust: false
    // Added to every process's environment (the suites: the stand-ins' TS_FAKE_* variables)
    property var environment: ({})
    // The clock, for the suites (0: the real one)
    property real fixedNow: 0
    property int readDebounceMs: 150
    property int pollMs: 60000
    property int watchPollMs: 3000
    property int loginTimeoutMs: TailscaleRules.timeLimits.login * 1000
    property int streamBackoffMinMs: 1000
    property int streamBackoffMaxMs: 30000
    property int readRetryMinMs: 2000
    property int readRetryMaxMs: 60000
    // Overrides of TailscaleRules.timeLimits (seconds), for the suites
    property var timeLimits: ({})
    // Open the login page in the browser (setting mod.tailscale.openLoginInBrowser)
    readonly property bool openLoginInBrowser: module ? module.value("openLoginInBrowser") !== false : true

    // An operation failed: a one-off notification "<what> failed" with `reason` (Main
    // forwards it as the provider's failed(entryId, what, reason))
    signal failed(string what, string reason)

    // ---- Tools ----

    // "owner" | "seam" | "test-stand-ins" | "path" ("" before the start)
    property string toolsMode: ""
    property string _tools: ""
    // Absolute paths ("" unknown or missing)
    property string tailscalePath: ""
    property string timeoutPath: ""
    property string pkexecPath: ""
    property string curlPath: ""
    property string socketPath: TailscaleRules.localApiSocket
    // "unknown" | "present" | "missing" | "untrusted"
    property string cli: "unknown"
    property string untrustedReason: ""
    // curl was looked for and is not there: no stream, the slow poll only
    readonly property bool curlMissing: cli === "present" && curlPath === ""
    // Why nothing can be run as administrator here ("" it can)
    readonly property string elevationProblem: cli !== "present" ? ""
        : timeoutPath === "" ? "Changes that need an administrator are not offered: coreutils' timeout was not found, and a command run as administrator could not be stopped once started."
        : pkexecPath === "" ? "Changes that need an administrator are not offered: pkexec was not found." : ""

    function tool(name) {
        return _tools !== "" ? _tools + "/" + name : name;
    }

    function _limit(name) {
        const value = (timeLimits ?? {})[name];
        return typeof value === "number" && value >= 1 ? Math.round(value) : TailscaleRules.timeLimits[name];
    }

    // ---- State ----

    property var status: null
    property var prefs: null
    // "unknown" | "running" | "not-running"
    property string daemon: "unknown"
    property bool readDenied: false
    // The last read timed out: what was read before is not shown as the state
    property bool stale: false
    // "" | "connect" | "disconnect" | "login" | "logout" | "exit-node" | "setting" | "operator" | "start"
    property string operation: ""
    // The login URL the running login (or a pending connect) printed or the bus sent;
    // `busAuthUrl` one the bus sent while the module was not logging in (shown, never opened)
    property string authUrl: ""
    property string busAuthUrl: ""
    property real exitNodeOfflineSince: 0
    property real now: fixedNow > 0 ? fixedNow : Date.now()
    property string userName: ""
    property int uid: -1
    // The suggested exit node: an id from the bus, or a name from `exit-node suggest`
    property string suggestedId: ""
    property string suggestedName: ""
    property var lanSubnets: []
    property bool streamUp: false
    // A lasting condition found by an action (origin "network" needing the user, a denied
    // change): attention until the user acts or the phase changes
    property var pendingAttention: null
    // The last error the daemon sent on the bus (shown as a warning)
    property string busError: ""
    property string _lastTailnet: ""

    // Counters, for the tests and the IPC state
    property int reads: 0
    property int streamStarts: 0
    property int events: 0
    property int opened: 0
    property int readTimeouts: 0

    // The entries have been read successfully at least once (or there is nothing to read)
    readonly property bool ready: status !== null || stale || cli === "missing" || cli === "untrusted" || daemon === "not-running"
    readonly property bool busy: operation !== ""
    readonly property bool canChange: TailscaleRules.canChange(prefs, { userName: userName, uid: uid })
    // Only what the entry's name uses (never an e-mail address: TailscaleRules.entryTailnet)
    readonly property string lastTailnet: {
        const remembered = _lastTailnet !== "" ? _lastTailnet : String(module?.store?.get("lastTailnet", "") ?? "");
        return TailscaleRules.isEmailLike(remembered) ? "" : remembered;
    }
    readonly property bool updateManagedBySystem: tailscalePath.startsWith("/run/current-system/") || tailscalePath.startsWith("/nix/store/")
        || tailscalePath.startsWith("/etc/profiles/") || tailscalePath.indexOf("/.nix-profile/") >= 0

    readonly property var facts: ({
        cli: cli === "missing" ? "missing" : cli === "untrusted" ? "untrusted" : "present",
        untrustedReason: untrustedReason,
        daemon: daemon === "not-running" ? "not-running" : "running",
        readDenied: readDenied,
        stale: stale,
        operation: ["connect", "disconnect", "login", "logout"].includes(operation) ? operation : "",
        authUrl: authUrl,
        exitNodeOfflineSince: exitNodeOfflineSince,
        updateManagedBySystem: updateManagedBySystem,
        now: now,
        lastTailnet: lastTailnet,
        interfaceName: ""
    })
    readonly property var view: TailscaleRules.stateOf(status, prefs, facts)

    // What the entry's status line says while an operation the rules do not know runs
    readonly property var _operationLabels: ({
        "exit-node": "Changing the exit node…", "setting": "Changing a setting…", "operator": "Making you the operator…",
        "start": "Starting the service…"
    })

    // THE provider entry (TailscaleRules.entry, with the attention an action found, the
    // operation's own status line, and curl's absence said once)
    readonly property var entry: {
        const base = TailscaleRules.entry(status, prefs, facts);
        const held = pendingAttention !== null && base.attention === null
            ? { reason: pendingAttention.reason, action: pendingAttention.action } : base.attention;
        const label = _operationLabels[operation] ?? "";
        let line = label !== "" ? label : base.status;
        if (curlMissing && operation === "" && view.phase !== "unknown")
            line = (line !== "" ? line + " · " : "") + "live updates need curl";
        return Object.assign({}, base, { attention: held, status: line.slice(0, 80), busy: operation !== "" });
    }
    // The view with that attention, for the plans
    readonly property var _planView: pendingAttention !== null && view.attention === null
        ? Object.assign({}, view, { attention: pendingAttention }) : view

    readonly property var devices: status ? TailscaleRules.peers(status, now, {}) : []
    readonly property var exitNodes: TailscaleRules.exitNodes(status, prefs, suggestedId !== "" ? suggestedId : suggestedName)
    readonly property var routeWarnings: status ? TailscaleRules.routeShadowsLan(status, lanSubnets, prefs) : []
    readonly property var warnings: view.warnings.concat(routeWarnings.map(found => ({ kind: "route-shadows-lan", text: found.text })),
        busError !== "" ? [{ kind: "error", text: "Tailscale said: " + busError }] : [],
        curlMissing ? [{ kind: "curl-missing", text: "Live updates need curl: without it Tailscale's state is re-read once a minute." }] : [],
        elevationProblem !== "" ? [{ kind: "no-elevation", text: elevationProblem }] : [],
        cli === "present" && timeoutPath === "" ? [{ kind: "no-timeout", text: "coreutils' timeout was not found: Tailscale's commands run without a time limit." }] : [])
    // This computer
    readonly property var self: status?.self ?? null
    readonly property var keyExpiry: TailscaleRules.keyExpiryWarning(self, now)

    // ---- Start and stop ----

    property int _generation: 0

    onRunningChanged: running ? _start() : _stop()
    Component.onCompleted: {
        if (running)
            _start();
    }
    Component.onDestruction: _stop()

    function _start() {
        _generation++;
        _tools = toolsDir;
        toolsMode = toolsDir !== "" ? "owner" : "";
        if (toolsDir === "") {
            const seam = Quickshell.env("H2S_TAILSCALE_TOOLS");
            if (typeof seam === "string" && seam.startsWith("/")) {
                _tools = seam.replace(/\/+$/, "");
                toolsMode = "seam";
            } else if (typeof Quickshell.env("H2S_TEST_MODULES") === "string" && Quickshell.env("H2S_TEST_MODULES") !== "") {
                _tools = String(Qt.resolvedUrl("../tools/stand-in")).replace(/^file:\/\//, "").replace(/\/+$/, "");
                toolsMode = "test-stand-ins";
            } else {
                toolsMode = "path";
            }
        }
        _resolveTools();
        _readIdentity();
        _readLan();
    }

    function _stop() {
        _generation++;
        _readTimer.stop();
        _readRetry.stop();
        _streamRestart.stop();
        _loginTimer.stop();
        if (_stream.running)
            _stream.running = false;
        _opToken++;
        _readToken++;
        // Everything it started: asked to end (a root process cannot be — it ends at its
        // timeout), and never waited for again
        for (const process of _processes)
            process.abandon();
        _processes = [];
        _opProcess = null;
        streamUp = false;
        operation = "";
        authUrl = "";
        _reading = false;
        _readAgain = false;
        _watchers = 0;
    }

    function _alive(generation) {
        return running && generation === _generation;
    }

    // tailscale, timeout, pkexec and curl by absolute path (the seam's, or PATH's — then
    // judged: TailscaleRules.toolsProbe), and the LocalAPI socket that exists
    function _resolveTools() {
        const generation = _generation;
        const judge = toolsMode === "path" || checkTrust;
        const probe = [
            "dir=$1; check=$2; shift 2",
            "for n in tailscale timeout pkexec curl; do",
            "  if [ -n \"$dir\" ]; then p=\"$dir/$n\"; { [ -f \"$p\" ] && [ -x \"$p\" ]; } || p=''; else p=$(command -v \"$n\" 2> /dev/null) || p=''; fi",
            "  case $p in /*) ;; *) p='' ;; esac",
            "  printf 'tool\\t%s\\t%s\\n' \"$n\" \"$p\"",
            "  if [ -n \"$p\" ] && [ \"$check\" = 1 ] && [ \"$n\" != curl ]; then",
            "    r=$(readlink -f -- \"$p\") && printf 'real\\t%s\\t%s\\n' \"$n\" \"$r\" && stat -L --printf \"stat\\t$n\\t%u\\t%a\\t%n\\n\" -- \"$(dirname -- \"$p\")\" \"$r\" \"$(dirname -- \"$r\")\"",
            "  fi",
            "done",
            "for s in \"$@\"; do [ -S \"$s\" ] && { printf 'socket\\t%s\\n' \"$s\"; break; }; done",
            "true"
        ].join("\n");
        _misc.run(["sh", "-c", probe, "sh", _tools, judge ? "1" : "0"].concat(TailscaleRules.localApiSockets), result => {
            if (!_alive(generation))
                return;
            const found = TailscaleRules.toolsProbe(result.lines.join("\n"), judge);
            const tools = found.tools;
            curlPath = tools.curl.path;
            socketPath = found.socket !== "" ? found.socket : TailscaleRules.localApiSocket;
            const untrusted = found.untrusted.filter(name => name !== "curl");
            if (untrusted.length > 0) {
                tailscalePath = "";
                timeoutPath = "";
                pkexecPath = "";
                untrustedReason = tools[untrusted[0]].reason;
                cli = "untrusted";
                return;
            }
            untrustedReason = "";
            timeoutPath = tools.timeout.path;
            pkexecPath = tools.pkexec.path;
            _admin.elevate = [pkexecPath !== "" ? pkexecPath : "pkexec"];
            _adminSpare.elevate = _admin.elevate;
            if (tools.tailscale.path === "") {
                tailscalePath = "";
                cli = "missing";
                return;
            }
            tailscalePath = tools.tailscale.path;
            cli = "present";
            _scheduleRead(true);
            _startStream();
        });
    }

    function _readIdentity() {
        const generation = _generation;
        _misc.run(["sh", "-c", "id -u; id -un"], result => {
            if (!_alive(generation) || !result.ok)
                return;
            uid = Number(result.lines[0] ?? -1);
            const name = (result.lines[1] ?? "").trim();
            userName = TailscaleRules.validUserName(name) ? name : "";
        });
    }

    // The local networks (for "an accepted route covers the LAN"): global addresses of every
    // interface but Tailscale's
    function _readLan() {
        const generation = _generation;
        _misc.run(["sh", "-c", "ip -o addr show scope global 2> /dev/null; true"], result => {
            if (!_alive(generation))
                return;
            const subnets = [];
            for (const line of result.lines) {
                const match = /^\d+:\s+(\S+)\s+inet6?\s+(\S+)/.exec(line);
                if (match && !match[1].startsWith("tailscale") && !subnets.includes(match[2]))
                    subnets.push(match[2]);
            }
            lanSubnets = subnets.slice(0, 32);
        });
    }

    // ---- Running a command (every one but the stream: a process of its own) ----

    property var _processes: []

    // `argv` as it runs (timed already); `limitMs` the watchdog (0 none): past it `done` gets
    // { timedOut: true, code: 124 } and the process is no longer waited for. done({ ok, code,
    // out, err, timedOut }) once; onChunk(text) with its output as it comes. → the process
    // (abandon() it to stop waiting)
    function _spawn(argv, limitMs, done, onChunk) {
        const process = _processComponent.createObject(root, {
            command: argv, environment: _environment(), limitMs: limitMs, done: done ?? null, onChunk: onChunk ?? null
        });
        _processes = _processes.concat([process]);
        process.running = true;
        return process;
    }

    function _forget(process) {
        _processes = _processes.filter(item => item !== process);
    }

    // A tailscale command (commandFor's) by absolute path, under timeout (its time limit:
    // `seconds`) → the argv
    function _timedArgv(command, seconds) {
        const timed = TailscaleRules.timed([tailscalePath].concat(command.argv.slice(1)), timeoutPath, seconds);
        return timed.ok ? timed.argv : [tailscalePath].concat(command.argv.slice(1));
    }

    // The watchdog: a little after timeout(1)'s own TERM and KILL
    function _watchdogMs(seconds) {
        return (seconds + TailscaleRules.timeLimits.killAfter + 5) * 1000;
    }

    // ---- Reading ----

    property bool _reading: false
    property bool _readAgain: false
    property int _readToken: 0
    property int _readFailures: 0

    // Asks for a re-read: one within readDebounceMs (`now` true: at once), never two at a time
    function _scheduleRead(immediately) {
        if (!running || cli !== "present")
            return;
        if (immediately === true) {
            _readTimer.stop();
            _read();
        } else if (!_readTimer.running) {
            _readTimer.start();
        }
    }

    function refresh() {
        if ((cli === "missing" || cli === "untrusted") && running)
            _resolveTools();
        else
            _scheduleRead(true);
    }

    function _read() {
        if (!running || cli !== "present")
            return;
        if (_reading) {
            _readAgain = true;
            return;
        }
        _reading = true;
        _readRetry.stop();
        reads++;
        const generation = _generation;
        const token = ++_readToken;
        const seconds = _limit("read");
        _spawn(_timedArgv(TailscaleRules.commandFor("status", {}), seconds), _watchdogMs(seconds), statusResult => {
            if (!_alive(generation) || token !== _readToken)
                return;
            if (_timedOut(statusResult)) {
                _readTimedOut();
                return;
            }
            _spawn(_timedArgv(TailscaleRules.commandFor("prefs", {}), seconds), _watchdogMs(seconds), prefsResult => {
                if (!_alive(generation) || token !== _readToken)
                    return;
                _applyRead(statusResult, _timedOut(prefsResult) ? { ok: false, code: 124, out: "", err: "" } : prefsResult);
                _reading = false;
                _readFailures = 0;
                stale = false;
                if (_readAgain) {
                    _readAgain = false;
                    _scheduleRead();
                }
            });
        });
    }

    function _timedOut(result) {
        return result.timedOut === true || TailscaleRules.errorKind(result.code, result.err).kind === "timeout" && (result.code === 124 || result.code === 137);
    }

    // A read that did not answer in time: the state is unknown (stale), retried with a backoff
    function _readTimedOut() {
        _reading = false;
        _readAgain = false;
        stale = true;
        readTimeouts++;
        _readRetry.interval = Math.min(readRetryMaxMs, readRetryMinMs * Math.pow(2, Math.min(_readFailures, 10)));
        _readFailures++;
        _readRetry.restart();
    }

    function _applyRead(statusResult, prefsResult) {
        if (fixedNow <= 0)
            now = Date.now();
        if (statusResult.ok) {
            const parsed = TailscaleRules.parseStatus(statusResult.out);
            if (parsed.ok) {
                status = parsed;
                daemon = "running";
                readDenied = false;
            }
        } else {
            const error = TailscaleRules.errorKind(statusResult.code, statusResult.err);
            if (error.kind === "not-running") {
                daemon = "not-running";
                status = null;
            } else if (error.kind === "denied") {
                readDenied = true;
            } else {
                console.warn("[tailscale] status --json failed:", error.message);
            }
        }
        if (prefsResult.ok) {
            const parsed = TailscaleRules.parsePrefs(prefsResult.out);
            if (parsed.ok)
                prefs = parsed;
        } else if (daemon === "not-running") {
            prefs = null;
        }
        _followExitNode();
        _rememberTailnet();
    }

    // When the exit node in use went offline (the grace before attention counts from there)
    function _followExitNode() {
        const current = TailscaleRules.currentExitNode(status, prefs);
        if (current && status?.backendState === "Running" && !current.online) {
            if (exitNodeOfflineSince <= 0)
                exitNodeOfflineSince = now;
        } else {
            exitNodeOfflineSince = 0;
        }
    }

    // Remembers only what the entry's name shows (a named tailnet; never an e-mail address,
    // and an old e-mail address in the store is cleared)
    function _rememberTailnet() {
        // Only while a tailnet is current (logged out: the remembered name stays)
        if (status === null || !status.tailnet?.name)
            return;
        const name = TailscaleRules.entryTailnet(status, {});
        const stored = String(module?.store?.get("lastTailnet", "") ?? "");
        if (name !== _lastTailnet)
            _lastTailnet = name;
        if (stored !== name)
            module?.store?.set("lastTailnet", name);
    }

    function _environment() {
        return Object.assign({}, environment ?? {});
    }

    // ---- The event stream ----

    property var _splitter: TailscaleRules.jsonSplitter()
    property real _streamStartedAt: 0
    property int _streamFailures: 0

    function _startStream() {
        if (!running || cli !== "present" || _stream.running || curlPath === "")
            return;
        _splitter = TailscaleRules.jsonSplitter();
        _stream.command = [curlPath, "-sN", "--unix-socket", socketPath,
            "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus?mask=" + TailscaleRules.watchMask];
        _stream.environment = _environment();
        _streamStartedAt = Date.now();
        streamStarts++;
        _stream.running = true;
    }

    function _streamEnded() {
        streamUp = false;
        if (!running)
            return;
        if (Date.now() - _streamStartedAt >= 10000)
            _streamFailures = 0;
        _streamRestart.interval = Math.min(streamBackoffMaxMs, streamBackoffMinMs * Math.pow(2, Math.min(_streamFailures, 10)));
        _streamFailures++;
        _streamRestart.restart();
        // The daemon may be gone: read now (a read finds "not running")
        _scheduleRead(true);
    }

    function _onBusText(text) {
        const fed = TailscaleRules.jsonFeed(_splitter, text);
        _splitter = fed.state;
        for (const object of fed.objects)
            _onBusMessage(object);
    }

    function _onBusMessage(object) {
        events++;
        streamUp = true;
        const digest = TailscaleRules.notifyDigest(object);
        if (!digest.ok)
            return;
        if (digest.state !== "") {
            if (status !== null && status.backendState !== digest.state)
                status = Object.assign({}, status, { backendState: digest.state });
            if (daemon !== "running")
                daemon = "running";
        }
        if (digest.prefs !== null)
            prefs = digest.prefs;
        if (digest.browseToUrl !== "") {
            // A pending connect's login URL too: shown while `up` still waits
            if (operation === "login" || operation === "connect") {
                if (authUrl === "")
                    authUrl = digest.browseToUrl;
                _maybeOpenLogin();
            } else {
                busAuthUrl = digest.browseToUrl;
            }
        }
        if (digest.loginFinished) {
            busAuthUrl = "";
            busError = "";
        }
        if (digest.errMessage !== "")
            busError = digest.errMessage;
        if (digest.suggestedExitNode !== "")
            suggestedId = digest.suggestedExitNode;
        _scheduleRead();
    }

    // ---- Actions ----

    // The operation in flight: a token (a late answer of an abandoned one is ignored), its
    // plain process (ended when abandoned), who asked
    property int _opToken: 0
    property var _opProcess: null
    property string _opOrigin: ""
    property string _opText: ""

    property var _pendingPhase: ""
    onViewChanged: {
        if (pendingAttention !== null && view.phase !== _pendingPhase)
            pendingAttention = null;
    }

    function _hold(attention) {
        if (!attention)
            return;
        _pendingPhase = view.phase;
        pendingAttention = attention;
    }

    function _origin(origin) {
        return origin === "user" ? "user" : "network";
    }

    // The provider's three (origin as the contract's request.origin; attend is the user's)
    function connect(origin) {
        return _execute(TailscaleRules.planConnect(_planView, canChange, _origin(origin)), _origin(origin), "connect");
    }

    // While a connect is pending: it is no longer waited for (its plain process ended), and
    // `down` runs (TailscaleRules.planDisconnect, connecting)
    function disconnect(origin) {
        const connecting = operation === "connect";
        const plan = TailscaleRules.planDisconnect(_planView, canChange, _origin(origin), { connecting: connecting });
        if (connecting && running && (plan.kind === "run" || plan.kind === "needs-user"))
            _abandonOperation();
        return _execute(plan, _origin(origin), "disconnect");
    }

    function attend() {
        const kind = _planView.attention?.kind ?? "";
        const operationName = kind === "service-not-running" ? "start" : kind === "exit-node-offline" ? "exit-node"
            : (kind === "login" || kind === "key-expired") ? "login" : (view.phase === "running" ? "disconnect" : "connect");
        return _execute(TailscaleRules.planAttend(_planView, canChange, "user"), "user", operationName);
    }

    // `plan`: TailscaleRules' → true when something was started
    function _execute(plan, origin, operationName) {
        if (!running)
            return false;
        if (origin === "user")
            pendingAttention = null;
        if (plan.kind === "read") {
            _scheduleRead(true);
            return false;
        }
        if (plan.kind === "needs-user") {
            _hold(plan.attention);
            return false;
        }
        if (plan.kind === "open-url") {
            if (origin === "user")
                openUrl(plan.url);
            return origin === "user";
        }
        if (plan.kind !== "run" || plan.command === null)
            return false;
        if (busy)
            return false;
        if (plan.command.name === "login")
            return _startLogin(origin);
        if (plan.command.name === "startService")
            return _startService();
        return _runChange(plan.command, origin, operationName);
    }

    // A change by name (TailscaleRules.commandFor) — the page's and the chooser's: the user's
    function _userChange(name, args, operationName) {
        if (!running || busy)
            return false;
        pendingAttention = null;
        const command = TailscaleRules.commandFor(name, args ?? {});
        if (!command.ok) {
            failed("Changing Tailscale", command.error);
            return false;
        }
        return _runChange(command, "user", operationName);
    }

    function setExitNode(option) {
        if (option === null || option === undefined)
            return _userChange("exitNodeNone", {}, "exit-node");
        return _userChange("exitNode", { node: option.argument }, "exit-node");
    }

    // The suggested exit node (asked for first when none is known)
    function useSuggested() {
        if (exitNodes.suggested)
            return setExitNode(exitNodes.suggested);
        suggest(() => {
            if (exitNodes.suggested)
                setExitNode(exitNodes.suggested);
            else
                failed("Choosing the suggested exit node", "Tailscale has no exit node to suggest.");
        });
        return true;
    }

    function setAllowLan(on) {
        return _userChange("allowLan", { on: on === true }, "setting");
    }

    function setAcceptRoutes(on) {
        return _userChange("acceptRoutes", { on: on === true }, "setting");
    }

    function setAcceptDns(on) {
        return _userChange("acceptDns", { on: on === true }, "setting");
    }

    function setShieldsUp(on) {
        return _userChange("shieldsUp", { on: on === true }, "setting");
    }

    function logout() {
        return _userChange("logout", {}, "logout");
    }

    // pkexec `tailscale set --operator=<this user>`, the name checked by the rules
    function becomeOperator() {
        if (!TailscaleRules.validUserName(userName)) {
            failed("Making you Tailscale's operator", "This user's name could not be read.");
            return false;
        }
        return _userChange("operator", { user: userName }, "operator");
    }

    function startService() {
        if (!running || busy)
            return false;
        pendingAttention = null;
        return _startService();
    }

    // Stops waiting for the operation in flight: its token bumped (its late answer ignored),
    // its plain process ended (a root one cannot be: it ends at its timeout), busy cleared
    function _abandonOperation() {
        _opToken++;
        _loginTimer.stop();
        if (_opProcess !== null)
            _opProcess.abandon();
        _opProcess = null;
        operation = "";
        authUrl = "";
        _opText = "";
        _scheduleRead(true);
    }

    // The free PrivilegedAction (one may still wait for an abandoned root process: it queues)
    function _freeAdmin() {
        return _admin.busy && !_adminSpare.busy ? _adminSpare : _admin;
    }

    // Runs `command` (a tailscale command from the table) plainly, by absolute path, under its
    // time limit; denied and asked by the user: through pkexec; denied otherwise: attention
    function _runChange(command, origin, operationName) {
        if (tailscalePath === "") {
            failed(command.description, "Tailscale is not installed.");
            return false;
        }
        const seconds = _limit(command.timeLimit ?? "change");
        const generation = _generation;
        const token = ++_opToken;
        operation = operationName;
        _opOrigin = origin;
        _opText = "";
        _loginOpened = false;
        authUrl = "";
        const pendingConnect = command.name === "connect";
        _opProcess = _spawn(_timedArgv(command, seconds), _watchdogMs(seconds), result => {
            if (!_alive(generation) || token !== _opToken)
                return;
            _opProcess = null;
            if (result.ok) {
                _finish();
                return;
            }
            if (_timedOut(result)) {
                _finish();
                failed(command.description, TailscaleRules.timeoutMessage(command.name, seconds));
                return;
            }
            const error = TailscaleRules.errorKind(result.code, result.err);
            if (error.kind !== "denied") {
                _finish();
                failed(command.description, error.message);
                return;
            }
            if (origin !== "user") {
                _finish();
                _hold({ kind: "needs-privilege", reason: "Tailscale refused a change asked for by a network: it needs an administrator's password — or make this user Tailscale's operator",
                        action: operationName === "disconnect" ? "Disconnect" : "Connect" });
                return;
            }
            const elevated = TailscaleRules.privileged(command.argv, tailscalePath, { timeout: timeoutPath, seconds: seconds, description: command.description });
            if (!elevated.ok || elevationProblem !== "") {
                _finish();
                failed(command.description, elevationProblem !== "" ? elevationProblem : elevated.error);
                return;
            }
            _freeAdmin().run(elevated.argv.slice(1), elevated.prompt, answer => {
                if (!_alive(generation) || token !== _opToken)
                    return;
                _finish();
                if (answer.ok || answer.dismissed)
                    return;
                if (answer.refused)
                    failed(command.description, TailscaleRules.pkexecOutcome(127).message);
                else if (answer.notFound === true || answer.code < 0 || /\bnot found\b|No such file/i.test(answer.error ?? ""))
                    // PrivilegedAction could not run it at all (no pkexec, a path that is gone)
                    failed(command.description, "It could not be run as administrator: pkexec, timeout or tailscale was not found.");
                else if (answer.code === 124 || answer.code === 137)
                    failed(command.description, TailscaleRules.timeoutMessage(command.name, seconds));
                else
                    failed(command.description, TailscaleRules.errorKind(answer.code, answer.error).message);
            }, _environment());
        }, pendingConnect ? text => _onConnectText(text, token) : null);
        return true;
    }

    // A pending connect's output: a login URL shows (and opens, for the user's connect) while
    // `up` still waits
    function _onConnectText(text, token) {
        if (token !== _opToken || operation !== "connect")
            return;
        _opText = (_opText + text).slice(-65536);
        const parsed = TailscaleRules.parseLoginOutput(_opText);
        if (parsed.authUrl !== "" && authUrl === "") {
            authUrl = parsed.authUrl;
            _maybeOpenLogin();
        }
    }

    function _finish() {
        operation = "";
        authUrl = "";
        _scheduleRead(true);
    }

    // `systemctl start tailscaled.service` (systemd asks polkit itself: no pkexec)
    function _startService() {
        const command = TailscaleRules.commandFor("startService", {});
        const generation = _generation;
        const token = ++_opToken;
        const seconds = _limit("change");
        const timed = TailscaleRules.timed([tool("systemctl")].concat(command.argv.slice(1)), timeoutPath, seconds);
        operation = "start";
        _opProcess = _spawn(timed.ok ? timed.argv : [tool("systemctl")].concat(command.argv.slice(1)), _watchdogMs(seconds), result => {
            if (!_alive(generation) || token !== _opToken)
                return;
            _opProcess = null;
            operation = "";
            if (!result.ok) {
                failed(command.description, _timedOut(result) ? TailscaleRules.timeoutMessage("startService", seconds)
                    : ((result.err.split("\n")[0] ?? "").trim() || ("systemctl exited with status " + result.code + ".")));
                return;
            }
            daemon = "unknown";
            _streamFailures = 0;
            _streamRestart.stop();
            _scheduleRead(true);
            _startStream();
        });
        return true;
    }

    // Opens a link: the seam's xdg-open when the seam is in use, else Api.openUrl
    function openUrl(url) {
        const safe = TailscaleRules.safeUrl(url);
        if (safe === "")
            return false;
        opened++;
        if (_tools !== "")
            _misc.run([tool("xdg-open"), safe], () => {}, _environment());
        else
            Api.openUrl(safe);
        return true;
    }

    // `tailscale exit-node suggest` → suggestedName; then `done()`
    function suggest(done) {
        if (!running || cli !== "present") {
            done?.();
            return;
        }
        const generation = _generation;
        const seconds = _limit("read");
        _spawn(_timedArgv(TailscaleRules.commandFor("exitNodeSuggest", {}), seconds), _watchdogMs(seconds), result => {
            if (!_alive(generation))
                return;
            const parsed = TailscaleRules.parseExitNodeSuggest(result.out);
            if (parsed.name !== "")
                suggestedName = parsed.name;
            done?.();
        });
    }

    // ---- Logging in ----

    property string _loginText: ""
    property bool _loginElevated: false
    property bool _loginOpened: false
    readonly property bool loggingIn: operation === "login"
    // The login's time limit, in whole seconds (timeout(1)'s, also around the root one)
    readonly property int _loginSeconds: Math.max(1, Math.ceil(loginTimeoutMs / 1000))

    function _startLogin(origin) {
        if (origin !== "user" || tailscalePath === "")
            return false;
        const token = ++_opToken;
        operation = "login";
        _opOrigin = origin;
        authUrl = "";
        _loginText = "";
        _loginElevated = false;
        _loginOpened = false;
        _loginTimer.restart();
        _opProcess = _spawn(_timedArgv(TailscaleRules.commandFor("login", {}), _loginSeconds), _watchdogMs(_loginSeconds),
            result => _loginExited(token, result), text => _onLoginText(text, token));
        return true;
    }

    // Stops waiting for the login at once (a pending connect: Disconnect's way). The plain
    // login is ended; one through pkexec runs as root — it cannot be signalled from here and
    // ends by itself at its timeout; its late exit is ignored (the token)
    function cancelLogin() {
        if (operation === "connect") {
            disconnect("user");
            return;
        }
        if (operation !== "login")
            return;
        _abandonOperation();
    }

    function _maybeOpenLogin() {
        if ((operation === "login" || operation === "connect") && _opOrigin === "user" && !_loginOpened && authUrl !== "" && openLoginInBrowser) {
            _loginOpened = true;
            openUrl(authUrl);
        }
    }

    function _onLoginText(data, token) {
        if (token !== _opToken)
            return;
        _loginText = (_loginText + data).slice(-65536);
        const parsed = TailscaleRules.parseLoginOutput(_loginText);
        if (parsed.authUrl !== "" && authUrl === "") {
            authUrl = parsed.authUrl;
            _maybeOpenLogin();
        }
    }

    function _loginExited(token, result) {
        if (!running || token !== _opToken)
            return;
        _opProcess = null;
        const description = TailscaleRules.commandFor("login", {}).description;
        const code = result.code;
        if (code === 0 || TailscaleRules.parseLoginOutput(_loginText).success) {
            _loginDone();
            return;
        }
        if (_timedOut(result)) {
            _loginDone();
            failed(description, TailscaleRules.timeoutMessage("login", _loginSeconds));
            return;
        }
        if (!_loginElevated) {
            const error = TailscaleRules.errorKind(code, _loginText);
            if (error.kind === "denied") {
                const elevated = TailscaleRules.privileged(["tailscale", "login"], tailscalePath,
                    { timeout: timeoutPath, seconds: _loginSeconds, description: description });
                if (!elevated.ok || elevationProblem !== "") {
                    _loginDone();
                    failed(description, elevationProblem !== "" ? elevationProblem : elevated.error);
                    return;
                }
                // pkexec <timeout> -k 5 <seconds> <tailscale> login: ends by itself
                _loginElevated = true;
                _loginText = "";
                _opProcess = _spawn([pkexecPath].concat(elevated.argv.slice(1)), _watchdogMs(_loginSeconds),
                    answer => _loginExited(token, answer), text => _onLoginText(text, token));
                return;
            }
            _loginDone();
            failed(description, error.message);
            return;
        }
        const outcome = TailscaleRules.pkexecOutcome(code);
        _loginDone();
        if (outcome.outcome === "dismissed")
            return;
        failed(description, outcome.outcome === "no-agent" ? outcome.message : TailscaleRules.errorKind(code, _loginText).message);
    }

    function _loginDone() {
        _loginTimer.stop();
        operation = "";
        authUrl = "";
        _scheduleRead(true);
    }

    // ---- Watching (the devices page while shown) ----

    property int _watchers: 0
    readonly property bool watching: _watchers > 0

    function watch() {
        _watchers++;
        _scheduleRead();
    }

    function unwatch() {
        _watchers = Math.max(0, _watchers - 1);
    }

    // ---- Resume from sleep (module API 1.2: the handle's resumed()) ----

    function resumed() {
        if (!running)
            return;
        if (fixedNow <= 0)
            now = Date.now();
        _readLan();
        refresh();
        if (_stream.running)
            _stream.running = false;
        else
            _startStream();
    }

    property Connections _resume: Connections {
        target: root.module
        ignoreUnknownSignals: true
        function onResumed() {
            root.resumed();
        }
    }

    // ---- Processes and timers ----

    property CommandAction _misc: CommandAction {}
    property PrivilegedAction _admin: PrivilegedAction {
        // A failure is the provider's failed(), not PrivilegedAction's notification
        notifyFailures: false
    }
    property PrivilegedAction _adminSpare: PrivilegedAction {
        notifyFailures: false
    }

    // One command: its output collected, its exit answered once, a watchdog
    property Component _processComponent: Component {
        Process {
            id: process
            property var done: null
            property var onChunk: null
            property int limitMs: 0
            property int code: -1
            property var _out: []
            property string err: ""
            property bool _answered: false
            stdout: SplitParser {
                splitMarker: ""
                onRead: data => {
                    process._out.push(data);
                    process.onChunk?.(data);
                }
            }
            stderr: SplitParser {
                splitMarker: ""
                onRead: data => {
                    process.err = (process.err + data).slice(-65536);
                    process.onChunk?.(data);
                }
            }
            function _answer(result) {
                if (_answered)
                    return;
                _answered = true;
                const callback = done;
                done = null;
                onChunk = null;
                callback?.(result);
            }
            // No longer waited for: `done` is not called; the process is asked to end (a root
            // one cannot be: it ends at its timeout, and this object goes with it)
            function abandon() {
                _answered = true;
                done = null;
                onChunk = null;
                _watchdog.stop();
                if (running)
                    running = false;
                else
                    Qt.callLater(_end);
            }
            property bool _ended: false
            function _end() {
                if (_ended)
                    return;
                _ended = true;
                root._forget(process);
                process.destroy();
            }
            onExited: (exitCode, exitStatus) => {
                code = exitCode;
                _watchdog.stop();
                _answer({ ok: exitCode === 0, code: exitCode, out: _out.join(""), err: err.trim(), timedOut: false });
                Qt.callLater(_end);
            }
            onRunningChanged: {
                if (!running)
                    Qt.callLater(() => {
                        _answer({ ok: false, code: code, out: _out.join(""), err: err.trim(), timedOut: false });
                        _end();
                    });
            }
            property Timer _watchdog: Timer {
                interval: Math.max(1, process.limitMs)
                running: process.limitMs > 0
                onTriggered: {
                    const callback = process.done;
                    const result = { ok: false, code: 124, out: process._out.join(""), err: process.err.trim(), timedOut: true };
                    process.abandon();
                    callback?.(result);
                }
            }
        }
    }

    property Process _stream: Process {
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root._onBusText(line + "\n")
        }
        onRunningChanged: {
            if (!running)
                root._streamEnded();
        }
    }

    property Timer _readTimer: Timer {
        interval: root.readDebounceMs
        onTriggered: root._read()
    }

    // A read that timed out, tried again
    property Timer _readRetry: Timer {
        onTriggered: root._scheduleRead(true)
    }

    property Timer _streamRestart: Timer {
        onTriggered: root._startStream()
    }

    // The login given up: no longer waited for (the plain one ended; a root one ends at its
    // own timeout, set to the same time)
    property Timer _loginTimer: Timer {
        interval: root.loginTimeoutMs
        onTriggered: {
            if (root.operation !== "login")
                return;
            root._abandonOperation();
            root.failed(TailscaleRules.commandFor("login", {}).description, TailscaleRules.timeoutMessage("login", root.loginTimeoutMs / 1000));
        }
    }

    // The slow poll, at all times (and the CLI looked for again while missing or not trusted)
    property Timer _poll: Timer {
        interval: root.pollMs
        repeat: true
        running: root.running
        onTriggered: root.refresh()
    }

    // The traffic while the devices page is shown
    property Timer _watchPoll: Timer {
        interval: root.watchPollMs
        repeat: true
        running: root.running && root.watching && root.cli === "present"
        onTriggered: root._scheduleRead()
    }

    // The clock: `now`, every 5 s, for the grace of an offline exit node and "last seen"
    property Timer _clock: Timer {
        interval: 5000
        repeat: true
        running: root.running && root.fixedNow <= 0
        onTriggered: root.now = Date.now()
    }
}
