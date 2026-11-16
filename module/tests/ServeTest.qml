import QtQuick
import qs.tests
import ".."

// Delivery step 5, the pure parts: ServeRules (serve configs — proxy, TCP, Funnel on and off,
// paths, empty, unknown fields —, preconditions, every argv, intents planned against a fresh
// config), CertRules, LockRules (lock status variants), NetworkExitRules (the table's decisions).
TestCase {
    id: suite
    suiteName: "tailscale: serve, certificates, lock, exit node per network"

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
        configs();
        preconditions();
        plans();
        certificates();
        lock();
        networkExit();
    }

    readonly property var serveStatus: TailscaleRules.parseStatus(fixture("status-serve.json"))
    readonly property var plainStatus: TailscaleRules.parseStatus(fixture("status-running.json"))
    readonly property var prefs: TailscaleRules.parsePrefs(fixture("prefs-running.json"))

    function configs() {
        const empty = ServeRules.parseConfig(fixture("serve-empty.json"));
        same([empty.ok, empty.empty, empty.entries.length, empty.funnelOn], [true, true, 0, false], "empty config: nothing shared");
        same(ServeRules.parseConfig("").ok, true, "no output: empty");
        same(ServeRules.parseConfig("[1]").ok, false, "a list: not ok");
        same(ServeRules.parseConfig("{nope").ok, false, "not JSON: not ok");

        const proxy = ServeRules.parseConfig(fixture("serve-proxy.json"));
        same(proxy.entries.map(entry => [entry.type, entry.port, entry.mount, entry.what, entry.funnel]),
             [["https", 443, "/", "proxy", false], ["https", 443, "/api", "proxy", false]], "proxy: two mounts on 443");
        same(proxy.entries.map(entry => entry.url), ["https://self.example-tailnet.ts.net/", "https://self.example-tailnet.ts.net/api"], "proxy: links without :443");
        assertEqual(ServeRules.targetLabel(proxy.entries[0]), "port 3000", "a local proxy is named by its port");

        const funnel = ServeRules.parseConfig(fixture("serve-funnel.json"));
        same(funnel.entries.map(entry => [entry.port, entry.what, entry.funnel]), [[443, "proxy", true], [8443, "text", false]], "funnel: on for 443, off (false) for 8443");
        assert(funnel.funnelOn, "funnel: on somewhere");
        assertEqual(funnel.entries[1].url, "https://self.example-tailnet.ts.net:8443/", "a port other than 443 is in the link");

        const tcp = ServeRules.parseConfig(fixture("serve-tcp.json"));
        same(tcp.entries.map(entry => [entry.type, entry.port, entry.target]), [["tcp", 2222, "127.0.0.1:22"], ["tls-terminated-tcp", 5432, "127.0.0.1:5432"]], "TCP forwarders");
        same(ServeRules.entriesFor(tcp, serveStatus)[0].urls.slice(0, 2), ["self.example-tailnet.ts.net:2222", "100.64.0.1:2222"], "a forwarder's names to copy, with the port");

        const paths = ServeRules.parseConfig(fixture("serve-path.json"));
        assert(paths.entries.length === 2 && paths.entries.every(entry => entry.what === "path"), "path entries listed as paths");

        const rich = ServeRules.parseConfig(fixture("serve-rich.json"));
        assert(rich.ok, "unknown fields are ignored");
        same([rich.foreground, rich.services], [1, 1], "foreground sessions and services counted, not listed");
        assert(rich.entries.some(entry => entry.type === "http" && entry.port === 80 && entry.url === "http://self.example-tailnet.ts.net/"), "an HTTP listener");
        assert(rich.entries.some(entry => entry.what === "redirect"), "a redirect is shown as one");
        same(ServeRules.parseConfig({ Web: { "__proto__": { Handlers: {} } }, TCP: { "0": { HTTPS: true }, "x": 1 } }).entries, [], "garbage keys dropped");
    }

    function preconditions() {
        const ready = ServeRules.preconditions(serveStatus, prefs);
        same([ready.connected, ready.https, ready.magicDns, ready.funnelAllowed, ready.canFunnel, ready.funnelPorts], [true, true, true, true, true, [443, 8443, 10000]],
             "the serve fixture: all there");
        const plain = ServeRules.preconditions(plainStatus, prefs);
        same(plain.problems.map(problem => problem.kind), ["https"], "real status: HTTPS certificates off");
        assertEqual(plain.problems[0].url, ServeRules.adminDnsUrl, "with the admin console's DNS page");
        same(ServeRules.preconditions(null, null).problems.map(problem => problem.kind), ["not-connected"], "nothing read: not connected");
        const shields = ServeRules.preconditions(serveStatus, Object.assign({}, prefs, { shieldsUp: true }));
        same([shields.canFunnel, shields.funnelProblems.map(problem => problem.kind)], [false, ["shields-up"]], "shields up: no Funnel");
        const noFunnel = Object.assign({}, serveStatus, { self: Object.assign({}, serveStatus.self, { caps: ["https"] }) });
        same(ServeRules.preconditions(noFunnel, prefs).funnelProblems.map(problem => problem.kind), ["funnel"], "no funnel attribute");
        same(ServeRules.funnelPorts(["https://tailscale.com/cap/funnel-ports?ports=443,8000-8002"]), [443, 8000, 8001, 8002], "port ranges");
        same(ServeRules.funnelPorts(["https://evil.example/cap/funnel-ports?ports=1"]), [], "another capability's ports are not taken");
    }

    function plans() {
        const empty = ServeRules.parseConfig("{}");
        same(ServeRules.addPlan(empty, { kind: "proxy", port: 443, localPort: "3000", path: "" }, serveStatus, prefs).argv,
             ["tailscale", "serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:3000"], "share port 3000");
        same(ServeRules.addPlan(empty, { kind: "proxy", port: 8443, localPort: 8080, path: "app", funnel: true }, serveStatus, prefs).argv,
             ["tailscale", "funnel", "--bg", "--yes", "--https=8443", "--set-path=/app", "http://127.0.0.1:8080"], "with a path, on the internet");
        same(ServeRules.addPlan(empty, { kind: "tcp", port: 2222, localPort: 22 }, serveStatus, prefs).argv,
             ["tailscale", "serve", "--bg", "--yes", "--tcp=2222", "tcp://127.0.0.1:22"], "a TCP forward");
        const refused = (config, intent, status, expected, message) => {
            const plan = ServeRules.addPlan(config, intent, status ?? serveStatus, prefs);
            same([plan.kind, plan.error], ["refused", expected], message);
        };
        refused(empty, { kind: "proxy", port: 443, localPort: "3000; rm" }, null, "Enter a local port", "a local port that is not a number");
        refused(empty, { kind: "proxy", port: 443, localPort: "-1" }, null, "Enter a local port", "never something that reads as an option");
        refused(empty, { kind: "proxy", port: 443, localPort: 3000, path: "/../etc" }, null, "Not a usable path", "a path with ..");
        refused(empty, { kind: "proxy", port: 443, localPort: 3000 }, plainStatus, "HTTPS certificates are off for this tailnet", "HTTPS not enabled: never sent");
        refused(empty, { kind: "proxy", port: 443, localPort: 3000, funnel: true },
                Object.assign({}, serveStatus, { self: Object.assign({}, serveStatus.self, { caps: ["https"] }) }), "Funnel is not allowed for this device", "Funnel not permitted");
        refused(empty, { kind: "proxy", port: 4443, localPort: 3000, funnel: true }, null, "Funnel works on port 443, 8443, 10000 only", "a port Funnel does not serve");
        refused(ServeRules.parseConfig(fixture("serve-proxy.json")), { kind: "proxy", port: 443, localPort: 9, path: "/api" }, null, "Already shared", "the same mount again");
        refused(ServeRules.parseConfig(fixture("serve-tcp.json")), { kind: "proxy", port: 2222, localPort: 9 }, null, "Port 2222 is in use", "web on a TCP port");
        refused(null, { kind: "proxy", port: 443, localPort: 3000 }, null, "What is shared is not read yet", "config not read");
        refused(empty, { kind: "proxy", port: 443, localPort: 3000 }, TailscaleRules.parseStatus(fixture("status-stopped.json")), "Connect to share", "not connected");
        // A port with Funnel on keeps it when a path is added there
        const funnel = ServeRules.parseConfig(fixture("serve-funnel.json"));
        assertEqual(ServeRules.addPlan(funnel, { kind: "proxy", port: 443, localPort: 5000, path: "/new" }, serveStatus, prefs).argv[1], "funnel",
                    "adding to a port with Funnel on keeps Funnel on");
        // Remove
        same(ServeRules.removePlan(funnel, funnel.entries[0].key).argv, ["tailscale", "serve", "--bg", "--yes", "--https=443", "--set-path=/", "off"], "remove a web entry");
        const tcp = ServeRules.parseConfig(fixture("serve-tcp.json"));
        same(ServeRules.removePlan(tcp, tcp.entries[1].key).argv, ["tailscale", "serve", "--bg", "--yes", "--tls-terminated-tcp=5432", "off"], "remove a forwarder");
        const paths = ServeRules.parseConfig(fixture("serve-path.json"));
        assertEqual(ServeRules.removePlan(paths, paths.entries[0].key).kind, "run", "a path entry can be removed (nothing is read)");
        assertEqual(ServeRules.removePlan(funnel, "https:1:/").kind, "refused", "an entry that is gone");
        // Funnel on / off sends the entry again
        same(ServeRules.funnelPlan(funnel, funnel.entries[0].key, false, serveStatus, prefs).argv,
             ["tailscale", "serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:3000"], "Funnel off: the handler again with serve");
        same(ServeRules.funnelPlan(funnel, funnel.entries[1].key, true, serveStatus, prefs).argv,
             ["tailscale", "funnel", "--bg", "--yes", "--https=8443", "text:hello"], "Funnel on for a text");
        assertEqual(ServeRules.funnelPlan(funnel, funnel.entries[0].key, true, serveStatus, prefs).kind, "nothing", "already on");
        assertEqual(ServeRules.funnelPlan(paths, paths.entries[0].key, true, serveStatus, prefs).error, "Change this one in a terminal", "a path is never sent again");
        same(ServeRules.resetPlan().argv, ["tailscale", "serve", "reset"], "stop all");
        // Planned against what is there now, for the profile clicked in
        assertEqual(ServeRules.planIntent({ action: "remove", key: "x" }, funnel, serveStatus, prefs, "a|b|c", "d|e|f").kind, "changed", "another profile: changed meanwhile");
        assertEqual(ServeRules.planIntent({ action: "funnel", key: funnel.entries[0].key, on: true }, ServeRules.parseConfig("{}"), serveStatus, prefs, "", "").error,
                    "Not shared any more", "removed meanwhile: nothing sent");
        same(ServeRules.mountFor("/a/b/"), { ok: true, mount: "/a/b/", error: "" }, "a mount ending in /");
    }

    function certificates() {
        assertEqual(CertRules.domainFor(serveStatus), "self.example-tailnet.ts.net", "this computer's own name from CertDomains");
        same(CertRules.domains({ certDomains: ["-x.ts.net", "a/b.ts.net", "ok.example-tailnet.ts.net", "nodot"] }), ["ok.example-tailnet.ts.net"], "unsafe names dropped");
        assertEqual(CertRules.domainFor({ certDomains: ["other.example-tailnet.ts.net"], self: { dnsName: "self.example-tailnet.ts.net" } }), "", "only its own name");
        assertEqual(CertRules.problem(plainStatus, true, "/d"), "HTTPS certificates are off for this tailnet", "no CertDomains");
        assertEqual(CertRules.problem(serveStatus, false, "/d"), "Needs the operator", "not the operator");
        assertEqual(CertRules.problem(serveStatus, true, "/d"), "", "the operator: offered");
        assertEqual(CertRules.certDir("", "/home/user1"), "/home/user1/.local/share/h2s-shell/tailscale/certs", "the default folder");
        assertEqual(CertRules.certDir("relative", ""), "", "no absolute data home: none");
        const argv = CertRules.argv("/d", "self.example-tailnet.ts.net", "/bin/timeout", 180, "/bin/tailscale");
        same(argv.slice(3), ["sh", "/d", "self.example-tailnet.ts.net", "/bin/timeout", "180", "/bin/tailscale"], "the script's arguments");
        same(CertRules.argv("/d", "self.example-tailnet.ts.net", "", 180, "tailscale"), [], "tailscale not by absolute path: nothing");
        assertEqual(CertRules.expiry("notAfter=Feb 14 12:00:00 2027 GMT\n"), Date.UTC(2027, 1, 14, 12, 0, 0), "openssl's end date");
        assertEqual(CertRules.expiry("garbage"), 0, "no date");
    }

    function lock() {
        const off = LockRules.parse(fixture("lock-disabled.json"));
        same([off.ok, off.enabled, off.lockedOut, LockRules.summary(off)], [true, false, false, "Off"], "lock off");
        assert(off.publicKey.startsWith("tlpub:") && off.nodeKey.startsWith("nodekey:"), "keys read");
        const signed = LockRules.parse(fixture("lock-signed.json"));
        same([signed.enabled, signed.signed, signed.trustedKeys, signed.lockedOut, LockRules.attention(signed)], [true, true, 2, false, null], "signed");
        const out = LockRules.parse(fixture("lock-locked-out.json"));
        same([out.lockedOut, out.trustedKeys, out.filteredPeers, LockRules.summary(out)], [true, 3, 1, "Locked out"], "locked out");
        assertEqual(LockRules.attention(out).kind, "locked-out", "locked out: attention");
        same(LockRules.parse("Tailnet lock is NOT enabled.").ok, false, "the text form: not ok");
        same(LockRules.parse({ Enabled: true, NodeKeySigned: false, PublicKey: "tlpub:-x", NodeKey: "nodekey:00" }).lockedOut, false, "a malformed key: not called locked out");
    }

    function networkExit() {
        const exitStatus = TailscaleRules.parseStatus(fixture("status-rich.json"));
        const nodes = TailscaleRules.exitNodes(exitStatus, prefs, "");
        const online = nodes.own.concat(...nodes.countries.map(country => [].concat(...country.cities.map(city => city.nodes)))).find(option => option.online);
        const table = { "cafe-uuid": { choice: online.id, label: online.name }, "home-uuid": { choice: "none" }, "bad id!": { choice: "none" } };
        const networks = [{ id: "cafe-uuid", name: "Café", kind: "wifi", active: true }, { id: "home-uuid", name: "Home", kind: "ethernet", active: false }];
        same(NetworkExitRules.rows(table).map(row => row.id), ["cafe-uuid", "home-uuid"], "bad ids dropped");
        const decide = extra => NetworkExitRules.decide(Object.assign({ table: table, networks: networks, lastKey: "", prefs: prefs, exitNodes: nodes, canChange: true, useProblem: "" }, extra));
        same([decide({}).kind, decide({}).name, decide({}).args.node], ["run", "exitNode", online.argument], "café up: its exit node");
        assertEqual(decide({ prefs: null }).kind, "wait", "prefs not read: wait");
        assertEqual(decide({ lastKey: "cafe-uuid" }).kind, "same", "the same networks again: left alone (a manual choice stays)");
        assertEqual(decide({ canChange: false }).kind, "needs-operator", "not the operator: nothing run");
        assertEqual(decide({ useProblem: "offering" }).kind, "refused", "offering an exit node: refused");
        assertEqual(decide({ networks: [networks[0], Object.assign({}, networks[1], { active: true })] }).kind, "conflict", "two networks disagree");
        const home = decide({ networks: [Object.assign({}, networks[0], { active: false }), Object.assign({}, networks[1], { active: true })] });
        same([home.kind, home.key], ["already", "home-uuid"], "home up, no exit node in use: already");
        const homeUsing = decide({ networks: [networks[1]].map(network => Object.assign({}, network, { active: true })), prefs: Object.assign({}, prefs, { exitNodeId: "nX" }) });
        same([homeUsing.kind, homeUsing.name], ["run", "exitNodeNone"], "home up with an exit node in use: cleared");
        assertEqual(decide({ networks: [], lastKey: "cafe-uuid" }).kind, "none-marked", "no marked network up");
        assertEqual(decide({ table: { "cafe-uuid": { choice: "nGONE" } } }).kind, "unavailable", "a node that is gone");
        assertEqual(decide({ table: { "cafe-uuid": { choice: "auto" } } }).name, "exitNodeAuto", "automatic");
        same(Object.keys(NetworkExitRules.withRow(table, "home-uuid", null)), ["cafe-uuid"], "removed");
        same(Object.keys(NetworkExitRules.withRow({}, "__proto__", "none")), [], "a prototype name is not a network");
    }
}
