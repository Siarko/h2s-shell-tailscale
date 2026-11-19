# Privileges

Tailscale lets any user read its state.
Changes need root or the operator, a user that Tailscale lets change its settings.

## How a change runs

1. The command runs as you.
2. If Tailscale answers "Access denied" and you clicked, the module asks the shell to run it
   again as administrator (the shell's `module.privileged`).
3. The shell runs it through pkexec, one password question at a time. Its polkit prompt
   says who asks and what for: "Module: Tailscale" and the action in a few words
   ("Authorization: Connect"); the exact command is one click away. With another polkit
   agent the shell sends a notification with the same two lines just before.

A change that did not come from a click never asks for a password and never opens a browser.
This covers the shell starting a VPN with a network, and IPC calls.
Instead the entry shows that it needs you.

Buttons show a lock while changes need a password.

## The pkexec command

The shell builds it:

```
pkexec <timeout> -k 3 <seconds> <tailscale> <arguments>
```

- `pkexec` and `timeout` are the shell's own, found and checked by the shell.
  NixOS: the setuid wrapper `/run/wrappers/bin/pkexec`. Arch: `/usr/bin/pkexec`.
- `tailscale` is the absolute path the shell found for the module (`module.programs`).
  The module passes it only when the shell judged it trusted: owned by root and writable
  by root alone, or in the Nix store. Otherwise nothing runs at all.
- The time limit ends a root process the shell cannot signal.
- When the shell has no trusted pkexec or `timeout`, nothing runs as administrator. The
  page says why.
- A dismissed prompt shows nothing. A run that was not allowed is told once, by the shell.
- While the screen is locked nothing asks for a password; click again after unlocking.

The words the prompt shows for each action:

| Action | Prompt says |
|---|---|
| connect, disconnect | Connect, Disconnect |
| log in, add an account, log out | Log in, Add an account, Log out |
| exit node (choose, none, automatic) | Change the exit node |
| local network beside the exit node | Allow the local network, Block the local network |
| accepted routes | Accept routes, Ignore routes |
| Tailscale DNS | Use Tailscale DNS, Ignore Tailscale DNS |
| shields up | Block incoming connections, Allow incoming connections |
| SSH server | Start the SSH server, Stop the SSH server |
| web interface | Start the web interface, Stop the web interface |
| exit node offer | Offer an exit node, Stop offering an exit node |
| offered routes | Change offered routes |
| app connector | Offer an app connector, Stop the app connector |
| source NAT | Turn on source NAT, Turn off source NAT |
| stateful filtering | Turn on stateful filtering, Turn off stateful filtering |
| posture reports | Report device posture, Stop posture reports |
| peer relay | Run a peer relay, Turn off the peer relay |
| automatic updates | Turn on automatic updates, Turn off automatic updates |
| update checks | Check for updates, Stop update checks |
| this device's name | Rename this device |
| the account's nickname | Name the account |
| operator | Become the operator, Give up the operator role |
| accounts | List accounts, Switch account, Remove an account |
| serve and Funnel | Share a port, Share a port on the internet, Stop a share, Turn on Funnel, Turn off Funnel, Stop every share |

## What may run through pkexec

Only after a click, and only when Tailscale refused it as you:

| Command | Used for |
|---|---|
| `up`, `down` | connect, disconnect |
| `login` | log in, add an account |
| `logout` | log out |
| `set …` | exit node, switches, hostname, nickname, operator, sharing, SSH, web interface, More, updates |
| `switch <id>`, `switch remove <id>` | switch or remove an account |
| `switch --list --json` | read the account list |
| `serve …`, `funnel …`, `serve reset` | serve and Funnel |

## What never runs through pkexec

| What | Runs as |
|---|---|
| `status --json`, `debug prefs`, `exit-node suggest` | you |
| the event bus (`curl` on the local API socket) | you |
| `netcheck`, `dns status`, `debug derp-map`, `version`, `ping` | you |
| `serve status --json`, `lock status --json` | you |
| reading `/proc/sys/net/ipv4/ip_forward` and `/proc/sys/net/ipv6/conf/all/forwarding` | you |
| Taildrop: `file cp`, saving received files | you, operator only |
| `cert` | you, operator only |
| exit node by network | you, operator only |
| `systemctl start tailscaled.service` | you; systemd asks polkit itself |

Taildrop and certificates never run as root.
A root `file cp` would open the chosen paths long after any check.
A root save or `cert` would leave root-owned files in your folders.

The module writes no sysctl and changes no system file.

## Time limits

Every command has a time limit. What runs as you goes through the shell's command runner:
past the limit the command gets TERM, and KILL 5 s later. What runs as administrator has the
shell's `timeout`, `-k 3`, inside pkexec.

| Kind | Limit |
|---|---|
| reads | 15 s |
| changes | 60 s |
| bare `up` | 60 s |
| `login` | 10 minutes |
| `netcheck` | 30 s |
| `ping` | 10 s |
| `cert` | 180 s |
| Taildrop send | 6 hours |
| Taildrop save, per file | 600 s |

After 60 s a bare `up` stops waiting. The daemon keeps trying by itself. Disconnect stops it.

## The operator

"Make <user> the operator" on the page runs `set --operator=<user>`. It asks for a password once.

The operator may then, without a password:

- connect, disconnect and change settings
- run Tailscale's SSH server
- offer this computer as an exit node or its networks as routes
- change DNS
- log out or switch accounts
- use Taildrop, certificates and the exit node by network

The operator is a setting of each account.
Logging in again with the same account resets it.

To keep it on NixOS, the page shows a line to copy:

```nix
services.tailscale.extraSetFlags = [ "--operator=<user>" ];
```

"Stop being the operator" runs `set --operator=`.
