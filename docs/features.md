# Features

What each part of the module does, from the user's side.
Who may do what is in [privileges.md](privileges.md).

## Where it shows up

| Place | Content |
|---|---|
| Network popup, VPN section | the Tailscale entry, its exit node chooser, the login link |
| VPN card (Settings → System → Network → VPN) | tailnet, account, this device, exit node, key expiry, warnings |
| Settings → System → Network → Tailscale | the module's page with everything below |
| Bar widget "Tailscale" | icon, optional text, badge, popup |

## The VPN entry

The entry is called "Tailscale", or "Tailscale · <tailnet>" for an organisation's tailnet.
It never shows an e-mail address.

Its status line reads "Off", "Starting…", "Tailnet only" or "Via <exit node>".
Within 7 days of key expiry it adds "key expires in N days".

When something needs you, the entry says so and offers one button:

| Situation | Button |
|---|---|
| logged out | Log in |
| key expired | Log in |
| waiting for an admin's approval | opens the admin console |
| `tailscaled` not running | Start |
| exit node offline for over a minute | Use none |
| locked out by tailnet lock (while connected) | Open admin console |

The entry also covers "not installed", "not trusted" and "Not answering — state unknown".
"Not trusted" means a `tailscale`, `timeout` or `pkexec` on PATH that your user could replace. Then nothing runs.

## Connection

- Connect runs a bare `tailscale up`. Disconnect runs `tailscale down`.
- Log in runs a bare `tailscale login`. The login page opens in the browser. The link can also be copied.
- A login can be cancelled. It gives up after 10 minutes.
- Log out asks for confirmation first.

## Exit node

- Choose none, the suggested node, one of the tailnet's own, or a Mullvad location.
- Mullvad locations are grouped by country, then city.
- Offline nodes are shown but cannot be chosen.
- A filter appears when the list is long.
- "Allow the local network" keeps the LAN reachable while an exit node is in use.
- A line appears when another VPN is up beside the exit node.

### By network

Mark saved Wi-Fi and Ethernet networks with "none", "automatic" or one of the tailnet's exit nodes.

- When the set of marked networks that are up changes, the module sets the exit node once.
- A choice made by hand afterwards stays until the networks change.
- A drop to no marked network shorter than 30 s does not count.
- Two marked networks up with different choices: nothing happens.
- While Tailscale is off or starting, the module waits. It never turns Tailscale on.

## Network switches

| Switch | Command |
|---|---|
| Use routes from other devices | `set --accept-routes` |
| Use Tailscale's DNS | `set --accept-dns` |
| Block incoming connections | `set --shields-up` |

## Accounts

- The account in use and its tailnet are always shown.
- "Show accounts" reads the list (`switch --list --json`). It is kept in memory only.
- Switch to another account, or remove one that is not in use.
- "Add account" runs a bare `tailscale login`. It disconnects first.
- Set a nickname for the account in use.

`tailscale login` always moves to a new, empty profile first.
Logging in again with the same account resets this device's Tailscale settings.
If a login does not finish, the page offers "Switch back" to the previous account.

## This device

- Name, rename, or go back to the system's host name.
- A name must be one DNS label: letters, digits and inner dashes, at most 63 characters.
- Tailscale addresses and MagicDNS name, copied with a click.
- Online state and home relay.
- Key expiry. A warning starts 14 days before. The page links the admin console to renew the key.

A personal tailnet is shown by its MagicDNS suffix, for example `tail1234.ts.net`.

## Devices

Each row shows name, owner, system, online or last seen, direct or relayed, and addresses to copy.
The traffic counters update while the page is open.

| Action | When |
|---|---|
| Ping | always; one ping, "direct, 4 ms" or "relayed (DERP fra), 31 ms" |
| Send file… | the device can receive files |
| Copy ssh command | the device runs Tailscale SSH |

## Sharing

- Offer this computer as an exit node.
- Offer subnet routes. A route is checked before it is sent.
- Each offer shows its approval: approved, waiting for an admin, standby, or unknown.
- The admin console's page for this machine is linked while something waits.
- IP forwarding is read from `/proc`. If it is off, the page shows the NixOS lines to fix it.
- The web interface (port 5252) with its link.

Under **More**:

- app connector
- source NAT for offered routes
- stateful filtering
- peer relay port
- posture reports
- netfilter mode and tags (read only)

Offering an exit node and using one exclude each other. The page says so and offers "Stop using it".

## SSH

- Turn Tailscale's SSH server on or off.
- Who may log in is set by the tailnet's access rules. The page links them.
- The switch is off with a reason when the tailnet does not allow SSH.
- The system's `sshd` is not touched.

## Taildrop

Needs your user to be Tailscale's operator.

- Send files to devices that can receive them. Choose files, paste absolute paths, or drop them.
- Progress is shown per file. Cancel stops the send.
- A send with no progress for 2 minutes is stopped. A send lasts 6 hours at most.
- Received files raise a notification and show "Files received" on the entry.
- Save them by hand or automatically (off by default).
- The folder defaults to `XDG_DOWNLOAD_DIR`, else `~/Downloads`.
- If the name is taken: Keep both, Replace or Leave waiting. Automatic saving never replaces.
- Received names are made safe: no separators, no hidden or leading-dash names, at most 200 bytes.
- "Open folder" opens the folder, never a file.

## Serve and Funnel

- Lists what this computer serves, with its links. "Public" marks Funnel.
- Share a local port over HTTPS on 443, 8443 or 10000, with an optional path.
- Forward a TCP port.
- Turn Funnel on or off per HTTPS share.
- Remove one share, or stop all (`serve reset`).
- Missing requirements are listed with links: connected, MagicDNS, HTTPS certificates, the Funnel attribute and port, shields up off.

Funnel applies to a whole port.
"Funnel on" asks first and names the other shares on that port.
A port that holds anything the module does not create itself is never made public by the module.
Files, folders, sockets and redirects are such things. The page says "Change this one in a terminal".

## Certificates

Needs the operator.

- "Get certificate" for this device's MagicDNS name.
- Files go to `${XDG_DATA_HOME:-~/.local/share}/h2s-shell/tailscale/certs`.
- The folder is 700. The key is 600, the certificate 644.
- The page shows the paths and, with `openssl`, the end date.
- Certificates are not renewed automatically.

## Tailnet lock

Status only: off, on and signed, or locked out.
The page shows the keys to copy and the number of trusted keys.

## Diagnostics

Run only on "Check the network".

- client version
- `netcheck`: UDP, IPv4 and IPv6, NAT, port mapping, nearest relays, captive portal
- `dns status`: MagicDNS, resolvers, split DNS, search domains
- every health warning
- an available update (shown, never installed)

"Copy diagnostics" copies it all without keys, links or addresses.

## About

- Update checks (`--update-check`).
- Automatic updates (`--auto-update`). Off with a reason where the system updates Tailscale, as on NixOS.

## Bar widget and popup

The icon is Tailscale's VPN glyph. Its colour shows the state:

| Colour | State |
|---|---|
| dim | nothing to use: not installed, service stopped, state unknown |
| plain | off |
| accent, dimmed | connecting or disconnecting |
| accent | connected |
| warning | needs you |

A small globe shows while an exit node is in use.
A badge counts received files. It shows a dot when the count is unknown.

The popup holds:

- the state with Connect, Disconnect or the button the state needs
- account and tailnet
- the exit node chooser
- this device's addresses and name
- devices, online first, with "Send file…" for the operator and "All devices…" past the limit
- received files with Save
- "Settings…" and "Admin console"

The widget and popup start no timers or processes of their own.
Widget options are in [settings.md](settings.md#bar-widget).
