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
    // option), no addresses (a notification may show on a shared screen), and plain text
    // (TailscaleRules.plainText: a notification daemon may read markup in the body)
    function _plain(text) {
        return TailscaleRules.plainText(TailscaleRules.withoutAddresses(String(text ?? "")), 1000).replace(/^[\s-]+/, "");
    }

    // The shell's networks (module API 1.3), for the exit node per network
    property Binding _networks: Binding {
        target: main.client.networkExit
        property: "networks"
        value: Api.networks ?? []
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
                phase: client.view.phase, state: client.entry.state,
                attention: client.attentionKind,
                attentionAction: client.entry.attention?.action ?? "", status: status, busy: client.busy, operation: client.operation,
                // What a failed click left on the status line (no addresses), the daemon's own words
                // for its state, and which programs were found — enough to tell why a click did nothing
                failure: client.failureText, backendState: client.status?.backendState ?? "",
                haveNodeKey: client.status?.haveNodeKey ?? false, wantRunning: client.prefs?.wantRunning ?? false,
                loggedOut: client.prefs?.loggedOut ?? false,
                tools: { tailscale: client.tailscalePath, timeout: client.timeoutPath, curl: client.curlPath, systemctl: client.systemctlPath },
                exitNode: exitNode !== null, exitNodeOnline: exitNode?.online ?? false, cli: client.cli, daemon: client.daemon,
                streamUp: client.streamUp, canChange: client.canChange, ready: client.ready, testMode: Api.testMode,
                stale: client.stale, curlMissing: client.curlMissing, elevation: client.elevationProblem === "",
                loginPending: client.authUrl !== "", devices: client.devices.length, exitNodes: client.exitNodes.count,
                warnings: client.warnings.length, reads: client.reads, streamStarts: client.streamStarts, events: client.events,
                opened: client.opened, registered: main.provider.registered
            });
        }

        // The provider's own, for tests and scripts — as origin "network" (never a password
        // prompt, never a browser: any process of the user may call this), except in module
        // test mode (the lock-bed test: its pkexec is a stand-in that asks nobody)
        function connect(): void {
            main.provider.connect(TailscaleRules.entryId, { origin: main._ipcOrigin() });
        }

        function disconnect(): void {
            main.provider.disconnect(TailscaleRules.entryId, { origin: main._ipcOrigin() });
        }

        function refresh(): void {
            main.client.refresh();
        }

        // As the page's "Check again": looks for Tailscale (or its service) again at once
        function recheck(): void {
            main.client.recheck();
        }

        // The accounts as read (ids only, no names or addresses): { read, ids, selected,
        // outdated, hostname (prefs' --hostname: the user's own choice), keyState, loginInterrupted }
        function profiles(): string {
            const client = main.client;
            const list = client.accounts ?? [];
            return JSON.stringify({
                read: client.accounts !== null, ids: list.map(account => account.id), selected: list.find(account => account.selected)?.id ?? "",
                outdated: client.accountsOutdated, hostname: client.prefs?.hostname ?? "", keyState: client.keyState.state,
                loginInterrupted: client.loginInterrupted !== null, namePending: client.device?.namePending ?? false,
                nameNote: client.device?.nameNote ?? ""
            });
        }

        // These change Tailscale or read what only root may: as the page's buttons, but never
        // a password prompt from a script — only while this user needs none (the operator) or
        // in module test mode (the lock-bed test); and asked as origin "network" (_ipcOrigin)
        // outside it, so a denial (a stale canChange) is a failure, not a prompt
        function readProfiles(): void {
            if (main._ipcMayChange())
                main.client.readAccounts(main._ipcOrigin());
        }

        function switchProfile(id: string): void {
            if (main._ipcMayChange())
                main.client.switchAccount(id, main._ipcOrigin());
        }

        function setHostname(name: string): void {
            if (main._ipcMayChange())
                main.client.setHostname(name, main._ipcOrigin());
        }

        // Step 3: what this computer offers, without the networks themselves: { known, connected,
        // exitNode (offered), exitNodeState, routes (count), routeStates [pending | approved |
        // standby | unknown], pending, connector, webClient, ssh, sshAllowed (true / false /
        // null), forwardingRead, ipv4Forwarding, ipv6Forwarding, forwardingWarning, prefsCurrent
        // (a route edit is accepted: prefs read since the last operation) }
        function sharing(): string {
            const client = main.client;
            const share = client.sharing;
            return JSON.stringify({
                known: share.known, connected: share.connected, exitNode: share.exitNode.offered, exitNodeState: share.exitNode.state,
                routes: share.routes.length, routeStates: share.routes.map(route => route.state), pending: share.pendingCount,
                connector: share.connector, webClient: share.webClient, ssh: client.sshServer.on, sshAllowed: client.sshServer.allowedByTailnet,
                forwardingRead: client.forwarding.readAt > 0, ipv4Forwarding: client.forwarding.ipv4, ipv6Forwarding: client.forwarding.ipv6,
                forwardingWarning: client.forwardingWarning !== null, prefsCurrent: client.prefsCurrent
            });
        }

        // As the page's controls, under the same rule as setHostname (no prompt from a script)
        function advertiseRoute(network: string): void {
            if (main._ipcMayChange())
                main.client.addRoute(network, main._ipcOrigin());
        }

        function removeRoute(network: string): void {
            if (main._ipcMayChange())
                main.client.removeRoute(network, main._ipcOrigin());
        }

        function advertiseExitNode(on: bool): void {
            if (main._ipcMayChange())
                main.client.setAdvertiseExitNode(on, main._ipcOrigin());
        }

        function setSsh(on: bool): void {
            if (main._ipcMayChange())
                main.client.setSwitch("ssh", on, main._ipcOrigin());
        }

        // Reads /proc's two forwarding switches (any user may)
        function readForwarding(): void {
            main.client.readForwarding();
        }

        // Step 4, Taildrop — its state without names, paths or addresses: { targets (devices that
        // can receive), available (online ones), targetSet, chosen (paths chosen), sendState,
        // sendOutcomes [per file], waitingCount (-1 unknown: not the operator),
        // busWaiting, incoming, saved [outcomes], saveError, operator, canSave, folderSet,
        // conflict, autoSave, notices (arrival notifications made) }
        function taildrop(): string {
            const drop = main.client.taildrop;
            return JSON.stringify({
                targets: drop.targets.length, available: drop.targets.filter(item => item.available).length, targetSet: drop.target !== null,
                chosen: drop.chosen.length, sendState: drop.send.state, sendOutcomes: drop.send.files.map(file => file.outcome),
                waitingCount: drop.waitingCount, busWaiting: drop.busWaiting,
                incoming: drop.incoming.length, saved: drop.saved.map(item => item.outcome), saveError: drop.saveError !== "",
                operator: drop.isOperator, canSave: drop.canSave, folderSet: drop.folder !== "", conflict: drop.conflict,
                autoSave: drop.autoSave, notices: drop.notices.length
            });
        }

        // Sends one file (an absolute path) to a device by its stable id — the operator only, as
        // this user: never a password prompt
        function sendFile(deviceId: string, path: string): void {
            const drop = main.client.taildrop;
            drop.targetId = deviceId;
            drop.clearPaths();
            if (drop.addPaths(path) > 0)
                drop.sendFiles();
        }

        function cancelSend(): void {
            main.client.taildrop.cancelSend();
        }

        // Saves the waiting files — only ever without a prompt (the operator, as this user)
        function saveReceived(): void {
            main.client.taildrop.save("ipc");
        }

        // Step 5, serve and Funnel — counts and states, never names or URLs: { read, entries,
        // types [https | http | tcp | …], whats [proxy | tcp | path | text | …], ports, funnel [bool],
        // funnelOn, urls (count), connected, https, magicDns, funnelAllowed, canFunnel, message }
        function serve(): string {
            const share = main.client.serve;
            const ready = share.ready;
            return JSON.stringify({
                read: share.config !== null, entries: share.entries.length, types: share.entries.map(entry => entry.type),
                whats: share.entries.map(entry => entry.what), ports: share.entries.map(entry => entry.port),
                funnel: share.entries.map(entry => entry.funnel), funnelOn: share.config?.funnelOn ?? false,
                urls: share.entries.reduce((sum, entry) => sum + entry.urls.length, 0), connected: ready.connected, https: ready.https,
                magicDns: ready.magicDns, funnelAllowed: ready.funnelAllowed, canFunnel: ready.canFunnel, message: share.message !== ""
            });
        }

        function readServe(): void {
            main.client.serve.read();
        }

        // As the page's controls, under the same rule as setHostname (no prompt from a script):
        // HTTPS on `port` to the local port `localPort`; Funnel on or off for the entry on `port`
        function sharePort(port: int, localPort: int): void {
            if (main._ipcMayChange())
                main.client.serve.add({ kind: "proxy", port: port, localPort: localPort, path: "" }, main._ipcOrigin());
        }

        function setFunnel(port: int, on: bool): void {
            const entry = main.client.serve.entries.find(item => item.port === port && item.type === "https" && item.mount === "/");
            if (entry && main._ipcMayChange())
                main.client.serve.setFunnel(entry.key, on, main._ipcOrigin());
        }

        // Tailnet lock and the per-network exit node: states only
        function tailnetLock(): string {
            const lock = main.client.tailnetLock.lock;
            return JSON.stringify({ read: lock !== null, enabled: lock?.enabled ?? false, signed: lock?.signed ?? null,
                                    lockedOut: lock?.lockedOut ?? false, trustedKeys: lock?.trustedKeys ?? 0 });
        }

        function readTailnetLock(): void {
            main.client.tailnetLock.read();
        }

        function networkExit(): string {
            const exit = main.client.networkExit;
            return JSON.stringify({ rows: exit.rows.length, networks: exit.networks.length, active: exit.networks.filter(network => network.active).length,
                                    decision: exit.decision.kind, runs: exit.runs, canChange: main.client.canChange });
        }

        // Marks a network (by its id) with a choice: "none", "auto" or a node's stable id
        function setNetworkExit(networkId: string, choice: string): void {
            const node = main.client.exitNodes.own.find(option => option.id === choice);
            main.client.networkExit.setChoice(networkId, choice === "" ? null : choice, node?.name ?? "", "");
        }

        // Diagnostics need no privileges; their state without addresses or names
        function runDiagnostics(): void {
            main.client.runDiagnostics();
        }

        // Step 6, the bar widget's state as it shows it (TailscaleWidgetRules, the same the
        // widget reads) — no names: { kind, tone, mark, badge }
        function widget(): string {
            const summary = TailscaleWidgetRules.summaryOf(main.client);
            const drop = main.client.taildrop;
            const badge = TailscaleWidgetRules.badge(drop.waitingCount, drop.busWaiting, true);
            return JSON.stringify({ kind: summary.kind, tone: summary.tone, mark: summary.mark, badge: badge.shown ? (badge.text || "dot") : "" });
        }

        function diagnostics(): string {
            const result = main.client.diagnostics;
            return JSON.stringify({
                running: result.running, ran: result.ranAt > 0, netcheckRows: result.netcheck.length, dnsRows: result.dns.length,
                nearest: result.nearest?.code ?? "", errors: result.errors.length, health: main.client.health.length
            });
        }
    }

    function _ipcMayChange() {
        return client.canChange || _ipcOrigin() === "user";
    }

    // Module test mode (module API 1.10): set only by the shell's test entry points, never by
    // a variable alone — there the programs are stand-ins and nothing reaches a real pkexec
    function _ipcOrigin() {
        return Api.testMode ? "user" : "network";
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
