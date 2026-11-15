# h2s-shell-tailscale

The Tailscale module for [h2s-shell](../h2s-shell), the Quickshell desktop shell: Tailscale
listed among the shell's VPNs (connect, disconnect, log in, exit nodes), with a page of its
own for the devices and settings. The plan is the shell's `docs/plans/tailscale.md`; the
module system it plugs into is `docs/plans/modules.md`.

**Stage T0** (this state): the module's pure logic (`module/TailscaleRules.qml`), its suites,
fixtures and stand-in tools. No UI, no live processes; nothing here talks to a real
tailscaled.

## Layout

```
module/                 the module itself — what gets installed
  module.json           the manifest (id, name, version, api, tests; main, slots… later)
  qmldir                its own singletons (TailscaleRules)
  TailscaleRules.qml    pure functions: status/prefs → the VPN entry, devices, exit nodes,
                        accounts, the event bus, errors, every command's argv
  tests/                its suites (extend the shell's TestCase: `import qs.tests`)
fixtures/               redacted real outputs and synthetic ones (see fixtures/README.md)
tools/
  stand-in/tailscale    a stand-in CLI: a state machine over the fixtures
  stand-in/pkexec       a stand-in pkexec: ok / 126 / 127, logs what it was asked to run
  stand-in/curl         a stand-in for the LocalAPI event stream
  test.sh               checks the stand-ins
  redact-status.jq      turns a live `tailscale status --json` into a fixture
tests/
  run.sh                runs the module's suites headless against a shell checkout
  harness.qml           its loader while the shell has no tests/run-modules.sh
```

## Running the tests

```
flock /tmp/h2s-locktest.flock tests/run.sh      # the QML suites, headless
tools/test.sh                                   # the stand-ins
```

`tests/run.sh` needs a checkout of the shell: `H2S_SHELL_DIR` (default `../h2s-shell-wt2`).
When that checkout has `tests/run-modules.sh` (the shell's official module runner), it is
used — the module is then loaded through the real module host. Otherwise the same isolation
is built here (a private headless labwc, `env -i`, private runtime and XDG directories, no
D-Bus; `H2S_OWN_HARNESS=1` forces this way). Quickshell and the compositor are found as the
shell's own runners find them (`LOCKTEST_QS` names a Quickshell). The `flock` matters when
other test runs may share the machine.

Never run the suites with `quickshell -p` in a real session, and never point the stand-in
tests at the real `tailscale`: `tools/test.sh` runs every stand-in by its absolute path.

## Installing

Once the shell supports it: add this repository's link in the shell's Settings → Modules
(the shell clones it and loads `module/`). On NixOS the shell's `programs.h2s-shell.modules`
option will take it as a package (a flake comes later).
