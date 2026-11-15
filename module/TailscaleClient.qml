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
//     (readable by any user), split by TailscaleRules.jsonFeed and read by notifyDigest. A
//     message's State, BrowseToURL, LoginFinished, ErrMessage, Prefs and SuggestedExitNode are
//     taken from it at once; every message is also a TRIGGER to re-read `status --json` and
//     `debug prefs` — debounced (readDebounceMs) and coalesced: never more than one read in
//     flight, a trigger during a read gives one more read after it.
//   - The stream ends (daemon stopped or restarted, curl gone): an immediate re-read (which
//     finds "not running" if so), and the stream is started again after a backoff (1 s,
//     doubling to streamBackoffMaxMs; back to 1 s after a stream that lived 10 s).
//   - While the stream is down: a slow poll (pollMs, 60 s) re-reads — and looks for the CLI
//     again when it was missing.
//   - Resume from sleep: the module API offers no signal for it, so a 10 s clock notices a
//     jump (the event loop stood still longer than resumeGapMs) and re-reads and restarts the
//     stream.
//   - Byte counters (devices' traffic) are in `status --json`: re-read every watchPollMs only
//     while something watches (the devices page: watch() / unwatch()).
//
// THE TOOLS SEAM — the one place that decides which tailscale, curl, pkexec, systemctl and
// xdg-open run (`tool(name)`):
//   - `toolsDir` set by the owner (the suites): programs from there;
//   - else H2S_TAILSCALE_TOOLS in the shell's environment (an absolute directory): from there
//     (the module's lock-bed test);
//   - else, under the shell's module test runner (H2S_TEST_MODULES is set): the stand-ins next
//     to the module (../tools/stand-in) — a module test can never reach the real tailscale;
//     when they are not there nothing runs (the CLI counts as missing);
//   - else (inert): the names, found on PATH; tailscale's absolute path resolved once with
//     `command -v` (kept as found — on NixOS /run/current-system/sw/bin/tailscale, a link that
//     survives updates), and a link opened with Api.openUrl.
// With the seam in use a link is opened by the seam's xdg-open (never Api.openUrl's).
//
// ACTIONS run one at a time (`busy`, `operation`): planned by TailscaleRules (planConnect,
// planDisconnect, planAttend, commandFor), run plainly by absolute path through the API's
// CommandAction; when Tailscale answers "Access denied" and ONLY when the user asked
// (origin "user"), run again through the API's PrivilegedAction (pkexec, the command table's
// description for the prompt). Origin "network" never prompts and never opens a browser:
// it sets `attention` instead. pkexec 126 (dismissed) shows nothing; 127 is `failed` with the
// contract's sentence; any other failure is `failed(what, reason)` with the rules' sentence.
// `tailscale login` runs as a Process of its own (its URL is read while it waits), ended
// after loginTimeoutMs or by cancelLogin().
QtObject {
    id: root

    // ---- Set by the owner ----

    // Acts only while true (Main binds it to module.active); false ends everything
    property bool running: false
    // The module's handle (its store, its settings), or null (a suite's client)
    property var module: null
    // The tools seam (above): "" = decided at start from the environment
    property string toolsDir: ""
    // Added to every process's environment (the suites: the stand-ins' TS_FAKE_* variables)
    property var environment: ({})
    // The clock, for the suites (0: the real one)
    property real fixedNow: 0
    property int readDebounceMs: 150
    property int pollMs: 60000
    property int watchPollMs: 3000
    property int loginTimeoutMs: 10 * 60 * 1000
    property int streamBackoffMinMs: 1000
    property int streamBackoffMaxMs: 30000
    property int resumeGapMs: 30000
    // Open the login page in the browser (setting mod.tailscale.openLoginInBrowser)
    readonly property bool openLoginInBrowser: module ? module.value("openLoginInBrowser") !== false : true

    // An operation failed: a one-off notification "<what> failed" with `reason` (Main
    // forwards it as the provider's failed(entryId, what, reason))
    signal failed(string what, string reason)

    // ---- Tools ----

    // "owner" | "seam" | "test-stand-ins" | "path" ("" before the start)
    property string toolsMode: ""
    property string _tools: ""
    // tailscale's absolute path ("" unknown or missing)
    property string tailscalePath: ""
    // "unknown" | "present" | "missing"
    property string cli: "unknown"

    function tool(name) {
        return _tools !== "" ? _tools + "/" + name : name;
    }

    // ---- State ----

    property var status: null
    property var prefs: null
    // "unknown" | "running" | "not-running"
    property string daemon: "unknown"
    property bool readDenied: false
    // "" | "connect" | "disconnect" | "login" | "logout" | "exit-node" | "setting" | "operator" | "start"
    property string operation: ""
    // The login URL the running login printed or the bus sent; `busAuthUrl` one the bus sent
    // while the module was not logging in (shown, never opened)
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

    // The entries have been read successfully at least once (or there is nothing to read)
    readonly property bool ready: status !== null || cli === "missing" || daemon === "not-running"
    readonly property bool busy: operation !== ""
    readonly property bool canChange: TailscaleRules.canChange(prefs, { userName: userName, uid: uid })
    readonly property string lastTailnet: _lastTailnet !== "" ? _lastTailnet : String(module?.store?.get("lastTailnet", "") ?? "")
    readonly property bool updateManagedBySystem: tailscalePath.startsWith("/run/current-system/") || tailscalePath.startsWith("/nix/store/")
        || tailscalePath.startsWith("/etc/profiles/") || tailscalePath.indexOf("/.nix-profile/") >= 0

    readonly property var facts: ({
        cli: cli === "missing" ? "missing" : "present",
        daemon: daemon === "not-running" ? "not-running" : "running",
        readDenied: readDenied,
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

    // THE provider entry (TailscaleRules.entry, with the attention an action found and the
    // operation's own status line)
    readonly property var entry: {
        const base = TailscaleRules.entry(status, prefs, facts);
        const held = pendingAttention !== null && base.attention === null
            ? { reason: pendingAttention.reason, action: pendingAttention.action } : base.attention;
        const label = _operationLabels[operation] ?? "";
        return Object.assign({}, base, { attention: held, status: label !== "" ? label : base.status, busy: operation !== "" });
    }
    // The view with that attention, for the plans
    readonly property var _planView: pendingAttention !== null && view.attention === null
        ? Object.assign({}, view, { attention: pendingAttention }) : view

    readonly property var devices: status ? TailscaleRules.peers(status, now, {}) : []
    readonly property var exitNodes: TailscaleRules.exitNodes(status, prefs, suggestedId !== "" ? suggestedId : suggestedName)
    readonly property var routeWarnings: status ? TailscaleRules.routeShadowsLan(status, lanSubnets, prefs) : []
    readonly property var warnings: view.warnings.concat(routeWarnings.map(found => ({ kind: "route-shadows-lan", text: found.text })),
        busError !== "" ? [{ kind: "error", text: "Tailscale said: " + busError }] : [])
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
        _admin.elevate = [tool("pkexec")];
        if (_tools === "") {
            // pkexec by its absolute path as well (on NixOS the setuid wrapper, /run/wrappers/bin)
            const generation = _generation;
            _misc.run(["sh", "-c", "command -v pkexec"], result => {
                const found = (result.lines[0] ?? "").trim();
                if (_alive(generation) && found.startsWith("/"))
                    _admin.elevate = [found];
            });
        }
        _resolveCli();
        _readIdentity();
        _readLan();
    }

    function _stop() {
        _generation++;
        _readTimer.stop();
        _streamRestart.stop();
        _loginTimer.stop();
        if (_stream.running)
            _stream.running = false;
        if (_login.running) {
            _loginCancelled = true;
            _login.running = false;
        }
        streamUp = false;
        operation = "";
        _reading = false;
        _readAgain = false;
        _watchers = 0;
    }

    function _alive(generation) {
        return running && generation === _generation;
    }

    function _resolveCli() {
        const generation = _generation;
        const command = _tools !== ""
            ? ["sh", "-c", "[ -x \"$1\" ] && printf '%s\\n' \"$1\"", "sh", _tools + "/tailscale"]
            : ["sh", "-c", "command -v tailscale"];
        _misc.run(command, result => {
            if (!_alive(generation))
                return;
            const found = (result.lines[0] ?? "").trim();
            if (result.ok && found.startsWith("/")) {
                tailscalePath = found;
                cli = "present";
                _scheduleRead(true);
                _startStream();
            } else {
                tailscalePath = "";
                cli = "missing";
            }
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

    // ---- Reading ----

    property bool _reading: false
    property bool _readAgain: false

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
        if (cli === "missing" && running)
            _resolveCli();
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
        reads++;
        const generation = _generation;
        const environment = _environment();
        _reader.run([tailscalePath, "status", "--json"], statusResult => {
            if (!_alive(generation))
                return;
            _reader.run([tailscalePath, "debug", "prefs"], prefsResult => {
                if (!_alive(generation))
                    return;
                _applyRead(statusResult, prefsResult);
                _reading = false;
                if (_readAgain) {
                    _readAgain = false;
                    _scheduleRead();
                }
            }, environment);
        }, environment);
    }

    function _applyRead(statusResult, prefsResult) {
        if (fixedNow <= 0)
            now = Date.now();
        if (statusResult.ok) {
            const parsed = TailscaleRules.parseStatus(statusResult.lines.join("\n"));
            if (parsed.ok) {
                status = parsed;
                daemon = "running";
                readDenied = false;
            }
        } else {
            const error = TailscaleRules.errorKind(statusResult.code, statusResult.error);
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
            const parsed = TailscaleRules.parsePrefs(prefsResult.lines.join("\n"));
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

    function _rememberTailnet() {
        const name = TailscaleRules.tailnetName(status, {});
        if (name !== "" && name !== _lastTailnet) {
            _lastTailnet = name;
            module?.store?.set("lastTailnet", name);
        }
    }

    function _environment() {
        return Object.assign({}, environment ?? {});
    }

    // ---- The event stream ----

    property var _splitter: TailscaleRules.jsonSplitter()
    property real _streamStartedAt: 0
    property int _streamFailures: 0

    function _startStream() {
        if (!running || cli !== "present" || _stream.running)
            return;
        _splitter = TailscaleRules.jsonSplitter();
        _stream.command = [tool("curl"), "-sN", "--unix-socket", TailscaleRules.localApiSocket,
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
            if (operation === "login") {
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

    function disconnect(origin) {
        return _execute(TailscaleRules.planDisconnect(_planView, canChange, _origin(origin)), _origin(origin), "disconnect");
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

    // Runs `command` (a tailscale command from the table) plainly, by absolute path; denied
    // and asked by the user: through pkexec; denied otherwise: attention
    function _runChange(command, origin, operationName) {
        if (tailscalePath === "") {
            failed(command.description, "Tailscale is not installed.");
            return false;
        }
        const plain = [tailscalePath].concat(command.argv.slice(1));
        const generation = _generation;
        operation = operationName;
        _actions.run(plain, result => {
            if (!_alive(generation))
                return;
            if (result.ok) {
                _finish();
                return;
            }
            const error = TailscaleRules.errorKind(result.code, result.error);
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
            const elevated = TailscaleRules.privileged(command.argv, tailscalePath);
            if (!elevated.ok) {
                _finish();
                failed(command.description, elevated.error);
                return;
            }
            _admin.run(elevated.argv.slice(1), command.description, answer => {
                if (!_alive(generation))
                    return;
                _finish();
                if (answer.ok || answer.dismissed)
                    return;
                if (answer.refused)
                    failed(command.description, TailscaleRules.pkexecOutcome(127).message);
                else if (answer.code < 0 || /\bnot found\b|No such file/i.test(answer.error ?? ""))
                    // PrivilegedAction could not run it at all (no pkexec, a path that is gone)
                    failed(command.description, "It could not be run as administrator: pkexec or " + tailscalePath + " was not found.");
                else
                    failed(command.description, TailscaleRules.errorKind(answer.code, answer.error).message);
            }, _environment());
        }, _environment());
        return true;
    }

    function _finish() {
        operation = "";
        _scheduleRead(true);
    }

    // `systemctl start tailscaled.service` (systemd asks polkit itself: no pkexec)
    function _startService() {
        const command = TailscaleRules.commandFor("startService", {});
        const generation = _generation;
        operation = "start";
        _actions.run([tool("systemctl")].concat(command.argv.slice(1)), result => {
            if (!_alive(generation))
                return;
            operation = "";
            if (!result.ok) {
                failed(command.description, (result.error.split("\n")[0] ?? "").trim() || ("systemctl exited with status " + result.code + "."));
                return;
            }
            daemon = "unknown";
            _streamFailures = 0;
            _streamRestart.stop();
            _scheduleRead(true);
            _startStream();
        }, _environment());
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
        _misc.run([tailscalePath, "exit-node", "suggest"], result => {
            if (!_alive(generation))
                return;
            const parsed = TailscaleRules.parseExitNodeSuggest(result.lines.join("\n"));
            if (parsed.name !== "")
                suggestedName = parsed.name;
            done?.();
        }, _environment());
    }

    // ---- Logging in ----

    property string _loginText: ""
    property bool _loginElevated: false
    property bool _loginCancelled: false
    property bool _loginTimedOut: false
    property bool _loginOpened: false
    readonly property bool loggingIn: _login.running

    function _startLogin(origin) {
        if (origin !== "user" || tailscalePath === "")
            return false;
        operation = "login";
        authUrl = "";
        _loginText = "";
        _loginElevated = false;
        _loginCancelled = false;
        _loginTimedOut = false;
        _loginOpened = false;
        _login.command = [tailscalePath, "login"];
        _login.environment = _environment();
        _login.code = -1;
        _login.running = true;
        _loginTimer.restart();
        return true;
    }

    // Ends a login in progress (a login run through pkexec runs as root: it cannot be ended
    // from here, and is only no longer waited for)
    function cancelLogin() {
        if (operation !== "login")
            return;
        _loginCancelled = true;
        if (_login.running)
            _login.running = false;
        else
            _loginDone();
    }

    function _maybeOpenLogin() {
        if (operation === "login" && !_loginOpened && authUrl !== "" && openLoginInBrowser) {
            _loginOpened = true;
            openUrl(authUrl);
        }
    }

    function _onLoginText(data) {
        _loginText = (_loginText + data).slice(-65536);
        const parsed = TailscaleRules.parseLoginOutput(_loginText);
        if (parsed.authUrl !== "" && authUrl === "") {
            authUrl = parsed.authUrl;
            _maybeOpenLogin();
        }
    }

    function _loginExited(code) {
        if (!running)
            return;
        const description = TailscaleRules.commandFor("login", {}).description;
        if (_loginCancelled) {
            _loginDone();
            return;
        }
        if (_loginTimedOut) {
            _loginDone();
            failed(description, "The login was not finished within " + Math.round(loginTimeoutMs / 60000) + " minutes; nothing was changed.");
            return;
        }
        if (code === 0 || TailscaleRules.parseLoginOutput(_loginText).success) {
            _loginDone();
            return;
        }
        if (!_loginElevated) {
            const error = TailscaleRules.errorKind(code, _loginText);
            if (error.kind === "denied") {
                const elevated = TailscaleRules.privileged(["tailscale", "login"], tailscalePath);
                if (elevated.ok) {
                    _loginElevated = true;
                    _loginText = "";
                    _login.command = [_admin.elevate[0]].concat(elevated.argv.slice(1));
                    _login.code = -1;
                    _login.running = true;
                    return;
                }
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

    // ---- Watching (the devices page) ----

    property int _watchers: 0
    readonly property bool watching: _watchers > 0

    function watch() {
        _watchers++;
        _scheduleRead();
    }

    function unwatch() {
        _watchers = Math.max(0, _watchers - 1);
    }

    // ---- Processes and timers ----

    property CommandAction _reader: CommandAction {}
    property CommandAction _actions: CommandAction {}
    property CommandAction _misc: CommandAction {}
    property PrivilegedAction _admin: PrivilegedAction {
        // A failure is the provider's failed(), not PrivilegedAction's notification
        notifyFailures: false
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

    property Process _login: Process {
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._onLoginText(data)
        }
        stderr: SplitParser {
            splitMarker: ""
            onRead: data => root._onLoginText(data)
        }
        property int code: -1
        onExited: (exitCode, exitStatus) => code = exitCode
        // Ended either way (also when the module ends it): handled once the exit code is in
        onRunningChanged: {
            if (!running)
                Qt.callLater(() => root._loginExited(code));
        }
    }

    property Timer _readTimer: Timer {
        interval: root.readDebounceMs
        onTriggered: root._read()
    }

    property Timer _streamRestart: Timer {
        onTriggered: root._startStream()
    }

    property Timer _loginTimer: Timer {
        interval: root.loginTimeoutMs
        onTriggered: {
            if (root._login.running) {
                root._loginTimedOut = true;
                root._login.running = false;
            }
        }
    }

    // The slow poll while the stream is down (and the CLI looked for again while missing)
    property Timer _poll: Timer {
        interval: root.pollMs
        repeat: true
        running: root.running && !root.streamUp
        onTriggered: root.refresh()
    }

    // The traffic while the devices page is open
    property Timer _watchPoll: Timer {
        interval: root.watchPollMs
        repeat: true
        running: root.running && root.watching && root.cli === "present"
        onTriggered: root._scheduleRead()
    }

    // The clock: `now` for the grace of an offline exit node and "last seen"; and a jump in it
    // (the computer slept) re-reads and restarts the stream
    property real _lastTick: Date.now()
    property Timer _clock: Timer {
        interval: 5000
        repeat: true
        running: root.running
        onTriggered: {
            const moment = Date.now();
            const slept = moment - root._lastTick > interval + root.resumeGapMs;
            root._lastTick = moment;
            if (root.fixedNow <= 0)
                root.now = moment;
            if (slept) {
                root._readLan();
                root._scheduleRead(true);
                if (root._stream.running)
                    root._stream.running = false;
                else
                    root._startStream();
            }
        }
    }
}
