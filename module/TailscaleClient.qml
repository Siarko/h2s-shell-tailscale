import QtQuick
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
//   - LOOKING AGAIN (TailscaleRules.recheckPlan): Tailscale may be installed, started or
//     fixed while the shell runs. While the CLI is missing or not trusted, or the service is
//     not running, the client looks again on a backoff (recheckMinMs doubling up to pollMs,
//     restarted whenever one of the module's views comes on screen: wake()), and at once when
//     the user asks (recheck(): "Check again"). Found: the reads, the stream and every
//     sub-client start as at the start — no restart of the shell.
//   - Resume from sleep: the module handle's resumed() (API 1.2) re-reads and restarts the
//     stream.
//   - Byte counters (devices' traffic) are in `status --json`: re-read every watchPollMs only
//     while something watches (the devices page while it is shown: watch() / unwatch()).
//
// RUNNING: every command — the reads, the changes, the stream — goes through the shell's
// command runner (module API 1.8, `runner`), by its program's absolute path, with a time limit
// (TailscaleRules.runLimits, the limits in TailscaleRules.timeLimits; a suite may shorten them
// with `timeLimits`; the stream has none). A run the client stops waiting for (stopped, an
// operation given up) is cancelled, and its answer never reaches the code that started it.
// A read that times out marks the state stale (the entry: "Not answering — state unknown")
// and is retried with a backoff (readRetryMinMs, doubling to readRetryMaxMs).
//
// PROGRAMS — which tailscale, timeout, curl, systemctl and openssl run: the shell's lookup,
// the module handle's `programs` (module API 1.9: each by its absolute path, judged trusted or
// not; TailscaleRules.programsFound). A tailscale this user could change is not trusted, and
// then nothing runs. In module test mode the shell hands over the stand-ins of the manifest's
// testPrograms instead (tests/stand-in) — a module test never reaches the real tailscale. A
// suite's own client is given a scenario's handle (tests/ScenarioHandle.qml). Looking again
// (recheck(), wake(), the backoff) asks the shell to look the programs up again
// (recheckPrograms), and the LocalAPI socket is looked for each time. Links open through
// Api.openUrl (in module test mode it records them).
//
// ACTIONS run one at a time (`busy`, `operation`): planned by TailscaleRules (planConnect,
// planDisconnect, planAttend, commandFor), run plainly by absolute path; when Tailscale
// answers "Access denied" and ONLY when the user asked (origin "user"), run again as
// administrator: the handle's `privileged.start` (module API 1.11; TailscaleRules
// .privilegedRun: only a trusted tailscale, with the command's `what` for the shell's prompt
// and its time limit, which the shell's own timeout keeps inside pkexec). Origin "network"
// never prompts and never opens a browser: it sets `attention` instead. A dismissed prompt
// shows nothing; a refused run is told by the shell; any other failure is `failed(what,
// reason)` with the rules' sentence (TailscaleRules.privilegedOutcome).
// A failed connect, disconnect, login or start the user asked for also leaves its reason on
// the entry's status line (`failure`, TailscaleRules.failureText / failureAfter) — never as
// attention, so the shell's "VPN with a network" may still connect it — until the phase
// changes, a change goes through or a connect starts: the notification alone may never show
// (no notification daemon, no notify-send). A click on Connect while the state is unknown
// reads first and then tries once more, or says that Tailscale does not answer.
// A pending connect (a bare `up` waits for Running) shows a login URL from its output or the
// bus at once, and Disconnect ends it (stops waiting, ends the plain process, runs `down`).
// `tailscale login` runs as a process of its own (its URL is read while it waits; as
// administrator through privileged.start, its output streamed); cancelled (cancelLogin) or
// after loginTimeoutMs the module STOPS WAITING at once — a login token: a late exit of the old
// process is ignored — and ends the plain process or cancels the run as administrator (which
// ends pkexec while it asks; once it runs as root it ends at its time limit).
QtObject {
    id: root

    // ---- Set by the owner ----

    // Acts only while true (Main binds it to module.active); false ends everything
    property bool running: false
    // The module's handle (its store, its settings, resumed(), its programs, running as
    // administrator), or a suite's scenario handle (tests/ScenarioHandle.qml), or null
    property var module: null
    // The system's facts (module API 1.13; a suite may give its own): the user, the host name,
    // the home and download folders, IP forwarding
    property var system: Api.system
    // The networks this computer is on (module API 1.16, Api.localNetworks; a suite may give
    // its own): for "an accepted route covers the local network"
    property var localNetworks: Api.localNetworks
    // Added to every command's environment, and handed to the runs as administrator (the
    // suites: the stand-ins' TS_FAKE_* variables; module API 1.14 takes them in test mode only)
    property var environment: ({})
    // What runs the commands: the shell's command runner (module API 1.8) — its own, or one a
    // suite hands over to see what is started ({ start(argv, options), cancelAll() })
    property var runner: _ownRunner
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
    // The first wait before looking again while Tailscale is missing or stopped (doubling up
    // to pollMs)
    property int recheckMinMs: 5000
    // How long after the user's Start a service that is gone again counts as failing to start
    property int startWatchMs: 30000
    property real _startedAt: 0
    // Overrides of TailscaleRules.timeLimits (seconds), for the suites
    property var timeLimits: ({})
    // The system's host name, as the shell read it ("" unknown)
    readonly property string systemHostname: String(system?.hostName ?? "").slice(0, 253)
    // Open the login page in the browser (setting mod.tailscale.openLoginInBrowser)
    readonly property bool openLoginInBrowser: module ? module.value("openLoginInBrowser") !== false : true

    // An operation failed: a one-off notification "<what> failed" with `reason` (Main
    // forwards it as the provider's failed(entryId, what, reason))
    signal failed(string what, string reason)

    // ---- Programs ----

    // The handle's (above): { <name>: { path, trusted, reason } }, null while not looked up
    readonly property var programs: module?.programsReady === false ? null : (module?.programs ?? null)
    // Absolute paths, as last applied ("" unknown or missing)
    property string tailscalePath: ""
    // Only for Taildrop's save script: a limit for each file it fetches
    property string timeoutPath: ""
    property string curlPath: ""
    property string systemctlPath: ""
    property string opensslPath: ""
    property string socketPath: TailscaleRules.localApiSocket
    // "unknown" | "present" | "missing" | "untrusted"
    property string cli: "unknown"
    property string untrustedReason: ""
    // curl was looked for and is not there: no stream, the slow poll only
    readonly property bool curlMissing: cli === "present" && curlPath === ""
    // Running as administrator: the handle's (module API 1.11), null without one
    readonly property var privileged: module?.privileged ?? null
    // Why nothing can be run as administrator here ("" it can)
    readonly property string elevationProblem: TailscaleRules.elevationProblem(cli, privileged?.available === true,
        privileged ? String(privileged.unavailableReason ?? "") : "no way to run as administrator")

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
    // The moment the state is derived at: the last read's, moved on by the shell's minute clock
    // (module API 1.12, Api.minuteNow: "last seen", the key's expiry) and by the one-shot timer
    // that ends an offline exit node's grace; a suite's fixedNow instead
    readonly property real now: fixedNow > 0 ? fixedNow : Math.max(Api.minuteNow, _moment)
    property real _moment: Date.now()
    // Who runs the shell, as the shell read it ("" and -1 unknown)
    readonly property string userName: TailscaleRules.validUserName(String(system?.userName ?? "")) ? String(system.userName) : ""
    readonly property int uid: typeof system?.uid === "number" && Number.isInteger(system.uid) && system.uid >= 0 ? system.uid : -1
    // The suggested exit node: an id from the bus, or a name from `exit-node suggest`
    property string suggestedId: ""
    property string suggestedName: ""
    readonly property var lanSubnets: TailscaleRules.lanSubnets(localNetworks)
    property bool streamUp: false
    // A lasting condition found by an action (origin "network" needing the user, a denied
    // change): attention until the user acts or the phase changes
    property var pendingAttention: null
    // A failed click of the user's: { text, phase, settling } (TailscaleRules.failureAfter), or null
    property var failure: null
    // The last error the daemon sent on the bus (shown as a warning)
    property string busError: ""
    // The health warnings the bus sent last (titles and texts; null: none sent yet — status's
    // Health lines then)
    property var busHealth: null
    property string _lastTailnet: ""
    // Taildrop (step 4): sending and receiving files, on this client's runner and operation lock
    readonly property TaildropClient taildrop: TaildropClient {
        client: root
    }
    // Step 5: serve and Funnel, certificates, tailnet lock (status), an exit node per network
    readonly property ServeClient serve: ServeClient { client: root }
    readonly property CertClient cert: CertClient { client: root }
    readonly property LockClient tailnetLock: LockClient { client: root }
    readonly property NetworkExitClient networkExit: NetworkExitClient { client: root }

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
        "start": "Starting the service…", "accounts": "Reading the accounts…", "accounts-auto": "Reading the accounts…",
        "account": "Changing the account…", "sharing": "Changing what this computer offers…",
        "taildrop-save": "Saving received files…", "serve": "Changing what this computer shares…",
        "cert": "Getting a certificate…"
    })

    // THE provider entry (TailscaleRules.entry, with the attention an action found, the
    // operation's own status line, a failed click's reason, and curl's absence said once)
    // Which attention the entry shows, by kind ("" none): the state's, else tailnet lock's
    // (only while connected: attention on an entry that is down would replace its Connect),
    // else the one an action found
    readonly property var _shownAttention: {
        if (view.attention !== null)
            return view.attention;
        if (pendingAttention === null && view.phase === "running" && tailnetLock.attention !== null)
            return Object.assign({}, tailnetLock.attention, { lockedOut: true });
        return pendingAttention;
    }
    readonly property string attentionKind: _shownAttention?.kind ?? ""
    // A failed click's reason ("" none): the status line while nothing runs (TailscaleRules
    // .failureAfter)
    readonly property string failureText: failure?.text ?? ""
    readonly property var entry: {
        const base = TailscaleRules.entry(status, prefs, facts);
        const shown = _shownAttention;
        const label = _operationLabels[operation] ?? "";
        let line = label !== "" ? label : (failureText !== "" && operation === "" ? failureText : base.status);
        // Files waiting in Tailscale's inbox: a fact on the status line, never attention
        if (label === "" && taildrop.statusText !== "")
            line = (line !== "" ? line + " · " : "") + taildrop.statusText;
        if (curlMissing && operation === "" && view.phase !== "unknown")
            line = (line !== "" ? line + " · " : "") + "live updates need curl";
        return Object.assign({}, base, { attention: shown !== null ? { reason: shown.reason, action: shown.action } : null,
                                         status: line.slice(0, 80), busy: operation !== "" });
    }
    // The view with that attention, for the plans
    readonly property var _planView: pendingAttention !== null && view.attention === null
        ? Object.assign({}, view, { attention: pendingAttention }) : view

    readonly property var devices: status ? TailscaleRules.peers(status, now, {}) : []
    readonly property var exitNodes: TailscaleRules.exitNodes(status, prefs, suggestedId !== "" ? suggestedId : suggestedName)
    readonly property var routeWarnings: status ? TailscaleRules.routeShadowsLan(status, lanSubnets, prefs) : []
    readonly property var warnings: view.warnings.concat(routeWarnings.map(found => ({ kind: "route-shadows-lan", text: found.text })),
        busError !== "" ? [{ kind: "error", text: "Tailscale said: " + TailscaleRules.plainText(busError, 500) }] : [],
        curlMissing ? [{ kind: "curl-missing", text: "Live updates need curl: without it Tailscale's state is re-read once a minute." }] : [],
        elevationProblem !== "" ? [{ kind: "no-elevation", text: elevationProblem }] : [])
    // This computer
    readonly property var self: status?.self ?? null
    readonly property var keyExpiry: TailscaleRules.keyExpiryWarning(self, now)

    // ---- Start and stop ----

    onRunningChanged: running ? _start() : _stop()
    Component.onCompleted: {
        if (running)
            _start();
    }
    Component.onDestruction: _stop()

    function _start() {
        // A look of an earlier start is no longer waited for (its answer is dropped)
        _probing = false;
        _lookAgain = false;
        _resolveTools();
    }

    // How many times the client stopped: a run's answer is dropped when it changed since the
    // run started (_run)
    property int _stops: 0

    function _stop() {
        _stops++;
        loginInterrupted = null;
        _strandCheck = null;
        _loginFrom = null;
        loginNote = "";
        _readTimer.stop();
        _readRetry.stop();
        _streamRestart.stop();
        _loginTimer.stop();
        _recheckTimer.stop();
        _graceTimer.stop();
        // Its timer is stopped: an offline moment kept would leave the next start's grace
        // without one (_followExitNode starts it only for a new moment)
        exitNodeOfflineSince = 0;
        _recheckAttempts = 0;
        _probing = false;
        _startedAt = 0;
        _readIntent = "";
        failure = null;
        _streamRun = null;
        _opToken++;
        _readToken++;
        // Everything it started: cancelled (a root process cannot be ended — it ends at its
        // time limit), and its answer never comes back (_run)
        runner?.cancelAll();
        _opRun = null;
        for (const run of _privilegedRuns)
            run.cancel();
        _privilegedRuns = [];
        _opPrivileged = null;
        streamUp = false;
        operation = "";
        authUrl = "";
        _reading = false;
        _readAgain = false;
        _watchers = 0;
        diagnostics = Object.assign({}, diagnostics, { running: false });
        pings = ({});
    }

    // The programs as the handle has them now (TailscaleRules.programsFound), and the LocalAPI
    // socket that exists. `lookUp`: the shell is asked to look the programs up again first
    // (installed or changed since); its answer comes as a change of `programs`, which applies
    // them again
    function _resolveTools(lookUp) {
        if (lookUp === true && typeof module?.recheckPrograms === "function")
            module.recheckPrograms();
        // One look at a time (a view and the timer may ask together); one asked meanwhile
        // follows it
        if (_probing) {
            _lookAgain = true;
            return;
        }
        _probing = true;
        const probe = "for s in \"$@\"; do [ -S \"$s\" ] && { printf 'socket\\t%s\\n' \"$s\"; break; }; done; true";
        _run(["sh", "-c", probe, "sh"].concat(TailscaleRules.localApiSockets), _limitMs("read"), result => {
            _probing = false;
            let socket = "";
            for (const line of result.stdout.split("\n")) {
                const parts = String(line).split("\t");
                if (parts[0] === "socket" && parts.length === 2 && TailscaleRules.localApiSockets.includes(parts[1])) {
                    socket = parts[1];
                    break;
                }
            }
            socketPath = socket !== "" ? socket : TailscaleRules.localApiSocket;
            _applyPrograms();
            if (_lookAgain) {
                _lookAgain = false;
                _resolveTools();
            }
        });
    }
    property bool _lookAgain: false

    // A new answer of the shell's lookup (a recheck, the machine woke): applied again
    onProgramsChanged: {
        if (running)
            _resolveTools();
    }

    function _applyPrograms() {
        const found = TailscaleRules.programsFound(programs);
        curlPath = found.curl;
        timeoutPath = found.timeout;
        systemctlPath = found.systemctl;
        opensslPath = found.openssl;
        untrustedReason = found.untrustedReason;
        // Not looked up yet: the handle's answer starts it (onProgramsChanged)
        if (!found.known) {
            tailscalePath = "";
            cli = "unknown";
            return;
        }
        if (found.cli !== "present") {
            const wasPresent = cli === "present";
            tailscalePath = "";
            cli = found.cli;
            _logOutcome("looking for tailscale", false, found.cli === "untrusted" ? untrustedReason : "not installed");
            _readIntent = "";
            if (wasPresent)
                _stopStream();
            _followRecheck();
            return;
        }
        const again = cli === "present" && tailscalePath === found.tailscale;
        tailscalePath = found.tailscale;
        cli = "present";
        _logOutcome("looking for tailscale", true, "");
        if (!again)
            _streamFailures = 0;
        _scheduleRead(true);
        _startStream();
        _followRecheck();
    }

    // ---- Running a command (the shell's command runner) ----

    // `argv` by absolute path, under the time limit `limitMs` (TailscaleRules.runLimits; 0 none),
    // with this client's environment, its output cut at TailscaleRules.maxAnswerChars.
    // done(result) once with the runner's result ({ ok, code, stdout, stderr, timedOut,
    // failedToStart, truncated, error, … }) — a cut one with `ok` false (only part of the
    // answer; runError says "too-long") — never for a run that was cancelled, nor for one
    // started before the client stopped (its answer can still come after the stop: one the
    // runner had refused, or could not start): nobody waits for it any more.
    // `onOutput(text)`: each line of both streams, with its line break, as it comes. → the
    // runner's handle ({ running, cancel() })
    function _run(argv, limitMs, done, onOutput) {
        const limits = TailscaleRules.runLimits(limitMs);
        const stopsAtStart = _stops;
        return runner.start(argv, {
            timeoutMs: limits.ok ? limits.timeoutMs : TailscaleRules.timeLimits.read * 1000, killAfterMs: limits.killAfterMs,
            environment: Object.assign({}, environment ?? {}),
            maxOutputBytes: TailscaleRules.maxAnswerChars,
            onStdout: onOutput ?? null, onStderr: onOutput ?? null,
            done: result => {
                if (result.cancelled === true || _stops !== stopsAtStart)
                    return;
                done?.(result.truncated === true && result.ok === true ? Object.freeze(Object.assign({}, result, { ok: false })) : result);
            }
        });
    }

    // A tailscale command (commandFor's) by absolute path → the argv
    function _tailscaleArgv(command) {
        return TailscaleRules.commandLine(command.argv, tailscalePath);
    }

    // A time limit of TailscaleRules.timeLimits (or a suite's) in milliseconds
    function _limitMs(name) {
        return _limit(name) * 1000;
    }

    // ---- Reading ----

    // The last `status --json` failed (not answering, or an answer that could not be read):
    // read again on the look-again backoff
    property bool _statusFailing: false

    // ---- Logging: once per change of outcome (TailscaleRules.logLine, the handle's module.log) ----
    // Per thing logged (status, prefs, the stream, the look for the programs): whether the last
    // line written was a failure; and how many lines each wrote (for the suites). The shell's
    // module.log (module API 1.12) writes a line only when it differs from the last one written
    // under the same key, the thing's name
    property var _logFailing: ({})
    property var logCounts: ({})
    function _logOutcome(what, ok, reason) {
        const line = TailscaleRules.logLine(what, ok, Api.address.redact(String(reason ?? "")), _logFailing[what] === true);
        if (line === null || typeof module?.log !== "function")
            return;
        if (module.log(line.level, line.text, what) !== true)
            return;
        _logFailing[what] = line.level !== "info";
        logCounts[what] = (logCounts[what] ?? 0) + 1;
    }

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
        if (cli !== "present" && running)
            _resolveTools(true);
        else
            _scheduleRead(true);
    }

    // ---- Looking again (TailscaleRules.recheckPlan) ----

    // Something is missing that may turn up by itself (installed, started): the page offers
    // "Check again"
    readonly property bool canLookAgain: running && cli !== "unknown" && TailscaleRules.recheckPlan({ cli: cli, daemon: daemon, phase: view.phase, readFailing: _statusFailing }, false) !== "none"
    property bool _probing: false
    property real _wokenAt: 0
    property int _recheckAttempts: 0

    // The user's "Check again": looks at once, whatever the state → true when it looked
    function recheck() {
        if (!running)
            return false;
        failure = null;
        pendingAttention = null;
        _recheckAttempts = 0;
        return _recheck(true);
    }

    // One of the module's views came on screen (the page, the popup, the network popup's
    // row, the card): looks again only while something is missing, at most every 2 s, and
    // starts the backoff over (the user may be installing or starting it now)
    function wake() {
        if (!running)
            return false;
        const moment = Date.now();
        if (moment - _wokenAt < 2000)
            return false;
        _wokenAt = moment;
        _recheckAttempts = 0;
        const looked = _recheck(false);
        _followRecheck();
        return looked;
    }

    function _recheck(asked) {
        const plan = TailscaleRules.recheckPlan({ cli: cli, daemon: daemon, phase: view.phase, readFailing: _statusFailing }, asked);
        if (plan === "probe") {
            _resolveTools(true);
            return true;
        }
        if (plan === "read") {
            _streamFailures = 0;
            if (_streamRun === null) {
                _streamRestart.stop();
                _startStream();
            }
            _scheduleRead(true);
            return true;
        }
        return false;
    }

    // The backoff runs while something is missing, and stops once nothing is
    function _followRecheck() {
        if (!running || TailscaleRules.recheckPlan({ cli: cli, daemon: daemon, phase: view.phase, readFailing: _statusFailing }, false) === "none") {
            _recheckTimer.stop();
            _recheckAttempts = 0;
            return;
        }
        _recheckTimer.interval = TailscaleRules.recheckDelayMs(_recheckAttempts, recheckMinMs, pollMs);
        _recheckTimer.restart();
    }
    onDaemonChanged: _followRecheck()
    on_StatusFailingChanged: _followRecheck()

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
        const readNumber = reads;
        const token = ++_readToken;
        const serialAtStart = _changeSerial;
        _run(_tailscaleArgv(TailscaleRules.commandFor("status", {})), _limitMs("read"), statusResult => {
            if (token !== _readToken)
                return;
            if (_timedOut(statusResult)) {
                _readTimedOut();
                return;
            }
            _run(_tailscaleArgv(TailscaleRules.commandFor("prefs", {})), _limitMs("read"), prefsResult => {
                if (token !== _readToken)
                    return;
                _applyRead(statusResult, prefsResult);
                // These prefs were read after every operation that ended before the read began
                if (prefsResult.ok && !_timedOut(prefsResult) && prefs?.ok === true)
                    _prefsSerial = serialAtStart;
                _checkStranded(readNumber);
                _reading = false;
                _readFailures = 0;
                stale = false;
                // Only a read begun after the failure shows where it left Tailscale
                if (readNumber > _failureAfterRead)
                    _failureEvent("read");
                _afterRead();
                if (_readAgain) {
                    _readAgain = false;
                    _scheduleRead();
                }
            });
        });
    }

    function _timedOut(result) {
        return result.timedOut === true;
    }

    // A read that did not answer in time: the state is unknown (stale), retried with a backoff
    function _readTimedOut() {
        _reading = false;
        _readAgain = false;
        stale = true;
        readTimeouts++;
        _logOutcome("status --json", false, TailscaleRules.timeoutMessage("status", _limit("read")));
        // A click waiting for this read: said, not done blind
        if (_readIntent !== "") {
            _readIntent = "";
            _noteFailure(TailscaleRules.timeoutMessage("status", _limit("read")));
        }
        _readRetry.interval = Math.min(readRetryMaxMs, readRetryMinMs * Math.pow(2, Math.min(_readFailures, 10)));
        _readFailures++;
        _readRetry.restart();
    }

    function _applyRead(statusResult, prefsResult) {
        _moment = Date.now();
        if (statusResult.ok) {
            const parsed = TailscaleRules.parseStatus(statusResult.stdout);
            if (parsed.ok) {
                status = parsed;
                daemon = "running";
                readDenied = false;
                // Answering: a later stop is not "right after starting"
                _startedAt = 0;
            }
            _statusFailing = !parsed.ok;
            _logOutcome("status --json", parsed.ok, "its answer could not be read");
        } else {
            const error = TailscaleRules.runError(statusResult);
            _statusFailing = true;
            _logOutcome("status --json", false, error.message);
            if (error.kind === "not-running") {
                daemon = "not-running";
                status = null;
                // Gone again soon after the user's Start: it fails at start (no network device
                // after a kernel update without a reboot, a bad state file) — said on the entry
                if (_startedAt > 0 && Date.now() - _startedAt < startWatchMs) {
                    _startedAt = 0;
                    _noteFailure("Tailscale stopped right after starting.", reads - 1);
                }
            } else if (error.kind === "denied") {
                readDenied = true;
            }
        }
        if (prefsResult.ok) {
            const parsed = TailscaleRules.parsePrefs(prefsResult.stdout);
            if (parsed.ok)
                prefs = parsed;
            _logOutcome("debug prefs", parsed.ok, "its answer could not be read");
        } else if (daemon === "not-running") {
            prefs = null;
        } else if (statusResult.ok) {
            // Only while status answers: a daemon that is down is said once, by status
            _logOutcome("debug prefs", false, TailscaleRules.runError(prefsResult).message);
        }
        _followExitNode();
        _rememberTailnet();
    }

    // When the exit node in use went offline (the grace before attention counts from there)
    function _followExitNode() {
        const current = TailscaleRules.currentExitNode(status, prefs);
        if (current && status?.backendState === "Running" && !current.online) {
            if (exitNodeOfflineSince <= 0) {
                exitNodeOfflineSince = now;
                _graceTimer.restart();
            }
        } else {
            exitNodeOfflineSince = 0;
            _graceTimer.stop();
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

    // ---- The event stream ----

    property var _splitter: TailscaleRules.jsonSplitter()
    property real _streamStartedAt: 0
    property int _streamFailures: 0

    // The stream's run (the runner's handle), null while none runs
    property var _streamRun: null

    // The stream: the runner without a time limit, its lines read as they come; when it ends,
    // _streamEnded (unless it was stopped: _stopStream, the client stopping)
    function _startStream() {
        if (!running || cli !== "present" || _streamRun !== null || curlPath === "")
            return;
        const argv = TailscaleRules.streamArgv(curlPath, socketPath);
        if (argv.length === 0)
            return;
        _splitter = TailscaleRules.jsonSplitter();
        _streamStartedAt = Date.now();
        streamStarts++;
        let run = null;
        run = runner.start(argv, {
            timeoutMs: 0, environment: Object.assign({}, environment ?? {}), keepOutput: false,
            onStdout: text => {
                if (_streamRun === run)
                    _onBusText(text);
            },
            done: result => {
                if (_streamRun !== run)
                    return;
                _streamRun = null;
                _streamEnded();
            }
        });
        _streamRun = run;
    }

    // Ends the stream; it is not started again by itself
    function _stopStream() {
        const run = _streamRun;
        _streamRun = null;
        streamUp = false;
        run?.cancel();
    }

    // Ends the stream as if it had ended by itself: it is started again after the backoff
    function _restartStream() {
        _streamRun?.cancel();
    }

    function _streamEnded() {
        // It had been there (a message, or alive a while): the daemon may just have gone
        const wasUp = streamUp || Date.now() - _streamStartedAt >= 10000;
        streamUp = false;
        if (!running)
            return;
        if (Date.now() - _streamStartedAt >= 10000)
            _streamFailures = 0;
        _streamRestart.interval = Math.min(streamBackoffMaxMs, streamBackoffMinMs * Math.pow(2, Math.min(_streamFailures, 10)));
        _streamFailures++;
        _streamRestart.restart();
        _logOutcome("the event stream", false, "it ended");
        // The daemon may be gone: read now (a read finds "not running"). A stream that never
        // came up is no news — the reads then follow the look-again backoff, not every restart
        if (wasUp)
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
        if (!streamUp)
            _logOutcome("the event stream", true, "");
        streamUp = true;
        taildrop._onBus(object);
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
        if (digest.health !== null)
            busHealth = digest.health;
        if (digest.suggestedExitNode !== "")
            suggestedId = digest.suggestedExitNode;
        _scheduleRead();
    }

    // ---- Actions ----

    // The operation in flight: a token (a late answer of an abandoned one is ignored), its
    // plain run (cancelled when abandoned), who asked
    property int _opToken: 0
    property var _opRun: null
    property string _opOrigin: ""
    property string _opText: ""

    property var _pendingPhase: ""
    onViewChanged: {
        if (pendingAttention !== null && view.phase !== _pendingPhase)
            pendingAttention = null;
        if (failure !== null)
            failure = TailscaleRules.failureAfter(failure, "view", view.phase);
    }

    // A failed click of the user's: its reason on the entry's status line (TailscaleRules
    // .failureText, .failureAfter). Addresses are kept out (the status line may show on a
    // shared screen); the daemon's error and health are offered for a failure without words.
    // Only a read begun after the failure settles it: `settleAfter` the reads begun before it
    // (default: all so far); an operation's own failure counts from the operation's end
    // (_readsBeforeEnd), whose read is fresh
    property int _failureAfterRead: 0
    property int _readsBeforeEnd: 0
    function _noteFailure(reason, settleAfter) {
        if (!running)
            return;
        const health = (Array.isArray(busHealth) ? busHealth : []).map(item => Object.assign({}, item, { text: Api.address.redact(item?.text),
                                                                                                      title: Api.address.redact(item?.title) }));
        // The long sentence stays on the card's warnings; the status line gets the short one
        if (reason === elevationProblem && elevationProblem !== "")
            reason = "Can't ask for the password.";
        const text = TailscaleRules.failureText(Api.address.redact(String(reason ?? "")), { error: Api.address.redact(busError), health: health });
        failure = TailscaleRules.failureAfter(failure, "failed", view.phase, text);
        _failureAfterRead = typeof settleAfter === "number" ? settleAfter : reads;
    }

    function _failureEvent(event) {
        if (failure !== null)
            failure = TailscaleRules.failureAfter(failure, event, view.phase);
    }

    // A click while the state was unknown: what it asked for ("connect" | "disconnect"), done
    // once the read answers (_afterRead)
    property string _readIntent: ""

    function _afterRead() {
        if (_readIntent === "")
            return;
        const intent = _readIntent;
        _readIntent = "";
        Qt.callLater(() => {
            if (!running || busy)
                return;
            const plan = intent === "disconnect"
                ? TailscaleRules.planDisconnect(_planView, canChange, "user", {})
                : TailscaleRules.planConnect(_planView, canChange, "user");
            // Still unknown after a read that answered: said, never a blind `up`
            if (plan.kind === "read") {
                _noteFailure("Couldn't read Tailscale's state.");
                return;
            }
            _execute(plan, "user", intent);
        });
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
        // A new try, from anyone: the last one's failure is no longer the news
        _failureEvent("connecting");
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
        // Locked out by tailnet lock: the admin console, where a trusted device signs this one
        if (_shownAttention?.lockedOut === true) {
            const url = TailscaleRules.adminMachineUrl(status, prefs);
            return openUrl(url !== "" ? url : TailscaleRules.adminMachinesUrl);
        }
        // Exactly the attention the entry shows (_planView's: the state's, else an action's)
        const kind = _planView.attention?.kind ?? "";
        const action = _planView.attention?.action ?? "";
        const operationName = kind === "service-not-running" ? "start" : kind === "exit-node-offline" ? "exit-node"
            : (kind === "login" || kind === "key-expired") ? "login" : action === "Disconnect" ? "disconnect" : "connect";
        return _execute(TailscaleRules.planAttend(_planView, canChange, "user"), "user", operationName);
    }

    // `plan`: TailscaleRules' → true when something was started (or looked at again)
    function _execute(plan, origin, operationName) {
        if (!running)
            return false;
        if (origin === "user") {
            pendingAttention = null;
            _failureEvent("acted");
        }
        if (plan.kind === "recheck")
            return recheck();
        if (plan.kind === "read") {
            // The user's click is not dropped: done once the state is known
            if (origin === "user" && (operationName === "connect" || operationName === "disconnect"))
                _readIntent = operationName;
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
        if (["login", "addAccount"].includes(plan.command.name))
            return _startLogin(origin, plan.command.name);
        if (plan.command.name === "startService")
            return _startService();
        return _runChange(plan.command, origin, operationName);
    }

    // A change by name (TailscaleRules.commandFor) — the page's and the chooser's: the user's
    function _userChange(name, args, operationName, origin, onSuccess) {
        if (!running || busy)
            return false;
        pendingAttention = null;
        const command = TailscaleRules.commandFor(name, args ?? {});
        if (!command.ok) {
            failed("Changing Tailscale", command.error);
            return false;
        }
        return _runChange(command, _origin(origin ?? "user"), operationName, onSuccess);
    }

    function setExitNode(option) {
        if (option === null || option === undefined)
            return _userChange("exitNodeNone", {}, "exit-node");
        // The daemon refuses to use an exit node while offering one: said before anything runs
        if (TailscaleRules.exitNodeUseProblem(prefs) !== "") {
            failed("Changing Tailscale's exit node", TailscaleRules.exitNodeUseProblem(prefs));
            return false;
        }
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

    // `tailscale set --operator=` (empty): only root may change Tailscale again. The operator
    // may run it without a password; anyone else through pkexec
    function giveUpOperator() {
        return _userChange("operator", { user: "" }, "operator");
    }

    function startService() {
        if (!running || busy)
            return false;
        pendingAttention = null;
        return _startService();
    }

    // ---- Accounts (profiles) ----
    //
    // The list (`switch --list --json`) is denied to all but root and the operator, so it is
    // read only when the user asks (readAccounts: through pkexec when denied) — or by itself
    // while this user may change Tailscale (no prompt then). It is kept in memory only (it
    // holds e-mail addresses), and after a switch or a removal it is updated in place rather
    // than read again (another prompt).

    // [{ id, nickname, tailnet, account, selected }] — null: not read
    property var accounts: null
    // The account in use as status and prefs say it (any user may read those)
    readonly property var currentAccount: TailscaleRules.currentAccount(status, prefs)
    // The list read before no longer matches the account in use (switched elsewhere, a new one
    // added): offered to read again
    readonly property bool accountsOutdated: accounts !== null && !TailscaleRules.accountsCurrent(accounts, currentAccount.loginName)

    // `origin`: "user" (the page's buttons, the default) may be asked a password; anything
    // else (the IPC) never — a denial is then a failure, not a prompt
    function readAccounts(origin) {
        if (!running || busy)
            return false;
        return _runChange(TailscaleRules.commandFor("switchList", {}), _origin(origin ?? "user"), "accounts", output => {
            accounts = TailscaleRules.parseSwitchList(output);
        });
    }

    // After a change: read again when that asks for no password — as origin "network", so a
    // canChange that is already stale (a new profile has no operator) never prompts; a denial
    // then just leaves the list as it is (marked out of date when it no longer matches)
    function _accountsChanged() {
        if (canChange)
            Qt.callLater(() => {
                if (!busy && running)
                    _runChange(TailscaleRules.commandFor("switchList", {}), "network", "accounts-auto", output => {
                        accounts = TailscaleRules.parseSwitchList(output);
                    });
            });
    }

    function switchAccount(id, origin) {
        if (!running || busy)
            return false;
        const command = TailscaleRules.commandFor("switchAccount", { id: id });
        if (!command.ok) {
            failed("Switching Tailscale account", command.error);
            return false;
        }
        pendingAttention = null;
        return _runChange(command, _origin(origin ?? "user"), "account", () => {
            accounts = accounts !== null ? TailscaleRules.accountsAfter(accounts, { switched: id }) : null;
            loginInterrupted = null;
            _accountsChanged();
        });
    }

    // Not the account in use (TailscaleRules.accountRows: removable)
    function removeAccount(id) {
        if (!running || busy)
            return false;
        const row = TailscaleRules.accountRows(accounts ?? []).find(account => account.id === id);
        const listed = (accounts ?? []).find(account => account.id === id);
        const inUse = (row && !row.removable) || (listed && currentAccount.loginName !== ""
            && String(listed.account).toLowerCase() === currentAccount.loginName.toLowerCase());
        if (inUse) {
            failed("Removing a Tailscale account", "The account in use cannot be removed: switch to another first, or log out.");
            return false;
        }
        // Which one is in use is not sure while the list is out of date
        if (accountsOutdated) {
            failed("Removing a Tailscale account", "The list of accounts is out of date: read it again first.");
            return false;
        }
        const command = TailscaleRules.commandFor("removeAccount", { id: id });
        if (!command.ok) {
            failed("Removing a Tailscale account", command.error);
            return false;
        }
        return _runChange(command, "user", "account", () => {
            accounts = accounts !== null ? TailscaleRules.accountsAfter(accounts, { removed: id }) : null;
            _accountsChanged();
        });
    }

    // Another account: a bare `tailscale login` while logged in starts a new profile
    function addAccount() {
        if (!running || busy)
            return false;
        pendingAttention = null;
        return _startLogin("user", "addAccount");
    }

    // ---- This device ----

    readonly property var device: TailscaleRules.thisDevice(status, prefs, now, systemHostname)
    readonly property var keyState: TailscaleRules.keyState(self, now)

    // "" = the system's own name again
    function setHostname(name, origin) {
        return _userChange("hostname", { name: String(name ?? "").trim() }, "setting", origin);
    }

    function setNickname(name) {
        return _userChange("nickname", { name: String(name ?? "").trim() }, "setting");
    }

    // ---- Sharing this computer (step 3): every change a `tailscale set` ----
    //
    // The exit node and the routes share one preference (AdvertiseRoutes): the exit node is
    // changed with --advertise-exit-node alone, the routes with --advertise-routes alone (the
    // whole list of subnet routes each time) — set.go keeps the other half (TailscaleRules,
    // "Sharing this computer"). IP forwarding is read through the shell (Api.system.readIpForwarding: /proc, any user may) only when asked:
    // the page's Sharing section on screen, and after a change that offers something.

    readonly property var sharing: TailscaleRules.sharing(status, prefs)
    readonly property var sshServer: TailscaleRules.sshServer(status, prefs)
    // { ipv4, ipv6 (true/false/null), readAt (ms, 0 never) }
    property var forwarding: ({ ipv4: null, ipv6: null, readAt: 0 })
    readonly property var forwardingWarning: TailscaleRules.forwardingWarning(sharing, forwarding, busHealth, status, updateManagedBySystem)
    readonly property string autoUpdateProblem: updateManagedBySystem
        ? "Not available: Tailscale is updated with the system here and refuses to update itself." : ""
    readonly property var _switchCommands: ["ssh", "webClient", "snat", "statefulFiltering", "connector", "posture", "autoUpdate", "updateCheck"]
    property real _forwardingAskedAt: 0

    // Reads both switches (unprivileged: the system's facts, module API 1.13), at most once a
    // second
    function readForwarding() {
        if (!running)
            return false;
        const moment = Date.now();
        if (moment - _forwardingAskedAt < 1000)
            return false;
        _forwardingAskedAt = moment;
        let read = null;
        try {
            read = typeof system?.readIpForwarding === "function" ? system.readIpForwarding() : null;
        } catch (error) {
            read = null;
        }
        const state = value => value === true || value === false ? value : null;
        forwarding = { ipv4: state(read?.ipv4), ipv6: state(read?.ipv6), readAt: fixedNow > 0 ? fixedNow : moment };
        return true;
    }

    function _afterOffer() {
        _forwardingAskedAt = 0;
        readForwarding();
    }

    function setAdvertiseExitNode(on, origin) {
        if (on === true && TailscaleRules.exitNodeOfferProblem(prefs) !== "") {
            failed("Offering this computer as an exit node", TailscaleRules.exitNodeOfferProblem(prefs));
            return false;
        }
        return _userChange("advertiseExitNode", { on: on === true }, "sharing", origin, () => _afterOffer());
    }

    // Route edits. The list sent is the WHOLE list of subnet routes, so it must never be built
    // from prefs that are stale or of another profile — it would drop routes, or write one
    // profile's routes into another. So:
    //   - refused unless prefs are read and current: no operation (a change, a switch, a login)
    //     has ended since the read they came from (_changeSerial / _prefsSerial), and the list
    //     was not cut at the 256 read;
    //   - the click is an INTENT (add X / remove X); the command is planned
    //     (TailscaleRules.routeEditPlan) from prefs read again under the operation's lock, right
    //     before the plain run and again right before the retry through pkexec; a profile that
    //     changed since the click aborts ("Changed meanwhile"); a route added or removed
    //     meanwhile ends quietly (nothing to send);
    //   - once sent, the list is held in `prefs` at once, so a second edit before the next read
    //     builds on it.
    // What stays open: once pkexec's password dialog is up, its argv is fixed — a change made
    // elsewhere while the dialog waits is overwritten by this list.
    property int _changeSerial: 0
    property int _prefsSerial: 0
    readonly property bool prefsCurrent: prefs?.ok === true && _prefsSerial === _changeSerial

    // Adds one subnet route (checked by TailscaleRules.routeProblem first)
    function addRoute(text, origin) {
        const problem = TailscaleRules.routeProblem(String(text ?? ""), prefs?.advertiseRoutes ?? []);
        if (problem.error !== "" && prefs?.ok === true) {
            failed("Offering a route", problem.error);
            return false;
        }
        return _editRoutes({ add: problem.network !== "" ? problem.network : String(text ?? "") }, origin, "Offering a route");
    }

    function removeRoute(route, origin) {
        const removed = Api.address.parseCidr(String(route ?? ""));
        if (prefs?.ok === true && (!removed || !(prefs.advertiseRoutes ?? []).some(item => Api.address.parseCidr(item)?.network === removed.network))) {
            failed("Removing a route", "That network is not offered.");
            return false;
        }
        return _editRoutes({ remove: removed ? removed.network : String(route ?? "") }, origin, "Removing a route");
    }

    function _editRoutes(intent, origin, what) {
        if (!running || busy)
            return false;
        if (prefs?.ok !== true || !prefsCurrent) {
            failed(what, prefs?.ok !== true ? "Tailscale's settings are not read yet: try again in a moment."
                : "Tailscale's settings are being read again after the last change: try again in a moment.");
            return false;
        }
        const first = TailscaleRules.routeEditPlan(prefs, intent, "");
        if (first.kind !== "run") {
            failed(what, first.kind === "nothing" ? "Nothing to change." : first.error);
            return false;
        }
        pendingAttention = null;
        const identity = TailscaleRules.prefsIdentity(prefs);
        const prepare = (token, go) => _readPrefsNow(token, fresh => {
            const plan = TailscaleRules.routeEditPlan(fresh, intent, identity);
            if (plan.kind === "run") {
                go(plan.command);
                return;
            }
            _finish();
            if (plan.kind !== "nothing")
                failed(what, plan.error);
        });
        return _runChange(first.command, _origin(origin ?? "user"), "sharing", (output, command) => {
            // The list just sent, held until the next read brings the daemon's own
            const sent = String(command.argv[2] ?? "").replace(/^--advertise-routes=/, "");
            prefs = TailscaleRules.prefsWithRoutes(prefs, sent === "" ? [] : sent.split(","));
            _prefsSerial = _changeSerial;
            if ("add" in intent)
                _afterOffer();
        }, prepare);
    }

    // One of the plain switches (_switchCommands): Tailscale SSH, the web interface, SNAT,
    // stateful filtering, the app connector, posture reports, automatic updates, update checks
    function setSwitch(name, on, origin) {
        if (!_switchCommands.includes(name)) {
            failed("Changing Tailscale", "No such switch.");
            return false;
        }
        if (name === "autoUpdate" && on === true && autoUpdateProblem !== "") {
            failed("Turning on Tailscale's automatic updates", autoUpdateProblem);
            return false;
        }
        if (name === "ssh" && on === true && !sshServer.canTurnOn) {
            failed("Starting Tailscale's SSH server", sshServer.problem);
            return false;
        }
        return _userChange(name, { on: on === true }, "sharing", origin, name === "connector" && on === true ? () => _afterOffer() : null);
    }

    // "" turns the peer relay off
    function setRelayServerPort(text, origin) {
        return _userChange("relayServerPort", { port: String(text ?? "").trim() }, "sharing", origin);
    }

    // ---- Diagnostics: run when asked, never at start or on a clock ----
    //
    // runDiagnostics(): `version --json`, `debug derp-map` (once: the relay names), `netcheck
    // --format=json`, `dns status --json`, one after another, each under its time limit
    // (netcheck probes every relay region: timeLimits.diagnose). Reads only, any user may run
    // them; they do not take the operation lock (nothing they do conflicts with a change),
    // but one run at a time.

    // { running, ranAt (ms, 0 never), clientVersion, netcheck (summary rows), nearest, dns
    // (rows), errors [text] }
    property var diagnostics: ({ running: false, ranAt: 0, clientVersion: "", netcheck: [], nearest: null, dns: [], errors: [] })
    property var _derpMap: null
    readonly property var health: TailscaleRules.healthList(busHealth, status)
    readonly property string updateNotice: {
        const version = status?.clientVersion ?? null;
        return version && version.runningLatest === false && version.latestVersion !== ""
            ? "Tailscale " + version.latestVersion + " is available" + (updateManagedBySystem ? " (updated with the system)" : "") : "";
    }
    // The text "Copy diagnostics" copies (TailscaleRules.diagnosticsText: no keys, no links)
    readonly property string diagnosticsReport: TailscaleRules.diagnosticsText({
        clientVersion: diagnostics.clientVersion, daemonVersion: status?.version ?? "", backendState: status?.backendState ?? "",
        netcheck: diagnostics.netcheck, dns: diagnostics.dns, health: health, update: updateNotice
    })

    function runDiagnostics() {
        if (!running || cli !== "present" || diagnostics.running)
            return false;
        const result = { running: true, ranAt: 0, clientVersion: "", netcheck: [], nearest: null, dns: [], errors: [] };
        diagnostics = Object.assign({}, result);
        const steps = [
            { name: "version", limit: "read", apply: output => result.clientVersion = TailscaleRules.parseVersion(output).long },
            { name: "derpMap", limit: "read", skip: () => _derpMap !== null, apply: output => _derpMap = TailscaleRules.parseDerpMap(output) },
            { name: "netcheck", limit: "diagnose", apply: output => {
                const summary = TailscaleRules.netcheckSummary(TailscaleRules.parseNetcheck(output), _derpMap ?? {});
                if (!summary.ok)
                    result.errors.push("netcheck: its answer could not be read.");
                result.netcheck = summary.rows;
                result.nearest = summary.nearest;
            } },
            { name: "dnsStatus", limit: "read", apply: output => {
                const dns = TailscaleRules.parseDnsStatus(output);
                if (!dns.ok)
                    result.errors.push("dns status: its answer could not be read.");
                result.dns = TailscaleRules.dnsSummary(dns);
            } }
        ];
        const next = () => {
            const step = steps.shift();
            if (!step) {
                result.running = false;
                result.ranAt = fixedNow > 0 ? fixedNow : Date.now();
                diagnostics = Object.assign({}, result);
                return;
            }
            if (step.skip?.()) {
                next();
                return;
            }
            const command = TailscaleRules.commandFor(step.name, {});
            const seconds = _limit(step.limit);
            _run(_tailscaleArgv(command), seconds * 1000, answer => {
                if (answer.ok)
                    step.apply(answer.stdout);
                else
                    result.errors.push(command.argv.slice(1, 3).join(" ") + ": " + (_timedOut(answer)
                        ? TailscaleRules.timeoutMessage(step.name, seconds) : TailscaleRules.runError(answer).message));
                diagnostics = Object.assign({}, result, { running: true });
                next();
            });
        };
        next();
        return true;
    }

    // ---- Ping a device (from its row): one ping, `tailscale ping --c=1 --timeout=3s` ----

    // { <device id>: { running, ok, text } }
    property var pings: ({})

    function ping(device) {
        if (!running || cli !== "present" || !device || typeof device.id !== "string")
            return false;
        if (pings[device.id]?.running)
            return false;
        const target = device.ipv4 || (device.addresses ?? [])[0] || "";
        const command = TailscaleRules.commandFor("ping", { target: target });
        const id = device.id;
        const record = value => {
            const next = Object.assign({}, pings);
            next[id] = value;
            pings = next;
        };
        if (!command.ok) {
            record({ running: false, ok: false, text: command.error });
            return false;
        }
        record({ running: true, ok: false, text: "pinging…" });
        const seconds = _limit("ping");
        _run(_tailscaleArgv(command), seconds * 1000, answer => {
            const parsed = TailscaleRules.parsePing(answer.stdout);
            const summary = TailscaleRules.pingSummary(parsed);
            if (summary.ok || parsed.timedOut || parsed.noReply || answer.ok)
                record({ running: false, ok: summary.ok, text: summary.text });
            else
                record({ running: false, ok: false, text: _timedOut(answer) ? "no answer within " + seconds + " s"
                    : TailscaleRules.runError(answer).message });
        });
        return true;
    }

    // Stops waiting for the operation in flight: its token bumped (its late answer ignored),
    // its plain run cancelled, its run as administrator cancelled (pkexec ends while it asks;
    // a command already running as root ends at its time limit), busy cleared
    function _abandonOperation() {
        _opToken++;
        _loginTimer.stop();
        _opRun?.cancel();
        _opRun = null;
        if (_opPrivileged !== null)
            _opPrivileged.cancel();
        _opPrivileged = null;
        operation = "";
        authUrl = "";
        _opText = "";
        _readsBeforeEnd = reads;
        _scheduleRead(true);
    }

    // ---- Running as administrator (module API 1.11: the handle's privileged.start) ----

    // The runs started and not answered yet (cancelled when the client stops), and the
    // operation's own
    property var _privilegedRuns: []
    property var _opPrivileged: null

    // `command` (commandFor's) as administrator, under the time limit `seconds`:
    // TailscaleRules.privilegedRun decides (a trusted tailscale only, the command's `what`),
    // the shell runs it — one password question at a time, its own timeout inside pkexec.
    // `handlers`: { onStdout(text), onStderr(text), done(result) } — done once, with the
    // shell's result (privilegedOutcome reads it), never after the client stopped.
    // → { ok, error }: not ok when nothing was started (error: why)
    function _runPrivileged(command, seconds, handlers) {
        const plan = TailscaleRules.privilegedRun(command, {
            program: programs?.tailscale ?? null, available: privileged?.available === true,
            unavailableReason: privileged ? String(privileged.unavailableReason ?? "") : "no way to run as administrator", seconds: seconds,
            environment: environment
        });
        if (!plan.ok)
            return { ok: false, error: plan.error };
        let run = null;
        const forget = () => {
            _privilegedRuns = _privilegedRuns.filter(item => item !== run);
            if (_opPrivileged === run)
                _opPrivileged = null;
        };
        // The suites' stand-in state (module API 1.14, module test mode only); never given
        // outside a suite (`environment` is empty there). A run the client cancelled (it
        // stopped, the operation was given up) hands over no output and answers `cancelled`;
        // its handlers drop that by the operation's token
        const environmentOption = plan.environment !== null ? { environment: plan.environment } : {};
        try {
            run = privileged.start(plan.argv, Object.assign(environmentOption, {
                what: plan.what, timeoutMs: plan.timeoutMs, notifyFailures: false,
                onStdout: text => handlers?.onStdout?.(text),
                onStderr: text => handlers?.onStderr?.(text),
                done: result => {
                    forget();
                    if (running)
                        handlers?.done?.(result);
                }
            }));
        } catch (error) {
            return { ok: false, error: "It could not be run as administrator: " + String(error).slice(0, 200) };
        }
        if (run !== null && typeof run?.cancel === "function" && run.running !== false)
            _privilegedRuns = _privilegedRuns.concat([run]);
        _opPrivileged = run;
        return { ok: true, error: "" };
    }

    // Runs `command` (a tailscale command from the table) plainly, by absolute path, under its
    // time limit; denied and asked by the user: through pkexec; denied otherwise: attention
    // `onSuccess(output, command)`: called with its standard output (and the command that ran)
    // once it succeeded (plainly or through pkexec) — a read that only root or the operator may
    // do (switch --list). `prepare`: see below (a change derived from current prefs)
    // `onEnd({ ok, dismissed, elevated, code, message, error })`: when given, called once at the
    // end, whatever it was — and failures are then NOT notified (the caller shows them: Taildrop's
    // per-file results); `error` is the raw stderr
    function _runChange(command, origin, operationName, onSuccess, prepare, onEnd) {
        // `notify` false: the shell told it already (a refused run as administrator)
        const fail = (description, message, extra, notify) => {
            if (onEnd)
                onEnd(Object.assign({ ok: false, dismissed: false, elevated: false, code: -1, message: message, error: "" }, extra ?? {}));
            else if (notify !== false)
                failed(description, message);
            // The user's connect or disconnect: also on the entry, where the click was
            if (origin === "user" && (operationName === "connect" || operationName === "disconnect"))
                _noteFailure(message, _readsBeforeEnd);
        };
        // One change at a time: a second caller never replaces the running one (its process
        // and its result would be lost)
        if (busy) {
            fail(command.description, "Another Tailscale change is running.");
            return false;
        }
        if (tailscalePath === "") {
            fail(command.description, "Tailscale is not installed.");
            return false;
        }
        const seconds = _limit(command.timeLimit ?? "change");
        const token = ++_opToken;
        operation = operationName;
        _opOrigin = origin;
        _opText = "";
        _loginOpened = false;
        authUrl = "";
        const pendingConnect = command.name === "connect";
        // `prepare(token, go)`: a change whose value derives from current prefs (a route edit)
        // builds its command again from prefs read now — under this operation's lock, before
        // the plain run and before the retry through pkexec — and calls go(command), or ends
        // the operation itself (_finish) when there is nothing to do or it changed meanwhile
        const stage = (current, next) => prepare ? prepare(token, next) : next(current);
        const elevate = current => {
            let output = "";
            const started = _runPrivileged(current, seconds, {
                onStdout: text => output = (output + text).slice(-1048576),
                done: answer => {
                    if (token !== _opToken)
                        return;
                    _finish();
                    const outcome = TailscaleRules.privilegedOutcome(answer, current.name, seconds);
                    if (outcome.kind === "cancelled")
                        return;
                    if (outcome.kind === "ok") {
                        _failureEvent("succeeded");
                        onSuccess?.(output.replace(/\n$/, ""), current);
                    }
                    if (outcome.kind === "ok" || outcome.kind === "dismissed") {
                        onEnd?.({ ok: outcome.kind === "ok", dismissed: outcome.kind === "dismissed", elevated: true, code: answer.code ?? 0, message: "", error: "" });
                        return;
                    }
                    fail(current.description, outcome.message, { elevated: true, code: answer.code ?? -1, error: String(answer.stderr ?? "") },
                         outcome.notify);
                }
            });
            if (!started.ok) {
                _finish();
                fail(current.description, elevationProblem !== "" ? elevationProblem : started.error);
            }
        };
        const plain = current => {
            _opRun = _run(_tailscaleArgv(current), seconds * 1000, result => {
                if (token !== _opToken)
                    return;
                _opRun = null;
                if (result.ok) {
                    _finish();
                    _failureEvent("succeeded");
                    onSuccess?.(result.stdout, current);
                    onEnd?.({ ok: true, dismissed: false, elevated: false, code: 0, message: "", error: "" });
                    return;
                }
                const extra = { code: result.code, error: result.stderr };
                if (_timedOut(result)) {
                    _finish();
                    fail(current.description, TailscaleRules.timeoutMessage(current.name, seconds), extra);
                    return;
                }
                const error = TailscaleRules.runError(result);
                if (error.kind !== "denied") {
                    _finish();
                    fail(current.description, error.message, extra);
                    return;
                }
                if (origin !== "user") {
                    _finish();
                    // The list read again by itself: denied is no news
                    if (operationName === "accounts-auto")
                        return;
                    // Not the provider's connect/disconnect (the IPC): a failure, never a prompt
                    if (operationName !== "connect" && operationName !== "disconnect") {
                        fail(current.description, error.message + " Asked from outside the page: no password prompt.", extra);
                        return;
                    }
                    _hold({ kind: "needs-privilege", reason: "Tailscale refused a change asked for by a network: it needs an administrator's password — or make this user Tailscale's operator",
                            action: operationName === "disconnect" ? "Disconnect" : "Connect" });
                    return;
                }
                stage(current, elevate);
            }, pendingConnect ? text => _onConnectText(text, token) : null);
        };
        stage(command, plain);
        return true;
    }

    // Reads `debug prefs` (any user may) for an operation in flight: done(parsed prefs) — or
    // nothing when the operation was abandoned meanwhile; a failed read is parsed as not ok
    function _readPrefsNow(token, done) {
        _opRun = _run(_tailscaleArgv(TailscaleRules.commandFor("prefs", {})), _limitMs("read"), result => {
            if (token !== _opToken)
                return;
            _opRun = null;
            done(TailscaleRules.parsePrefs(result.ok ? result.stdout : ""));
        });
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
        _changeSerial++;
        authUrl = "";
        _readsBeforeEnd = reads;
        _scheduleRead(true);
    }

    // `systemctl start tailscaled.service` (systemd asks polkit itself: no pkexec), systemctl
    // by the path the shell found
    function _startService() {
        const command = TailscaleRules.commandFor("startService", {});
        if (systemctlPath === "") {
            failed(command.description, "systemctl was not found.");
            _noteFailure("Not started.");
            return false;
        }
        const token = ++_opToken;
        const seconds = _limit("change");
        operation = "start";
        _opRun = _run(TailscaleRules.commandLine(command.argv, systemctlPath), seconds * 1000, result => {
            if (token !== _opToken)
                return;
            _opRun = null;
            operation = "";
            _changeSerial++;
            if (!result.ok) {
                const reason = _timedOut(result) ? TailscaleRules.timeoutMessage("startService", seconds)
                    : ((result.stderr.trim().split("\n")[0] ?? "").trim() || ("systemctl exited with status " + result.code + "."));
                failed(command.description, reason);
                // A refused start and a cancelled password prompt look alike ("Access denied"):
                // the entry says it neutrally, the notification keeps systemd's words
                _noteFailure(_timedOut(result) ? reason : "Not started.");
                return;
            }
            daemon = "unknown";
            _failureEvent("succeeded");
            _startedAt = Date.now();
            _streamFailures = 0;
            _streamRestart.stop();
            _scheduleRead(true);
            _startStream();
        });
        return true;
    }

    // A folder in the file manager (Taildrop's "Open folder"): a file: URL of a FOLDER only — the
    // caller passes the save folder, never a received file — through Api.openUrl with allowFile
    function openFolder(url) {
        if (typeof url !== "string" || !url.startsWith("file:///") || /[\u0000-\u001f]/.test(url))
            return false;
        opened++;
        Api.openUrl(url, { allowFile: true });
        return true;
    }

    // A command that is not a tailscale command (Taildrop's save script, the certificate's),
    // run under the operation lock, plainly — never through pkexec — under the time limit
    // `limitMs`: done(result) once (the runner's), unless abandoned
    function _runLocked(operationName, argv, limitMs, done) {
        if (!running || busy)
            return false;
        const token = ++_opToken;
        operation = operationName;
        _opRun = _run(argv, limitMs, result => {
            if (token !== _opToken)
                return;
            _opRun = null;
            _finish();
            done(result);
        });
        return true;
    }

    function openUrl(url) {
        const safe = TailscaleRules.safeUrl(url);
        if (safe === "")
            return false;
        opened++;
        Api.openUrl(safe);
        return true;
    }

    // `tailscale exit-node suggest` → suggestedName; then `done()`
    function suggest(done) {
        if (!running || cli !== "present") {
            done?.();
            return;
        }
        _run(_tailscaleArgv(TailscaleRules.commandFor("exitNodeSuggest", {})), _limitMs("read"), result => {
            const parsed = TailscaleRules.parseExitNodeSuggest(result.stdout);
            if (parsed.name !== "")
                suggestedName = parsed.name;
            done?.();
        });
    }

    // ---- Logging in (also: adding an account, renewing the key) ----

    property string _loginText: ""
    // The login runs as root: the run as administrator printed its first line (before that it
    // waits in the shell's queue or for the password, and nothing runs as root yet)
    property bool _loginElevated: false
    property bool _loginOpened: false
    // Which: "login" | "addAccount" (both a bare `tailscale login`)
    property string _loginCommand: "login"
    // The login started from a logged-in profile, and the account it was (the list's selected
    // row, when the list was read: { id, title }; else { id: "", title: "" })
    property var _loginFrom: null
    // A login that started from a logged-in profile and then did not finish (cancelled, timed
    // out, failed) after it printed its URL: `tailscale login` had by then moved this computer
    // to a new, empty profile — the page offers the way back ({ id, title }; id "" when the
    // accounts were not read: "Show accounts" then). null otherwise; cleared once connected
    // again or another account is chosen.
    property var loginInterrupted: null
    // A login from a logged-in profile that did not finish: the next read decides whether it
    // left the daemon on the empty profile ({ from, afterRead }), see _checkStranded
    property var _strandCheck: null
    // One line after a cancelled login that runs as administrator (it cannot be stopped)
    property string loginNote: ""
    readonly property bool loggingIn: operation === "login"
    // The login's time limit, in whole seconds (the runner's, and the shell's around the root one)
    readonly property int _loginSeconds: Math.max(1, Math.ceil(loginTimeoutMs / 1000))

    function _startLogin(origin, commandName) {
        if (origin !== "user" || tailscalePath === "")
            return false;
        const token = ++_opToken;
        _loginCommand = commandName === "addAccount" ? "addAccount" : "login";
        loginNote = "";
        const loggedIn = ["running", "starting", "stopped", "needs-approval"].includes(view.phase);
        const selected = (accounts ?? []).find(account => account.selected) ?? null;
        _loginFrom = loggedIn ? { id: selected?.id ?? "", title: selected ? (TailscaleRules.accountRows([selected])[0]?.title ?? "") : "" } : null;
        operation = "login";
        _opOrigin = origin;
        authUrl = "";
        _loginText = "";
        _loginElevated = false;
        _loginOpened = false;
        _loginTimer.restart();
        _opRun = _run(_tailscaleArgv(TailscaleRules.commandFor(_loginCommand, {})), _loginSeconds * 1000,
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
        // A login already running as root ends only at its time limit: its browser page still
        // works. One still waiting for the password (or its turn) ends with the cancel
        if (_loginElevated)
            loginNote = "Close the login page in the browser: the login runs on as administrator until its time limit.";
        else if (_opPrivileged !== null)
            loginNote = "Login cancelled.";
        _loginGaveUp();
        _abandonOperation();
    }

    // The login did not finish (cancelled, timed out, failed, a prompt dismissed). A bare
    // `login` moves the daemon to a new, empty profile FIRST (cli/login.go), before any URL —
    // or not at all, when Tailscale refused it before. So the state decides, not what was
    // seen: the next read after this, if it shows no login, sets loginInterrupted
    // (_checkStranded)
    function _loginGaveUp() {
        if (_loginFrom !== null) {
            _strandCheck = { from: _loginFrom, afterRead: reads };
            _scheduleRead(true);
        }
        _loginFrom = null;
    }

    // After a read: a login given up from a logged-in profile left it on the empty profile when
    // status or prefs show no login now (loginInterrupted: "Switch back"); the old account
    // still in use: nothing. A login shown again ends an interruption.
    function _checkStranded(readNumber) {
        const loggedIn = currentAccount.loginName !== "" && !["logged-out", "needs-login", "key-expired", "unknown"].includes(view.phase);
        if (_strandCheck !== null && readNumber > _strandCheck.afterRead) {
            if (!loggedIn)
                loginInterrupted = _strandCheck.from;
            _strandCheck = null;
        } else if (loginInterrupted !== null && loggedIn && operation !== "login") {
            loginInterrupted = null;
        }
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
        _opRun = null;
        const description = TailscaleRules.commandFor(_loginCommand, {}).description;
        const code = result.code;
        if (code === 0 || TailscaleRules.parseLoginOutput(_loginText).success) {
            _loginFrom = null;
            _failureEvent("succeeded");
            loginInterrupted = null;
            // A new account (or a renewed key) changes the list: read again when that asks
            // for no password; otherwise the page offers to
            if (accounts !== null)
                _accountsChanged();
            _loginDone();
            return;
        }
        if (_timedOut(result)) {
            _loginGaveUp();
            _loginDone();
            _loginFailed(description, TailscaleRules.timeoutMessage(_loginCommand, _loginSeconds));
            return;
        }
        const error = result.error !== "" || result.failedToStart ? TailscaleRules.runError(result) : TailscaleRules.errorKind(code, _loginText);
        if (error.kind === "denied") {
            // As administrator, its output streamed (the login link): the shell's timeout
            // inside pkexec ends it at the login's limit. Its first line: it runs as root
            _loginText = "";
            const elevatedText = text => {
                if (token === _opToken)
                    _loginElevated = true;
                _onLoginText(text, token);
            };
            const started = _runPrivileged(TailscaleRules.commandFor(_loginCommand, {}), _loginSeconds, {
                onStdout: elevatedText,
                onStderr: elevatedText,
                done: answer => _elevatedLoginEnded(token, answer)
            });
            if (!started.ok) {
                _loginGaveUp();
                _loginDone();
                _loginFailed(description, elevationProblem !== "" ? elevationProblem : started.error);
            }
            return;
        }
        _loginGaveUp();
        _loginDone();
        _loginFailed(description, error.message);
    }

    // The login as administrator ended (the shell's result: TailscaleRules.privilegedOutcome)
    function _elevatedLoginEnded(token, answer) {
        if (!running || token !== _opToken)
            return;
        _opPrivileged = null;
        const description = TailscaleRules.commandFor(_loginCommand, {}).description;
        // The login's own words are what it printed, read as it came
        const outcome = TailscaleRules.privilegedOutcome(Object.assign({}, answer, { stderr: _loginText }), _loginCommand, _loginSeconds);
        // Cancelled: the client's own cancel changed the token (above), so this is one it did
        // not make — the login ends quietly, as when dismissed
        if (outcome.kind === "cancelled") {
            _loginGaveUp();
            _loginDone();
            return;
        }
        if (outcome.kind === "ok" || TailscaleRules.parseLoginOutput(_loginText).success) {
            _loginFrom = null;
            _failureEvent("succeeded");
            loginInterrupted = null;
            if (accounts !== null)
                _accountsChanged();
            _loginDone();
            return;
        }
        // Dismissed: nothing ran as root — but the plain attempt before it may already have
        // moved to the empty profile (refused after the move): the state decides
        _loginGaveUp();
        _loginDone();
        if (outcome.kind === "dismissed")
            return;
        _loginFailed(description, outcome.message, outcome.notify);
    }

    // A login that failed: notified (unless the shell told it: `notify` false); one to connect
    // (not another account) also on the entry
    function _loginFailed(description, reason, notify) {
        if (notify !== false)
            failed(description, reason);
        if (_loginCommand === "login")
            _noteFailure(reason, _readsBeforeEnd);
    }

    function _loginDone() {
        _loginTimer.stop();
        operation = "";
        _changeSerial++;
        authUrl = "";
        _readsBeforeEnd = reads;
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
        tailnetLock.read();
        _moment = Date.now();
        // The host name may have changed meanwhile (the shell reads it again)
        if (typeof system?.refresh === "function")
            system.refresh();
        refresh();
        if (_streamRun !== null)
            _restartStream();
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

    // ---- The runner and the timers ----

    property CommandRunner _ownRunner: CommandRunner {}

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

    // The login given up: no longer waited for (the plain one ended; one as administrator
    // cancelled — running as root it ends at its time limit, set to the same time)
    property Timer _loginTimer: Timer {
        interval: root.loginTimeoutMs
        onTriggered: {
            if (root.operation !== "login")
                return;
            root._loginGaveUp();
            root._abandonOperation();
            root._loginFailed(TailscaleRules.commandFor(root._loginCommand, {}).description, TailscaleRules.timeoutMessage(root._loginCommand, root.loginTimeoutMs / 1000));
        }
    }

    // The slow poll, at all times (and the CLI looked for again while missing or not trusted)
    // — but not twice: while the backoff below runs, it looks
    property Timer _poll: Timer {
        interval: root.pollMs
        repeat: true
        running: root.running
        onTriggered: {
            if (!root._recheckTimer.running)
                root.refresh();
        }
    }

    // Looking again while Tailscale is missing, not trusted or stopped (_followRecheck sets
    // the interval: the backoff)
    property Timer _recheckTimer: Timer {
        repeat: false
        onTriggered: {
            root._recheckAttempts++;
            root._recheck(false);
            root._followRecheck();
        }
    }

    // The traffic while the devices page is shown
    property Timer _watchPoll: Timer {
        interval: root.watchPollMs
        repeat: true
        running: root.running && root.watching && root.cli === "present"
        onTriggered: root._scheduleRead()
    }

    // An offline exit node's grace (TailscaleRules.exitNodeOfflineGraceMs) ends: the state is
    // derived again then, not at the next minute or read
    property Timer _graceTimer: Timer {
        interval: TailscaleRules.exitNodeOfflineGraceMs + 250
        repeat: false
        onTriggered: root._moment = Date.now()
    }
}
