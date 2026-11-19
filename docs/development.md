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
The shell runs them in module test mode: every program the module names comes from
`module/tests/stand-in` (the manifest's `testPrograms`), a run as administrator goes through
the stand-in `pkexec`, links are recorded (`ModuleTestKit.opened`), and `Api.system` gives
made-up facts. The live suites run many scenarios at once, each with a client of its own: its
handle is a `ScenarioHandle` (`module/tests/ScenarioHandle.qml`), which gives the stand-ins as
its programs (or a scenario's: one missing, an untrusted one, one installed later) and passes
each run as administrator to the module's real handle — the shell's one queue and the stand-in
`pkexec` — recording it (`what`, argv, limit) on the way. The client hands its `TS_FAKE_*`
environment to the run (module API 1.14: `options.environment`, taken in module test mode
only), so each scenario's runs as root see its own stand-in state. The handle's `log` keeps
`module.log`'s one line per key for its scenario alone and records the lines; `notify` goes
through the shell (recorded: `ModuleTestKit.notified`); `dataDirectory` is the scenario's own
folder. The system's and the networks' facts are the test kit's (`ModuleTestKit.setSystem`,
`setNetworks`, `setNow`); `TailscaleModuleTest` sets them only once the live suites are done,
since they are the whole runner's. `CertMoveTest` moves certificates on data homes of its own
under the test kit's temporary home. `TailscaleModuleTest` uses
the module's real handle directly; it turns the module off and on again only once the other
suites are done, since that ends every run of the module in the shell's queue.

#### NixOS

`nix` provides the pinned labwc; Quickshell is the one the `h2s-shell` launcher runs.

#### Arch

Without `nix`, labwc has to be installed; Quickshell is `qs` on `PATH`, else
`quickshell`.

### `tests/lock-bed/run.sh`

Starts the real shell in the shell's lock test bed, with this module, in module test mode:
the module's programs are its stand-ins, its runs as administrator go through the shell's
queue to the stand-in `pkexec`. The stand-ins take the test's state from the `TS_FAKE_*`
variables the test exports.
The tests are in `tests/lock-bed/tests/`.
The shell's `tests/lock/run.sh` must support `LOCKTEST_EXTRA_TESTS`.
It needs `nix`, on NixOS and on Arch: the shell's lock test bed takes its tools from it only.

### `tools/test.sh`

Checks the stand-ins. It runs each one by absolute path, so the real tools never run.

### Safety

- Never run the suites with `quickshell -p` in your own session.
- Never point the stand-in tests at the real `tailscale`.

## Stand-ins

`module/tests/stand-in/` holds the fake programs the module runs (`tailscale`, `pkexec`,
`curl`, `timeout`, `systemctl`, `openssl`); `tools/stand-in/` the two the lock bed puts on the
shell's own `PATH` (`xdg-open`, `nmcli`). None of them touches a real daemon or the network.

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
State lives in `TS_FAKE_STATE_DIR`, one directory per test. A file `user` there names the
caller for the operator's checks (it wins over `TS_FAKE_USER`); `TS_FAKE_CALLS` names a file
each call's own path is added to.

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
