# h2s-shell-tailscale

The Tailscale module for [h2s-shell](../h2s-shell), the Quickshell desktop shell: Tailscale
listed among the shell's VPNs (connect, disconnect, log in and out, exit nodes), with a page of
its own for the main switches and the devices. The plan is the shell's
`docs/plans/tailscale.md`; the module system it plugs into is `docs/plans/modules.md`. It needs
module API 1.1 (the VPN slots).

## What works (delivery step 1)

- **The entry among the VPNs** — "Tailscale · <tailnet>" in the bar's VPN glyph, the network
  popup's VPN section, the overview and Settings → System → Network → VPN, in every state: off,
  connecting, connected ("Tailnet only" / "Via <exit node>"), and what needs you, with its
  button: log in, key expired, waiting for approval (opens the admin console), the service not
  running ("Start"), the exit node offline ("Use none", after a minute's grace), not installed.
- **Connect / disconnect** (bare `tailscale up` / `down`), **log in** (bare `tailscale login`:
  the link opens in the browser — setting "Open Tailscale's login page in the browser" — and
  can be copied; cancel; given up after 10 minutes), **log out** (confirmed with the shell's
  delete button).
- **Exit nodes**: under Tailscale's row in the popup and on the page — none, the suggested one,
  this tailnet's own, Mullvad locations by country (collapsed) and city, offline ones disabled,
  a filter when the list is long; "Allow the local network".
- **The switches**: use routes from other devices, use Tailscale's DNS, block incoming
  connections (shields up). Every change is a `tailscale set`.
- **The devices**: name, owner, system, online / last seen, direct or relayed, addresses and
  name to copy (a click), the traffic while the page is open, a filter, the exit-node mark.
- **Privileges**: tried plainly; when Tailscale says "Access denied" and you clicked, it is
  run again through pkexec (the shell's polkit agent asks); buttons carry the lock while
  changes need a password. "Make <you> the operator" on the page asks once instead (with what
  an operator may do), and shows the NixOS line to make it last. "Bring it up with this
  network" never prompts and never opens a browser: the entry asks for you instead.
- **The card** on the VPN page: tailnet, account, this computer's name and addresses, the exit
  node, the key's expiry, warnings (Tailscale's health, an accepted route that covers the local
  network, two VPNs up), and that the shell's blocking of traffic outside a VPN does not
  support Tailscale (the owner's decision).
- **Live**: one reader of tailscaled's event bus (`curl` on the LocalAPI socket), each
  message a trigger for one coalesced re-read of `status --json` and `debug prefs`; restarted
  with a backoff when it ends, a 60 s poll meanwhile, a re-read after the computer slept.
- Profile facts `tailscale.connected` and `tailscale.exitNode`; IPC target `tailscale`
  (`state`: phase, state, attention, counts — no names, addresses or URLs).

Not yet: accounts and tailnets, hostname, diagnostics, sharing this computer, Taildrop, serve
and funnel, a bar widget of its own (delivery steps 2–6 of the plan's §8).

## Trying it in a development shell

Start a development shell (never your session's) with the module directory in its
environment:

```
H2S_SHELL_MODULE_PATH=/home/h2s/src/h2s-shell-tailscale/module
```

The shell's launcher hands it to the shell; `qs ipc call modules list` shows it loaded, and
Settings → System → Network → Tailscale is its page. It reads Tailscale with your user's
rights; the first change asks for an administrator's password.

## Layout

```
module/                 the module itself — what gets installed
  module.json           the manifest: main, the three VPN slots, the page, a setting, facts, tests
  qmldir                its types and singletons
  TailscaleRules.qml    pure functions: status/prefs → the VPN entry, devices, exit nodes,
                        the event bus, errors, plans, every command's argv
  TailscaleClient.qml   the live side: the stream, reads, actions, the tools seam (I/O only)
  Tailscale.qml         a singleton that points at the running client (for the page)
  Main.qml              made by the shell's host: the client, the VPN provider, IPC, facts
  TailscaleRow.qml      slot network.vpn.row: the exit-node chooser, the login link
  TailscaleCard.qml     slot network.vpn.card: tailnet, account, this computer, warnings
  TailscalePage.qml     slot network.vpn.page and the settings page "tailscale"
  ExitNodeChooser.qml   the chooser (row and page)
  DeviceRow.qml         one device on the page
  tests/                its suites (extend the shell's TestCase: `import qs.tests`)
fixtures/               redacted real outputs and synthetic ones (see fixtures/README.md)
tools/
  stand-in/tailscale    a stand-in CLI: a state machine over the fixtures
  stand-in/pkexec       a stand-in pkexec: ok / 126 / 127, logs what it was asked to run
  stand-in/curl         a stand-in for the LocalAPI event stream
  stand-in/systemctl    starts / stops the stand-in daemon (a file)
  stand-in/xdg-open     opens nothing, logs the link
  stand-in/nmcli        answers nothing (for the lock-bed test's shell)
  test.sh               checks the stand-ins
  redact-status.jq      turns a live `tailscale status --json` into a fixture
tests/
  run.sh                runs the module's suites through the shell's tests/run-modules.sh
  harness.qml           its own loader, for a shell without run-modules.sh
  lock-bed/run.sh       the lock-bed tests, through the shell's tests/lock/run.sh
  lock-bed/tests/       … tailscale.sh: the real shell with the module and the stand-ins
```

## The tools seam

One place (`TailscaleClient.tool()`) decides which `tailscale`, `curl`, `pkexec`,
`systemctl` and `xdg-open` run: a directory given by the owner (the suites), else
`H2S_TAILSCALE_TOOLS` in the shell's environment (the lock-bed test), else — under the shell's
module test runner — `tools/stand-in` next to the module, else (unset: the normal case) the
names on PATH, tailscale's absolute path resolved once with `command -v`. With a directory in
use a link is opened by its `xdg-open`, never by the shell's.

## Running the tests

```
flock /tmp/h2s-locktest.flock tests/run.sh             # the QML suites, headless
flock /tmp/h2s-locktest.flock tests/lock-bed/run.sh    # the real shell in the lock test bed
tools/test.sh                                          # the stand-ins
```

Both runners need a checkout of the shell: `H2S_SHELL_DIR` (default `../h2s-shell-wt`); the
lock-bed runner needs its `tests/lock/run.sh` to take `LOCKTEST_EXTRA_TESTS`. The suites run
the live client against the stand-ins only (they put the stand-ins first on PATH as well).
Never run the suites with `quickshell -p` in a real session, and never point the stand-in
tests at the real `tailscale`: `tools/test.sh` runs every stand-in by its absolute path.

## Installing

Once the shell supports it: add this repository's link in the shell's Settings → Modules
(the shell clones it and loads `module/`). On NixOS the shell's `programs.h2s-shell.modules`
option will take it as a package (a flake comes later).
