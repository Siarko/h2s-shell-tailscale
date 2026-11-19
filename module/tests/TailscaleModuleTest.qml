import QtQuick
import Quickshell
import qs.api
import qs.tests
import ".."

// The module as the shell's host loaded it (tests/run-modules.sh, module test mode): its main
// made the live client and the VPN provider; its programs are the stand-ins of its manifest's
// testPrograms (never a real tailscale), handed over by the shell; the facts are declared and
// pushed; the slot contributions are the manifest's. Then the lifetime rule: the
// module turned off (ModuleTestKit), its client stops (stream and timers) and its provider
// leaves; on again, a new main.
TestCase {
    id: suite
    suiteName: "tailscale: the module in the shell's host"
    asynchronous: true

    readonly property var module: Api.moduleAt(Qt.resolvedUrl("."))
    property var _steps: []
    property var _firstClient: null
    property CommandAction _shell: CommandAction {}
    property var _envReads: null

    function _then(description, condition, action) {
        _steps.push({ description: description, condition: condition, action: action });
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
            if (!ready && waited < 15000)
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

    function runAsync() {
        assert(module !== null && module.active, "the module is loaded and active");
        assertEqual(module.status?.state, "loaded", "… state loaded");
        assertEqual(JSON.stringify(module.status?.warnings ?? null), "[]", "… no warning (imports: qs.api, qs.components, Quickshell)");
        assertEqual(module.manifest.api, "1.13", "written for module API 1.13 (programs, test mode, running as administrator, the system's facts)");
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
        const slots = (module.manifest.slots ?? []).map(entry => entry.slot).sort().join(",");
        assertEqual(slots, "network.vpn.card,network.vpn.row", "the row's and the card's VPN slots in its manifest — no network.vpn.page: its page is a settings page");
        assertEqual((module.manifest.settingsPages ?? []).map(page => page.id + ":" + page.parent).join(","), "tailscale:network",
                    "its page: the settings page \"tailscale\" under Network");
        assert(Api.slots.some(slot => slot.name === "network.vpn.row"), "… offered by the shell");
        assertEqual(module.value("openLoginInBrowser"), true, "its setting: open the login in the browser (default on)");

        _then("the main's client is there", () => Tailscale.client !== null && Tailscale.client.cli !== "unknown", () => {
            const client = Tailscale.client;
            _firstClient = client;
            const standIns = module.directory + "/tests/stand-in";
            assertEqual(client.tailscalePath, standIns + "/tailscale", "the client runs tailscale by the path module.programs gives: the stand-in");
            same([client.timeoutPath, client.curlPath, client.systemctlPath, client.opensslPath],
                 [standIns + "/timeout", standIns + "/curl", standIns + "/systemctl", standIns + "/openssl"], "… and so timeout, curl, systemctl, openssl");
            assertEqual(client.elevationProblem, "", "… changes as administrator offered (its pkexec: the stand-in)");
            assert(client.running, "the client runs while the module is active");
        });
        _then("the client read the stand-in's state", () => Tailscale.client?.status !== null && Tailscale.client?.entry.state === "activated", () => {
            assertEqual(module.facts["tailscale.connected"], true, "fact tailscale.connected pushed");
            assertEqual(module.facts["tailscale.exitNodeInUse"], false, "fact tailscale.exitNodeInUse: false (a neutral value, never a name)");
            assertEqual(module.facts["tailscale.exitNode"], undefined, "… no fact with the exit node's name");
            assert(module.setFact("connected", "yes") !== "", "… a fact checked against its declared type");
            assert(Tailscale.client.streamStarts >= 1, "the main's client streams the bus");
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
            // The environment variables it once read for its stand-ins and folders: gone
            _shell.run(["sh", "-c", "grep -rlE 'H2S_TEST_MODULES|H2S_TAILSCALE_' --include='*.qml' --exclude-dir=tests -- \"$1\"; echo end", "sh", module.directory],
                       result => suite._envReads = result.lines);
        });
        _then("no environment reads", () => suite._envReads !== null, () => {
            same(suite._envReads, ["end"], "no QML file of the module reads H2S_TEST_MODULES or H2S_TAILSCALE_* any more");
            // Off: as `modules setEnabled` does
            assert(ModuleTestKit.setEnabled("tailscale", false), "turned off");
        });
        _then("off", () => !module.active, () => {
            assertEqual(Tailscale.client, null, "off: the main is gone, and the client's reference with it");
            let stillRunning = false;
            try {
                stillRunning = _firstClient?.running === true;
            } catch (error) {}
            assert(!stillRunning, "off: the old client no longer runs (destroyed with the main)");
            assert(module.setFact("connected", true) !== "", "off: no fact can be set");
            ModuleTestKit.setEnabled("tailscale", true);
        });
        _then("on again", () => module.active && Tailscale.client !== null && Tailscale.client !== _firstClient, () => {
            assert(Tailscale.client.running, "on again: a new client, running");
        });
        _clock.start();
    }
}
