import QtQuick
import qs.tests
import ".."

// TailscaleRules, the process side: the IPN bus (one message per line, and the pretty-printed
// form fed in arbitrary chunks), what an exit code and stderr mean (the real "Access denied"
// and not-running texts, the `up` trap), pkexec's own exits, the one command builder (argv
// arrays only; never a flag on `up`), the pkexec form, and the CLI's other outputs (login,
// ping, netcheck).
TestCase {
    id: suite
    suiteName: "tailscale: bus, errors, commands"

    readonly property var rules: TailscaleRules

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

    // Feeds `text` to the splitter in pieces of `size` characters → { objects, dropped }
    function split(text, size) {
        let state = rules.jsonSplitter();
        const objects = [];
        let dropped = 0;
        for (let i = 0; i < text.length; i += size) {
            const result = rules.jsonFeed(state, text.slice(i, i + size));
            state = result.state;
            objects.push(...result.objects);
            dropped += result.dropped;
        }
        return { objects: objects, dropped: dropped, state: state };
    }

    function run() {
        // --- notifyDigest, line by line ---
        const lines = fixture("bus-lines.jsonl").split("\n").filter(line => line !== "");
        const expectedKinds = [["state", "prefs"], ["health"], ["suggested-exit-node"], ["client-version"], ["state"], ["state"], ["browse"],
                               ["login-finished"], ["state"], ["state"], ["error"], ["files"], ["files"], ["engine"], ["health"], ["changed"]];
        {
            assertEqual(lines.length, expectedKinds.length, "bus: the fixture's messages");
            const digests = lines.map(line => rules.notifyDigest(line));
            same(digests.map(digest => digest.kinds), expectedKinds, "bus: each message's kinds");
            same(digests.filter(digest => digest.state !== "").map(digest => digest.state),
                 ["Running", "Stopped", "NeedsLogin", "Starting", "Running"], "bus: numeric states named");
            assert(digests[0].prefs.ok && digests[0].prefs.acceptRoutes && digests[0].prefs.wantRunning, "bus: Prefs parsed as prefs");
            assertEqual(digests[0].version, "1.104.4", "bus: Version");
            same(digests[1].health, [{ code: "update-available", severity: "low", title: "Update available",
                                       text: "An update from version 1.104.4 to 1.106.0 is available.", impactsConnectivity: false }], "bus: health warnings");
            assertEqual(digests[2].suggestedExitNode, "nMULL21CNTRL", "bus: the suggested exit node");
            assertEqual(digests[3].clientVersion.latestVersion, "1.106.0", "bus: the client version");
            assertEqual(digests[6].browseToUrl, "https://login.tailscale.com/a/REDACTED", "bus: BrowseToURL");
            assert(digests[7].loginFinished, "bus: LoginFinished");
            assertEqual(digests[10].errMessage, "example: the coordination server did not answer", "bus: ErrMessage");
            same(digests[14].health, [], "bus: health with no warnings is an empty list, not null");
            assert(digests.every(digest => digest.ok), "bus: every message read");

            const odd = text => rules.notifyDigest(text).kinds.join(",");
            assertEqual(odd('{"State":99}'), "changed", "bus: an unknown state number");
            assertEqual(odd('{"State":1.5}'), "changed", "bus: a fractional state");
            assertEqual(odd('{"State":-1}'), "changed", "bus: a negative state");
            assertEqual(rules.notifyDigest('{"State":"Running"}').state, "Running", "bus: a state by name is taken too");
            assertEqual(rules.notifyDigest('{"State":1}').state, "InUseOtherUser", "bus: state 1 is InUseOtherUser");
            assertEqual(odd('{"BrowseToURL":"javascript:alert(1)"}'), "changed", "bus: a URL that is not http(s) is not offered");
            assertEqual(odd('{"BrowseToURL":"https://a b"}'), "changed", "bus: a URL with a space is not offered");
            assertEqual(odd('{"LoginFinished":null}'), "changed", "bus: LoginFinished null is not a login");
            assertEqual(odd('{"ErrMessage":""}'), "changed", "bus: an empty error");
            assertEqual(odd('{"Health":{"Warnings":{"__proto__":{"Severity":"high"},"x":5}}}'), "health", "bus: prototype-named warnings are data");
            assertEqual(odd('{"Prefs":"x","Engine":[]}'), "changed", "bus: wrong types are ignored");
            assertEqual(odd("{}"), "changed", "bus: an empty message is a change");
            for (const bad of [null, "", "nope", "[1]", 5, "{"])
                assertEqual(rules.notifyDigest(bad).ok, false, "bus: " + JSON.stringify(bad) + " is not a message");
        }

        // --- the splitter: pretty-printed, one per line, in any chunks ---
        {
            const pretty = fixture("bus-pretty.txt");
            for (const size of [1, 3, 7, 64, 1000, pretty.length]) {
                const result = split(pretty, size);
                same(result.objects.map(object => rules.notifyDigest(object).kinds), expectedKinds, "split: pretty-printed in pieces of " + size);
                assertEqual(result.dropped, 0, "split: nothing dropped, pieces of " + size);
                assertEqual(result.state.buffer, "", "split: nothing left over, pieces of " + size);
            }
            const lined = split(fixture("bus-lines.jsonl"), 5);
            assertEqual(lined.objects.length, expectedKinds.length, "split: one per line works too");
            assertEqual(lined.objects[15].SomethingNewer.Field, "with a } brace and a \"quote\" in a string", "split: braces and quotes inside strings");

            const half = rules.jsonFeed(rules.jsonSplitter(), '{"a":"x\\');
            const rest = rules.jsonFeed(half.state, '"y"}{"b":1}');
            assert(half.objects.length === 0 && rest.objects.length === 2 && rest.objects[0].a === "x\"y", "split: an escape cut between chunks");
            const noisy = split('warning: something\n{"State":6}\n[1,2]\n{"a":}\n{"BrowseToURL":"https://login.tailscale.com/a/x"}', 4);
            same(noisy.objects.map(object => Object.keys(object)[0]), ["State", "BrowseToURL"], "split: text, a list and broken JSON between objects skipped");
            assert(noisy.dropped >= 2, "split: and counted as dropped");
            const pending = rules.jsonFeed(rules.jsonSplitter(), '{"State":');
            assert(pending.objects.length === 0 && pending.state.buffer === '{"State":', "split: an incomplete object waits");
            same(rules.jsonFeed(null, '{"x":1}').objects, [{ x: 1 }], "split: no state is a fresh one");
            same(rules.jsonFeed(rules.jsonSplitter(), null).objects, [], "split: no chunk, nothing");

            // An object bigger than maxObjectBytes is dropped whole; the stream goes on
            const huge = '{"big":"' + "x".repeat(rules.maxObjectBytes + 10) + '","n":{"m":"}"}}';
            const afterHuge = split(huge + '\n{"State":4}', 1 << 20);
            same(afterHuge.objects, [{ State: 4 }], "split: an oversized object dropped, the next one read");
            assertEqual(afterHuge.dropped, 1, "split: the oversized one counted");
            assert(afterHuge.state.buffer.length === 0, "split: nothing of it kept");
        }

        // --- errorKind: the real texts ---
        {
            const kind = (code, name) => rules.errorKind(code, fixture(name)).kind;
            assertEqual(kind(1, "stderr-access-denied-set.txt"), "denied", "error: set denied (real)");
            assertEqual(kind(1, "stderr-access-denied-switch-list.txt"), "denied", "error: switch --list denied (real)");
            assertEqual(kind(1, "stderr-access-denied-logout.txt"), "denied", "error: logout denied");
            assertEqual(kind(1, "stderr-access-denied-file.txt"), "denied", "error: file get denied");
            assertEqual(kind(1, "stderr-not-running.txt"), "not-running", "error: daemon not running (real)");
            assertEqual(kind(1, "stderr-not-running-refused.txt"), "not-running", "error: socket refusing");
            assertEqual(kind(1, "stderr-up-accidental-revert.txt"), "revert", "error: the `up` trap (real)");
            assertEqual(kind(1, "stderr-needs-login.txt"), "needs-login", "error: logged out");
            assertEqual(kind(1, "stderr-timeout.txt"), "timeout", "error: the CLI's timeout");
            const other = rules.errorKind(1, fixture("stderr-switch-no-profile.txt"));
            same(other, { kind: "other", message: "No profile named \"zz99\"" }, "error: anything else, its first line");
            assertEqual(rules.errorKind(0, fixture("stderr-access-denied-set.txt")).kind, "", "error: exit 0 is no error");
            assertEqual(rules.errorKind(124, "").kind, "timeout", "error: timeout(1)'s 124");
            same(rules.errorKind(1, null), { kind: "other", message: "Tailscale exited with status 1." }, "error: no stderr");
            same(rules.errorKind("x", 42), { kind: "other", message: "42" }, "error: odd types");
            assert(rules.errorKind(1, fixture("stderr-access-denied-set.txt")).message.length > 10, "error: a sentence for the notification");
            assertEqual(rules.errorKind(1, "\n\n   \n").message, "Tailscale exited with status 1.", "error: blank stderr");
        }

        // --- pkexecOutcome: as the shell reads pkexec ---
        {
            same(rules.pkexecOutcome(0), { outcome: "ok", failure: false, message: "" }, "pkexec: 0 ok");
            const dismissed = rules.pkexecOutcome(126);
            assert(dismissed.outcome === "dismissed" && dismissed.failure === false, "pkexec: 126 dismissed, not a failure");
            same(rules.pkexecOutcome(127), { outcome: "no-agent", failure: true, message: "No authentication agent answered." },
                 "pkexec: 127 no agent, a failure with the contract's sentence");
            assert(rules.pkexecOutcome(1).outcome === "failed" && rules.pkexecOutcome(1).failure, "pkexec: anything else is the program's failure");
            assertEqual(rules.pkexecOutcome(null).outcome, "failed", "pkexec: no code");
        }

        // --- commandFor: the table ---
        {
            const argv = (name, args) => rules.commandFor(name, args).argv;
            const table = [
                ["connect", {}, ["tailscale", "up"]],
                ["disconnect", {}, ["tailscale", "down"]],
                ["login", {}, ["tailscale", "login"]],
                ["addAccount", {}, ["tailscale", "login"]],
                ["logout", {}, ["tailscale", "logout"]],
                ["exitNode", { node: "100.64.0.4" }, ["tailscale", "set", "--exit-node=100.64.0.4"]],
                ["exitNode", { node: "se-sto-wg-021.mullvad.ts.net" }, ["tailscale", "set", "--exit-node=se-sto-wg-021.mullvad.ts.net"]],
                ["exitNode", { node: "auto:any" }, ["tailscale", "set", "--exit-node=auto:any"]],
                ["exitNodeAuto", {}, ["tailscale", "set", "--exit-node=auto:any"]],
                ["exitNodeNone", {}, ["tailscale", "set", "--exit-node="]],
                ["allowLan", { on: true }, ["tailscale", "set", "--exit-node-allow-lan-access=true"]],
                ["acceptRoutes", { on: false }, ["tailscale", "set", "--accept-routes=false"]],
                ["acceptDns", { on: true }, ["tailscale", "set", "--accept-dns=true"]],
                ["shieldsUp", { on: true }, ["tailscale", "set", "--shields-up=true"]],
                ["ssh", { on: false }, ["tailscale", "set", "--ssh=false"]],
                ["webClient", { on: true }, ["tailscale", "set", "--webclient=true"]],
                ["advertiseExitNode", { on: true }, ["tailscale", "set", "--advertise-exit-node=true"]],
                ["updateCheck", { on: false }, ["tailscale", "set", "--update-check=false"]],
                ["hostname", { name: "box" }, ["tailscale", "set", "--hostname=box"]],
                ["hostname", { name: "" }, ["tailscale", "set", "--hostname="]],
                ["advertiseRoutes", { routes: ["192.168.1.0/24", "fd00:99::/64", "192.168.1.0/24"] }, ["tailscale", "set", "--advertise-routes=192.168.1.0/24,fd00:99::/64"]],
                ["advertiseRoutes", { routes: [] }, ["tailscale", "set", "--advertise-routes="]],
                ["operator", { user: "alice" }, ["tailscale", "set", "--operator=alice"]],
                ["switchAccount", { id: "c3d4" }, ["tailscale", "switch", "c3d4"]],
                ["switchList", {}, ["tailscale", "switch", "--list", "--json"]],
                ["removeAccount", { id: "c3d4" }, ["tailscale", "switch", "remove", "c3d4"]],
                ["ping", { target: "laptop", count: 3 }, ["tailscale", "ping", "--c=3", "--timeout=3s", "laptop"]],
                ["ping", { target: "100.64.0.11" }, ["tailscale", "ping", "--c=1", "--timeout=3s", "100.64.0.11"]],
                ["netcheck", {}, ["tailscale", "netcheck", "--format=json"]],
                ["fileCp", { files: ["/home/u/a.txt", "/home/u/with space.pdf"], target: "laptop" }, ["tailscale", "file", "cp", "/home/u/a.txt", "/home/u/with space.pdf", "laptop:"]],
                ["fileTargets", {}, ["tailscale", "file", "cp", "--targets"]],
                ["fileGet", { directory: "/home/u/Downloads" }, ["tailscale", "file", "get", "--conflict=rename", "/home/u/Downloads"]],
                ["serveStatus", {}, ["tailscale", "serve", "status", "--json"]],
                ["serveReset", {}, ["tailscale", "serve", "reset"]],
                ["serveAdd", { protocol: "https", port: 443, target: 3000 }, ["tailscale", "serve", "--bg", "--https=443", "3000"]],
                ["serveAdd", { protocol: "http", port: 80, target: "http://localhost:8080/app" }, ["tailscale", "serve", "--bg", "--http=80", "http://localhost:8080/app"]],
                ["serveRemove", { protocol: "https", port: 443 }, ["tailscale", "serve", "--bg", "--https=443", "off"]],
                ["funnelStatus", {}, ["tailscale", "funnel", "status", "--json"]],
                ["funnelReset", {}, ["tailscale", "funnel", "reset"]],
                ["funnelAdd", { protocol: "https", port: 8443, target: "3000" }, ["tailscale", "funnel", "--bg", "--https=8443", "3000"]],
                ["funnelRemove", { protocol: "https", port: 8443 }, ["tailscale", "funnel", "--bg", "--https=8443", "off"]],
                ["cert", { domain: "self.example-tailnet.ts.net", certFile: "/home/u/c.crt", keyFile: "/home/u/c.key" },
                 ["tailscale", "cert", "--cert-file=/home/u/c.crt", "--key-file=/home/u/c.key", "self.example-tailnet.ts.net"]],
                ["lockStatus", {}, ["tailscale", "lock", "status"]],
                ["status", {}, ["tailscale", "status", "--json"]],
                ["prefs", {}, ["tailscale", "debug", "prefs"]],
                ["exitNodeSuggest", {}, ["tailscale", "exit-node", "suggest"]],
                ["exitNodeList", {}, ["tailscale", "exit-node", "list"]],
                ["dnsStatus", {}, ["tailscale", "dns", "status", "--json"]],
                ["version", {}, ["tailscale", "version", "--json"]],
                ["derpMap", {}, ["tailscale", "debug", "derp-map"]],
                ["nickname", { name: "home" }, ["tailscale", "set", "--nickname=home"]],
                ["startService", {}, ["systemctl", "start", "tailscaled.service"]]
            ];
            for (const row of table)
                same(argv(row[0], row[1]), row[2], "command " + row[0] + " " + JSON.stringify(row[1]));
            const covered = table.map(row => row[0]).concat(["watch"]);
            same(rules.commandNames.filter(name => !covered.includes(name)), [], "command: every name in the table");
            assertEqual(argv("watch", {})[2], "watch-ipn", "command: watch through the CLI");

            // Every command: an argv of plain strings, a description, never a flag on `up`
            let problems = [];
            for (const row of table.concat([["watch", {}, null]])) {
                const command = rules.commandFor(row[0], row[1]);
                if (!command.ok || !Array.isArray(command.argv) || !command.argv.every(item => typeof item === "string" && !/[\n\u0000]/.test(item)))
                    problems.push(row[0] + ": argv");
                if (command.argv[1] === "up" && command.argv.length !== 2)
                    problems.push(row[0] + ": a flag on up");
                if (command.argv[1] === "login" && command.argv.length !== 2)
                    problems.push(row[0] + ": a flag on login");
                if (typeof command.description !== "string" || command.description === "")
                    problems.push(row[0] + ": description");
                if (command.changes && !command.privileged && command.argv[0] === "tailscale")
                    problems.push(row[0] + ": a change not marked privileged");
            }
            same(problems, [], "command: argv arrays of strings, described, no flag on up/login, changes privileged");
            const reads = ["status", "prefs", "ping", "netcheck", "exitNodeSuggest", "exitNodeList", "serveStatus", "lockStatus", "version", "watch"];
            assert(reads.every(name => !rules.commandFor(name, { target: "laptop" }).changes), "command: reading commands change nothing");
            assert(reads.every(name => !rules.commandFor(name, { target: "laptop" }).privileged), "command: reading commands need no privilege");
            const switchList = rules.commandFor("switchList", {});
            assert(!switchList.changes && switchList.privileged, "command: switch --list reads but is denied to non-operators");
            assert(rules.commandFor("fileGet", { directory: "/tmp/in" }).writesAsRoot && rules.commandFor("cert", { domain: "a.b", certFile: "/a", keyFile: "/b" }).writesAsRoot,
                   "command: file get and cert would write as root through pkexec");
            assert(rules.commandFor("login", {}).longRunning, "command: login waits for the browser");

            // Refusals: never a half-checked argv
            const refusals = [
                ["operator", { user: "root; rm -rf /" }], ["operator", { user: "Alice" }], ["operator", { user: "" }], ["operator", { user: "$USER" }],
                ["operator", {}], ["hostname", { name: "bad_name" }], ["hostname", { name: "-x" }], ["hostname", { name: 5 }],
                ["advertiseRoutes", { routes: ["192.168.1.5/24"] }], ["advertiseRoutes", { routes: ["0.0.0.0/0"] }], ["advertiseRoutes", { routes: ["::/0"] }],
                ["advertiseRoutes", { routes: ["300.1.1.1/24"] }], ["advertiseRoutes", { routes: ["fd00::/129"] }], ["advertiseRoutes", { routes: "10.0.0.0/8" }],
                ["advertiseRoutes", { routes: [null] }],
                ["exitNode", { node: "--evil" }], ["exitNode", { node: "" }], ["exitNode", {}], ["exitNode", { node: "a b" }],
                ["ping", { target: "-c" }], ["ping", { target: "laptop", count: 0 }], ["ping", { target: "laptop", count: 31 }],
                ["ping", { target: "laptop", count: 2.5 }], ["ping", { target: "laptop", count: "3" }], ["ping", {}],
                ["fileCp", { files: ["relative.txt"], target: "laptop" }], ["fileCp", { files: ["/a\nb"], target: "laptop" }],
                ["fileCp", { files: ["/a/../etc/shadow"], target: "laptop" }], ["fileCp", { files: [], target: "laptop" }],
                ["fileCp", { files: ["/a"], target: "fd7a::1" }], ["fileCp", { files: ["/a"], target: "-x" }], ["fileCp", { files: "/a", target: "laptop" }],
                ["fileGet", { directory: "Downloads" }], ["fileGet", { directory: "/tmp", conflict: "explode" }],
                ["serveAdd", { protocol: "https", port: 443, target: "http://example.com" }], ["serveAdd", { protocol: "https", port: 0, target: 3000 }],
                ["serveAdd", { protocol: "gopher", port: 70, target: 3000 }], ["serveAdd", { protocol: "https", port: 443, target: "3000; rm" }],
                ["funnelAdd", { protocol: "https", port: 8080, target: 3000 }], ["funnelAdd", { protocol: "http", port: 80, target: 3000 }],
                ["cert", { domain: "100.64.0.1", certFile: "/a", keyFile: "/b" }], ["cert", { domain: "a.b", certFile: "a", keyFile: "/b" }],
                ["switchAccount", { id: "a b" }], ["switchAccount", { id: "" }], ["removeAccount", { id: "--all" }],
                ["nonsense", {}], ["__proto__", {}], ["constructor", {}], [null, null], [undefined, "x"]
            ];
            const leaked = refusals.filter(row => {
                const command = rules.commandFor(row[0], row[1]);
                return command.ok || command.argv.length !== 0 || command.error === "";
            }).map(row => JSON.stringify(row));
            same(leaked, [], "command: " + refusals.length + " bad requests refused with a reason, no argv");
            assertEqual(rules.commandFor("hostname", null).argv.join(" "), "tailscale set --hostname=", "command: args null is no args");
        }

        // --- privileged: the pkexec form ---
        {
            const ts = "/run/current-system/sw/bin/tailscale";
            const to = "/run/current-system/sw/bin/timeout";
            const limited = { timeout: to, seconds: 60 };
            same(rules.privileged(["tailscale", "set", "--shields-up=true"], ts, limited).argv,
                 ["pkexec", to, "-k", "5", "60", ts, "set", "--shields-up=true"], "privileged: pkexec, then timeout around tailscale, both by absolute path");
            same(rules.privileged(rules.commandFor("connect", {}).argv, "/usr/bin/tailscale", { timeout: "/usr/bin/timeout", seconds: 60 }).argv,
                 ["pkexec", "/usr/bin/timeout", "-k", "5", "60", "/usr/bin/tailscale", "up"], "privileged: connect stays bare (the limit is timeout's, never a flag)");
            const login = rules.privileged(rules.commandFor("login", {}).argv, ts, { timeout: to, seconds: 600, description: "Logging in to Tailscale" });
            same(login.argv, ["pkexec", to, "-k", "5", "600", ts, "login"], "privileged: the elevated login ends by itself (timeout 600 s under pkexec)");
            assertEqual(login.prompt, "Logging in to Tailscale: runs `tailscale login` as administrator, stopped after 10 minutes", "privileged: the prompt says what runs");
            const noTimeout = rules.privileged(["tailscale", "login"], ts, { timeout: "", seconds: 600 });
            assert(!noTimeout.ok && /timeout was not found/.test(noTimeout.error), "privileged: without timeout nothing is run as root: " + noTimeout.error);
            assertEqual(rules.privileged(["tailscale", "down"], ts).ok, false, "privileged: no options (no timeout): refused");
            for (const path of ["tailscale", "bin/tailscale", "", null, "/usr/../tmp/tailscale", "/usr/bin/tail scale", "/usr/bin/", "/a\nb"])
                assertEqual(rules.privileged(["tailscale", "down"], path, limited).ok, false, "privileged: path " + JSON.stringify(path) + " refused");
            for (const argv of [["sh", "-c", "x"], [], null, "tailscale down", ["tailscale", 5]])
                assertEqual(rules.privileged(argv, "/usr/bin/tailscale", limited).ok, false, "privileged: argv " + JSON.stringify(argv) + " refused");
            for (const seconds of [0, -1, 1.5, "60", 90000])
                assertEqual(rules.privileged(["tailscale", "down"], ts, { timeout: to, seconds: seconds }).ok, false, "privileged: limit " + JSON.stringify(seconds) + " refused");
            assertEqual(rules.privileged(["tailscale", "down"], ts, { timeout: "timeout", seconds: 60 }).ok, false, "privileged: a relative timeout refused");
        }

        // --- timed: every plain command under timeout ---
        {
            const ts = "/usr/bin/tailscale";
            same(rules.timed([ts, "status", "--json"], "/usr/bin/timeout", rules.timeLimits.read).argv,
                 ["/usr/bin/timeout", "-k", "5", "15", ts, "status", "--json"], "timed: a read, 15 s");
            same(rules.timed([ts, "up"], "/usr/bin/timeout", rules.timeLimits.up).argv, ["/usr/bin/timeout", "-k", "5", "60", ts, "up"], "timed: up, 60 s, bare");
            same(rules.timed([ts, "set", "--shields-up=true"], "/usr/bin/timeout", rules.timeLimits.change).argv,
                 ["/usr/bin/timeout", "-k", "5", "60", ts, "set", "--shields-up=true"], "timed: a set, 60 s");
            same(rules.timed([ts, "login"], "/usr/bin/timeout", rules.timeLimits.login).argv, ["/usr/bin/timeout", "-k", "5", "600", ts, "login"], "timed: login, 600 s");
            const bare = rules.timed([ts, "up"], "", 60);
            assert(bare.ok && !bare.limited && bare.argv.join(" ") === ts + " up", "timed: no timeout found: as it is, limited false");
            for (const argv of [["tailscale", "up"], [], null, ["/a b/tailscale"]])
                assertEqual(rules.timed(argv, "/usr/bin/timeout", 60).ok, false, "timed: " + JSON.stringify(argv) + " refused");
            same([rules.commandFor("connect", {}).timeLimit, rules.commandFor("login", {}).timeLimit, rules.commandFor("status", {}).timeLimit,
                  rules.commandFor("shieldsUp", { on: true }).timeLimit], ["up", "login", "read", "change"], "commands: their time limits");
            assertEqual(rules.errorKind(124, "").message, "Tailscale did not answer in time and was stopped: check its service and the network.", "error: 124's sentence");
            assertEqual(rules.errorKind(137, "").kind, "timeout", "error: 137 (KILLed after TERM) is a timeout too");
            assert(/did not connect within 60 s\. It keeps trying by itself; Disconnect stops it\./.test(rules.timeoutMessage("connect", 60)), "timeout: connect's sentence");
            assert(/within 10 minutes/.test(rules.timeoutMessage("login", 600)), "timeout: login's sentence");
            const exitNode = rules.commandFor("exitNode", { node: "100.64.0.4" });
            assert(exitNode.description.indexOf("100.64") < 0, "commands: the exit node's description has no address: " + exitNode.description);
            assertEqual(rules.withoutAddresses("invalid value \"100.64.0.4\" for --exit-node; fd7a:115c:a1e0::1 and 10.0.0.0/8 too, version 1.104.4 at 12:30"),
                        "invalid value \"<address>\" for --exit-node; <address> and <address> too, version 1.104.4 at 12:30", "withoutAddresses: IPv4, IPv6, prefixes gone; versions and times kept");
        }

        // --- which programs run: the probe and the trust check ---
        {
            const probe = lines => lines.join("\n");
            const store = "/nix/store/abc-tailscale-1.104.4/bin/tailscale";
            const good = probe([
                "tool\ttailscale\t/run/current-system/sw/bin/tailscale", "real\ttailscale\t" + store,
                "stat\ttailscale\t0\t555\t/run/current-system/sw/bin", "stat\ttailscale\t1000\t555\t" + store, "stat\ttailscale\t1000\t555\t/nix/store/abc-tailscale-1.104.4/bin",
                "tool\ttimeout\t/usr/bin/timeout", "real\ttimeout\t/usr/bin/timeout",
                "stat\ttimeout\t0\t755\t/usr/bin", "stat\ttimeout\t0\t755\t/usr/bin/timeout", "stat\ttimeout\t0\t755\t/usr/bin",
                "tool\tpkexec\t/run/wrappers/bin/pkexec", "real\tpkexec\t/run/wrappers/wrappers.x/pkexec",
                "stat\tpkexec\t0\t755\t/run/wrappers/bin", "stat\tpkexec\t0\t4511\t/run/wrappers/wrappers.x/pkexec", "stat\tpkexec\t0\t755\t/run/wrappers/wrappers.x",
                "tool\tcurl\t/home/u/bin/curl", "socket\t/run/tailscale/tailscaled.sock"]);
            const found = rules.toolsProbe(good, true);
            same(found.untrusted, [], "trust: root-owned and Nix store programs are trusted");
            assertEqual(found.tools.tailscale.path, "/run/current-system/sw/bin/tailscale", "trust: the path kept as found (the link)");
            assertEqual(found.tools.curl.trusted, true, "trust: curl is not judged (never run as root)");
            assertEqual(found.socket, "/run/tailscale/tailscaled.sock", "probe: the socket that exists (the fallback)");
            const writable = probe(["tool\ttailscale\t/home/u/.local/bin/tailscale", "real\ttailscale\t/home/u/.local/bin/tailscale",
                "stat\ttailscale\t1000\t755\t/home/u/.local/bin", "stat\ttailscale\t1000\t755\t/home/u/.local/bin/tailscale", "stat\ttailscale\t1000\t755\t/home/u/.local/bin"]);
            const bad = rules.toolsProbe(writable, true);
            same(bad.untrusted, ["tailscale"], "trust: a tailscale this user owns is refused");
            assert(/not trusted/.test(bad.tools.tailscale.reason) && bad.tools.tailscale.reason.indexOf("/home/") < 0, "trust: the reason says so, without the path: " + bad.tools.tailscale.reason);
            const linkInHome = probe(["tool\tpkexec\t/home/u/bin/pkexec", "real\tpkexec\t/run/wrappers/wrappers.x/pkexec",
                "stat\tpkexec\t1000\t755\t/home/u/bin", "stat\tpkexec\t0\t4511\t/run/wrappers/wrappers.x/pkexec", "stat\tpkexec\t0\t755\t/run/wrappers/wrappers.x"]);
            same(rules.toolsProbe(linkInHome, true).untrusted, ["pkexec"], "trust: a link to a good pkexec in a directory this user owns is refused (it could be swapped)");
            const groupWritable = probe(["tool\ttimeout\t/opt/bin/timeout", "real\ttimeout\t/opt/bin/timeout",
                "stat\ttimeout\t0\t775\t/opt/bin", "stat\ttimeout\t0\t755\t/opt/bin/timeout", "stat\ttimeout\t0\t775\t/opt/bin"]);
            same(rules.toolsProbe(groupWritable, true).untrusted, ["timeout"], "trust: a group-writable directory is refused");
            same(rules.toolsProbe(probe(["tool\ttailscale\t/usr/bin/tailscale"]), true).untrusted, ["tailscale"], "trust: not checkable (no stat): refused");
            same(rules.toolsProbe(writable, false).untrusted, [], "trust: the seam's programs are not judged");
            assertEqual(rules.toolsProbe(probe(["tool\ttailscale\t"]), true).tools.tailscale.path, "", "probe: not found");
            assertEqual(rules.toolsProbe(probe(["socket\t/tmp/evil.sock"]), true).socket, "", "probe: only the known socket paths");
            for (const hostile of [null, undefined, 5, "tool\t__proto__\t/x", "stat\ttailscale\t0"])
                assert(Array.isArray(rules.toolsProbe(hostile, true).untrusted), "probe: hostile input " + JSON.stringify(hostile) + " gives an answer");
        }

        // --- the CLI's other outputs ---
        {
            same(rules.parseLoginOutput(fixture("login-output.txt")), { authUrl: "https://login.tailscale.com/a/REDACTED", approvalUrl: "", success: true },
                 "login output: the URL, then success");
            same(rules.parseLoginOutput("\nTo authenticate, visit:\n\n\thttps://login.tailscale.com/a/REDACTED\n\n"),
                 { authUrl: "https://login.tailscale.com/a/REDACTED", approvalUrl: "", success: false }, "login output: the URL before success");
            assertEqual(rules.parseLoginOutput(fixture("machine-auth-output.txt")).approvalUrl, "https://login.tailscale.com/admin/machines", "login output: approval");
            assertEqual(rules.parseLoginOutput("To authenticate, visit:\n\tjavascript:alert(1)\n").authUrl, "", "login output: not an http(s) URL");
            same(rules.parseLoginOutput(null), { authUrl: "", approvalUrl: "", success: false }, "login output: nothing");
            assertEqual(rules.safeUrl("https://login.tailscale.com/a/x"), "https://login.tailscale.com/a/x", "safeUrl: https");
            for (const bad of ["file:///etc/passwd", "https://a b", "https://a\nb", "", null, "https://" + "a".repeat(2050), "https://a\"b"])
                assertEqual(rules.safeUrl(bad), "", "safeUrl: " + JSON.stringify(bad).slice(0, 40) + " refused");

            const direct = rules.parsePing(fixture("ping-direct.txt"));
            same(direct.replies.map(reply => reply.via + " " + reply.detail + " " + reply.ms),
                 ["derp fra 31", "derp fra 29", "direct 198.51.100.11:41641 4"], "ping: DERP, then direct");
            assertEqual(direct.replies[0].address, "100.64.0.11", "ping: the address");
            const relay = rules.parsePing(fixture("ping-peer-relay.txt"));
            assert(relay.replies.length === 2 && relay.replies[0].via === "peer-relay" && relay.directNotEstablished, "ping: through a peer relay, no direct path");
            const timeout = rules.parsePing(fixture("ping-timeout.txt"));
            assert(timeout.replies.length === 0 && timeout.timedOut && timeout.noReply, "ping: timed out, no reply");
            same(rules.parsePing(42).replies, [], "ping: nothing");

            const netcheck = rules.parseNetcheck(fixture("netcheck.json"));
            assert(netcheck.ok && netcheck.udp && netcheck.ipv4 && !netcheck.ipv6, "netcheck: the flags");
            assertEqual(netcheck.preferredDerp, 4, "netcheck: the preferred DERP region");
            same(netcheck.regions, [{ id: 4, ms: 21.5 }, { id: 1, ms: 98 }, { id: 9, ms: 145 }], "netcheck: regions, fastest first, in ms");
            assertEqual(netcheck.mappingVariesByDestIp, false, "netcheck: mapping");
            assertEqual(rules.parseNetcheck("nope").ok, false, "netcheck: not JSON");
            same(rules.parseNetcheck('{"RegionLatency":{"x":1,"2":-5,"3":"7"}}').regions, [], "netcheck: odd latencies skipped");
        }
    }
}
