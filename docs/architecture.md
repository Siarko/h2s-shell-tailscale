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
  module.json                  manifest: main, widget, two VPN slots, page, setting, facts, programs, tests
  qmldir                       types and singletons
  Main.qml                     created by the shell's module host: client, VPN provider, IPC, facts
  Tailscale.qml                singleton pointing at the running client
  TailscaleRules.qml           state, entry, devices, exit nodes, event bus, errors, commands
  TailscaleClient.qml          event stream, reads, actions, programs, runs as administrator
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
  tests/                       QML suites; StandInModule.qml, a handle for a suite's own client
  tests/stand-in/              fake tailscale, pkexec, curl, timeout, systemctl, openssl: the
                               manifest's testPrograms
fixtures/                      outputs of the tailscale CLI and local API
tools/stand-in/                fake xdg-open and nmcli, for the shell itself in the lock bed
tools/test.sh                  checks the stand-ins
tools/redact-status.jq         turns a real `status --json` into a fixture
tests/run.sh                   runs the QML suites
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
- When the stream ends, it restarts with a backoff from 1 s to 30 s.
  The client reads once only if the stream had been up: a message came, or it lived 10 s.
- A 60 s poll runs at all times, except while the look-again backoff runs.
- After the computer wakes (`module.resumed()`), the client reads again and restarts the stream.
- Device traffic is read every 3 s, only while the page shows the devices.
- A read that times out marks the state stale. It is retried with a backoff from 2 s to 60 s.

Without `curl` there is no stream, only the poll.

### Looking again

`TailscaleRules.recheckPlan` says what to do while something is missing:

| Situation | Plan |
|---|---|
| `tailscale` not found or not trusted | `probe`: resolve the programs again |
| service not running, state not readable, or `status --json` failing | `read`: read again and start the stream |
| anything else | `none` |

- `TailscaleClient` runs the plan on a backoff: `recheckMinMs` (5 s) doubling up to `pollMs` (60 s).
- `wake()` runs it at once and starts the backoff over. The page, the popup, the VPN row and the VPN card call it when they appear.
- `recheck()` runs it at once whatever the state. It backs "Check again" and the IPC call `recheck`.
- When the programs are found, the reads, the stream and every feature client start as at the start.

### Logging

The client logs reads only when their outcome changes (`TailscaleRules.logChange`):

- "`<what>` failed: `<reason>`" on the first failure
- "`<what>` still failing, now: `<reason>`" when the reason changes
- "`<what>` answers again" on recovery

`<what>` is `status --json`, `debug prefs`, `the event stream` or `looking for tailscale`.
Addresses in the reason show as `[address]`.

## Actions

- Actions run one at a time (`busy`, `operation`). A second change while one runs is refused.
- A Taildrop send runs outside this lock, so Disconnect stays free.
- Every command is an argv array built by `commandFor()` or a feature's rules. No shell line.
- `tailscale up` and `tailscale login` never get flags. Settings go through `tailscale set`.
- The exit node flag and the route flag are never sent together. Each keeps the other's half of the shared preference.
- A route edit is built from prefs read again just before it runs.
  If the account changed meanwhile, it is aborted.
- Serve changes are built from the serve config read just before they run.
- After Funnel goes on, `ServeClient` reads the config again and checks it with `ServeRules.publicCheck`. Meanwhile `serve.checking` holds back other serve changes and the exit node by network.
- A failed click on Connect, Disconnect, Log in or Start sets `failure` (`TailscaleRules.failureText`, `failureAfter`). Changes run by other clients (operation `serve`, `exit-node`) never set it.

## Programs

The manifest names the programs the module runs (`optionalPrograms`: `tailscale`, `timeout`,
`curl`, `systemctl`, `openssl`, `pkexec`). The shell looks each up on PATH and judges it;
the module takes them from its handle, `module.programs` (module API 1.9), and runs each by
that absolute path (`TailscaleRules.programsFound`).

- `tailscale`, `timeout` and `pkexec` must be trusted: owned by root and writable by root
  alone, or in the Nix store. A run as administrator is `pkexec <timeout> … <tailscale> …`.
  Otherwise the module counts as "not trusted" and runs nothing.
- `curl`, `systemctl` and `openssl` run as you only and are not judged. Without `curl` there
  is no event stream; without `openssl` a certificate's end date is not shown.
- "Check again", a view coming on screen and the backoff ask the shell to look again
  (`module.recheckPrograms()`); the shell also does after the machine wakes.

Links open through `Api.openUrl`. Runs as administrator go through the API's
`PrivilegedAction`, its `elevate` the `pkexec` of `module.programs`. See
[privileges.md](privileges.md).

The system's facts come from `Api.system` (module API 1.13): IP forwarding
(`readIpForwarding()`), the download folder (Taildrop's default folder) and the data home
(the certificate folder, `<data home>/h2s-shell/tailscale/certs`).

### Module test mode

Under the shell's module test runner and in the lock bed the shell is in module test mode
(`Api.testMode`). There every program comes from `module/tests/stand-in` (the manifest's
`testPrograms`), runs as administrator go through the stand-in `pkexec`, `Api.openUrl` only
records the link, and `Api.system` gives made-up facts. IPC calls count as a click there
(the stand-in pkexec asks nobody). A suite's own client gets a `StandInModule` as its handle:
the stand-ins as its programs (or a scenario's: one missing, an untrusted one, one found
later).

Small helpers (`sh`, `find`, `stat`, `cat`, `id`, `ip`) are found through PATH.
