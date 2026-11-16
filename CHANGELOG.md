# Changelog

## 0.6.0 — unreleased (delivery steps 5 and 6: serve and Funnel, certificates, tailnet lock, an exit node per network; a bar widget and popup)

Needs the shell's module API 1.3 (`Api.networks`, `Api.vpnsUp`: the saved networks and the VPNs up, new
for the exit node per network; `module.presetValue` / `setPresetValue` for the bar widget's settings). The new live suite asks for 60 s (its four scenarios run one after another), the exit node per network suite 30 s.

- Serve (a collapsed section): what this computer shares, read with `serve status --json` (any user
  may) when the section is open on screen and after each change — each entry with where it listens,
  what it serves, "Public" when Funnel is on, its links to copy. Share a local port over HTTPS
  (443, 8443 or 10000, an optional path) or as a TCP forward; Funnel on or off per HTTPS entry;
  remove one; stop all (`serve reset`, behind the delete button). Every change is planned again
  from prefs and the config read under the change lock; through pkexec when denied (a click only).
  Files and folders are never added (tailscaled serves them as root); ones already there are
  listed and can be removed. What is missing is said with the admin console's link: connect,
  MagicDNS, HTTPS certificates, the Funnel attribute, shields up.
- Certificates (collapsed): "Get certificate" for this computer's MagicDNS name, the operator
  only, as the user, into `<data home>/h2s-shell/tailscale/certs` (700; key 600 as the CLI
  writes it); the files to copy, the end date (openssl, when installed). No renewal.
- Tailnet lock: on or off, signed or locked out, the keys to copy, the trusted keys' count. A
  locked-out device raises attention on the entry while connected ("Open admin console"). Nothing
  changes the lock.
- Exit node by network: a table in the Exit node section; when the marked networks that are up
  change, the exit node is set or cleared once (a choice made by hand afterwards stays). Only for
  the operator (an automatic change never prompts). A line when another VPN is up beside the exit
  node.
- Funnel is per port: "Funnel on" asks first and names the other shares that go public with it;
  adding to a public port reads "Share publicly". A port holding a file or folder, a unix socket
  or anything else the module would not send itself is never made public, also not through
  pkexec ("Change this one in a terminal"). Funnel off needs HTTPS serving. Shares under an old
  device name are left to a terminal. A failed read of the config plans nothing. Stop all says
  when files, terminal shares or services stop too.
- Exit node by network waits for Tailscale (off, starting, devices not known yet) and applies the
  choice once it is up; a short drop to no marked network (under 30 s) does not re-apply it.
- Tailnet lock status is read only while Tailscale runs (once it is up, when this device's key
  changes, 8 s after the state settles), when the page shows it and on resume — not while
  stopped or logged out.
- The live suite runs 16 scenarios at a time (all fifty at once starved the event loop and timed
  out in about one run of three), waits up to 15 s per step by the clock, asks for 60 s, and
  waits on conditions where it slept (processes gone, the stand-in's login moved, the next read).
- Shorter texts: "Shields up is on", "Locked out by tailnet lock", "Another VPN is also on". The
  old serve and cert command builders are gone.
- `errorKind`: the daemon's "must be root, or be an operator and able to run 'sudo tailscale'"
  (a serve config holding a path) counts as denied. `parseStatus` keeps `certDomains`. Time limit
  `cert` (180 s).
- IPC: `serve`, `readServe`, `sharePort <port> <local port>`, `setFunnel <port> <true|false>`,
  `tailnetLock`, `readTailnetLock`, `networkExit`, `setNetworkExit <network id> <choice>`.
- Stand-ins: serve and Funnel (status, add, remove, reset, the CLI's and daemon's refusals), `cert`,
  `lock status --json`, an `openssl` for the end date.
- Step 6: a bar widget "Tailscale" with a popup, not on the bar by default (Settings → Bar → Add
  widget). The
  icon coloured by state (off, connecting, connected, needs attention, nothing to use), a globe
  while an exit node is in use, a badge for received files, optional text (none, state, exit
  node). No tooltip.
- Step 6: the popup — state with Connect or Disconnect (or Log in, Start), the account, the
  exit-node chooser, this device's addresses, devices online first with a cap and "Send file…",
  received files with Save, Settings… and Admin console. It renders the client's state; nothing
  new runs.
- Step 6: its preset pane (text, badge, device cap) through `module.presetValue` /
  `setPresetValue`; `TailscaleWidgetRules` (pure); IPC `widget`; the device rows' "Send file…"
  rule shared (`canSendTo`); Taildrop's `chooseInPage` opens the page's file chooser from the popup.

## 0.5.0 — unreleased (delivery step 4: Taildrop)

Needs the shell's module API 1.2 (no core change: the dialogs are QtQuick.Dialogs, notifications
with an action are `module.notify`, "Open folder" is `Api.openUrl(file:…, { allowFile: true })`).
The new live suite asks for 30 s.

