import QtQuick

// A module handle for a suite's own TailscaleClient (the module's main gets the real one):
// what the client takes from its handle, with a scenario's own programs. `programs` are the
// stand-ins of this directory (the manifest's testPrograms), as the shell hands them over in
// module test mode — or what a scenario says (programsIn: one left out, an untrusted one,
// none yet); `installed` is what the next recheckPrograms() finds (a program installed
// meanwhile).
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
}
