# IPC

The module registers the IPC target `tailscale` in `module/Main.qml`.
It exists while the module is enabled.

```bash
h2s-shell ipc call tailscale state
h2s-shell ipc call tailscale advertiseRoute 192.168.1.0/24
```

## Rules

- Read functions return JSON. They hold counts and states only. No names, addresses or URLs.
- The one exception for paths: `state`'s `tools` holds the absolute paths of the programs found.
- No call ever opens a password prompt or a browser.
- `connect` and `disconnect` act like the shell starting a VPN with a network. If they need you, the entry says so.
- Functions marked "operator" do nothing unless your user needs no password.
- If Tailscale still refuses a change, it fails like any other failure.

Calls run as a user's click only when the tools seam names stand-ins.
This lets tests drive the stand-in pkexec. See [architecture.md](architecture.md#tools-seam).

## Connection

| Function | Effect |
|---|---|
| `state` | JSON, fields below |
| `connect` | connect; never prompts |
| `disconnect` | disconnect; never prompts |
| `refresh` | read Tailscale's state again |
| `recheck` | look for Tailscale or its service again at once, as the page's "Check again" |

### Fields of `state`

| Field | Content |
|---|---|
| `phase` | the module's phase, for example `running`, `stopped`, `logged-out`, `not-running`, `missing`, `unknown` |
| `state` | the entry's VPN state, for example `activated`, `activating`, empty for off |
| `attention` | kind of the attention the entry shows; empty for none |
| `attentionAction` | that attention's button label |
| `status` | the entry's status line; the exit node's name replaced by `<exit node>` |
| `busy`, `operation` | whether a change runs, and which |
| `failure` | the reason a failed click left on the status line; empty for none |
| `backendState` | the daemon's `BackendState` |
| `haveNodeKey` | from `status --json` |
| `wantRunning`, `loggedOut` | from `debug prefs` |
| `tools` | `{ tailscale, timeout, pkexec, curl }`: absolute paths; empty when not found |
| `toolsMode` | `owner`, `seam`, `test-stand-ins` or `path` |
| `cli` | `present`, `missing`, `untrusted` or `unknown` |
| `daemon` | `running`, `not-running` or `unknown` |
| `exitNode`, `exitNodeOnline` | an exit node is in use; it is online |
| `streamUp`, `streamStarts`, `events` | the event stream is up; how often it started; messages received |
| `canChange` | changes need no password |
| `ready` | the client has a first answer: state read, read timed out, Tailscale not found, or the service down |
| `stale` | the last read timed out |
| `curlMissing` | `curl` was not found |
| `elevation` | pkexec changes are possible |
| `loginPending` | a login link is waiting |
| `devices`, `exitNodes`, `warnings` | counts |
| `reads` | `status --json` reads so far |
| `opened` | links opened |
| `registered` | the VPN provider is registered with the shell |

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
| `serve` | JSON: entries with type, target kind, port and Funnel; link count; what is missing; `message` (the page shows a message) |
| `readServe` | read the serve config again |
| `sharePort <port> <local port>` | serve `http://127.0.0.1:<local port>` over HTTPS on `<port>` (operator) |
| `setFunnel <port> <true\|false>` | Funnel for the HTTPS share at `/` on `<port>` (operator) |

The check after Funnel runs for these calls too. Turning Funnel off again then never prompts.

## Tailnet lock and exit node by network

| Function | Effect |
|---|---|
| `tailnetLock` | JSON: read, enabled, signed, locked out, trusted key count |
| `readTailnetLock` | read the lock status again |
| `networkExit` | JSON: marked rows, networks, active networks, last decision, runs |
| `setNetworkExit <network id> <choice>` | mark a network: `none`, `auto` or an exit node's stable id; empty removes the mark |

Marking a network needs no privileges. Applying it needs the operator.

`networkExit`'s `decision` is one of:

| Value | Meaning |
|---|---|
| empty | nothing decided yet |
| `applied` | the exit node was set |
| `already` | it was already as wanted |
| `manual` | an exit node picked by hand ended an open choice |
| `none-marked` | no marked network is up |
| `unavailable`, `needs-operator`, `refused`, `conflict` | the choice is open, for that reason |
| `failed` | the change failed; the choice is open |

## Diagnostics and widget

| Function | Effect |
|---|---|
| `runDiagnostics` | run the diagnostics |
| `diagnostics` | JSON: running, ran, row counts, nearest relay code, errors, health warnings |
| `widget` | JSON: the bar widget's kind, tone, exit node mark, badge |
