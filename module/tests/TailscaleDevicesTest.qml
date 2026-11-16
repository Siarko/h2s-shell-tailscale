import QtQuick
import qs.tests
import ".."

// TailscaleRules, what the page and the popup list: the devices (connection kind, owner,
// sharing, last seen; stable order; Mullvad nodes and sharees left out), exit nodes (own and
// grouped by country and city, the current and suggested one), accounts (`switch --list`),
// the warnings (key expiry, a route that covers the LAN, two VPNs), formatting, and the
// address arithmetic behind them.
TestCase {
    id: suite
    suiteName: "tailscale: devices, exit nodes, accounts, warnings"

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
        const rich = rules.parseStatus(fixture("status-rich.json"));
        const richPrefs = rules.parsePrefs(fixture("prefs-rich.json"));
        const running = rules.parseStatus(fixture("status-running.json"));

        // --- peers ---
        {
            const devices = rules.peers(rich, now);
            same(devices.map(device => device.name), ["build", "lab", "laptop", "nas", "phone", "printer", "exit-home", "old-desktop"],
                 "peers: online first, then by name; Mullvad nodes and the sharee left out");
            const byName = name => devices.find(device => device.name === name);
            assertEqual(byName("laptop").connection, "direct", "peers: CurAddr → direct");
            assertEqual(byName("phone").connection, "idle", "peers: online, not active → idle");
            assertEqual(byName("nas").connection, "relayed", "peers: active through DERP → relayed");
            assertEqual(byName("build").connection, "peer-relay", "peers: PeerRelay → peer-relay");
            assertEqual(byName("old-desktop").connection, "offline", "peers: offline");
            assertEqual(byName("laptop").owner, "user1@example.com", "peers: the owner from the User map");
            assertEqual(byName("laptop").ownerName, "Example User 1", "peers: the owner's display name");
            assertEqual(byName("laptop").dnsName, "laptop.example-tailnet.ts.net", "peers: DNS name without the trailing dot");
            assertEqual(byName("laptop").ipv4, "100.64.0.11", "peers: the IPv4 address");
            assertEqual(byName("laptop").rxBytes, 7340032, "peers: traffic");
            assert(byName("laptop").canReceiveFiles && byName("laptop").fileSharingNote === "", "peers: a Taildrop target");
            same(byName("nas").tags, ["tag:server", "tag:nas"], "peers: tags");
            assert(byName("nas").exitNodeOption && !byName("nas").isExitNode, "peers: can be an exit node, is not");
            same(byName("nas").subnetRoutes, ["192.168.1.0/24"], "peers: subnet routes");
            same(byName("lab").subnetRoutes, ["10.20.0.0/16", "fd00:99::/64"], "peers: IPv6 subnet routes too");
            assert(byName("printer").sharedIn && byName("printer").owner === "friend@example.org", "peers: shared in from another tailnet");
            assertEqual(byName("printer").fileSharingNote, "it belongs to another user", "peers: why files cannot go there");
            assert(!byName("laptop").sharedIn, "peers: an own device is not shared in");
            assert(byName("old-desktop").keyExpired, "peers: an expired key");
            assertEqual(byName("old-desktop").lastSeenText, "3 days ago", "peers: last seen, from now");
            assertEqual(byName("exit-home").lastSeenText, "2 h ago", "peers: last seen hours ago");
            assertEqual(byName("laptop").lastSeenText, "online", "peers: online needs no last seen");
            assertEqual(byName("old-desktop").fileSharingNote, "offline", "peers: an offline target");
            assertEqual(rules.peers(rich, now, { includeLocationNodes: true }).length, 14, "peers: Mullvad nodes on request");
            assertEqual(rules.peers(rich, now, { includeSharees: true }).length, 9, "peers: the sharee on request");

            const real = rules.peers(running, now);
            assertEqual(real.length, 9, "peers: the real fixture's nine");
            same(real.slice(0, 2).map(device => device.name), ["peer10", "peer4"], "peers: online first");
            assertEqual(real[0].connection, "relayed", "peers: the real active peer is relayed");
            assertEqual(real[1].connection, "idle", "peers: the real idle peer");
            assertEqual(real.find(device => device.name === "peer2").keyExpired, true, "peers: Expired from control");

            // Stable: the input's order does not matter, equal names fall back to the id
            const reversed = Object.assign({}, rich, { peers: rich.peers.slice().reverse() });
            same(rules.peers(reversed, now).map(device => device.id), devices.map(device => device.id), "peers: the same order whatever the input's");
            const twins = rules.parseStatus({ Peer: { b: { ID: "n2", HostName: "twin", Online: true }, a: { ID: "n1", HostName: "twin", Online: true } } });
            same(rules.peers(twins, now).map(device => device.id), ["n1", "n2"], "peers: equal names ordered by id");

            // 500 peers: all there, sorted, quickly
            const many = { BackendState: "Running", MagicDNSSuffix: "example-tailnet.ts.net", Peer: {} };
            for (let i = 0; i < 500; i++)
                many.Peer["nodekey:" + i] = { ID: "n" + i, HostName: "host" + ((i * 7919) % 500), DNSName: "host" + ((i * 7919) % 500) + ".example-tailnet.ts.net.",
                    Online: i % 3 !== 0, Active: i % 5 === 0, Relay: "fra", TailscaleIPs: ["100.64." + Math.floor(i / 250) + "." + (i % 250 + 1)] };
            const started = Date.now();
            const list = rules.peers(rules.parseStatus(JSON.stringify(many)), now);
            const elapsed = Date.now() - started;
            assertEqual(list.length, 500, "peers: 500 peers");
            let ordered = true;
            for (let i = 1; i < list.length; i++) {
                if (list[i - 1].online === list[i].online && list[i - 1].name.toLowerCase() > list[i].name.toLowerCase())
                    ordered = false;
                if (!list[i - 1].online && list[i].online)
                    ordered = false;
            }
            assert(ordered, "peers: 500 sorted");
            assert(elapsed < 3000, "peers: 500 parsed and listed in " + elapsed + " ms");

            for (const hostile of [null, undefined, {}, { peers: "x" }, { peers: [null, 3, { id: 5 }] }, "status"])
                same(rules.peers(hostile, now), [], "peers: hostile " + JSON.stringify(hostile) + " → none");
            assertEqual(rules.connectionOf(null), "offline", "connectionOf: nothing is offline");
        }

        // --- exit nodes ---
        {
            const choice = rules.exitNodes(rich, richPrefs, "se-sto-wg-021.mullvad.ts.net.");
            same(choice.own.map(option => option.name), ["nas", "exit-home"], "exit nodes: own ones, online first");
            assertEqual(choice.own[1].online, false, "exit nodes: an offline own one is listed, marked");
            same(choice.countries.map(country => country.country), ["Germany", "Sweden", "USA"], "exit nodes: countries by name");
            const sweden = choice.countries[1];
            same(sweden.cities.map(city => city.city), ["Gothenburg", "Stockholm"], "exit nodes: cities by name");
            const stockholm = sweden.cities[1];
            same(stockholm.nodes.map(node => node.name), ["se-sto-wg-021", "se-sto-wg-022"], "exit nodes: by priority within a city");
            assertEqual(stockholm.best.name, "se-sto-wg-021", "exit nodes: a city's best online node");
            assertEqual(choice.countries[0].cities[0].best, null, "exit nodes: no best when all are offline");
            assertEqual(choice.current.id, "nMULL21CNTRL", "exit nodes: the current one");
            assertEqual(choice.current.label, "Stockholm, Sweden", "exit nodes: a location node's label");
            assertEqual(choice.current.argument, "100.64.0.21", "exit nodes: chosen by IPv4 address");
            assertEqual(choice.suggested?.id, "nMULL21CNTRL", "exit nodes: suggested by DNS name");
            assertEqual(rules.exitNodes(rich, richPrefs, "nMULL25CNTRL").suggested?.label, "New York City, USA", "exit nodes: suggested by id");
            assertEqual(rules.exitNodes(rich, richPrefs, "").suggested, null, "exit nodes: no suggestion");
            assertEqual(choice.count, 8, "exit nodes: all eight");

            const real = rules.exitNodes(rules.parseStatus(fixture("status-exit-node.json")), rules.parsePrefs(fixture("prefs-exit-node.json")), null);
            same(real.own.map(option => option.name + (option.current ? "*" : "")), ["peer10", "peer4*"], "exit nodes: the real ones, the current marked");
            same(real.countries, [], "exit nodes: no location nodes in the real fixture");
            assertEqual(rules.exitNodes(running, rules.parsePrefs(fixture("prefs-running.json")), null).current, null, "exit nodes: none in use");
            assertEqual(rules.exitNodeLabel(null), "", "exitNodeLabel: nothing");
            assertEqual(rules.exitNodeLabel(rich.peers.find(peer => peer.hostName === "nas")), "nas", "exitNodeLabel: an own node by name");
            assertEqual(rules.exitNodeArgument(null), "", "exitNodeArgument: nothing");
            for (const hostile of [null, {}, { peers: 5 }])
                assertEqual(rules.exitNodes(hostile, hostile, hostile).count, 0, "exit nodes: hostile " + JSON.stringify(hostile));

            // An exit node chosen by address only (ExitNodeIP), as the CLI may leave it
            const byIp = rules.currentExitNode(running, rules.parsePrefs({ ExitNodeIP: "100.64.0.4" }));
            assert(byIp && byIp.id === "nPEER4CNTRL" && byIp.name === "peer4", "currentExitNode: from ExitNodeIP");

            same(rules.parseExitNodeSuggest(fixture("exit-node-suggest.txt")), { name: "se-sto-wg-021.mullvad.ts.net", none: false }, "suggest: the name");
            same(rules.parseExitNodeSuggest(fixture("exit-node-suggest-none.txt")), { name: "", none: true }, "suggest: none available");
            same(rules.parseExitNodeSuggest(null), { name: "", none: false }, "suggest: nothing");
        }

        // --- accounts ---
        {
            const expected = [
                { id: "a1b2", nickname: "", tailnet: "example-tailnet.ts.net", account: "user1@example.com", selected: true },
                { id: "c3d4", nickname: "work", tailnet: "example.org", account: "user1@example.org", selected: false }
            ];
            same(rules.parseSwitchList(fixture("switch-list.json")), expected, "accounts: --json");
            const table = rules.parseSwitchList(fixture("switch-list.txt"));
            same(table.map(account => [account.id, account.tailnet, account.account, account.selected]),
                 [["a1b2", "example-tailnet.ts.net", "user1@example.com", true], ["c3d4", "example.org", "user1@example.org", false]],
                 "accounts: the table, the current one marked with *");
            same(rules.parseSwitchList(JSON.parse(fixture("switch-list.json"))), expected, "accounts: an already parsed list");
            same(rules.parseSwitchList('[{"id":"a1"},{"id":"a1"},{"id":"bad id"},null,{"id":7},{"id":"b2","selected":"yes"}]').map(account => account.id + account.selected),
                 ["a1false", "b2false"], "accounts: repeated, malformed ids and non-objects skipped");
            for (const hostile of [null, "", "garbage", "[", "{}", 42, "ID  Tailnet  Account\n"])
                same(rules.parseSwitchList(hostile), [], "accounts: " + JSON.stringify(hostile) + " → none");
            same(rules.parseSwitchList("ID  Tailnet  Account\nzz;rm  t  a\n").length, 0, "accounts: an id with odd characters is skipped");
        }

        // --- warnings ---
        {
            const day = 86400000;
            assertEqual(rules.keyExpiryWarning({ keyExpiry: 0 }, now), null, "key: no expiry (disabled) → nothing");
            assertEqual(rules.keyExpiryWarning({ keyExpiry: now + 20 * day }, now), null, "key: 20 days away → nothing yet");
            const fortnight = rules.keyExpiryWarning({ keyExpiry: now + 14 * day }, now);
            assert(fortnight?.kind === "key-expiring" && fortnight.days === 14 && fortnight.text.includes("in 14 days"), "key: 14 days → expiring");
            assert(rules.keyExpiryWarning({ keyExpiry: now + day }, now).text.includes("in 1 day"), "key: one day, singular");
            assert(rules.keyExpiryWarning({ keyExpiry: now + day / 2 }, now).text.includes("within a day"), "key: within a day");
            assertEqual(rules.keyExpiryWarning({ keyExpiry: now - 1 }, now)?.kind, "key-expired", "key: past → expired");
            assertEqual(rules.keyExpiryWarning({ keyExpiry: now + day, expired: true }, now)?.kind, "key-expired", "key: control says expired");
            assertEqual(rules.keyExpiryWarning({ keyExpiry: now + day }, 0), null, "key: no clock → nothing");
            assertEqual(rules.keyExpiryWarning(null, now), null, "key: no self → nothing");
            assertEqual(rules.keyExpiryWarning(rules.parseStatus(fixture("status-key-expiring.json")).self, now)?.days, 3, "key: the fixture, 3 days");

            const shadow = rules.routeShadowsLan(rich, ["192.168.1.0/24"], richPrefs);
            assert(shadow.length === 1 && shadow[0].device === "nas" && shadow[0].route === "192.168.1.0/24", "routes: the nas's route covers the LAN");
            assert(shadow[0].text.includes("192.168.1.0/24"), "routes: said in a sentence");
            assertEqual(rules.routeShadowsLan(rich, ["192.168.1.37/24"], richPrefs).length, 1, "routes: the LAN given with a host address");
            assertEqual(rules.routeShadowsLan(rich, ["192.168.0.0/16"], richPrefs).length, 1, "routes: a LAN containing the route");
            assertEqual(rules.routeShadowsLan(rich, ["10.0.0.0/8"], richPrefs)[0]?.device, "lab", "routes: a route inside the LAN");
            assertEqual(rules.routeShadowsLan(rich, ["fd00:99::/48"], richPrefs)[0]?.route, "fd00:99::/64", "routes: IPv6");
            assertEqual(rules.routeShadowsLan(rich, ["192.168.2.0/24"], richPrefs).length, 0, "routes: a LAN beside the route");
            assertEqual(rules.routeShadowsLan(rich, ["192.168.1.0/24"], rules.parsePrefs({ RouteAll: false })).length, 0, "routes: not accepted → no trap");
            assertEqual(rules.routeShadowsLan(rich, ["0.0.0.0/0", "garbage", null, 5], richPrefs).length, 0, "routes: odd LAN values ignored");
            assertEqual(rules.routeShadowsLan(null, null, null).length, 0, "routes: nothing");
            assertEqual(rules.routeShadowsLan(running, ["192.168.99.0/24"], null)[0]?.device, "peer10", "routes: the real fixture's subnet router");

            assertEqual(rules.twoVpnsNote({ tailscaleUp: true, otherVpns: [] }), "", "two VPNs: alone, nothing");
            assertEqual(rules.twoVpnsNote({ tailscaleUp: false, otherVpns: ["Work"] }), "", "two VPNs: Tailscale down, nothing");
            const both = rules.twoVpnsNote({ tailscaleUp: true, otherVpns: ["Work"], exitNode: "Stockholm, Sweden", acceptDns: true });
            assert(both.includes("Work") && both.includes("Stockholm, Sweden") && both.includes("100.100.100.100"), "two VPNs: routes and DNS");
            const dnsOnly = rules.twoVpnsNote({ tailscaleUp: true, otherVpns: ["Work"], acceptDns: true });
            assert(dnsOnly.includes("DNS") && !dnsOnly.includes("exit node"), "two VPNs: without an exit node only DNS");
            assertEqual(rules.twoVpnsNote({ tailscaleUp: true, otherVpns: ["Work"], acceptDns: false }), "", "two VPNs: nothing shared");
            assertEqual(rules.twoVpnsNote(null), "", "two VPNs: nothing given");
        }

        // --- formatting ---
        {
            assertEqual(rules.bytes(0), "0 B", "bytes: zero");
            assertEqual(rules.bytes(4560796), "4 MB", "bytes: megabytes whole");
            assertEqual(rules.bytes(1610612736), "1.5 GB", "bytes: gigabytes to one decimal");
            assertEqual(rules.bytes("x"), "0 B", "bytes: not a number");
            assertEqual(rules.ago(0, now), "never", "ago: never");
            assertEqual(rules.ago(now - 30000, now), "just now", "ago: just now");
            assertEqual(rules.ago(now - 5 * 60000, now), "5 min ago", "ago: minutes");
            assertEqual(rules.ago(now - 3 * 3600000, now), "3 h ago", "ago: hours");
            assertEqual(rules.ago(now - 30 * 3600000, now), "yesterday", "ago: yesterday");
            assertEqual(rules.ago(now - 90 * 86400000, now), "3 months ago", "ago: months");
            assertEqual(rules.ago(now + 60000, now), "just now", "ago: a moment in the future is now");
        }

        // --- addresses ---
        {
            const cidr = rules.parseCidr("192.168.1.0/24");
            assert(cidr && cidr.family === 4 && cidr.bits === 24 && cidr.canonical, "cidr: an IPv4 network");
            const hostBits = rules.parseCidr("192.168.1.5/24");
            assert(hostBits && !hostBits.canonical && hostBits.network === "192.168.1.0/24", "cidr: host bits → not canonical, the network named");
            assertEqual(rules.parseCidr("fd00:99:0:0::/64")?.network, "fd00:99::/64", "cidr: IPv6 written canonically");
            assertEqual(rules.parseCidr("fd7a:115c:a1e0::1")?.network, "fd7a:115c:a1e0::1/128", "cidr: a bare IPv6 address is a /128");
            assertEqual(rules.parseCidr("::ffff:192.0.2.1/128")?.network, "::ffff:192.0.2.1/128", "cidr: an embedded IPv4, written as Go's netip prints it");
            assertEqual(rules.parseCidr("::/0")?.bits, 0, "cidr: the IPv6 default route");
            assertEqual(rules.parseCidr("2001:db8:0:1:1:1:1:1/64")?.network, "2001:db8:0:1::/64", "cidr: zeros compressed once, the longest run");
            for (const bad of ["300.1.1.1/24", "1.2.3/24", "1.2.3.4/33", "fd00::/129", "1::2::3", "01.2.3.4/8", "1.2.3.4/", "1.2.3.4/x", "fe80::1%eth0",
                               "::1.2.3.4:5", "1.2.3.4.5", "", null, 5, "1:2:3:4:5:6:7:8:9", "a".repeat(80)])
                assertEqual(rules.parseCidr(bad), null, "cidr: " + JSON.stringify(bad) + " refused");
            assert(rules.cidrOverlap(rules.parseCidr("10.0.0.0/8"), rules.parseCidr("10.20.0.0/16")), "overlap: contained");
            assert(!rules.cidrOverlap(rules.parseCidr("10.0.0.0/8"), rules.parseCidr("11.0.0.0/8")), "overlap: beside");
            assert(!rules.cidrOverlap(rules.parseCidr("10.0.0.0/8"), rules.parseCidr("fd00::/8")), "overlap: different families");
            assert(rules.cidrOverlap(rules.parseCidr("fd00:99::/64"), rules.parseCidr("fd00:99::1")), "overlap: IPv6 host in network");
            assert(!rules.cidrOverlap(null, cidr), "overlap: nothing");

            assert(rules.validTarget("peer4") && rules.validTarget("laptop.example-tailnet.ts.net.") && rules.validTarget("100.64.0.4")
                   && rules.validTarget("fd7a:115c:a1e0::4"), "target: names and addresses");
            for (const bad of ["-c", "--exit-node", "a b", "x;y", "", null, "a".repeat(254), "peer:", "ünï", "a..b"])
                assert(!rules.validTarget(bad), "target: " + JSON.stringify(bad) + " refused");
            assert(rules.validUserName("alice") && rules.validUserName("_svc") && rules.validUserName("user-1"), "user name: plain names");
            for (const bad of ["Alice", "root; rm -rf /", "", "a".repeat(33), "$USER", "-x", "a b", "1abc", null, "alice\n"])
                assert(!rules.validUserName(bad), "user name: " + JSON.stringify(bad) + " refused");
            assert(rules.validHostname("box") && rules.validHostname("my-box2") && rules.validHostname(""), "hostname: plain ones, and empty");
            for (const bad of ["-box", "box-", "bad_name", "a.b", "a".repeat(64), null])
                assert(!rules.validHostname(bad), "hostname: " + JSON.stringify(bad) + " refused");
        }
    }
}
