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
// declared and pushed; the slot contributions are the manifest's. Then the lifetime rule: the
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
        assertEqual(client.cert.oldDir, Api.system.dataHome + "/h2s-shell/tailscale/certs", "… the folder used before, under the system's data home");
        assert(client.cert.moved?.done === true && client.cert.moveLogs === 0, "… nothing there to move at the start: done, nothing logged");
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
        assert(client.now <= Date.now() + 60000, "… the real clock again");
    }

    function runAsync() {
        assert(module !== null && module.active, "the module is loaded and active");
        assertEqual(module.status?.state, "loaded", "… state loaded");
        assertEqual(JSON.stringify(module.status?.warnings ?? null), "[]", "… no warning (imports: qs.api, qs.components, Quickshell)");
        assertEqual(module.manifest.api, "1.23", "written for module API 1.23 (the helpers, the system's and the networks' facts, its data directory, the VPN places as anchors)");
        assert(Api.testMode, "the module test runner: module test mode");
        const deprecations = JSON.stringify(module.status?.deprecations ?? []);
        assert(!/pkexec|PrivilegedAction|elevate|stand-in/i.test(deprecations),
               "… not in the transitional test-mode gate any more (no stand-in pkexec outside testPrograms): " + deprecations);
        // Its programs: the stand-ins of its testPrograms, handed over by the shell, trusted
        const standIns = module.directory + "/tests/stand-in";
        assertEqual(module.manifest.testPrograms, "tests/stand-in", "its stand-ins: tests/stand-in (testPrograms)");
        assert(module.programsReady, "its programs looked up");
        const programs = module.programs;
        const fromStandIns = ["tailscale", "timeout", "curl", "systemctl", "openssl", "pkexec"]
            .filter(name => programs[name]?.path !== standIns + "/" + name || programs[name]?.trusted !== true || programs[name]?.reason !== "test stand-in");
        assertEqual(fromStandIns.join(","), "", "every program it names is its stand-in (trusted, \"test stand-in\"), never one on PATH");
        assert(module.privileged.available, "… and the shell can run as administrator through the stand-in pkexec (" + module.privileged.unavailableReason + ")");
        const slots = (module.manifest.slots ?? []).map(entry => entry.slot).sort().join(",");
        assertEqual(slots, "network.vpn.card,network.vpn.row", "the row's and the card's VPN slots in its manifest — no network.vpn.page: its page is a settings page");
        assertEqual((module.manifest.settingsPages ?? []).map(page => page.id + ":" + page.parent).join(","), "tailscale:network",
                    "its page: the settings page \"tailscale\" under Network");
        assert(Api.slots.some(slot => slot.name === "network.vpn.row"), "… offered by the shell");
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
            for (const entry of module.manifest.slots ?? []) {
                const component = Qt.createComponent("file://" + module.directory + "/" + entry.component, Component.PreferSynchronous);
                const view = component.status === Component.Ready ? component.createObject(null, { module: module, context: null }) : null;
                assert(view !== null && view.client === module.main.client, entry.slot + ": the main's client, no provider needed (" + component.errorString() + ")");
                view?.destroy();
            }
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
