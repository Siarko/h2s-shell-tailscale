import QtQuick
import qs.tests
import ".."

// TailscaleRules, the process side: the IPN bus (one message per line, and the pretty-printed
// form fed in arbitrary chunks), what an exit code and stderr mean (the real "Access denied"
// and not-running texts, the `up` trap), how a run as administrator ended (the shell's result),
// the one command builder (argv arrays only; never a flag on `up`; a `what` for every
// privileged one), the run as administrator, which programs run, and the CLI's other outputs
// (login, ping, netcheck).
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
            same(rules.errorKind(1, "\nTo authenticate, visit:\n\n\thttps://login.tailscale.com/a/REDACTED\n\nbackend error: example login failure\n"),
                 { kind: "other", message: "backend error: example login failure" }, "error: what a waiting login printed is not the reason");
            assertEqual(rules.errorKind(1, "To authenticate, visit:\n\thttps://login.tailscale.com/a/REDACTED\n").message, "Tailscale exited with status 1.",
                        "error: a login link alone is never the reason");
            assert(rules.errorKind(1, "failed: see https://login.tailscale.com/a/REDACTED now").message.indexOf("/a/") < 0, "error: a login link inside a line is cut out");
            assertEqual(rules.errorKind(0, fixture("stderr-access-denied-set.txt")).kind, "", "error: exit 0 is no error");
            assertEqual(rules.errorKind(124, "").kind, "timeout", "error: timeout(1)'s 124");
            same(rules.errorKind(1, null), { kind: "other", message: "Tailscale exited with status 1." }, "error: no stderr");
            same(rules.errorKind("x", 42), { kind: "other", message: "42" }, "error: odd types");
            assert(rules.errorKind(1, fixture("stderr-access-denied-set.txt")).message.length > 10, "error: a sentence for the notification");
            assertEqual(rules.errorKind(1, "\n\n   \n").message, "Tailscale exited with status 1.", "error: blank stderr");
        }

        // --- privilegedOutcome: module.privileged's result (module API 1.11) ---
        {
            const result = extra => Object.assign({ ok: false, code: -1, stdout: "", stderr: "", dismissed: false, refused: false, notFound: false,
                                                    timedOut: false, cancelled: false, blocked: "", error: "" }, extra);
            same(rules.privilegedOutcome(result({ ok: true, code: 0 }), "connect", 60), { kind: "ok", notify: false, message: "" }, "privileged: ok");
            same(rules.privilegedOutcome(result({ cancelled: true }), "connect", 60), { kind: "cancelled", notify: false, message: "" },
                 "privileged: cancelled by the module: nothing to say");
            same(rules.privilegedOutcome(result({ dismissed: true, code: 126 }), "connect", 60), { kind: "dismissed", notify: false, message: "" },
                 "privileged: dismissed: show nothing, not a failure");
            same(rules.privilegedOutcome(result({ dismissed: true, blocked: "locked" }), "connect", 60), { kind: "dismissed", notify: false, message: "" },
                 "privileged: refused for the lock: dismissed, silent (the user clicks again once unlocked)");
            same(rules.privilegedOutcome(result({ refused: true, code: 127 }), "connect", 60), { kind: "failed", notify: false, message: "Not allowed." },
                 "privileged: refused (not authorised, no agent): a failure the shell tells itself — not notified again");
            same(rules.privilegedOutcome(result({ timedOut: true, code: 124 }), "connect", 60),
                 { kind: "failed", notify: true, message: "Still connecting after 60 s. Disconnect to stop." }, "privileged: timed out: the limit's sentence");
            same(rules.privilegedOutcome(result({ timedOut: true }), "shieldsUp", 60).message, rules.timeoutMessage("shieldsUp", 60), "privileged: … per command");
            same(rules.privilegedOutcome(result({ notFound: true }), "connect", 60),
                 { kind: "failed", notify: true, message: "It could not be run as administrator: tailscale was not found." }, "privileged: not found");
            same(rules.privilegedOutcome(result({ blocked: "unprintable" }), "connect", 60),
                 { kind: "failed", notify: true, message: "It was not run as administrator: the command holds characters that can't be shown." },
                 "privileged: blocked by the shell, in plain words — never its code word");
            assertEqual(rules.privilegedOutcome(result({ blocked: "no-purpose" }), "connect", 60).message,
                        "It was not run as administrator: it doesn't say what it is for.", "privileged: blocked, no purpose: plain words");
            assertEqual(rules.privilegedOutcome(result({ blocked: "locked" }), "connect", 60).message,
                        "It was not run as administrator: the screen is locked.", "privileged: blocked, locked (without dismissed): plain words");
            assertEqual(rules.privilegedOutcome(result({ blocked: "something-new" }), "connect", 60).message,
                        "It was not run as administrator.", "privileged: a refusal it does not know: no code word shown");
            assertEqual(rules.privilegedOutcome(result({ blocked: "constructor" }), "connect", 60).message,
                        "It was not run as administrator.", "privileged: a refusal named like an object's own property: no code word either");
            same(rules.privilegedOutcome(result({ error: "not available: no pkexec found" }), "connect", 60),
                 { kind: "failed", notify: true, message: "It could not be run as administrator: not available: no pkexec found" }, "privileged: the shell's error");
            same(rules.privilegedOutcome(result({ code: 1, stderr: fixture("stderr-access-denied-set.txt") }), "shieldsUp", 60),
                 { kind: "failed", notify: true, message: rules.errorKind(1, fixture("stderr-access-denied-set.txt")).message }, "privileged: the command's own failure: its stderr");
            for (const hostile of [null, undefined, 5, "ok", [], { ok: "true" }])
                assertEqual(rules.privilegedOutcome(hostile, "connect", 60).kind, "failed", "privileged: " + JSON.stringify(hostile) + " is a failure, never ok");
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
                ["operator", { user: "" }, ["tailscale", "set", "--operator="]],
                ["switchAccount", { id: "c3d4" }, ["tailscale", "switch", "c3d4"]],
                ["switchList", {}, ["tailscale", "switch", "--list", "--json"]],
                ["removeAccount", { id: "c3d4" }, ["tailscale", "switch", "remove", "c3d4"]],
                ["ping", { target: "laptop", count: 3 }, ["tailscale", "ping", "--c=3", "--timeout=3s", "laptop"]],
                ["ping", { target: "100.64.0.11" }, ["tailscale", "ping", "--c=1", "--timeout=3s", "100.64.0.11"]],
                ["netcheck", {}, ["tailscale", "netcheck", "--format=json"]],
                ["fileCp", { files: ["/home/u/a.txt", "/home/u/with space.pdf"], target: "laptop" }, ["tailscale", "file", "cp", "--", "/home/u/a.txt", "/home/u/with space.pdf", "laptop:"]],
                ["fileTargets", {}, ["tailscale", "file", "cp", "--targets"]],
                ["fileGet", { directory: "/home/u/Downloads" }, ["tailscale", "file", "get", "--conflict=rename", "/home/u/Downloads"]],
                ["serveStatus", {}, ["tailscale", "serve", "status", "--json"]],
                ["serveReset", {}, ["tailscale", "serve", "reset"]],
                ["funnelStatus", {}, ["tailscale", "funnel", "status", "--json"]],
                ["funnelReset", {}, ["tailscale", "funnel", "reset"]],
                ["lockStatus", {}, ["tailscale", "lock", "status"]],
                ["status", {}, ["tailscale", "status", "--json"]],
                ["prefs", {}, ["tailscale", "debug", "prefs"]],
                ["exitNodeSuggest", {}, ["tailscale", "exit-node", "suggest"]],
                ["exitNodeList", {}, ["tailscale", "exit-node", "list"]],
                ["dnsStatus", {}, ["tailscale", "dns", "status", "--json"]],
                ["version", {}, ["tailscale", "version", "--json"]],
                ["derpMap", {}, ["tailscale", "debug", "derp-map"]],
                ["nickname", { name: "home" }, ["tailscale", "set", "--nickname=home"]],
                ["autoUpdate", { on: false }, ["tailscale", "set", "--auto-update=false"]],
                ["snat", { on: true }, ["tailscale", "set", "--snat-subnet-routes=true"]],
                ["statefulFiltering", { on: false }, ["tailscale", "set", "--stateful-filtering=false"]],
                ["connector", { on: true }, ["tailscale", "set", "--advertise-connector=true"]],
                ["posture", { on: false }, ["tailscale", "set", "--report-posture=false"]],
                ["relayServerPort", { port: "40000" }, ["tailscale", "set", "--relay-server-port=40000"]],
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
            assert(rules.commandFor("fileGet", { directory: "/tmp/in" }).writesAsRoot, "command: file get would write as root through pkexec");
            // The old serve/funnel and cert builders are gone: ServeRules and CertRules build those
            assert(["serveAdd", "funnelAdd", "serveRemove", "funnelRemove", "cert"].every(name => !rules.commandFor(name, { protocol: "https", port: 443, target: 3000 }).ok),
                   "command: no legacy serve or cert builder");
            assert(rules.commandFor("login", {}).longRunning, "command: login waits for the browser");

            // Refusals: never a half-checked argv
            const refusals = [
                ["operator", { user: "root; rm -rf /" }], ["operator", { user: "Alice" }], ["operator", { user: "$USER" }],
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

        // --- privilegedRun: what module.privileged.start is given ---
        {
            const ts = "/run/current-system/sw/bin/tailscale";
            const trusted = { path: ts, trusted: true, reason: "root's, and only root can change it" };
            const facts = extra => Object.assign({ program: trusted, available: true, unavailableReason: "", seconds: 60 }, extra ?? {});
            same(rules.privilegedRun(rules.commandFor("shieldsUp", { on: true }), facts()),
                 { ok: true, error: "", argv: [ts, "set", "--shields-up=true"], what: "Block incoming connections", timeoutMs: 60000, environment: null },
                 "privilegedRun: tailscale by its trusted path, the command's words, its limit in ms (the shell's timeout inside pkexec), no environment");
            // The environment: only what a suite gave its client (module API 1.14, test mode
            // only); the client's empty one outside a suite gives none, so the shell never
            // sees the option there
            for (const given of [{}, undefined, null, "TS=1", ["A"], { "BAD NAME": "x" }, { A: 5 }])
                assertEqual(rules.privilegedRun(rules.commandFor("connect", {}), facts({ environment: given })).environment, null,
                            "privilegedRun: environment " + JSON.stringify(given) + " → none");
            const scenarioEnvironment = { TS_FAKE_STATE_DIR: "/tmp/x", TS_FAKE_GONE: null };
            const withEnvironment = rules.privilegedRun(rules.commandFor("connect", {}), facts({ environment: scenarioEnvironment }));
            same(withEnvironment.environment, scenarioEnvironment, "privilegedRun: a suite's variables, a removal (null) among them, handed on");
            assert(withEnvironment.environment !== scenarioEnvironment, "… as a copy");
            assertEqual(rules.privilegedRun(rules.commandFor("connect", {}), facts({ available: false, environment: scenarioEnvironment })).environment, null,
                        "privilegedRun: refused: no environment either");
            same(rules.privilegedRun(rules.commandFor("connect", {}), facts()).argv, [ts, "up"], "privilegedRun: connect stays bare (the limit is the shell's, never a flag)");
            same(rules.privilegedRun(rules.commandFor("login", {}), facts({ seconds: 600 })).timeoutMs, 600000, "privilegedRun: the login's 10 minutes");
            const untrusted = rules.privilegedRun(rules.commandFor("connect", {}), facts({ program: { path: "/home/u/bin/tailscale", trusted: false, reason: "others than root can change /home/u/bin/tailscale" } }));
            assert(!untrusted.ok && untrusted.argv.length === 0 && /isn't trusted/.test(untrusted.error),
                   "privilegedRun: an untrusted tailscale is refused by the module (the shell does not judge it): " + untrusted.error);
            assertEqual(rules.privilegedRun(rules.commandFor("connect", {}), facts({ program: { path: ts } })).ok, false, "privilegedRun: no verdict: refused");
            assertEqual(rules.privilegedRun(rules.commandFor("connect", {}), facts({ program: { path: ts, trusted: "true" } })).ok, false, "privilegedRun: trusted must be true itself");
            assertEqual(rules.privilegedRun(rules.commandFor("connect", {}), facts({ program: null })).ok, false, "privilegedRun: no tailscale: refused");
            const unavailable = rules.privilegedRun(rules.commandFor("connect", {}), facts({ available: false, unavailableReason: "no pkexec found" }));
            assertEqual(unavailable.error, "Changes that need an administrator are not offered: no pkexec found.", "privilegedRun: the shell cannot: its reason");
            for (const path of ["tailscale", "bin/tailscale", "", null, "/usr/../tmp/tailscale", "/usr/bin/tail scale", "/usr/bin/", "/a\nb"])
                assertEqual(rules.privilegedRun(rules.commandFor("connect", {}), facts({ program: { path: path, trusted: true } })).ok, false,
                            "privilegedRun: path " + JSON.stringify(path) + " refused");
            for (const command of [{ argv: ["sh", "-c", "x"], what: "Run" }, { argv: [], what: "x" }, null, { argv: "tailscale down", what: "x" },
                                   { argv: ["tailscale", 5], what: "x" }, { argv: ["tailscale", "down"] }, { argv: ["tailscale", "down"], what: "  " }])
                assertEqual(rules.privilegedRun(command, facts()).ok, false, "privilegedRun: " + JSON.stringify(command) + " refused");
            for (const seconds of [0, -1, 1.5, "60", 3601, 21600])
                assertEqual(rules.privilegedRun(rules.commandFor("connect", {}), facts({ seconds: seconds })).ok, false, "privilegedRun: limit " + JSON.stringify(seconds) + " refused");
            assertEqual(rules.elevationProblem("present", true, ""), "", "elevation: available");
            assertEqual(rules.elevationProblem("missing", false, "x"), "", "elevation: said only while Tailscale is there");
            assertEqual(rules.elevationProblem("present", false, "no trusted timeout (coreutils) on PATH: a run as administrator needs it to end at its limit."),
                        "Changes that need an administrator are not offered: no trusted timeout (coreutils) on PATH: a run as administrator needs it to end at its limit.",
                        "elevation: the shell's reason, one sentence");
        }

        // --- what: every privileged command says what it does, in a few words ---
        {
            const asked = [["connect", {}, "Connect"], ["disconnect", {}, "Disconnect"], ["login", {}, "Log in"], ["addAccount", {}, "Add an account"],
                ["logout", {}, "Log out"], ["exitNode", { node: "100.64.0.4" }, "Change the exit node"], ["exitNodeNone", {}, "Change the exit node"],
                ["exitNodeAuto", {}, "Change the exit node"], ["allowLan", { on: true }, "Allow the local network"], ["allowLan", { on: false }, "Block the local network"],
                ["acceptRoutes", { on: true }, "Accept routes"], ["acceptRoutes", { on: false }, "Ignore routes"],
                ["acceptDns", { on: true }, "Use Tailscale DNS"], ["acceptDns", { on: false }, "Ignore Tailscale DNS"],
                ["shieldsUp", { on: true }, "Block incoming connections"], ["shieldsUp", { on: false }, "Allow incoming connections"],
                ["ssh", { on: true }, "Start the SSH server"], ["ssh", { on: false }, "Stop the SSH server"],
                ["webClient", { on: true }, "Start the web interface"], ["webClient", { on: false }, "Stop the web interface"],
                ["advertiseExitNode", { on: true }, "Offer an exit node"], ["advertiseExitNode", { on: false }, "Stop offering an exit node"],
                ["autoUpdate", { on: true }, "Turn on automatic updates"], ["autoUpdate", { on: false }, "Turn off automatic updates"],
                ["snat", { on: true }, "Turn on source NAT"], ["snat", { on: false }, "Turn off source NAT"],
                ["statefulFiltering", { on: true }, "Turn on stateful filtering"], ["statefulFiltering", { on: false }, "Turn off stateful filtering"],
                ["connector", { on: true }, "Offer an app connector"], ["connector", { on: false }, "Stop the app connector"],
                ["posture", { on: true }, "Report device posture"], ["posture", { on: false }, "Stop posture reports"],
                ["relayServerPort", { port: "40000" }, "Run a peer relay"], ["relayServerPort", { port: 40000 }, "Run a peer relay"], ["relayServerPort", { port: "" }, "Turn off the peer relay"],
                ["updateCheck", { on: true }, "Check for updates"], ["updateCheck", { on: false }, "Stop update checks"],
                ["hostname", { name: "box" }, "Rename this device"], ["advertiseRoutes", { routes: ["192.168.7.0/24"] }, "Change offered routes"],
                ["nickname", { name: "home" }, "Name the account"], ["operator", { user: "tester" }, "Become the operator"], ["operator", { user: "" }, "Give up the operator role"],
                ["switchAccount", { id: "c3d4" }, "Switch account"], ["switchList", {}, "List accounts"], ["removeAccount", { id: "a1b2" }, "Remove an account"],
                ["fileCp", { files: ["/tmp/a"], target: "100.64.0.4" }, "Send a file"], ["fileCp", { files: ["/tmp/a", "/tmp/b"], target: "100.64.0.4" }, "Send files"],
                ["fileGet", { directory: "/tmp/in" }, "Receive files"], ["serveReset", {}, "Stop every share"], ["funnelReset", {}, "Stop Funnel"]];
            same(asked.filter(row => rules.commandFor(row[0], row[1]).what !== row[2]).map(row => row[0] + " → " + rules.commandFor(row[0], row[1]).what), [],
                 "what: each privileged command's words for the prompt");
            const missing = rules.commandNames.filter(name => {
                const row = asked.find(item => item[0] === name);
                const command = rules.commandFor(name, row ? row[1] : {});
                return command.ok && command.privileged && !(command.what.length > 0 && command.what.length <= 40);
            });
            same(missing, [], "what: no privileged command without words, none longer than 40 characters (the prompt cuts there)");
            assertEqual(rules.commandFor("status", {}).what, undefined, "what: only privileged commands have one");
            assert(rules.commandFor("hostname", { name: "box" }).what.indexOf("box") < 0 && rules.commandFor("operator", { user: "tester" }).what.indexOf("tester") < 0,
                   "what: never a name the user typed");
        }

        // --- running a command: the shell's runner (argv, time limit, result) ---
        {
            const ts = "/usr/bin/tailscale";
            same(rules.commandLine(rules.commandFor("status", {}).argv, ts), [ts, "status", "--json"], "commandLine: tailscale by its absolute path");
            same(rules.commandLine(rules.commandFor("connect", {}).argv, ts), [ts, "up"], "commandLine: up, bare");
            same(rules.commandLine(rules.commandFor("startService", {}).argv, "/usr/bin/systemctl").slice(0, 1), ["/usr/bin/systemctl"], "commandLine: systemctl by its path");
            for (const path of ["", "tailscale", "/a b/tailscale", "/x/../tailscale", null])
                same(rules.commandLine(["tailscale", "up"], path), [], "commandLine: path " + JSON.stringify(path) + " refused");
            for (const argv of [[], null, [1, 2], "tailscale up"])
                same(rules.commandLine(argv, ts), [], "commandLine: argv " + JSON.stringify(argv) + " refused");
            same(rules.runLimits(rules.timeLimits.read * 1000), { ok: true, timeoutMs: 15000, killAfterMs: 5000 }, "runLimits: a read, 15 s, KILL 5 s after TERM");
            same(rules.runLimits(rules.timeLimits.login * 1000), { ok: true, timeoutMs: 600000, killAfterMs: 5000 }, "runLimits: the login, 10 minutes");
            same(rules.runLimits(0), { ok: true, timeoutMs: 0, killAfterMs: 5000 }, "runLimits: 0, no limit (the stream)");
            assertEqual(rules.runLimits(10 * 86400000).timeoutMs, rules.maxRunMs, "runLimits: at most a day");
            for (const value of [-1, NaN, Infinity, "15000", null, undefined])
                assertEqual(rules.runLimits(value).ok, false, "runLimits: " + String(value) + " not ok");
            same(rules.streamArgv("/usr/bin/curl", "/run/tailscale/tailscaled.sock"),
                 ["/usr/bin/curl", "-sN", "--unix-socket", "/run/tailscale/tailscaled.sock", "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus?mask=" + rules.watchMask],
                 "streamArgv: curl on watch-ipn-bus, by absolute paths");
            same(rules.streamArgv("", "/run/tailscale/tailscaled.sock"), [], "streamArgv: no curl, no stream");
            same(rules.streamArgv("/usr/bin/curl", "tailscaled.sock"), [], "streamArgv: a socket not by absolute path: none");
            // The runner's result → the module's reading of it
            const result = changes => Object.assign({ ok: false, code: 1, stdout: "", stderr: "", timedOut: false, cancelled: false, failedToStart: false, error: "" }, changes);
            same(rules.runError(result({ ok: true, code: 0 })), { kind: "", message: "" }, "runError: ok");
            same(rules.runError(result({ ok: true, code: 0, truncated: true })), { kind: "too-long", message: "The answer was too long." },
                 "runError: output cut by the runner: a failure, though it exited 0");
            assert(rules.maxAnswerChars >= 32 * 1024 * 1024, "the runner's cut: room for a large tailnet's status --json");
            same(rules.runError(result({ timedOut: true, code: -1 })), { kind: "timeout", message: rules.errorKind(124, "").message }, "runError: timed out, whatever the code");
            same(rules.runError(result({ code: -1, error: "argv is empty" })), { kind: "not-run", message: "It could not be run: argv is empty" }, "runError: refused by the runner, why");
            same(rules.runError(result({ code: 127, failedToStart: true, stderr: "timeout: failed to run command" })), { kind: "not-run", message: "The program could not be started." },
                 "runError: the program could not be started");
            assertEqual(rules.runError(result({ stderr: "Access denied: prefs write access denied" })).kind, "denied", "runError: otherwise errorKind's of stderr");
            assertEqual(rules.runError(result({ code: 3, stderr: "" })).message, "Tailscale exited with status 3.", "runError: … and of the exit status");
            assertEqual(rules.runError(null).kind, "other", "runError: no result: a failure");
            same([rules.commandFor("connect", {}).timeLimit, rules.commandFor("login", {}).timeLimit, rules.commandFor("status", {}).timeLimit,
                  rules.commandFor("shieldsUp", { on: true }).timeLimit], ["up", "login", "read", "change"], "commands: their time limits");
            assertEqual(rules.errorKind(124, "").message, "Tailscale did not answer in time and was stopped: check its service and the network.", "error: 124's sentence");
            assertEqual(rules.errorKind(137, "").kind, "timeout", "error: 137 (KILLed after TERM) is a timeout too");
            assertEqual(rules.timeoutMessage("connect", 60), "Still connecting after 60 s. Disconnect to stop.", "timeout: connect's sentence");
            assert(/within 10 minutes/.test(rules.timeoutMessage("login", 600)), "timeout: login's sentence");
            const exitNode = rules.commandFor("exitNode", { node: "100.64.0.4" });
            assert(exitNode.description.indexOf("100.64") < 0, "commands: the exit node's description has no address: " + exitNode.description);
        }

        // --- which programs run: module.programs (the shell's lookup and verdict) ---
        {
            const verdict = (path, trusted, reason) => ({ path: path, trusted: trusted, reason: reason ?? "" });
            const all = { tailscale: verdict("/run/current-system/sw/bin/tailscale", true), timeout: verdict("/usr/bin/timeout", true),
                          curl: verdict("/home/u/bin/curl", false, "others than root can change /home/u/bin/curl"), systemctl: verdict("/usr/bin/systemctl", true),
                          openssl: verdict("", false, "not found"), pkexec: verdict("/run/wrappers/bin/pkexec", true) };
            same(rules.programsFound(all), { known: true, cli: "present", untrustedReason: "", tailscale: "/run/current-system/sw/bin/tailscale",
                                             timeout: "/usr/bin/timeout", curl: "/home/u/bin/curl", systemctl: "/usr/bin/systemctl", openssl: "" },
                 "programs: each by the path the shell found; curl not judged (it runs as this user only); openssl not found");
            same(rules.programsFound(null), { known: false, cli: "unknown", untrustedReason: "", tailscale: "", timeout: "", curl: "", systemctl: "", openssl: "" },
                 "programs: not looked up yet: unknown");
            assertEqual(rules.programsFound({}).cli, "missing", "programs: looked up, no tailscale: missing");
            assertEqual(rules.programsFound({ tailscale: verdict("", false, "not found") }).cli, "missing", "programs: tailscale not found: missing");
            const untrusted = rules.programsFound(Object.assign({}, all, { tailscale: verdict("/home/u/bin/tailscale", false, "others than root can change /home/u/bin/tailscale") }));
            same([untrusted.cli, untrusted.tailscale], ["untrusted", ""], "programs: a tailscale this user could change: untrusted, its path not taken");
            assertEqual(untrusted.untrustedReason, "Tailscale isn't trusted (others than root can change /home/u/bin/tailscale): nothing runs.", "… the shell's reason, said");
            assertEqual(untrusted.timeout, "/usr/bin/timeout", "… the others still found");
            assertEqual(rules.programsFound({ tailscale: { path: "/usr/bin/tailscale" } }).cli, "untrusted", "programs: no verdict: untrusted, never trusted");
            assertEqual(rules.programsFound({ tailscale: verdict("/x/tailscale", false, "") }).untrustedReason, "Tailscale isn't trusted (it could not be checked): nothing runs.",
                        "programs: no reason given");
            assert(rules.programsFound({ tailscale: verdict("/x/tailscale", false, "<b>x</b>\nline") }).untrustedReason.indexOf("<") < 0, "programs: the reason as plain text, one line");
            for (const path of ["tailscale", "/usr/../tmp/tailscale", "/a b/tailscale", "/usr/bin/", 5])
                assertEqual(rules.programsFound({ tailscale: verdict(path, true) }).cli, "missing", "programs: path " + JSON.stringify(path) + " is no program");
            for (const hostile of [5, "x", [], { tailscale: null }, { tailscale: "x" }])
                assert(["unknown", "missing"].includes(rules.programsFound(hostile).cli), "programs: hostile " + JSON.stringify(hostile) + " runs nothing");
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
