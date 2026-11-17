| bus-taildrop.jsonl | synthetic, fields from ipn/backend.go (PartialFile, OutgoingFile) and feature/taildrop (Done before the rename, FilesWaiting attached; the watch's first message with SessionID) | step 4: a transfer coming in, done, FilesWaiting on a later message, outgoing progress (an older finished entry of the same name, another peer's), a message without FilesWaiting |
| files-waiting.json | synthetic, apitype.WaitingFile | GET /localapi/v0/files/ (operator only): adversarial names (".bashrc", "-rf", a U+202E name — the last refused by a real daemon) |
| stderr-access-denied-file-cp.txt | from source (cli/cli.go's advice around the LocalAPI's 403 "file access denied") | `file cp` as a non-operator |
# Fixtures

Inputs for the suites and the stand-ins. Nothing here may identify a real tailnet: tailnet
`example-tailnet.ts.net`, accounts `user1@example.com` and the like, Tailscale addresses
`100.64.0.N` / `fd7a:115c:a1e0::N`, endpoints in `198.51.100.0/24` (TEST-NET-2), LANs
`192.168.x.0/24`, keys zeroed or `nodekey:peerN`, URLs `…/a/REDACTED`. Check every fixture
you add for all of these.

Provenance:
- **real, redacted** — output of tailscale 1.104.4 on the owner's machine (read-only
  commands), passed through `tools/redact-status.jq` or redacted by hand.
- **from source** — the wording of Tailscale's own code (cmd/tailscale/cli, ipn), with
  example values.
- **synthetic** — made for the tests, in the shape the source describes.

