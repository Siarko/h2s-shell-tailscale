import QtQuick
import qs.tests
import ".."

// TailscaleRules for delivery step 2: accounts (the list, the account in use, the tailnet's
// name without an e-mail address), this device (hostname and nickname rules, the key's state,
// renewing it before it expires), and diagnostics (netcheck, the relay map, DNS status,
// version, ping, health, the copied report) — on redacted fixtures from tailscale 1.104.4 and
// on input from older or newer daemons (fields missing, of the wrong type).
TestCase {
    id: suite
    suiteName: "tailscale: accounts, this device, diagnostics"

    readonly property var rules: TailscaleRules
    readonly property real now: Date.UTC(2026, 10, 15, 12, 0, 0)
    readonly property real day: 86400000

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
        accounts();
        thisDevice();
        keyExpiry();
        names();
        commands();
        diagnostics();
    }

    function accounts() {
        const list = rules.parseSwitchList(fixture("switch-list.json"));
        const rows = rules.accountRows(list);
        same(rows.map(row => [row.id, row.title, row.subtitle, row.selected, row.removable]), [
            ["a1b2", "example-tailnet.ts.net", "user1@example.com", true, false],
            ["c3d4", "work", "user1@example.org · example.org", false, true]
        ], "accounts: titled by nickname, else tailnet; the e-mail address in the subtitle; the one in use not removable");
        same(rules.accountRows([{ id: "p1", tailnet: "me@example.com", account: "me@example.com", selected: false }]).map(row => row.title + "|" + row.subtitle),
             ["me@example.com|"], "accounts: a personal tailnet (named by the e-mail address): the address once, as the title");
        same(rules.accountRows([null, { id: "-x" }, { id: 4 }, "a"]), [], "accounts: rows that are not accounts dropped");
        same(rules.accountRows(undefined), [], "accounts: nothing → none");

        const switched = rules.accountsAfter(list, { switched: "c3d4" });
        same(switched.map(account => account.id + account.selected), ["a1b2false", "c3d4true"], "after a switch: the list marks the new one");
        same(rules.accountsAfter(list, { switched: "zz99" }).map(account => account.selected), [true, false], "after a switch to an unknown id: unchanged");
        same(rules.accountsAfter(list, { removed: "c3d4" }).map(account => account.id), ["a1b2"], "after a removal: gone");
        same(rules.accountsAfter(list, { removed: "a1b2" }).map(account => account.id), ["a1b2", "c3d4"], "the account in use is never dropped from the list");
        assert(list[0].selected === true, "accountsAfter does not change the list it was given");

        const status = rules.parseStatus(fixture("status-running.json"));
        const prefs = rules.parsePrefs(fixture("prefs-running.json"));
        const current = rules.currentAccount(status, prefs);
        same([current.loginName, current.tailnet], ["user1@example.com", "example-tailnet.ts.net"], "the account in use: login from prefs, the tailnet by its MagicDNS suffix");
        assertEqual(rules.currentAccount(status, null).loginName, "user1@example.com", "… from status's users when prefs are not read");
        assertEqual(rules.currentAccount(null, null).loginName, "", "… nothing read: empty");
        assert(rules.accountsCurrent(list, "user1@example.com"), "the list matches the account in use");
        assert(!rules.accountsCurrent(list, "user2@example.net"), "… not once another account is in use");
        assert(rules.accountsCurrent(list, ""), "… unknown: not called outdated");
        assert(rules.accountsCurrent(null, "x@example.com"), "… no list: nothing to say");
    }

    function names() {
        const running = rules.parseStatus(fixture("status-running.json"));
        const work = rules.parseStatus(fixture("status-running-work.json"));
        assertEqual(rules.tailnetName(running, {}), "example-tailnet.ts.net", "tailnet: a personal one (named by an e-mail address) by its MagicDNS suffix");
        assertEqual(rules.tailnetName(work, {}), "example.org", "tailnet: an organisation's by its name");
        assertEqual(rules.tailnetName(null, { lastTailnet: "example.org" }), "example.org", "tailnet: not read: the one remembered");
        assertEqual(rules.tailnetName(null, { lastTailnet: "me@example.com" }), "", "tailnet: never an e-mail address remembered");
        const bare = rules.parseStatus('{"BackendState":"Running","CurrentTailnet":{"Name":"me@example.com"}}');
        assertEqual(rules.tailnetName(bare, {}), "", "tailnet: an e-mail address and no suffix (an older daemon): nothing rather than the address");
        assertEqual(rules.entry(work, null, { now: now }).name, "Tailscale · example.org", "the entry: an organisation's tailnet named");
        assertEqual(rules.entry(running, null, { now: now }).name, "Tailscale", "the entry: still never the e-mail address");
    }

    function thisDevice() {
        const status = rules.parseStatus(fixture("status-running.json"));
        const prefs = rules.parsePrefs(fixture("prefs-running.json"));
        const device = rules.thisDevice(status, prefs, now);
        same([device.hostName, device.customHostname, device.dnsName, device.ipv4, device.ipv6, device.online, device.relay],
             ["self", "", "self.example-tailnet.ts.net", "100.64.0.1", "fd7a:115c:a1e0::1", true, "zzz"], "this device: name, addresses, MagicDNS name, online, home relay");
        assertEqual(device.key.state, "valid", "… its key valid (2027)");
        const renamed = rules.parsePrefs(fixture("prefs-running.json").replace('"Hostname": ""', '"Hostname": "box"'));
        assertEqual(rules.thisDevice(status, renamed, now).customHostname, "box", "… a --hostname set here");
        assertEqual(rules.thisDevice(null, prefs, now), null, "… status not read: null");
        assertEqual(rules.thisDevice(rules.parseStatus('{"BackendState":"Running"}'), null, now), null, "… no Self (an odd daemon): null");
        const noAddresses = rules.thisDevice(rules.parseStatus('{"Self":{"HostName":"h","TailscaleIPs":["100.64.0.9"]}}'), null, now);
        same([noAddresses.ipv4, noAddresses.ipv6, noAddresses.key.state], ["100.64.0.9", "", "disabled"], "… addresses from Self when the top level has none; no KeyExpiry: expiry off");

        for (const good of ["", "box", "my-box2", "a", "A1", "x".repeat(63)])
            assertEqual(rules.hostnameProblem(good), "", "hostname: " + JSON.stringify(good) + " is fine");
        const bad = { "x": "x".repeat(64), "a.b": "a.b", "my_box": "my_box", "my box": "my box", "-box": "-box", "box-": "box-", "café": "café" };
        for (const key of Object.keys(bad))
            assert(rules.hostnameProblem(bad[key]) !== "", "hostname: " + JSON.stringify(key) + " refused: " + rules.hostnameProblem(bad[key]));
        assert(/dots/.test(rules.hostnameProblem("a.b")), "hostname: a dot — says Tailscale uses the first label");
        assert(/"_"/.test(rules.hostnameProblem("my_box")), "hostname: names the character not allowed");
        assert(rules.hostnameProblem(null) !== "" && rules.hostnameProblem(5) !== "", "hostname: not text → refused");
        assert(rules.validHostname("box") && !rules.validHostname("a.b"), "validHostname follows hostnameProblem");

        for (const good of ["", "home", "Work laptop", "ü".repeat(64)])
            assertEqual(rules.nicknameProblem(good), "", "nickname: " + JSON.stringify(good).slice(0, 20) + " is fine");
        for (const badName of ["x".repeat(65), "a\nb", "-flag", null])
            assert(rules.nicknameProblem(badName) !== "", "nickname: " + JSON.stringify(badName).slice(0, 20) + " refused");
    }

    function keyExpiry() {
        const self = expiry => ({ keyExpiry: expiry, expired: false });
        assertEqual(rules.keyState(null, now).state, "unknown", "key: no self → unknown");
        assertEqual(rules.keyState(self(now + day), 0).state, "unknown", "key: no clock → unknown");
        assertEqual(rules.keyState(self(0), now).state, "disabled", "key: no expiry → disabled");
        same(rules.keyState(self(now - 1), now), { state: "expired", days: 0, text: "expired" }, "key: past → expired");
        assertEqual(rules.keyState({ keyExpiry: now + 30 * day, expired: true }, now).state, "expired", "key: control says expired → expired");
        same(rules.keyState(self(now + 7 * day), now), { state: "soon", days: 7, text: "expires in 7 days" }, "key: exactly 7 days → soon (renew now)");
        assertEqual(rules.keyState(self(now + 7 * day + 1), now).state, "warning", "key: 7 days and a moment (day 8) → only a warning");
        assertEqual(rules.keyState(self(now + 14 * day), now).state, "warning", "key: 14 days → warning");
        assertEqual(rules.keyState(self(now + 14 * day + 1), now).state, "valid", "key: past 14 days → valid");
        same(rules.keyState(self(now + day / 2), now), { state: "soon", days: 1, text: "expires within a day" }, "key: half a day → soon, within a day");
        assertEqual(rules.keyState(self(now + day), now).text, "expires in 1 day", "key: one day, singular");
        assertEqual(rules.reauthSoonDays, 7, "\"about to expire\" is 7 days");

        // The entry: a key about to expire is a warning and a status line, never attention —
        // nothing renews it without harm (a bare `login` drops the connection, and with the
        // same account resets this device's settings)
        const expiring = rules.parseStatus(fixture("status-key-expiring.json"));
        const prefs = rules.parsePrefs(fixture("prefs-running.json"));
        const view = rules.stateOf(expiring, prefs, { now: now });
        same([view.phase, view.attention, view.status], ["running", null, "Tailnet only · key expires in 3 days"], "key in 3 days, connected: no attention, the status line says it");
        assert(view.warnings.some(warning => warning.kind === "key-expiring" && /admin console/.test(warning.text)), "… a warning naming the admin console: " + view.warnings.map(warning => warning.text).join(" | "));
        assertEqual(rules.entry(expiring, prefs, { now: now }).attention, null, "… no attention on the entry the shell shows");
        const stopped = Object.assign({}, expiring, { backendState: "Stopped" });
        const stoppedView = rules.stateOf(stopped, prefs, { now: now });
        same([stoppedView.attention, stoppedView.status], [null, "Off"], "off: no attention, the status line just \"Off\"");
        assert(stoppedView.warnings.some(warning => warning.kind === "key-expiring"), "… the warning");
        const later = rules.stateOf(expiring, prefs, { now: Date.UTC(2026, 10, 7, 12, 0, 0) });
        same([later.attention, later.status], [null, "Tailnet only"], "key in 11 days: a warning only, the status line plain");
        assert(later.warnings.some(warning => warning.kind === "key-expiring"), "… the warning");
        const expired = rules.stateOf(rules.parseStatus(fixture("status-key-expired.json")), prefs, { now: now });
        assertEqual(expired.attention?.kind, "key-expired", "expired: step 1's attention (log in)");
        assertEqual(rules.planAttend(view, false, "user").kind, "nothing", "nothing to attend for a key about to expire");
        assert(!rules.commandNames.includes("reauth") && !rules.commandFor("reauth", {}).ok, "no `reauth` command");
    }

    function commands() {
        same(rules.commandFor("hostname", { name: "box" }).argv, ["tailscale", "set", "--hostname=box"], "hostname: a set");
        same(rules.commandFor("hostname", { name: "" }).argv, ["tailscale", "set", "--hostname="], "hostname: empty = the system's");
        const refused = rules.commandFor("hostname", { name: "a.b" });
        assert(!refused.ok && /dots/.test(refused.error), "hostname: refused with the rule's sentence");
        same(rules.commandFor("nickname", { name: "home" }).argv, ["tailscale", "set", "--nickname=home"], "nickname: a set");
        assert(rules.commandFor("nickname", { name: "home" }).description.indexOf("home") < 0, "nickname: not in the description (notifications)");
        assert(!rules.commandFor("nickname", { name: "-x" }).ok, "nickname: a flag refused");
        same(rules.commandFor("switchAccount", { id: "c3d4" }).argv, ["tailscale", "switch", "c3d4"], "switch: by id");
        same(rules.commandFor("removeAccount", { id: "c3d4" }).argv, ["tailscale", "switch", "remove", "c3d4"], "remove: switch remove <id> (in 1.104's help)");
        same(rules.commandFor("addAccount", {}).argv, ["tailscale", "login"], "add: a bare login");
        same(rules.commandFor("ping", { target: "100.64.0.11" }).argv, ["tailscale", "ping", "--c=1", "--timeout=3s", "100.64.0.11"], "ping: one, 3 s");
        assert(rules.commandFor("ping", { target: "100.64.0.11" }).description.indexOf("100.64") < 0, "ping: no address in the description");
        same(rules.commandFor("netcheck", {}).argv, ["tailscale", "netcheck", "--format=json"], "netcheck");
        same(rules.commandFor("dnsStatus", {}).argv, ["tailscale", "dns", "status", "--json"], "dns status --json");
        same(rules.commandFor("version", {}).argv, ["tailscale", "version", "--json"], "version --json");
        same(rules.commandFor("derpMap", {}).argv, ["tailscale", "debug", "derp-map"], "debug derp-map");
        for (const name of ["netcheck", "dnsStatus", "version", "derpMap", "ping"])
            assert(!rules.commandFor(name, { target: "100.64.0.1" }).changes && !rules.commandFor(name, { target: "100.64.0.1" }).privileged, name + ": a read any user may do");
        assertEqual(rules.timeLimits.diagnose, 30, "netcheck's time limit: 30 s");
    }

    function diagnostics() {
        const real = rules.parseNetcheck(fixture("netcheck-real.json"));
        same([real.ok, real.udp, real.ipv4, real.ipv6, real.osHasIpv6, real.mappingVariesByDestIp, real.portMapping, real.captivePortal, real.preferredDerp],
             [true, true, true, false, true, false, [], false, 14], "netcheck (1.104's shape: a comment line, then JSON)");
        same(real.regions[0], { id: 14, ms: 25.4 }, "… fastest region first, in ms");
        const old = rules.parseNetcheck(fixture("netcheck.json"));
        same([old.ok, old.preferredDerp, old.captivePortal], [true, 4, null], "netcheck: the older synthetic shape (CaptivePortal null: unknown)");
        same(rules.parseNetcheck('{"UDP":true,"UPnP":true,"PCP":true}').portMapping, ["UPnP", "PCP"], "netcheck: port mapping services found");
        assertEqual(rules.parseNetcheck("# Warning only").ok, false, "netcheck: no JSON → not ok");
        assertEqual(rules.parseNetcheck("2026/11/16 log line\n{\"UDP\":false}").ok, true, "netcheck: a log line before the JSON");

        const derp = rules.parseDerpMap(fixture("derp-map.json"));
        same(derp["14"], { code: "ams", name: "Amsterdam" }, "derp map: region 14");
        same(rules.parseDerpMap('{"Regions":{"x":{},"5":null,"6":{"RegionCode":7}}}'), { "6": { code: "", name: "" } }, "derp map: odd regions skipped or emptied");
        same(rules.parseDerpMap("nope"), {}, "derp map: not JSON → empty");

        const summary = rules.netcheckSummary(real, derp);
        assert(summary.ok, "netcheck summary");
        const row = label => summary.rows.find(item => item.label === label)?.value;
        assertEqual(row("Nearest relay"), "Amsterdam (ams), 25.4 ms", "… the nearest relay by name, with its latency");
        assertEqual(row("UDP"), "yes", "… UDP");
        assertEqual(row("IPv6"), "no (the network lacks it)", "… IPv6: the system has it, the network does not");
        assertEqual(row("Port mapping"), "none", "… no port mapping");
        assert(/Frankfurt \(fra\) 30 ms/.test(row("Next relays")), "… the next relays: " + row("Next relays"));
        assert(JSON.stringify(summary).indexOf("198.51.100") < 0, "… never the public address");
        assertEqual(rules.netcheckSummary(real, null).rows.find(item => item.label === "Nearest relay").value, "region 14, 25.4 ms", "… no relay map: the region's number");
        assertEqual(rules.netcheckSummary(rules.parseNetcheck('{"UDP":false,"MappingVariesByDestIP":true,"CaptivePortal":true}'), derp).rows.map(item => item.value).join("|").indexOf("hard — direct connections less likely") >= 0, true, "… a hard NAT said");
        assert(rules.netcheckSummary(rules.parseNetcheck('{"CaptivePortal":true}'), {}).rows.some(item => item.label === "Captive portal"), "… a captive portal said");
        assertEqual(rules.netcheckSummary(null, derp).ok, false, "… nothing → not ok");

        const dns = rules.parseDnsStatus(fixture("dns-status.json"));
        same([dns.ok, dns.tailscaleDns, dns.magicDns, dns.suffix, dns.selfDnsName, dns.resolvers, dns.searchDomains],
             [true, true, true, "example-tailnet.ts.net", "self.example-tailnet.ts.net", [], ["example-tailnet.ts.net"]], "dns status (1.104's shape)");
        same(dns.splitRoutes.map(route => route.domain + "→" + route.resolvers.join(",")), ["example.com→192.168.1.53", "ts.net→192.0.2.53,2620:111:8007::53"], "… split DNS, sorted");
        same(rules.parseDnsStatus('{"Resolvers":[{"Addr":"192.0.2.1"},"192.0.2.2",{},5]}').resolvers, ["192.0.2.1", "192.0.2.2"], "dns: resolvers as objects or text");
        const older = rules.parseDnsStatus('{"TailscaleDNS":false}');
        same([older.ok, older.magicDns, older.splitRoutes, older.searchDomains], [true, false, [], []], "dns: an older daemon's few fields");
        assertEqual(rules.parseDnsStatus("[]").ok, false, "dns: not an object → not ok");
        const dnsRows = rules.dnsSummary(dns);
        same(dnsRows.map(item => item.label), ["Tailscale DNS", "MagicDNS", "Resolvers", "Split DNS", "Search domains"], "dns summary rows");
        assertEqual(dnsRows[1].value, "on — example-tailnet.ts.net", "… MagicDNS on, its suffix");
        same(rules.dnsSummary(null), [], "dns summary: nothing → none");

        same(rules.parseVersion(fixture("version.json")), { ok: true, short: "1.104.4", long: "1.104.4" }, "version --json");
        assertEqual(rules.parseVersion("1.104.4").ok, false, "version: plain text → not ok");

        assertEqual(rules.pingSummary(rules.parsePing(fixture("ping-direct.txt"))).text, "direct, 4 ms", "ping: direct, the last reply's time");
        assertEqual(rules.pingSummary(rules.parsePing("pong from laptop (100.64.0.11) via DERP(fra) in 31ms\n")).text, "relayed (DERP fra), 31 ms", "ping: relayed");
        assertEqual(rules.pingSummary(rules.parsePing(fixture("ping-peer-relay.txt"))).text, "via a peer relay, 11 ms", "ping: a peer relay");
        same(rules.pingSummary(rules.parsePing(fixture("ping-timeout.txt"))), { ok: false, text: "no reply" }, "ping: timed out");
        same(rules.pingSummary(null), { ok: false, text: "no reply" }, "ping: nothing");

        const status = rules.parseStatus(fixture("status-health-warnings.json"));
        same(rules.healthList(null, status).map(warning => warning.text.slice(0, 20)), ["Tailscale could not ", "Unable to connect to"], "health: status's lines while the bus sent none");
        const bus = rules.notifyDigest(fixture("bus-lines.jsonl").split("\n")[1]).health;
        same(rules.healthList(bus, status).map(warning => warning.title), ["Update available"], "health: the bus's, with titles, when it sent some");
        same(rules.healthList([], status), [], "health: the bus says none → none");

        const report = rules.diagnosticsText({
            clientVersion: "1.104.4", daemonVersion: "1.104.4", backendState: "Running", netcheck: summary.rows, dns: dnsRows,
            health: [{ title: "Login", text: "visit https://login.tailscale.com/a/REDACTED or login.tailscale.com/a/X2 with nodekey:abc123 from 100.64.0.5" }], update: ""
        });
        assert(report.indexOf("Client: 1.104.4, daemon: 1.104.4") >= 0, "report: versions");
        assert(report.indexOf("Nearest relay: Amsterdam (ams), 25.4 ms") >= 0, "report: netcheck");
        assert(report.indexOf("MagicDNS: on") >= 0, "report: DNS");
        assert(report.indexOf("https://") < 0 && report.indexOf("<link>") >= 0, "report: no links");
        assert(report.indexOf("nodekey:abc") < 0 && report.indexOf("<key>") >= 0, "report: no keys");
        assert(report.indexOf("login.tailscale.com") < 0, "report: no link without a scheme either");
        assert(report.indexOf("100.64.0.5") < 0, "report: no address in a health text");
        assertEqual(rules.diagnosticsText(null).split("\n")[1], "Client: unknown, daemon: unknown", "report: nothing known");
    }
}
