pragma Singleton

import QtQuick
import Quickshell

// Certificates (delivery step 5), pure. `tailscale cert --cert-file=F --key-file=K <domain>`
// asks the LocalAPI's cert/ for the pair — write access (root or the operator) or
// TS_PERMIT_CERT_UID (ipn/localapi/cert.go) — and the CLI writes the files ITSELF, as the user
// who runs it: the certificate 0644, the key 0600, each atomically (cli/cert.go writeIfChanged).
// Root writing into a folder the user picked is the pattern step 4 rejected, so: the operator
// only, run as the user, into the module's own data folder (certDir), never through pkexec. The
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

    // The folder: "<the module's data directory>/certs" (module API 1.13, module.dataDirectory:
    // made by the shell, private to the user) — "" when there is none
    function certDir(dataDirectory) {
        return typeof dataDirectory === "string" && dataDirectory.startsWith("/") && !/[\u0000-\u001f\u007f]/.test(dataDirectory)
            ? dataDirectory.replace(/\/+$/, "") + "/certs" : "";
    }

    // Where certificates were kept before the data directory: "<data home>/h2s-shell/tailscale/certs"
    // ("" when the data home is not absolute)
    function oldCertDir(dataHome) {
        return typeof dataHome === "string" && dataHome.startsWith("/") && !/[\u0000-\u001f\u007f]/.test(dataHome)
            ? dataHome.replace(/\/+$/, "") + "/h2s-shell/tailscale/certs" : "";
    }

    // ---- Moving the old folder's certificates into the data directory (once) ----
    //
    // Run as the user (never as root), at the client's start. Only the module's own files move:
    // "<domain>.crt" and "<domain>.key" (a domain as domains() takes it), each a regular file of
    // the user's, not a link. A domain's pair moves together, with mv (the mode and times kept);
    // where the data directory already has a file of the pair that is not older than the old
    // one, the pair stays where it is — a newer file is never overwritten. A link, another
    // user's file or anything else is left alone. The old folder (and the module's folder above
    // it) is removed only once empty; anything left keeps it. The old folder itself a link, or
    // not the user's, or unreadable: nothing moves. One line per file and one for the outcome:
    //   "none" (no old folder), "refused folder-link", "failed <why>", "moved <name>",
    //   "kept <name>" (a newer one there), "refused <name>" (a link, not a regular file, not
    //   the user's), "other <name>" (not a certificate's file), "failed <name>" (mv failed),
    //   "removed" (the old folder is gone)
    // argv: ["sh", "-c", moveScript, "sh", oldDir, newDir]
    readonly property string moveScript: [
        "old=$1; new=$2; umask 077",
        "[ -L \"$old\" ] && { echo 'refused folder-link'; exit 0; }",
        "[ -e \"$old\" ] || { echo none; exit 0; }",
        "[ -d \"$old\" ] && [ -O \"$old\" ] || { echo 'failed not-own-folder'; exit 0; }",
        "[ -r \"$old\" ] && [ -x \"$old\" ] || { echo 'failed unreadable'; exit 0; }",
        "[ -L \"$new\" ] && { echo 'failed target-link'; exit 0; }",
        "mkdir -p -- \"$new\" && [ -d \"$new\" ] && [ -O \"$new\" ] && chmod 700 -- \"$new\" || { echo 'failed target'; exit 0; }",
        "own() { [ -f \"$1\" ] && [ ! -L \"$1\" ] && [ -O \"$1\" ]; }",
        "done_domains=' '",
        "for path in \"$old\"/* \"$old\"/.[!.]*; do",
        "  [ -e \"$path\" ] || [ -L \"$path\" ] || continue",
        "  name=${path##*/}",
        "  case $name in *.crt) domain=${name%.crt} ;; *.key) domain=${name%.key} ;; *) echo \"other $name\"; continue ;; esac",
        "  if ! printf '%s\\n' \"$domain\" | grep -Eqx '[a-z0-9]([a-z0-9-]{0,62})(\\.[a-z0-9]([a-z0-9-]{0,62}))+'; then echo \"other $name\"; continue; fi",
        "  case $done_domains in *\" $domain \"*) continue ;; esac",
        "  done_domains=\"$done_domains$domain \"",
        "  pair=''; keep=''",
        "  for kind in crt key; do",
        "    from=\"$old/$domain.$kind\"; to=\"$new/$domain.$kind\"",
        "    [ -e \"$from\" ] || [ -L \"$from\" ] || continue",
        "    if ! own \"$from\"; then echo \"refused $domain.$kind\"; keep=1; continue; fi",
        "    if [ -e \"$to\" ] || [ -L \"$to\" ]; then { own \"$to\" && [ \"$from\" -nt \"$to\" ]; } || keep=1; fi",
        "    pair=\"$pair $kind\"",
        "  done",
        "  for kind in $pair; do",
        "    if [ -n \"$keep\" ]; then echo \"kept $domain.$kind\"; continue; fi",
        "    if mv -f -- \"$old/$domain.$kind\" \"$new/$domain.$kind\"; then echo \"moved $domain.$kind\"; else echo \"failed $domain.$kind\"; fi",
        "  done",
        "done",
        "rmdir -- \"$old\" 2> /dev/null && { echo removed; rmdir -- \"${old%/*}\" 2> /dev/null; }",
        "true"
    ].join("\n")

    // The move's argv, or [] when either folder is not known (not absolute) or both are one
    function moveArgv(oldDir, newDir) {
        const absolute = path => typeof path === "string" && path.startsWith("/") && !/[\u0000-\u001f\u007f]/.test(path);
        if (!absolute(oldDir) || !absolute(newDir) || oldDir.replace(/\/+$/, "") === newDir.replace(/\/+$/, ""))
            return [];
        return ["sh", "-c", moveScript, "sh", oldDir, newDir];
    }

    // The move's answer (the runner's result) → { moved, kept, refused, other, failed (counts),
    // removed (the old folder is gone), done (nothing left to move), log: null (nothing to say)
    // | { level, text } } — counts only, never a name (a certificate's name is the tailnet's)
    function moveOutcome(result) {
        const counts = { moved: 0, kept: 0, refused: 0, other: 0, failed: 0, removed: false, done: false, log: null };
        if (!result || result.ok !== true) {
            counts.log = { level: "warn", text: "certificates: the old folder could not be looked at; they stay there" };
            return counts;
        }
        let why = "";
        let none = false;
        for (const line of String(result.stdout ?? "").split("\n")) {
            const word = line.split(" ")[0];
            if (line === "none")
                none = true;
            else if (line === "removed")
                counts.removed = true;
            else if (line === "refused folder-link")
                why = "the old folder is a link";
            else if (word === "failed" && /^failed [a-z-]+$/.test(line))
                why = { "not-own-folder": "the old folder is not yours", "unreadable": "the old folder cannot be read",
                        "target-link": "the data folder is a link", "target": "the data folder cannot be made" }[line.slice(7)] ?? "it failed";
            else if (["moved", "kept", "refused", "other", "failed"].includes(word))
                counts[word]++;
        }
        if (none)
            return Object.assign(counts, { done: true });
        if (why !== "") {
            counts.log = { level: "warn", text: "certificates: not moved to the data folder (" + why + "); they stay in the old folder" };
            return counts;
        }
        const left = counts.kept + counts.refused + counts.other + counts.failed;
        counts.done = left === 0;
        const parts = [];
        if (counts.moved > 0)
            parts.push(counts.moved + (counts.moved === 1 ? " file" : " files") + " moved to the data folder");
        if (counts.kept > 0)
            parts.push(counts.kept + " left in the old folder (a newer one is in the data folder)");
        if (counts.refused + counts.failed > 0)
            parts.push((counts.refused + counts.failed) + " left in the old folder (a link, not yours, or it could not be moved)");
        if (counts.other > 0)
            parts.push(counts.other + " other " + (counts.other === 1 ? "file" : "files") + " left in the old folder");
        if (parts.length > 0)
            counts.log = { level: left > 0 ? "warn" : "info", text: "certificates: " + parts.join("; ") };
        return counts;
    }

    function files(dir, domain) {
        return dir === "" || domain === "" ? null : { cert: dir + "/" + domain + ".crt", key: dir + "/" + domain + ".key" };
    }

    // The script that runs as the user: the folder made private (700, the user's own, not a
    // link), then the CLI under coreutils' timeout (when the module found it), then the
    // certificate's end date (openssl, when found). Every program by the absolute path given
    // ("": none). The runner's limit (timeLimits.cert) is around the whole script, but where
    // the runner keeps it with its own timer (no root-owned timeout and setpriv) only `sh` is
    // signalled: the script's own timeout is what then ends `tailscale cert`, which would
    // otherwise run on after the limit.
    // argv: ["sh", "-c", script, "sh", dir, domain, timeout, seconds, tailscale, openssl]
    readonly property string script: [
        "dir=$1; domain=$2; limit=$3; seconds=$4; tailscale=$5; openssl=$6; umask 077",
        "[ -L \"$dir\" ] && { echo 'h2s: the folder is a link' >&2; exit 3; }",
        "mkdir -p -- \"$dir\" && [ -d \"$dir\" ] && [ ! -L \"$dir\" ] && [ -O \"$dir\" ] || { echo 'h2s: the folder is not usable' >&2; exit 3; }",
        "chmod 700 -- \"$dir\" || exit 3",
        "if [ -n \"$limit\" ]; then \"$limit\" -k 5 \"$seconds\" \"$tailscale\" cert --cert-file=\"$dir/$domain.crt\" --key-file=\"$dir/$domain.key\" \"$domain\" || exit $?",
        "else \"$tailscale\" cert --cert-file=\"$dir/$domain.crt\" --key-file=\"$dir/$domain.key\" \"$domain\" || exit $?; fi",
        "[ -n \"$openssl\" ] && \"$openssl\" x509 -noout -enddate -in \"$dir/$domain.crt\" 2> /dev/null; true"
    ].join("\n")

    // Only the end date of a certificate there (any user may read their own files):
    // ["sh", "-c", checkScript, "sh", cert, key, openssl ("": none)]
    readonly property string checkScript: [
        "[ -f \"$1\" ] && [ -f \"$2\" ] || exit 0",
        "echo present",
        "[ -n \"$3\" ] && \"$3\" x509 -noout -enddate -in \"$1\" 2> /dev/null; true"
    ].join("\n")

    // The script's argv; timeout and openssl by absolute path, else "" (none); `seconds` the
    // script's own limit on `tailscale cert` (1 to 86400)
    function argv(dir, domain, timeoutPath, seconds, tailscalePath, opensslPath) {
        if (files(dir, domain) === null || typeof tailscalePath !== "string" || !tailscalePath.startsWith("/"))
            return [];
        if (typeof seconds !== "number" || !Number.isInteger(seconds) || seconds < 1 || seconds > 86400)
            return [];
        const absolute = path => typeof path === "string" && path.startsWith("/") ? path : "";
        return ["sh", "-c", script, "sh", dir, domain, absolute(timeoutPath), String(seconds), tailscalePath, absolute(opensslPath)];
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
