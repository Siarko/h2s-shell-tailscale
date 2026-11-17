# Architecture

## The split

Each feature has up to three files:

| Part | Role |
|---|---|
| `*Rules.qml` | pure functions: parse output, decide state, build every command's argv. Singletons. |
| `*Client.qml` | I/O only: runs processes, reads files, holds live state |
| `*Section.qml`, `*Table.qml` | UI on the settings page |

The rules hold every decision, so the suites test them with plain objects.

## File map

```
module/
  module.json                  manifest: main, widget, two VPN slots, page, setting, facts, tests
  qmldir                       types and singletons
  Main.qml                     created by the shell's module host: client, VPN provider, IPC, facts
  Tailscale.qml                singleton pointing at the running client
  TailscaleRules.qml           state, entry, devices, exit nodes, event bus, errors, commands
  TailscaleClient.qml          event stream, reads, actions, tools seam
  TailscaleRow.qml             slot network.vpn.row: exit node chooser, login link
  TailscaleCard.qml            slot network.vpn.card: tailnet, account, device, warnings
  TailscalePage.qml            settings page "tailscale"
  ExitNodeChooser.qml          exit node list (row, page, popup)
  DeviceRow.qml                one device on the page
  CopyChips.qml                addresses and names to copy with a click
  SharingSection.qml           exit node and route offers, forwarding, web interface, More
  SshSection.qml               SSH server
  Taildrop{Rules,Client,Section}.qml     Taildrop
  Serve{Rules,Client,Section}.qml        serve and Funnel
  Cert{Rules,Client,Section}.qml         certificates
  Lock{Rules,Client,Section}.qml         tailnet lock status
  NetworkExit{Rules,Client,Table}.qml    exit node by network
  TailscaleWidget.qml          bar widget "tailscale"
  TailscalePopup.qml           its popup
  TailscaleWidgetSettings.qml  its preset pane
  TailscaleWidgetRules.qml     icon state, text, badge, popup devices
  tests/                       QML suites
fixtures/                      outputs of the tailscale CLI and local API
tools/stand-in/                fake tailscale, pkexec, curl and other tools for tests
tools/test.sh                  checks the stand-ins
tools/redact-status.jq         turns a real `status --json` into a fixture
tests/run.sh                   runs the QML suites
tests/harness.qml              suite loader for a shell without tests/run-modules.sh
tests/lock-bed/                runs the real shell with the module and the stand-ins
```

## Lifetime

`Main.qml` owns one `TailscaleClient`. The client runs only while `module.active` is true.
Turning the module off destroys `Main`, which ends the stream, the timers and every process.
The feature clients (`TaildropClient`, `ServeClient`, …) hang off the main client.

## How state is read

- One `curl` reads the daemon's event bus at `/localapi/v0/watch-ipn-bus`.
- The socket is `/var/run/tailscale/tailscaled.sock`, else `/run/tailscale/tailscaled.sock`.
- The watch mask is 11414: state, prefs, health, suggested exit node, version. No private keys, no network map.
- State, login URL, errors and prefs are taken from each message at once.
- Each message also triggers a re-read of `status --json` and `debug prefs`.
  Re-reads are debounced and never overlap.
- When the stream ends, the client reads once and restarts the stream with a backoff from 1 s to 30 s.
- A 60 s poll runs at all times.
- After the computer wakes (`module.resumed()`), the client reads again and restarts the stream.
- Device traffic is read every 3 s, only while the page shows the devices.
- A read that times out marks the state stale. It is retried with a backoff from 2 s to 60 s.

Without `curl` there is no stream, only the poll.

## Actions

- Actions run one at a time (`busy`, `operation`). A second change while one runs is refused.
- A Taildrop send runs outside this lock, so Disconnect stays free.
- Every command is an argv array built by `commandFor()` or a feature's rules. No shell line.
- `tailscale up` and `tailscale login` never get flags. Settings go through `tailscale set`.
- The exit node flag and the route flag are never sent together. Each keeps the other's half of the shared preference.
- A route edit is built from prefs read again just before it runs.
  If the account changed meanwhile, it is aborted.
- Serve changes are built from the serve config read just before they run.

## Tools seam

`TailscaleClient.tool()` decides which `tailscale`, `timeout`, `curl`, `pkexec`, `systemctl` and `xdg-open` run.
The first that applies wins:

| Source | `toolsMode` | Used by |
|---|---|---|
| `toolsDir` set by the owner | `owner` | the suites |
| `H2S_TAILSCALE_TOOLS` (an absolute directory) | `seam` | the lock-bed test |
| `tools/stand-in` next to the module, when `H2S_TEST_MODULES` is set | `test-stand-ins` | the shell's module test runner |
| the names on PATH | `path` | normal use |

On PATH, each program is resolved once to an absolute path with `command -v` and checked with `stat`.
`tailscale`, `timeout` and `pkexec` must be owned by root and not group- or other-writable, or be in the Nix store.
Otherwise the module counts as "not trusted" and runs nothing.

With a tools directory, links open through its `xdg-open`, not the shell's.

Other environment variables, for tests:

| Variable | Replaces |
|---|---|
| `H2S_TAILSCALE_FORWARDING_DIR` | the two `/proc` forwarding files (`ipv4`, `ipv6` in that directory) |
| `H2S_TAILSCALE_DOWNLOAD_DIR` | the default Taildrop folder |
| `H2S_TAILSCALE_CERT_DIR` | the certificate folder |

Small helpers (`sh`, `find`, `stat`, `cat`, `openssl`) are found through PATH.
