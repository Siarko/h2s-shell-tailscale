# Settings and stored data

## Setting

One global setting, declared in `module/module.json`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `mod.tailscale.openLoginInBrowser` | bool | `true` | open Tailscale's login page in the browser; off: the link is only shown, to copy |

It is on the module's page, next to the login link.

## Bar widget

The widget type is `tailscale`. Its options live in the widget's preset.
They appear in the bar's section editor once the entry has a preset ("Customize").

| Key | Values | Default | Meaning |
|---|---|---|---|
| `text` | `none`, `state`, `exitNode` | `none` | text beside the icon |
| `badge` | bool | `true` | count of received Taildrop files on the icon |
| `devices` | 3, 5, 10, 20 | 5 | how many devices the popup lists |

The defaults are the manifest's `presetDefaults`.
The popup mode (click or hover) is the shell's, as for every popup widget.

## Stored data

The module keeps a few values in its store, `~/.config/h2s_shell/modules/tailscale.json`.
The shell's module host owns that file.

| Key | Content | Set by |
|---|---|---|
| `lastTailnet` | the last organisation tailnet's name, for the entry's name; never an e-mail address | `TailscaleClient.qml` |
| `taildrop.folder` | the save folder; absent means the default | `TaildropClient.qml` |
| `taildrop.conflict` | `rename`, `overwrite` or `skip` | `TaildropClient.qml` |
| `taildrop.autoSave` | bool | `TaildropClient.qml` |
| `exitByNetwork` | `{ <network id>: { choice, label, name } }` | `NetworkExitClient.qml` |
| `exitByNetwork.lastKey` | the set of marked networks last acted on | `NetworkExitClient.qml` |

`choice` is `none`, `auto` or an exit node's stable id. A network id is NetworkManager's profile UUID.

Certificates are written to `${XDG_DATA_HOME:-~/.local/share}/h2s-shell/tailscale/certs`.

The account list holds e-mail addresses. It is kept in memory only.

## Facts

Facts the shell's profile conditions can use:

| Fact | Type | True when |
|---|---|---|
| `tailscale.connected` | bool | Tailscale is connected |
| `tailscale.exitNodeInUse` | bool | connected and an exit node is in use |

Facts never say which exit node.
