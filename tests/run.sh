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
# Two ways, one result:
# - The shell has tests/run-modules.sh (its official module test runner): that is used, with
#   this repository's module/ directory — it loads the module through the real module host
#   (manifest, API, imports checked). This is the way to keep; the rest of this script then
#   goes away.
# - It has not (yet): the same isolation is built here, after the shell's tests/run-unit.sh
#   — a private headless labwc, `env -i`, a private HOME / XDG_RUNTIME_DIR / XDG dirs, D-Bus
#   addresses that lead nowhere, no new privileges — and tests/harness.qml loads the module's
#   suites by file:// URL from a private copy of the shell's tree (Quickshell binds `qs.` to
#   the directory of the root file, and the shell's tree must not be written to).
#   H2S_OWN_HARNESS=1 forces this way even when the official runner exists. This way runs
#   every suite: naming suites needs the shell's runner.
#
# Tools: as the shell's runners find them (tests/lock/resolve.sh: labwc from
# tests/lock/tools.nix through nix, Quickshell from the h2s-shell launcher or LOCKTEST_QS).
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

if [ -x "$SHELL_DIR/tests/run-modules.sh" ] && [ "${H2S_OWN_HARNESS:-0}" != 1 ]; then
    echo "run.sh: using the shell's tests/run-modules.sh ($SHELL_DIR)"
    grep -q -- '--suite' "$SHELL_DIR/tests/run-modules.sh" || [ ${#suite_arguments[@]} -eq 0 ] \
        || { echo "run.sh: $SHELL_DIR's tests/run-modules.sh cannot run named suites (no --suite); nothing was run" >&2; exit 2; }
    if [ -n "$output_copy" ]; then
        exec "$SHELL_DIR/tests/run-modules.sh" --log "$output_copy" "${suite_arguments[@]}" "$MODULE_DIR"
    fi
    exec "$SHELL_DIR/tests/run-modules.sh" "${suite_arguments[@]}" "$MODULE_DIR"
fi
[ ${#suite_arguments[@]} -eq 0 ] \
    || { echo "run.sh: the module's own harness runs every suite; naming suites needs the shell's tests/run-modules.sh. Nothing was run" >&2; exit 2; }
echo "run.sh: using the module's own harness (tests/harness.qml) with $SHELL_DIR"

LOCKTEST_DIR=$SHELL_DIR/tests/lock
PROBE_TIMEOUT=5
probe=""
work=""
temp_base=${TMPDIR:-/tmp}

cleanup() {
    [ -n "${labwc_pid:-}" ] && { kill -TERM -- "-$labwc_pid" 2> /dev/null; sleep 0.3; kill -KILL -- "-$labwc_pid" 2> /dev/null; }
    [ -n "$probe" ] && rm -rf "$probe"
    [ -n "$work" ] && rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

setup_error() {
    echo "run.sh: $*" >&2
    exit 2
}

[ "$(id -u)" != 0 ] || setup_error "do not run as root"
case "$MODULE_DIR" in *:*) setup_error "the module path cannot hold ':'" ;; esac
[ -f "$LOCKTEST_DIR/resolve.sh" ] || setup_error "$SHELL_DIR has no tests/lock/resolve.sh"
source "$LOCKTEST_DIR/resolve.sh"

# Short: a Unix socket path is limited to 107 bytes
work=$(mktemp -d /tmp/ts.XXXXXX) || setup_error "cannot create a temp dir"
chmod 700 "$work"
mkdir -p "$work/run" "$work/home" "$work/labwc" "$work/xdg/config" "$work/xdg/cache" "$work/xdg/data" "$work/xdg/state" "$work/shell"
chmod 700 "$work/run"
echo '<?xml version="1.0"?><labwc_config/>' > "$work/labwc/rc.xml"

# The shell's tree, without its history and documents, with the harness at its root
tar -C "$SHELL_DIR" --exclude=./.git --exclude=./docs --exclude=./site -cf - . | tar -C "$work/shell" -xf - \
    || setup_error "cannot copy the shell's tree"
cp "$REPOSITORY/tests/harness.qml" "$work/shell/tests-module-harness.qml" || setup_error "cannot place the harness"

isolated=(env -i PATH="$LOCKTEST_TOOLS/bin:$PATH" HOME="$work/home" XDG_RUNTIME_DIR="$work/run"
    XDG_CONFIG_HOME="$work/xdg/config" XDG_CACHE_HOME="$work/xdg/cache" XDG_DATA_HOME="$work/xdg/data"
    XDG_STATE_HOME="$work/xdg/state" LANG=en_US.UTF-8
    DBUS_SESSION_BUS_ADDRESS="unix:path=$work/run/no-session-bus"
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=$work/run/no-system-bus" LIBSEAT_BACKEND=disabled-for-test)

"${isolated[@]}" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
    "$SETPRIV" --no-new-privs setsid timeout 300 labwc -C "$work/labwc" > "$work/labwc.log" 2>&1 < /dev/null &
labwc_pid=$!
for _ in $(seq 1 100); do [ -S "$work/run/wayland-0" ] && break; sleep 0.1; done
[ -S "$work/run/wayland-0" ] || { cat "$work/labwc.log" >&2; setup_error "the headless compositor did not start"; }

started=$SECONDS
log=$work/module.log
"${isolated[@]}" H2S_TEST_MODULE_DIR="$MODULE_DIR" WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland \
    "$SETPRIV" --no-new-privs timeout 240 "$LOCKTEST_QS" -p "$work/shell/tests-module-harness.qml" > "$log" 2>&1 < /dev/null
status=$?
[ -n "$output_copy" ] && cp "$log" "$output_copy"
cat "$log"

failed=0
summary=$(grep -E -- '^.*--- .*: [0-9]+/[0-9]+ passed' "$log" | sed 's/^.*--- /--- /')
fails=$(grep -c -E '  FAIL: ' "$log")
errors=$(grep -c -E 'TypeError|ReferenceError' "$log")
expected=$(sed -n 's/^.*MODULE-SUITES-EXPECTED: \([0-9][0-9]*\).*$/\1/p' "$log" | tail -n 1)
echo
echo "Module suites ($((SECONDS - started)) s, quickshell exit $status):"
echo "$summary" | sed 's/^/  /'
[ "$fails" -gt 0 ] && { echo "  $fails check(s) FAILED"; failed=1; }
[ "$errors" -gt 0 ] && { echo "  $errors TypeError/ReferenceError line(s)"; grep -E 'TypeError|ReferenceError' "$log" | head -n 10 | sed 's/^/    /'; failed=1; }
[ "$status" = 124 ] && { echo "  quickshell timed out"; failed=1; }
[ "$status" != 0 ] && [ "$status" != 124 ] && { echo "  quickshell exited with status $status"; failed=1; }
reported=$(printf '%s\n' "$summary" | grep -c -- '^--- ')
[ "$reported" -lt "${expected:-1}" ] && { echo "  only $reported of the ${expected:-1} suites module.json lists reported"; failed=1; }
[ -n "$summary" ] || { echo "  no suite reported: quickshell did not run them"; failed=1; }
exit $failed
