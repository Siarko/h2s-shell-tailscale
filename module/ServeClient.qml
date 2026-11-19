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
// URL, never a path); nothing else does. Funnel is per host:port, so the planning (in both
// passes) refuses to make public a port that holds anything the module would not send itself
// (ServeRules.publicProblem): a retry as root never publishes a path handler.
// The CLI still does its own read-modify-write after the plan (through pkexec: after the
// password dialog), so after Funnel went on the config is read once more and, when the port now
// holds more than the plan allowed, Funnel is turned off again at once and the user told
// (ServeRules.publicCheck) — asking for a password only right after the click's own change;
// a check that had to wait for another change never asks, and when it would need to, the
// page offers "Turn off Funnel" (funnelOffNeeded, turnFunnelOff()). Writing the config through the LocalAPI with If-Match would close
// that gap, but POST serve-config needs root or the operator: everyone else would have to run a
// whole config, composed here, through pkexec.
QtObject {
    id: root

    property var client: null

    readonly property bool running: client !== null && client.running && client.cli === "present"
    // ServeRules.parseConfig's, null: not read
    property var config: null
    property string readError: ""
    property bool reading: false
    // Funnel just went on: the config is being checked (and Funnel turned off again if needed)
    property bool checking: false
    property int reads: 0
    // The last change's outcome, for the page ("" none): one short line
    property string message: ""
    // Funnel found on a port holding more than planned, and not turned off (it needed a
    // password the check may not ask for, the prompt was dismissed, or it failed): { port },
    // null none. The page offers "Turn off Funnel" (turnFunnelOff)
    property var funnelOffNeeded: null
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
        _readConfig(parsed => {
            reading = false;
            done?.(parsed);
        });
        return true;
    }

    // One read of the config, whatever else is reading → done(parsed | null); nothing when the
    // client stopped meanwhile
    function _readConfig(done) {
        const generation = client._generation;
        client._spawn(client._timedArgv(TailscaleRules.commandFor("serveStatus", {}), _seconds()), client._watchdogMs(_seconds()), result => {
            if (!client._alive(generation)) {
                reading = false;
                checking = false;
                return;
            }
            reads++;
            if (!result.ok) {
                readError = TailscaleRules.plainText(TailscaleRules.errorKind(result.code, result.err).message, 300);
                done(null);
                return;
            }
            const parsed = ServeRules.parseConfig(result.out);
            readError = parsed.ok ? "" : "Tailscale's answer could not be read";
            if (parsed.ok)
                config = parsed;
            done(parsed.ok ? parsed : null);
        });
    }

    // For the change in flight (`token`): prefs, then the config, read now → done(prefs, config)
    function _readFresh(token, done) {
        const generation = client._generation;
        client._readPrefsNow(token, fresh => {
            client._opProcess = client._spawn(client._timedArgv(TailscaleRules.commandFor("serveStatus", {}), _seconds()), client._watchdogMs(_seconds()), result => {
                if (!client._alive(generation) || token !== client._opToken)
                    return;
                client._opProcess = null;
                // A failed read is not an empty config: planning on "nothing shared" would miss
                // what is on a port (Funnel is per port) — not ok, so nothing is planned on it
                if (!result.ok) {
                    readError = TailscaleRules.plainText(TailscaleRules.errorKind(result.code, result.err).message, 300);
                    done(fresh, { ok: false, error: readError, entries: [] });
                    return;
                }
                const parsed = ServeRules.parseConfig(result.out);
                if (parsed.ok)
                    config = parsed;
                done(fresh, parsed);
            });
        });
    }

    function _command(plan) {
        return { ok: true, error: "", name: "serve", argv: plan.argv, changes: true, privileged: true, description: plan.description, what: plan.what,
                 timeLimit: "change" };
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

    // The page's "Turn off Funnel" for funnelOffNeeded: the check again, at the user's click —
    // which may ask for the password
    function turnFunnelOff() {
        const pending = funnelOffNeeded;
        if (!running || client.busy || checking || pending === null)
            return false;
        funnelOffNeeded = null;
        message = "";
        // No waiting for another change: the password is asked now or not at all
        _checkPublic(pending.port, "user", funnelCheckTries);
        return true;
    }

    function _change(intent, origin) {
        if (!running || client.busy || checking)
            return false;
        const first = ServeRules.planIntent(intent, config, client.status, client.prefs, "", "");
        if (first.kind !== "run") {
            message = first.kind === "nothing" ? "" : first.error;
            return false;
        }
        message = "";
        client.pendingAttention = null;
        const identity = TailscaleRules.prefsIdentity(client.prefs);
        const asked = client._origin(origin ?? "user");
        // The plan that ran last: the one made again under the lock, when there was one
        let ran = first;
        const prepare = (token, go) => _readFresh(token, (fresh, parsed) => {
            const plan = ServeRules.planIntent(intent, parsed, client.status, fresh, identity, TailscaleRules.prefsIdentity(fresh));
            if (plan.kind === "run") {
                ran = plan;
                go(_command(plan));
                return;
            }
            client._finish();
            message = plan.kind === "nothing" ? "" : plan.error;
        });
        return client._runChange(_command(first), asked, "serve", null, prepare, outcome => {
            // The CLI's words as plain text (TailscaleRules.plainText), as on the entry
            if (!outcome.ok && !outcome.dismissed)
                message = TailscaleRules.plainText(outcome.message, 300);
            // Checked whatever the outcome but a dismissed prompt (nothing was sent then): a
            // `funnel` ended by its time limit may have written its config before it was stopped
            if (ran.publicPort > 0 && !outcome.dismissed)
                _checkPublic(ran.publicPort, asked, 1);
            else
                read();
        });
    }

    // How often the check after a Funnel waits for another change to end before it gives up
    property int funnelCheckTries: 5
    // The check waiting for the change lock: { port, tries }, null none
    property var _checkWaiting: null

    // After Funnel went on for `port`: the config read again and checked (ServeRules.publicCheck);
    // a port that now holds more than the plan allowed has Funnel turned off at once, with the
    // click's origin (a user's click may ask for the password again; anything else never does),
    // and the user is told (ServeRules.funnelOffOutcome; a dismissed prompt tells nothing). No
    // change of this page starts meanwhile (`checking`); a change from elsewhere holding the lock
    // is waited for, and the check is made again once it ended, at most funnelCheckTries times —
    // never asking for a password then: the click is over, and when one is needed the page
    // offers "Turn off Funnel" (funnelOffNeeded)
    function _checkPublic(port, origin, tries) {
        checking = true;
        _readConfig(parsed => {
            if (!checking)
                return;
            const check = ServeRules.publicCheck(parsed, port, client.status, client.prefs);
            if (check.kind === "nothing") {
                checking = false;
                return;
            }
            if (check.kind !== "run") {
                checking = false;
                _tell(check.error);
                return;
            }
            if (client.busy) {
                if (tries >= funnelCheckTries) {
                    checking = false;
                    funnelOffNeeded = { port: port };
                    _tell(ServeRules.funnelNotice("failed", port));
                    return;
                }
                _checkWaiting = { port: port, tries: tries + 1 };
                return;
            }
            const prepare = (token, go) => _readFresh(token, (fresh, again) => {
                const plan = ServeRules.publicCheck(again, port, client.status, fresh);
                if (plan.kind === "run") {
                    go(_command(plan));
                    return;
                }
                client._finish();
                checking = false;
                if (plan.kind !== "nothing")
                    _tell(plan.error);
            });
            // Not busy (checked just above, nothing runs in between): every way it ends comes
            // through onEnd
            client._runChange(_command(check), origin, "serve", null, prepare, outcome => {
                checking = false;
                const result = ServeRules.funnelOffOutcome(outcome, origin === "user");
                funnelOffNeeded = result.offer ? { port: port } : null;
                if (result.notice !== "")
                    _tell(ServeRules.funnelNotice(result.notice, port));
                read();
            });
        });
    }

    function _tell(text) {
        message = text;
        client.failed(ServeRules.funnelNoticeTitle, text);
    }

    readonly property Connections _lock: Connections {
        target: root.client
        function onBusyChanged() {
            const waiting = root._checkWaiting;
            if (root.client.busy || waiting === null)
                return;
            root._checkWaiting = null;
            // Not the click's any more: never a password prompt from here
            root._checkPublic(waiting.port, "network", waiting.tries);
        }
    }
    function _reset() {
        config = null;
        readError = "";
        reading = false;
        checking = false;
        _checkWaiting = null;
        funnelOffNeeded = null;
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
