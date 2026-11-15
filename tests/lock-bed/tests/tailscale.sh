# shellcheck shell=bash
# Tailscale's module in the real shell (sourced by the shell's tests/lock/run.sh after its
# lib.sh, through LOCKTEST_EXTRA_TESTS — see tests/lock-bed/run.sh): the launcher starts the
# shell with this repository's module/ (H2S_SHELL_MODULE_PATH) and the stand-ins as every
# program the module runs — named to it by its tools seam (H2S_TAILSCALE_TOOLS) and first on
# the shell's PATH too (so even the shell's own xdg-open and nmcli are stand-ins). Wrappers
# give the stand-ins this test's private state and logs.
#
# Checked: the module loads; the Tailscale entry appears among the VPNs (its IPC state) and in
# the network popup's VPN section (screenshot); connecting as a user who is not Tailscale's
# operator runs bare `up`, is denied and runs again through (the stand-in) pkexec; the
# exit-node chooser under the row lists the fixture's nodes; the VPN settings page opens, and
# its card's "Settings…" goes to the module's settings page (settings currentPage); and the
# lock still locks and unlocks with the module loaded.

module_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P) || abort "no module repository"
[ -f "$module_repo/module/module.json" ] || abort "no module at $module_repo/module"
standins=$module_repo/tools/stand-in
tools=$WORK/ts-tools
mkdir -p "$tools/state"
printf 'stopped\n' > "$tools/state/scenario"
echo '{"Health":{"Warnings":{}}}' > "$tools/bus.jsonl"
: > "$tools/log"
: > "$tools/pkexec.log"
: > "$tools/calls"
for program in tailscale timeout curl pkexec systemctl xdg-open nmcli; do
    cat > "$tools/$program" << WRAPPER
#!/bin/sh
# h2s-stand-in wrapper: every call logged by the path it was called by
printf '%s\n' "\$0" >> "$tools/calls"
export TS_FAKE_STATE_DIR="$tools/state" TS_FAKE_LOG="$tools/log" TS_FAKE_PKEXEC_LOG="$tools/pkexec.log" \\
    TS_FAKE_LOGIN_DELAY=1 TS_FAKE_FIXTURES="$module_repo/fixtures" TS_FAKE_BUS_FILE="$tools/bus.jsonl" \\
    TS_FAKE_BUS_END=hold TS_FAKE_BUS_HOLD=240 TS_FAKE_USER=tester
exec "$standins/$program" "\$@"
WRAPPER
    chmod +x "$tools/$program"
done
export H2S_TAILSCALE_TOOLS=$tools

stack_start --modules "$module_repo/module" --shell-path "$tools" \
    --settings '{"bar.left": [{"type": "network", "preset": ""}, {"type": "clock", "preset": ""}]}'

