# Development

## Loading a checkout

The shell's launcher reads `H2S_SHELL_MODULE_PATH`, a colon-separated list.
Each entry is a module directory or a directory of modules.
It is searched before `${XDG_DATA_HOME:-~/.local/share}/h2s-shell/modules`.
The shell takes the first module of an id and reports later ones as duplicates.

```bash
H2S_SHELL_MODULE_PATH=<checkout>/module
```

Set it in the launcher's environment, then start the shell.
`h2s-shell ipc call modules list` shows which directory was loaded.

## Tests

Both test runners need a checkout of h2s-shell. Set `H2S_SHELL_DIR`; the default is `../h2s-shell-wt`.

```bash
tests/run.sh             # the QML suites, headless
tests/run.sh TaildropTest ServeTest    # only the named suites
tests/lock-bed/run.sh    # the real shell in the lock test bed
tools/test.sh            # the stand-ins
```

When other test runs may share the machine, wrap the runners in `flock /tmp/h2s-locktest.flock`.

### `tests/run.sh`

- Runs the suites listed under `tests` in `module/module.json`.
- Hands the module to the shell's `tests/run-modules.sh`, which loads it through the module host in a private headless compositor.
- A shell checkout without `tests/run-modules.sh` cannot run the suites: status 2, with the reason.
- The tools (Quickshell, labwc, util-linux, coreutils) are found by the shell's runner: the pinned ones through `nix` where there is a `nix` command, else those on `PATH`. Its first lines say which.
- `--log <file>` saves the output.
- Names after that run only those suites. A suite is named by its file in `module/tests/` without `.qml`.
- Exit status: 0 all passed, 1 a failure, 2 the runner could not start or a name is not a suite of the module.

The suites extend the shell's `TestCase` (`import qs.tests`).
They run the live client against the stand-ins only.

#### NixOS

`nix` provides the pinned labwc; Quickshell is the one the `h2s-shell` launcher runs.

#### Arch

Without `nix`, labwc has to be installed; Quickshell is the `qs` on `PATH`.

### `tests/lock-bed/run.sh`

Starts the real shell in the shell's lock test bed, with this module and the stand-ins.
The tests are in `tests/lock-bed/tests/`.
The shell's `tests/lock/run.sh` must support `LOCKTEST_EXTRA_TESTS`.
It needs `nix`, on NixOS and on Arch: the shell's lock test bed takes its tools from it only.

### `tools/test.sh`

Checks the stand-ins. It runs each one by absolute path, so the real tools never run.

### Safety

- Never run the suites with `quickshell -p` in your own session.
- Never point the stand-in tests at the real `tailscale`.

## Stand-ins

`tools/stand-in/` holds fake programs. None of them touches a real daemon or the network.

| Program | Does |
|---|---|
| `tailscale` | a state machine over the fixtures: accounts, `set` flags with the real refusals, approval, Taildrop, serve, `cert`, `lock status` |
| `pkexec` | asks nobody; `ok`, dismissed (126), no agent (127) or unkillable; logs what it ran |
| `curl` | the event bus and Taildrop's inbox |
| `timeout` | runs the real coreutils `timeout` |
| `systemctl` | starts and stops the stand-in daemon |
| `xdg-open` | opens nothing, logs the link |
| `openssl` | reads the stand-in certificate's end date |
| `nmcli` | answers nothing |

They are configured with `TS_FAKE_*` variables. Each script's header lists them.
State lives in `TS_FAKE_STATE_DIR`, one directory per test.

Some cases of the stand-in `tailscale`.
A scenario comes from `TS_FAKE_STATE`, else from the file `scenario` in the state dir.

| Setting | Case |
|---|---|
| scenario `fresh` | a daemon fresh from the package: no profile, no node key, WantRunning off, NoState |
| scenario `fresh-needs-login` | the same in NeedsLogin |
| `TS_FAKE_DAEMON=down`, or a file `daemon-down` in the state dir | the daemon is not running |
| file `serve-next.json` in the state dir | another client's serve change, landing when the next `funnel` runs as root |
| file `serve-fail-after-write` in the state dir | that `funnel` run fails after it wrote the config |

## Fixtures

`fixtures/` holds CLI and local API output, real and synthetic.
`fixtures/README.md` lists each file and where it comes from.

Fixtures must not identify a real tailnet. Use these placeholders:

| Kind | Placeholder |
|---|---|
| tailnet | `example-tailnet.ts.net` |
| accounts | `user1@example.com` |
| Tailscale addresses | `100.64.0.N`, `fd7a:115c:a1e0::N` |
| public endpoints | `198.51.100.0/24` |
| LANs | `192.168.x.0/24` |
| keys | zeroed, or `nodekey:peerN` |
| URLs | `…/a/REDACTED` |

`tools/redact-status.jq` turns a real `tailscale status --json` into a fixture.
Check the result by hand before adding it.
