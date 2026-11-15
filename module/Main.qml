import QtQuick
import Quickshell.Io
import qs.api
import qs.components

// Created by the module host while the module is enabled. Everything of the module that acts
// lives here: the live client (its stream, timers and commands), the VPN provider (it leaves
// VpnManager when this is destroyed), the IPC target, the facts.
QtObject {
    id: main

    // The module's handle, set by the host before Component.onCompleted
    property var module: null

    property TailscaleClient client: TailscaleClient {
        module: main.module
        running: main.module?.active ?? false
    }

    // Tailscale among the shell's VPNs. providerId: the module's id (module API 1.1), so its
    // VPN slots (the row's, the card's) are the manifest's
    property VpnProvider provider: VpnProvider {
        // The live client, for the slots' contributions (context.provider.client)
        readonly property var client: main.client

        providerId: main.module?.moduleId ?? "tailscale"
        kind: "mesh"
        typeName: TailscaleRules.typeName
        glyph: "󰖂"
        entries: [main.client.entry]
        ready: main.client.ready
        busy: main.client.busy
        canChange: main.client.canChange
        // The owner's decision (tailscale.md §8): the shell's kill switch does not support it
        lockdownNote: "Tailscale is not let through while traffic outside a VPN is blocked: turn the blocking off to use it."

        // An unknown origin is taken as "network" (the client reads anything but "user" so)
        function connect(entryId, request) {
            main.client.connect(request?.origin);
        }
        function disconnect(entryId, request) {
            main.client.disconnect(request?.origin);
        }
        function attend(entryId) {
            main.client.attend();
        }
    }

    // Never a text starting with "-" into a notification (notify-send would read it as an
    // option), and no addresses (a notification may show on a shared screen)
    function _plain(text) {
        return TailscaleRules.withoutAddresses(String(text ?? "")).replace(/^[\s-]+/, "");
    }

    property Connections _failures: Connections {
        target: main.client
        function onFailed(what, reason) {
            main.provider.failed(TailscaleRules.entryId, main._plain(what), main._plain(reason));
        }
    }

    // Facts for profile conditions: pushed only when their value changes (each setFact
    // re-evaluates the shell's settings). Neutral values only: whether an exit node is in
    // use, never its name (no profile condition needs which one)
    readonly property bool connected: client.entry.state === "activated"
    readonly property bool exitNodeInUse: connected && client.view.exitNode !== null
    onConnectedChanged: module?.setFact("connected", connected)
    onExitNodeInUseChanged: module?.setFact("exitNodeInUse", exitNodeInUse)

    // For tests and scripts: plain state — no names, addresses or URLs
    property IpcHandler ipc: IpcHandler {
        target: "tailscale"

        function state(): string {
            const client = main.client;
            const exitNode = client.view.exitNode;
            let status = client.entry.status;
            if (exitNode && exitNode.name !== "")
                status = status.split(exitNode.name).join("<exit node>");
            return JSON.stringify({
                phase: client.view.phase, state: client.entry.state, attention: client.view.attention?.kind ?? (client.pendingAttention?.kind ?? ""),
                attentionAction: client.entry.attention?.action ?? "", status: status, busy: client.busy, operation: client.operation,
                exitNode: exitNode !== null, exitNodeOnline: exitNode?.online ?? false, cli: client.cli, daemon: client.daemon,
                streamUp: client.streamUp, canChange: client.canChange, ready: client.ready, toolsMode: client.toolsMode,
                stale: client.stale, curlMissing: client.curlMissing, elevation: client.elevationProblem === "",
                loginPending: client.authUrl !== "", devices: client.devices.length, exitNodes: client.exitNodes.count,
                warnings: client.warnings.length, reads: client.reads, streamStarts: client.streamStarts, events: client.events,
                opened: client.opened, registered: main.provider.registered
            });
        }

        // The provider's own, for tests and scripts — as origin "network" (never a password
        // prompt, never a browser: any process of the user may call this), except while the
        // tools seam names stand-ins (the lock-bed test: its pkexec asks nobody)
        function connect(): void {
            main.provider.connect(TailscaleRules.entryId, { origin: main._ipcOrigin() });
        }

        function disconnect(): void {
            main.provider.disconnect(TailscaleRules.entryId, { origin: main._ipcOrigin() });
        }

        function refresh(): void {
            main.client.refresh();
        }
    }

    function _ipcOrigin() {
        return client.toolsMode === "seam" || client.toolsMode === "test-stand-ins" || client.toolsMode === "owner" ? "user" : "network";
    }

    Component.onCompleted: {
        // Its page is the settings page named by its module id, "tailscale" (the manifest's
        // settingsPages, under Network): the card's "Settings…" goes there rather than framing
        // a copy over the VPN page — there is no network.vpn.page slot any more. Assigned, not
        // declared: a shell from before VpnProvider.settingsPage would refuse the whole main
        // over an unknown property; there the page is still in the list, the card has no
        // button.
        if ("settingsPage" in provider)
            provider.settingsPage = main.module?.moduleId ?? "tailscale";
        Tailscale.client = client;
        module?.setFact("connected", connected);
        module?.setFact("exitNodeInUse", exitNodeInUse);
    }
    Component.onDestruction: {
        if (Tailscale.client === client)
            Tailscale.client = null;
    }
}
