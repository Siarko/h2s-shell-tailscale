import QtQuick
import Quickshell
import qs.api

// Serve and Funnel's live side (delivery step 5): I/O only, every decision ServeRules'. Made by
// the live client (TailscaleClient.serve), on its runner and its change lock.
//
// READING: `serve status --json` (any user may) when the page's Serve section is on screen,
// after each change, and on refresh(). No polling: the bus says nothing about the serve config.
// CHANGING: every click is an INTENT (add, remove, Funnel on/off, reset). Under the change lock
// it is planned again from prefs (the profile: a switch since the click aborts, "Changed
// meanwhile") and the serve config read right then — before the plain run and again before the
// retry through pkexec (the client's `prepare`) —, because a Funnel switch sends the entry's
// handler again and must send what is there now. A user's click may ask for a password (root
// runs `tailscale serve …` with the module's own argv: a local port or the entry's own proxy
// URL, never a path); nothing else does.
QtObject {
    id: root

    property var client: null

    readonly property bool running: client !== null && client.running && client.cli === "present"
    // ServeRules.parseConfig's, null: not read
    property var config: null
    property string readError: ""
    property bool reading: false
    property int reads: 0
    // The last change's outcome, for the page ("" none): one short line
    property string message: ""
    readonly property var ready: ServeRules.preconditions(client?.status ?? null, client?.prefs ?? null)
    readonly property var entries: config !== null ? ServeRules.entriesFor(config, client?.status ?? null) : []

    function _seconds() {
        return client._limit("read");
    }

    // Reads the config (one read at a time) → done(parsed) when given
    function read(done) {
        if (!running || reading)
            return false;
        reading = true;
        const generation = client._generation;
        client._spawn(client._timedArgv(TailscaleRules.commandFor("serveStatus", {}), _seconds()), client._watchdogMs(_seconds()), result => {
            reading = false;
            if (!client._alive(generation))
                return;
            reads++;
            if (!result.ok) {
                readError = TailscaleRules.errorKind(result.code, result.err).message;
                done?.(null);
                return;
            }
            const parsed = ServeRules.parseConfig(result.out);
            readError = parsed.ok ? "" : "Tailscale's answer could not be read";
            if (parsed.ok)
                config = parsed;
            done?.(parsed.ok ? parsed : null);
        });
        return true;
    }

    // For the change in flight (`token`): prefs, then the config, read now → done(prefs, config)
    function _readFresh(token, done) {
        const generation = client._generation;
        client._readPrefsNow(token, fresh => {
            client._opProcess = client._spawn(client._timedArgv(TailscaleRules.commandFor("serveStatus", {}), _seconds()), client._watchdogMs(_seconds()), result => {
                if (!client._alive(generation) || token !== client._opToken)
                    return;
                    client._opProcess = null;
                const parsed = ServeRules.parseConfig(result.ok ? result.out : "");
                if (parsed.ok)
                    config = parsed;
                done(fresh, parsed);
            });
        });
    }

    function _command(plan) {
        return { ok: true, error: "", name: "serve", argv: plan.argv, changes: true, privileged: true, description: plan.description, timeLimit: "change" };
    }

    // The page's actions (origin "user" unless the IPC asks)
    function add(intent, origin) {
        return _change(Object.assign({ action: "add" }, intent ?? {}), origin);
    }

    function remove(key, origin) {
        return _change({ action: "remove", key: key }, origin);
    }

    function setFunnel(key, on, origin) {
        return _change({ action: "funnel", key: key, on: on === true }, origin);
    }

    function reset(origin) {
        return _change({ action: "reset" }, origin);
    }

    function _change(intent, origin) {
        if (!running || client.busy)
            return false;
        const first = ServeRules.planIntent(intent, config, client.status, client.prefs, "", "");
        if (first.kind !== "run") {
            message = first.kind === "nothing" ? "" : first.error;
            return false;
        }
        message = "";
        client.pendingAttention = null;
        const identity = TailscaleRules.prefsIdentity(client.prefs);
        const prepare = (token, go) => _readFresh(token, (fresh, parsed) => {
            const plan = ServeRules.planIntent(intent, parsed, client.status, fresh, identity, TailscaleRules.prefsIdentity(fresh));
            if (plan.kind === "run") {
                go(_command(plan));
                return;
            }
            client._finish();
            message = plan.kind === "nothing" ? "" : plan.error;
        });
        return client._runChange(_command(first), client._origin(origin ?? "user"), "serve", () => read(), prepare, outcome => {
            if (!outcome.ok && !outcome.dismissed)
                message = outcome.message;
            read();
        });
    }

    function _reset() {
        config = null;
        readError = "";
        reading = false;
        message = "";
    }

    readonly property Connections _life: Connections {
        target: root.client
        function onRunningChanged() {
            if (!root.client.running)
                root._reset();
        }
    }
}
