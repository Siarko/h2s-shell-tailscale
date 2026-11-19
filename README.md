# h2s-shell-tailscale

Tailscale for the h2s-shell desktop shell.
The module lists Tailscale among the shell's VPNs and adds a settings page, a bar widget and a popup.
It works through the `tailscale` CLI and the daemon's local API.

## Features

- Connect, disconnect, log in and log out from the network popup.
- Pick an exit node, including Mullvad locations.
- Pick an exit node per Wi-Fi or Ethernet network.
- Switch, add and remove Tailscale accounts.
- Rename this device and see when its key expires.
- Turn on accepted routes, Tailscale DNS and shields up.
- Offer this computer as an exit node or subnet router.
- Run Tailscale's SSH server and web interface.
- Send and receive files with Taildrop.
- Share local ports with serve and Funnel.
- Get an HTTPS certificate for this device.
- See tailnet lock status.
- List the tailnet's devices and ping them.
- Run network diagnostics.
- Find Tailscale when it is installed or started later, without a restart.

## Requirements

| What | Needed for |
|---|---|
| h2s-shell with module API 1.23 | everything |
| `tailscale` and a running `tailscaled` | everything |
| `pkexec` and coreutils `timeout`, found by the shell | changes that need an administrator |
| `curl` | live updates and saving received files |
| `openssl` | showing a certificate's end date |

Without `curl`, the module polls Tailscale once a minute.

On NixOS, `services.tailscale.enable = true;` provides `tailscale` and `tailscaled`.

## Install

Clone the repository and link its `module` directory into the shell's module directory:

```bash
git clone https://github.com/Siarko/h2s-shell-tailscale.git h2s-shell-tailscale
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/h2s-shell/modules"
ln -s "$PWD/h2s-shell-tailscale/module" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/h2s-shell/modules/tailscale"
```

The shell's launcher looks for modules each time it starts the shell. Restart it:

```bash
h2s-shell --restart
```

Check that the module loaded:

```bash
h2s-shell ipc call modules list
```

The page is under Settings → System → Network → Tailscale.
The bar widget is not added by default. Add it in Settings → Behaviour → Bar with "＋ Add widget".

For a development checkout, see [docs/development.md](docs/development.md).

## Privileges

Reading Tailscale's state needs no privileges.
Most changes need root or Tailscale's operator. The module first tries them as you.
If Tailscale refuses, a click asks for an administrator's password through the shell's prompt,
which says that Tailscale asks and what for.
The page offers to make your user the operator, so it asks only once.
Taildrop, certificates and the exit node per network work only for the operator.

Details are in [docs/privileges.md](docs/privileges.md).

## Documentation

| File | Content |
|---|---|
| [features.md](docs/features.md) | what each part does |
| [privileges.md](docs/privileges.md) | what runs as you, what runs as root, the operator |
| [settings.md](docs/settings.md) | the setting, widget options, stored data, facts |
| [ipc.md](docs/ipc.md) | the `tailscale` IPC target |
| [architecture.md](docs/architecture.md) | file map, how state is read, programs, module test mode |
| [limitations.md](docs/limitations.md) | what is not offered and why, known gaps |
| [development.md](docs/development.md) | tests, stand-ins, fixtures |
| [CHANGELOG.md](CHANGELOG.md) | changes |
