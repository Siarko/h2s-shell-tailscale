# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project

`h2s-shell-tailscale` is a module for the h2s-shell desktop shell: Tailscale as one of the
shell's VPNs, a settings page, a bar widget and a popup. QML, loaded by the shell's module
host against the shell's module API (`qs.api`); it works through the `tailscale` CLI and the
daemon's local API.

The core repository (h2s-shell) holds the tracker for both: `notes/tracker.md` there says
what is next and records the owner's decisions. This repository keeps no tracker of its own.
Read the core's `CLAUDE.md` too: its development rules apply here.

## Layout

```
module/            the module: module.json (manifest), qmldir, the QML, module/tests/ (suites)
tests/             runners: run.sh (QML suites, headless), lock-bed/ (the real shell), harness.qml
tools/stand-in/    fake tailscale, pkexec, curl, systemctl, … for the tests
tools/test.sh      checks the stand-ins; tools/redact-status.jq makes fixtures
fixtures/          CLI and local API output, redacted (fixtures/README.md lists each file)
docs/              user and developer documentation; README.md stays short
```

`docs/architecture.md` has the file map and how state is read; `docs/development.md` the
stand-ins and fixtures.

## Running the tests

Against a checkout of the core that nobody is editing while the tests run:

```
H2S_SHELL_DIR=<core checkout> tests/run.sh             # the QML suites, headless
H2S_SHELL_DIR=<core checkout> tests/run.sh TaildropTest ServeTest   # only the named suites
H2S_SHELL_DIR=<core checkout> tests/lock-bed/run.sh    # the real shell in the lock test bed
H2S_SHELL_DIR=<core checkout> tests/lock-bed/run.sh tailscale       # only the named tests
tools/test.sh                                          # the stand-ins
```

A suite is named by its file in `module/tests/` without `.qml`, a lock-bed test by its file
in `tests/lock-bed/tests/` without `.sh`; a name that does not exist is an error and nothing
runs. When other runs may share the machine, wrap them in `flock /tmp/h2s-locktest.flock …`. A
failure saying something "could not be checked within 5 s" is usually machine load: run once
more before looking into it. Never run the suites with `quickshell -p` in your own session.

## Conventions

- **Rules, clients, sections.** `*Rules.qml` (singletons) hold every decision as pure
  functions — parsing, state, every command's argv — with unit cases. `*Client.qml` only
  does I/O and holds live state. `*Section.qml` / `*Table.qml` are UI. A new feature gets
  the same split.
- **Fixtures are redacted.** No real tailnet or device names, addresses, e-mail addresses
  or keys: use the placeholders in `docs/development.md` ("Fixtures"), and check a fixture
  made with `tools/redact-status.jq` by hand.
- **Tests run the live client against the stand-ins only** (`tools/stand-in/`, configured
  with `TS_FAKE_*`); never against the real `tailscale`, `tailscaled` or `pkexec`.

## Development rules

The core's `CLAUDE.md` ("Development rules") has the full list; these matter most here.

- **The module API is ours.** If the module needs something the API lacks, stop: the API is
  extended in the core first (a minor version, a `### Module API` line in the core's
  CHANGELOG). Never build a substitute here, and never reach into the core's singletons or
  another module. — Workarounds in modules became the real API.
- **Text from Tailscale** (device and tailnet names, error output, health warnings) is shown
  as plain text (`textFormat: Text.PlainText`), on one line, length-capped; never as markup,
  never on a command line unquoted. — Names come from other people's devices.
- **Nothing asks for a password without the user's click.** The event stream, timers, a
  network change and IPC never start `pkexec`; a dismissed prompt is silent. — An unasked
  prompt trains people to type passwords into anything.
- **A failed read is "unknown", never "fine";** a late answer from a read started before the
  state changed never overwrites newer state. — The daemon restarts, logs out and changes
  accounts under the module.
- **Log on a change of outcome, not on every attempt;** reads while Tailscale is missing or
  stopped follow the backoff. — Logs filled with the same line.
- **A button's label and its effect are one decision**, made in the rules from the current
  state.
- **Live tests wait on conditions, never on fixed sleeps;** a test that cannot fail is
  deleted. — The live suites run many shell clients at once and break under load.
- **Docs and comments describe the code as it is;** user-visible strings are the few plain
  words a person would put on a control. Nothing refers to a developer's own machine, user
  name or paths; NixOS and Arch are treated together.
- **One slice = one change with its test;** run the suites it touches while iterating, all
  three runners before committing.

## Documentation

- `README.md` is short: what the module does, requirements, install, where the rest is.
- Details go in `docs/` (features, privileges, settings, IPC, architecture, limitations,
  development), in English, with "NixOS" and "Arch" subsections where the systems differ.
- Every user-visible change gets a line under **Unreleased** in `CHANGELOG.md`; the
  module's version is in `module/module.json`.
- Only commit when explicitly asked.
