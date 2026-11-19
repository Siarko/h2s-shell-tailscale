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
  module.json                  manifest: main, widget, two VPN anchors, four network card anchors, page, setting, facts, programs, tests
  qmldir                       types and singletons
  Main.qml                     created by the shell's module host: client, VPN provider, IPC, facts
  TailscaleRules.qml           state, entry, devices, exit nodes, event bus, errors, commands
  TailscaleClient.qml          event stream, reads, actions, programs, runs as administrator
  TailscaleRow.qml             at popup.network.connections.vpn.row: exit node chooser, login link
  TailscaleCard.qml            at settings.network_vpn.vpns.card.settings: tailnet, account, device, warnings
  TailscalePage.qml            settings page "tailscale"
  ExitNodeChooser.qml          exit node list (row, page, popup)
  DeviceRow.qml                one device on the page
  CopyChips.qml                addresses and names to copy with a click
  SharingSection.qml           exit node and route offers, forwarding, web interface, More
  SshSection.qml               SSH server
  Taildrop{Rules,Client,Section}.qml     Taildrop
  TaildropSendRow.qml          the popup's row under a device: files chosen, Send, progress
  Serve{Rules,Client,Section}.qml        serve and Funnel
  Cert{Rules,Client,Section}.qml         certificates
  Lock{Rules,Client,Section}.qml         tailnet lock status
  NetworkExit{Rules,Client}.qml          exit node by network
  NetworkExitCard.qml          at the saved networks' card.settings: the network's exit node
  NetworkExitMark.qml          at their card.title: the mark while one is set
  TailscaleWidget.qml          bar widget "tailscale"
  TailscalePopup.qml           its popup
  TailscaleWidgetSettings.qml  its preset pane
  TailscaleWidgetRules.qml     icon state, text, badge, popup devices
  tests/                       QML suites; ScenarioHandle.qml, a handle for a suite's own client
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
Turning the module off destroys `Main`, which ends the stream, the timers and every command.
The feature clients (`TaildropClient`, `ServeClient`, …) hang off the main client.

The views (the widget, its popup, the page, the VPN row and card) reach the client through
the module's handle: `module.main?.client` (module API 1.15). It is null while the module is
off, and the views show nothing then.

The popup's device cap is the preset of the bar entry that opened it: the shell hands the
popup that entry as `opener` (`opener.preset`). The popup takes at most `availableHeight`,
which the shell keeps current, and scrolls past it.

## Running commands

- Every command goes through the shell's command runner (`CommandRunner`, module API 1.8):
  the reads, the changes, the stream, the scripts. `TailscaleClient._run` starts each.
- Each runs by its program's absolute path (`TailscaleRules.commandLine`), with the client's
  environment and a time limit (`TailscaleRules.runLimits`, the table in
  [privileges.md](privileges.md)). The stream has none.
- A run the client stops waiting for is cancelled: when the client stops, or an operation is
  given up. Its answer never reaches the code that started it.
- The runner's result is read by `TailscaleRules.runError`: timed out, not run, or the
  command's own error (`errorKind`).

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
- After the computer wakes (`module.resumed()`), the client reads again and restarts the stream, and a choice of exit node made for now ends (`NetworkExitClient.dropOverride`).
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

The client logs through the shell's `module.log` (module API 1.12), keyed by what it logs,
so the same line is written once (`TailscaleRules.logLine` says the line):

- "`<what>` failed: `<reason>`" on a failure, again when the reason changes
- "`<what>` answers again" on recovery

`<what>` is `status --json`, `debug prefs`, `the event stream` or `looking for tailscale`.
Addresses in the reason show as `[address]` (`Api.address.redact`).

### The time

The state is derived at `now`: the moment of the last read, moved on by the shell's minute
clock (`Api.minuteNow`, module API 1.12) for "last seen" and the key's expiry. When an exit
node goes offline, a one-shot timer ends its grace (`exitNodeOfflineGraceMs`, 60 s); the
module has no clock of its own.

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

- `tailscale` must be trusted: owned by root and writable by root alone, or in the Nix store.
  It is the one program handed to pkexec. Otherwise the module counts as "not trusted" and
  runs nothing.
- `timeout`, `curl`, `systemctl` and `openssl` run as you only and are not judged. `timeout`
  limits each file of a Taildrop save and `tailscale cert` inside the certificate script:
  where the shell keeps a run's limit with its own timer, it stops only the script, not what
  the script started. Without `timeout` the scripts' overall limits still hold.
  Without `curl` there is no event stream; without `openssl` a certificate's end date is not
  shown.
- `pkexec` is named only for module test mode. Outside it the shell uses its own.
- "Check again", a view coming on screen and the backoff ask the shell to look again
  (`module.recheckPrograms()`); the shell also does after the machine wakes.

Links open through `Api.openUrl`. Taildrop's files and folder are chosen through the handle's
`module.chooseFiles` (module API 1.17: the shell's one chooser). While the client's own
chooser is open a new ask does not replace it; an answer after the client stopped is dropped.
"busy" or an error is said where the chooser was asked for (`TaildropRules.chooserNote`). Runs as administrator go through the handle's
`module.privileged.start`, with the command's `what` and its time limit
(`TailscaleRules.privilegedRun`); the result is read by `TailscaleRules.privilegedOutcome`.
See [privileges.md](privileges.md).

The system's facts come from `Api.system` (module API 1.13): the user's name and uid (who may
change Tailscale without a password), the host name (this device's name when none is set in
Tailscale), the home and download folders (where Taildrop's choosers start, its default folder), IP
forwarding (`readIpForwarding()`). The networks this computer is on are
`Api.localNetworks` (module API 1.16: "an accepted route covers the local network"); the
saved networks `Api.networks`, and `Api.networksReady` says they are read whole (the exit
node per network waits until then); the VPNs up `Api.vpnsUp`, with what each does with the
traffic (`fullTunnel`, `setsDns`, `routes`: "another VPN is also on" only beside one that
may take all traffic, or whose routes overlap the tailnet or the subnet routes Tailscale
carries). The module's own VPN reports the same on its entry
(`TailscaleRules.traffic`). Sizes, "ago" and addresses use `Api.format` and `Api.address`.

Certificates are kept in `<module.dataDirectory>/certs` (module API 1.13).

### Module test mode

Under the shell's module test runner and in the lock bed the shell is in module test mode
(`Api.testMode`). There every program comes from `module/tests/stand-in` (the manifest's
`testPrograms`), runs as administrator go through the stand-in `pkexec`, `Api.openUrl` only
records the link, and `Api.system` gives made-up facts. IPC calls count as a click there
(the stand-in pkexec asks nobody). A suite's own client gets a `ScenarioHandle` as its handle:
the stand-ins as its programs (or a scenario's: one missing, an untrusted one, one found
later), and the runs as administrator recorded and handed to the module's real handle; the
client gives them its scenario's environment (module API 1.14, module test mode only).

Small helpers (`sh`, `find`, `stat`, `cat`, `mv`) are found through PATH.
