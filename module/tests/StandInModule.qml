import QtQuick
import qs.api

// A module handle for a suite's own TailscaleClient (the module's main gets the real one):
// what the client takes from its handle, with a scenario's own state. The real handle's
// programs and runs as administrator are one per module, in the shell's one environment, and
// the live suites run many scenarios at once, each with its own stand-in state (TS_FAKE_* in
// the client's `environment`); so here
//   - `programs` are the stand-ins of this directory (the manifest's testPrograms), as the
//     shell hands them over in module test mode — or what a scenario says (programsIn:
//     one left out, an untrusted one, none yet); `installed` is what the next
//     recheckPrograms() finds (a program installed meanwhile);
//   - `privileged` stands in for the shell's module.privileged: start(argv, options) records
//     the call (`calls`: { argv, what, timeoutMs }) and runs it as the shell would — the
//     stand-in pkexec, a timeout inside it — with the scenario's environment, and answers
//     with the shell's result shape (126 dismissed, 127 refused, 124/137 timed out). The
//     shell's own queue, prompt and timeout are checked where the real handle is used: the
//     module suite (TailscaleModuleTest) and the lock bed.
QtObject {
    id: root

    // The stand-ins (tests/stand-in) by absolute path
    readonly property string standIns: String(Qt.resolvedUrl("stand-in")).replace(/^file:\/\//, "").replace(/\/+$/, "")

    // The programs as the module names them (module.json's optionalPrograms), each the
    // stand-in of that name — trusted, as the shell's test mode hands them over. options:
    // { without: a name left out (path ""), untrusted: a name judged untrusted, missing: true
    // (none found) }
    function programsIn(options) {
        const names = ["tailscale", "timeout", "curl", "systemctl", "openssl", "pkexec"];
        const result = {};
        for (const name of names) {
            const absent = options?.missing === true || options?.without === name;
            const untrusted = options?.untrusted === name;
            result[name] = Object.freeze({ path: absent ? "" : standIns + "/" + name, trusted: !absent && !untrusted,
                                           reason: absent ? "not found" : untrusted ? "others than root can change " + standIns + "/" + name : "test stand-in" });
        }
        return Object.freeze(result);
    }

    property var programs: programsIn({})
    property bool programsReady: true
    // What the next recheckPrograms() finds (null: the same as now)
    property var installed: null
    property int rechecks: 0

    function recheckPrograms() {
        rechecks++;
        if (installed !== null) {
            programs = installed;
            installed = null;
        }
    }

    signal resumed()
    readonly property var store: null
    function value(key) {
        return undefined;
    }

    // The scenario's stand-in environment, for the runs as administrator
    property var environment: ({})

    readonly property QtObject privileged: QtObject {
        id: privilegedRuns
        property bool available: true
        property string unavailableReason: ""
        // Every start(): { argv, what, timeoutMs } (copies)
        property var calls: []

        function start(argv, options) {
            const words = Array.from(argv ?? []).map(word => String(word));
            calls = calls.concat([{ argv: words, what: String(options?.what ?? ""), timeoutMs: options?.timeoutMs ?? 0 }]);
            const handle = { running: true, cancel: () => {} };
            const answer = result => {
                handle.running = false;
                const done = options?.done;
                Qt.callLater(() => done?.(Object.freeze(result)));
            };
            const base = { ok: false, code: -1, stdout: "", stderr: "", dismissed: false, refused: false, notFound: false,
                           timedOut: false, cancelled: false, blocked: "", error: "" };
            if (!privilegedRuns.available) {
                answer(Object.assign({}, base, { error: "not available: " + privilegedRuns.unavailableReason }));
                return handle;
            }
            if (String(options?.what ?? "").trim() === "") {
                answer(Object.assign({}, base, { blocked: "no-purpose" }));
                return handle;
            }
            if (words.length === 0 || !words[0].startsWith("/")) {
                answer(Object.assign({}, base, { notFound: true }));
                return handle;
            }
            // As the shell hands it to pkexec: <pkexec> <timeout> -k 3 <limit> <argv…>
            const seconds = Math.max(1, Math.ceil((options?.timeoutMs ?? 1000) / 1000));
            let cancelled = false;
            const run = root._runner.start([root.standIns + "/pkexec", root.standIns + "/timeout", "-k", "3", String(seconds)].concat(words), {
                timeoutMs: 0, keepOutput: true, environment: root.environment,
                onStdout: text => {
                    if (!cancelled)
                        options?.onStdout?.(text);
                },
                onStderr: text => {
                    if (!cancelled)
                        options?.onStderr?.(text);
                },
                done: result => {
                    handle.running = false;
                    const code = result.code;
                    const mapped = Object.assign({}, base, {
                        ok: result.ok === true && !cancelled, code: code, stdout: result.stdout ?? "", stderr: result.stderr ?? "",
                        cancelled: cancelled || result.cancelled === true, dismissed: !cancelled && code === 126,
                        refused: !cancelled && code === 127, timedOut: !cancelled && (code === 124 || code === 137)
                    });
                    options?.done?.(Object.freeze(mapped));
                }
            });
            handle.cancel = () => {
                cancelled = true;
                run.cancel();
            };
            return handle;
        }
    }

    property CommandRunner _runner: CommandRunner {}
}
