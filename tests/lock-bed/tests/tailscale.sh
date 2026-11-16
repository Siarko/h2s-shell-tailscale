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
# its card's "Settings…" goes to the module's settings page (settings currentPage); step 2 on
# that page: the accounts read (through pkexec) and listed, a switch to the other account that
# the page and the entry follow, renaming this device, a key about to expire (a warning, the admin console), a
# netcheck run and the diagnostics section opened by a click; step 3: a rename while disconnected
# (shown as set, "the tailnet shows it after connecting"), a route and the exit node offered through
# pkexec (waiting for approval, the route kept beside the exit node, approved by the stand-in's
# admin), the forwarding warning from the bed's fake /proc (H2S_TAILSCALE_FORWARDING_DIR), SSH on,
# screenshots of This device, Sharing and SSH; and the lock still locks and
# unlocks with the module loaded.

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
# The fixtures, copied: the key-expiring one gets a key that expires in 3 days from now (the
# fixture's own date is fixed; the shell reads the real clock)
cp -r "$module_repo/fixtures" "$tools/fixtures"
for file in status-key-expiring.json status-key-expiring-work.json; do
    sed -i "0,/\"KeyExpiry\": \"[^\"]*\"/s//\"KeyExpiry\": \"$(date -u -d '+3 days' +%Y-%m-%dT%H:%M:%SZ)\"/" "$tools/fixtures/$file"
done
for program in tailscale timeout curl pkexec systemctl xdg-open nmcli; do
    cat > "$tools/$program" << WRAPPER
#!/bin/sh
# h2s-stand-in wrapper: every call logged by the path it was called by
printf '%s\n' "\$0" >> "$tools/calls"
export TS_FAKE_STATE_DIR="$tools/state" TS_FAKE_LOG="$tools/log" TS_FAKE_PKEXEC_LOG="$tools/pkexec.log" \\
    TS_FAKE_LOGIN_DELAY=1 TS_FAKE_FIXTURES="$tools/fixtures" TS_FAKE_BUS_FILE="$tools/bus.jsonl" \\
    TS_FAKE_BUS_END=hold TS_FAKE_BUS_HOLD=240 TS_FAKE_USER=tester
exec "$standins/$program" "\$@"
WRAPPER
    chmod +x "$tools/$program"
