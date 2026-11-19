pragma Singleton

import QtQuick
import Quickshell
import qs.api

// Taildrop's pure rules (delivery step 4): which devices can receive, the files to send
// (paths checked before anything runs), the bus's file fields (FilesWaiting, IncomingFiles,
// OutgoingFiles), received names made safe, the waiting list, the save script and its
// output, the download folder. No I/O: TaildropClient.qml runs what these decide; suite
// tests/TaildropTest.qml.
//
// WHAT TAILSCALE ALLOWS (tailscale 1.104.4's source, feature/taildrop/localapi.go and
// ipn/ipnauth/ipnauth.go IsReadonlyConn): the LocalAPI's file-put (sending) and files/
// (listing, fetching, deleting received files) need WRITE access — root, or the profile's
// operator; any other user is refused ("file access denied", 403). file-targets and the
// bus need only read access. `tailscale file cp` / `file get` open and write the files
// themselves, with the caller's own uid (cli/file.go). So Taildrop is the operator's, run as
// the user, never through pkexec: a root send would open the chosen paths long after any
// check (a swapped file or parent link: root reads and sends what the user cannot), a root
// receive would leave root's files in the user's folder.
Singleton {
    id: root

    readonly property var conflictPolicies: ["rename", "overwrite", "skip"]
    readonly property string defaultConflict: "rename"
    readonly property var conflictLabels: ({ rename: "Keep both", overwrite: "Replace", skip: "Leave waiting" })
    // At most this many files in one send (the CLI sends them one after another)
    readonly property int maxFiles: 32
    // A received name is cut to this many UTF-8 bytes (a filesystem's limit is 255; room is
    // left for " (99)" when a name is taken)
    readonly property int maxNameBytes: 200

    // ---- Small helpers ----

    function _isObject(value) {
        return value !== null && typeof value === "object" && !Array.isArray(value);
    }

    function _get(object, key) {
        if (!_isObject(object) || !Object.prototype.hasOwnProperty.call(object, key))
            return undefined;
        try {
            return object[key];
        } catch (error) {
            return undefined;
        }
    }

    function _string(value, limit) {
        return typeof value === "string" ? value.slice(0, limit ?? 4096) : "";
    }

    function _number(value, fallback) {
        return typeof value === "number" && isFinite(value) ? value : fallback;
    }

    function _utf8Bytes(text) {
        let bytes = 0;
        for (const character of text) {
            const code = character.codePointAt(0);
            bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
        }
        return bytes;
    }

    // Control characters (C0, DEL, C1) and the invisible ones that reorder or hide text (bidi
    // controls, zero-width marks, the BOM): never in a name shown or written
    readonly property var _unsafeCharacters: /[\u0000-\u001f\u007f-\u009f؜​-‏‪-‮⁠-⁩﻿￹-￻]/g

    // ---- Who can receive ----

    // The devices a file can be sent to (TailscaleRules.peers' entries): Tailscale's own
    // verdict per peer (status's TaildropTarget — computed by the same rules as the LocalAPI's
    // file-targets: the same user's devices and those shared with file sharing; ipnstate
    // TaildropTargetStatus): 1 available, 5 offline (listed, not offered). Any other reason:
    // not a target at all. → [{ id, name, online, available, note, argument }]
    function targets(devices) {
        const list = [];
        for (const device of Array.isArray(devices) ? devices : []) {
            if (!_isObject(device))
                continue;
            const online = device.canReceiveFiles === true;
            const offline = !online && device.fileSharingNote === "offline";
            if (!online && !offline)
                continue;
            const argument = targetArgument(device);
            list.push({
                id: _string(device.id, 128), name: _string(device.name, 128), online: online,
                available: online && argument !== "",
                note: offline ? "offline" : (argument === "" ? "no address" : ""),
                argument: argument
            });
        }
        return list;
    }

    // What `tailscale file cp … <argument>:` gets for a device: its IPv4 address in the
    // tailnet's range (never ambiguous, never an option), "" when it has none
    function targetArgument(device) {
        const ipv4 = _string(device?.ipv4, 15);
        return Api.address.isIpv4(ipv4) && Api.address.contains("100.64.0.0/10", ipv4) ? ipv4 : "";
    }

    // ---- Files to send ----

    // Why a path is not sent ("" when it may be checked): absolute, no control characters,
    // no "." or ".." component, not a folder by its spelling
    function pathProblem(path) {
        if (typeof path !== "string" || path === "")
            return "no path";
        if (!path.startsWith("/"))
            return "not an absolute path";
        if (path.length > 4096)
            return "too long";
        if (/[\u0000-\u001f\u007f]/.test(path))
            return "control characters in the path";
        if (path.endsWith("/"))
            return "a folder";
        const parts = path.split("/").slice(1);
        if (parts.some(part => part === "." || part === ".."))
            return "\".\" or \"..\" in the path";
        return "";
    }

    // Paths from pasted text or a drop: one per line, or file:// URLs (decoded); blank lines
    // and duplicates dropped → { paths [], problems [{ text, problem }] }
    function parsePaths(input) {
        const items = Array.isArray(input) ? input.map(item => String(item)) : String(input ?? "").split(/\r?\n/);
        const paths = [];
        const problems = [];
        for (const raw of items) {
            let text = raw.trim();
            if (text === "")
                continue;
            if (/^file:/i.test(text)) {
                const match = /^file:\/\/(localhost)?(\/[^?#]*)$/i.exec(text);
                if (!match) {
                    problems.push({ text: text.slice(0, 200), problem: "not a local file" });
                    continue;
                }
                try {
                    text = decodeURIComponent(match[2]);
                } catch (error) {
                    problems.push({ text: text.slice(0, 200), problem: "not a valid file URL" });
                    continue;
                }
            }
            const problem = pathProblem(text);
            if (problem !== "") {
                problems.push({ text: text.replace(_unsafeCharacters, "?").slice(0, 200), problem: problem });
                continue;
            }
            if (!paths.includes(text))
                paths.push(text);
        }
        return { paths: paths, problems: problems };
    }

    // The base name the receiver sees (the CLI sends filepath.Base)
    function baseName(path) {
        const parts = String(path ?? "").split("/");
        return parts[parts.length - 1] ?? "";
    }

    // The time limit of a look at local files (the check before a send, the folder's)
    readonly property int checkLimitMs: 15000

    // The user-side check before a send: one `find` over the paths, as the user, not
    // following links (-P): a regular file this user can read, a link, a folder, unreadable,
    // or (not printed: find's error) missing. Paths are absolute, so find never reads one as
    // an expression. → argv
    function checkArgv(paths) {
        return ["find", "-P"].concat(paths, ["-maxdepth", "0",
            "(", "-type", "l", "-printf", "link\\t0\\t%p\\n", ")", "-o",
            "(", "-type", "f", "-readable", "-printf", "file\\t%s\\t%p\\n", ")", "-o",
            "(", "-type", "f", "-printf", "unreadable\\t0\\t%p\\n", ")", "-o",
            "(", "-type", "d", "-printf", "folder\\t0\\t%p\\n", ")", "-o",
            "-printf", "other\\t0\\t%p\\n"]);
    }

    // find's output for `paths` → [{ path, name, ok, size, problem }] in the order asked
    function parseCheck(output, paths) {
        const found = {};
        for (const line of String(output ?? "").split("\n")) {
            const match = /^(link|file|unreadable|folder|other)\t(\d+)\t(\/.*)$/.exec(line);
            if (match && !Object.prototype.hasOwnProperty.call(found, match[3]))
                found[match[3]] = { kind: match[1], size: Number(match[2]) };
        }
        const problems = {
            link: "Link", unreadable: "Not readable", folder: "Folder", other: "Not a file"
        };
        return (Array.isArray(paths) ? paths : []).map(path => {
            const entry = Object.prototype.hasOwnProperty.call(found, path) ? found[path] : null;
            return {
                path: path, name: displayName(baseName(path)), ok: entry?.kind === "file", size: entry?.kind === "file" ? entry.size : 0,
                problem: entry === null ? "Not found" : (entry.kind === "file" ? "" : problems[entry.kind])
            };
        });
    }

    // `tailscale file cp -- <paths…> <address>:` (TailscaleRules.commandFor("fileCp"))
    function sendCommandArgs(paths, target) {
        return { files: paths, target: target?.argument ?? "" };
    }

    // A failed send's stderr → one short sentence
    function sendError(code, stderr) {
        const text = String(stderr ?? "");
        if (/Access denied|file access denied/i.test(text))
            return { kind: "denied", message: "Needs the operator" };
        if (/not connected to the tailnet|is not connected/i.test(text))
            return { kind: "not-connected", message: "Not connected" };
        let match = /cannot send files: ([^\n]+)/.exec(text);
        if (match)
            return { kind: "refused", message: "Device can't receive files" };
        match = /can't send to [^:]*: ([^\n]+)/.exec(text);
        if (match)
            return { kind: "refused", message: "Unknown device" };
        if (/directories not supported/.test(text))
            return { kind: "folder", message: "Folders can't be sent" };
        if (/no such file or directory/i.test(text))
            return { kind: "missing", message: "A file is gone" };
        if (code === 124 || code === 137)
            return { kind: "timeout", message: "Took too long, stopped" };
        const last = text.split("\n").map(line => line.trim()).filter(line => line !== "" && !line.startsWith("#")).pop() ?? "";
        return { kind: "error", message: last !== "" ? _plain(last, 200) : "Send failed" };
    }

    function _plain(text, limit) {
        return String(text ?? "").replace(_unsafeCharacters, "").replace(/\b100\.\d+\.\d+\.\d+\b/g, "[address]").slice(0, limit ?? 200);
    }

    // ---- The bus's file fields (ipn.Notify) ----

    // A bus message → { files: bool (it had any file field), waiting: true | null (FilesWaiting
    // is attached to every message while files wait — absent on one that has file fields
    // means none; on others: unknown), incoming [] | null, outgoing [] | null }
    function notifyFiles(input) {
        let raw = input;
        if (typeof input === "string") {
            try {
                raw = JSON.parse(input);
            } catch (error) {
                raw = null;
            }
        }
        const result = { files: false, initial: false, waiting: null, incoming: null, outgoing: null };
        if (!_isObject(raw))
            return result;
        // The first message of a watch carries SessionID and is built without the hooks that
        // attach FilesWaiting (ipnlocal WatchNotificationsAs): its silence says nothing
        result.initial = _get(raw, "SessionID") !== undefined;
        if (_get(raw, "FilesWaiting") !== undefined && _get(raw, "FilesWaiting") !== null)
            result.waiting = true;
        const incoming = _get(raw, "IncomingFiles");
        if (Array.isArray(incoming)) {
            result.incoming = incoming.slice(0, 256).filter(item => _isObject(item)).map(item => ({
                name: _string(_get(item, "Name"), 1024), started: _time(_get(item, "Started")),
                size: _number(_get(item, "DeclaredSize"), -1), received: _number(_get(item, "Received"), 0), done: _get(item, "Done") === true
            })).filter(item => item.name !== "");
        }
        const outgoing = _get(raw, "OutgoingFiles");
        if (Array.isArray(outgoing)) {
            result.outgoing = outgoing.slice(0, 512).filter(item => _isObject(item)).map(item => ({
                id: _string(_get(item, "ID"), 128), peerId: _string(_get(item, "PeerID"), 128), name: _string(_get(item, "Name"), 1024),
                started: _time(_get(item, "Started")), size: _number(_get(item, "DeclaredSize"), -1), sent: _number(_get(item, "Sent"), 0),
                finished: _get(item, "Finished") === true, succeeded: _get(item, "Succeeded") === true
            })).filter(item => item.name !== "");
        }
        result.files = result.waiting !== null || result.incoming !== null || result.outgoing !== null;
        return result;
    }

    function _time(value) {
        if (typeof value !== "string" || value === "" || value.startsWith("0001-"))
            return 0;
        const parsed = Date.parse(value);
        return isFinite(parsed) ? parsed : 0;
    }

    // Files that arrived: entries of `incoming` that are done and not yet in `seen` (keys
    // "<name>\n<started>") → { arrived [{ key, name }], seen (the new set, bounded) }
    function arrivals(seen, incoming) {
        const known = Array.isArray(seen) ? seen.slice() : [];
        const arrived = [];
        for (const item of Array.isArray(incoming) ? incoming : []) {
            if (!item?.done)
                continue;
            const key = item.name + "\n" + item.started;
            if (known.includes(key))
                continue;
            known.push(key);
            arrived.push({ key: key, name: displayName(item.name) });
        }
        return { arrived: arrived, seen: known.slice(-256) };
    }

    // A name for the screen: plain text, nothing invisible, bounded
    function displayName(name) {
        const text = String(name ?? "").replace(_unsafeCharacters, "�");
        return text.length > 120 ? text.slice(0, 80) + "…" + text.slice(-30) : text;
    }

    // The send's progress from the bus: the newest entry per name for this peer that started
    // at or after `since` (a little slack for the daemon's clock) → { <name>: { sent, size,
    // finished, succeeded } }
    function sendProgress(outgoing, peerId, names, since) {
        const result = {};
        for (const item of Array.isArray(outgoing) ? outgoing : []) {
            if (item.peerId !== peerId || !names.includes(item.name) || (item.started > 0 && item.started < since - 5000))
                continue;
            const previous = result[item.name];
            if (previous && previous.started > item.started)
                continue;
            result[item.name] = { started: item.started, sent: Math.max(0, item.sent), size: item.size, finished: item.finished, succeeded: item.succeeded };
        }
        return result;
    }

    function percent(sent, size) {
        return size > 0 ? Math.max(0, Math.min(100, Math.floor(100 * sent / size))) : -1;
    }

    // ---- Choosing (the shell's chooser, module API 1.17) ----

    // Whether a chooser's answer holds a choice: not when the user closed it, the session
    // was locked, another chooser was open, or it failed
    function _chose(result) {
        return _isObject(result) && result.cancelled !== true && String(result.blocked ?? "") === "" && String(result.error ?? "") === ""
            && Array.isArray(result.paths);
    }

    // The files of a chooser's answer → the paths to keep ([] when nothing was chosen), each
    // checked as a pasted one (pathProblem), at most maxFiles
    function chosenPaths(result) {
        if (!_chose(result))
            return [];
        return parsePaths(result.paths.filter(path => typeof path === "string" && path.startsWith("/"))).paths.slice(0, maxFiles);
    }

    // The folder of a chooser's answer ("folder" mode) → its path, "" when none was chosen
    function chosenFolder(result) {
        if (!_chose(result) || result.paths.length !== 1 || typeof result.paths[0] !== "string")
            return "";
        const folder = cleanFolder(result.paths[0]);
        return folderProblem(folder) === "" ? folder : "";
    }

    // What the place that asked says about a chooser's answer: "" for a choice, a close, or a
    // lock (the screen is locked: nothing to say); another chooser open (any module's, one for
    // the whole shell) → a short note; an error → its text, plain, on one line
    function chooserNote(result) {
        if (!_isObject(result))
            return "";
        const blocked = String(result.blocked ?? "");
        if (blocked === "busy")
            return "Another file chooser is open";
        if (blocked !== "")
            return "";
        return _plain(String(result.error ?? "").replace(/\s+/g, " ").trim(), 120);
    }

    // ---- The bar popup's send row ----

    // A send's bytes so far over the files it sends → { sent, total, fraction (0…1; -1 while
    // no size is known) }; a file sent counts whole
    function sendTotals(files) {
        let sent = 0;
        let total = 0;
        for (const file of Array.isArray(files) ? files : []) {
            if (!_isObject(file) || file.ok !== true)
                continue;
            const size = Math.max(0, _number(file.size, 0));
            total += size;
            sent += file.outcome === "sent" ? size : Math.min(size, Math.max(0, _number(file.sent, 0)));
        }
        return { sent: sent, total: total, fraction: total > 0 ? Math.max(0, Math.min(1, sent / total)) : -1 };
    }

    // What the files are called on one line: one file's name, "N files" for several
    function filesLabel(paths) {
        const list = Array.isArray(paths) ? paths : [];
        return list.length === 1 ? displayName(baseName(list[0])) : list.length + " files";
    }

    // The row under a device in the bar popup and what its buttons do. `choices` { <device
    // id>: paths }: the files picked there per device, not sent yet; `send`: TaildropClient's
    // send (`origin` "popup" when the popup started it, `popupCleared` once the popup's "×"
    // cleared its result); `busy`: some send runs. → null (no row), or { kind, label, names,
    // fraction, text, tone, canSend, canCancel, canDrop }:
    //   "sending"  this device's send from the popup runs: the bar, Cancel
    //   "choice"   files picked for it: Send (while no send runs), "×" drops them
    //   "result"   its send from the popup ended (sent, failed and why, cancelled): "×" clears it
    // A run outranks a choice; a choice outranks the last result.
    function popupRow(choices, send, deviceId, busy) {
        const id = String(deviceId ?? "");
        if (id === "")
            return null;
        const ours = _isObject(send) && send.origin === "popup" && String(send.targetId ?? "") === id;
        const files = ours && Array.isArray(send.files) ? send.files.filter(file => _isObject(file)) : [];
        const names = list => list.map(item => typeof item === "string" ? displayName(baseName(item)) : String(item.name ?? "")).join(", ").slice(0, 300);
        if (ours && (send.state === "checking" || send.state === "sending")) {
            const totals = sendTotals(files);
            const checking = send.state === "checking";
            return { kind: "sending", label: filesLabel(files.map(file => file.path)), names: names(files), fraction: checking ? -1 : totals.fraction,
                     text: checking ? "Checking…" : totals.fraction >= 0 ? Math.floor(totals.fraction * 100) + " %" : "Sending…",
                     tone: "normal", canSend: false, canCancel: true, canDrop: false };
        }
        const paths = popupPaths(choices, id);
        if (paths.length > 0)
            return { kind: "choice", label: filesLabel(paths), names: names(paths), fraction: -1, text: "", tone: "normal",
                     canSend: busy !== true, canCancel: false, canDrop: true };
        if (!ours || send.popupCleared === true || !["done", "failed", "cancelled"].includes(send.state))
            return null;
        const good = files.filter(file => file.ok === true);
        const refused = files.filter(file => file.ok !== true && String(file.problem ?? "") !== "");
        const message = String(send.message ?? "");
        const text = send.state === "done" ? (refused.length > 0 ? "Sent " + good.length + " of " + files.length : "Sent")
            : send.state === "cancelled" ? (message || "Cancelled")
            : [message || "Not sent", good.length === 0 && refused.length === 1 ? String(refused[0].problem) : ""].filter(part => part !== "").join(" · ");
        return { kind: "result", label: files.length > 0 ? filesLabel(files.map(file => file.path)) : "", names: names(files),
                 fraction: send.state === "done" ? 1 : -1, text: text,
                 tone: send.state === "done" ? "success" : send.state === "failed" ? "warning" : "muted",
                 canSend: false, canCancel: false, canDrop: true };
    }

    // The files picked in the popup for one device ([] none)
    function popupPaths(choices, deviceId) {
        const paths = _isObject(choices) ? choices[String(deviceId ?? "")] : null;
        return Array.isArray(paths) ? paths : [];
    }

    // The devices the popup keeps in its list past its cap: those with files picked, a note,
    // or the popup's send (running, or its result not cleared there)
    function popupKept(choices, notes, send) {
        const kept = [];
        const add = id => {
            if (id !== "" && !kept.includes(id))
                kept.push(id);
        };
        for (const id of Object.keys(_isObject(choices) ? choices : {}))
            if (popupPaths(choices, id).length > 0)
                add(id);
        for (const id of Object.keys(_isObject(notes) ? notes : {}))
            if (String(notes[id] ?? "") !== "")
                add(id);
        if (_isObject(send) && send.origin === "popup" && send.state !== ""
                && (send.state === "checking" || send.state === "sending" || send.popupCleared !== true))
            add(String(send.targetId ?? ""));
        return kept;
    }

    // ---- Receiving ----

    // A received name as it is written: Tailscale already refuses "/", "\", control and other
    // non-graphic characters, surrounding spaces, "." and "..", more than 255 bytes
    // (feature/taildrop: validateBaseName, validFilenameRune) — checked again here, whatever
    // the daemon: no path separator, nothing invisible, no leading "." (a hidden file such as
    // .bashrc) or "-", cut to maxNameBytes keeping the extension. "" only for a name that is
    // not text.
    function safeReceivedName(name) {
        if (typeof name !== "string")
            return "";
        let text = name.replace(_unsafeCharacters, "_").replace(/[\/\\]/g, "_").trim();
        text = text.replace(/^[.\-\s]+/, "");
        if (text === "")
            text = "received file";
        if (_utf8Bytes(text) > maxNameBytes) {
            const dot = text.lastIndexOf(".");
            const extension = dot > 0 && text.length - dot <= 16 ? text.slice(dot) : "";
            let stem = extension !== "" ? text.slice(0, dot) : text;
            const budget = maxNameBytes - _utf8Bytes(extension);
            let cut = "";
            for (const character of stem) {
                if (_utf8Bytes(cut + character) > budget)
                    break;
                cut += character;
            }
            text = cut.trim() + extension;
        }
        return text;
    }

    // The LocalAPI's waiting list (GET /localapi/v0/files/: [{ Name, Size }], operator only) →
    // { ok, files [{ name (as Tailscale has it), shown, saveAs, escaped, size }] } — saveAs
    // unique in the list (a second one that cleans to the same name gets " (2)")
    function parseWaiting(text) {
        let raw = null;
        try {
            raw = JSON.parse(String(text ?? ""));
        } catch (error) {
            return { ok: false, files: [] };
        }
        if (raw === null)
            raw = [];
        if (!Array.isArray(raw))
            return { ok: false, files: [] };
        const files = [];
        const taken = [];
        for (const item of raw.slice(0, 256)) {
            const name = _string(_get(item, "Name"), 1024);
            if (name === "")
                continue;
            let saveAs = safeReceivedName(name);
            for (let i = 2; taken.includes(saveAs.toLowerCase()) && i < 100; i++)
                saveAs = numbered(safeReceivedName(name), i);
            taken.push(saveAs.toLowerCase());
            files.push({ name: name, shown: displayName(name), saveAs: saveAs, escaped: encodeURIComponent(name), size: _number(_get(item, "Size"), 0) });
        }
        return { ok: true, files: files };
    }

    // "photo.jpg", 2 → "photo (2).jpg" (as the CLI's numberedFileName: path.Ext)
    function numbered(name, number) {
        const dot = name.lastIndexOf(".");
        return dot > 0 ? name.slice(0, dot) + " (" + number + ")" + name.slice(dot) : name + " (" + number + ")";
    }

    // Why a folder is not a place to save to ("" fine): absolute, plain
    function folderProblem(path) {
        if (typeof path !== "string" || path === "")
            return "no folder";
        if (!path.startsWith("/"))
            return "not an absolute path";
        if (path.length > 1024 || /[\u0000-\u001f\u007f]/.test(path))
            return "not a usable path";
        if (path.split("/").some(part => part === "." || part === ".."))
            return "\".\" or \"..\" in the path";
        return "";
    }

    // The folder's own spelling without a trailing "/"
    function cleanFolder(path) {
        const text = String(path ?? "").trim();
        return text.length > 1 ? text.replace(/\/+$/, "") : text;
    }

    // The default save folder: the system's download folder (Api.system.downloadDirectory,
    // module API 1.13: XDG_DOWNLOAD_DIR, else ~/Downloads), when it is a folder below a home —
    // the home itself ("$HOME/" in user-dirs.dirs means "no download folder") or a path that
    // is not one gives <home>/Downloads; no home: ""
    function defaultFolder(downloadDirectory, home) {
        const homeDir = cleanFolder(home);
        const fallback = homeDir !== "" && homeDir.startsWith("/") ? homeDir + "/Downloads" : "";
        const value = cleanFolder(downloadDirectory);
        return value !== "" && folderProblem(value) === "" && value !== homeDir ? value : fallback;
    }

    // The save script, run AS THE USER (never through pkexec) with sh -c and its values as
    // arguments (never in the script's text): $1 curl, $2 the LocalAPI socket, $3 timeout ("":
    // none), $4 seconds per request, $5 the conflict policy, $6 the folder, then pairs
    // <escaped name> <name to save as>. The folder must be a real directory (not a link) that
    // this user owns and may write. Each file: fetched from the LocalAPI (GET files/<name>,
    // operator only) into a private staging directory inside the folder (mktemp, 700), then
    // moved into place by rename — `mv -T` never into a directory, `-n` never over an existing
    // file unless the policy is "overwrite" (a rename replaces a link itself, never what it
    // points to) — and only then deleted from Tailscale's inbox (DELETE files/<name>), as `tailscale file get` does.
    // "skip" leaves a file whose name is taken waiting. One line per file: saved, saved-kept
    // (saved, the inbox copy not deleted), skipped, failed; "error" for the folder.
    readonly property string saveScript: [
        "set -u",
        "curl=$1; socket=$2; limit=$3; seconds=$4; policy=$5; dir=$6; shift 6",
        // Each request runs in the background and is waited for, so that a TERM (the module ending
        // it) first kills the request, then removes the staging directory: nothing can recreate
        // a file in it afterwards
        "child=''",
        "run() { if [ -n \"$limit\" ]; then \"$limit\" -k 5 \"$seconds\" \"$@\" & else \"$@\" & fi; child=$!; wait \"$child\"; status=$?; child=''; return $status; }",
        "case $dir in /*) ;; *) printf 'error\\tnot-absolute\\n'; exit 3 ;; esac",
        "if [ -L \"$dir\" ] || [ ! -d \"$dir\" ]; then printf 'error\\tnot-a-folder\\n'; exit 3; fi",
        "[ -O \"$dir\" ] || { printf 'error\\tnot-yours\\n'; exit 3; }",
        "[ -w \"$dir\" ] || { printf 'error\\tnot-writable\\n'; exit 3; }",
        "staging=$(mktemp -d -p \"$dir\" .tailscale-receiving.XXXXXX) || { printf 'error\\tno-staging\\n'; exit 3; }",
        "case $staging in \"$dir\"/.tailscale-receiving.??????) ;; *) printf 'error\\tno-staging\\n'; exit 3 ;; esac",
        "cleanup() { if [ -n \"$child\" ]; then kill \"$child\" 2> /dev/null; wait \"$child\" 2> /dev/null; fi; rm -rf -- \"$staging\"; }",
        "trap cleanup EXIT",
        "trap 'exit 143' TERM INT HUP",
        "base=http://local-tailscaled.sock/localapi/v0/files/",
        "while [ $# -ge 2 ]; do",
        "  escaped=$1; name=$2; shift 2",
        "  case $name in '' | .* | -* | */*) printf 'failed\\t%s\\tbad-name\\n' \"$name\"; continue ;; esac",
        "  if [ \"$policy\" = skip ] && { [ -e \"$dir/$name\" ] || [ -L \"$dir/$name\" ]; }; then printf 'skipped\\t%s\\n' \"$name\"; continue; fi",
        "  rm -f -- \"$staging/part\"",
        "  if ! run \"$curl\" -sS --fail --unix-socket \"$socket\" -o \"$staging/part\" \"$base$escaped\" > /dev/null 2>&1; then printf 'failed\\t%s\\tfetch\\n' \"$name\"; continue; fi",
        "  final=''",
        "  case $policy in",
        "    overwrite) mv -f -T -- \"$staging/part\" \"$dir/$name\" 2> /dev/null && final=$name ;;",
        "    skip) mv -n -T -- \"$staging/part\" \"$dir/$name\" 2> /dev/null; [ -e \"$staging/part\" ] || final=$name ;;",
        "    *) case $name in ?*.*) stem=${name%.*}; ext=.${name##*.} ;; *) stem=$name; ext='' ;; esac",
        "       i=0; candidate=$name",
        "       while [ $i -lt 100 ]; do",
        "         [ $i -gt 0 ] && candidate=\"$stem ($i)$ext\"",
        "         if [ ! -e \"$dir/$candidate\" ] && [ ! -L \"$dir/$candidate\" ]; then",
        "           mv -n -T -- \"$staging/part\" \"$dir/$candidate\" 2> /dev/null",
        "           [ -e \"$staging/part\" ] || { final=$candidate; break; }",
        "         fi",
        "         i=$((i + 1))",
        "       done ;;",
        "  esac",
        "  if [ -z \"$final\" ]; then",
        "    rm -f -- \"$staging/part\"",
        "    if [ \"$policy\" = skip ]; then printf 'skipped\\t%s\\n' \"$name\"; else printf 'failed\\t%s\\tnot-placed\\n' \"$name\"; fi",
        "    continue",
        "  fi",
        "  if run \"$curl\" -sS --fail --unix-socket \"$socket\" -X DELETE \"$base$escaped\" > /dev/null 2>&1; then printf 'saved\\t%s\\t%s\\n' \"$name\" \"$final\"",
        "  else printf 'saved-kept\\t%s\\t%s\\n' \"$name\" \"$final\"; fi",
        "done",
        "exit 0"
    ].join("\n")

    // The save's argv → { ok, error, argv }
    function saveArgv(options) {
        const curl = _string(_get(options, "curl"), 1024);
        const socket = _string(_get(options, "socket"), 1024);
        const limit = _string(_get(options, "timeout"), 1024);
        const seconds = _number(_get(options, "seconds"), 60);
        const policy = _get(options, "policy");
        const folder = cleanFolder(_get(options, "folder"));
        const files = _get(options, "files");
        if (!curl.startsWith("/") || !socket.startsWith("/") || (limit !== "" && !limit.startsWith("/")))
            return { ok: false, error: "Needs curl", argv: [] };
        if (!conflictPolicies.includes(policy))
            return { ok: false, error: "Bad setting", argv: [] };
        if (folderProblem(folder) !== "")
            return { ok: false, error: "Folder not usable", argv: [] };
        if (!Array.isArray(files) || files.length === 0)
            return { ok: false, error: "Nothing waiting", argv: [] };
        const pairs = [];
        for (const file of files) {
            if (typeof file?.escaped !== "string" || file.escaped === "" || file.escaped === "." || file.escaped === ".." || /[\/\u0000-\u001f]/.test(file.escaped)
                    || typeof file?.saveAs !== "string" || safeReceivedName(file.saveAs) !== file.saveAs)
                return { ok: false, error: "Bad file name", argv: [] };
            pairs.push(file.escaped, file.saveAs);
        }
        return { ok: true, error: "", argv: ["sh", "-c", saveScript, "sh", curl, socket, limit, String(Math.round(seconds)), policy, folder].concat(pairs) };
    }

    // The save's output → { error (the folder's problem, "" none), results [{ outcome:
    // saved | skipped | failed, name, savedAs, kept (the inbox copy not deleted), reason }] }
    function parseSave(output, folder) {
        const folderErrors = {
            "not-absolute": "Folder not usable", "not-a-folder": "Folder not found", "not-yours": "Not your folder",
            "not-writable": "Folder not writable", "no-staging": "Can't write here"
        };
        const reasons = { "bad-name": "bad name", fetch: "not fetched", "not-placed": "no free name" };
        const result = { error: "", results: [] };
        for (const line of String(output ?? "").split("\n")) {
            const parts = line.split("\t");
            if (parts[0] === "error") {
                result.error = folderErrors[parts[1]] ?? "Folder not usable";
            } else if ((parts[0] === "saved" || parts[0] === "saved-kept") && parts.length >= 3) {
                result.results.push({ outcome: "saved", rawName: parts[1], name: displayName(parts[1]), savedAs: displayName(parts[2]),
                    path: cleanFolder(folder) + "/" + parts[2], kept: parts[0] === "saved-kept", reason: "" });
            } else if (parts[0] === "skipped" && parts.length >= 2) {
                result.results.push({ outcome: "skipped", rawName: parts[1], name: displayName(parts[1]), savedAs: "", path: "", kept: true, reason: "name taken" });
            } else if (parts[0] === "failed" && parts.length >= 2) {
                result.results.push({ outcome: "failed", rawName: parts[1], name: displayName(parts[1]), savedAs: "", path: "", kept: true, reason: reasons[parts[2]] ?? "failed" });
            }
        }
        return result;
    }

    // The listing's argv (GET /localapi/v0/files/ — lists only: without ?waitsec it neither
    // waits nor changes anything; operator only)
    function listArgv(curl, socket) {
        return [curl, "-sS", "--fail", "--unix-socket", socket, "http://local-tailscaled.sock/localapi/v0/files/"];
    }

    // A folder as a file: URL (for Api.openUrl's allowFile): each component percent-encoded
    function folderUrl(folder) {
        const path = cleanFolder(folder);
        if (folderProblem(path) !== "")
            return "";
        return "file://" + path.split("/").map(part => encodeURIComponent(part)).join("/");
    }

    // One line for the provider entry's status while files wait ("" none)
    // `count` the files listed (the operator's listing; -1 unknown), `waiting` the bus's
    // FilesWaiting
    function waitingText(count, waiting) {
        if (count > 0)
            return count === 1 ? "1 file received" : count + " files received";
        return count < 0 && waiting === true ? "Files received" : "";
    }
}
