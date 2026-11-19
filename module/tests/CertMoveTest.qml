import QtQuick
import Quickshell
import qs.api
import qs.tests
import ".."

// Certificates move once from the folder used before (<data home>/h2s-shell/tailscale/certs)
// into the module's data directory (module API 1.13: module.dataDirectory), as the user
// (CertRules.moveScript, CertClient.moveOld). Each case has its own data home under the test
// kit's temporary one, never the user's: a fresh move (modes kept, the old folder gone), a move
// already done, a conflict (a newer file there is never overwritten; an older one is), an
// unreadable old folder, a link in the old folder and the old folder itself a link (refused).
// The outcome is logged once (module.log, counts only).
TestCase {
    id: suite
    suiteName: "tailscale: certificates move into the data directory"
    asynchronous: true

    readonly property string base: (ModuleTestKit.dataHome !== "" ? ModuleTestKit.dataHome : (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"))
        + "/certmove-" + Date.now()
    readonly property string domain: "self.example-tailnet.ts.net"

    property CommandAction _shell: CommandAction {}
    property Component _clientComponent: Component {
        TailscaleClient {}
    }
    property Component _moduleComponent: Component {
        ScenarioHandle {}
    }

    property var _steps: []
    property var _cases: []

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    // A case: its folders, a client that is not running (the move needs no tailscale), and the
    // sh lines that set it up ($1 the case's folder, $2 the old folder, $3 the data directory)
    function makeCase(name, setup) {
        const dir = base + "/" + name;
        const c = { name: name, dir: dir, dataHome: dir + "/data", oldDir: dir + "/data/h2s-shell/tailscale/certs",
                    dataDirectory: dir + "/data/h2s-shell/module-data/tailscale", listing: null, client: null, module: null };
        c.newDir = c.dataDirectory + "/certs";
        _cases.push(c);
        step(c, "set up", () => {
            const lines = ["mkdir -p -- \"$3\"", "chmod 700 -- \"$3\""].concat(setup);
            _shell.run(["sh", "-c", lines.join(" && "), "sh", dir, c.oldDir, c.dataDirectory], result => {
                if (!result.ok)
                    fail(name + ": set up failed: " + result.error + " " + result.stderr);
                c.module = _moduleComponent.createObject(suite, { dataDirectory: c.dataDirectory });
                c.client = _clientComponent.createObject(suite, { module: c.module, system: Object.assign({}, Api.system, { dataHome: c.dataHome }) });
                c.ready = true;
            });
        });
        return c;
    }

    // A step acts once its condition holds (at most 10 s)
    function step(c, description, action, condition) {
        _steps.push({ c: c, description: description, action: action, condition: condition ?? (() => true) });
    }

    // Moves, waits for the outcome, then lists both folders into c.listing
    function move(c, description, check) {
        step(c, description + ": move", () => {
            c.client.cert.moved = null;
            assert(c.client.cert.moveOld(), c.name + ": the move runs");
        }, () => c.ready === true && !c.client.cert.moving);
        step(c, description + ": moved", () => list(c), () => c.client.cert.moved !== null);
        step(c, description + ": listed", () => check(c.client.cert.moved, c.listing), () => c.listing !== null);
    }

    // "<where>/<name> <mode> <kind> <content>" for every entry of the old folder (and its parent's
    // existence) and the data directory's certs; "old: none" when it is gone
    function list(c) {
        c.listing = null;
        const script = [
            "describe() { for path in \"$1\"/* \"$1\"/.[!.]*; do [ -e \"$path\" ] || [ -L \"$path\" ] || continue;",
            "  if [ -L \"$path\" ]; then printf '%s/%s link\\n' \"$2\" \"${path##*/}\";",
            "  else printf '%s/%s %s %s\\n' \"$2\" \"${path##*/}\" \"$(stat -c %a -- \"$path\")\" \"$(cat -- \"$path\" 2> /dev/null)\"; fi; done; }",
            "if [ -L \"$1\" ]; then echo 'old: link'; elif [ -d \"$1\" ]; then chmod u+rx -- \"$1\" 2> /dev/null; describe \"$1\" old; else echo 'old: none'; fi",
            "[ -d \"${1%/*}\" ] || echo 'old parent: none'",
            "[ -d \"$2\" ] && describe \"$2\" new; true"
        ].join("\n");
        _shell.run(["sh", "-c", script, "sh", c.oldDir, c.newDir], result => c.listing = result.lines.map(line => line.trim()).filter(line => line !== ""));
    }

    property Timer _clock: Timer {
        interval: 30
        repeat: true
        property int waited: 0
        onTriggered: {
            const current = suite._steps[0];
            if (!current) {
                stop();
                suite._finishAll();
                return;
            }
            let ready = false;
            try {
                ready = current.condition();
            } catch (error) {}
            waited += interval;
            if (!ready && waited < 10000)
                return;
            waited = 0;
            suite._steps.shift();
            if (!ready) {
                suite.fail(current.c.name + ": timed out waiting: " + current.description);
                suite._steps = suite._steps.filter(other => other.c !== current.c);
                return;
            }
            try {
                current.action();
            } catch (error) {
                suite.fail(current.c.name + ": threw in \"" + current.description + "\": " + error);
            }
        }
    }

    function _finishAll() {
        for (const c of _cases) {
            c.client?.destroy();
            c.module?.destroy();
        }
        // The unreadable case's folder opened again, so it can be removed
        _shell.run(["sh", "-c", "chmod -R u+rwx -- \"$1\" 2> /dev/null; rm -rf -- \"$1\"", "sh", base], () => suite.finish());
    }

    function runAsync() {
        const crt = domain + ".crt";
        const key = domain + ".key";
        const pair = (where, text) => ["mkdir -p -- \"" + where + "\"",
                                       "printf '" + text + "-crt' > \"" + where + "/" + crt + "\"", "chmod 644 -- \"" + where + "/" + crt + "\"",
                                       "printf '" + text + "-key' > \"" + where + "/" + key + "\"", "chmod 600 -- \"" + where + "/" + key + "\""];
        const at = (where, stamp) => "touch -d '" + stamp + "' -- \"" + where + "/" + crt + "\" \"" + where + "/" + key + "\"";

        // ---- Fresh: the pair moves, modes and contents kept; the old folders go ----
        const fresh = makeCase("fresh", pair("$2", "old"));
        move(fresh, "fresh", (moved, listing) => {
            same(listing, ["old: none", "old parent: none", "new/" + crt + " 644 old-crt", "new/" + key + " 600 old-key"],
                 "fresh: both files in the data directory, the certificate 644 and the key 600 as they were; the old folder and the module's folder above it gone");
            same([moved.moved, moved.done, moved.removed], [2, true, true], "fresh: two moved, done");
            same(fresh.module.logged.map(line => line.level + ": " + line.text), ["info: certificates: 2 files moved to the data folder"],
                 "fresh: logged once, counts only (no name)");
        });
        move(fresh, "fresh, again", (moved, listing) => {
            same([moved.done, moved.moved], [true, 0], "fresh, run again: nothing there — done");
            assertEqual(fresh.module.logged.length, 1, "… nothing more logged");
        });

        // ---- Already moved: no old folder, the data directory's files untouched ----
        const already = makeCase("already", pair("$3/certs", "new"));
        move(already, "already", (moved, listing) => {
            same(listing, ["old: none", "old parent: none", "new/" + crt + " 644 new-crt", "new/" + key + " 600 new-key"], "already moved: the files as they were");
            same([moved.done, already.module.logged.length], [true, 0], "… done, nothing logged");
        });

        // ---- Conflict: a newer pair in the data directory stays; the old pair stays too ----
        const conflict = makeCase("conflict", pair("$2", "old").concat([at("$2", "2026-01-01 00:00"), "printf 'x' > \"$2/notes.txt\"", "chmod 600 -- \"$2/notes.txt\""],
                                                                      pair("$3/certs", "new"), [at("$3/certs", "2026-06-01 00:00")]));
        move(conflict, "conflict", (moved, listing) => {
            same(listing, ["old/notes.txt 600 x", "old/" + crt + " 644 old-crt", "old/" + key + " 600 old-key",
                           "new/" + crt + " 644 new-crt", "new/" + key + " 600 new-key"],
                 "conflict: the newer pair in the data directory never overwritten; the old pair and another file left in the old folder");
            same([moved.moved, moved.kept, moved.other, moved.done], [0, 2, 1, false], "conflict: two kept, one other file, not done");
            same(conflict.module.logged.map(line => line.level), ["warn"], "… one warning");
            assert(!conflict.module.logged[0].text.includes("example"), "… without the certificate's name: " + conflict.module.logged[0].text);
        });
        move(conflict, "conflict, again (the next start)", (moved, listing) => {
            assertEqual(moved.kept, 2, "conflict, again: still kept");
            assertEqual(conflict.module.logged.length, 1, "… the same line not logged twice (module.log, one per key)");
        });

        // ---- An older pair in the data directory: the old, newer one replaces it ----
        const older = makeCase("older", pair("$3/certs", "new").concat([at("$3/certs", "2026-01-01 00:00")], pair("$2", "old"), [at("$2", "2026-06-01 00:00")]));
        move(older, "older", (moved, listing) => {
            same(listing, ["old: none", "old parent: none", "new/" + crt + " 644 old-crt", "new/" + key + " 600 old-key"],
                 "an older pair in the data directory: replaced by the newer one from the old folder");
            same([moved.moved, moved.done], [2, true], "… moved, done");
        });

        // ---- The old folder cannot be read: nothing moves, the folder stays ----
        const unreadable = makeCase("unreadable", pair("$2", "old").concat(["chmod 000 -- \"$2\""]));
        move(unreadable, "unreadable", (moved, listing) => {
            same(listing, ["old/" + crt + " 644 old-crt", "old/" + key + " 600 old-key"], "unreadable: nothing moved, the old folder left (listed after opening it)");
            same([moved.moved, moved.done], [0, false], "… not done");
            same(unreadable.module.logged.map(line => line.level + ": " + line.text),
                 ["warn: certificates: not moved to the data folder (the old folder cannot be read); they stay in the old folder"], "… said once");
        });

        // ---- A link in the old folder: refused, never followed; the pair's other file stays too ----
        const link = makeCase("link", ["mkdir -p -- \"$2\"", "printf 'secret' > \"$1/elsewhere\"", "ln -s -- \"$1/elsewhere\" \"$2/" + crt + "\"",
                                       "printf 'old-key' > \"$2/" + key + "\"", "chmod 600 -- \"$2/" + key + "\""]);
        move(link, "link", (moved, listing) => {
            same(listing, ["old/" + crt + " link", "old/" + key + " 600 old-key"], "a link in the old folder: refused and left, its pair left with it, nothing in the data directory");
            same([moved.refused, moved.kept, moved.moved, moved.done], [1, 1, 0, false], "… one refused, one kept");
            assert(link.module.logged[0]?.text.includes("a link, not yours"), "… said: " + link.module.logged[0]?.text);
        });
        step(link, "link: the target untouched", () => _shell.run(["cat", link.dir + "/elsewhere"], result => link.target = result.lines.join("")), () => true);
        step(link, "link: read", () => assertEqual(link.target, "secret", "… the link's target untouched"), () => link.target !== undefined);

        // ---- The old folder itself a link: refused, nothing moves ----
        const folderLink = makeCase("folder-link", pair("$1/real", "old").concat(["mkdir -p -- \"${2%/*}\"", "ln -s -- \"$1/real\" \"$2\""]));
        move(folderLink, "folder link", (moved, listing) => {
            same(listing, ["old: link"], "the old folder a link: left as it is, nothing in the data directory");
            same([moved.moved, moved.done], [0, false], "… not done");
            assert(folderLink.module.logged[0]?.text.includes("the old folder is a link"), "… said");
        });

        // ---- No data directory (the shell could not make it): nothing runs ----
        step(fresh, "no data directory", () => {
            fresh.module.dataDirectory = "";
            same([fresh.client.cert.dir, fresh.client.cert.moveOld()], ["", false], "no data directory: no folder, no move");
            assertEqual(CertRules.problem({ backendState: "Running", certDomains: [domain], self: { dnsName: domain } }, true, fresh.client.cert.dir), "No data folder",
                        "… a certificate is not offered, saying why");
        });

        _clock.start();
    }
}
