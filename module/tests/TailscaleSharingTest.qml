import QtQuick
import qs.tests
import ".."

// TailscaleRules for delivery step 3: what this computer offers (exit node, subnet routes with
// their approval, tags, the app connector, NAT, filtering, the peer relay, posture, the web
// interface), the route checks, how the exit node and the routes compose into one `tailscale
// set` each, the refused combinations, IP forwarding, Tailscale SSH (server and the device
// rows' ssh command) — and the "This device" name while the tailnet has not caught up — on
// redacted fixtures (prefs/status-sharing.json, synthetic from tailscale 1.104.4's real ones)
// and on input from older or newer daemons.
TestCase {
    id: suite
    suiteName: "tailscale: sharing this computer, SSH"

    readonly property var rules: TailscaleRules
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

    function run() {
        prefsFields();
        approval();
        routeChecks();
        routeEdits();
        composition();
        refusedCombinations();
        forwarding();
        ssh();
        relayAndMore();
        deviceName();
    }

    function prefsFields() {
        const prefs = rules.parsePrefs(fixture("prefs-sharing.json"));
        same([prefs.ok, prefs.advertiseExitNode, prefs.advertiseRoutes], [true, true, ["10.20.0.0/16", "192.168.50.0/24", "2001:db8:1::/48"]],
             "prefs: the exit-node pair read as the exit node, the rest as subnet routes");
        same(prefs.advertiseRoutesAll.length, 5, "… the whole list kept too");
        same([prefs.ssh, prefs.webClient, prefs.snat, prefs.statefulFiltering, prefs.netfilterMode, prefs.advertiseConnector, prefs.postureChecking, prefs.relayServerPort],
             [true, true, true, true, "on", true, true, 40000], "prefs: SSH, web interface, SNAT, stateful filtering, netfilter, connector, posture, relay port");
        same(prefs.advertiseTags, ["tag:server", "tag:relay"], "prefs: tags asked for");
        const plain = rules.parsePrefs(fixture("prefs-running.json"));
        same([plain.advertiseExitNode, plain.advertiseRoutes, plain.statefulFiltering, plain.relayServerPort, plain.advertiseConnector],
             [false, [], false, null, false], "prefs (real, 1.104.4): nothing offered, stateful filtering off (NoStatefulFiltering true), no relay");
        const old = rules.parsePrefs('{"AdvertiseRoutes":["0.0.0.0/0"],"NoSNAT":"yes","NetfilterMode":7,"RelayServerPort":70000,"AppConnector":5}');
        same([old.advertiseExitNode, old.advertiseRoutes, old.snat, old.statefulFiltering, old.netfilterMode, old.relayServerPort, old.advertiseConnector],
             [false, [], true, null, "", null, false], "prefs: half an exit pair is no exit node; odd types fall back to the defaults");
    }

    function approval() {
        const status = rules.parseStatus(fixture("status-sharing.json"));
        const prefs = rules.parsePrefs(fixture("prefs-sharing.json"));
        const share = rules.sharing(status, prefs);
        same([share.known, share.connected], [true, true], "sharing: read, connected");
        same(share.routes.map(route => route.route + " " + route.state), [
            "10.20.0.0/16 standby", "192.168.50.0/24 approved", "2001:db8:1::/48 pending"
        ], "routes: approved = in Self.AllowedIPs; primary = PrimaryRoutes; neither = waiting for approval");
        assert(/admin/.test(share.routes[2].text), "… a pending route says it waits for an admin: " + share.routes[2].text);
        same([share.exitNode.offered, share.exitNode.state], [true, "pending"], "exit node offered, not approved (no /0 in AllowedIPs)");
        assertEqual(share.pendingCount, 2, "two things wait for approval");
        assertEqual(share.adminUrl, "https://login.tailscale.com/admin/machines/100.64.0.1", "the admin console's page of this machine");
        same([share.tagsRequested, share.tagsApplied], [["tag:server", "tag:relay"], ["tag:server"]], "tags asked for and applied (read only)");
        same(share.families, [4, 6], "forwarding matters for IPv4 and IPv6 (the exit node)");
        assertEqual(share.webClientUrl, "http://100.64.0.1:5252", "the web interface's link");

        const approved = rules.parseStatus(fixture("status-sharing.json").replace('"10.20.0.0/16"\n    ],', '"10.20.0.0/16",\n      "0.0.0.0/0",\n      "::/0"\n    ],'));
        assertEqual(rules.sharing(approved, prefs).exitNode.state, "approved", "exit node approved: both /0 in AllowedIPs");
        const option = rules.parseStatus(fixture("status-sharing.json").replace('"ExitNodeOption": false', '"ExitNodeOption": true'));
        assertEqual(rules.sharing(option, prefs).exitNode.state, "approved", "… or ExitNodeOption true");
        const stopped = rules.parseStatus(fixture("status-sharing.json").replace('"BackendState": "Running"', '"BackendState": "Stopped"'));
        const offline = rules.sharing(stopped, prefs);
        same([offline.exitNode.state, offline.routes.map(route => route.state)], ["unknown", ["unknown", "unknown", "unknown"]],
             "not connected: approval unknown, not guessed");
        assertEqual(rules.sharing(null, null).known, false, "nothing read: unknown");
        assertEqual(rules.sharing(status, rules.parsePrefs("{}")).offersAny, false, "empty prefs: nothing offered");
        const headscale = rules.parsePrefs(fixture("prefs-sharing.json").replace("https://controlplane.tailscale.com", "https://hs.example.com"));
        assertEqual(rules.sharing(status, headscale).adminUrl, "", "another control server: no admin console link");
    }

    function routeChecks() {
        same(rules.routeProblem("192.168.1.0/24", []), { network: "192.168.1.0/24", error: "", warning: "" }, "route: fine");
        same(rules.routeProblem(" 2001:DB8::/32 ", []).network, "2001:db8::/32", "route: IPv6, written canonically");
        assert(/Host bits/.test(rules.routeProblem("192.168.1.5/24", []).error) && /192\.168\.1\.0\/24/.test(rules.routeProblem("192.168.1.5/24", []).error),
               "route: host bits set → refused, naming the network");
        assert(rules.routeProblem("10.1.2.3", []).error !== "", "route: an address without a prefix (netip.ParsePrefix needs one)");
        assert(/exit node/.test(rules.routeProblem("0.0.0.0/0", []).error), "route: 0.0.0.0/0 → the exit-node switch");
        assert(/exit node/.test(rules.routeProblem("::/0", []).error), "route: ::/0 → the exit-node switch");
        for (const bad of ["192.168.1.0/33", "2001:db8::/129", "300.1.1.0/24", "010.0.0.0/8", "10.0.0.0/08", "10.0.0.0/", "x/24", "", "fe80::1%eth0/64"])
            assert(rules.routeProblem(bad, []).error !== "", "route: " + JSON.stringify(bad) + " refused");
        assertEqual(rules.routeProblem("192.168.1.0/24", ["192.168.1.0/24"]).error, "Already offered.", "route: a duplicate refused");
        assertEqual(rules.routeProblem("2001:db8::/32", ["2001:0db8::/32"]).error, "Already offered.", "route: a duplicate written differently refused");
        const cgnat = rules.routeProblem("100.100.0.0/16", []);
        same([cgnat.error, /100\.64\.0\.0\/10/.test(cgnat.warning)], ["", true], "route: inside 100.64.0.0/10 → allowed with a warning");
        assert(rules.routeProblem("100.0.0.0/8", []).warning !== "", "route: around 100.64.0.0/10 → a warning too");
        assert(rules.routeProblem("fd7a:115c:a1e0:ab::/64", []).warning !== "", "route: inside Tailscale's IPv6 range → a warning");
        assertEqual(rules.routeProblem(null, []).error !== "", true, "route: not text → refused");
        assert(/Host bits/.test(rules.routeProblem("2001:db8::1/64", []).error), "route: IPv6 host bits set (2001:db8::1/64) → refused");
        assertEqual(rules.routeProblem("::ffff:192.0.2.0/120", []).network, "::ffff:192.0.2.0/120", "route: IPv4-mapped IPv6 written as Tailscale prints it");
    }

    // The review's must-fix: a route edit is an intent, planned against fresh prefs
    function routeEdits() {
        const prefs = rules.parsePrefs(fixture("prefs-sharing.json"));
        const identity = rules.prefsIdentity(prefs);
        assertEqual(identity, "user1@example.com|nSELFCNTRL|https://controlplane.tailscale.com", "identity: login, node, control server");
        assertEqual(rules.prefsIdentity(rules.parsePrefs("{}")), "", "identity: nothing known → empty");
        assertEqual(rules.prefsIdentity(null), "", "identity: no prefs → empty");
        const add = rules.routeEditPlan(prefs, { add: "192.168.7.0/24" }, identity);
        same([add.kind, add.command.argv[2]], ["run", "--advertise-routes=10.20.0.0/16,192.168.50.0/24,2001:db8:1::/48,192.168.7.0/24"], "add: the whole list from these prefs");
        assertEqual(rules.routeEditPlan(prefs, { add: "192.168.50.0/24" }, identity).kind, "nothing", "add a route already there (added meanwhile): nothing to send");
        same(rules.routeEditPlan(prefs, { remove: "10.20.0.0/16" }, identity).routes, ["192.168.50.0/24", "2001:db8:1::/48"], "remove: the rest");
        assertEqual(rules.routeEditPlan(prefs, { remove: "10.99.0.0/16" }, identity).kind, "nothing", "remove one not offered (removed meanwhile): nothing to send");
        assertEqual(rules.routeEditPlan(null, { add: "192.168.7.0/24" }, "").kind, "refused", "prefs not read: refused (never a list from nothing)");
        assertEqual(rules.routeEditPlan(rules.parsePrefs("not json"), { remove: "10.20.0.0/16" }, "").kind, "refused", "prefs unreadable: refused");
        const other = rules.parsePrefs(fixture("prefs-sharing.json").replace('"LoginName": "user1@example.com"', '"LoginName": "user1@example.org"'));
        assertEqual(rules.routeEditPlan(other, { add: "192.168.7.0/24" }, identity).kind, "changed", "another profile than the one clicked in: changed meanwhile");
        const many = [];
        for (let i = 0; i < 300; i++)
            many.push("10." + Math.floor(i / 256) + "." + (i % 256) + ".0/24");
        const cut = rules.parsePrefs(JSON.stringify({ AdvertiseRoutes: many, Config: { UserProfile: { LoginName: "a@example.com" } } }));
        same([cut.advertiseRoutesCut, cut.advertiseRoutes.length], [true, 256], "more than 256 routes: the list is cut and says so");
        assertEqual(rules.routeEditPlan(cut, { add: "192.168.7.0/24" }, "").kind, "refused", "… edits refused (they would drop the rest)");
        assertEqual(rules.routeEditPlan(prefs, { add: "10.1.2.3" }, identity).kind, "refused", "an invalid route refused");
        assertEqual(rules.routeEditPlan(prefs, {}, identity).kind, "refused", "no intent refused");
        const held = rules.prefsWithRoutes(prefs, ["192.168.7.0/24"]);
        same([held.advertiseRoutes, held.advertiseRoutesAll, held.advertiseExitNode, prefs.advertiseRoutes.length], [["192.168.7.0/24"], ["0.0.0.0/0", "::/0", "192.168.7.0/24"], true, 3],
             "the list sent held at once (the exit node unchanged), the prefs given untouched");
    }

    function composition() {
        // set.go calcAdvertiseRoutesForSet: each flag alone keeps the other half — so the
        // module sends one of them, never both, and never a /0 in the list
        same(rules.routesWith(["10.20.0.0/16"], "192.168.1.0/24"), ["10.20.0.0/16", "192.168.1.0/24"], "add a route: the list grows");
        same(rules.routesWith(["10.20.0.0/16", "0.0.0.0/0", "::/0"], "192.168.1.0/24"), ["10.20.0.0/16", "192.168.1.0/24"], "… the exit pair never in it");
        same(rules.routesWith(["10.20.0.0/16"], "10.20.0.0/16"), ["10.20.0.0/16"], "… no duplicate");
        same(rules.routesWithout(["10.20.0.0/16", "192.168.1.0/24"], "10.20.0.0/16"), ["192.168.1.0/24"], "remove a route");
        same(rules.routesWithout(["2001:db8::/32"], "2001:0db8::/32"), [], "… matched canonically");
        const prefs = rules.parsePrefs(fixture("prefs-sharing.json"));
        const add = rules.commandFor("advertiseRoutes", { routes: rules.routesWith(prefs.advertiseRoutes, "192.168.7.0/24") });
        same(add.argv, ["tailscale", "set", "--advertise-routes=10.20.0.0/16,192.168.50.0/24,2001:db8:1::/48,192.168.7.0/24"],
             "routes: the whole subnet list, no /0 (set keeps the exit node: CalcAdvertiseRoutes(list, AdvertisesExitNode()))");
        same(rules.commandFor("advertiseRoutes", { routes: [] }).argv, ["tailscale", "set", "--advertise-routes="], "no routes: empty value (keeps the exit node)");
        same(rules.commandFor("advertiseExitNode", { on: true }).argv, ["tailscale", "set", "--advertise-exit-node=true"], "exit node on: the flag alone (keeps the routes)");
        same(rules.commandFor("advertiseExitNode", { on: false }).argv, ["tailscale", "set", "--advertise-exit-node=false"], "exit node off: drops only the pair");
        assert(!rules.commandFor("advertiseRoutes", { routes: ["0.0.0.0/0", "::/0"] }).ok, "routes: the default routes refused in the list");
        assert(!rules.commandFor("advertiseRoutes", { routes: ["10.1.2.3"] }).ok, "routes: a bare address refused");
        assert(!rules.commandFor("advertiseRoutes", { routes: "10.0.0.0/8" }).ok, "routes: not a list refused");
        same(rules.commandFor("advertiseRoutes", { routes: ["10.0.0.0/8", "10.0.0.0/8"] }).argv[2], "--advertise-routes=10.0.0.0/8", "routes: deduplicated");
        for (const name of ["advertiseExitNode", "advertiseRoutes", "ssh", "webClient", "snat", "statefulFiltering", "connector", "posture", "autoUpdate", "updateCheck", "relayServerPort"]) {
            const command = rules.commandFor(name, { on: true, routes: [], port: "" });
            assert(command.ok && command.argv[1] === "set" && command.changes && command.privileged, name + ": a privileged `tailscale set`");
            assert(command.argv.slice(2).every(argument => /^--[a-z-]+=/.test(argument)), name + ": --flag=value form: " + command.argv.join(" "));
        }
        assert(!rules.commandNames.includes("advertiseTags") && !rules.commandFor("advertiseTags", { tags: ["tag:x"] }).ok,
               "no tag changes: --advertise-tags is a flag of `up` only (cli/set.go has none)");
    }

    function refusedCombinations() {
        const using = rules.parsePrefs(fixture("prefs-exit-node.json"));
        assert(/Stop using it/.test(rules.exitNodeOfferProblem(using)), "offering an exit node while using one: refused before it runs (checkExitNodePrefsLocked)");
        assertEqual(rules.exitNodeOfferProblem(rules.parsePrefs(fixture("prefs-running.json"))), "", "… not using one: fine");
        assertEqual(rules.sharing(rules.parseStatus(fixture("status-exit-node.json")), using).exitNode.problem, rules.exitNodeOfferProblem(using), "… shown on the section");
        const offering = rules.parsePrefs(fixture("prefs-sharing.json"));
        assert(/Stop offering/.test(rules.exitNodeUseProblem(offering)), "using an exit node while offering one: refused too");
        assertEqual(rules.exitNodeUseProblem(rules.parsePrefs(fixture("prefs-running.json"))), "", "… not offering: fine");
        assertEqual(rules.exitNodeOfferProblem(null), "", "no prefs: nothing to say");
        // Tailscale's own refusals, shown plainly (the first line that is not a "Warning:")
        assertEqual(rules.errorKind(1, "Cannot advertise an exit node and use an exit node at the same time.").message,
                    "Cannot advertise an exit node and use an exit node at the same time.", "the daemon's refusal shown as it is");
        assertEqual(rules.errorKind(1, "Warning: client version \"1.104.4\" != tailscaled server version \"1.104.2\"\n192.168.1.5/24 has non-address bits set; expected 192.168.1.0/24").message,
                    "192.168.1.5/24 has non-address bits set; expected 192.168.1.0/24", "a CLI warning line is not taken for the error");
        assertEqual(rules.errorKind(1, "Auto-updates are not supported on this platform.").message, "Auto-updates are not supported on this platform.", "auto-update refused (NixOS)");
        assertEqual(rules.errorKind(1, "aborted, no changes made").kind, "aborted", "the lose-ssh confirmation answered no: its own sentence");
        assertEqual(rules.errorKind(2, "flag provided but not defined: -advertise-tags").message, "flag provided but not defined: -advertise-tags", "an unknown flag shown");
    }

    function forwarding() {
        const status = rules.parseStatus(fixture("status-sharing.json"));
        const share = rules.sharing(status, rules.parsePrefs(fixture("prefs-sharing.json")));
        assertEqual(rules.forwardingWarning(share, { ipv4: true, ipv6: true }, null, status, true), null, "both on: no warning");
        const off = rules.forwardingWarning(share, { ipv4: false, ipv6: true }, null, status, true);
        assert(off !== null && /IPv4/.test(off.text) && !/IPv6/.test(off.text), "IPv4 off: a warning naming it: " + off?.text);
        assert(off.nixosLines[0] === "services.tailscale.useRoutingFeatures = \"server\";" && /ip_forward/.test(off.nixosLines[1]), "… with the NixOS lines (useRoutingFeatures, or the sysctls)");
        assert(/ip_forward/.test(rules.forwardingWarning(share, { ipv4: false, ipv6: false }, null, status, false).nixosLines[0]), "… not NixOS: the sysctl settings");
        assertEqual(rules.forwardingWarning(share, { ipv4: null, ipv6: null }, null, status, true), null, "not read: no warning");
        const routesOnly = rules.sharing(status, rules.parsePrefs('{"AdvertiseRoutes":["192.168.50.0/24"]}'));
        same(routesOnly.families, [4], "only an IPv4 route: only IPv4 matters");
        assertEqual(rules.forwardingWarning(routesOnly, { ipv4: true, ipv6: false }, null, status, true), null, "… IPv6 off does not matter then");
        const nothing = rules.sharing(status, rules.parsePrefs(fixture("prefs-running.json")));
        assertEqual(rules.forwardingWarning(nothing, { ipv4: false, ipv6: false }, null, status, true), null, "nothing offered: no warning");
        const connector = rules.sharing(status, rules.parsePrefs('{"AppConnector":{"Advertise":true}}'));
        assert(rules.forwardingWarning(connector, { ipv4: false, ipv6: true }, null, status, true) !== null, "an app connector needs forwarding too (warnOnAdvertiseRoutes)");
        const bus = [{ code: "ip-forwarding-off", title: "IP forwarding is off", text: "Subnet routing is enabled, but IP forwarding is disabled. Check that IP forwarding is enabled on your machine." }];
        const says = rules.forwardingWarning(share, { ipv4: true, ipv6: true }, bus, status, true);
        assert(says !== null && /Subnet routing is enabled/.test(says.tailscaleSays), "Tailscale's own health warning (ip-forwarding-off) shown even when /proc says on");
        const fromStatus = Object.assign({}, status, { health: ["Subnet routing is enabled, but IP forwarding is disabled. Check that IP forwarding is enabled on your machine."] });
        assert(/IP forwarding is disabled/.test(rules.forwardingWarning(share, { ipv4: true, ipv6: true }, null, fromStatus, true)?.tailscaleSays ?? ""), "… or from status's Health text");
    }

    function ssh() {
        const status = rules.parseStatus(fixture("status-running.json"));
        const on = rules.sshServer(status, rules.parsePrefs(fixture("prefs-sharing.json")));
        same([on.on, on.allowedByTailnet, on.canTurnOn], [true, true, true], "SSH server on; the tailnet allows it (cap/ssh in Self's CapMap)");
        const noCap = rules.parseStatus(fixture("status-running.json").replace('"https://tailscale.com/cap/ssh": null,', ""));
        const refused = rules.sshServer(noCap, rules.parsePrefs(fixture("prefs-running.json")));
        same([refused.on, refused.allowedByTailnet, refused.canTurnOn, refused.problem !== ""], [false, false, false, true], "no cap/ssh: it cannot be turned on (checkSSHPrefsLocked), said why");
        assertEqual(rules.sshServer(rules.parseStatus('{"Self":{"HostName":"h"}}'), null).allowedByTailnet, null, "no CapMap (an older daemon): unknown, allowed to try");
        same(rules.commandFor("ssh", { on: true }).argv, ["tailscale", "set", "--ssh=true"], "SSH: set --ssh=true (no --accept-risk: Tailscale's own check stays)");

        const peers = rules.peers(status, now, {});
        const withSsh = peers.filter(device => device.sshHostKeys > 0);
        assert(withSsh.length >= 1, "a device that reports sshHostKeys");
        assert(/^ssh [a-z0-9.-]+\.example-tailnet\.ts\.net$/.test(withSsh[0].sshCommand), "… its command: ssh <MagicDNS name>: " + withSsh[0].sshCommand);
        assert(peers.filter(device => device.sshHostKeys === 0).every(device => device.sshCommand === ""), "devices without Tailscale SSH: no command");
        assertEqual(rules.sshCommand({ sshHostKeys: 1, dnsName: "-oProxyCommand=x", addresses: ["100.64.0.9"] }), "ssh 100.64.0.9", "a name that could be an option: the address instead");
        assertEqual(rules.sshCommand({ sshHostKeys: 1, dnsName: "a;b", addresses: [] }), "", "… and nothing without one");
        assertEqual(rules.sshCommand(null), "", "nothing → no command");
    }

    function relayAndMore() {
        for (const good of ["", "0", "40000", "65535"])
            assertEqual(rules.relayPortProblem(good), "", "relay port " + JSON.stringify(good) + " fine");
        for (const bad of ["65536", "-1", "04", "4 0", "x", null])
            assert(rules.relayPortProblem(bad) !== "", "relay port " + JSON.stringify(bad) + " refused");
        same(rules.commandFor("relayServerPort", { port: "40000" }).argv, ["tailscale", "set", "--relay-server-port=40000"], "relay: a port");
        same(rules.commandFor("relayServerPort", { port: "" }).argv, ["tailscale", "set", "--relay-server-port="], "relay: off (empty value)");
        assert(!rules.commandFor("relayServerPort", { port: "x" }).ok, "relay: refused before it runs");
        same(rules.commandFor("posture", { on: true }).argv, ["tailscale", "set", "--report-posture=true"], "posture: --report-posture (no --posture-checking in 1.104)");
        same(rules.commandFor("snat", { on: false }).argv, ["tailscale", "set", "--snat-subnet-routes=false"], "SNAT off");
        same(rules.commandFor("statefulFiltering", { on: true }).argv, ["tailscale", "set", "--stateful-filtering=true"], "stateful filtering on");
        same(rules.commandFor("connector", { on: true }).argv, ["tailscale", "set", "--advertise-connector=true"], "app connector on");
        same(rules.commandFor("autoUpdate", { on: false }).argv, ["tailscale", "set", "--auto-update=false"], "auto-update off");
        same(rules.commandFor("webClient", { on: true }).argv, ["tailscale", "set", "--webclient=true"], "web interface on");
        const share = rules.sharing(rules.parseStatus(fixture("status-running.json")), rules.parsePrefs(fixture("prefs-running.json")));
        same([share.snat, share.statefulFiltering, share.netfilterMode, share.relayServerPort, share.webClient, share.webClientUrl, share.autoUpdate, share.updateCheck],
             [true, false, "on", null, false, "", null, true], "the real prefs: defaults as 1.104.4 has them");
    }

    // The coordinator's bug 1: `set --hostname` changes prefs at once; status's Self follows
    // only once the control plane has the name (observed: set while Stopped)
    function deviceName() {
        const running = fixture("status-running.json");
        const prefsWith = name => rules.parsePrefs(fixture("prefs-running.json").replace('"Hostname": ""', '"Hostname": "' + name + '"'));
        const stopped = rules.parseStatus(running.replace('"BackendState": "Running"', '"BackendState": "Stopped"'));
        const pendingStopped = rules.thisDevice(stopped, prefsWith("framework"), now, "");
        same([pendingStopped.hostName, pendingStopped.statusName, pendingStopped.namePending, pendingStopped.nameNote],
             ["framework", "self", true, "the tailnet shows it after connecting"], "stopped, name set, status old: the new name shown, said when the tailnet has it");
        const followed = rules.thisDevice(rules.parseStatus(running.replace(/"HostName": "self"/, '"HostName": "framework"')), prefsWith("framework"), now, "");
        same([followed.hostName, followed.namePending, followed.nameNote], ["framework", false, ""], "running, followed: nothing to say");
        const updating = rules.thisDevice(rules.parseStatus(running), prefsWith("framework"), now, "");
        same([updating.hostName, updating.namePending, updating.nameNote], ["framework", true, "updating"], "running, not yet followed: updating");
        const plain = rules.thisDevice(rules.parseStatus(running), rules.parsePrefs(fixture("prefs-running.json")), now, "");
        same([plain.hostName, plain.customHostname, plain.namePending], ["self", "", false], "no name set, system unknown: status's name, nothing pending");
        const back = rules.thisDevice(rules.parseStatus(running.replace(/"HostName": "self"/, '"HostName": "framework"')), rules.parsePrefs(fixture("prefs-running.json")), now, "self.example.com");
        same([back.hostName, back.namePending, back.nameNote], ["self", true, "updating"], "back to the system's name, not yet followed: pending");
        assertEqual(rules.thisDevice(rules.parseStatus(running), rules.parsePrefs(fixture("prefs-running.json")), now, "SELF").namePending, false, "the system's name, followed (case and domain ignored)");
        assertEqual(rules.thisDevice(rules.parseStatus(running), prefsWith("Self"), now, "").namePending, false, "a name differing only in case: followed");
    }
}
