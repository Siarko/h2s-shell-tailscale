# Privileges

Tailscale lets any user read its state.
Changes need root or the operator, a user that Tailscale lets change its settings.

## How a change runs

1. The command runs as you.
2. If Tailscale answers "Access denied" and you clicked, it runs again through pkexec.
3. The shell's polkit agent asks for an administrator's password.

A change that did not come from a click never asks for a password and never opens a browser.
This covers the shell starting a VPN with a network, and IPC calls.
Instead the entry shows that it needs you.

Buttons show a lock while changes need a password.

## The pkexec command

```
pkexec <timeout> -k 5 <seconds> <tailscale> <arguments>
```

- `pkexec`, `timeout` and `tailscale` are the absolute paths the shell found for the module
  (`module.programs`).
- The time limit ends a root process the shell cannot signal.
- Without coreutils `timeout`, nothing runs as administrator. The page says why.
- `tailscale`, `timeout` and `pkexec` must be judged trusted by the shell: owned by root and
  writable by root alone, or in the Nix store. Otherwise nothing runs.

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

Every command runs under coreutils `timeout -k 5`:

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
