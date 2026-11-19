# Limitations

## Not offered, by design

| What | Why |
|---|---|
| Renewing the key | a bare `login` disconnects and, with the same account, resets this device's settings. The page links the admin console instead. |
| Changing tags | `--advertise-tags` is a flag of `up` only, and changing tags re-authenticates. Tags are shown. |
| Changing the netfilter mode | it can break the system's firewall. It is shown. |
| `tailscale bugreport` | it uploads logs |
| Serving files and folders | `tailscaled` opens them as root at request time, following links. Existing ones are listed and can be removed. |
| Managing unix sockets, Tailscale Services, foreground `serve` | shown and counted only |
| Certificate renewal | the files are written only on "Get certificate" |
| Changing tailnet lock | init, sign, add, remove and disable belong to the tailnet's administration |
| Taildrop or certificates through pkexec | root would read or write paths long after any check |
| Opening a terminal for SSH | the shell has no terminal setting. Rows offer "Copy ssh command". |

Also not offered: Funnel over TCP, `--relay-server-static-endpoints`, `--remote-config`.

## Known gaps

- The event bus is watched without peer changes. A device's online state can be up to a minute old.
- The sender of a received file is not known. The event bus does not say.
- A user who is not the operator sees that files wait, not how many.
- Taildrop addresses the target device by its IPv4 address.
- Saving received files needs `curl`.
- "Another VPN is also on" and the card's note count a VPN whose traffic the shell does not know (a plugin VPN still activating) as one that may take all traffic.
- The shell's blocking of traffic outside a VPN does not let Tailscale through. The VPN card says so.
- The widget has no tooltip and no middle-click action.
- Nothing of the module is on the lock screen.
- A login that already runs as administrator cannot be stopped from the shell. It ends at its time limit. The page asks you to close the login page in the browser.
- A login from a logged-in account that does not finish leaves Tailscale on a new, empty profile. The page offers "Switch back".
- Serve changes go through `tailscale serve`, which reads and writes the config itself. Something added on a port between the module's plan and that write goes public with a Funnel until the check after Funnel turns it off. Writing the config through the local API with `If-Match` would close the gap, but needs root or the operator for every change.
- A failed exit node by network change is not retried for the same networks and choice while the shell runs. A restart tries it once more.
- An exit node chosen for now is kept in memory only, in the module's main. Anything that builds the main again ends it and applies the networks' choice: a restart of the shell, a reload, the module turned off and on.
- "for <network>" in the exit node chooser cannot tell an automatic exit node from one set by hand to some node: with "Automatic" any exit node in use counts as the network's.
- Without a notification daemon, failures of serve and Funnel show only on the page, those of the exit node by network only on the network's card.