- Taildrop needs this user to be Tailscale's operator and never runs through pkexec (a root send
  was rejected in review: root would open the chosen paths long after any check). Not the
  operator: one line and "Let this user manage Tailscale without a password".
- Send from the page's Taildrop section and "Send file…" on device rows: devices Tailscale says can
  receive, files from the chooser, pasted paths or a drop. `tailscale file cp -- <paths…> <IPv4>:`
  as the user, outside the change lock (the entry is not busy); Disconnect, logout and account
  switches end it; Cancel kills it; stopped after 2 minutes without progress on the bus, 6 hours
  at most. Per-file progress and results.
- Received files: a notification per arrival with the name ("Save" for the operator), "Files
  received" on the entry's status line. The operator saves into a folder (default
  XDG_DOWNLOAD_DIR, else ~/Downloads) with a conflict policy; names made safe; placed by rename in
  a folder of the user's own that is not a link; "Open folder". Auto-save (off by default) runs per
  arrival, never replaces, does not retry a file it left until the next arrival or a manual Save.
- Administration: operator of this account or not; "Stop being the operator" (`set --operator=`).
- One change at a time: `_runChange` refuses a second change while one runs ("Another Tailscale
  change is running.") instead of replacing it.
- `commandFor("fileCp")` puts `--` before the paths; `commandFor("operator", { user: "" })` gives
  the operator up; time limits `send` (6 h) and `save` (600 s per request).
- IPC: `taildrop`, `sendFile <device id> <path>`, `cancelSend`, `saveReceived`.
- Stand-ins: `file cp` (checks, the 403, bus progress, TS_FAKE_SEND_DELAY / _FAIL / _REFUSE, a copy
  in sent/), curl's Taildrop inbox (files/: list, fetch, delete; 403 unless the operator),
  TS_FAKE_BUS_FOLLOW.

## 0.4.0 — unreleased (delivery step 3)

Needs the shell's module API 1.2 (unchanged). The live suite asks for 45 s (`timeLimitMs`, set only
where the shell's TestCase has it: a shell from before that change gives it 20 s).

- A "Sharing" section on the page: offer this computer as an exit node (`set
  --advertise-exit-node=`), offer networks as subnet routes (`set --advertise-routes=<the whole
  list>`: add with a check first — address/prefix, no host bits, no default route, no duplicate,
  a warning inside Tailscale's own ranges —, remove with the delete button), each with its
  approval read from status (approved, waiting for an admin, approved but another device serves
  it, unknown while not connected) and the admin console's page of this machine. The two
  flags are never sent together: each alone keeps the other half of the shared preference
  (tailscale 1.104.4's cli/set.go). Offering an exit node while using one (and the reverse) is
  refused before it runs, with "Stop using it".
- IP forwarding read from /proc (only while something is offered and the page is shown, or
  after offering): when it is off, a warning with the NixOS lines
  (`services.tailscale.useRoutingFeatures = "server"`, or the sysctls) — nothing is written.
  Tailscale's own "IP forwarding is off" health warning shown there too.
- The web interface switch (`--webclient`) with its link; under "More" (collapsed): the app
  connector, source NAT for offered routes, stateful filtering, the peer relay's port
  (`--relay-server-port=`, empty = off), posture reports (`--report-posture`), the netfilter
  mode and the tags (read only: tags change only with `tailscale up`).
- An "SSH" section: Tailscale's SSH server (`set --ssh=`), who may log in (the tailnet's access
  rules, linked), off with the reason when the tailnet does not allow it, Tailscale's own SSH
  health warnings. Device rows that run Tailscale SSH get a "Copy ssh command" chip (`ssh
  <MagicDNS name>`).
- About: update checks (`--update-check`) and automatic updates (`--auto-update`, off with the
  reason where Tailscale is updated with the system).
- Tailscale's refusals shown as it says them (the CLI's "Warning:" lines skipped; the lose-ssh
  confirmation that cannot be answered without a terminal explained).
- Fixed (owner's report): a name set while disconnected looked as if the rename had failed —
  the page now shows the name set (prefs), and says "the tailnet shows it after connecting" or
  "updating" while status still has the old one; the old MagicDNS name is marked, not offered as
  a chip. The system's name is read once (/proc/sys/kernel/hostname) to tell the same when going
  back to it.
- Fixed (owner's report): "This device"'s label/value rows (name, MagicDNS, connection, key)
  are together, so their label column no longer shows as a gap beside a lone "Name" row.
- IPC `sharing`, `advertiseRoute`, `removeRoute`, `advertiseExitNode`, `setSsh`,
  `readForwarding`; `profiles` says `namePending` / `nameNote`.
- After the review: a route edit is an intent (add / remove one network) planned from prefs read
  again just before the command runs and again before the retry through pkexec; refused while
  prefs are not read, not read again since the last change or account switch, or cut at 256
  routes, and for a network not offered; aborted when the account changed meanwhile; the list
  sent is held at once (a second edit before the next read builds on it). The SSH and web
  interface hints say what they expose; the VPN card shows a new name while the tailnet has the
  old one; IPv4-mapped IPv6 routes are written as Tailscale prints them; a delayed process
  answer after its object was destroyed no longer throws.
- Stand-ins: every new flag of `set` with the real composition, checks and refusals (host bits,
  an address without prefix, half an exit pair, exit node in use, SSH not allowed, auto-update on
  NixOS, the lose-ssh abort, `--advertise-tags` unknown to `set`), an admin's approval (a state
  file), a name set while not Running reaching status only with `up`. Fixtures
  status-sharing.json and prefs-sharing.json.

## 0.3.0 — unreleased (delivery step 2)

Needs the shell's module API 1.2 (unchanged: no core change for this step).

- Accounts on the page: the account in use and its tailnet under the state; the list on "Show
  accounts" (`switch --list --json`, through pkexec unless you are the operator; kept in memory
  only, read again by itself only for the operator), switch, remove another account (delete
  button), add an account (a bare `login`), a nickname for the account in use (`set
  --nickname=`, prefilled). A login from a logged-in account that did not finish leaves
  Tailscale on a new, empty profile (`login` moves there first, before its link): the next read
  decides, the page says so and offers "Switch back". "Add account" says it disconnects.
- A personal tailnet is named by its MagicDNS suffix on the card and the page, no longer by the
  e-mail address it is named after (the address stays in the account line).
- This device: its name, rename (`set --hostname=`, checked as a DNS label first; back to the
  system's name), addresses and MagicDNS name to copy, online and home relay, the key's expiry.
- A key that expires: a warning from 14 days, within 7 days on the entry's status line too, and
  the admin console's link on the page — no "Renew" (a bare `login` would disconnect and, with
  the same account, reset this device's settings). Beside an expired key's "Log in": that
  logging in again resets the settings.
- Diagnostics, collapsed and run only when asked: client version, netcheck (with the relays'
  names from `debug derp-map`), `dns status --json`, every health warning with its title, the
  update notice; "Copy diagnostics" (no keys, no links). No `bugreport`.
- Ping a device from its row (`ping --c=1 --timeout=3s`): direct or relayed, the time.
- After the review: IPC changes are asked as origin "network" outside the stand-ins (a denial
  is a failure, never a prompt); the list is read again by itself without a prompt; an account
  is not removed while the list is out of date or when it is the one in use; "Copy
  diagnostics" also drops scheme-less links and addresses in health texts; shorter netcheck
  texts; the stand-in's `login` moves to the empty profile first and resets the prefs of a
  same-account login, each profile keeping its own prefs.
- IPC `profiles`, `readProfiles`, `switchProfile`, `setHostname`, `runDiagnostics`,
  `diagnostics`.
- `ping` defaults to one ping within 3 s (was 5 within 5 s); `dns status` and `version` are
  read as JSON; netcheck's JSON is found after the "# Warning" line the real CLI prints.
- Stand-ins: accounts (profiles, switch, `login` adding one or rejoining the same, remove,
  nickname), `--hostname` shown in status, `dns status --json`, `debug derp-map`, `version
  --json`, netcheck in the real shape (and failing). Redacted fixtures from tailscale 1.104.4
  for netcheck, DNS status, the relay map and version; a second account's status.

## 0.2.0 — unreleased (delivery step 1)

Needs the shell's module API 1.2 (the handle's `resumed()`, the pages' `shown`).

- "Settings…" on Tailscale's VPN card goes to its settings page (Settings → System → Network
  → Tailscale; the provider's `settingsPage`) instead of opening a copy of the page over the
  VPN page: the module no longer contributes `network.vpn.page`. On a shell without
  `VpnProvider.settingsPage` the card has no "Settings…"; the page is in the list either way.

After the review of step 1:

- Every command runs under coreutils' timeout (reads 15 s, changes 60 s, bare `up` 60 s, login
  10 minutes; `-k 5`), commands run through pkexec too (`pkexec timeout … tailscale …`): a
  root process ends by itself. Without timeout nothing is run as administrator (the page says
  why). Never a flag on `up` or `login`.
- Cancelling a login (or its time limit) stops waiting at once, through pkexec too; a late
  exit is ignored. A pending connect shows a login URL (its output or the bus) and Disconnect
  or Cancel ends it (then `down`). A read that times out: "Not answering — state unknown",
  retried with a backoff; connect re-reads first while the state is unknown.
- Peers' and the control server's names shown as plain text, never markup.
- The entry is "Tailscale", or "Tailscale · <organisation tailnet>" — never an e-mail address
  (nor is one remembered). The fact `tailscale.exitNode` (a name) is now
  `tailscale.exitNodeInUse` (bool); no addresses in failure notifications.
- IPC `connect`/`disconnect` act as origin "network" (never a prompt), except with stand-ins.
- The slow poll runs at all times; curl missing is said once and polled instead; the socket
  falls back to /run/tailscale/tailscaled.sock; a tailscale, timeout or pkexec found on PATH
  that this user could replace is not trusted, and then nothing runs.
- Shorter texts on the page, the card and in messages (the same facts, no repetitions); the
  NixOS update note is not shown beside the update warning that says the same.

- Tailscale among the shell's VPNs: one entry in every state, with what needs you and its
  button (log in, key expired, approval, start the service, exit node offline, not installed).
- Connect, disconnect, log in (link opened in the browser and to copy, cancel, a 10-minute
  limit), log out; denied changes asked again through pkexec when you clicked, never when a
  network did; "make me the operator" with the NixOS line.
- Exit nodes in the network popup and on the page (none, suggested, own, Mullvad by country
  and city, filter), allow the local network; accept routes, accept DNS, shields up.
- The VPN card's extras (tailnet, account, this computer, key expiry, warnings, the kill switch
  note) and the module's page (also under Settings → System → Network → Tailscale) with the
  devices list.
- Live state from tailscaled's event bus (one curl), coalesced re-reads, backoff, a 60 s poll
  while it is down, a re-read after sleep; the traffic read only while the page is open.
- Facts `tailscale.connected`, `tailscale.exitNodeInUse`; setting
  `mod.tailscale.openLoginInBrowser`; IPC target `tailscale`.
- Stand-ins for systemctl, xdg-open and nmcli; the stand-in daemon can be stopped and started
  (a file); an expired key keeps a logged-in machine's prefs; a login ended while it waits
  takes its sleep with it. Suites for the live side and the module in the shell's host; a
  lock-bed test.

## 0.1.0 (stage T0)

The rules (`TailscaleRules`), their suites, the redacted fixtures and the stand-in tools.
