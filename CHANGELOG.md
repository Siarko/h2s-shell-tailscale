# Changelog

## 0.2.0 — unreleased (delivery step 1)

Needs the shell's module API 1.1.

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
- Facts `tailscale.connected`, `tailscale.exitNode`; setting
  `mod.tailscale.openLoginInBrowser`; IPC target `tailscale`.
- Stand-ins for systemctl, xdg-open and nmcli; the stand-in daemon can be stopped and started
  (a file); an expired key keeps a logged-in machine's prefs; a login ended while it waits
  takes its sleep with it. Suites for the live side and the module in the shell's host; a
  lock-bed test.

## 0.1.0 (stage T0)

The rules (`TailscaleRules`), their suites, the redacted fixtures and the stand-in tools.
