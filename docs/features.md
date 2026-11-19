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
| a daemon fresh from the package (no node key) | Log in |
| key expired | Log in |
| waiting for an admin's approval | opens the admin console |
| `tailscaled` not running | Start |
| `tailscale` not installed | Check again |
| not trusted | Check again |
| exit node offline for over a minute | Use none |
| locked out by tailnet lock (while connected) | Open admin console |

The entry also covers "Not answering — state unknown".
"Not trusted" means the `tailscale` the shell found on PATH could be replaced by your user. Then nothing runs.

### Looking again

Tailscale may be installed, fixed or started while the shell runs.
The module finds it without a restart of the shell.

- While Tailscale is not installed, not trusted or its service is not running, the module looks again by itself.
- The first look comes after 5 s. The wait doubles up to 60 s.
- Opening the page, the bar popup, the network popup or the VPN card looks again at once, at most every 2 s. It also starts the wait over.
- "Check again" looks at once. It is the entry's button while Tailscale is not found.
- The page also shows "Check again" while the service is down, the state is not readable, or Tailscale does not answer.
- The IPC call `recheck` does the same.

### When a click fails

A failed Connect, Disconnect, Log in or Start puts its reason on the entry's status line.
The entry's button stays the one its state needs.
A notification says it too, if a notification daemon runs.

- The reason goes when the state changes, a change succeeds, a connect starts, or you press the entry's button again.
- The first read after the failure checks it. If Tailscale is connected by then, the reason goes.
- A time limit or a bare exit status has no words of its own. Then the line shows the daemon's own error, or a health warning that cuts the connection.
- A refused or cancelled Start says "Not started."
- A service that stops within 30 s of Start says "Tailscale stopped right after starting."
- Connect or Disconnect while the state is unknown reads first and then acts. If the state stays unknown, the line says "Couldn't read Tailscale's state."
- Only clicks do this. A connect or disconnect from the shell or the IPC gives a notification only. If it needs a password, the entry shows a button.
- Failures of the exit node by network and of serve changes never use the entry's status line.

Text from Tailscale is shown as plain text: one line, `<`, `>` and `&` as look-alikes.
On the status line and in notifications, IP addresses show as `[address]`.

## Connection

- Connect runs a bare `tailscale up`. Disconnect runs `tailscale down`.
- Log in runs a bare `tailscale login`. The login page opens in the browser. The link can also be copied.
- A login can be cancelled. It gives up after 10 minutes. Cancelled while the password is asked, it says "Login cancelled."
- Log out asks for confirmation first.
- A daemon in NoState with a node key and WantRunning off counts as off. Connect runs `tailscale up`.

## Exit node

- Choose none, the suggested node, one of the tailnet's own, or a Mullvad location.
- Mullvad locations are grouped by country, then city.
- Offline nodes are shown but cannot be chosen.
- A filter appears when the list is long.
- "Allow the local network" keeps the LAN reachable while an exit node is in use.
- A line appears when another VPN that takes all traffic (or may) is up beside the exit node, or one whose routes overlap the tailnet or the subnet routes in use. Any other split VPN does not count.

### By network

Mark saved Wi-Fi and Ethernet networks with "none", "automatic" or one of the tailnet's exit nodes.

- When the set of marked networks that are up changes, the module sets the exit node once.
- A choice made by hand afterwards stays until the networks change.
- A drop to no marked network shorter than 30 s does not count.
- While Tailscale is off or starting, the module waits. It never turns Tailscale on.
- It runs as an automatic change: never a password prompt. It waits while another change runs or Serve checks a Funnel.

A choice that cannot be applied stays open. It is applied once the reason goes:

| Reason | Shown on the page |
|---|---|
| the chosen node is offline or gone | The chosen exit node is not available |
| your user is not the operator | Needs the operator |
| this computer offers itself as an exit node | why using one is refused |
| two marked networks up want different nodes | Two networks want different exit nodes |
| the change failed | Tailscale's error |

- Each open choice gives one notification, "Exit node for this network". The same networks and choice never notify twice.
- A failed change is not tried again for the same networks and choice. It is tried again when the networks change, and once after a restart of the shell.
- An exit node picked by hand while a choice is open ends it. The pick stays until the networks change, also across a restart.
- The open choice is kept in the store under `exitByNetwork.held`.

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
- Received files raise a notification (the names on one line, as plain text) and show "Files received" on the entry.
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
Files, folders, sockets and redirects are such things.
So are the ports of terminal sessions (`serve` without `--bg`) and of Tailscale Services.
The page says "Change this one in a terminal".

- A new share on a terminal session's port is refused: "Port N is in use".
- A Funnel turned on in a terminal session counts as public.

### The check after Funnel

`tailscale serve` reads and writes the config itself, after the module planned the change.
Through pkexec, that happens after the password dialog.
So after Funnel goes on, the module reads the config again.
If the port then holds something the module would not make public, it turns Funnel off at once.

| Outcome | Message |
|---|---|
| turned off | Funnel off. Something else is on port N. |
| turning off failed | Couldn't turn Funnel off on port N. |
| turning off needs a password, and the click is over | Port N is public with something else on it. Turn Funnel off on Tailscale's page. |
| the config could not be read | Couldn't check port N. Funnel may still be on. |
| nothing the module can send turns it off | Port N is public. Turn Funnel off in a terminal. |

- The message shows on the page and as a notification titled "Funnel".
- Right after the click, turning Funnel off uses the click's origin. A click may ask for the password again.
- No other serve change starts during the check.
- If another change holds the lock, the check waits for it and tries again. After 5 tries it gives up with "Couldn't turn Funnel off".
- A check that waited never asks for a password. When turning Funnel off needs one, it says so.
- While Funnel is still on, the Serve section shows "Turn off Funnel". The password is asked at that click.
- A dismissed password prompt shows nothing; the button stays.

## Certificates

Needs the operator.

- "Get certificate" for this device's MagicDNS name.
- Files go to `${XDG_DATA_HOME:-~/.local/share}/h2s-shell/module-data/tailscale/certs`, in the module's data folder.
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
