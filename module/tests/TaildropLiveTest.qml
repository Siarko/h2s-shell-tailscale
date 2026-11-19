import QtQuick
import Quickshell
import qs.api
import qs.tests
import ".."

// Taildrop's live side (TaildropClient, on TailscaleClient's runner) against the stand-ins
// (tests/stand-in, each client's StandInModule): sending — the user-side check, `file cp --` plainly, denied → pkexec, the
// bus's progress, cancel, a dismissed prompt, an offline device — and receiving — the bus's
// arrivals for a user who is not the operator (a notice, no listing, no save), the operator's
// listing and save with adversarial names into a real folder (sanitised, owned by the user,
// numbered, overwritten, left waiting), a folder that is a link, saving by itself, giving the
// operator up. Each scenario has its own directory, stand-in state and client.
TestCase {
    id: suite
    suiteName: "tailscale: Taildrop against the stand-ins"
    asynchronous: true
    Component.onCompleted: {
        if ("timeLimitMs" in suite)
            suite["timeLimitMs"] = 30000;
    }

    function _path(url) {
        return String(url).replace(/^file:\/\//, "").replace(/\/+$/, "");
    }

    readonly property string standIns: _path(Qt.resolvedUrl("stand-in"))
    readonly property string fixtures: _path(Qt.resolvedUrl("../../fixtures"))
    readonly property string base: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ts-drop-" + Date.now()

    property var _scenarios: []
    property var _all: []
    property Component _clientComponent: Component {
        TailscaleClient {}
    }
    property CommandAction _shell: CommandAction {}
    property Component _moduleComponent: Component {
        StandInModule {}
    }

    // options: { env {}, setup (sh lines, $1 the scenario's directory) }
    function scenario(name, options) {
        const dir = base + "/" + name;
        const s = { name: name, dir: dir, log: dir + "/log", pkexecLog: dir + "/pkexec.log", client: null, failures: [], steps: [], started: false,
                    options: options ?? {} };
        s.env = Object.assign({
            TS_FAKE_STATE_DIR: dir + "/state", TS_FAKE_LOG: s.log, TS_FAKE_PKEXEC_LOG: s.pkexecLog, TS_FAKE_USER: "tester",
            TS_FAKE_FIXTURES: fixtures, TS_FAKE_BUS_FILE: dir + "/bus.jsonl", TS_FAKE_BUS_FOLLOW: "1", TS_FAKE_BUS_HOLD: "28"
        }, s.options.env ?? {});
        _scenarios.push(s);
        _all.push(s);
        then(s, "set up", () => s.ready === true, () => {});
        s.steps[0].start = () => {
            const lines = ["mkdir -p \"$1/state/inbox\" \"$1/downloads\" \"$1/files\"", ": > \"$1/log\"", ": > \"$1/pkexec.log\"",
                "printf 'running\\n' > \"$1/state/scenario\"", "echo '{\"Health\":{\"Warnings\":{}}}' > \"$1/bus.jsonl\""].concat(s.options.setup ?? []);
            _shell.run(["sh", "-c", lines.join(" && "), "sh", dir], result => {
                if (!result.ok)
                    fail(name + ": set up failed: " + result.error);
                s.module = _moduleComponent.createObject(suite);
                s.client = _clientComponent.createObject(suite, {
                    module: s.module, environment: s.env, readDebounceMs: 100, streamBackoffMinMs: 200, streamBackoffMaxMs: 800, pollMs: 5000,
                    readRetryMinMs: 300, readRetryMaxMs: 1200
                });
                s.client.taildrop.defaultFolder = dir + "/downloads";
                if (s.options.idleLimitMs)
                    s.client.taildrop.idleLimitMs = s.options.idleLimitMs;
                s.client.failed.connect((what, reason) => s.failures.push({ what: what, reason: reason }));
                s.client.running = true;
                s.ready = true;
            });
        };
        return s;
    }

    function then(s, description, condition, action, start) {
        s.steps.push({ description: description, condition: condition, action: action, start: start ?? null });
    }

    // Runs `script` (sh -c, $1 the scenario's directory) and stores its output's lines in s[key]
    function thenShell(s, description, script, key, action) {
        then(s, description, () => s[key] !== undefined, () => action(s[key]), () => {
            s[key] = undefined;
            _shell.run(["sh", "-c", script, "sh", s.dir], result => s[key] = result.lines.map(line => line.trim()).filter(line => line !== ""));
        });
    }

    // Runs `script` (as thenShell) again and again (300 ms apart) until its first line is
    // `wanted` — a condition outside the client (a process gone, a line in a log) — then
    // action(that line)
    function thenShellUntil(s, description, script, key, wanted, action) {
        const run = () => {
            s[key + "Running"] = true;
            s[key + "At"] = Date.now();
            _shell.run(["sh", "-c", script, "sh", s.dir], result => {
                s[key] = (result.lines[0] ?? "").trim();
                s[key + "Running"] = false;
            });
        };
        then(s, description, () => {
            if (s[key] === wanted)
                return true;
            if (!s[key + "Running"] && Date.now() - s[key + "At"] >= 300)
                run();
            return false;
        }, () => action(s[key]), () => {
            s[key] = undefined;
            run();
        });
    }

    function logs(s, description, action) {
        thenShell(s, description + " (logs read)", "cat \"$1/log\"; echo '----'; cat \"$1/pkexec.log\"", "_logLines", lines => {
            const cut = lines.indexOf("----");
            s.logLines = lines.slice(0, cut);
            s.pkexecLines = lines.slice(cut + 1);
            action();
        });
    }

    function waitMs(s, ms) {
        let until = 0;
        then(s, "wait " + ms + " ms", () => Date.now() >= until, () => {}, () => until = Date.now() + ms);
    }

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    function count(lines, pattern) {
        return (lines ?? []).filter(line => pattern.test(line)).length;
    }

    function rx(text) {
        return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    function drop(s) {
        return s.client.taildrop;
    }

    // An arrival as the daemon announces it (feature/taildrop/send.go: SendFileNotify after the
    // rename, Done set; ext.go setNotifyFilesWaiting adds FilesWaiting), appended to the bus
    function arriveLine(name, size) {
        return JSON.stringify({ IncomingFiles: [{ Name: name, Started: "2026-11-16T10:00:00Z", DeclaredSize: size, Received: size, Done: true }], FilesWaiting: {} });
    }

    function busReady(s) {
        return s.client.streamUp && s.client.status !== null && !s.client._reading;
    }

    property Timer _clock: Timer {
        interval: 40
        repeat: true
        onTriggered: {
            for (const s of suite._scenarios) {
                const step = s.steps[0];
                if (!step)
                    continue;
                if (!s.started) {
                    s.started = true;
                    s.waitedUntil = Date.now() + 12000;
                    try {
                        step.start?.();
                    } catch (error) {
                        suite.fail(s.name + ": threw starting \"" + step.description + "\": " + error);
                    }
                }
                let ready = false;
                try {
                    ready = step.condition();
                } catch (error) {}
                if (!ready && Date.now() < s.waitedUntil)
                    continue;
                s.steps.shift();
                s.started = false;
                if (!ready) {
                    suite.fail(s.name + ": timed out waiting: " + step.description);
                    s.steps = [];
                    continue;
                }
                try {
                    step.action();
                } catch (error) {
                    suite.fail(s.name + ": threw in \"" + step.description + "\": " + error);
                }
            }
            suite._scenarios = suite._scenarios.filter(s => s.steps.length > 0);
            if (suite._scenarios.length === 0) {
                stop();
                suite._finishAll();
            }
        }
    }

    function _finishAll() {
        for (const s of _all)
            s.client?.destroy();
        _shell.run(["rm", "-rf", "--", base], () => suite.finish());
    }

    function runAsync() {
        // This user as the profile's operator (the client compares with `id -un`); the stand-ins
        // grant the operator's access through TS_FAKE_OPERATOR
        const operatorPrefs = "printf 'OperatorUser=%s\\n' \"$(id -un)\" > \"$1/state/prefs\"";
        const operator = { TS_FAKE_OPERATOR: "1" };

        // ---- Not the operator: nothing runs, never a prompt ----
        const notOpSend = scenario("send-not-operator", { setup: ["printf 'hello' > \"$1/files/a.txt\""] });
        then(notOpSend, "devices read", () => busReady(notOpSend) && drop(notOpSend).targets.length > 0, () => {
            drop(notOpSend).targetId = "nPEER4CNTRL";
            drop(notOpSend).addPaths(notOpSend.dir + "/files/a.txt");
            assert(!drop(notOpSend).canSend, "not the operator: cannot send");
            assert(!drop(notOpSend).sendFiles(), "send refused");
            assertEqual(drop(notOpSend).send.message, "Needs the operator", "… said in a few words");
        });
        logs(notOpSend, "nothing ran", () => {
            assertEqual(count(notOpSend.logLines, /^file /), 0, "no `file cp`");
            assertEqual(notOpSend.pkexecLines.length, 0, "nothing through pkexec");
        });

        // ---- The operator sends: checked for the message, `file cp --` as the user ----
        const send = scenario("send", { env: operator, setup: [operatorPrefs,
            "printf 'hello' > \"$1/files/a.txt\"", "printf 'pdfpdfpdf' > \"$1/files/with space.pdf\"",
            "ln -s /etc/hostname \"$1/files/link.txt\"", "mkdir \"$1/files/folder\"", "printf 'x' > \"$1/files/secret\" && chmod 000 \"$1/files/secret\""] });
        then(send, "devices read", () => busReady(send) && send.client.canChange && drop(send).targets.length > 0, () => {
            const targets = drop(send).targets;
            assert(targets.some(item => item.id === "nPEER4CNTRL" && item.available && item.argument === "100.64.0.4"), "peer4 (TaildropTarget 1) can receive, by its IPv4 address");
            assert(targets.some(item => item.id === "nPEER2CNTRL" && !item.available && item.note === "offline"), "peer2 (TaildropTarget 5) listed, offline, not offered");
            drop(send).targetId = "nPEER4CNTRL";
            const added = drop(send).addPaths([send.dir + "/files/a.txt", "file://" + encodeURI(send.dir + "/files/with space.pdf"), send.dir + "/files/link.txt",
                send.dir + "/files/folder", send.dir + "/files/secret", send.dir + "/files/missing", "relative.txt", send.dir + "/files/../files/a.txt"]);
            assertEqual(added, 6, "six absolute paths taken (a drop's file URL decoded), a relative one and one with \"..\" refused");
            assertEqual(drop(send).inputProblems.length, 2, "… the two refused shown");
            assert(drop(send).sendFiles(), "send starts");
        });
        then(send, "sent", () => drop(send).send.state === "done", () => {
            same(drop(send).send.files.map(file => file.outcome), ["sent", "sent", "refused", "refused", "refused", "refused"],
                 "two sent; the link, the folder, the unreadable and the missing file left out");
            same(drop(send).send.files.slice(2).map(file => file.problem), ["Link", "Folder", "Not readable", "Not found"], "… each with its reason");
            same(drop(send).chosen, [send.dir + "/files/link.txt", send.dir + "/files/folder", send.dir + "/files/secret", send.dir + "/files/missing"],
                 "the sent files leave the list, the refused stay");
            assertEqual(send.failures.length, 0, "no failure notification");
        });
        logs(send, "after the send", () => {
            assertEqual(count(send.logLines, new RegExp("^file cp -- " + rx(send.dir + "/files/a.txt") + " " + rx(send.dir + "/files/with space.pdf") + " 100\\.64\\.0\\.4:$")), 1,
                        "`file cp -- <the two checked files> 100.64.0.4:` once, as the user");
            assertEqual(send.pkexecLines.length, 0, "never through pkexec");
        });
        thenShell(send, "what arrived", "cat \"$1/state/sent/a.txt\"; echo; cat \"$1/state/sent/with space.pdf\"", "arrived", lines => {
            same(lines, ["hello", "pdfpdfpdf"], "the stand-in daemon got both files' contents");
        });

        // ---- A send holds no change lock; Disconnect ends it ----
        const slow = scenario("slow", { env: Object.assign({ TS_FAKE_SEND_DELAY: "2" }, operator), setup: [operatorPrefs, "head -c 4000 /dev/zero > \"$1/files/big.bin\""] });
        then(slow, "devices read", () => busReady(slow) && slow.client.canChange && drop(slow).targets.length > 0, () => {
            drop(slow).targetId = "nPEER4CNTRL";
            drop(slow).addPaths(slow.dir + "/files/big.bin");
            assert(drop(slow).sendFiles(), "send starts");
        });
        then(slow, "progress from the bus", () => (drop(slow).send.files[0]?.percent ?? -1) >= 50, () => {
            assertEqual(drop(slow).send.state, "sending", "still sending at 50 % (the bus's OutgoingFiles: Sent 2000 of 4000)");
            assertEqual(slow.client.operation, "", "… not the client's operation");
            assert(!slow.client.busy && !slow.client.entry.busy, "… the entry not busy: other changes are free");
            assert(slow.client.disconnect("user"), "Disconnect meanwhile");
            assertEqual(drop(slow).send.state, "cancelled", "… ends the send");
            assertEqual(drop(slow).send.message, "Stopped: disconnected", "… said so");
        });
        then(slow, "disconnected", () => !slow.client.busy && slow.client.status?.backendState === "Stopped", () => {});
        thenShell(slow, "nothing completed", "ls \"$1/state/sent\" 2> /dev/null | wc -l", "completed", lines => same(lines, ["0"], "the killed send never completed"));

        // ---- Cancel kills it; a stalled send stops ----
        const cancel = scenario("cancel", { env: Object.assign({ TS_FAKE_SEND_DELAY: "3" }, operator), setup: [operatorPrefs, "printf 'abc' > \"$1/files/a.txt\""] });
        then(cancel, "devices read", () => busReady(cancel) && cancel.client.canChange && drop(cancel).targets.length > 0, () => {
            drop(cancel).targetId = "nPEER4CNTRL";
            drop(cancel).addPaths(cancel.dir + "/files/a.txt");
            drop(cancel).sendFiles();
        });
        then(cancel, "sending", () => drop(cancel).send.state === "sending" && drop(cancel).send.files[0]?.outcome === "sending", () => {
            assert(drop(cancel).cancelSend(), "cancel");
            same([drop(cancel).send.state, drop(cancel).send.files[0].outcome], ["cancelled", "not sent"], "… cancelled, not sent");
        });
        // One grep over every environ, then the command lines of this scenario's processes
        thenShellUntil(cancel, "the send's process gone",
            "for f in $(grep -lzx \"TS_FAKE_STATE_DIR=$1/state\" /proc/[0-9]*/environ 2> /dev/null); do p=${f%/environ}; tr '\\0' ' ' < \"$p/cmdline\" 2> /dev/null | grep -q 'tailscale file cp' && echo \"$p\"; done | wc -l",
            "sendsLeft", "0", left => assertEqual(left, "0", "the send's process ended"));
        thenShell(cancel, "killed", "ls \"$1/state/sent\" 2> /dev/null | wc -l", "killed", lines => same(lines, ["0"], "the process was killed: nothing arrived"));
        const stall = scenario("stall", { idleLimitMs: 1200, env: Object.assign({ TS_FAKE_SEND_DELAY: "6" }, operator), setup: [operatorPrefs, "printf 'abc' > \"$1/files/a.txt\""] });
        then(stall, "devices read", () => busReady(stall) && stall.client.canChange && drop(stall).targets.length > 0, () => {
            drop(stall).targetId = "nPEER4CNTRL";
            drop(stall).addPaths(stall.dir + "/files/a.txt");
            drop(stall).sendFiles();
        });
        then(stall, "stalled", () => drop(stall).send.state === "failed", () => {
            assertEqual(drop(stall).send.message, "Stalled, stopped", "no progress on the bus: stopped");
        });

        // ---- Offline device; the daemon's refusal ----
        const refused = scenario("refused", { env: Object.assign({ TS_FAKE_SEND_REFUSE: "target's OS does not support Taildrop" }, operator),
                                              setup: [operatorPrefs, "printf 'x' > \"$1/files/a.txt\""] });
        then(refused, "devices read", () => busReady(refused) && refused.client.canChange && drop(refused).targets.length > 0, () => {
            drop(refused).targetId = "nPEER2CNTRL";
            drop(refused).addPaths(refused.dir + "/files/a.txt");
            assert(!drop(refused).sendFiles(), "an offline device: not started");
            assertEqual(drop(refused).send.message, "Device is offline", "… said so");
            drop(refused).targetId = "nPEER4CNTRL";
            assert(drop(refused).sendFiles(), "send to peer4");
        });
        then(refused, "refused by the daemon", () => drop(refused).send.state === "failed", () => {
            assertEqual(drop(refused).send.message, "Device can't receive files", "the daemon's refusal, in a few words");
        });

        // ---- One change at a time: never replaced, never lost ----
        const race = scenario("race", { env: operator, setup: [operatorPrefs, "printf 'x' > \"$1/state/inbox/a.txt\""] });
        then(race, "ready", () => busReady(race) && race.client.canChange && drop(race).waitingCount === 1, () => {
            race.ends = [];
            const first = TailscaleRules.commandFor("shieldsUp", { on: true });
            const second = TailscaleRules.commandFor("acceptRoutes", { on: true });
            assert(race.client._runChange(first, "user", "setting", null, null, outcome => race.ends.push(["first", outcome.ok])), "the first change starts");
            assert(!race.client._runChange(second, "user", "setting", null, null, outcome => race.ends.push(["second", outcome.ok, outcome.message])),
                   "a second one at once: refused");
            same(race.ends, [["second", false, "Another Tailscale change is running."]], "… told so, at once");
            assert(!drop(race).save("user"), "a save meanwhile: refused");
            assertEqual(drop(race).saveError, "Another Tailscale change is running.", "… told so");
        });
        then(race, "the first finished", () => race.ends.length === 2 && !race.client.busy && race.client.prefs?.shieldsUp === true, () => {
            same(race.ends[1], ["first", true], "the first change was not replaced: it finished");
            assertEqual(race.client.prefs?.shieldsUp, true, "… and took effect");
        });
        logs(race, "what ran", () => {
            assertEqual(count(race.logLines, /^set --shields-up=true$/), 1, "the first ran");
            assertEqual(count(race.logLines, /^set --accept-routes/), 0, "the refused one never ran");
        });

        // ---- Receiving, not the operator: told, not offered ----
        const notOp = scenario("receive-not-operator", { setup: ["printf 'data' > \"$1/state/inbox/photo.jpg\""] });
        then(notOp, "stream up", () => busReady(notOp), () => {
            assertEqual(drop(notOp).waitingCount, -1, "the waiting list is not readable (files/ needs write access)");
            _shell.run(["sh", "-c", "printf '%s\\n' \"$2\" >> \"$1/bus.jsonl\"", "sh", notOp.dir, arriveLine("photo.jpg", 4)], () => {});
        });
        then(notOp, "an arrival", () => drop(notOp).notices.length === 1, () => {
            same(drop(notOp).notices[0], { names: ["photo.jpg"], actions: [] }, "one notice with the name, no Save");
            assert(drop(notOp).busWaiting, "FilesWaiting seen");
            assert(/Files received/.test(notOp.client.entry.status), "the entry's status says so: " + notOp.client.entry.status);
            assertEqual(notOp.client.entry.attention, null, "… never attention");
            assert(!drop(notOp).save("user"), "save refused");
            assertEqual(drop(notOp).saveError, "Needs the operator", "… with the reason");
        });
        logs(notOp, "no inbox access", () => {
            assertEqual(count(notOp.logLines, /localapi\/v0\/files\//), 0, "no files/ request as a non-operator");
            assertEqual(notOp.pkexecLines.length, 0, "nothing as root");
        });

        // ---- Receiving as the operator: adversarial names into a real folder ----
        const op = scenario("receive-operator", { env: operator, setup: [operatorPrefs,
            "printf 'new report' > \"$1/state/inbox/report.pdf\"", "printf 'evil' > \"$1/state/inbox/.bashrc\"", "printf 'dash' > \"$1/state/inbox/-rf\"",
            "printf 'u' > \"$1/state/inbox/über naïve.txt\"", "printf 'old report' > \"$1/downloads/report.pdf\"",
            "mkdir \"$1/downloads/a dir.txt\"", "printf 'd' > \"$1/state/inbox/a dir.txt\""] });
        then(op, "listed", () => busReady(op) && drop(op).waitingCount === 5, () => {
            same(drop(op).waiting.map(file => file.saveAs).sort(), ["-rf", ".bashrc", "a dir.txt", "report.pdf", "über naïve.txt"].map(name => TaildropRules.safeReceivedName(name)).sort(),
                 "the listing's names, made safe for saving");
            _shell.run(["sh", "-c", "printf '%s\\n' \"$2\" >> \"$1/bus.jsonl\"", "sh", op.dir, arriveLine("report.pdf", 10)], () => {});
        });
        then(op, "the arrival offers Save", () => drop(op).notices.length === 1, () => {
            same(drop(op).notices[0].actions, ["save"], "the notification's action: Save");
            assert(drop(op).save("user"), "save");
        });
        then(op, "saved", () => !op.client.busy && drop(op).saved.length >= 5, () => {
            const outcomes = {};
            for (const item of drop(op).saved)
                outcomes[item.name] = item.outcome + ":" + item.savedAs;
            same(Object.keys(outcomes).sort().map(key => key + "=" + outcomes[key]), ["-rf=saved:rf", ".bashrc=saved:bashrc", "a dir.txt=saved:a dir (1).txt",
                 "report.pdf=saved:report (1).pdf", "über naïve.txt=saved:über naïve.txt"],
                 "rename: a taken name numbered (a folder of that name too), the hidden and the dash names cleaned");
            assertEqual(drop(op).saveError, "", "no error");
        });
        then(op, "inbox emptied", () => drop(op).waitingCount === 0, () => {});
        thenShell(op, "the folder", "cd \"$1/downloads\" && for f in * .[!.]*; do [ -e \"$f\" ] || continue; printf '%s|%s|%s\\n' \"$f\" \"$(stat -c %u -- \"$f\")\" \"$(id -u)\"; done; ls -A \"$1/state/inbox\" | wc -l; cat 'report.pdf'",
                  "folder", lines => {
            same(lines.slice(0, -2).map(line => line.split("|")[0]).sort(), ["a dir (1).txt", "a dir.txt", "bashrc", "report (1).pdf", "report.pdf", "rf", "über naïve.txt"],
                 "exactly the cleaned names; no hidden file, no staging directory left");
            assert(lines.slice(0, -2).every(line => line.split("|")[1] === line.split("|")[2]), "every file owned by this user");
            assertEqual(lines[lines.length - 2], "0", "Tailscale's inbox emptied (DELETE after each placed file)");
            assertEqual(lines[lines.length - 1], "old report", "the existing file untouched");
        });
        then(op, "overwrite", () => true, () => {
            drop(op).setConflict("overwrite");
            _shell.run(["sh", "-c", "printf 'newest' > \"$1/state/inbox/report.pdf\"", "sh", op.dir], () => {
                op.client.taildrop.refreshWaiting();
                op.listedAgain = true;
            });
        });
        then(op, "listed again", () => op.listedAgain === true && drop(op).waitingCount === 1 && !op.client.busy, () => assert(drop(op).save("user"), "save (overwrite)"));
        then(op, "overwritten", () => !op.client.busy && drop(op).waitingCount === 0, () => {});
        thenShell(op, "replaced", "cat \"$1/downloads/report.pdf\"", "replaced", lines => same(lines, ["newest"], "overwrite: replaced"));
        then(op, "skip", () => true, () => {
            drop(op).setConflict("skip");
            _shell.run(["sh", "-c", "printf 'again' > \"$1/state/inbox/report.pdf\"", "sh", op.dir], () => {
                op.client.taildrop.refreshWaiting();
                op.listedThird = true;
            });
        });
        then(op, "listed a third time", () => op.listedThird === true && drop(op).waitingCount === 1 && !op.client.busy, () => assert(drop(op).save("user"), "save (skip)"));
        then(op, "skipped", () => !op.client.busy && drop(op).saved[0]?.outcome === "skipped", () => {
            assertEqual(drop(op).waitingCount, 1, "skip: left waiting in Tailscale's inbox");
            assert(drop(op).save("user"), "save again (skip)");
        });
        then(op, "skipped again", () => !op.client.busy && drop(op).waitingCount === 1, () => {
            assertEqual(drop(op).saved.filter(item => item.outcome === "skipped").length, 1, "a file left again: one line, not two");
            assert(drop(op).openFolder(), "Open folder");
        });
        then(op, "the folder opened", () => op.client.opened === 1, () => {});
        logs(op, "after saving", () => {
            assertEqual(op.pkexecLines.length, 0, "receiving never runs anything as root");
            assert(count(op.logLines, /^curl -sS --fail --unix-socket \S+ http:\/\/local-tailscaled\.sock\/localapi\/v0\/files\/$/) >= 3, "the listing: GET files/");
            assertEqual(count(op.logLines, /^curl .*-X DELETE /), 6, "DELETE only after each placed file (5 + the overwrite; not the skipped)");
            const folderUrl = "file://" + op.dir.split("/").map(part => encodeURIComponent(part)).join("/") + "/downloads";
            assert((ModuleTestKit.opened ?? []).some(entry => entry.url === folderUrl && entry.allowFile === true),
                   "Open folder: the folder (checked to be one), never a file, through Api.openUrl with allowFile");
            assertEqual(count(op.logLines, /^file get/), 0, "never `tailscale file get`");
        });

        // ---- The folder is a link: refused, nothing taken from the inbox ----
        const linked = scenario("folder-link", { env: operator, setup: [operatorPrefs,
            "printf 'x' > \"$1/state/inbox/a.txt\"", "mkdir \"$1/elsewhere\"", "rmdir \"$1/downloads\"", "ln -s \"$1/elsewhere\" \"$1/downloads\""] });
        then(linked, "listed", () => busReady(linked) && drop(linked).waitingCount === 1, () => assert(drop(linked).save("user"), "save"));
        then(linked, "refused", () => !linked.client.busy && drop(linked).saveError !== "", () => {
            assertEqual(drop(linked).saveError, "Folder not found", "a link as the folder: refused");
            assertEqual(drop(linked).waitingCount, 1, "… the file still waiting");
        });
        thenShell(linked, "nothing written", "ls -A \"$1/elsewhere\" | wc -l", "written", lines => same(lines, ["0"], "nothing written through the link"));

        // ---- Auto-save: from an arrival, no loop; never "overwrite"; giving the operator up ----
        const auto = scenario("auto-save", { env: operator, setup: [operatorPrefs, "printf 'mine' > \"$1/downloads/note.txt\""] });
        then(auto, "the operator", () => busReady(auto) && auto.client.canChange && drop(auto).waitingCount === 0, () => {
            drop(auto).setConflict("overwrite");
            drop(auto).setAutoSave(true);
            assert(drop(auto).autoSave, "auto-save on");
            assertEqual(drop(auto).autoConflict, "rename", "… with \"overwrite\" chosen it keeps both");
            _shell.run(["sh", "-c", "printf 'auto' > \"$1/state/inbox/note.txt\" && printf '%s\\n' \"$2\" >> \"$1/bus.jsonl\"", "sh", auto.dir, arriveLine("note.txt", 4)], () => {});
        });
        then(auto, "saved by itself", () => drop(auto).saved.some(item => item.outcome === "saved" && item.savedAs === "note (1).txt") && !auto.client.busy, () => {
            same(drop(auto).notices[0].actions, [], "the notice has no Save while saving is automatic");
            assertEqual(drop(auto).autoRuns, 1, "one run for one arrival");
            drop(auto).setConflict("skip");
        });
        thenShell(auto, "not replaced", "cat \"$1/downloads/note.txt\"", "mine", lines => same(lines, ["mine"], "auto-save never replaced the existing file"));
        // A name taken with "skip": tried once, left, not retried
        then(auto, "skip arrives", () => true, () => {
            _shell.run(["sh", "-c", "printf 'again' > \"$1/state/inbox/note.txt\" && printf '%s\\n' \"$2\" >> \"$1/bus.jsonl\"", "sh", auto.dir,
                        arriveLine("note.txt", 5).replace("10:00:00", "10:01:00")], () => {});
        });
        then(auto, "left once", () => drop(auto).autoRuns === 2 && !auto.client.busy && drop(auto).saved[0]?.outcome === "skipped", () => {});
        waitMs(auto, 1500);
        then(auto, "no retry", () => true, () => {
            assertEqual(drop(auto).autoRuns, 2, "a file left is not tried again (no loop)");
            assertEqual(drop(auto).saved.filter(item => item.outcome === "skipped").length, 1, "… one line for it");
            drop(auto).setFolder(auto.dir + "/missing");
            _shell.run(["sh", "-c", "printf 'b' > \"$1/state/inbox/b.txt\" && printf '%s\\n' \"$2\" >> \"$1/bus.jsonl\"", "sh", auto.dir, arriveLine("b.txt", 1)], () => {});
        });
        then(auto, "folder error", () => drop(auto).autoRuns === 3 && !auto.client.busy && drop(auto).saveError !== "", () => {
            assertEqual(drop(auto).saveError, "Folder not found", "a missing folder: one message");
        });
        waitMs(auto, 1500);
        then(auto, "no storm", () => true, () => {
            assertEqual(drop(auto).autoRuns, 3, "… and no retry");
            assert(auto.client.giveUpOperator(), "give the operator up");
        });
        then(auto, "no longer the operator", () => !auto.client.busy && !auto.client.canChange, () => {
            assert(!drop(auto).canSave && !drop(auto).canSend, "Taildrop no longer offered");
        });
        logs(auto, "after giving up", () => {
            assertEqual(count(auto.logLines, /^set --operator=$/), 1, "`set --operator=` (empty), plainly");
            assertEqual(auto.pkexecLines.length, 0, "… the operator needs no pkexec for it");
        });
        _clock.start();
    }
}
