import QtQuick
import qs.tests
import ".."

// TaildropRules (delivery step 4) on redacted fixtures and adversarial input: who can receive
// (status's TaildropTarget), paths to send and the user-side check, the CLI's refusals, the
// bus's file fields (bus-taildrop.jsonl, synthetic from ipn/backend.go and feature/taildrop),
// arrivals, progress, received names made safe, the waiting list (files-waiting.json), the
// save script's argv and output, the download folder.
TestCase {
    id: suite
    suiteName: "tailscale: Taildrop rules"

    readonly property var rules: TaildropRules

    function fixture(name) {
        const view = Qt.createQmlObject("import Quickshell.Io\nFileView { blockLoading: true }", suite, "fixture");
        view.path = Qt.resolvedUrl("../../fixtures/" + name);
        const text = view.text();
        view.destroy();
        if (!text)
            fail("fixture " + name + " is empty or missing");
        return text;
    }

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    function run() {
        targets();
        paths();
        check();
        sendErrors();
        bus();
        names();
        waiting();
        saving();
        folders();
    }

    function targets() {
        const status = TailscaleRules.parseStatus(fixture("status-running.json"));
        const devices = TailscaleRules.peers(status, Date.UTC(2026, 10, 15), {});
        const list = rules.targets(devices);
        const peer4 = list.find(item => item.id === "nPEER4CNTRL");
        same([peer4?.available, peer4?.argument, peer4?.note], [true, "100.64.0.4", ""], "real status: TaildropTarget 1 → offered, by its IPv4 address");
        const peer2 = list.find(item => item.id === "nPEER2CNTRL");
        same([peer2?.available, peer2?.note], [false, "offline"], "TaildropTarget 5 (offline) → listed, not offered");
        assert(list.every(item => item.online || item.note === "offline"), "nothing else listed");
        same(rules.targets([{ id: "x", name: "tv", canReceiveFiles: false, fileSharingNote: "its system cannot receive files" },
                            { id: "y", name: "other", canReceiveFiles: false, fileSharingNote: "it belongs to another user" }]), [],
             "other reasons (unsupported OS, another user, missing capability): not targets");
        same(rules.targets([{ id: "z", name: "v6only", canReceiveFiles: true, ipv4: "" }]).map(item => [item.available, item.note]), [[false, "no address"]],
             "no IPv4 address: listed, not offered");
        assertEqual(rules.targetArgument({ ipv4: "192.168.1.5" }), "", "an address outside Tailscale's range: none");
        assertEqual(rules.targetArgument({ ipv4: "-100.64.0.1" }), "", "never something that reads as an option");
        same(rules.targets(null), [], "no devices: none");
    }

    function paths() {
        assertEqual(rules.pathProblem("/home/u/a.txt"), "", "an absolute path");
        same(["relative.txt", "", "/a/../etc/shadow", "/a/./b", "/a\nb", "/tmp/", "/" + "x".repeat(4100), 5].map(path => rules.pathProblem(path) !== ""),
             [true, true, true, true, true, true, true, true], "refused: relative, empty, \"..\", \".\", a newline, a trailing slash, too long, not text");
        const parsed = rules.parsePaths("/home/u/a b.txt\n\nfile:///home/u/%C3%BCber.txt\nfile://localhost/home/u/c.txt\nfile://host/x\nrelative\n/home/u/a b.txt\n-rf");
        same(parsed.paths, ["/home/u/a b.txt", "/home/u/über.txt", "/home/u/c.txt"], "pasted lines and file URLs (decoded), duplicates dropped");
        same(parsed.problems.map(item => item.problem), ["not a local file", "not an absolute path", "not an absolute path"], "another host, a relative path, \"-rf\" refused");
        same(rules.parsePaths(["file:///a/%ZZ"]).problems.map(item => item.problem), ["not a valid file URL"], "a broken URL refused");
        assertEqual(rules.baseName("/home/u/with space.pdf"), "with space.pdf", "the base name the receiver sees");
    }

    function check() {
        const argv = rules.checkArgv(["/a", "/b c"]);
        same(argv.slice(0, 5), ["find", "-P", "/a", "/b c", "-maxdepth"], "find, not following links, the paths (absolute: never read as an expression)");
        const output = "file\t5\t/a\nlink\t0\t/l\nfolder\t0\t/d\nunreadable\t0\t/s\nfile\t9\t/b c\n";
        const result = rules.parseCheck(output, ["/a", "/b c", "/l", "/d", "/s", "/gone"]);
        same(result.map(item => [item.ok, item.size, item.problem]),
             [[true, 5, ""], [true, 9, ""], [false, 0, "Link"], [false, 0, "Folder"], [false, 0, "Not readable"], [false, 0, "Not found"]], "each path's verdict, in the order asked");
        same(rules.parseCheck("file\t1\t/x\nfile\t1\t/y", ["/y"]).length, 1, "only what was asked");
        const command = TailscaleRules.commandFor("fileCp", rules.sendCommandArgs(["/a", "/b c"], { argument: "100.64.0.4" }));
        same(command.argv, ["tailscale", "file", "cp", "--", "/a", "/b c", "100.64.0.4:"], "`file cp -- <paths> <address>:`");
        assertEqual(command.timeLimit, "send", "… its own limit (TaildropClient runs it as the user, never through pkexec)");
        assertEqual(TailscaleRules.timeLimits.send, 21600, "… 6 hours overall (a stalled send is stopped after 2 minutes without progress)");
        assert(!/100\.64/.test(command.description), "… no address in the description (it reaches notifications)");
    }

    function sendErrors() {
        same(rules.sendError(1, fixture("stderr-access-denied-file-cp.txt")).kind, "denied", "the CLI's access denied (source: cli.go)");
        same(rules.sendError(1, "can't send to 100.64.0.9: cannot send files: target's OS does not support Taildrop").message,
             "Device can't receive files", "the daemon's refusal");
        same(rules.sendError(1, "can't send to 100.64.0.9: unknown target; not in your Tailnet").message, "Unknown device", "an unknown target");
        same(rules.sendError(1, "directories not supported").kind, "folder", "a folder");
        same(rules.sendError(124, "").kind, "timeout", "timeout(1)'s 124");
        same(rules.sendError(1, "500 Internal Server Error: \u001b[31mpeer 100.64.0.7 gone").message, "500 Internal Server Error: [31mpeer [address] gone",
             "anything else: its last line, control characters and addresses removed");
    }

    function bus() {
        const lines = fixture("bus-taildrop.jsonl").split("\n").filter(line => line !== "");
        const digests = lines.map(line => rules.notifyFiles(line));
        same([digests[0].initial, digests[0].files, digests[0].waiting], [true, false, null], "the watch's first message: initial, no file fields");
        same(digests[1].incoming, [{ name: "holiday.jpg", started: Date.UTC(2026, 10, 16, 10), size: 2048, received: 1024, done: false }], "a transfer coming in");
        same([digests[2].incoming[0].done, digests[2].waiting], [true, true], "done, and FilesWaiting attached");
        same([digests[3].files, digests[3].waiting, digests[3].initial], [true, true, false], "any later message carries FilesWaiting while files wait");
        same([digests[7].files, digests[7].waiting, digests[7].initial], [false, null, false], "… its absence on a later message: none wait");
        let seen = [];
        let found = rules.arrivals(seen, digests[1].incoming);
        same(found.arrived, [], "not done: no arrival");
        found = rules.arrivals(found.seen, digests[2].incoming);
        same(found.arrived.map(item => item.name), ["holiday.jpg"], "done: one arrival");
        found = rules.arrivals(found.seen, digests[2].incoming);
        same(found.arrived, [], "the same again (a replayed stream): not twice");
        const progress = rules.sendProgress(digests[5].outgoing, "nPEER4CNTRL", ["notes.txt"], Date.UTC(2026, 10, 16, 10, 5));
        same(progress["notes.txt"], { started: Date.UTC(2026, 10, 16, 10, 5), sent: 2000, size: 4000, finished: false, succeeded: false },
             "this send's entry: the peer's, started since; an older finished one of the same name and another peer's ignored");
        assertEqual(rules.percent(2000, 4000), 50, "50 %");
        assertEqual(rules.percent(10, -1), -1, "size unknown: no percentage");
        same(rules.notifyFiles("not json"), { files: false, initial: false, waiting: null, incoming: null, outgoing: null }, "garbage: nothing");
        same(rules.notifyFiles({ IncomingFiles: [null, 5, { Name: "" }, { Name: "a", DeclaredSize: "x" }] }).incoming.map(item => [item.name, item.size]), [["a", -1]],
             "odd entries dropped, odd fields defaulted");
    }

    function names() {
        const cases = [
            ["holiday.jpg", "holiday.jpg"], ["../x", "_x"], ["/etc/passwd", "_etc_passwd"], [".bashrc", "bashrc"], ["..", "received file"],
            ["...hidden", "hidden"], ["-rf", "rf"], ["a\nb", "a_b"], ["a‮gpj.exe", "a_gpj.exe"], ["​.profile", "_.profile"],
            ["  spaced  ", "spaced"], ["back\\slash", "back_slash"], ["über naïve.txt", "über naïve.txt"], [5, ""]
        ];
        for (const [input, expected] of cases)
            assertEqual(rules.safeReceivedName(input), expected, "safe name: " + JSON.stringify(input));
        const long = rules.safeReceivedName("a".repeat(300) + ".tar.gz");
        assert(long.endsWith(".gz") && long.length <= rules.maxNameBytes, "300 characters: cut to " + rules.maxNameBytes + " bytes, the extension kept (" + long.length + ")");
        const wide = rules.safeReceivedName("ü".repeat(300));
        assert(wide.length === rules.maxNameBytes / 2, "two-byte characters cut by bytes, never inside a character (" + wide.length + ")");
        assert(rules.safeReceivedName("\u0007\u0000x").indexOf("\u0000") < 0, "no NUL");
        assertEqual(rules.displayName("a‮b"), "a�b", "shown: invisible characters as �");
        assertEqual(rules.displayName("x".repeat(200)).length, 111, "shown: long names shortened");
        assertEqual(rules.numbered("photo.jpg", 2), "photo (2).jpg", "numbered as the CLI does");
        assertEqual(rules.numbered("README", 1), "README (1)", "… without an extension");
    }

    function waiting() {
        const parsed = rules.parseWaiting(fixture("files-waiting.json"));
        assert(parsed.ok, "the waiting list read");
        same(parsed.files.map(file => file.saveAs), ["holiday.jpg", "bashrc", "rf", "report (1).pdf", "bashrc (2)", "_gpj.exe"],
             "made safe, and unique in the batch (\".bashrc\" and \"bashrc\")");
        same(parsed.files.map(file => file.escaped).slice(0, 4), ["holiday.jpg", ".bashrc", "-rf", "report%20(1).pdf"], "names escaped for the URL");
        same(rules.parseWaiting("null"), { ok: true, files: [] }, "null: none");
        same(rules.parseWaiting("{}").ok, false, "not a list: not read");
        same(rules.parseWaiting("<html>").ok, false, "garbage: not read");
    }

    function saving() {
        const files = rules.parseWaiting(fixture("files-waiting.json")).files;
        const options = { curl: "/bin/curl", socket: "/run/ts.sock", timeout: "/bin/timeout", seconds: 600, policy: "rename", folder: "/home/u/Downloads/", files: files };
        const prepared = rules.saveArgv(options);
        assert(prepared.ok, "the save's argv");
        same(prepared.argv.slice(0, 2).concat(prepared.argv.slice(3, 10)), ["sh", "-c", "sh", "/bin/curl", "/run/ts.sock", "/bin/timeout", "600", "rename", "/home/u/Downloads"],
             "sh -c <constant script> with every value an argument (never in the script's text)");
        same(prepared.argv.slice(10, 14), ["holiday.jpg", "holiday.jpg", ".bashrc", "bashrc"], "pairs: escaped name, name to save as");
        assertEqual(prepared.argv[2], rules.saveScript, "the script is the constant one");
        assert(rules.saveScript.indexOf("-L \"$dir\"") >= 0 && rules.saveScript.indexOf("-O \"$dir\"") >= 0, "the script refuses a link and a folder this user does not own");
        assert(rules.saveScript.indexOf("mv -n -T") >= 0 && rules.saveScript.indexOf("mv -f -T") >= 0, "… moves by rename, never into a directory");
        assert(!/pkexec|sudo/.test(rules.saveScript), "… never as root");
        assert(rules.saveScript.indexOf("kill \"$child\"") >= 0 && rules.saveScript.indexOf("rm -rf -- \"$staging\"") >= 0, "… on exit it kills a running request, then removes its own staging directory");
        for (const [change, expected] of [[{ curl: "" }, "Needs curl"], [{ policy: "explode" }, "Bad setting"],
                [{ folder: "Downloads" }, "Folder not usable"], [{ files: [] }, "Nothing waiting"],
                [{ files: [{ escaped: "a%2Fb/c", saveAs: "x" }] }, "Bad file name"], [{ files: [{ escaped: "..", saveAs: "x" }] }, "Bad file name"],
                [{ files: [{ escaped: ".", saveAs: "x" }] }, "Bad file name"], [{ files: [{ escaped: "x", saveAs: ".bashrc" }] }, "Bad file name"]])
            assertEqual(rules.saveArgv(Object.assign({}, options, change)).error, expected, "refused: " + expected);
        const output = "saved\tholiday.jpg\tholiday.jpg\nsaved-kept\tbashrc\tbashrc (1)\nskipped\trf\nfailed\treport (1).pdf\tfetch\n";
        same(rules.parseSave(output, "/home/u/Downloads").results.map(item => [item.outcome, item.savedAs, item.kept, item.reason]),
             [["saved", "holiday.jpg", false, ""], ["saved", "bashrc (1)", true, ""], ["skipped", "", true, "name taken"], ["failed", "", true, "not fetched"]], "the script's lines read");
        assertEqual(rules.parseSave("saved\ta\ta (1)", "/x/").results[0].path, "/x/a (1)", "the saved file's path");
        assertEqual(rules.parseSave("error\tnot-yours\n", "/x").error, "Not your folder", "the folder's problem");
        same(rules.listArgv("/bin/curl", "/run/ts.sock"), ["/bin/curl", "-sS", "--fail", "--unix-socket", "/run/ts.sock", "http://local-tailscaled.sock/localapi/v0/files/"],
             "the listing: GET files/ without ?waitsec (lists, never waits, changes nothing)");
    }

    function folders() {
        assertEqual(rules.downloadFolder("XDG_DOWNLOAD_DIR=\"$HOME/Hämtningar\"\n", "/home/u"), "/home/u/Hämtningar", "XDG_DOWNLOAD_DIR with $HOME");
        assertEqual(rules.downloadFolder("# comment\nXDG_DOWNLOAD_DIR=\"/data/dl/\"", "/home/u"), "/data/dl", "an absolute one");
        assertEqual(rules.downloadFolder("XDG_DOWNLOAD_DIR=\"$HOME/\"", "/home/u"), "/home/u/Downloads", "\"$HOME/\" (none): ~/Downloads");
        assertEqual(rules.downloadFolder("XDG_DOWNLOAD_DIR=\"$(rm -rf ~)\"", "/home/u"), "/home/u/Downloads", "never run: a command substitution is no folder");
        assertEqual(rules.downloadFolder("", "/home/u/"), "/home/u/Downloads", "no file: ~/Downloads");
        assertEqual(rules.downloadFolder("", ""), "", "no home: none");
        assertEqual(rules.folderUrl("/home/u/My Files/#1"), "file:///home/u/My%20Files/%231", "a folder as a file: URL, each part encoded");
        assertEqual(rules.folderUrl("relative"), "", "not absolute: no URL");
        assertEqual(rules.folderProblem("/a/../b"), "\".\" or \"..\" in the path", "\"..\" refused");
        same([rules.waitingText(2, true), rules.waitingText(1, false), rules.waitingText(-1, true), rules.waitingText(-1, false), rules.waitingText(0, true)],
             ["2 files received", "1 file received", "Files received", "", ""], "the entry's status line");
    }
}
