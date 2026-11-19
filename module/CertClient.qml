import QtQuick
import qs.api

// Certificates' live side (delivery step 5): the operator gets a certificate for this
// computer's MagicDNS name into the module's own folder, as the user (CertRules.script under the
// client's change lock, plainly — never through pkexec: root would write into a folder of the
// user's). The folder: certDir (set by the owner: the suites), else CertRules.certDir of the
// system's data home and home (Api.system, through the client; in module test mode the test
// kit's). The certificate's end date is read with openssl when the module found it. No renewal.
QtObject {
    id: root

    property var client: null
    property string certDir: ""

    readonly property bool running: client !== null && client.running && client.cli === "present"
    readonly property string dir: certDir !== "" ? certDir
        : CertRules.certDir(String(client?.system?.dataHome ?? ""), String(client?.system?.home ?? ""))
    readonly property string domain: CertRules.domainFor(client?.status ?? null)
    readonly property var files: CertRules.files(dir, domain)
    readonly property string problem: CertRules.problem(client?.status ?? null, client?.canChange === true, dir)
    // { present, expires (ms, 0 unknown) } of the files there, null: not looked
    property var current: null
    property string message: ""
    property bool getting: client?.operation === "cert"

    // Looks whether the files are there (when the section shows)
    function check() {
        if (!running || files === null)
            return false;
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
        const argv = CertRules.argv(dir, domain, client.tailscalePath, client.opensslPath);
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

    readonly property Connections _life: Connections {
        target: root.client
        function onRunningChanged() {
            if (!root.client.running) {
                root.current = null;
                root.message = "";
            }
        }
    }
}
