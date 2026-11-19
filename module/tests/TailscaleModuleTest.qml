import QtQuick
import Quickshell
import qs.api
import qs.tests
import ".."
import "liveSuites.js" as LiveSuites

// The module as the shell's host loaded it (tests/run-modules.sh, module test mode): its main
// made the live client and the VPN provider; its programs are the stand-ins of its manifest's
// testPrograms (never a real tailscale), handed over by the shell; a run as administrator goes
// through the shell's own queue and its stand-in pkexec, saying who and what for; the facts are
// declared and pushed; its row and card are the manifest's anchors (no slots). Then the lifetime rule: the
// module turned off (ModuleTestKit), its client stops (stream and timers) and its provider
// leaves; on again, a new main.
TestCase {
    id: suite
    suiteName: "tailscale: the module in the shell's host"
    asynchronous: true
    // It waits for the live suites (below): up to the runner's cap
    Component.onCompleted: {
        if ("timeLimitMs" in suite)
            suite["timeLimitMs"] = 60000;
    }

    readonly property var module: Api.moduleAt(Qt.resolvedUrl("."))
    // The live client, as the module's views reach it (module API 1.15); null while off
    function _client() {
        return module.main?.client ?? null;
    }
    property var _steps: []
    property var _firstClient: null
    property CommandAction _shell: CommandAction {}
    property var _envReads: null
    // The notifications recorded before its own (the records are the whole runner's: the
    // other suites run beside this one, so they are never cleared here)
    property int _notifiedBefore: 0
    function _ownNotices() {
        return (ModuleTestKit.notified ?? []).slice(_notifiedBefore).filter(notice => notice.summary === "Module: Tailscale");
    }

    // timeoutMs: how long the step may wait for its condition (15 s when not given)
    function _then(description, condition, action, timeoutMs) {
        _steps.push({ description: description, condition: condition, action: action, timeoutMs: timeoutMs ?? 15000 });
    }

    property Timer _clock: Timer {
        interval: 40
        repeat: true
        property int waited: 0
        onTriggered: {
            const step = suite._steps[0];
            if (!step) {
                stop();
                suite.finish();
                return;
            }
            waited += interval;
            let ready = false;
            try {
                ready = step.condition();
            } catch (error) {}
            if (!ready && waited < step.timeoutMs)
                return;
            waited = 0;
            suite._steps.shift();
            if (!ready)
                suite.fail("timed out waiting: " + step.description);
            try {
                step.action();
            } catch (error) {
                suite.fail("threw in \"" + step.description + "\": " + error);
            }
        }
    }

    // The first item under `item` (children and a Flickable's content) with that objectName
    function _findNamed(item, name) {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (const child of [item.contentItem].concat(Array.from(item.children ?? []))) {
            const found = child && child !== item ? _findNamed(child, name) : null;
            if (found)
                return found;
        }
        return null;
    }

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }

    // The shell's helpers and facts (module API 1.12–1.16) as the main's client takes them, set
    // through the test kit — only once the live suites are done: the facts are the whole
    // runner's, and the live suites read Api.system's user name
    function _factsSeen() {
        const client = _client();
        // Who runs the shell and the host name: Api.system, no `id`, no /proc read of its own
        assertEqual(ModuleTestKit.setSystem({ userName: "alice", uid: 1234, hostName: "box" }).length, 0, "system facts set");
        same([client.userName, client.uid, client.systemHostname], ["alice", 1234, "box"], "the user, the uid and the host name: Api.system's");
        assertEqual(client.device?.hostName, "box", "… this device named after the system's host name (no name set in Tailscale)");
        ModuleTestKit.setSystem({ userName: "", uid: null, hostName: "" });
        same([client.userName, client.uid, client.systemHostname], ["", -1, ""], "… not known: unknown here too, never a guess");
        ModuleTestKit.setSystem(null);
        assertEqual(client.userName, Api.system.userName, "… back to the test kit's");
        // Its data folder: the shell's module.dataDirectory, the certificates in it
        assert(module.dataDirectory !== "" && client.cert.dir === module.dataDirectory + "/certs",
               "certificates: in the module's data directory (" + client.cert.dir + ")");
        // The local networks: Api.localNetworks (no `ip addr` of its own); the stand-in's tailnet
        // has a subnet router for 192.168.99.0/24, its routes accepted
        assertEqual(ModuleTestKit.setNetworks({ localNetworks: [{ device: "wlan0", kind: "wifi", address: "192.168.99.5/24" },
                                                                { device: "eth0", kind: "ethernet", address: "10.1.2.3/16" }] }).length, 0, "local networks set");
        same(client.lanSubnets, ["192.168.99.0/24", "10.1.0.0/16"], "the local networks: Api.localNetworks'");
        same(client.routeWarnings.map(found => found.lan), ["192.168.99.0/24"], "… an accepted route that covers one: warned");
        ModuleTestKit.setNetworks({ localNetworksReady: false });
        same([client.lanSubnets, client.routeWarnings.length], [[], 0], "… not read: none, no warning");
        // The networks read whole, for the exit node per network: Api.networksReady
        assertEqual(client.networkExit.networksReady, true, "networks read whole (the defaults): networksReady");
        ModuleTestKit.setNetworks({ networksReady: false });
        assertEqual(client.networkExit.networksReady, false, "… not read: the exit node per network waits");
        // Other VPNs up: Api.vpnsUp's rows with what they do with the traffic
        ModuleTestKit.setNetworks({ vpnsUp: [{ name: "Office", type: "wireguard", provider: "", fullTunnel: false, setsDns: false, routes: ["10.20.0.0/16"] }] });
        same(TailscaleRules.fullTunnelVpns(Api.vpnsUp, module.moduleId), [], "another VPN, a split one: no \"another VPN is also on\"");
        ModuleTestKit.setNetworks({ vpnsUp: [{ name: "Work", type: "wireguard", provider: "", fullTunnel: true, setsDns: true, routes: ["0.0.0.0/0"] }] });
        same(TailscaleRules.fullTunnelVpns(Api.vpnsUp, module.moduleId), ["Work"], "… a full tunnel: said");
        // The page's "Another VPN is also on", as the page shows it from Api.vpnsUp: no exit node
        // in use here, so only a VPN whose routes overlap Tailscale's (the accepted subnet route
        // 192.168.99.0/24) shows it; a split one beside it does not
        const pageComponent = Qt.createComponent("file://" + module.directory + "/TailscalePage.qml", Component.PreferSynchronous);
        const page = pageComponent.status === Component.Ready ? pageComponent.createObject(null, { module: module, width: 700 }) : null;
        assert(page !== null, "the page builds (" + pageComponent.errorString() + ")");
        const hint = _findNamed(page, "tailscaleOtherVpnHint");
        assert(hint !== null, "… with its two-VPN hint");
        ModuleTestKit.setNetworks({ vpnsUp: [{ name: "Office", type: "wireguard", provider: "", fullTunnel: false, setsDns: false, routes: ["10.20.0.0/16"] }] });
        same([client.view.exitNode, hint?.visible], [null, false], "the page: no exit node, a split VPN beside the tailnet — no hint");
        ModuleTestKit.setNetworks({ vpnsUp: [{ name: "Lab", type: "wireguard", provider: "", fullTunnel: false, setsDns: false, routes: ["192.168.99.0/25"] }] });
        assertEqual(hint?.visible, true, "… a split VPN whose route overlaps the accepted subnet route — \"Another VPN is also on\"");
        ModuleTestKit.setNetworks({ vpnsUp: [{ name: "Lab", type: "wireguard", provider: "", fullTunnel: false, setsDns: false, routes: ["100.100.0.0/16"] }] });
        assertEqual(hint?.visible, true, "… one that overlaps the tailnet's own range — said too");
        ModuleTestKit.setNetworks({ vpnsUp: [{ name: "Plugin", type: "vpn", provider: "", fullTunnel: null, setsDns: null, routes: null }] });
        assertEqual(hint?.visible, false, "… routes not known and no exit node — not an overlap");
        page?.destroy();
        ModuleTestKit.setNetworks(null);
        // Its own VPN's traffic, reported on the provider's entry (Api.vpnsUp's for it)
        const entry = module.main.provider.entries[0];
        same([entry.fullTunnel, entry.setsDns, entry.routes.slice(0, 2)], [false, true, ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]],
             "its entry: no exit node — not a full tunnel, Tailscale's DNS, its ranges first");
        // The clock: the shell's minute (Api.minuteNow), no clock of its own
        const later = Date.UTC(2030, 0, 2, 3, 4, 30);
        ModuleTestKit.setNow(later);
        assertEqual(client.now, Date.UTC(2030, 0, 2, 3, 4, 0), "the time the state is derived at follows Api.minuteNow");
        ModuleTestKit.setNow(0);
        // Back on the real clock: within the current minute (the shell's minute start, or the
        // last read since), not the 2030 one set above
        const realNow = Date.now();
        assert(client.now <= realNow && client.now > realNow - 61000, "… the real clock again: " + new Date(client.now).toISOString());
    }

    function runAsync() {
        assert(module !== null && module.active, "the module is loaded and active");
        assertEqual(module.status?.state, "loaded", "… state loaded");
        assertEqual(JSON.stringify(module.status?.warnings ?? null), "[]", "… no warning (imports: qs.api, qs.components, Quickshell)");
        assertEqual(module.manifest.api, "1.31", "written for module API 1.31 (the helpers, the system's and the networks' facts, its data directory, the VPN places and the network cards' places as anchors, the public ProgressBar and HoverTip)");
        assert(Api.testMode, "the module test runner: module test mode");
        const deprecations = JSON.stringify(module.status?.deprecations ?? []);
        assert(!/pkexec|PrivilegedAction|elevate|stand-in/i.test(deprecations),
               "… not in the transitional test-mode gate any more (no stand-in pkexec outside testPrograms): " + deprecations);
        // Its row and card through anchors (module API 1.23): no slot among its deprecations;
        // what is left is the shell's internal elements (until the module moves off them)
        assert(!/slots|network\.vpn\.(row|card)/.test(deprecations), "… no slot deprecation: its row and card are anchors: " + deprecations);
        same((module.status?.deprecations ?? []).map(text => text.split(" (")[0]), ["import qs.components"], "… its deprecations: only qs.components");
        same(module.status?.errors ?? [], [], "… no error (its anchors are offered and take its placements)");
        // Its programs: the stand-ins of its testPrograms, handed over by the shell, trusted
        const standIns = module.directory + "/tests/stand-in";
        assertEqual(module.manifest.testPrograms, "tests/stand-in", "its stand-ins: tests/stand-in (testPrograms)");
        assert(module.programsReady, "its programs looked up");
        const programs = module.programs;
        const fromStandIns = ["tailscale", "timeout", "curl", "systemctl", "openssl", "pkexec"]
            .filter(name => programs[name]?.path !== standIns + "/" + name || programs[name]?.trusted !== true || programs[name]?.reason !== "test stand-in");
        assertEqual(fromStandIns.join(","), "", "every program it names is its stand-in (trusted, \"test stand-in\"), never one on PATH");
        assert(module.privileged.available, "… and the shell can run as administrator through the stand-in pkexec (" + module.privileged.unavailableReason + ")");
        same(module.manifest.slots ?? [], [], "no `slots` in its manifest");
        same((module.manifest.anchors ?? []).map(entry => [entry.at, entry.place, entry.component]),
             [["popup.network.connections.vpn.row", "after", "TailscaleRow.qml"], ["settings.network_vpn.vpns.card.settings", "prepend", "TailscaleCard.qml"],
              ["settings.network_wifi.saved.card.settings", "append", "NetworkExitCard.qml"],
              ["settings.network_ethernet.profiles.card.settings", "append", "NetworkExitCard.qml"],
              ["settings.network_wifi.saved.card.title", "append", "NetworkExitMark.qml"],
              ["settings.network_ethernet.profiles.card.title", "append", "NetworkExitMark.qml"]],
             "its row and card as anchors: under its row in the network popup, first in its opened card; the exit node per network in the saved networks' opened cards, its mark on their name lines");
        for (const entry of module.manifest.anchors ?? []) {
            const offered = (Api.anchors ?? []).find(anchor => anchor.path === entry.at);
            const ownProvider = entry.at.startsWith("popup.network.connections.vpn.") || entry.at.startsWith("settings.network_vpn.");
            assert(offered && (offered.scope === "own-provider") === ownProvider && (offered.placements ?? []).includes(entry.place),
                   entry.at + ": offered by the shell" + (ownProvider ? ", own-provider" : "") + ", taking \"" + entry.place + "\"");
        }
        assertEqual((module.manifest.settingsPages ?? []).map(page => page.id + ":" + page.parent).join(","), "tailscale:network",
                    "its page: the settings page \"tailscale\" under Network");
        assertEqual(module.value("openLoginInBrowser"), true, "its setting: open the login in the browser (default on)");

        _then("the main's client is there", () => _client() !== null && _client().cli !== "unknown", () => {
            const client = module.main.client;
            _firstClient = client;
            const standIns = module.directory + "/tests/stand-in";
            assertEqual(client.tailscalePath, standIns + "/tailscale", "the client runs tailscale by the path module.programs gives: the stand-in");
            same([client.timeoutPath, client.curlPath, client.systemctlPath, client.opensslPath],
                 [standIns + "/timeout", standIns + "/curl", standIns + "/systemctl", standIns + "/openssl"], "… and so timeout, curl, systemctl, openssl");
            assertEqual(client.elevationProblem, "", "… changes as administrator offered");
            assert(client.running, "the client runs while the module is active");
        });
        _then("the client read the stand-in's state", () => _client()?.status !== null && _client()?.entry.state === "activated", () => {
            assertEqual(module.facts["tailscale.connected"], true, "fact tailscale.connected pushed");
            assertEqual(module.facts["tailscale.exitNodeInUse"], false, "fact tailscale.exitNodeInUse: false (a neutral value, never a name)");
            assertEqual(module.facts["tailscale.exitNode"], undefined, "… no fact with the exit node's name");
            assert(module.setFact("connected", "yes") !== "", "… a fact checked against its declared type");
            assert(_client().streamStarts >= 1, "the main's client streams the bus");
            // Step 6: its bar widget, offered to the bar (the host's widget entries feed
            // WidgetRegistry, which the bar section editor lists), built as the bar builds it
            const widgetEntry = (ModuleTestKit.widgetEntries ?? []).find(entry => entry.type === "tailscale");
            assertEqual(widgetEntry?.module, "tailscale", "its bar widget \"tailscale\" is among the shell's widget types");
            assert(String(widgetEntry?.widget).startsWith("file://") && String(widgetEntry?.widget).endsWith("/TailscaleWidget.qml"), "… its widget by URL");
            assert(String(widgetEntry?.popupPanel).endsWith("/TailscalePopup.qml") && String(widgetEntry?.settings).endsWith("/TailscaleWidgetSettings.qml"),
                   "… with its popup and its settings pane");
            assertEqual(JSON.stringify(widgetEntry?.presetDefaults), JSON.stringify({ text: "none", badge: true, devices: 5 }), "… and its presets' defaults");
            const widgetComponent = Qt.createComponent(widgetEntry.widget, Component.PreferSynchronous);
            const widget = widgetComponent.status === Component.Ready ? widgetComponent.createObject(null, { module: module }) : null;
            assert(widget !== null, "the widget builds in the shell (" + widgetComponent.errorString() + ")");
            assertEqual(widget?.summary.kind, "connected", "… showing the live client's state: connected");
            if (typeof module.presetValue === "function")
                assertEqual(module.presetValue("tailscale", "", "devices"), 5, "… its preset read through the handle (module API 1.3)");
            widget?.destroy();
            // Its popup panel, row and card, as the shell builds them: each reaches the live
            // client through the handle (module API 1.15: module.main.client)
            const panelComponent = Qt.createComponent(widgetEntry.popupPanel, Component.PreferSynchronous);
            const panel = panelComponent.status === Component.Ready
                ? panelComponent.createObject(null, { module: module, opener: { widgetType: "tailscale", preset: "", edge: "top", byTouch: false } }) : null;
            assert(panel !== null && panel.client === module.main.client, "its popup panel: the main's client (" + panelComponent.errorString() + ")");
            assertEqual(panel?.deviceCap, 5, "… the device cap of the opener's preset: the default");
            panel?.destroy();
            // Its row and card as the shell builds them at their anchors, with the place's
            // context: the main's client, the other VPNs as Api.vpnsUp's rows (otherVpns)
            const work = { name: "Work", type: "wireguard", provider: "", fullTunnel: true, setsDns: true, routes: ["0.0.0.0/0"] };
            for (const entry of (module.manifest.anchors ?? []).filter(item => !item.component.startsWith("NetworkExit"))) {
                const component = Qt.createComponent("file://" + module.directory + "/" + entry.component, Component.PreferSynchronous);
                const context = { anchor: entry.at, placement: entry.place, vpnId: "tailscale:main", entryId: "main", vpn: { name: "Tailscale" },
                                  provider: module.main.provider, otherVpnsUp: ["Work"], otherVpns: [work] };
                const view = component.status === Component.Ready ? component.createObject(null, { module: module, context: context }) : null;
                assert(view !== null && view.client === module.main.client, entry.at + ": the main's client, no provider needed (" + component.errorString() + ")");
                if (entry.component === "TailscaleCard.qml")
                    assert(String(view?._twoVpns).includes("Work"), "… the card's note on two VPNs from the context's otherVpns: " + view?._twoVpns);
                view?.destroy();
                const bare = component.status === Component.Ready ? component.createObject(null, { module: module, context: null }) : null;
                assert(bare !== null, entry.at + ": builds without a context too");
                bare?.destroy();
            }
            // The exit node per network on a saved network's card, as the shell builds it with
            // the card's context: set in the opened card, marked on the name line, cleared
            const networkContext = at => ({ anchor: at, placement: "append", networkId: "cafe-uuid", name: "Café", kind: "wifi", active: false });
            const cardComponent = Qt.createComponent("file://" + module.directory + "/NetworkExitCard.qml", Component.PreferSynchronous);
            const markComponent = Qt.createComponent("file://" + module.directory + "/NetworkExitMark.qml", Component.PreferSynchronous);
            // A parent: an item without one stays hidden once it was hidden
            const holder = Qt.createQmlObject("import QtQuick\nItem {}", suite, "holder");
            const exitCard = cardComponent.createObject(holder, { module: module, context: networkContext("settings.network_wifi.saved.card.settings") });
            const exitMark = markComponent.createObject(holder, { module: module, context: networkContext("settings.network_wifi.saved.card.title") });
            assert(exitCard !== null && exitCard.exit === module.main.client.networkExit && exitMark?.exit === module.main.client.networkExit,
                   "the network card's element and mark: the main's client (" + cardComponent.errorString() + markComponent.errorString() + ")");
            const choice = _findNamed(exitCard, "tailscaleNetworkExitChoice");
            assertEqual(exitMark?.visible, false, "… nothing set for the network: no mark");
            choice?.picked("none");
            same([exitMark?.visible, exitMark?.label, module.main.client.networkExit.rows.map(row => row.id)], [false, "", ["cafe-uuid"]],
                 "… \"No exit node\" set in the card: kept, no mark on the name line");
            choice?.picked("auto");
            same([exitMark?.visible, exitMark?.label], [true, "Exit node: automatic"], "… an exit node set: marked on the name line");
            choice?.picked("");
            same([exitMark?.visible, module.main.client.networkExit.rows.length], [false, 0], "… cleared: the mark gone");
            // Each before its parent: the shell's dropdown, torn down with its parent, reads
            // a parent already gone
            exitCard?.destroy();
            exitMark?.destroy();
            Qt.callLater(() => holder.destroy());
            assert(!("client" in module.main.provider), "the provider carries no client of its own");
        });
        // The shell's queue, its test polkit agent and the module's on/off state are shared with
        // the live suites, which run beside this one through the same handle: another agent
        // and the module turned off would change their runs (liveSuites.js)
        _then("the live suites are done", () => LiveSuites.allDone() && ModuleTestKit.privilegedIdle, () => {
            // A change only root may make, asked by the user: through the shell's queue and
            // its stand-in pkexec. With another polkit agent the shell sends a notification
            // saying who and what for just before pkexec starts — the run's `what`, recorded
            suite._notifiedBefore = (ModuleTestKit.notified ?? []).length;
            ModuleTestKit.setPolkitAgent("other");
            assert(!_client().canChange, "not the operator: a change needs an administrator");
            assert(_client().setShieldsUp(true), "Block incoming connections: starts");
        }, 55000);
        _then("run as administrator through the shell", () => _client().prefs?.shieldsUp === true && !_client().busy && ModuleTestKit.privilegedIdle, () => {
            const notices = suite._ownNotices();
            same(notices.map(notice => notice.body), ["Authorization: Block incoming connections"],
                 "the shell said who and what for: \"Module: Tailscale\", \"Authorization: Block incoming connections\"");
            assertEqual(notices[0]?.format, "plain", "… as plain text");
            assert(!(ModuleTestKit.notified ?? []).slice(suite._notifiedBefore).some(notice => /^(Block|Allow) incoming connections/.test(notice.summary)),
                   "… and nothing failed");
            assert(_client().setShieldsUp(false), "and back: starts");
        });
        _then("back", () => _client().prefs?.shieldsUp === false && !_client().busy && ModuleTestKit.privilegedIdle, () => {
            same(suite._ownNotices().map(notice => notice.body),
                 ["Authorization: Block incoming connections", "Authorization: Allow incoming connections"], "… each run with its own words");
            ModuleTestKit.setPolkitAgent("active");
            // The environment variables it once read for its stand-ins and folders: gone
            _shell.run(["sh", "-c", "grep -rlE 'H2S_TEST_MODULES|H2S_TAILSCALE_' --include='*.qml' --exclude-dir=tests -- \"$1\"; echo end", "sh", module.directory],
                       result => suite._envReads = result.lines);
        });
        _then("no environment reads", () => suite._envReads !== null, () => {
            same(suite._envReads, ["end"], "no QML file of the module reads H2S_TEST_MODULES or H2S_TAILSCALE_* any more");
            suite._factsSeen();
            // Off: as `modules setEnabled` does
            assert(ModuleTestKit.setEnabled("tailscale", false), "turned off");
        });
        _then("off", () => !module.active, () => {
            assertEqual(module.main, null, "off: the main is gone, and the client with it");
            let stillRunning = false;
            try {
                stillRunning = _firstClient?.running === true;
            } catch (error) {}
            assert(!stillRunning, "off: the old client no longer runs (destroyed with the main)");
            assert(module.setFact("connected", true) !== "", "off: no fact can be set");
            ModuleTestKit.setEnabled("tailscale", true);
        });
        _then("on again", () => module.active && _client() !== null && _client() !== _firstClient, () => {
            assert(_client().running, "on again: a new client, running");
        });
        _clock.start();
    }
}
