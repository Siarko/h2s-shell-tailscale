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
    // three VPN slots are the manifest's
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
        lockdownNote: "Tailscale does not work with the shell's blocking of traffic outside a VPN: blocked, it cannot reach its servers or its peers, so it may not connect or carry traffic. Turn the blocking off to use Tailscale."

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

    // Never a text starting with "-" into a notification (notify-send would read it as an option)
    function _plain(text) {
        return String(text ?? "").replace(/^[\s-]+/, "");
    }

    property Connections _failures: Connections {
        target: main.client
        function onFailed(what, reason) {
            main.provider.failed(TailscaleRules.entryId, main._plain(what), main._plain(reason));
        }
    }

    // Facts for profile conditions: pushed only when their value changes (each setFact
    // re-evaluates the shell's settings)
    readonly property bool connected: client.entry.state === "activated"
    readonly property string exitNodeName: connected ? (client.view.exitNode?.name ?? "") : ""
    onConnectedChanged: module?.setFact("connected", connected)
    onExitNodeNameChanged: module?.setFact("exitNode", exitNodeName)

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
                loginPending: client.authUrl !== "", devices: client.devices.length, exitNodes: client.exitNodes.count,
                warnings: client.warnings.length, reads: client.reads, streamStarts: client.streamStarts, events: client.events,
                opened: client.opened, registered: main.provider.registered
            });
        }

        // The provider's own, as the core calls it (origin "user"): for tests
        function connect(): void {
            main.provider.connect(TailscaleRules.entryId, { origin: "user" });
        }

        function disconnect(): void {
            main.provider.disconnect(TailscaleRules.entryId, { origin: "user" });
        }

        function refresh(): void {
            main.client.refresh();
        }
    }

    Component.onCompleted: {
        Tailscale.client = client;
        module?.setFact("connected", connected);
        module?.setFact("exitNode", exitNodeName);
    }
    Component.onDestruction: {
        if (Tailscale.client === client)
            Tailscale.client = null;
    }
}
