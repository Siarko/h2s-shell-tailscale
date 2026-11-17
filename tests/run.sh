#!/usr/bin/env bash
# Runs the module's QML suites (module/module.json "tests") headless, against a checkout of
# h2s-shell (they extend its TestCase and run in its Quickshell).
#
#   tests/run.sh                                 every suite, against $H2S_SHELL_DIR
#                                                (default: ../h2s-shell-wt)
#   tests/run.sh TaildropTest ServeTest          only the named ones (a suite's file in
#                                                module/tests/ without ".qml")
#   tests/run.sh --log <file> [<suite>…]         the output also saved to <file>
#
# The runner is the shell's tests/run-modules.sh, given this repository's module/ directory:
# it loads the module through the real module host (manifest, API, imports checked) in the
# shell's private headless compositor, with the tools the shell's runners take (the pinned
# ones through nix where there is a `nix` command, else those on PATH; its first lines say
# which). A shell checkout without that runner cannot run the suites: status 2.
#
# When other runs may share the machine: flock /tmp/h2s-locktest.flock tests/run.sh
#
# Exit status: 0 every suite passed; 1 a check FAILed, a TypeError / ReferenceError was
# printed, a suite did not compile or report, Quickshell exited non-zero or timed out, no
# suite reported; 2 the runner could not be set up, or a name is not a suite of the module
# (nothing runs then).
set -uo pipefail

REPOSITORY=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
MODULE_DIR=$REPOSITORY/module
SHELL_DIR=${H2S_SHELL_DIR:-$REPOSITORY/../h2s-shell-wt}
SHELL_DIR=$(cd "$SHELL_DIR" 2> /dev/null && pwd -P) || { echo "run.sh: no shell checkout at ${H2S_SHELL_DIR:-../h2s-shell-wt} (set H2S_SHELL_DIR)" >&2; exit 2; }
[ -f "$SHELL_DIR/tests/TestCase.qml" ] || { echo "run.sh: $SHELL_DIR is not an h2s-shell checkout (no tests/TestCase.qml)" >&2; exit 2; }

output_copy=""
if [ "${1:-}" = --log ]; then
    output_copy=${2:-}
    [ -n "$output_copy" ] || { echo "run.sh: --log needs a file" >&2; exit 2; }
    shift 2
fi
# What is left names suites: given to the shell's runner, which knows the module's list
suite_arguments=()
for name in "$@"; do
    case "$name" in -*) echo "usage: tests/run.sh [--log <file>] [<suite>…]" >&2; exit 2 ;; esac
    suite_arguments+=(--suite "$name")
done

# The stand-ins first on PATH, whatever runs a program by name (the shell's Api.openUrl runs
# xdg-open): the module itself takes them through its tools seam under the module runner
export PATH="$REPOSITORY/tools/stand-in:$PATH"

[ -x "$SHELL_DIR/tests/run-modules.sh" ] \
    || { echo "run.sh: $SHELL_DIR has no tests/run-modules.sh (the shell's module test runner, which runs these suites); nothing was run" >&2; exit 2; }
echo "run.sh: using the shell's tests/run-modules.sh ($SHELL_DIR)"
grep -q -- '--suite' "$SHELL_DIR/tests/run-modules.sh" || [ ${#suite_arguments[@]} -eq 0 ] \
    || { echo "run.sh: $SHELL_DIR's tests/run-modules.sh cannot run named suites (no --suite); nothing was run" >&2; exit 2; }
if [ -n "$output_copy" ]; then
    exec "$SHELL_DIR/tests/run-modules.sh" --log "$output_copy" "${suite_arguments[@]}" "$MODULE_DIR"
fi
exec "$SHELL_DIR/tests/run-modules.sh" "${suite_arguments[@]}" "$MODULE_DIR"
