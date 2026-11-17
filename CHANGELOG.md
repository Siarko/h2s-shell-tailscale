# Changelog

Current version: 0.6.0 (`module/module.json`).

## Unreleased

Needs h2s-shell with module API 1.3.

### Added

- Tailscale as one entry among the shell's VPNs, in every state.
- The entry's button for what needs you: log in, key expired, approval, start the service, exit node offline, locked out.
- Connect, disconnect, log in and log out.
- Login link opened in the browser or copied. Setting `mod.tailscale.openLoginInBrowser`.
- Exit node chooser in the network popup and on the page, with Mullvad locations and a filter.
- "Allow the local network", accepted routes, Tailscale DNS and shields up.
- Exit node per Wi-Fi or Ethernet network.
- VPN card: tailnet, account, this device, exit node, key expiry, warnings.
- Settings page under Settings → System → Network → Tailscale.
- Accounts: show, switch, add, remove, nickname.
- This device: rename, addresses, MagicDNS name, home relay, key expiry.
- Key expiry warning from 14 days, on the entry's status line within 7 days.
- Devices list with ping, traffic, "Send file…" and "Copy ssh command".
- Sharing: exit node and subnet route offers with their approval state.
- IP forwarding check with the NixOS lines to fix it.
- Web interface, app connector, source NAT, stateful filtering, peer relay, posture reports.
- Tailscale's SSH server switch.
- Update checks and automatic updates.
- Taildrop: send files, save received ones by hand or automatically.
- Serve and Funnel: share local ports over HTTPS or TCP, Funnel per share, remove, stop all.
- HTTPS certificate for this device's MagicDNS name.
- Tailnet lock status.
- Diagnostics: version, netcheck, DNS status, health warnings, "Copy diagnostics".
- "Make <user> the operator", with the NixOS line to keep it.
- Bar widget "Tailscale" with a popup and options for text, badge and device count.
- Live updates from tailscaled's event bus, with a 60 s poll and a re-read after sleep.
- Facts `tailscale.connected` and `tailscale.exitNodeInUse`.
- IPC target `tailscale`.

## 0.1.0

Internal: parsing rules, fixtures and stand-in tools. No user-visible features.
