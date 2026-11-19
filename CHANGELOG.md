# Changelog

Current version: 0.6.0 (`module/module.json`).

## Unreleased

Needs h2s-shell with module API 1.31.

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
- Tailscale installed or started later is found without a restart. "Check again" and IPC `recheck`.
- A failed Connect, Disconnect, Log in or Start shows its reason on the entry's status line.
- A daemon fresh from the package offers Log in.
- Funnel turned off again when something else landed on its port. A notification says so. When that needs a password after the click is over, "Turn off Funnel" asks for it on the page.
- Exit node by network: an open choice is applied once its node is back or you become the operator.
- Exit node by network: one notification per change. A pick by hand while a choice is open stays.
- IPC `state` fields `failure`, `backendState`, `haveNodeKey`, `wantRunning`, `loggedOut`, `tools`.
- Parsing rules, fixtures and stand-in tools for the tests.

### Changed

- Text from Tailscale shows as plain text. Addresses on the status line and in notifications show as `[address]`.
- Read failures are logged once per change, not on every try.
- Large tailnets are read: an answer up to 32 MB. A longer one counts as a failed read, logged as "The answer was too long."
- Reads while Tailscale is missing or stopped follow a backoff from 5 s to 60 s.
- Funnel is refused on ports of terminal sessions and Tailscale Services.
- The programs it runs (`tailscale`, `timeout`, `curl`, `systemctl`, `openssl`) are the ones the shell finds and judges. Only `tailscale` must be one your user cannot replace: it is the one run as administrator.
- Changes that need an administrator run through the shell: its password prompt says "Module: Tailscale" and what for, for example "Authorization: Connect". A change that is not allowed is told by the shell; for Connect, Disconnect and Log in "Not allowed." also shows on the entry, and for a share or Funnel in the Serve section. A run the shell refuses before asking says why in plain words.
- A login cancelled while it waits for the password says "Login cancelled." Only one already running as administrator says it runs on until its time limit.
- Links and the Taildrop folder open through the shell.
- IP forwarding, the download folder and the data folder come from the shell's system facts.
- IPC `state`: `testMode` in place of `toolsMode`; `tools` names `tailscale`, `timeout`, `curl`, `systemctl`.
- Commands run through the shell's command runner, each with its time limit. The card no longer warns when coreutils `timeout` is missing: the shell then keeps the limits itself, but it can stop only the command it started, not what that command started in turn. Getting a certificate and saving Taildrop files keep their own `timeout` where it is found, so those end on time either way.
- The popup shows as many devices as the preset of the bar entry that opened it, as the shell tells it.
- Certificates are kept in the module's data folder (`…/h2s-shell/module-data/tailscale/certs`). Certificates got before stay in `…/h2s-shell/tailscale/certs`; they are not moved.
- A notification for received files lists the names on one line, separated by commas, as plain text.
- "Another VPN is also on" and the card's note about two VPNs count only VPNs that take all traffic (for the exit node) or bring their own DNS (for Tailscale's DNS). A split VPN without its own DNS gets a warning only when its routes overlap the tailnet or the subnet routes Tailscale carries.
- The user, the host name, the local networks and the home folder come from the shell's facts; the module runs no `id`, `ip addr` or read of `/proc` of its own.
- The exit node per network waits until the shell has read the networks whole, not merely until it lists one.
- Tailscale's entry tells the shell what it does with the traffic: a full tunnel through an exit node, its DNS, the networks it carries. What it cannot know whole (the peers not read yet, more than 256 routes, DNS with MagicDNS off) it leaves unknown.
- Log lines through the shell's module log: a changed reason reads "failed: <reason>" again rather than "still failing, now: <reason>".
- Its row in the network popup and its part of the VPN card are the manifest's `anchors` (the places under its row and in its opened card) instead of `slots`; the shell no longer lists them as deprecated.
- Sizes, times ("5 min ago") and addresses use the shell's helpers; the state follows the shell's minute clock, and an exit node's offline grace ends on time.
- "Send file…" in the bar popup stays in the popup: the shell's file chooser, then a row under the device with the files, Send and "×", then the shell's progress bar with Cancel and the result (the bar sliding while no size is known, full in the success colour when sent, in the danger colour when the send failed). Each device keeps its own files. The settings window no longer opens.
- Taildrop's files and its folder for received files are chosen in the shell's file chooser instead of the module's own dialogs.
- The exit node per network is set on the network's own card (Settings → System → Network, a saved Wi-Fi or Ethernet network, opened): "Tailscale exit node". While the network routes through an exit node (a node or "Automatic", not "No exit node"), the card's name line shows the exit-node mark, with the choice in the shell's tooltip. The table on the Tailscale page is gone. Choices made before are kept.
- A choice in the exit node chooser is for now, once Tailscale made the change (not when it failed or the password prompt was dismissed): it wins over the networks' choices until "Default", a wake from sleep or a restart, and the network's choice then applies again; with no network's choice up, no exit node is used. The chooser shows "Default" while a choice is for now, with what it brings back, and its header says "for now" or "for <network>" (only while that network's exit node is still the one in use).
- Exit node names from other devices show on one line: line breaks and invisible direction marks are dropped.

### Removed

- The test seams `H2S_TAILSCALE_TOOLS`, `H2S_TAILSCALE_FORWARDING_DIR`, `H2S_TAILSCALE_DOWNLOAD_DIR`, `H2S_TAILSCALE_CERT_DIR`. Tests use the shell's module test mode; the stand-ins are in `module/tests/stand-in`.
