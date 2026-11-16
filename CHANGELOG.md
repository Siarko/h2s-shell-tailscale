# Changelog

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