ts_state() { shell_ipc tailscale state 2> /dev/null; }
ts_field() { ts_state | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print(str(v).lower() if isinstance(v,bool) else v)' "$1" 2> /dev/null; }
ts_is() { [ "$(ts_field "$1")" = "$2" ]; }
module_state() {
    shell_ipc modules list | python3 -I -c '
import json, sys
modules = [m for m in json.load(sys.stdin)["modules"] if m["id"] == "tailscale"]
print(modules[0]["state"] if modules else "absent")'
}
module_errors() {
    shell_ipc modules list | python3 -I -c '
import json, sys
modules = [m for m in json.load(sys.stdin)["modules"] if m["id"] == "tailscale"]
print(json.dumps(modules[0]["errors"] + modules[0].get("warnings", []) if modules else ["absent"]))'
}

# The module comes after the bar's first frame (the host checks its files first)
# (a function: check_within re-runs its command, but arguments are expanded only once)
module_loaded() { [ "$(module_state)" = loaded ]; }
check_within 20 "the module is loaded" module_loaded
check_within 15 "its IPC answers, its provider registered" ts_is registered true
check "the tools seam names the stand-ins (H2S_TAILSCALE_TOOLS)" ts_is toolsMode seam
check_within 15 "the entry: off (the stand-in is stopped)" ts_is phase stopped
check "… not busy, no attention" test "$(ts_field state)|$(ts_field attention)|$(ts_field busy)" = "||false"
check "… changes ask for a password (not the operator)" ts_is canChange false
check_within 10 "the stream of the bus is up (the stand-in curl)" ts_is streamUp true
log "tailscale state: $(ts_state)"

# The network popup, opened by a click on the network cell: the VPN section with Tailscale
cell_rect() { shell_ipc shelltest cellRect network; }
cell_shown() { python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r.get("width",0) > 0 else 1)' "$(cell_rect)"; }
check_within 10 "the network widget is in the bar" cell_shown
rect=$(cell_rect)
move_pointer "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["x"] + r["width"] // 2)' "$rect")" \
    "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["y"] + r["height"] // 2)' "$rect")"
send_input "click left"
popup_open() { shell_ipc shelltest popupState | python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["open"] else 1)'; }
check_within 5 "a click on it opens the network popup" popup_open
log "popup: $(shell_ipc shelltest popupState)"
sleep 1
screenshot popup-tailscale-off

# Connect, as the core does (VpnManager → the provider's connect, origin "user"); the shell has
# no IPC for VpnManager, so the module's test IPC calls the provider's own connect
shell_ipc tailscale connect > /dev/null
check_within 15 "connect: the entry is connected" ts_is state activated
check "… not busy any more" ts_is busy false
check "bare \`up\`, run plainly, denied, then as root" test "$(grep -cx 'up' "$tools/log")" = 2
check "… through pkexec: the seam's timeout (60 s) around the seam's tailscale, by absolute paths" grep -qP "^pkexec\t$tools/timeout\t-k\t5\t60\t$tools/tailscale\tup\$" "$tools/pkexec.log"
check "no \`up\` with a flag, ever" test "$(grep -c '^up ' "$tools/log")" = 0

# The exit-node chooser under Tailscale's row: its header, then the list
item_rect() { shell_ipc shelltest popupItemRect "$1"; }
item_shown() { python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r.get("width",0) > 0 and r.get("height",0) > 0 else 1)' "$(item_rect "$1")"; }
if ! popup_open; then
    move_pointer "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["x"] + r["width"] // 2)' "$rect")" \
        "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["y"] + r["height"] // 2)' "$rect")"
    send_input "click left"
    check_within 5 "the network popup open again" popup_open
fi
check_within 10 "the exit-node chooser shows under Tailscale's row (slot network.vpn.row)" item_shown tailscaleExitNodeHeader
header=$(item_rect tailscaleExitNodeHeader)
log "chooser header: $header"
screenshot popup-tailscale-on
move_pointer "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["x"] + r["width"] // 2)' "$header")" \
    "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["y"] + r["height"] // 2)' "$header")"
send_input "click left"
check_within 5 "a click opens the list: \"None\" first" item_shown tailscaleExitNode-0
check "… the fixture's two exit nodes listed (a heading, then peer4 and peer10)" item_shown tailscaleExitNode-3
item_absent() { ! item_shown "$1"; }
check "… and no more (no location nodes in this fixture)" item_absent tailscaleExitNode-4
check "the IPC agrees: 2 exit nodes" ts_is exitNodes 2
screenshot popup-exit-nodes
# Closed again by a click on its cell
move_pointer "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["x"] + r["width"] // 2)' "$rect")" \
    "$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["y"] + r["height"] // 2)' "$rect")"
send_input "click left"
popup_closed() { ! popup_open; }
check_within 5 "a second click closes the popup" popup_closed

# The VPN settings page (the card with its extras), then the module's own page
check "settings openPage network_vpn" test -z "$(shell_ipc settings openPage network_vpn)"
sleep 1
screenshot settings-vpn
# Its card opened (a click on its title row, where the page lays it out first): the extras
move_pointer 700 175
send_input "click left"
sleep 1
screenshot settings-vpn-card
# The card's "Settings…" (the core's button, under the extras): it goes to the module's settings
# page "tailscale" (the provider's settingsPage) — the list selects it; no framed copy
check "… the card's extras built without an error" test "$(module_errors)" = "[]"
check "before: the VPN page is the open one" test "$(shell_ipc settings currentPage)" = network_vpn
move_pointer 244 344
send_input "click left"
settings_on_tailscale() { [ "$(shell_ipc settings currentPage)" = tailscale ]; }
check_within 5 "\"Settings…\" on the card opens the settings page \"tailscale\" (the list's selected page)" settings_on_tailscale
sleep 1.5
screenshot settings-tailscale
check "… built without an error or a warning" test "$(module_errors)" = "[]"
shell_ipc settings close > /dev/null

check "the stand-ins were called (their log)" test "$(grep -c . "$tools/log")" -gt 3
outside_calls() { grep -cv "^$tools/[a-z-]*\$" "$tools/calls"; }
check "every program the module ran was one of the seam's: each call's path under $tools" test "$(grep -c . "$tools/calls")" -gt 3 -a "$(outside_calls)" = 0
outside_pkexec() { awk -F '\t' -v dir="$tools/" '{ for (i = 2; i <= NF; i++) if ($i ~ /^\// && index($i, dir) != 1) bad++ } END { print bad + 0 }' "$tools/pkexec.log"; }
check "… and every path handed to pkexec too" test "$(outside_pkexec)" = 0
check "… and as many tailscale calls through the seam as its log has lines (none bypassed it)" \
    test "$(grep -cx "$tools/tailscale" "$tools/calls")" -ge "$(grep -cvE '^(curl|xdg-open|systemctl) |^$' "$tools/log")"

# The lock, with the module loaded and streaming
lock_by_ipc
check_within 5 "lock by IPC locks the compositor" compositor_locked
check_within 5 "the compositor confirmed it" state_is secure true
wake_prompt || fail "the prompt did not wake"
check_within 5 "the methods are known" state_is armed true
type_text "$LOCKTEST_PASSWORD"
press_key Return
check_within 10 "the password unlocks" compositor_unlocked
check "the same shell throughout (nothing crashed it)" test "$(_find_shell_pid)" = "$SHELL_PID"
check "Tailscale still connected after the lock" ts_is state activated
check "no protocol error" no_protocol_errors
