import QtQuick
import qs.api

// Certificates' live side (delivery step 5): the operator gets a certificate for this
// computer's MagicDNS name into the module's own folder, as the user (CertRules.script under the
// client's change lock, plainly — never through pkexec: root would write into a folder of the
// user's). The folder: certDir (set by the owner: the suites), else CertRules.certDir of the
// module's data directory (module API 1.13, the handle's dataDirectory; in module test mode a
// private temporary one). At the client's start, certificates in the folder used before
// (CertRules.oldCertDir of the system's data home) are moved there once (CertRules.moveScript,
// as the user), and the outcome logged once (module.log). The certificate's end date is read
// with openssl when the module found it. No renewal.
QtObject {
    id: root

    property var client: null
    property string certDir: ""

    readonly property bool running: client !== null && client.running && client.cli === "present"
    readonly property string dir: certDir !== "" ? certDir : CertRules.certDir(String(client?.module?.dataDirectory ?? ""))
    // The folder used before the data directory
    readonly property string oldDir: CertRules.oldCertDir(String(client?.system?.dataHome ?? ""))
    readonly property string domain: CertRules.domainFor(client?.status ?? null)
    readonly property var files: CertRules.files(dir, domain)
    readonly property string problem: CertRules.problem(client?.status ?? null, client?.canChange === true, dir)
    // { present, expires (ms, 0 unknown) } of the files there, null: not looked
    property var current: null
    property string message: ""
    property bool getting: client?.operation === "cert"

    // The move from the old folder: CertRules.moveOutcome's answer (null: not run yet), and
    // whether it runs; how many log lines it wrote (for the suites)
    property var moved: null
    property bool moving: false
    property int moveLogs: 0
    property bool _checkAfterMove: false

    // Moves the old folder's certificates into the data folder (CertRules.moveScript, as the
    // user, never through pkexec) → false when there is nothing to run (a folder not known)
    function moveOld() {
        const argv = CertRules.moveArgv(oldDir, dir);
        if (client === null || moving || argv.length === 0)
            return false;
        moving = true;
        client._run(argv, CertRules.checkLimitMs, result => {
            moving = false;
            const outcome = CertRules.moveOutcome(result);
            moved = outcome;
            if (outcome.log !== null && typeof client.module?.log === "function"
                    && client.module.log(outcome.log.level, outcome.log.text, "certificate move") === true)
                moveLogs++;
            if (_checkAfterMove) {
                _checkAfterMove = false;
                check();
            }
        });
        return true;
    }

    // Looks whether the files are there (when the section shows; after the move when it runs)
    function check() {
        if (!running || files === null)
            return false;
        if (moving) {
            _checkAfterMove = true;
            return true;
        }
        client._run(CertRules.checkArgv(files, client.opensslPath), CertRules.checkLimitMs, result => {
            current = result.stdout.indexOf("present") >= 0 ? { present: true, expires: CertRules.expiry(result.stdout) } : { present: false, expires: 0 };
        });
        return true;
    }

    function get() {
        if (!running || client.busy)
            return false;
        if (problem !== "") {
            message = problem;
            return false;
        }
        const seconds = client._limit("cert");
        const argv = CertRules.argv(dir, domain, client.timeoutPath, seconds, client.tailscalePath, client.opensslPath);
        if (argv.length === 0) {
            message = "Not possible here";
            return false;
        }
        message = "";
        return client._runLocked("cert", argv, seconds * 1000, result => {
            if (result.ok) {
                current = { present: true, expires: CertRules.expiry(result.stdout) };
                return;
            }
            message = result.timedOut ? TailscaleRules.timeoutMessage("cert", seconds) : TailscaleRules.runError(result).message;
        });
    }

    // A client running before this was complete: its start was not seen below
    Component.onCompleted: {
        if (client?.running === true)
            Qt.callLater(moveOld);
    }

    readonly property Connections _life: Connections {
        target: root.client
        function onRunningChanged() {
            if (!root.client.running) {
                root.current = null;
                root.message = "";
                root.moving = false;
                root._checkAfterMove = false;
            } else {
                root.moveOld();
            }
        }
    }
}
