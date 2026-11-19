import QtQuick
import qs.api

// A handle for a suite's own TailscaleClient (the module's main gets the real one), one per
// scenario. Running as administrator is the module's real handle's (Api.moduleAt):
// `privileged.start` goes to the shell's one queue and its stand-in pkexec, with the
// scenario's stand-in state in the environment the client hands over (module API 1.14, module
// test mode only); each call is recorded on the way (`calls`). What the shell's handle cannot
// vary per scenario is the scenario's own:
//   - `programs` are the stand-ins of this directory (the manifest's testPrograms), as the
//     shell hands them over in module test mode — or what a scenario says (programsIn: one
//     left out, an untrusted one, none yet); `installed` is what the next recheckPrograms()
//     finds (a program installed meanwhile);
//   - `privilegedAvailable` false: as if the shell had no way to run as administrator.
QtObject {
    id: root

    // The stand-ins (tests/stand-in) by absolute path
    readonly property string standIns: String(Qt.resolvedUrl("stand-in")).replace(/^file:\/\//, "").replace(/\/+$/, "")
    // The module's handle, as the shell made it
    readonly property var shellHandle: Api.moduleAt(Qt.resolvedUrl("."))

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

    property bool privilegedAvailable: true
    property string privilegedUnavailableReason: ""

    readonly property QtObject privileged: QtObject {
        readonly property bool available: root.privilegedAvailable && root.shellHandle?.privileged.available === true
        readonly property string unavailableReason: !root.privilegedAvailable ? root.privilegedUnavailableReason
                                                    : String(root.shellHandle?.privileged.unavailableReason ?? "no module handle")
        // Every start(): { argv, what, timeoutMs } (copies)
        property var calls: []

        function start(argv, options) {
            calls = calls.concat([{ argv: Array.from(argv ?? []).map(word => String(word)), what: String(options?.what ?? ""),
                                    timeoutMs: options?.timeoutMs ?? 0 }]);
            return root.shellHandle.privileged.start(argv, options);
        }
    }
}
