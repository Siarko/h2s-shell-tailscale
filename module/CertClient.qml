import QtQuick
import Quickshell
import qs.api

// Certificates' live side (delivery step 5): the operator gets a certificate for this
// computer's MagicDNS name into the module's own folder, as the user (CertRules.script under the
// client's change lock, plainly — never through pkexec: root would write into a folder of the
// user's). The folder: certDir (set by the owner: the suites) or H2S_TAILSCALE_CERT_DIR when
// absolute (the lock bed), else CertRules.certDir(XDG_DATA_HOME, HOME). The certificate's end
// date is read with openssl when it is there. No renewal.
QtObject {
    id: root

    property var client: null
    property string certDir: ""

    readonly property bool running: client !== null && client.running && client.cli === "present"
    readonly property string dir: {
        if (certDir !== "")
            return certDir;
        const seam = String(Quickshell.env("H2S_TAILSCALE_CERT_DIR") ?? "");
        if (seam.startsWith("/"))
            return seam.replace(/\/+$/, "");
        return CertRules.certDir(String(Quickshell.env("XDG_DATA_HOME") ?? ""), String(Quickshell.env("HOME") ?? ""));
    }
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
        const generation = client._generation;
        client._spawn(["sh", "-c", CertRules.checkScript, "sh", files.cert, files.key], 15000, result => {
            if (!client._alive(generation))
                return;
            current = result.out.indexOf("present") >= 0 ? { present: true, expires: CertRules.expiry(result.out) } : { present: false, expires: 0 };
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
        const argv = CertRules.argv(dir, domain, client.timeoutPath, seconds, client.tailscalePath);
        if (argv.length === 0) {
            message = "Not possible here";
            return false;
        }
        message = "";
        return client._runLocked("cert", argv, client._watchdogMs(seconds), result => {
            if (result.ok) {
                current = { present: true, expires: CertRules.expiry(result.out) };
                return;
            }
            message = result.timedOut || result.code === 124 ? TailscaleRules.timeoutMessage("cert", seconds)
                : TailscaleRules.errorKind(result.code, result.err).message;
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
