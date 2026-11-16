# h2s-shell-tailscale

The Tailscale module for [h2s-shell](../h2s-shell), the Quickshell desktop shell: Tailscale
listed among the shell's VPNs (connect, disconnect, log in and out, exit nodes), with a page of
its own for the main switches, the accounts, this device, sharing this computer (exit node, routes,
SSH server, web interface), the devices and diagnostics. The plan is the shell's
`docs/plans/tailscale.md`; the module system it plugs into is `docs/plans/modules.md`. It needs
module API 1.2 (the VPN slots, the handle's `resumed()`, the pages' `shown`).

## What works (delivery step 1)

- **The entry among the VPNs** — "Tailscale" (or "Tailscale · <organisation>" for a named
  tailnet; never the account's e-mail address, which is on the card) in the bar's VPN glyph, the network
  popup's VPN section, the overview and Settings → System → Network → VPN, in every state: off,
  connecting, connected ("Tailnet only" / "Via <exit node>"), and what needs you, with its
  button: log in, key expired, waiting for approval (opens the admin console), the service not
  running ("Start"), the exit node offline ("Use none", after a minute's grace), not installed,
  not trusted (a tailscale, timeout or pkexec on PATH this user could replace: nothing runs),
  not answering ("Not answering — state unknown": a read timed out; retried with a backoff).
- **Time limits**: every command runs under coreutils' `timeout -k 5 <s>` — reads 15 s,
  changes 60 s, a bare `up` 60 s (past that the daemon keeps trying by itself; Disconnect
  stops it), login 10 minutes — and through pkexec as `pkexec timeout … tailscale …`, so a
  root process ends by itself. Without `timeout`, nothing is run as administrator.
- **Connect / disconnect** (bare `tailscale up` / `down`), **log in** (bare `tailscale login`:
  the link opens in the browser — setting "Open Tailscale's login page in the browser" — and
  can be copied; cancel — at once, even for a login running as root; given up after 10
  minutes), **log out** (confirmed with the shell's delete button). A pending connect shows a
  login URL as soon as `up` prints it or the bus sends it; Disconnect or Cancel ends it.
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
- **Live**: one reader of tailscaled's event bus (`curl` on the LocalAPI socket,
  /var/run/tailscale/tailscaled.sock or /run/tailscale/tailscaled.sock), each message a trigger
  for one coalesced re-read of `status --json` and `debug prefs`; restarted with a backoff
  when it ends; a 60 s poll AT ALL TIMES; a re-read after the computer slept (`resumed()`).
  Without curl: "live updates need curl", the poll only. **To confirm on the real machine**:
  whether the bus (mask 11414: no peer changes) sends a message when a peer goes offline —
  until then a peer's or exit node's online state may be up to a minute old.
- Profile facts `tailscale.connected` and `tailscale.exitNodeInUse` (true/false — never which
  node); IPC target `tailscale` (`state`: phase, state, attention, counts — no names,
  addresses or URLs; `connect`/`disconnect` act as origin "network": they never prompt —
  except while the tools seam names stand-ins, for the lock-bed test). Failure notifications
  carry no addresses; peers' names are shown as plain text, never as markup.

## What works (delivery step 2)

- **Accounts** (Tailscale's profiles), on the page: the account in use and its tailnet under
  the connection state (any user may read that); the list (`switch --list --json`) only on
  "Show accounts" — it needs root or the operator, so it asks for a password and is kept in
  memory only (it holds e-mail addresses); while you are the operator it is read again by
  itself after each change. Switch (`switch <id>`), remove another account (`switch remove
  <id>`, the shell's delete button; the account in use cannot be removed), add one (a bare
  `login`, the existing login flow: link opened, copy, cancel, 10 minutes), a nickname for the
  account in use (`set --nickname=`, the field shows the one it has).
  **How `tailscale login` really behaves** (tailscale 1.104.4's source, cmd/tailscale/cli/login.go
  and ipn/ipnlocal/profiles.go): it ALWAYS moves to a new, empty profile first — the connection
  drops at once, before any link, until the login is done. Another account there becomes a new
  profile (with default settings — the operator too is a setting of each profile). The SAME
  account is merged into its old profile with login's default settings: its exit node, accepted
  routes, hostname, advertised routes, shields up, SSH, nickname and operator are lost. A login
  that started from a logged-in account and did not finish (cancelled, timed out, failed, the
  password prompt dismissed after the move) leaves Tailscale on that empty profile: the next
  read decides, the page says so and offers "Switch back" (`switch <id>`, which restores the
  old profile with its settings; "Show accounts" when the list was not read). A cancelled login
  running as administrator cannot be stopped: the page asks you to close its browser page.
- **The tailnet's name**: an organisation's tailnet by its name; a personal tailnet — whose
  name IS the account's e-mail address — by its MagicDNS suffix (`tail1234.ts.net`), on the
  card and the page. The e-mail address appears only as the account (the page's account line
  and the accounts list), never in the VPN entry's name.
- **This device**: its name (and whether it was set here or is the system's), rename
  (`set --hostname=`; checked first: one DNS label, letters, digits, inner dashes, ≤ 63 — a dot
  is refused, Tailscale uses the first label only), back to the system's (`--hostname=`), its
  addresses and MagicDNS name to copy (a click), online and its home relay, the key's expiry
  (date, "expires in N days", expired, expiry off).
- **The key's expiry**: a warning from 14 days before (the page, the card), and within 7 days
  (`TailscaleRules.reauthSoonDays`) the entry's status line says it too ("Tailnet only · key
  expires in 3 days") — never attention with an action: nothing here renews a key without
  harm (a bare `login` disconnects and, with the same account, resets this device's settings;
  `up --force-reauth` is a flag on `up`). The page links the admin console, where the key is
  renewed or its expiry turned off. An expired key keeps step 1's "Log in" — the page says
  beside it that logging in again resets this device's Tailscale settings (exit node, routes,
  name).
- **Diagnostics**, a collapsed section, run only on "Check the network": client version
  (`version --json`), `netcheck --format=json` (UDP, IPv4/IPv6, NAT, port mapping, the nearest
  relay by name — `debug derp-map`, read once — and the next ones, captive portal; never the
  public address), `dns status --json` (Tailscale DNS in use, MagicDNS, resolvers, split DNS,
  search domains), every health warning with its title and text (the bus's, else status's),
  the update notice (shown, never run). "Copy diagnostics" copies it all without keys or links.
  `tailscale bugreport` is not offered (it uploads logs). Time limits: netcheck 30 s, the
  others 15 s; one run at a time, beside changes (reads only).
- **Ping a device** from its row: `ping --c=1 --timeout=3s <its address>` → "direct, 4 ms",
  "relayed (DERP fra), 31 ms", "no reply" (a 10 s limit around it).

## What works (delivery step 3)

- **Sharing** (a section of the page): offer this computer as an **exit node** (`set
  --advertise-exit-node=true|false`); offer its networks as **subnet routes** (`set
  --advertise-routes=<every route, comma-separated>`, `=` for none) — a route is checked before
  it is sent (address/prefix, no host bits, IPv4 or IPv6, not a default route — that is the exit
  node —, no duplicate; a warning inside 100.64.0.0/10 or fd7a:115c:a1e0::/48). Each shows its
  **approval**, read from `status --json`: Self's AllowedIPs holds the routes an admin approved,
  PrimaryRoutes those this device serves now (approved but not primary: another router serves
  it), ExitNodeOption (both /0 in AllowedIPs) the exit node; while not connected: unknown. The
  admin console's page of this machine is linked while something waits.
  **How the exit node and the routes compose** (tailscale 1.104.4, cmd/tailscale/cli/set.go
  calcAdvertiseRoutesForSet): they are one preference, AdvertiseRoutes; `--advertise-routes`
  alone keeps the exit-node pair as it is, `--advertise-exit-node` alone keeps the routes — so
  the module sends one flag per command, never both, and never a /0 in the route list.
  A route edit is an intent (add or remove one network): its command is planned from prefs read
  again just before it runs — and again before the retry through pkexec —, so it never drops
  routes from a stale list or writes one account's routes into another; it is refused while
  Tailscale's settings are being read again after a change (try again in a moment), and aborted
  ("Changed meanwhile") when the account changed. Once the password dialog is up, the command
  is fixed.
  Offering an exit node while using one is refused by the daemon ("Cannot advertise an exit node
  and use an exit node at the same time.", ipnlocal checkExitNodePrefsLocked): the switch is off
  with the reason and a "Stop using it" button; choosing an exit node while offering one says so.
- **IP forwarding**: `/proc/sys/net/ipv4/ip_forward` and `/proc/sys/net/ipv6/conf/all/forwarding`
  are read (any user may) while the page is shown and something is offered, and after offering;
  off for a family that matters → a warning with what to put in the NixOS configuration
  (`services.tailscale.useRoutingFeatures = "server";`, or the two `boot.kernel.sysctl` lines)
  and Tailscale's own health warning ("ip-forwarding-off") when it sends one. The module writes
  no sysctl.
- **The web interface** (`--webclient`, port 5252) with its link; under **More** (collapsed):
  app connector (`--advertise-connector`), source NAT for offered routes
  (`--snat-subnet-routes`), stateful filtering (`--stateful-filtering`), the peer relay
  (`--relay-server-port=<port>`, 0 any port, empty = off), posture reports (`--report-posture`),
  and read only: the netfilter mode and the tags (asked for and applied).
- **SSH**: Tailscale's SSH server (`set --ssh=true|false`) — "who may log in is decided by the
  tailnet's access rules", the admin console's ACL page linked; off with the reason when the
  tailnet does not allow it (Self's CapMap lacks https://tailscale.com/cap/ssh — the daemon
  refuses then); Tailscale's own SSH health warnings; the system's sshd is not touched (Tailscale
  SSH answers on the Tailscale addresses only). The risk check of `set --ssh` (cli/up.go
  presentSSHToggleRisk) asks only when the CLI runs inside an SSH session over Tailscale
  (SSH_CLIENT from a 100.x address; pkexec clears it): from the desktop it does not ask; if it
  does, the refusal is explained. Device rows of devices that run Tailscale SSH (status's
  `sshHostKeys`) have **Copy ssh command** (`ssh <MagicDNS name>`, else `ssh <IPv4>`). No
  terminal is opened: the shell has no terminal setting or launch API (none in its
  SettingsSchema) — a possible later core addition.
- **About**: update checks (`--update-check`), automatic updates (`--auto-update`; off with the
  reason where Tailscale is updated with the system — on NixOS the daemon refuses: "Auto-updates
  are not supported on this platform.").
- **This device's name** (a fix): a name set while disconnected is the name shown; while
  status (what the tailnet has) still shows the old one the row says "the tailnet shows it after
  connecting" (off) or "updating" (connected), and the old MagicDNS name is marked, not offered
  to copy. Going back to the system's name is judged the same way (the system's name read once
  from /proc/sys/kernel/hostname).

**Left out, with the reason** (tailscale 1.104.4's cmd/tailscale/cli/set.go): changing tags —
`--advertise-tags` is a flag of `up` only (up.go), and changing tags there re-authenticates;
changing the netfilter mode (shown only: it can break the system's firewall); `--posture-checking`
does not exist (the flag is `--report-posture`); `--relay-server-static-endpoints` and
`--remote-config` (hidden) are not offered.

Not yet: Taildrop, serve and funnel, a bar widget of its own (delivery steps 4–6 of the plan's
§8).

## What needs root (asked through pkexec, answered by the shell's polkit agent)

Unless your user is Tailscale's operator, these are tried plainly, denied by Tailscale, and run
again as `pkexec <timeout> -k 5 <limit> <tailscale> …` — only after a click: `up`, `down`,
`login` (log in, add an account), `logout`, every `set …` (exit node, allow
LAN, routes, DNS, shields up, hostname, nickname, operator; since step 3: offering the exit node and routes,
SSH, the web interface, app connector, NAT, stateful filtering, peer relay, posture, update checks and
automatic updates), `switch <id>`, `switch remove
<id>`, and the read `switch --list --json`. Never through pkexec: `status --json`,
`debug prefs`, `exit-node suggest`, the bus, `netcheck`, `dns status`, `debug derp-map`,
`version`, `ping` (any user may), the two IP-forwarding files in /proc, and `systemctl start tailscaled.service` (systemd asks
polkit itself).

## IPC (`qs ipc call tailscale …`)

`state` (phase, state, attention, counts — no names, addresses or URLs), `connect`,
`disconnect` (origin "network": never a prompt), `refresh`; since step 2: `profiles` (ids,
the one in use, outdated, the hostname set here, the key's state, whether a login was
interrupted — no names or addresses), `readProfiles`, `switchProfile <id>`, `setHostname
<name>` (these three only while no password is needed — the operator — or the tools seam names
stand-ins; outside the seam they are asked as origin "network": a denial is a failure, never a
prompt), `runDiagnostics`, `diagnostics` (ran, row counts, the nearest relay's code, error
and health counts). Since step 3: `sharing` (what is offered and its approval, SSH, forwarding — counts and
states, never the networks), `advertiseRoute <network>`, `removeRoute <network>`, `advertiseExitNode
<true|false>`, `setSsh <true|false>` (under the same rule as `setHostname`), `readForwarding`;
`profiles` also says `namePending` and `nameNote`.


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
  module.json           the manifest: main, two VPN slots (row, card), the page, a setting, facts, tests
  qmldir                its types and singletons
  TailscaleRules.qml    pure functions: status/prefs → the VPN entry, devices, exit nodes,
                        the event bus, errors, plans, every command's argv
  TailscaleClient.qml   the live side: the stream, reads, actions, the tools seam (I/O only)
  Tailscale.qml         a singleton that points at the running client (for the page)
  Main.qml              made by the shell's host: the client, the VPN provider, IPC, facts
  TailscaleRow.qml      slot network.vpn.row: the exit-node chooser, the login link
  TailscaleCard.qml     slot network.vpn.card: tailnet, account, this computer, warnings
  TailscalePage.qml     the settings page "tailscale" (where the card's "Settings…" leads)
  ExitNodeChooser.qml   the chooser (row and page)
  DeviceRow.qml         one device on the page (with Ping)
  CopyChips.qml         addresses and names to copy with a click
  SharingSection.qml    the page's Sharing (exit node, routes, forwarding, web interface, More)
  SshSection.qml        the page's SSH (the server switch, access rules)
  tests/                its suites (extend the shell's TestCase: `import qs.tests`)
fixtures/               redacted real outputs and synthetic ones (see fixtures/README.md)
tools/
  stand-in/tailscale    a stand-in CLI: a state machine over the fixtures (accounts: profiles, switch,
                        login adding one, remove, nickname; hostname; netcheck, dns status, derp-map);
                        sharing: every `set` flag with set.go's composition and refusals, approval
  stand-in/pkexec       a stand-in pkexec: ok / 126 / 127 / unkillable, logs what it was asked to run
  stand-in/timeout      runs the real coreutils timeout (so the seam names every program)
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

One place (`TailscaleClient.tool()`) decides which `tailscale`, `timeout`, `curl`, `pkexec`,
`systemctl` and `xdg-open` run: a directory given by the owner (the suites), else
`H2S_TAILSCALE_TOOLS` in the shell's environment (the lock-bed test), else — under the shell's
module test runner — `tools/stand-in` next to the module, else (unset: the normal case) the
names on PATH, resolved once to absolute paths with `command -v` and checked with `stat`
(TailscaleRules.toolsProbe: owned by root and not group/other-writable, or in the Nix store —
the found path's directory, the real file and its directory). With a directory in use a link
is opened by its `xdg-open`, never by the shell's. (`stand-in/timeout` runs the real
coreutils timeout; `stand-in/pkexec` has an "unkillable" mode, `stand-in/tailscale` a slow
`up` and a hanging `status`.)

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
