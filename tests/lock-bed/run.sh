#!/usr/bin/env bash
# Runs the module's lock-bed tests (tests/lock-bed/tests/*.sh) in the shell's lock test bed:
# the real shell, started by its launcher in an invisible nested Hyprland, in module test mode,
# with this repository's module/ loaded — every program the module runs its stand-in
# (module/tests/stand-in, the manifest's testPrograms) — the shell's tests/lock/run.sh, which
# takes tests from another directory through LOCKTEST_EXTRA_TESTS. Its isolation is the test bed's (tests/lock/README.md in the shell).
#
#   tests/lock-bed/run.sh              every test here
#   tests/lock-bed/run.sh tailscale    the named ones
#
# H2S_SHELL_DIR names the shell checkout (default ../h2s-shell-wt). When other runs may share
# the machine: flock /tmp/h2s-locktest.flock tests/lock-bed/run.sh
set -uo pipefail

REPOSITORY=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd -P)
SHELL_DIR=$(cd "${H2S_SHELL_DIR:-$REPOSITORY/../h2s-shell-wt}" 2> /dev/null && pwd -P) \
    || { echo "lock-bed/run.sh: no shell checkout (set H2S_SHELL_DIR)" >&2; exit 2; }
[ -x "$SHELL_DIR/tests/lock/run.sh" ] || { echo "lock-bed/run.sh: $SHELL_DIR has no tests/lock/run.sh" >&2; exit 2; }
grep -q LOCKTEST_EXTRA_TESTS "$SHELL_DIR/tests/lock/run.sh" \
    || { echo "lock-bed/run.sh: $SHELL_DIR's tests/lock/run.sh takes no tests from outside (LOCKTEST_EXTRA_TESTS)" >&2; exit 2; }

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
    for file in "$REPOSITORY"/tests/lock-bed/tests/*.sh; do names+=("$(basename "$file" .sh)"); done
fi
LOCKTEST_EXTRA_TESTS="$REPOSITORY/tests/lock-bed/tests" exec "$SHELL_DIR/tests/lock/run.sh" "${names[@]}"
