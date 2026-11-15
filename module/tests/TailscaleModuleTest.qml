import QtQuick
import Quickshell
import qs.api
import qs.tests
import ".."

// The module as the shell's host loaded it (tests/run-modules.sh): its main made the live
// client and the VPN provider; under the module test runner the client took the stand-ins
// next to the module (never a real tailscale); the facts are declared and pushed; the slot
// contributions are the manifest's. Then the lifetime rule: the module turned off, its
// client stops (stream and timers) and its provider leaves; on again, a new main.
// (Turning it off goes through the handle's host — the test's only use of something beyond
// qs.api: the API has no setEnabled for a module itself.)
TestCase {
    id: suite
    suiteName: "tailscale: the module in the shell's host"
    asynchronous: true

    readonly property var module: Api.moduleAt(Qt.resolvedUrl("."))
    property var _steps: []
    property var _firstClient: null

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
            if (!ready && waited < 9000)
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

    function runAsync() {
        assert(module !== null && module.active, "the module is loaded and active");
        assertEqual(module.status?.state, "loaded", "… state loaded");
        assertEqual(JSON.stringify(module.status?.warnings ?? null), "[]", "… no warning (imports: qs.api, qs.components, Quickshell)");
        assertEqual(module.manifest.api, "1.2", "written for module API 1.2 (resumed(), shown)");
        const slots = (module.manifest.slots ?? []).map(entry => entry.slot).sort().join(",");
        assertEqual(slots, "network.vpn.card,network.vpn.page,network.vpn.row", "the three VPN slots in its manifest");
        assert(Api.slots.some(slot => slot.name === "network.vpn.row"), "… offered by the shell");
        assertEqual(module.value("openLoginInBrowser"), true, "its setting: open the login in the browser (default on)");

        _then("the main's client is there", () => Tailscale.client !== null && Tailscale.client.cli !== "unknown", () => {
            const client = Tailscale.client;
            _firstClient = client;
            assertEqual(client.toolsMode, "test-stand-ins", "under the module test runner: the stand-ins next to the module");
            assert(client.tailscalePath.endsWith("/tools/stand-in/tailscale"), "… tailscale is the stand-in: " + client.tailscalePath);
            assert(client.tool("curl").endsWith("/tools/stand-in/curl") && client.tool("pkexec").endsWith("/tools/stand-in/pkexec")
                   && client.tool("xdg-open").endsWith("/tools/stand-in/xdg-open") && client.tool("systemctl").endsWith("/tools/stand-in/systemctl"),
                   "… and so are curl, pkexec, xdg-open, systemctl");
            assert(client.running, "the client runs while the module is active");
        });
        _then("the client read the stand-in's state", () => Tailscale.client?.status !== null && Tailscale.client?.entry.state === "activated", () => {
            assertEqual(module.facts["tailscale.connected"], true, "fact tailscale.connected pushed");
            assertEqual(module.facts["tailscale.exitNodeInUse"], false, "fact tailscale.exitNodeInUse: false (a neutral value, never a name)");
            assertEqual(module.facts["tailscale.exitNode"], undefined, "… no fact with the exit node's name");
            assert(module.setFact("connected", "yes") !== "", "… a fact checked against its declared type");
            assert(Tailscale.client.streamStarts >= 1, "the main's client streams the bus");
            // Off: the handle's host is the shell's module host
            assert(module.host.setEnabled("tailscale", false), "turned off");
        });
        _then("off", () => !module.active, () => {
            assertEqual(Tailscale.client, null, "off: the main is gone, and the client's reference with it");
            let stillRunning = false;
            try {
                stillRunning = _firstClient?.running === true;
            } catch (error) {}
            assert(!stillRunning, "off: the old client no longer runs (destroyed with the main)");
            assert(module.setFact("connected", true) !== "", "off: no fact can be set");
            module.host.setEnabled("tailscale", true);
        });
        _then("on again", () => module.active && Tailscale.client !== null && Tailscale.client !== _firstClient, () => {
            assert(Tailscale.client.running, "on again: a new client, running");
        });
        _clock.start();
    }
}
