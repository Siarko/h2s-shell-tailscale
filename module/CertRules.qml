pragma Singleton

import QtQuick
import Quickshell

// Certificates (delivery step 5), pure. `tailscale cert --cert-file=F --key-file=K <domain>`
// asks the LocalAPI's cert/ for the pair — write access (root or the operator) or
// TS_PERMIT_CERT_UID (ipn/localapi/cert.go) — and the CLI writes the files ITSELF, as the user
// who runs it: the certificate 0644, the key 0600, each atomically (cli/cert.go writeIfChanged).
// Root writing into a folder the user picked is the pattern step 4 rejected, so: the operator
// only, run as the user, into a folder the module chooses (certDir), never through pkexec. The
// domain is one of status's CertDomains (feature/acme/cert.go: "invalid domain %q; must be one
// of %q" otherwise), never typed. No renewal: the daemon renews its cached certificate when asked
// again; the files are written only when "Get certificate" is clicked.
Singleton {
    id: root

    // The domains this computer may get a certificate for: status's CertDomains, only names
    // that are safe as one file name and argument (no option, no separator)
    function domains(status) {
        const list = Array.isArray(status?.certDomains) ? status.certDomains : [];
        return list.map(name => String(name).replace(/\.$/, "").toLowerCase())
            .filter(name => /^[a-z0-9](?:[a-z0-9-]{0,62})(?:\.[a-z0-9](?:[a-z0-9-]{0,62}))+$/.test(name)).slice(0, 8);
    }

    // The one offered: this computer's own MagicDNS name when it is listed, else none
    function domainFor(status) {
        const own = String(status?.self?.dnsName ?? "").toLowerCase();
        const list = domains(status);
        return list.includes(own) ? own : "";
    }

    // The folder: <data home>/h2s-shell/tailscale/certs ("" when the data home is not absolute)
    function certDir(dataHome, home) {
        const base = typeof dataHome === "string" && dataHome.startsWith("/") ? dataHome
            : (typeof home === "string" && home.startsWith("/") ? home.replace(/\/+$/, "") + "/.local/share" : "");
        return base === "" || /[\u0000-\u001f]/.test(base) ? "" : base.replace(/\/+$/, "") + "/h2s-shell/tailscale/certs";
    }

    function files(dir, domain) {
        return dir === "" || domain === "" ? null : { cert: dir + "/" + domain + ".crt", key: dir + "/" + domain + ".key" };
    }

    // The script that runs as the user: the folder made private (700, the user's own, not a
    // link), then the CLI, then the certificate's end date (openssl, when the module found it:
    // module.programs). Every program by the absolute path given ("": none). Its time limit is
    // the runner's, around the whole script (timeLimits.cert).
    // argv: ["sh", "-c", script, "sh", dir, domain, tailscale, openssl]
    readonly property string script: [
        "dir=$1; domain=$2; tailscale=$3; openssl=$4; umask 077",
        "[ -L \"$dir\" ] && { echo 'h2s: the folder is a link' >&2; exit 3; }",
        "mkdir -p -- \"$dir\" && [ -d \"$dir\" ] && [ ! -L \"$dir\" ] && [ -O \"$dir\" ] || { echo 'h2s: the folder is not usable' >&2; exit 3; }",
        "chmod 700 -- \"$dir\" || exit 3",
        "\"$tailscale\" cert --cert-file=\"$dir/$domain.crt\" --key-file=\"$dir/$domain.key\" \"$domain\" || exit $?",
        "[ -n \"$openssl\" ] && \"$openssl\" x509 -noout -enddate -in \"$dir/$domain.crt\" 2> /dev/null; true"
    ].join("\n")

    // Only the end date of a certificate there (any user may read their own files):
    // ["sh", "-c", checkScript, "sh", cert, key, openssl ("": none)]
    readonly property string checkScript: [
        "[ -f \"$1\" ] && [ -f \"$2\" ] || exit 0",
        "echo present",
        "[ -n \"$3\" ] && \"$3\" x509 -noout -enddate -in \"$1\" 2> /dev/null; true"
    ].join("\n")

    function argv(dir, domain, tailscalePath, opensslPath) {
        if (files(dir, domain) === null || typeof tailscalePath !== "string" || !tailscalePath.startsWith("/"))
            return [];
        const openssl = typeof opensslPath === "string" && opensslPath.startsWith("/") ? opensslPath : "";
        return ["sh", "-c", script, "sh", dir, domain, tailscalePath, openssl];
    }

    // The check's time limit (a look at two files and openssl)
    readonly property int checkLimitMs: 15000

    // The check's argv for the files (files()'s), openssl by its absolute path ("": none)
    function checkArgv(files, opensslPath) {
        if (files === null || typeof files !== "object")
            return [];
        const openssl = typeof opensslPath === "string" && opensslPath.startsWith("/") ? opensslPath : "";
        return ["sh", "-c", checkScript, "sh", String(files.cert), String(files.key), openssl];
    }

    // openssl's "notAfter=Feb 14 12:00:00 2027 GMT" → ms (0 none)
    function expiry(text) {
        const match = /^notAfter=(.+)$/m.exec(String(text ?? ""));
        if (!match)
            return 0;
        const parts = /^([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})\s+GMT$/.exec(match[1].trim());
        if (!parts)
            return 0;
        const month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].indexOf(parts[1]);
        return month < 0 ? 0 : Date.UTC(Number(parts[6]), month, Number(parts[2]), Number(parts[3]), Number(parts[4]), Number(parts[5]));
    }

    // Why it cannot be offered ("" it can): status and the operator
    function problem(status, isOperator, dir) {
        if (status?.backendState !== "Running")
            return "Connect first";
        if (domains(status).length === 0)
            return "HTTPS certificates are off for this tailnet";
        if (domainFor(status) === "")
            return "No certificate name for this device";
        if (!isOperator)
            return "Needs the operator";
        if (dir === "")
            return "No data folder";
        return "";
    }
}
