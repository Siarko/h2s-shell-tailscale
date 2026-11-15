# Changelog

## 0.2.0 — unreleased (delivery step 1)

Needs the shell's module API 1.2 (the handle's `resumed()`, the pages' `shown`).

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
