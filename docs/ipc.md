# IPC

The module registers the IPC target `tailscale` in `module/Main.qml`.
It exists while the module is enabled.

```bash
h2s-shell ipc call tailscale state
h2s-shell ipc call tailscale advertiseRoute 192.168.1.0/24
```

## Rules

- Read functions return JSON. They hold counts and states only. No names, addresses, paths or URLs.
- No call ever opens a password prompt or a browser.
- `connect` and `disconnect` act like the shell starting a VPN with a network. If they need you, the entry says so.
- Functions marked "operator" do nothing unless your user needs no password.
- If Tailscale still refuses a change, it fails like any other failure.

Calls run as a user's click only when the tools seam names stand-ins.
This lets tests drive the stand-in pkexec. See [architecture.md](architecture.md#tools-seam).

## Connection

| Function | Effect |
|---|---|
| `state` | JSON: phase, state, attention, status line, busy, exit node in use and online, tools, stream, counts |
| `connect` | connect; never prompts |
| `disconnect` | disconnect; never prompts |
| `refresh` | read Tailscale's state again |

## Accounts and this device

| Function | Effect |
|---|---|
| `profiles` | JSON: whether the list was read, account ids, the selected id, outdated, hostname set here, key state, interrupted login, `namePending`, `nameNote` |
| `readProfiles` | read the account list (operator) |
| `switchProfile <id>` | switch account (operator) |
| `setHostname <name>` | rename this device; empty for the system's name (operator) |

## Sharing and SSH

| Function | Effect |
|---|---|
| `sharing` | JSON: exit node offered and its approval, route count and states, connector, web interface, SSH, IP forwarding |
| `advertiseRoute <network>` | offer a subnet route (operator) |
| `removeRoute <network>` | stop offering a route (operator) |
| `advertiseExitNode <true\|false>` | offer this computer as an exit node (operator) |
| `setSsh <true\|false>` | Tailscale's SSH server (operator) |
| `readForwarding` | read the two IP forwarding files again |

## Taildrop

| Function | Effect |
|---|---|
| `taildrop` | JSON: targets, send state and per-file outcomes, waiting count (`-1` if unknown), saves, operator, folder, conflict policy, auto-save |
| `sendFile <device id> <absolute path>` | send one file to a device by its stable id (operator) |
| `cancelSend` | stop the running send |
| `saveReceived` | save waiting files (operator) |

## Serve and Funnel

| Function | Effect |
|---|---|
| `serve` | JSON: entries with type, target kind, port and Funnel; link count; what is missing |
| `readServe` | read the serve config again |
| `sharePort <port> <local port>` | serve `http://127.0.0.1:<local port>` over HTTPS on `<port>` (operator) |
| `setFunnel <port> <true\|false>` | Funnel for the HTTPS share at `/` on `<port>` (operator) |

## Tailnet lock and exit node by network

| Function | Effect |
|---|---|
| `tailnetLock` | JSON: read, enabled, signed, locked out, trusted key count |
| `readTailnetLock` | read the lock status again |
| `networkExit` | JSON: marked rows, networks, active networks, last decision, runs |
| `setNetworkExit <network id> <choice>` | mark a network: `none`, `auto` or an exit node's stable id; empty removes the mark |

Marking a network needs no privileges. Applying it needs the operator.

## Diagnostics and widget

| Function | Effect |
|---|---|
| `runDiagnostics` | run the diagnostics |
| `diagnostics` | JSON: running, ran, row counts, nearest relay code, errors, health warnings |
| `widget` | JSON: the bar widget's kind, tone, exit node mark, badge |
