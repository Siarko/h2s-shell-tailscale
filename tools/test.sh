#!/usr/bin/env bash
# Checks the stand-ins (tools/stand-in: tailscale, pkexec, curl, timeout, …) do what the next stage's
# end-to-end tests will count on. Each is run by its absolute path, never through PATH — so
# the real tailscale (or pkexec, or curl) can never be the one that runs — with a private
# state directory, and nothing reaches a daemon or the network.
#
#   tools/test.sh     prints PASS / FAIL lines; exit 0 when all passed, 1 otherwise
set -uo pipefail

TOOLS=$(cd "$(dirname "$(readlink -f "$0")")" && pwd -P)
FIXTURES=$(cd "$TOOLS/../fixtures" && pwd -P)
TS=$TOOLS/stand-in/tailscale
PKEXEC=$TOOLS/stand-in/pkexec
CURL=$TOOLS/stand-in/curl
work=$(mktemp -d "${TMPDIR:-/tmp}/ts-standin.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

pass() { passed=$((passed + 1)); echo "  PASS: $1"; }
fail() { failed=$((failed + 1)); echo "  FAIL: $1"; }
check() { # check <description> <command…>: passes when the command succeeds
    local description=$1
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# A fresh state for each scenario; TS_FAKE_* from the caller are dropped
fresh() {
    rm -rf "$work/state" "$work/log" "$work/pkexec.log"
    mkdir -p "$work/state"
    unset SSH_CLIENT
    unset TS_FAKE_STATE TS_FAKE_DAEMON TS_FAKE_OPERATOR TS_FAKE_ROOT TS_FAKE_PKEXEC TS_FAKE_BUS_END TS_FAKE_PING TS_FAKE_LOGIN_RESULT TS_FAKE_UP_DELAY TS_FAKE_UP_URL TS_FAKE_STATUS_HANG
    export TS_FAKE_STATE_DIR=$work/state TS_FAKE_LOG=$work/log TS_FAKE_PKEXEC_LOG=$work/pkexec.log
    export TS_FAKE_LOGIN_DELAY=0 TS_FAKE_USER=tester TS_FAKE_FIXTURES=$FIXTURES
}

backend() { "$TS" status --json | sed -n 's/^  "BackendState": "\(.*\)",$/\1/p'; }
pref() { "$TS" debug prefs | sed -n "s/^  \"$1\": \\(.*\\),\$/\\1/p"; }
run() { # run <stdout file> <stderr file> <command…> → the exit status in $status
    local out=$1 err=$2
    shift 2
    "$@" > "$out" 2> "$err"
    status=$?
}

echo "=== stand-in tailscale ==="
fresh
check "status --json replays the running fixture" cmp -s <("$TS" status --json) "$FIXTURES/status-running.json"
check "debug prefs replays the running prefs" cmp -s <("$TS" debug prefs) "$FIXTURES/prefs-running.json"
check "exit-node list replays its fixture" cmp -s <("$TS" exit-node list) "$FIXTURES/exit-node-list.txt"
check "exit-node suggest replays its fixture" cmp -s <("$TS" exit-node suggest) "$FIXTURES/exit-node-suggest.txt"
check "version works" grep -q '^1.104.4$' <("$TS" version)

# Read-only: every change denied with the real text, nothing changed
run "$work/out" "$work/err" "$TS" set --exit-node=peer4
check "read-only: set exits 1" test "$status" = 1
check "read-only: the real denial text" grep -q "^Access denied: prefs write access denied$" "$work/err"
check "read-only: the advice names the command as typed" grep -qF "Use 'sudo tailscale set --exit-node=peer4'." "$work/err"
check "read-only: nothing changed" test "$(pref ExitNodeID)" = '""'
run "$work/out" "$work/err" "$TS" switch --list
check "read-only: switch --list denied (profiles access denied)" grep -q "^Access denied: profiles access denied$" "$work/err"
run "$work/out" "$work/err" "$TS" logout
check "read-only: logout denied" grep -q "^Access denied: logout access denied$" "$work/err"
run "$work/out" "$work/err" "$TS" down
check "read-only: down denied, still running" test "$status" = 1 -a "$(backend)" = Running

# Operator: changes go through and show in status / prefs
export TS_FAKE_OPERATOR=1
run "$work/out" "$work/err" "$TS" set --accept-routes=false --shields-up --hostname=box
check "operator: set succeeds" test "$status" = 0
check "operator: RouteAll follows" test "$(pref RouteAll)" = false
check "operator: ShieldsUp follows" test "$(pref ShieldsUp)" = true
check "operator: Hostname follows" test "$(pref Hostname)" = '"box"'
run "$work/out" "$work/err" "$TS" set --exit-node=100.64.0.4
check "operator: an exit node by address" test "$status" = 0 -a "$(pref ExitNodeID)" = '"nPEER4CNTRL"'
check "operator: status shows the exit node" grep -q '"ExitNodeStatus"' <("$TS" status --json)
run "$work/out" "$work/err" "$TS" set --exit-node=
check "operator: no exit node" test "$(pref ExitNodeID)" = '""' -a "$(backend)" = Running
run "$work/out" "$work/err" "$TS" set --exit-node=nowhere
check "operator: an unknown exit node is an error" test "$status" = 1
run "$work/out" "$work/err" "$TS" set --nonsense
check "operator: an unknown flag is Go's flag error (one dash)" grep -q "flag provided but not defined: -nonsense" "$work/err"

# Sharing (step 3): set.go's composition of --advertise-routes and --advertise-exit-node
routes() { "$TS" debug prefs | awk '/^  "AdvertiseRoutes": null/ { print ""; exit } /^  "AdvertiseRoutes": \[/ { on = 1; next } on && /^  \]/ { print list; exit } on { gsub(/[ ",]/, ""); list = list (list == "" ? "" : ",") $0 }'; }
"$TS" set --advertise-routes=192.168.1.0/24,10.0.0.0/8
check "sharing: routes set, sorted by prefix length" test "$(routes)" = "10.0.0.0/8,192.168.1.0/24"
"$TS" set --advertise-exit-node
check "sharing: --advertise-exit-node alone keeps the routes" test "$(routes)" = "0.0.0.0/0,::/0,10.0.0.0/8,192.168.1.0/24"
"$TS" set --advertise-routes=192.168.2.0/24
check "sharing: --advertise-routes alone keeps the exit node" test "$(routes)" = "0.0.0.0/0,::/0,192.168.2.0/24"
"$TS" set --advertise-routes=
check "sharing: an empty --advertise-routes keeps the exit node" test "$(routes)" = "0.0.0.0/0,::/0"
run "$work/out" "$work/err" "$TS" set --exit-node=peer4
check "sharing: using an exit node while offering one is refused with the daemon's text" grep -qx "Cannot advertise an exit node and use an exit node at the same time." "$work/err"
"$TS" set --advertise-exit-node=false
check "sharing: --advertise-exit-node=false drops only the pair" test "$(routes)" = ""
"$TS" set --exit-node=peer4
run "$work/out" "$work/err" "$TS" set --advertise-exit-node
check "sharing: offering an exit node while using one is refused" test "$status" = 1 -a "$(routes)" = ""
"$TS" set --exit-node=
run "$work/out" "$work/err" "$TS" set --advertise-routes=192.168.1.5/24
check "sharing: host bits refused as the CLI does" grep -qx "192.168.1.5/24 has non-address bits set; expected 192.168.1.0/24" "$work/err"
run "$work/out" "$work/err" "$TS" set --advertise-routes=10.1.2.3
check "sharing: an address without a prefix refused" grep -qx '"10.1.2.3" is not a valid IP address or CIDR prefix' "$work/err"
run "$work/out" "$work/err" "$TS" set --advertise-tags=tag:x
check "sharing: --advertise-tags is not a flag of set (up only)" grep -qx "flag provided but not defined: -advertise-tags" "$work/err"
"$TS" set --advertise-routes=192.168.2.0/24 --advertise-exit-node
printf '192.168.2.0/24\n' > "$work/state/approved"
check "sharing: an approved route shows in Self's AllowedIPs and PrimaryRoutes" test "$("$TS" status --json | grep -c '"192.168.2.0/24"')" = 2
check "sharing: the exit node not approved: ExitNodeOption false" grep -q '^    "ExitNodeOption": false' <("$TS" status --json)
run "$work/out" "$work/err" "$TS" set --auto-update
check "sharing: auto-update refused as on NixOS" grep -qx "Auto-updates are not supported on this platform." "$work/err"
"$TS" set --relay-server-port=40000 --snat-subnet-routes=false --report-posture
check "sharing: relay port, SNAT, posture in prefs" test "$(pref RelayServerPort)|$(pref NoSNAT)|$(pref PostureChecking)" = "40000|true|true"
run "$work/out" "$work/err" env SSH_CLIENT="100.64.0.9 50000 22" "$TS" set --ssh
check "sharing: --ssh inside an SSH session over Tailscale aborts without a terminal" grep -qx "aborted, no changes made" "$work/err"
check "… nothing changed" test "$(pref RunSSH)" = false
run "$work/out" "$work/err" "$TS" set --ssh=maybe
check "operator: a bad boolean is refused" test "$status" = 2
run "$work/out" "$work/err" "$TS" down
check "operator: down → Stopped, WantRunning false" test "$(backend)" = Stopped -a "$(pref WantRunning)" = false
run "$work/out" "$work/err" "$TS" up
check "operator: bare up → Running again" test "$status" = 0 -a "$(backend)" = Running -a "$(pref WantRunning)" = true
run "$work/out" "$work/err" "$TS" up --accept-routes
check "up with a flag → the revert error" test "$status" = 1
check "up with a flag: the real revert text" cmp -s "$work/err" "$FIXTURES/stderr-up-accidental-revert.txt"
run "$work/out" "$work/err" "$TS" up --timeout=5s
check "up with any flag (even --timeout) → the revert error" grep -q "requires mentioning all" "$work/err"
check "switch --list --json replays its fixture" cmp -s <("$TS" switch --list --json) "$FIXTURES/switch-list.json"
check "switch --list replays the table" cmp -s <("$TS" switch --list) "$FIXTURES/switch-list.txt"
check "switch to another account: says so" grep -q "^Switching to account \"user1@example.org\"$" <("$TS" switch c3d4)
check "… and the list marks it" grep -q "user1@example.org\*$" <("$TS" switch --list)
check "… its own status (the work tailnet)" grep -q "example-org.ts.net" <("$TS" status --json)
check "… its login in the prefs" grep -q "\"LoginName\": \"user1@example.org\"" <("$TS" debug prefs)
"$TS" set --nickname=office --hostname=box > /dev/null
check "set --nickname names the account in use" grep -q "\"nickname\": \"office\"" <("$TS" switch --list --json)
check "set --hostname renames this computer in status" grep -q "\"HostName\": \"box\"" <("$TS" status --json)
"$TS" login > /dev/null 2>&1
check "login while logged in adds an account (e5f6), in use" grep -q "^e5f6 .*user2@example.net\*$" <("$TS" switch --list)
"$TS" switch remove c3d4
check "switch remove drops an account" test "$("$TS" switch --list | grep -c c3d4)" = 0
printf "a1b2\n" > "$work/state/current"; printf "running\n" > "$work/state/scenario"
TS_FAKE_LOGIN_SAME=1 "$TS" login > /dev/null 2>&1
check "login with the same account: back on its own profile" grep -q "user1@example.com\*$" <("$TS" switch --list)
check "… with login's defaults (accept routes off): the old prefs lost" grep -q "\"RouteAll\": false" <("$TS" debug prefs)
run "$work/out" "$work/err" "$TS" switch zz99
check "switch to an unknown account fails with the source's text" grep -q 'No profile named "zz99"' "$work/err"

# Logging out, logging in: the URL first, then success after the delay
run "$work/out" "$work/err" "$TS" logout
check "logout → NeedsLogin, LoggedOut" test "$(backend)" = NeedsLogin -a "$(pref LoggedOut)" = true
TS_FAKE_LOGIN_DELAY=1 "$TS" login > "$work/out" 2> "$work/err" &
login_pid=$!
sleep 0.4
check "login: the auth URL is printed before success" grep -q "https://login.tailscale.com/a/REDACTED" "$work/err"
check "login: meanwhile status says NeedsLogin with an AuthURL" grep -q '"AuthURL": "https://' <("$TS" status --json)
wait "$login_pid"
check "login: then Success." grep -q "^Success.$" "$work/err"
check "login: then Running, logged in" test "$(backend)" = Running -a "$(pref LoggedOut)" = false
run "$work/out" "$work/err" "$TS" logout
run "$work/out" "$work/err" env TS_FAKE_LOGIN_RESULT=fail "$TS" login
check "a failing login ends in an error, still logged out" test "$status" = 1 -a "$(backend)" = NeedsLogin
run "$work/out" "$work/err" "$TS" login --force-reauth
check "login with a flag is refused by the stand-in" test "$status" = 2

# Becoming the operator: allowed after `set --operator=<the user>` (done as root)
fresh
run "$work/out" "$work/err" env TS_FAKE_ROOT=1 "$TS" set --operator=tester
check "set --operator as root succeeds" test "$status" = 0
check "prefs show the operator" test "$(pref OperatorUser)" = '"tester"'
run "$work/out" "$work/err" "$TS" set --shields-up
check "as the operator, set needs no root" test "$status" = 0
run "$work/out" "$work/err" env TS_FAKE_USER=someone "$TS" set --shields-up
check "another user is still denied" test "$status" = 1

# Daemon down
fresh
run "$work/out" "$work/err" env TS_FAKE_DAEMON=down "$TS" status --json
check "daemon down: status fails with the real text" test "$status" = 1
check "daemon down: the text" cmp -s "$work/err" "$FIXTURES/stderr-not-running.txt"
check "daemon down: version still works" env TS_FAKE_DAEMON=down "$TS" version > /dev/null

# Scenarios
for scenario in stopped starting needs-login needs-machine-auth exit-node exit-node-offline key-expiring key-expired health-warnings update-available rich; do
    check "scenario $scenario replays its fixture" cmp -s <(TS_FAKE_STATE=$scenario "$TS" status --json) "$FIXTURES/status-$scenario.json"
done
check "scenario rich: prefs-rich" cmp -s <(TS_FAKE_STATE=rich "$TS" debug prefs) "$FIXTURES/prefs-rich.json"

# Others the module runs
check "ping replays pongs" grep -q "^pong from" <("$TS" ping --c=3 --timeout=5s laptop)
run "$work/out" "$work/err" env TS_FAKE_PING=timeout "$TS" ping --c=3 old-desktop
check "ping timeout: exit 1, no reply" test "$status" = 1
check "netcheck replays the real shape (a comment, then JSON)" cmp -s <("$TS" netcheck --format=json 2> /dev/null) "$FIXTURES/netcheck-real.json"
check "dns status --json replays its fixture" cmp -s <("$TS" dns status --json) "$FIXTURES/dns-status.json"
check "debug derp-map replays its fixture" cmp -s <("$TS" debug derp-map) "$FIXTURES/derp-map.json"
check "version --json replays its fixture" cmp -s <("$TS" version --json) "$FIXTURES/version.json"
run "$work/out" "$work/err" "$TS" file cp /tmp/a "/tmp/with space" laptop:
check "file cp with a target: ok" test "$status" = 0
check "file cp: paths arrive as separate arguments" grep -qF "file cp /tmp/a /tmp/with space laptop:" "$work/log"
run "$work/out" "$work/err" "$TS" file cp /tmp/a laptop
check "file cp without the colon fails" test "$status" = 1
run "$work/out" "$work/err" "$TS" file get /tmp/inbox
check "file get denied read-only" grep -q "^Access denied: file access denied$" "$work/err"
check "debug watch-ipn replays the pretty bus" cmp -s <("$TS" debug watch-ipn --initial) "$FIXTURES/bus-pretty.txt"
check "serve status --json" grep -q '{}' <("$TS" serve status --json)
check "lock status" grep -q "NOT enabled" <("$TS" lock status)
check "every call was logged" test "$(wc -l < "$work/log")" -gt 10

echo "=== stand-in pkexec ==="
fresh
run "$work/out" "$work/err" "$PKEXEC" "$TS" set --shields-up
check "ok: runs the program as root (the change goes through)" test "$status" = 0 -a "$(pref ShieldsUp)" = true
check "ok: logs the argv" grep -qP "^pkexec\t$TS\tset\t--shields-up$" "$work/pkexec.log"
run "$work/out" "$work/err" env TS_FAKE_PKEXEC=dismiss "$PKEXEC" "$TS" down
check "dismiss: exit 126, nothing run" test "$status" = 126 -a "$(backend)" = Running
run "$work/out" "$work/err" env TS_FAKE_PKEXEC=no-agent "$PKEXEC" "$TS" down
check "no-agent: exit 127" test "$status" = 127
run "$work/out" "$work/err" "$PKEXEC" tailscale down
check "a relative program name is refused (127)" test "$status" = 127 -a "$(backend)" = Running

echo "=== stand-in curl ==="
fresh
check "the bus lines, as scripted" cmp -s <("$CURL" -sN --unix-socket /var/run/tailscale/tailscaled.sock "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus?mask=11414") "$FIXTURES/bus-lines.jsonl"
run "$work/out" "$work/err" env TS_FAKE_BUS_END=die "$CURL" --unix-socket /s "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus"
check "die: the lines, then exit 56" test "$status" = 56 -a "$(wc -l < "$work/out")" = "$(wc -l < "$FIXTURES/bus-lines.jsonl")"
run "$work/out" "$work/err" env TS_FAKE_DAEMON=down "$CURL" --unix-socket /s "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus"
check "daemon down: exit 7" test "$status" = 7
run "$work/out" "$work/err" "$CURL" "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus"
check "without --unix-socket: exit 7" test "$status" = 7
run "$work/out" "$work/err" "$CURL" --unix-socket /s "http://local-tailscaled.sock/localapi/v0/status"
check "another URL: exit 22" test "$status" = 22
start=$SECONDS
run "$work/out" "$work/err" env TS_FAKE_BUS_DELAY=0.1 TS_FAKE_BUS_END=hold TS_FAKE_BUS_HOLD=1 "$CURL" --unix-socket /s "http://x/localapi/v0/watch-ipn-bus"
check "hold: waits, then ends" test "$status" = 0 -a $((SECONDS - start)) -ge 1

echo "=== stand-in systemctl, xdg-open, nmcli ==="
fresh
SYSTEMCTL=$TOOLS/stand-in/systemctl
XDG_OPEN=$TOOLS/stand-in/xdg-open
NMCLI=$TOOLS/stand-in/nmcli
run "$work/out" "$work/err" "$SYSTEMCTL" stop tailscaled.service
check "systemctl stop: the daemon down (a file in the state dir)" test "$status" = 0 -a -f "$work/state/daemon-down"
run "$work/out" "$work/err" "$TS" status --json
check "… the stand-in tailscale says not running" grep -q "Failed to connect" "$work/err"
run "$work/out" "$work/err" "$CURL" --unix-socket /s "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus"
check "… the stand-in curl cannot connect (exit 7)" test "$status" = 7
run "$work/out" "$work/err" "$SYSTEMCTL" start tailscaled.service
check "systemctl start: up again" test "$status" = 0 -a ! -e "$work/state/daemon-down" -a "$(backend)" = Running
run "$work/out" "$work/err" env TS_FAKE_SYSTEMCTL=fail "$SYSTEMCTL" start tailscaled.service
check "systemctl fail: exit 1" test "$status" = 1
check "systemctl: logged" grep -q "^systemctl start tailscaled.service$" "$work/log"
run "$work/out" "$work/err" "$XDG_OPEN" "https://login.tailscale.com/a/REDACTED"
check "xdg-open: opens nothing, logs the URL" test "$status" = 0 -a "$(grep -c "^xdg-open https://login.tailscale.com/a/REDACTED$" "$work/log")" = 1
run "$work/out" "$work/err" "$NMCLI" -t device
check "nmcli: answers nothing (exit 8)" test "$status" = 8
run "$work/out" "$work/err" env TS_FAKE_STATE=key-expired "$TS" debug prefs
check "key expired: prefs of a logged-in machine (an expiry is not a logout)" grep -q '"LoggedOut": false' "$work/out"
TS_FAKE_LOGIN_DELAY=5 "$TS" logout > /dev/null 2>&1; TS_FAKE_OPERATOR=1 "$TS" logout > /dev/null 2>&1
TS_FAKE_OPERATOR=1 TS_FAKE_LOGIN_DELAY=5 "$TS" login > /dev/null 2>&1 &
login_pid=$!
sleep 0.3
kill -TERM "$login_pid"
wait "$login_pid" 2> /dev/null
sleep 0.2
check "a login ended while it waits takes its sleep with it" test -z "$(pgrep -fx "sleep 5" 2> /dev/null)"

echo "=== stand-in timeout, unkillable pkexec, slow up, hung status ==="
fresh
TIMEOUT=$TOOLS/stand-in/timeout
run "$work/out" "$work/err" "$TIMEOUT" -k 1 5 "$TS" version
check "timeout: runs the program (the real timeout(1) found on PATH)" test "$status" = 0 -a "$(head -n 1 "$work/out")" = 1.104.4
start=$SECONDS
run "$work/out" "$work/err" env TS_FAKE_STATUS_HANG=30 "$TIMEOUT" -k 1 1 "$TS" status --json
check "hung status: under timeout 1 s it is stopped with 124" test "$status" = 124 -a $((SECONDS - start)) -le 4
run "$work/out" "$work/err" env PATH="$TOOLS/stand-in" "$TIMEOUT" 1 /bin/true
check "timeout: no real timeout(1) on PATH → 125, nothing run" test "$status" = 125
echo 30 > "$work/state/status-hang"
start=$SECONDS
run "$work/out" "$work/err" "$TIMEOUT" -k 1 1 "$TS" status --json
check "hung status by the state file: stopped too" test "$status" = 124 -a $((SECONDS - start)) -le 4
rm -f "$work/state/status-hang"
check "… answering again without it" cmp -s <("$TS" status --json) "$FIXTURES/status-running.json"
export TS_FAKE_OPERATOR=1
"$TS" down > /dev/null 2>&1
start=$SECONDS
TS_FAKE_UP_DELAY=30 TS_FAKE_UP_URL=1 "$TIMEOUT" -k 1 1 "$TS" up > "$work/out" 2> "$work/err"
status=$?
check "slow up: still waiting after 1 s, stopped by timeout (124)" test "$status" = 124 -a $((SECONDS - start)) -le 4
check "slow up: the login URL printed first" grep -q "https://login.tailscale.com/a/REDACTED" "$work/err"
check "slow up: meanwhile Starting, WantRunning set" test "$(backend)" = Starting -a "$(pref WantRunning)" = true
"$TS" down > /dev/null 2>&1; TS_FAKE_UP_DELAY=1 "$TS" up > /dev/null 2>&1
check "slow up given the time: Running" test "$(backend)" = Running
"$TS" down > /dev/null 2>&1
TS_FAKE_UP_DELAY=2 "$TS" up > /dev/null 2> "$work/err" &
up_pid=$!
sleep 0.5
"$TS" down > /dev/null 2>&1
wait "$up_pid"
check "slow up, then down meanwhile: up fails, never Running" test $? = 1 -a "$(backend)" = Stopped
unset TS_FAKE_OPERATOR
"$TS" logout > /dev/null 2>&1; TS_FAKE_ROOT=1 "$TS" logout > /dev/null 2>&1
start=$SECONDS
TS_FAKE_PKEXEC=unkillable TS_FAKE_UNKILLABLE_SECONDS=2 TS_FAKE_LOGIN_DELAY=0 "$PKEXEC" "$TS" login > /dev/null 2>&1 &
pk_pid=$!
sleep 0.3
kill -TERM "$pk_pid" 2> /dev/null
sleep 0.3
check "unkillable pkexec: SIGTERM ignored" kill -0 "$pk_pid"
wait "$pk_pid"
check "… it ends by itself after TS_FAKE_UNKILLABLE_SECONDS, with the program's status" test $? = 0 -a $((SECONDS - start)) -ge 2
check "… logged like any call" grep -qP "^pkexec\t$TS\tlogin$" "$work/pkexec.log"

echo
echo "--- stand-ins: $passed/$((passed + failed)) passed$([ "$failed" -gt 0 ] && echo ", $failed FAILED") ---"
[ "$failed" = 0 ]