done
export H2S_TAILSCALE_TOOLS=$tools
# IP forwarding as the bed's /proc would say it (the forwarding seam): IPv4 off, IPv6 on
mkdir -p "$tools/forwarding"
echo 0 > "$tools/forwarding/ipv4"
echo 1 > "$tools/forwarding/ipv6"
export H2S_TAILSCALE_FORWARDING_DIR=$tools/forwarding

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
# The card's "Settings…" (the core's button, under Disconnect): it goes to the module's settings
# page "tailscale" (the provider's settingsPage) — the list selects it; no framed copy
check "… the card's extras built without an error" test "$(module_errors)" = "[]"
check "before: the VPN page is the open one" test "$(shell_ipc settings currentPage)" = network_vpn
# Found where it is, not at fixed coordinates: the shell's `settings itemRect` (in the window)
# plus the window's place from the compositor
settings_rect() { shell_ipc settings itemRect "$1"; }
settings_window_at() { hyprctl -j clients | python3 -I -c '
import json, sys
windows = [c for c in json.load(sys.stdin) if c.get("title") == "Settings"]
print(json.dumps(windows[0]["at"] if windows else None))'; }
item_on_screen() { python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r.get("width",0) > 0 else 1)' "$(settings_rect "$1")"; }
check_within 5 "the card's \"Settings…\" is shown (profileSettings)" item_on_screen profileSettings
settings_button=$(settings_rect profileSettings)
primary_button=$(settings_rect profilePrimary)
window_at=$(settings_window_at)
log "Settings… $settings_button, Disconnect $primary_button, window at $window_at"
# Under the primary button (Disconnect), on its right edge
check "… under Disconnect, right-aligned with it" python3 -I -c '
import json, sys
settings, primary = json.loads(sys.argv[1]), json.loads(sys.argv[2])
sys.exit(0 if settings["y"] >= primary["y"] + primary["height"]
         and abs((settings["x"] + settings["width"]) - (primary["x"] + primary["width"])) <= 1 else 1)' "$settings_button" "$primary_button"
read -r click_x click_y < <(python3 -I -c '
import json, sys
rect, at = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(at[0] + rect["x"] + rect["width"] // 2, at[1] + rect["y"] + rect["height"] // 2)' "$settings_button" "$window_at")
move_pointer "$click_x" "$click_y"
sleep 0.3
screenshot settings-vpn-card-hover
send_input "click left"
settings_on_tailscale() { [ "$(shell_ipc settings currentPage)" = tailscale ]; }
check_within 5 "\"Settings…\" on the card opens the settings page \"tailscale\" (the list's selected page)" settings_on_tailscale
sleep 1.5
screenshot settings-tailscale
check "… built without an error or a warning" test "$(module_errors)" = "[]"

# ---- Step 2 on the page: accounts, this device's name, the key, diagnostics ----
ts_profiles() { shell_ipc tailscale profiles 2> /dev/null; }
profiles_field() { ts_profiles | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print(",".join(v) if isinstance(v,list) else (str(v).lower() if isinstance(v,bool) else v))' "$1" 2> /dev/null; }
profiles_is() { [ "$(profiles_field "$1")" = "$2" ]; }
ts_diagnostics_field() { shell_ipc tailscale diagnostics 2> /dev/null | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print(str(v).lower() if isinstance(v,bool) else v)' "$1" 2> /dev/null; }
ts_diagnostics_is() { [ "$(ts_diagnostics_field "$1")" = "$2" ]; }

check "the accounts are not read by themselves (the list needs a password)" profiles_is read false
shell_ipc tailscale readProfiles > /dev/null
check_within 10 "Show accounts (IPC, as the button): two accounts, a1b2 in use" profiles_is ids "a1b2,c3d4"
check "… a1b2 in use" profiles_is selected a1b2
check "… read through pkexec (switch --list --json under the read limit)" grep -qP "^pkexec\t$tools/timeout\t-k\t5\t15\t$tools/tailscale\tswitch\t--list\t--json\$" "$tools/pkexec.log"
check_within 5 "the page lists them (a row per account)" item_on_screen tailscaleAccount-c3d4
sleep 1
screenshot settings-tailscale-accounts

shell_ipc tailscale switchProfile c3d4 > /dev/null
check_within 10 "switch to c3d4: the list marks it" profiles_is selected c3d4
check "… through pkexec: switch c3d4" grep -qP "^pkexec\t$tools/timeout\t-k\t5\t60\t$tools/tailscale\tswitch\tc3d4\$" "$tools/pkexec.log"
entry_named_org() { shell_ipc tailscale state | grep -q '"status":"Tailnet only"' && ! profiles_is outdated true; }
check_within 10 "… the state follows (connected, the list matching the account in use)" entry_named_org
sleep 1
screenshot settings-tailscale-switched

shell_ipc tailscale setHostname box > /dev/null
check_within 10 "rename this device to box: prefs say so" profiles_is hostname box
check "… through pkexec: set --hostname=box" grep -qP "^pkexec\t$tools/timeout\t-k\t5\t60\t$tools/tailscale\tset\t--hostname=box\$" "$tools/pkexec.log"

# The key about to expire (3 days): no attention (nothing renews it without harm) — the status
# line and the page say it, with the admin console's link
printf 'key-expiring\n' > "$tools/state/scenario"
shell_ipc tailscale refresh > /dev/null
key_in_status() { shell_ipc tailscale state | grep -q '"status":"Tailnet only · key expires in 3 days"'; }
check_within 10 "a key expiring in 3 days: the entry's status line says it" key_in_status
check "… no attention, no action" test "$(ts_field attention)|$(ts_field attentionAction)" = "|"
check_within 5 "… the page offers the admin console" item_on_screen tailscaleAdminConsole
check "… the key's state: soon" profiles_is keyState soon
check "… still connected" ts_is state activated
sleep 1
screenshot settings-tailscale-key-expiring

check "diagnostics: nothing run by itself" ts_diagnostics_is ran false
shell_ipc tailscale runDiagnostics > /dev/null
check_within 15 "a netcheck run (IPC, as the button): done" ts_diagnostics_is ran true
check "… the nearest relay named from the relay map (ams)" ts_diagnostics_is nearest ams
check "… netcheck and DNS rows, no errors" test "$(ts_diagnostics_field netcheckRows)" -ge 6 -a "$(ts_diagnostics_field dnsRows)" -ge 4 -a "$(ts_diagnostics_field errors)" = 0
check "… netcheck ran plainly, never through pkexec" test "$(grep -c '^netcheck --format=json$' "$tools/log")" = 1 -a "$(grep -c netcheck "$tools/pkexec.log")" = 0
# Its section opened by a click on "Show", found where it is: the window first made floating,
# taller than the screen and moved up (Hyprland's Lua dispatchers), so that the end of the page
# is on screen
hyprctl dispatch 'hl.dsp.focus({ window = "title:^(Settings)$" })' > /dev/null 2>&1
for expression in 'hl.dsp.window.float({ action = "enable" })' 'hl.dsp.window.resize({ x = 1300, y = 2400 })' 'hl.dsp.window.move({ x = 300, y = -1340 })'; do
    answer=$(hyprctl dispatch "$expression" 2>&1 | head -n 1)
    [ "$answer" = ok ] || log "hyprctl dispatch $expression: $answer"
done
log "settings window: $(hyprctl -j activewindow | python3 -I -c 'import json,sys; w=json.load(sys.stdin); print(w.get("title"), w.get("at"), w.get("size"), w.get("floating"))')"
sleep 1
toggle=$(settings_rect tailscaleDiagnosticsToggle)
window_at=$(settings_window_at)
log "diagnostics toggle $toggle, window at $window_at"
read -r click_x click_y < <(python3 -I -c '
import json, sys
rect, at = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(at[0] + rect.get("x", 0) + rect.get("width", 0) // 2, at[1] + rect.get("y", 0) + rect.get("height", 0) // 2)' "$toggle" "$window_at")
if [ "$click_y" -lt "$OUTPUT_HEIGHT" ]; then
    move_pointer "$click_x" "$click_y"
    send_input "click left"
    check_within 5 "\"Show\" opens the diagnostics section" item_on_screen tailscaleDiagnostics
else
    log "the diagnostics toggle is below the screen (y $click_y): opened state not checked by a click"
fi
sleep 1
screenshot settings-tailscale-diagnostics
check "… the page built without an error or a warning" test "$(module_errors)" = "[]"

# ---- Step 3 ----
# The (floating, tall) settings window moved so that a page item is near the top of the screen
show_item() {
    local rect
    rect=$(settings_rect "$1")
    local y
    y=$(python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); print(80 - r.get("y", 0))' "$rect")
    answer=$(hyprctl dispatch "hl.dsp.window.move({ x = 300, y = $y })" 2>&1 | head -n 1)
    [ "$answer" = ok ] || log "hyprctl move to $y: $answer"
    sleep 1
}
ts_sharing_field() { shell_ipc tailscale sharing 2> /dev/null | python3 -I -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print(",".join(map(str,v)) if isinstance(v,list) else (str(v).lower() if isinstance(v,bool) else v))' "$1" 2> /dev/null; }
sharing_is() { [ "$(ts_sharing_field "$1")" = "$2" ]; }

# The coordinator's bug 1: a name set while disconnected is the name shown, with what the
# tailnet still has said beside it; connecting brings the tailnet along
shell_ipc tailscale disconnect > /dev/null
check_within 10 "disconnected (for a rename while off)" ts_is phase stopped
shell_ipc tailscale setHostname framework > /dev/null
check_within 10 "rename while off: prefs say framework" profiles_is hostname framework
check_within 5 "… the tailnet does not have it yet: said so" profiles_is nameNote "the tailnet shows it after connecting"
show_item tailscaleDeviceName
screenshot settings-tailscale-renamed-off
shell_ipc tailscale connect > /dev/null
check_within 15 "connected again" ts_is state activated
check_within 10 "… the tailnet has the new name now: nothing pending" profiles_is namePending false

# Sharing: a route offered (IPC, as the page's "Offer"), through pkexec; waiting for approval
check "sharing: nothing offered at first" sharing_is routes 0
check_within 10 "… prefs read since the last change (a route edit is accepted only then)" sharing_is prefsCurrent true
shell_ipc tailscale advertiseRoute 192.168.7.0/24 > /dev/null
check_within 10 "offer 192.168.7.0/24: listed, waiting for approval" sharing_is routeStates pending
check "… through pkexec: set --advertise-routes=192.168.7.0/24" grep -qP "^pkexec\t$tools/timeout\t-k\t5\t60\t$tools/tailscale\tset\t--advertise-routes=192\.168\.7\.0/24\$" "$tools/pkexec.log"
check_within 5 "… IP forwarding read from the bed's fake /proc: IPv4 off" sharing_is ipv4Forwarding false
check "… the forwarding warning shown" sharing_is forwardingWarning true
shell_ipc tailscale advertiseExitNode true > /dev/null
check_within 10 "offer the exit node: waiting for approval" sharing_is exitNodeState pending
check "… the route kept (set --advertise-exit-node alone)" sharing_is routes 1
check "… never both flags in one command" test "$(grep -c 'advertise-routes.*advertise-exit-node\|advertise-exit-node.*advertise-routes' "$tools/log")" = 0
printf '192.168.7.0/24\n' > "$tools/state/approved"
shell_ipc tailscale refresh > /dev/null
check_within 10 "an admin approved the route: approved" sharing_is routeStates approved
check "… the exit node still waiting" sharing_is exitNodeState pending
shell_ipc tailscale setSsh true > /dev/null
check_within 10 "Tailscale SSH on" sharing_is ssh true
check "… set --ssh=true through pkexec, no --accept-risk" grep -qP "^pkexec\t$tools/timeout\t-k\t5\t60\t$tools/tailscale\tset\t--ssh=true\$" "$tools/pkexec.log"
item_on_screen tailscaleForwardingWarning || log "the forwarding warning has no size"
show_item tailscaleOfferExitNode
screenshot settings-tailscale-sharing
show_item tailscaleSshServer
screenshot settings-tailscale-ssh
check "… the page built without an error or a warning" test "$(module_errors)" = "[]"
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