| File | Provenance | What |
|---|---|---|
| status-running.json, -stopped, -starting, -needs-login, -needs-machine-auth, -exit-node, -exit-node-offline, -health-warnings, -update-available | real, redacted (¹) | `status --json` in each state |
| status-key-expiring.json, status-key-expired.json | real, redacted; Self.KeyExpiry set by hand (2026-11-18 / 2026-11-01) | key expiry around "now" = 2026-11-15 |
| status-rich.json | synthetic | 15 peers: direct, idle, relayed, peer-relay, offline with an expired key, shared in from another tailnet, a sharee, an offline own exit node, an IPv4+IPv6 subnet router, a subnet route equal to a LAN (192.168.1.0/24), six Mullvad-style exit nodes with Location (current: Stockholm) |
| prefs-running.json, -stopped, -logged-out, -exit-node | real, redacted | `debug prefs` (keys zeroed as for a non-root reader) |
| status-fresh.json, status-fresh-needs-login.json, prefs-fresh.json | synthetic, in the shape of status-needs-login / prefs-logged-out (fields as 1.104.4's ipnstate and ipn/prefs.go) — not captured from a fresh install | a daemon fresh from the package: no profile, no node key, WantRunning and LoggedOut off; BackendState NoState or NeedsLogin (the stand-in scenarios "fresh", "fresh-needs-login") |
| prefs-rich.json | synthetic (from prefs-running) | an operator, an advertised exit node and route, the Mullvad exit node |
| status-sharing.json, prefs-sharing.json | synthetic (from status-running / prefs-running), fields from tailscale 1.104.4's ipn/prefs.go and ipnstate | step 3: an advertised exit node (not approved), three routes — 192.168.50.0/24 approved and primary, 10.20.0.0/16 approved but not primary (standby), 2001:db8:1::/48 pending —, tags asked and applied, SSH and the web interface on, stateful filtering on, an app connector, posture, a relay port, an unknown field |
| exit-node-list.txt | real, redacted | `exit-node list` |
| exit-node-suggest.txt, exit-node-suggest-none.txt | from source (cli/exitnode.go) | `exit-node suggest` |
| switch-list.txt, switch-list.json | synthetic, in the shape of cli/switch.go | `switch --list` (table, `--json`) |
| bus-lines.jsonl | synthetic, fields from ipn/backend.go | one IPN bus message per line (LocalAPI watch-ipn-bus): every Notify field the module reads, and one it does not know |
| bus-pretty.txt | synthetic | the same, pretty-printed as `debug watch-ipn` prints (tab-indented) |
| stderr-access-denied-set.txt, stderr-access-denied-switch-list.txt | real | the denial for a non-operator |
| stderr-access-denied-logout.txt, stderr-access-denied-file.txt | synthetic: the real frame, the 403 texts recalled from the LocalAPI source (not verified) | logout / file get denied |
| stderr-not-running.txt | real | daemon not running (systemd variant) |
| stderr-not-running-refused.txt | synthetic, wording recalled from the CLI's connection diagnostics (not verified) | socket there, refusing |
| stderr-up-accidental-revert.txt | real | `tailscale up --<flag>` on a machine with a non-default setting |
| stderr-needs-login.txt | synthetic, wording from cli/switch.go ("Logged out.") | logged out |
| stderr-timeout.txt | from source (cli/up.go) | `up --timeout` running out |
| stderr-switch-no-profile.txt | from source (cli/switch.go) | an unknown account |
| login-output.txt, machine-auth-output.txt | from source (cli/up.go) | what `login` / `up` print while waiting |
| ping-direct.txt, ping-peer-relay.txt, ping-timeout.txt | synthetic, formats from cli/ping.go | `ping` |
| netcheck.json | synthetic, fields of net/netcheck's Report (recalled, not verified) | `netcheck --format=json` |
| netcheck-real.json | real, redacted (1.104.4; regions cut to six, the public address 198.51.100.77) | `netcheck --format=json` as it really prints: a "# Warning" comment line, then the JSON |
| derp-map.json | real shape, cut to six regions, node host names example.com | `debug derp-map` (region ids → codes and names) |
| dns-status.json | real, redacted (the split-DNS domain example.com, its resolver 192.168.1.53, Tailscale's 192.0.2.53) | `dns status --json` |
| version.json | real | `version --json` |
| status-running-work.json, status-key-expiring-work.json | derived from status-running / -key-expiring: tailnet "example.org", suffix example-org.ts.net, login user1@example.org | the second account (stand-in profile c3d4) |
| status-serve.json | derived from status-running: Self's CapMap (and Capabilities) add "https", "funnel" and "https://tailscale.com/cap/funnel-ports?ports=443,8443,10000"; CertDomains ["self.example-tailnet.ts.net"] (cap names from 1.104.4's tailcfg/nodecap, CheckFunnelPort's attribute format) | step 5: the stand-in scenario "serve" (HTTPS certs and Funnel enabled) |
| serve-empty.json | real (1.104.4, `serve status --json` with nothing served) | `{}` |
| serve-proxy.json | synthetic, shape from 1.104.4's ipn/serve.go (ServeConfig, MarshalIndent: sorted keys, omitempty) | HTTPS 443: "/" → proxy http://127.0.0.1:3000, "/api" → http://127.0.0.1:8080 |
| serve-funnel.json | synthetic, shape from 1.104.4's ipn/serve.go | HTTPS 443 proxy with AllowFunnel true; HTTPS 8443 text "hello" with AllowFunnel false (present, off) |
| serve-tcp.json | synthetic, shape from 1.104.4's ipn/serve.go | TCP 2222 → 127.0.0.1:22; TLS-terminated TCP 5432 → 127.0.0.1:5432 (TerminateTLS self.example-tailnet.ts.net) |
| serve-path.json | synthetic, shape from 1.104.4's ipn/serve.go | HTTPS 443: "/files/" → path /srv/share, "/" → path /home/user1/index.html (served only as root: ipn/localapi/serve.go) |
| serve-rich.json | synthetic, shape from 1.104.4's ipn/serve.go | what the module only shows: HTTP 80 proxy plus a Redirect handler, a Foreground session (HTTPS 10000), Services "svc:example" (TCP + Web), an unknown top-level "FutureField" (the stand-in refuses to change it) |
| lock-disabled.json | real, redacted (1.104.4, `lock status --json` with tailnet lock off; keys replaced by …0001) | lock off |
| lock-signed.json | synthetic, shape from 1.104.4's cmd/tailscale/tslockjsonv1 and feature/tailnetlock/tslockjsonv1/status.go (zeroed keys, Head and signatures) | lock on, this node signed: two trusted keys (one this node's), a visible peer, FilteredPeers [] |
| lock-locked-out.json | synthetic, same shapes | lock on, NodeKeySigned false: three trusted keys (one a pre-auth key), one filtered (locked-out) peer |

(¹) The redaction set every non-zero time to 2026-01-01; in these files Self.KeyExpiry was
moved to 2027-05-01 by hand, so that "now" = 2026-11-15 does not read as an expired key.
Peers keep the redacted times.

The synthetic status, prefs, bus, switch and netcheck files were written by a one-off
Python script (not kept); edit them by hand from now on.
