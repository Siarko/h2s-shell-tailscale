import QtQuick
import qs.tests
import ".."

// TailscaleRules, the reading side: status and prefs (fixtures from a real machine, redacted,
// and hostile input), who may change Tailscale, the state and attention of the one VPN entry,
// the entry as the shell's provider contract wants it, and the plans for connect, disconnect
// and attend (origin "user" or "network").
TestCase {
    id: suite
    suiteName: "tailscale: state, entry, plans"

    readonly property var rules: TailscaleRules
    // 2026-11-15 12:00 UTC: the fixtures' "now" (key-expiring is 2026-11-18, key-expired
    // 2026-11-01)
    readonly property real now: Date.UTC(2026, 10, 15, 12, 0, 0)

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

    function status(name) {
        return rules.parseStatus(fixture("status-" + name + ".json"));
    }

    function prefs(name) {
        return rules.parsePrefs(fixture("prefs-" + name + ".json"));
    }

    // The shell's check of a provider entry (NetworkRules.vpnProviderEntries), restated: what
    // it would drop or reset
    function contractProblems(entry) {
        const problems = [];
        if (entry === null || typeof entry !== "object" || Array.isArray(entry))
            return ["not an object"];
        if (typeof entry.id !== "string" || !/^[A-Za-z0-9._~-]{1,64}$/.test(entry.id))
            problems.push("id");
        if (typeof entry.name !== "string" || entry.name.trim() === "")
            problems.push("name");
        if (!["activating", "activated", "deactivating", ""].includes(entry.state))
            problems.push("state " + entry.state);
        if (entry.attention !== null && (typeof entry.attention !== "object" || typeof entry.attention.reason !== "string"
                || entry.attention.reason.trim() === "" || typeof entry.attention.action !== "string"
                || entry.attention.reason.length > 300 || entry.attention.action.length > 40))
            problems.push("attention");
        if (entry.detail === null || typeof entry.detail !== "object" || Array.isArray(entry.detail))
            problems.push("detail");
        if (typeof entry.active !== "boolean" || entry.active !== (entry.state !== ""))
            problems.push("active");
        if (typeof entry.status !== "string")
            problems.push("status");
        if (typeof entry.busy !== "boolean")
            problems.push("busy");
        // What it does with the traffic (module API 1.16): true, false or null (unknown); routes a list or null
        for (const name of ["fullTunnel", "setsDns"])
            if (![true, false, null].includes(entry[name]))
                problems.push(name);
        if (entry.routes !== null && !(Array.isArray(entry.routes) && entry.routes.length <= 256 && entry.routes.every(route => typeof route === "string")))
            problems.push("routes");
        return problems;
    }

    function run() {
        // --- timeMs ---
        {
            assertEqual(rules.timeMs("0001-01-01T00:00:00Z"), 0, "time: Go's zero time is 0");
            assertEqual(rules.timeMs("2026-11-15T12:00:00Z"), now, "time: plain UTC");
            assertEqual(rules.timeMs("2026-11-15T12:00:00.123456789Z"), now + 123, "time: nine fractional digits");
            assertEqual(rules.timeMs("2026-11-15T13:30:00+01:30"), now, "time: an offset");
            assertEqual(rules.timeMs("2026-11-15T10:00:00-02:00"), now, "time: a negative offset");
            for (const bad of ["", "yesterday", null, undefined, 5, {}, "2026-11-15", "2026-11-15 12:00:00Z", "x".repeat(100)])
                assertEqual(rules.timeMs(bad), 0, "time: unreadable " + JSON.stringify(bad) + " is 0");
        }

        // --- parseStatus on the real (redacted) fixtures ---
        {
            const running = status("running");
            assert(running.ok, "status: running parses");
            assertEqual(running.backendState, "Running", "status: BackendState");
            assertEqual(running.peers.length, 9, "status: 9 peers");
            assertEqual(running.self.dnsName, "self.example-tailnet.ts.net", "status: the DNS name loses its trailing dot");
            assertEqual(running.tailnet.name, "user@example.com", "status: the tailnet's name");
            assertEqual(running.magicDnsSuffix, "example-tailnet.ts.net", "status: MagicDNS suffix");
            same(running.addresses, ["100.64.0.1", "fd7a:115c:a1e0::1"], "status: own addresses");
            assertEqual(running.users["10001"].loginName, "user1@example.com", "status: users by id");
            assertEqual(running.exitNodeStatus, null, "status: no exit node status");
            assertEqual(running.clientVersion, null, "status: no client version");
            const peer10 = running.peers.find(peer => peer.hostName === "peer10");
            same(peer10.primaryRoutes, ["192.168.99.0/24"], "status: a peer's primary routes");
            assertEqual(peer10.rxBytes, 4560796, "status: a peer's traffic");
            assert(peer10.active && peer10.online && peer10.exitNodeOption, "status: a peer's flags");
            assertEqual(running.peers.find(peer => peer.hostName === "peer2").expired, true, "status: an expired peer");
            assertEqual(running.peers.find(peer => peer.hostName === "peer4").lastSeen, 0, "status: zero time is 0");

            const exitNode = status("exit-node");
            same(exitNode.exitNodeStatus, { id: "nPEER4CNTRL", online: true, addresses: ["100.64.0.4", "fd7a:115c:a1e0::4"] },
                 "status: ExitNodeStatus, addresses without their prefix");
            assertEqual(status("exit-node-offline").exitNodeStatus.online, false, "status: the exit node offline");
            const login = status("needs-login");
            assertEqual(login.backendState, "NeedsLogin", "status: NeedsLogin");
            assertEqual(login.authUrl, "https://login.tailscale.com/a/REDACTED", "status: the AuthURL");
            assertEqual(login.tailnet, null, "status: no tailnet while logged out");
            assertEqual(login.peers.length, 0, "status: no peers while logged out");
            assertEqual(status("health-warnings").health.length, 2, "status: health texts");
            const update = status("update-available").clientVersion;
            assert(update && update.runningLatest === false && update.latestVersion === "1.106.0", "status: an update available");
            assertEqual(status("rich").peers.length, 15, "status: the rich fixture's peers");
            assertEqual(status("rich").peers.find(peer => peer.hostName === "se-sto-wg-021").location.city, "Stockholm", "status: a location");
        }

        // --- parseStatus on hostile input: never throws, never invents ---
        {
            for (const bad of [null, undefined, 42, "", "   ", "garbage", "[]", "null", "\"text\"", "{", true, []]) {
                const parsed = rules.parseStatus(bad);
                assert(parsed.ok === false && parsed.peers.length === 0 && parsed.backendState === "", "status: " + JSON.stringify(bad) + " is not a status");
            }
            const odd = rules.parseStatus(JSON.stringify({
                BackendState: 5, Self: "me", Health: "bad", TailscaleIPs: [1, null, "100.64.0.1"], CurrentTailnet: [],
                Peer: { "__proto__": { HostName: "proto", Online: true }, "constructor": { HostName: "ctor" }, "bad": null, "n": 7 },
                User: { "__proto__": { LoginName: "evil" }, "toString": "x" }, ClientVersion: "1.0", ExitNodeStatus: 3
            }));
            assert(odd.ok, "status: odd fields still parse");
            assertEqual(odd.backendState, "", "status: a number for BackendState is unknown");
            assertEqual(odd.self, null, "status: Self that is not an object is null");
            same(odd.health, [], "status: Health that is not a list is empty");
            same(odd.addresses, ["100.64.0.1"], "status: only text addresses");
            assertEqual(odd.tailnet, null, "status: CurrentTailnet that is a list is null");
            assertEqual(odd.peers.length, 2, "status: prototype-named peer keys are just keys; non-objects skipped");
            assert(odd.peers.some(peer => peer.hostName === "proto"), "status: the __proto__ peer is read as data");
            assertEqual(({}).HostName, undefined, "status: nothing was polluted");
            assertEqual(odd.users["__proto__"].loginName, "evil", "status: a __proto__ user is data");
            assertEqual(odd.clientVersion, null, "status: ClientVersion that is text is null");
            assertEqual(odd.exitNodeStatus, null, "status: ExitNodeStatus that is a number is null");

            const wrongTypes = rules.parseStatus({ Peer: [{ HostName: 1, Online: "yes", RxBytes: -5, TailscaleIPs: "100.64.0.9", Location: "here", Tags: [1, "tag:x"] }] });
            const node = wrongTypes.peers[0];
            assert(node.hostName === "" && node.online === false && node.rxBytes === 0, "status: wrong types fall back");
            same(node.addresses, [], "status: addresses that are not a list are empty");
            assertEqual(node.location, null, "status: a location that is text is null");
            same(node.tags, ["tag:x"], "status: only text tags");

            // A getter that throws, as from a hostile object passed in parsed
            const trap = {};
            Object.defineProperty(trap, "BackendState", { enumerable: true, get: () => { throw new Error("boom"); } });
            assertEqual(rules.parseStatus(trap).backendState, "", "status: a throwing getter counts as missing");

            const many = { BackendState: "Running", Peer: {} };
            for (let i = 0; i < rules.maxPeers + 5; i++)
                many.Peer["k" + i] = { ID: "n" + i, HostName: "h" + i };
            const big = rules.parseStatus(many);
            assert(big.peers.length === rules.maxPeers && big.peersCut, "status: peers beyond maxPeers are cut and said so");
            assertEqual(rules.parseStatus("x".repeat(rules.maxTextBytes + 1)).error, "too large", "status: oversized text is refused");
        }

        // --- parsePrefs ---
        {
            const running = prefs("running");
            assert(running.ok, "prefs: parse");
            assert(running.acceptRoutes && running.acceptDns && running.wantRunning && !running.loggedOut, "prefs: the running flags");
            assertEqual(running.controlUrl, "https://controlplane.tailscale.com", "prefs: control URL");
            assertEqual(running.loginName, "user1@example.com", "prefs: the account");
            assertEqual(running.operatorUser, "", "prefs: no operator (omitted while empty)");
            assertEqual(running.autoUpdate, null, "prefs: auto-update unset");
            assert(running.updateCheck, "prefs: update check");
            assertEqual(prefs("stopped").wantRunning, false, "prefs: stopped");
            assertEqual(prefs("logged-out").loggedOut, true, "prefs: logged out");
            assertEqual(prefs("logged-out").loginName, "", "prefs: no account while logged out");
            assertEqual(prefs("exit-node").exitNodeId, "nPEER4CNTRL", "prefs: the exit node");
            const rich = prefs("rich");
            assertEqual(rich.operatorUser, "alice", "prefs: the operator");
            assert(rich.advertiseExitNode, "prefs: the exit node pair means advertising an exit node");
            same(rich.advertiseRoutes, ["192.168.50.0/24"], "prefs: advertised routes without the pair");
            const odd = rules.parsePrefs({ RouteAll: "yes", AutoUpdate: null, Config: "x", AdvertiseRoutes: "10.0.0.0/8", WantRunning: 1 });
            assert(odd.ok && !odd.acceptRoutes && odd.acceptDns && !odd.wantRunning, "prefs: wrong types take Tailscale's defaults");
            same(odd.advertiseRoutes, [], "prefs: routes that are not a list");
            assertEqual(odd.loginName, "", "prefs: Config that is text");
            for (const bad of [null, "", "nope", "[1]", 3])
                assertEqual(rules.parsePrefs(bad).ok, false, "prefs: " + JSON.stringify(bad) + " is not prefs");
        }

        // --- canChange ---
        {
            assert(rules.canChange(null, { uid: 0 }), "canChange: root");
            assert(rules.canChange(prefs("rich"), { userName: "alice", uid: 1000 }), "canChange: the operator");
            assert(!rules.canChange(prefs("rich"), { userName: "bob", uid: 1000 }), "canChange: another user");
            assert(!rules.canChange(prefs("running"), { userName: "", uid: 1000 }), "canChange: an empty name never matches an empty operator");
            assert(!rules.canChange(null, null), "canChange: nothing known");
        }

        // --- stateOf, scenario by scenario ---
        {
            const facts = extra => Object.assign({ now: now, cli: "present", daemon: "running" }, extra ?? {});
            const check = (statusName, prefsName, extra, expected, message) => {
                const view = rules.stateOf(statusName ? status(statusName) : null, prefsName ? prefs(prefsName) : null, facts(extra));
                assertEqual(view.state, expected.state, message + ": state");
                assertEqual(view.attention?.kind ?? null, expected.attention ?? null, message + ": attention");
                assertEqual(view.status, expected.status, message + ": status line");
                assertEqual(view.summary, view.status, message + ": summary is the status line");
                if (expected.phase)
                    assertEqual(view.phase, expected.phase, message + ": phase");
                return view;
            };
            check("running", "running", {}, { state: "activated", status: "Tailnet only", phase: "running" }, "running");
            check("stopped", "stopped", {}, { state: "", status: "Off", phase: "stopped" }, "stopped");
            check("stopped", "stopped", { operation: "connect" }, { state: "activating", status: "Connecting…" }, "connecting from stopped");
            check("starting", "running", {}, { state: "activating", status: "Starting…", phase: "starting" }, "starting");
            check("running", "running", { operation: "disconnect" }, { state: "deactivating", status: "Disconnecting…" }, "disconnecting");
            const login = check("needs-login", "logged-out", {}, { state: "", attention: "login", status: "Logged out", phase: "logged-out" }, "logged out");
            assertEqual(login.attention.action, "Log in", "logged out: the action");
            assertEqual(login.authUrl, "https://login.tailscale.com/a/REDACTED", "logged out: the login URL is passed on");
            check("needs-login", "logged-out", { operation: "login" },
                  { state: "activating", attention: null, status: "Waiting for the login in the browser…" }, "a login in progress is transient, not attention");
            check("needs-login", "logged-out", { operation: "login", authUrl: "javascript:alert(1)" },
                  { state: "activating", status: "Waiting for the login in the browser…" }, "a bad URL in facts falls back to status's");
            check("key-expired", "running", {}, { state: "", attention: "key-expired", status: "Key expired", phase: "key-expired" }, "key expired");
            check("needs-machine-auth", "running", {}, { state: "", attention: "approval", status: "Waiting for approval", phase: "needs-approval" }, "waiting for approval");
            check("exit-node", "exit-node", {}, { state: "activated", status: "Via peer4" }, "via an exit node");
            const offline = check("exit-node-offline", "exit-node", {}, { state: "activated", attention: "exit-node-offline", status: "Via peer4 (offline)" },
                                  "exit node offline, since unknown: attention");
            assertEqual(offline.attention.action, "Use none", "exit node offline: the action");
            const fresh = check("exit-node-offline", "exit-node", { exitNodeOfflineSince: now - 10000 },
                                { state: "activated", attention: null, status: "Via peer4 (offline)" }, "exit node offline for 10 s: a warning");
            assert(fresh.warnings.some(warning => warning.kind === "exit-node-offline"), "exit node offline for 10 s: the warning");
            check("exit-node-offline", "exit-node", { exitNodeOfflineSince: now - 120000 },
                  { state: "activated", attention: "exit-node-offline", status: "Via peer4 (offline)" }, "exit node offline for 2 min: attention");
            // Within reauthSoonDays (7): a warning and the status line, never attention (TailscaleAccountsTest has the edges)
            const expiring = check("key-expiring", "running", {}, { state: "activated", attention: null, status: "Tailnet only · key expires in 3 days" }, "key expiring in 3 days");
            assert(expiring.warnings.some(warning => warning.kind === "key-expiring" && warning.days === 3), "key expiring in 3 days: a warning");
            const health = check("health-warnings", "running", {}, { state: "activated", status: "Tailnet only" }, "health warnings");
            assertEqual(health.warnings.filter(warning => warning.kind === "health").length, 2, "health warnings: both");
            const update = check("update-available", "running", { updateManagedBySystem: true }, { state: "activated", status: "Tailnet only" }, "update");
            const updateWarning = update.warnings.find(warning => warning.kind === "update");
            assert(updateWarning && updateWarning.text.includes("1.106.0") && updateWarning.text.includes("system"), "update: named, and left to the system");
            check("rich", "rich", {}, { state: "activated", status: "Via Stockholm, Sweden" }, "via a location exit node");
            check(null, null, {}, { state: "", status: "", phase: "unknown" }, "nothing read yet");
            check(null, null, { operation: "connect" }, { state: "activating", status: "Connecting…" }, "nothing read yet, connecting");
            check("running", "running", { cli: "missing" }, { state: "", attention: "not-installed", status: "Not installed", phase: "missing" }, "CLI missing");
            const down = check(null, null, { daemon: "not-running" }, { state: "", attention: "service-not-running", status: "Service not running", phase: "not-running" }, "daemon down");
            assertEqual(down.attention.action, "Start", "daemon down: the action");
            check(null, null, { readDenied: true }, { state: "", attention: "read-denied", status: "Not readable", phase: "denied" }, "may not read");
            const other = rules.stateOf(rules.parseStatus({ BackendState: "InUseOtherUser" }), null, facts());
            assertEqual(other.attention?.kind, "other-user", "another user");
            const unknown = rules.stateOf(rules.parseStatus({ BackendState: "Exploding" }), null, facts());
            assert(unknown.state === "" && unknown.attention === null && unknown.phase === "unknown"
                   && unknown.warnings.some(warning => warning.kind === "unknown-state"), "an unknown BackendState: off, said in a warning");
            assertEqual(rules.stateOf(rules.parseStatus({ BackendState: "NoState" }), rules.parsePrefs({ WantRunning: false }), facts()).state, "",
                        "NoState, not wanted: off");
            assertEqual(rules.stateOf(rules.parseStatus({ BackendState: "NoState" }), rules.parsePrefs({ WantRunning: true }), facts()).state, "activating",
                        "NoState, wanted: starting");
            assertEqual(rules.stateOf(status("stopped"), prefs("logged-out"), facts()).attention?.kind, "login",
                        "stopped and logged out: log in");
        }

        // --- entry: the one entry, in every state, always the contract's shape ---
        {
            const statusNames = ["running", "stopped", "starting", "needs-login", "needs-machine-auth", "exit-node", "exit-node-offline",
                "key-expiring", "key-expired", "health-warnings", "update-available", "rich", null];
            const prefsNames = ["running", "stopped", "logged-out", "exit-node", "rich", null];
            const factSets = [{}, { cli: "missing" }, { daemon: "not-running" }, { readDenied: true }, { operation: "connect" },
                { operation: "disconnect" }, { operation: "login" }, { operation: "logout" }, null, { now: "x", operation: 5 }];
            let combinations = 0;
            let problems = [];
            for (const statusName of statusNames) {
                for (const prefsName of prefsNames) {
                    for (const extra of factSets) {
                        const entry = rules.entry(statusName ? status(statusName) : null, prefsName ? prefs(prefsName) : null,
                                                  extra === null ? null : Object.assign({ now: now }, extra));
                        combinations++;
                        const found = contractProblems(entry);
                        if (entry?.id !== "main")
                            found.push("id " + entry?.id);
                        if (found.length > 0)
                            problems.push((statusName ?? "null") + "/" + (prefsName ?? "null") + "/" + JSON.stringify(extra) + ": " + found.join(", "));
                    }
                }
            }
            assertEqual(problems.length, 0, "entry: " + combinations + " combinations all fit the contract, id always \"main\""
                        + (problems.length > 0 ? " — " + problems.slice(0, 3).join("; ") : ""));
            for (const hostile of [undefined, 0, "x", [], { ok: true }, { ok: true, peers: null }])
                assertEqual(contractProblems(rules.entry(hostile, hostile, hostile)).length, 0, "entry: hostile input " + JSON.stringify(hostile) + " still gives the entry");

            const running = rules.entry(status("running"), prefs("running"), { now: now });
            assertEqual(running.name, "Tailscale", "entry: a personal tailnet (named by the account's e-mail address): just \"Tailscale\"");
            const organisation = JSON.parse(fixture("status-running.json"));
            organisation.CurrentTailnet.Name = "Example Org";
            assertEqual(rules.entry(rules.parseStatus(organisation), prefs("running"), { now: now }).name, "Tailscale · Example Org",
                        "entry: a named organisation tailnet: \"Tailscale · <its name>\"");
            assertEqual(rules.entryTailnet(status("running"), {}), "", "entryTailnet: never an e-mail address");
            assertEqual(rules.tailnetName(status("running"), {}), "example-tailnet.ts.net", "tailnetName (the card's and the page's): a personal tailnet by its MagicDNS suffix, never the e-mail address it is named after");
            assertEqual(rules.entry(null, null, { daemon: "not-running", lastTailnet: "user@example.com" }).name, "Tailscale",
                        "entry: an e-mail address remembered from before is not shown");
            same(running.detail, { iface: "tailscale0", interfaceName: "tailscale0", addresses: ["100.64.0.1", "fd7a:115c:a1e0::1"],
                                   server: "controlplane.tailscale.com", dns: ["100.100.100.100"] }, "entry: detail while up");
            assertEqual(running.status, "Tailnet only", "entry: the status line");
            // What Tailscale does with the traffic, for the shell's Api.vpnsUp (fullTunnel, setsDns, routes)
            same([running.fullTunnel, running.setsDns, running.routes], [false, true, ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "192.168.99.0/24"]],
                 "entry: no exit node — not a full tunnel; Tailscale's DNS; its ranges and the accepted subnet route");
            const throughExit = rules.entry(status("exit-node"), prefs("exit-node"), { now: now });
            same([throughExit.fullTunnel, throughExit.routes.slice(-2)], [true, ["0.0.0.0/0", "::/0"]], "entry: through an exit node — a full tunnel, all of both families");
            const noRoutes = rules.entry(status("running"), rules.parsePrefs(Object.assign(JSON.parse(fixture("prefs-running.json")), { RouteAll: false, CorpDNS: false })), { now: now });
            same([noRoutes.setsDns, noRoutes.routes], [false, ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]], "entry: routes not accepted, DNS not used — its own ranges only, no DNS");
            const down = rules.entry(status("stopped"), prefs("stopped"), { now: now });
            same([down.fullTunnel, down.setsDns, down.routes], [null, null, null], "entry: not up — not known (null), never false");
            same([rules.traffic(status("running"), null, rules.stateOf(status("running"), null, { now: now })).routes], [null], "traffic: prefs not read — unknown");
            assertEqual(running.busy, false, "entry: not busy");
            same(Object.keys(rules.entry(status("needs-login"), prefs("logged-out"), { now: now }).attention).sort(), ["action", "reason"],
                 "entry: attention is exactly { reason, action }");
            assertEqual(rules.entry(status("exit-node"), prefs("exit-node"), { now: now }).detail.server, "peer4.example-tailnet.ts.net",
                        "entry: the server is the exit node");
            assertEqual(rules.entry(status("exit-node"), prefs("exit-node"), { now: now }).status, "Via peer4", "entry: via the exit node");
            same(rules.entry(status("stopped"), prefs("stopped"), { now: now }).detail, {}, "entry: no detail while off");
            assertEqual(rules.entry(null, null, { daemon: "not-running" }).name, "Tailscale", "entry: no tailnet known: the type alone");
            assertEqual(rules.entry(null, null, { daemon: "not-running", lastTailnet: "example-tailnet.ts.net" }).name,
                        "Tailscale · example-tailnet.ts.net", "entry: the remembered tailnet while down");
            assertEqual(rules.entry(status("running"), prefs("running"), { now: now, operation: "disconnect" }).busy, true, "entry: busy during an operation");
            const userspace = rules.parseStatus(Object.assign(JSON.parse(fixture("status-running.json")), { TUN: false }));
            assertEqual(rules.entry(userspace, prefs("running"), { now: now }).detail.iface, undefined, "entry: userspace networking has no interface");
            assertEqual(rules.entry(status("running"), prefs("running"), { now: now, interfaceName: "ts1" }).detail.iface, "ts1", "entry: another interface name");
            assertEqual(rules.entry(status("running"), prefs("running"), { now: now, interfaceName: "x; rm -rf /" }).detail.iface, "tailscale0",
                        "entry: an impossible interface name is ignored");
            const longName = JSON.parse(fixture("status-exit-node.json"));
            longName.Peer["nodekey:peer4"].DNSName = "a-very-long-exit-node-name-that-goes-on-and-on-and-on-and-on-and-on-well-past-eighty-characters.example-tailnet.ts.net.";
            const longEntry = rules.entry(rules.parseStatus(longName), prefs("exit-node"), { now: now });
            assert(longEntry.status.length <= 80 && longEntry.status.startsWith("Via a-very-long") && longEntry.status.endsWith("…"),
                   "entry: the status line is at most 80 characters, the cut marked");
            const noDns = rules.parsePrefs(Object.assign(JSON.parse(fixture("prefs-running.json")), { CorpDNS: false }));
            assertEqual(rules.entry(status("running"), noDns, { now: now }).detail.dns, undefined, "entry: no Tailscale DNS while accept-DNS is off");
        }

        // --- plans: connect, disconnect, attend; origin user vs network ---
        {
            const view = (statusName, prefsName, extra) => rules.stateOf(statusName ? status(statusName) : null, prefsName ? prefs(prefsName) : null,
                                                                          Object.assign({ now: now }, extra ?? {}));
            const stopped = view("stopped", "stopped");
            let plan = rules.planConnect(stopped, true, "user");
            assert(plan.kind === "run" && !plan.privileged, "plan: connect as the operator runs plainly");
            same(plan.command.argv, ["tailscale", "up"], "plan: connect is bare `tailscale up`");
            plan = rules.planConnect(stopped, false, "user");
            assert(plan.kind === "run" && plan.privileged, "plan: connect by a user click, not operator: through pkexec");
            plan = rules.planConnect(stopped, false, "network");
            assert(plan.kind === "needs-user" && plan.command === null && plan.attention?.kind === "needs-privilege",
                   "plan: connect for a network, not operator: never a prompt, attention instead");
            assertEqual(plan.attention.action, "Connect", "plan: that attention's action");
            plan = rules.planConnect(stopped, true, "network");
            assert(plan.kind === "run" && !plan.privileged, "plan: connect for a network as the operator runs");
            const loggedOut = view("needs-login", "logged-out");
            plan = rules.planConnect(loggedOut, false, "user");
            assert(plan.kind === "run" && plan.privileged, "plan: connect while logged out logs in (pkexec)");
            same(plan.command.argv, ["tailscale", "login"], "plan: the login is bare `tailscale login`");
            plan = rules.planConnect(loggedOut, true, "network");
            assert(plan.kind === "needs-user" && plan.attention?.kind === "login", "plan: for a network, a login is never started (no browser)");
            plan = rules.planConnect(view("key-expired", "running"), true, "network");
            assert(plan.kind === "needs-user" && plan.attention?.kind === "key-expired", "plan: key expired, for a network: needs the user");
            assertEqual(rules.planConnect(view("running", "running"), false, "network").kind, "nothing", "plan: connect while running: nothing");
            assertEqual(rules.planConnect(view("starting", "running"), false, "user").kind, "nothing", "plan: connect while starting: nothing");
            plan = rules.planConnect(view(null, null, { daemon: "not-running" }), true, "network");
            assert(plan.kind === "needs-user" && plan.attention?.kind === "service-not-running", "plan: daemon down, for a network: needs the user");
            assertEqual(rules.planConnect(view(null, null, { cli: "missing" }), true, "user").kind, "recheck", "plan: not installed, Connect by the user: look again (installed since?), nothing run");
            assertEqual(rules.planConnect(view(null, null, { cli: "missing" }), true, "network").kind, "needs-user", "plan: not installed, for a network: the attention, no looking");
            assertEqual(rules.planConnect(view("needs-machine-auth", "running"), true, "user").kind, "nothing", "plan: waiting for approval: connect does nothing");
            // The state unknown (not read yet, or the last read timed out): read first, never a blind `up`
            for (const unknown of [view(null, null), view("running", "running", { stale: true })]) {
                for (const origin of ["user", "network"]) {
                    plan = rules.planConnect(unknown, false, origin);
                    assert(plan.kind === "read" && plan.command === null && !plan.privileged, "plan: connect while the state is unknown (" + origin + "): read, nothing run");
                }
            }
            const stale = view("running", "running", { stale: true });
            assert(stale.phase === "unknown" && stale.state === "" && stale.status === "Not answering — state unknown",
                   "state: a read that timed out: unknown, not \"connected\" from the last answer: " + JSON.stringify([stale.phase, stale.state, stale.status]));
            assertEqual(rules.entry(status("running"), prefs("running"), { now: now, stale: true }).name, "Tailscale", "entry: still listed while stale");
            assertEqual(view(null, null, { stale: true, operation: "connect" }).status, "Connecting…", "state: stale but connecting: \"Connecting…\"");
            const untrusted = view(null, null, { cli: "untrusted", untrustedReason: "The tailscale found on PATH is not trusted" });
            assert(untrusted.phase === "untrusted" && untrusted.status === "Not trusted" && untrusted.attention?.kind === "untrusted"
                   && untrusted.attention.reason === "The tailscale found on PATH is not trusted" && untrusted.attention.action === "Check again",
                   "state: an untrusted program: \"Not trusted\", attention with the reason, \"Check again\"");
            assertEqual(rules.planConnect(untrusted, true, "user").kind, "recheck", "plan: untrusted: nothing runs, the programs are looked at again");

            const running = view("running", "running");
            plan = rules.planDisconnect(running, false, "user");
            assert(plan.kind === "run" && plan.privileged, "plan: disconnect by a click, not operator: pkexec");
            same(plan.command.argv, ["tailscale", "down"], "plan: disconnect is `tailscale down`");
            plan = rules.planDisconnect(running, false, "network");
            assert(plan.kind === "needs-user" && plan.attention?.action === "Disconnect", "plan: disconnect for a network, not operator: attention");
            assert(rules.planDisconnect(running, true, "network").kind === "run", "plan: disconnect for a network as the operator");
            assertEqual(rules.planDisconnect(stopped, true, "user").kind, "nothing", "plan: disconnect while off: nothing");
            const pending = view("stopped", "stopped", { operation: "connect" });
            plan = rules.planDisconnect(pending, true, "user", { connecting: true });
            assert(plan.kind === "run" && plan.command.argv.join(" ") === "tailscale down", "plan: disconnect while a connect is pending: `down`, whatever the phase");
            plan = rules.planDisconnect(pending, false, "network", { connecting: true });
            assert(plan.kind === "needs-user" && !plan.privileged, "plan: … for a network, not operator: attention, never a prompt");
            assertEqual(rules.planDisconnect(view(null, null), true, "user").kind, "read", "plan: disconnect while unknown: read first");

            plan = rules.planAttend(loggedOut, false, "user");
            assert(plan.kind === "run" && plan.privileged && plan.command.argv.join(" ") === "tailscale login", "plan: attend a login: log in");
            plan = rules.planAttend(view("needs-machine-auth", "running"), true, "user");
            assert(plan.kind === "open-url" && plan.url.startsWith("https://"), "plan: attend an approval: the admin page");
            plan = rules.planAttend(view(null, null, { daemon: "not-running" }), false, "user");
            same(plan.command?.argv, ["systemctl", "start", "tailscaled.service"], "plan: attend the service: systemctl (polkit asks itself)");
            assert(!plan.privileged, "plan: no pkexec in front of systemctl");
            plan = rules.planAttend(view("exit-node-offline", "exit-node"), false, "user");
            same(plan.command?.argv, ["tailscale", "set", "--exit-node="], "plan: attend an offline exit node: use none");
            assert(plan.privileged, "plan: through pkexec when not the operator");
            assertEqual(rules.planAttend(loggedOut, true, "network").kind, "needs-user", "plan: attend is never unattended");
            const needsPrivilege = Object.assign({}, stopped, { attention: { kind: "needs-privilege", reason: "x", action: "Connect" } });
            assert(rules.planAttend(needsPrivilege, false, "user").command?.argv.join(" ") === "tailscale up", "plan: attend a needed password: connect now, by the user");
            assertEqual(rules.planAttend(view(null, null, { cli: "missing" }), true, "user").kind, "recheck", "plan: not installed: \"Check again\" looks again");
            // As VpnManager reads request.origin: anything but "network" is the user
            for (const origin of [undefined, null, "", "User", 5]) {
                assert(rules.planConnect(stopped, false, origin).privileged, "plan: origin " + JSON.stringify(origin) + " is the user's (may prompt)");
                assertEqual(rules.planConnect(loggedOut, false, origin).command?.argv.join(" "), "tailscale login", "plan: origin " + JSON.stringify(origin) + " may log in");
            }
            // Never a prompt, never a browser for a network, in any state
            const views = [stopped, running, loggedOut, view("key-expired", "running"), view("needs-machine-auth", "running"),
                           view("exit-node-offline", "exit-node"), view(null, null, { daemon: "not-running" }), view(null, null)];
            const unattended = [];
            for (const each of views)
                for (const allowed of [true, false])
                    unattended.push(rules.planConnect(each, allowed, "network"), rules.planDisconnect(each, allowed, "network"), rules.planAttend(each, allowed, "network"));
            assert(unattended.every(item => !item.privileged && item.kind !== "open-url" && item.command?.argv?.[1] !== "login"),
                   "plan: origin network never prompts, never opens a browser, never logs in (" + unattended.length + " plans)");
            assert(unattended.filter(item => item.kind === "needs-user").every(item => item.attention && item.attention.reason !== ""),
                   "plan: whenever the network's plan needs the user, it says why");
            for (const hostile of [null, undefined, {}, { phase: 5 }, "x"]) {
                const plans = [rules.planConnect(hostile, true, "user"), rules.planDisconnect(hostile, true, "network"), rules.planAttend(hostile, true, "user")];
                assert(plans.every(item => typeof item.kind === "string"), "plan: hostile view " + JSON.stringify(hostile) + " gives a plan");
            }
        }

        // --- a fresh install: NoState / NeedsLogin with no profile; Connect always leads somewhere ---
        {
            const state = (statusObject, prefsObject, extra) => rules.stateOf(rules.parseStatus(statusObject), prefsObject === null ? null : rules.parsePrefs(prefsObject),
                                                                               Object.assign({ now: now }, extra ?? {}));
            // A daemon fresh from the package: no node key, not trying to run
            const fresh = state({ BackendState: "NoState", HaveNodeKey: false }, { WantRunning: false, LoggedOut: false });
            assert(fresh.phase === "logged-out" && fresh.attention?.kind === "login" && fresh.attention.action === "Log in" && fresh.state === "",
                   "fresh NoState, no node key: logged out, \"Log in\" — not an idle \"Off\" whose Connect does nothing: " + JSON.stringify([fresh.phase, fresh.attention]));
            assertEqual(state({ BackendState: "NoState", HaveNodeKey: false }, null).phase, "logged-out", "fresh NoState, prefs not read yet: logged out too");
            let plan = rules.planConnect(fresh, false, "user");
            assert(plan.kind === "run" && plan.privileged && plan.command.argv.join(" ") === "tailscale login", "fresh NoState: Connect (user, not operator) logs in through pkexec");
            assertEqual(rules.planConnect(fresh, false, "network").kind, "needs-user", "fresh NoState: for a network, needs the user (no browser)");
            const freshLogin = state({ BackendState: "NoState", HaveNodeKey: false }, { WantRunning: false }, { operation: "login" });
            assert(freshLogin.state === "activating" && freshLogin.status === "Logging in…" && freshLogin.attention === null, "fresh NoState while logging in: activating, \"Logging in…\"");
            const waiting = state({ BackendState: "NoState", HaveNodeKey: false }, { WantRunning: true });
            assertEqual(waiting.phase + "|" + waiting.state, "starting|activating", "NoState, no key but wanted (an `up` waiting for the control server): starting");
            // Logged in, idle
            const idle = state({ BackendState: "NoState", HaveNodeKey: true }, { WantRunning: false });
            assert(idle.phase === "stopped" && idle.status === "Off" && idle.state === "" && idle.attention === null, "NoState with a key, not wanted: off, as Stopped");
            plan = rules.planConnect(idle, false, "user");
            assert(plan.kind === "run" && plan.privileged && plan.command.argv.join(" ") === "tailscale up", "idle NoState: Connect runs `up` (pkexec when not the operator), never nothing");
            const idleConnecting = state({ BackendState: "NoState", HaveNodeKey: true }, { WantRunning: false }, { operation: "connect" });
            assertEqual(idleConnecting.state + "|" + idleConnecting.status, "activating|Starting…", "idle NoState, connecting: activating");
            assertEqual(state({ BackendState: "NoState", HaveNodeKey: true }, { WantRunning: true }).phase, "starting", "NoState with a key, wanted: starting");
            // NeedsLogin on a fresh install: LoggedOut false, no node key, WantRunning false
            const needsLogin = state({ BackendState: "NeedsLogin", HaveNodeKey: false, AuthURL: "" }, { WantRunning: false, LoggedOut: false });
            assert(needsLogin.phase === "logged-out" && needsLogin.attention?.action === "Log in", "fresh NeedsLogin: logged out, \"Log in\"");
            assertEqual(rules.planAttend(needsLogin, false, "user").command?.argv.join(" "), "tailscale login", "fresh NeedsLogin: its action logs in");
            // Every phase a click can meet: Connect by the user never ends in a plain "nothing"
            // unless the entry already says why (attention) or it is already up
            const phases = [fresh, idle, needsLogin, waiting,
                            rules.stateOf(null, null, { now: now }), rules.stateOf(null, null, { now: now, cli: "missing" }),
                            rules.stateOf(null, null, { now: now, cli: "untrusted" }), rules.stateOf(null, null, { now: now, daemon: "not-running" }),
                            rules.stateOf(null, null, { now: now, readDenied: true }), rules.stateOf(null, null, { now: now, stale: true })];
            for (const each of phases) {
                for (const allowed of [true, false]) {
                    const result = rules.planConnect(each, allowed, "user");
                    const silent = result.kind === "nothing" && each.attention === null && !["running", "starting"].includes(each.phase);
                    assert(!silent, "connect (user) in phase " + each.phase + ": not a silent nothing (" + result.kind + ")");
                }
            }
        }

        // --- a failed click: its reason on the status line (failureText), its life (failureAfter) ---
        {
            assertEqual(rules.failureText("No authentication agent answered."), "No authentication agent answered.", "failure: the reason as it is");
            assertEqual(rules.failureText(""), "That didn't work.", "failure: never empty");
            const long = rules.failureText("first line\n\n  second line " + "x".repeat(400));
            assert(long.startsWith("first line second line") && long.length <= 80, "failure: one line, at most the status line's 80 characters");
            // A failure with no words of its own: the daemon's (a kernel updated without a reboot
            // leaves it without its network device: `up` waits, only health says why)
            const health = [{ code: "update-available", severity: "low", text: "An update is available.", impactsConnectivity: false },
                            { code: "network-device", severity: "high", text: "Tailscale could not create its network device.", impactsConnectivity: true }];
            assertEqual(rules.failureText(rules.timeoutMessage("connect", 60), { error: "", health: health }), "Tailscale could not create its network device.",
                        "failure: a time limit with health: the warning that cuts the connection");
            assertEqual(rules.failureText(rules.timeoutMessage("connect", 60), { error: "", health: [health[0]] }), "Still connecting after 60 s. Disconnect to stop.",
                        "failure: an update notice is no reason: the time limit said");
            assertEqual(rules.failureText("Tailscale exited with status 1.", { error: "", health: [{ severity: "high", text: "router: setting up rules failed" }] }),
                        "router: setting up rules failed", "failure: a bare exit status: a severe warning");
            assertEqual(rules.failureText("Tailscale exited with status 1.", { error: "", health: ["router: setting up rules failed"] }),
                        "Tailscale exited with status 1.", "failure: health without a severity is not taken");
            assertEqual(rules.failureText(rules.timeoutMessage("connect", 60), { error: "tun device not available", health: health }),
                        "Tailscale said: tun device not available", "failure: the daemon's own error first");
            assertEqual(rules.failureText("failed to set up the network device: no such device", { error: "x", health: health }),
                        "failed to set up the network device: no such device", "failure: the CLI's own line is kept");
            assertEqual(typeof rules.failureText("", { health: [null, 5, { text: 7 }] }), "string", "failure: hostile health");
            // Plain text only: nothing a Text could take for markup
            const marked = rules.failureText("<b>bad</b> & <address> &amp;", { error: "" });
            assert(!/[<>&]/.test(marked), "failure: no angle brackets or ampersands: " + marked);
            assertEqual(rules.plainText("a <i>b</i> & c\u0007d"), "a ‹i›b‹/i› ＆ c d", "plainText: look-alikes, no control characters");
            assert(rules.healthList([{ title: "<x>", text: "a & b" }], null).every(item => !/[<>&]/.test(item.title + item.text)), "healthList: plain text");

            // Its life
            let failure = rules.failureAfter(null, "failed", "stopped", "No authentication agent answered.");
            same(failure, { text: "No authentication agent answered.", phase: "stopped", settling: true }, "life: a new one settles with the next read");
            assertEqual(rules.failureAfter(failure, "view", "starting"), failure, "life: while settling, a view change keeps it");
            const settled = rules.failureAfter(failure, "read", "starting");
            same(settled, { text: "No authentication agent answered.", phase: "starting", settling: false }, "life: the read after: the phase it left Tailscale in");
            assertEqual(rules.failureAfter(failure, "read", "running"), null, "life: up after all: gone");
            assertEqual(rules.failureAfter(settled, "read", "starting"), settled, "life: the same phase: kept");
            assertEqual(rules.failureAfter(settled, "read", "stopped"), null, "life: another phase (read): gone");
            assertEqual(rules.failureAfter(settled, "view", "stopped"), null, "life: another phase (view): gone");
            for (const event of ["acted", "succeeded", "connecting", "stopped"])
                assertEqual(rules.failureAfter(settled, event, "starting"), null, "life: " + event + ": gone");
            assertEqual(rules.failureAfter(null, "read", "stopped"), null, "life: none stays none");
            assertEqual(rules.failureAfter(null, "failed", "stopped", "").text, "That didn't work.", "life: a new one is never empty");

            // Attend does what its button says, whatever the phase reads now
            const view = (statusName, prefsName, extra) => rules.stateOf(statusName ? status(statusName) : null, prefsName ? prefs(prefsName) : null,
                                                                          Object.assign({ now: now }, extra ?? {}));
            const lagging = Object.assign({}, view("running", "running"), { attention: { kind: "needs-privilege", reason: "x", action: "Connect" } });
            assertEqual(rules.planAttend(lagging, false, "user").kind, "nothing", "attend \"Connect\" while the view says running: never a disconnect");
            const stoppedMeanwhile = Object.assign({}, view("stopped", "stopped"), { attention: { kind: "needs-privilege", reason: "x", action: "Disconnect" } });
            assertEqual(rules.planAttend(stoppedMeanwhile, false, "user").command?.argv.join(" "), "tailscale down", "attend \"Disconnect\" while the view says stopped: `down`, never `up`");
        }

        // --- logging once per change of outcome (logLine; the shell's module.log keeps one line per key) ---
        {
            let failing = false;
            let last = "";
            const lines = [];
            const attempt = (ok, reason) => {
                const line = rules.logLine("status --json", ok, reason, failing);
                if (line === null)
                    return;
                // As module.log with a key: the same level and text again is not written
                const memo = line.level + ":" + line.text;
                if (memo === last)
                    return;
                last = memo;
                failing = line.level !== "info";
                lines.push(memo);
            };
            attempt(true, "");
            for (let i = 0; i < 14; i++)
                attempt(false, "The Tailscale service (tailscaled) is not running.");
            attempt(false, "Tailscale did not answer within 15 s.");
            attempt(false, "Tailscale did not answer within 15 s.");
            attempt(true, "");
            attempt(true, "");
            same(lines, ["warn:status --json failed: The Tailscale service (tailscaled) is not running.",
                         "warn:status --json failed: Tailscale did not answer within 15 s.",
                         "info:status --json answers again"],
                 "log: 14 failed attempts are one line; a new reason one more; the recovery one");
            same(rules.logLine("x", false, "", false), { level: "warn", text: "x failed: failed" }, "log: a failure without a reason still says so");
            assertEqual(rules.logLine("x", true, "", false), null, "log: answering as before — nothing");
            assert(!rules.logLine("x", false, "a\nb <c>", false).text.includes("\n"), "log: one line, plain");
        }

        // --- looking again: recheckPlan, recheckDelayMs ---
        {
            assertEqual(rules.recheckPlan({ cli: "missing" }, false), "probe", "recheck: not installed: look for the programs");
            assertEqual(rules.recheckPlan({ cli: "untrusted" }, false), "probe", "recheck: not trusted: look again");
            assertEqual(rules.recheckPlan({ cli: "unknown" }, false), "probe", "recheck: never looked (or the look got lost): look");
            assertEqual(rules.recheckPlan({ cli: "present", daemon: "not-running", phase: "not-running" }, false), "read", "recheck: the service not running: read (and the stream)");
            assertEqual(rules.recheckPlan({ cli: "present", daemon: "running", phase: "denied" }, false), "read", "recheck: not readable: read");
            assertEqual(rules.recheckPlan({ cli: "present", daemon: "running", phase: "running" }, false), "none", "recheck: all there: nothing (the stream and the poll)");
            assertEqual(rules.recheckPlan({ cli: "present", daemon: "running", phase: "unknown", readFailing: true }, false), "read", "recheck: status reads failing: read on the backoff");
            assertEqual(rules.recheckPlan({ cli: "present", daemon: "running", phase: "running" }, true), "read", "recheck: asked while all is there: read");
            assertEqual(rules.recheckPlan(null, false), "probe", "recheck: hostile facts: look");
            same([0, 1, 2, 3, 4, 10, 1000].map(attempt => rules.recheckDelayMs(attempt, 5000, 60000)), [5000, 10000, 20000, 40000, 60000, 60000, 60000],
                 "recheck: 5 s doubling to the slow poll's minute");
            assertEqual(rules.recheckDelayMs(0, 5000, 2000), 5000, "recheck: never below its first wait");
            assert([[undefined, undefined, undefined], ["x", null, -5], [-3, 0, 0]].every(args => {
                const ms = rules.recheckDelayMs(args[0], args[1], args[2]);
                return typeof ms === "number" && ms >= 100 && isFinite(ms);
            }), "recheck: hostile arguments give a sane wait");
        }
    }
}
