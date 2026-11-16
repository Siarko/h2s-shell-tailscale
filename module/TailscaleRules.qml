pragma Singleton

import Quickshell
import QtQuick

// The Tailscale module's decisions — pure, so module/tests/ check them on fixtures without a
// daemon: what `tailscale status --json`, `tailscale debug prefs` and the IPN bus say,
// mapped onto the shell's VPN provider contract (components/VpnProvider.qml in the shell;
// docs/plans/tailscale.md §3), the devices and exit nodes for the views, the accounts, what
// an error or a pkexec exit means, and the argv of every command the module runs.
//
// No I/O, no timers, no other singleton: time is passed in (`now`, milliseconds since
// 1970). Nothing here throws, whatever it is given — the status format is officially
// unstable, and the bus and the CLI's texts are not promised interfaces either. Unknown
// values fall back to "unknown" rather than to a guess that would show something false.
//
// WHAT IS RELIED ON (everything else in the inputs is ignored; each field missing → the
// default named here):
//   status --json (ipn/ipnstate.Status):
//     BackendState  string, one of backendStates — missing/unknown: phase "unknown", state ""
//     AuthURL       string — missing: "" (no login URL to offer)
//     HaveNodeKey   bool — missing: false (only refines "key expired")
//     TailscaleIPs  [string] — missing: [] (the entry's addresses)
//     Self          node (below) — missing: null (no key-expiry warning, no own name)
//     Health        [string] — missing: [] (no health warnings)
//     CurrentTailnet { Name, MagicDNSSuffix, MagicDNSEnabled } — missing: null (name
//                   "Tailscale" alone); MagicDNSSuffix at the top level is the fallback
//     Peer          { key: node } (an array is accepted too) — missing: no devices
//     User          { id: { LoginName, DisplayName } } — missing: owners unknown ("")
//     ClientVersion { RunningLatest, LatestVersion, Notify, NotifyText } — missing: no
//                   update notice
//     ExitNodeStatus { ID, Online, TailscaleIPs } — missing: the exit node is found from
//                   the peers' ExitNode flag and prefs' ExitNodeID instead
//     TUN           bool — missing: true (false = userspace networking: no interface)
//   a node: ID, PublicKey, HostName, DNSName, OS, UserID, TailscaleIPs, PrimaryRoutes,
//     CurAddr, Relay, PeerRelay, RxBytes, TxBytes, LastSeen, Online, Active, ExitNode,
//     ExitNodeOption, KeyExpiry, Expired, Tags, TaildropTarget, NoFileSharingReason,
//     Location { Country, CountryCode, City, CityCode, Priority }, ShareeNode,
//     AltSharerUserID — each missing: "", 0, false, [] or null.
//   debug prefs (ipn.Prefs; its keys are zeroed for a non-root reader): ControlURL,
//     RouteAll (accept routes, default false), ExitNodeID, ExitNodeIP,
//     ExitNodeAllowLANAccess, CorpDNS (accept DNS, default true), RunSSH, RunWebClient,
//     WantRunning, LoggedOut, ShieldsUp, AdvertiseTags, Hostname, AdvertiseRoutes,
//     OperatorUser, ProfileName, AutoUpdate { Check, Apply }, Config.UserProfile.LoginName.
//   the IPN bus (ipn.Notify, one JSON object per message): State (a NUMBER: ipn.State),
//     BrowseToURL, LoginFinished, ErrMessage, Prefs, Health { Warnings { code: {
//     Severity, Title, Text, ImpactsConnectivity } } }, SuggestedExitNode, ClientVersion,
//     OutgoingFiles, FilesWaiting, IncomingFiles, Engine, Version. Anything else: "changed".
//   switch --list --json: [{ id, nickname, tailnet, account, selected }] (root or the operator
//     only). netcheck --format=json: UDP, IPv4, IPv6, OSHasIPv6, MappingVariesByDestIP, UPnP,
//     PMP, PCP, CaptivePortal, PreferredDERP, RegionLatency (ns), after a "# Warning" line.
//     debug derp-map: Regions { id: { RegionCode, RegionName } }. dns status --json:
//     TailscaleDNS, CurrentTailnet { MagicDNSEnabled, MagicDNSSuffix, SelfDNSName }, Resolvers
//     [{ Addr }], SplitDNSRoutes { domain: [{ Addr }] }, SearchDomains, SystemDNSError.
//     version --json: short, long. Each missing: false, "", [] or unknown.
//
// TIME: status times are RFC 3339 text; they are read as milliseconds (0 = Go's zero time
// "0001-01-01T00:00:00Z", missing or unreadable). All durations here are milliseconds.
Singleton {
    id: root

    // ---- Constants ----

    readonly property string providerId: "tailscale"
    // The one entry's id. Never the tailnet's or the account's: it is stored in the user's
    // "VPN with a network" setting, and must survive switching tailnets, logging out and
    // the daemon being down.
    readonly property string entryId: "main"
    readonly property string typeName: "Tailscale"
    readonly property string defaultInterface: "tailscale0"
    // Tailscale's DNS resolver, what /etc/resolv.conf holds while accept-DNS is on
    readonly property string quadHundred: "100.100.100.100"
    // ipn.State, by number (the bus sends the number; status --json the name)
    readonly property var backendStates: ["NoState", "InUseOtherUser", "NeedsLogin", "NeedsMachineAuth", "Stopped", "Starting", "Running"]
    // How long before the key expires the page starts saying so
    readonly property int keyExpiryWarningDays: 14
    // An exit node offline for less than this is a warning; then it is attention (stateOf)
    readonly property int exitNodeOfflineGraceMs: 60000
    // Inputs larger than these are cut, not parsed whole
    readonly property int maxPeers: 5000
    readonly property int maxTextBytes: 16 * 1024 * 1024
    // The splitter of the bus stream drops a single object larger than this
    readonly property int maxObjectBytes: 8 * 1024 * 1024
    // Where an administrator approves a device (the default control server's)
    readonly property string adminMachinesUrl: "https://login.tailscale.com/admin/machines"
    // The IPN bus over the LocalAPI: ipn.NotifyWatchOpt bits (ipn/backend.go)
    readonly property var notifyMask: ({
        engineUpdates: 1, initialState: 2, initialPrefs: 4, noPrivateKeys: 16, initialDriveShares: 32,
        initialOutgoingFiles: 64, initialHealthState: 128, healthActions: 512, initialSuggestedExitNode: 1024,
        initialClientVersion: 2048, peerChanges: 4096, noNetMap: 8192, initialStatus: 16384, peerPatches: 32768
    })
    // What the module watches: the state and prefs first, health, the suggestion, the
    // version, no private keys, no network map (peers are re-read from status on a change)
    readonly property int watchMask: 2 | 4 | 16 | 128 | 1024 | 2048 | 8192
    readonly property string localApiSocket: "/var/run/tailscale/tailscaled.sock"
    // Where tailscaled's LocalAPI socket may be, in this order (the live side takes the first
    // that exists; localApiSocket when none does)
    readonly property var localApiSockets: ["/var/run/tailscale/tailscaled.sock", "/run/tailscale/tailscaled.sock"]
    // Time limits, in seconds: every command runs under coreutils' timeout (timed(), and
    // privileged() under pkexec), so nothing it runs can wait for ever — not a `status --json`
    // that hangs, not a bare `up` that waits for Running offline, behind a captive portal or
    // with an expired key, and not a root process the shell cannot signal.
    //   read      status --json, debug prefs, exit-node suggest: answered at once by a healthy
    //             daemon; 15 s is a stuck one
    //   change    set, down, logout, switch, systemctl start: the daemon applies them at once
    //   up        a bare `up` sets WantRunning and then WAITS for Running: with a working
    //             network that takes seconds; 60 s leaves room for a slow control server.
    //             Past it the daemon keeps trying by itself (WantRunning stays set), so
    //             stopping the CLI loses nothing — the entry follows the daemon's state
    //   login     the time a person gets to finish the login in the browser
    //   diagnose  netcheck: it probes every relay region (a few seconds when healthy)
    //   ping      one `ping --timeout=3s`, with room for the CLI to start and ask
    //   killAfter timeout(1)'s -k: KILL this long after TERM, for a program that ignores TERM
    readonly property var timeLimits: ({ read: 15, change: 60, up: 60, login: 600, diagnose: 30, ping: 10, killAfter: 5 })
    // An account (profile) id from `switch --list`: never starting with "-", which the CLI
    // would read as a flag
    readonly property var accountIdPattern: /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/

    // ipnstate.TaildropTargetStatus, by number → [canReceive, why not]
    readonly property var _taildropReasons: [
        "unknown", "", "no network map yet", "Tailscale is not running", "not allowed by the tailnet's policy",
        "offline", "no information about it", "its system cannot receive files", "it does not offer file sharing",
        "it belongs to another user"
    ]

    readonly property var _prototypeKeys: ["__proto__", "constructor", "prototype", "hasOwnProperty", "toString", "valueOf",
        "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__", "isPrototypeOf", "propertyIsEnumerable",
        "toLocaleString"]

    // ---- Small tolerant readers ----

    function _isObject(value) {
        return value !== null && typeof value === "object" && !Array.isArray(value);
    }

    // An own property only — never one inherited, never a getter that throws
    function _get(object, key) {
        if (object === null || typeof object !== "object")
            return undefined;
        try {
            return Object.prototype.hasOwnProperty.call(object, key) ? object[key] : undefined;
        } catch (error) {
            return undefined;
        }
    }

    // Text cut to `length` characters, an ellipsis marking the cut
    function _clip(text, length) {
        const value = typeof text === "string" ? text : "";
        return value.length <= length ? value : value.slice(0, length - 1) + "…";
    }

    function _string(value, maxLength) {
        return typeof value === "string" ? value.slice(0, maxLength ?? 1024) : "";
    }

    function _bool(value, fallback) {
        return typeof value === "boolean" ? value : (fallback ?? false);
    }

    function _number(value, fallback) {
        return typeof value === "number" && isFinite(value) ? value : (fallback ?? 0);
    }

    function _strings(value, maxItems) {
        if (!Array.isArray(value))
            return [];
        const result = [];
        for (let i = 0; i < value.length && result.length < (maxItems ?? 256); i++) {
            if (typeof value[i] === "string" && value[i] !== "")
                result.push(value[i].slice(0, 256));
        }
        return result;
    }

    function _keys(object) {
        if (!_isObject(object))
            return [];
        try {
            return Object.keys(object);
        } catch (error) {
            return [];
        }
    }

    function _dict() {
        return Object.create(null);
    }

    function _parseJson(input) {
        if (_isObject(input) || Array.isArray(input))
            return { value: input, error: "" };
        if (typeof input !== "string")
            return { value: null, error: "no text" };
        if (input.length > maxTextBytes)
            return { value: null, error: "too large" };
        const text = input.trim();
        if (text === "")
            return { value: null, error: "empty" };
        try {
            return { value: JSON.parse(text), error: "" };
        } catch (error) {
            return { value: null, error: "not JSON" };
        }
    }

    // RFC 3339 → milliseconds; 0 for Go's zero time, missing or unreadable. Date.parse is
    // not used: Go writes up to nine fractional digits, which it does not take everywhere.
    function timeMs(text) {
        if (typeof text !== "string" || text.length > 64)
            return 0;
        const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|([+-])(\d{2}):(\d{2}))$/.exec(text);
        if (!match)
            return 0;
        const year = Number(match[1]);
        if (year <= 1)
            return 0;
        let value = Date.UTC(year, Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6]));
        if (match[7])
            value += Math.floor(Number("0" + match[7]) * 1000);
        if (match[8] !== "Z")
            value -= (match[9] === "-" ? -1 : 1) * (Number(match[10]) * 60 + Number(match[11])) * 60000;
        return isFinite(value) ? value : 0;
    }

    // "host.tailnet.ts.net." → "host.tailnet.ts.net"
    function _dnsName(value) {
        return _string(value, 256).replace(/\.+$/, "");
    }

    // ---- Status ----

    // A node of the status (Self or a peer), normalised. `key` is its map key.
    function _node(raw, key) {
        if (!_isObject(raw))
            return null;
        const location = _get(raw, "Location");
        const tags = _get(raw, "Tags");
        return {
            id: _string(_get(raw, "ID"), 128),
            key: _string(_get(raw, "PublicKey"), 256) || _string(key, 256),
            hostName: _string(_get(raw, "HostName"), 256),
            dnsName: _dnsName(_get(raw, "DNSName")),
            os: _string(_get(raw, "OS"), 64),
            userId: (typeof _get(raw, "UserID") === "number" || typeof _get(raw, "UserID") === "string") ? String(_get(raw, "UserID")).slice(0, 32) : "",
            altSharerUserId: (typeof _get(raw, "AltSharerUserID") === "number" && _get(raw, "AltSharerUserID") !== 0) ? String(_get(raw, "AltSharerUserID")) : "",
            addresses: _strings(_get(raw, "TailscaleIPs"), 16),
            primaryRoutes: _strings(_get(raw, "PrimaryRoutes"), 256),
            curAddr: _string(_get(raw, "CurAddr"), 128),
            relay: _string(_get(raw, "Relay"), 64),
            peerRelay: _string(_get(raw, "PeerRelay"), 128),
            rxBytes: Math.max(0, _number(_get(raw, "RxBytes"))),
            txBytes: Math.max(0, _number(_get(raw, "TxBytes"))),
            lastSeen: timeMs(_get(raw, "LastSeen")),
            online: _bool(_get(raw, "Online")),
            active: _bool(_get(raw, "Active")),
            exitNode: _bool(_get(raw, "ExitNode")),
            exitNodeOption: _bool(_get(raw, "ExitNodeOption")),
            keyExpiry: timeMs(_get(raw, "KeyExpiry")),
            expired: _bool(_get(raw, "Expired")),
            tags: _strings(tags, 64),
            taildropTarget: Math.trunc(_number(_get(raw, "TaildropTarget"), 0)),
            noFileSharingReason: _string(_get(raw, "NoFileSharingReason"), 300),
            shareeNode: _bool(_get(raw, "ShareeNode")),
            location: _isObject(location) ? {
                country: _string(_get(location, "Country"), 100),
                countryCode: _string(_get(location, "CountryCode"), 8).toUpperCase(),
                city: _string(_get(location, "City"), 100),
                cityCode: _string(_get(location, "CityCode"), 16).toUpperCase(),
                priority: Math.max(0, Math.trunc(_number(_get(location, "Priority"))))
            } : null
        };
    }

    // `tailscale status --json` (text, or the object already parsed) → { ok, error,
    // backendState, haveNodeKey, authUrl, addresses, self, health [text], tailnet { name,
    // magicDnsSuffix, magicDnsEnabled } | null, magicDnsSuffix, peers [node], users
    // { id: { loginName, displayName } }, clientVersion { runningLatest, latestVersion,
    // notify, notifyText } | null, exitNodeStatus { id, online, addresses } | null, tun,
    // version, peersCut }. ok false (and everything empty) when it is not a JSON object.
    function parseStatus(input) {
        const result = {
            ok: false, error: "", backendState: "", haveNodeKey: false, authUrl: "", addresses: [], self: null,
            health: [], tailnet: null, magicDnsSuffix: "", peers: [], users: _dict(), clientVersion: null,
            exitNodeStatus: null, tun: true, version: "", peersCut: false
        };
        const parsed = _parseJson(input);
        if (!_isObject(parsed.value)) {
            result.error = parsed.error || "not an object";
            return result;
        }
        const raw = parsed.value;
        result.ok = true;
        result.version = _string(_get(raw, "Version"), 64);
        result.backendState = _string(_get(raw, "BackendState"), 32);
        result.haveNodeKey = _bool(_get(raw, "HaveNodeKey"));
        result.authUrl = safeUrl(_get(raw, "AuthURL"));
        result.addresses = _strings(_get(raw, "TailscaleIPs"), 16);
        result.tun = _bool(_get(raw, "TUN"), true);
        result.self = _node(_get(raw, "Self"), "");
        result.health = _strings(_get(raw, "Health"), 64);
        const tailnet = _get(raw, "CurrentTailnet");
        result.magicDnsSuffix = _dnsName(_get(raw, "MagicDNSSuffix")).replace(/^\.+/, "");
        if (_isObject(tailnet)) {
            result.tailnet = {
                name: _string(_get(tailnet, "Name"), 200),
                magicDnsSuffix: _dnsName(_get(tailnet, "MagicDNSSuffix")).replace(/^\.+/, "") || result.magicDnsSuffix,
                magicDnsEnabled: _bool(_get(tailnet, "MagicDNSEnabled"))
            };
            if (result.tailnet.magicDnsSuffix !== "")
                result.magicDnsSuffix = result.tailnet.magicDnsSuffix;
        }
        const peerMap = _get(raw, "Peer");
        const peerEntries = Array.isArray(peerMap) ? peerMap.map((value, index) => [String(index), value])
            : _keys(peerMap).map(key => [key, _get(peerMap, key)]);
        for (const pair of peerEntries) {
            if (result.peers.length >= maxPeers) {
                result.peersCut = true;
                break;
            }
            const node = _node(pair[1], pair[0]);
            if (node)
                result.peers.push(node);
        }
        const users = _get(raw, "User");
        for (const key of _keys(users)) {
            const user = _get(users, key);
            if (!_isObject(user))
                continue;
            result.users[String(key).slice(0, 32)] = {
                loginName: _string(_get(user, "LoginName"), 200),
                displayName: _string(_get(user, "DisplayName"), 200)
            };
        }
        const version = _get(raw, "ClientVersion");
        if (_isObject(version)) {
            result.clientVersion = {
                runningLatest: _bool(_get(version, "RunningLatest"), true),
                latestVersion: _string(_get(version, "LatestVersion"), 64),
                notify: _bool(_get(version, "Notify")),
                notifyText: _string(_get(version, "NotifyText"), 300)
            };
        }
        const exitStatus = _get(raw, "ExitNodeStatus");
        if (_isObject(exitStatus)) {
            result.exitNodeStatus = {
                id: _string(_get(exitStatus, "ID"), 128),
                online: _bool(_get(exitStatus, "Online")),
                addresses: _strings(_get(exitStatus, "TailscaleIPs"), 16).map(prefix => prefix.replace(/\/\d+$/, ""))
            };
        }
        return result;
    }

    // ---- Prefs ----

    // `tailscale debug prefs` (text or object; also the Prefs of a bus message) → { ok,
    // error, controlUrl, acceptRoutes, exitNodeId, exitNodeIp, exitNodeAllowLan, acceptDns,
    // ssh, webClient, wantRunning, loggedOut, shieldsUp, advertiseTags [], hostname,
    // advertiseRoutes [] (without the exit-node pair), advertiseExitNode, operatorUser,
    // profileName, loginName, updateCheck, autoUpdate (true / false / null unset) }.
    // Missing fields take Tailscale's own defaults (accept DNS on, the rest off).
    function parsePrefs(input) {
        const result = {
            ok: false, error: "", controlUrl: "", acceptRoutes: false, exitNodeId: "", exitNodeIp: "",
            exitNodeAllowLan: false, acceptDns: true, ssh: false, webClient: false, wantRunning: false,
            loggedOut: false, shieldsUp: false, advertiseTags: [], hostname: "", advertiseRoutes: [],
            advertiseExitNode: false, operatorUser: "", profileName: "", loginName: "", updateCheck: true,
            autoUpdate: null
        };
        const parsed = _parseJson(input);
        if (!_isObject(parsed.value)) {
            result.error = parsed.error || "not an object";
            return result;
        }
        const raw = parsed.value;
        result.ok = true;
        result.controlUrl = safeUrl(_get(raw, "ControlURL"));
        result.acceptRoutes = _bool(_get(raw, "RouteAll"));
        result.exitNodeId = _string(_get(raw, "ExitNodeID"), 128);
        result.exitNodeIp = _string(_get(raw, "ExitNodeIP"), 64);
        result.exitNodeAllowLan = _bool(_get(raw, "ExitNodeAllowLANAccess"));
        result.acceptDns = _bool(_get(raw, "CorpDNS"), true);
        result.ssh = _bool(_get(raw, "RunSSH"));
        result.webClient = _bool(_get(raw, "RunWebClient"));
        result.wantRunning = _bool(_get(raw, "WantRunning"));
        result.loggedOut = _bool(_get(raw, "LoggedOut"));
        result.shieldsUp = _bool(_get(raw, "ShieldsUp"));
        result.advertiseTags = _strings(_get(raw, "AdvertiseTags"), 64);
        result.hostname = _string(_get(raw, "Hostname"), 256);
        const routes = _strings(_get(raw, "AdvertiseRoutes"), 256);
        // The exit node is advertised as the two default routes (ipn/prefs.go)
        result.advertiseExitNode = routes.includes("0.0.0.0/0") && routes.includes("::/0");
        result.advertiseRoutes = routes.filter(route => route !== "0.0.0.0/0" && route !== "::/0");
        result.operatorUser = _string(_get(raw, "OperatorUser"), 64);
        result.profileName = _string(_get(raw, "ProfileName"), 200);
        const config = _get(raw, "Config");
        result.loginName = _string(_get(_get(config, "UserProfile"), "LoginName"), 200);
        const update = _get(raw, "AutoUpdate");
        result.updateCheck = _bool(_get(update, "Check"), true);
        const apply = _get(update, "Apply");
        result.autoUpdate = typeof apply === "boolean" ? apply : null;
        return result;
    }

    // ---- Who may change Tailscale ----

    // facts { userName, uid }: root, or the prefs' operator, may change without pkexec. An
    // unknown operator (prefs unread) counts as "may not": the buttons then carry the
    // privileged mark, and a change that turns out allowed simply runs without a prompt.
    function canChange(prefs, facts) {
        if (_number(_get(facts, "uid"), -1) === 0)
            return true;
        const user = _string(_get(facts, "userName"), 64);
        return user !== "" && _string(_get(prefs, "operatorUser"), 64) === user;
    }

    // ---- State ----

    // The peers of a parsed status — only nodes as _node makes them, whatever else a caller
    // passed in their place
    function _peersOf(status) {
        const list = _isObject(status) && Array.isArray(status.peers) ? status.peers : [];
        return list.filter(peer => _isObject(peer) && typeof peer.id === "string" && typeof peer.dnsName === "string"
            && Array.isArray(peer.addresses) && Array.isArray(peer.primaryRoutes) && Array.isArray(peer.tags));
    }

    function _peerById(status, id) {
        if (!id)
            return null;
        return _peersOf(status).find(peer => peer.id === id) ?? null;
    }

    // The exit node in use: { id, node (or null), online, name } or null
    function currentExitNode(status, prefs) {
        const peers = _peersOf(status);
        const statusId = status?.exitNodeStatus?.id ?? "";
        const prefsId = _string(_get(prefs, "exitNodeId"), 128);
        const id = statusId || prefsId || (peers.find(peer => peer.exitNode)?.id ?? "");
        const node = _peerById(status, id) ?? peers.find(peer => peer.exitNode) ?? null;
        if (!id && !node) {
            const ip = _string(_get(prefs, "exitNodeIp"), 64);
            if (!ip)
                return null;
            const byIp = peers.find(peer => peer.addresses.includes(ip)) ?? null;
            return { id: byIp?.id ?? "", node: byIp, online: byIp?.online ?? false, name: byIp ? exitNodeLabel(byIp) : ip };
        }
        const online = status?.exitNodeStatus && (!id || status.exitNodeStatus.id === id) ? status.exitNodeStatus.online : (node?.online ?? false);
        return { id: id || node?.id || "", node: node, online: online, name: node ? exitNodeLabel(node) : id };
    }

    function _attention(kind, reason, action) {
        return { kind: kind, reason: reason, action: action };
    }

    // The state of the one entry: status, prefs as parsed (either may be null: not read
    // yet) and facts the live side knows:
    //   cli          "present" | "missing" (the tailscale program is not on PATH) |
    //                "untrusted" (a program found could be changed by this user: nothing runs;
    //                untrustedReason says which)
    //   stale        bool — the last read timed out: the state is unknown
    //   daemon       "running" | "not-running" (an errorKind "not-running" from a read)
    //   readDenied   bool — this user may not even read Tailscale's state
    //   operation    "connect" | "disconnect" | "login" | "logout" | "" — one in flight
    //   authUrl      a login URL the running `login` printed (when status has none yet)
    //   exitNodeOfflineSince  ms when the exit node was first seen offline (0 unknown)
    //   updateManagedBySystem bool — the package is the system's (NixOS): say so, never run
    //   now          ms
    // → { state, attention { kind, reason, action } | null, status (the short line beside
    //     the state, ≤ 80 characters: the entry's `status`), summary (= status), phase,
    //     warnings [{ kind, text }], authUrl, exitNode (currentExitNode) }
    // `phase`: "unknown" | "missing" | "untrusted" | "not-running" | "denied" | "other-user" |
    //   "logged-out" | "needs-login" | "key-expired" | "needs-approval" | "stopped" |
    //   "starting" | "running" — what the plans below decide on.
    // Attention only for lasting states; a login in progress, starting, connecting are
    // "activating" with a status line, no attention.
    function stateOf(status, prefs, facts) {
        const now = _number(_get(facts, "now"), 0);
        const operation = _string(_get(facts, "operation"), 32);
        const warnings = [];
        const view = {
            state: "", attention: null, status: "", summary: "", phase: "unknown", warnings: warnings,
            authUrl: safeUrl(_get(facts, "authUrl")) || (status?.authUrl ?? ""), exitNode: null
        };
        const finish = () => {
            view.status = _clip(view.status, 80);
            view.summary = view.status;
            return view;
        };
        if (_get(facts, "cli") === "missing") {
            view.phase = "missing";
            view.attention = _attention("not-installed", "Tailscale is not installed on this computer", "");
            view.status = "Not installed";
            return finish();
        }
        if (_get(facts, "cli") === "untrusted") {
            view.phase = "untrusted";
            view.attention = _attention("untrusted", _string(_get(facts, "untrustedReason"), 300)
                || "The tailscale program found is not trusted (this user could change it): nothing is run", "");
            view.status = "Not trusted";
            return finish();
        }
        if (_get(facts, "daemon") === "not-running") {
            view.phase = "not-running";
            view.attention = _attention("service-not-running", "The Tailscale service (tailscaled) is not running", "Start");
            view.status = "Service not running";
            return finish();
        }
        if (_get(facts, "readDenied") === true) {
            view.phase = "denied";
            view.attention = _attention("read-denied", "This user may not read Tailscale's state", "");
            view.status = "Not readable";
            return finish();
        }
        if (_get(facts, "stale") === true) {
            // The last read timed out: what was read before may be false now — not shown as
            // the state (the entry stays listed, off, with this line); re-read with a backoff
            view.phase = "unknown";
            view.status = operation === "connect" ? "Connecting…" : (operation === "disconnect" ? "Disconnecting…" : "Not answering — state unknown");
            view.state = operation === "connect" ? "activating" : (operation === "disconnect" ? "deactivating" : "");
            return finish();
        }
        if (!status || status.ok !== true) {
            view.phase = "unknown";
            view.status = operation === "connect" || operation === "login" ? "Connecting…" : "";
            view.state = view.status !== "" ? "activating" : "";
            return finish();
        }
        const backend = status.backendState;
        const loggedOut = _get(prefs, "loggedOut") === true;
        const self = _isObject(status.self) && typeof status.self.keyExpiry === "number" ? status.self : null;
        const keyExpired = self !== null && (self.expired || (self.keyExpiry > 0 && now > 0 && self.keyExpiry <= now)) && !loggedOut;
        const loggingIn = operation === "login" || operation === "connect";

        if (backend === "NeedsLogin" || (loggedOut && (backend === "Stopped" || backend === "NoState"))) {
            view.phase = keyExpired ? "key-expired" : (loggedOut || !status.haveNodeKey ? "logged-out" : "needs-login");
            if (loggingIn) {
                // A login in progress is transient: the browser is (or will be) open
                view.state = "activating";
                view.status = view.authUrl !== "" ? "Waiting for the login in the browser…" : "Logging in…";
            } else if (keyExpired) {
                view.attention = _attention("key-expired", "This computer's Tailscale key has expired: log in again", "Log in");
                view.status = "Key expired";
            } else {
                view.attention = _attention("login", "Log in to Tailscale to connect", "Log in");
                view.status = "Logged out";
            }
        } else if (backend === "NeedsMachineAuth") {
            view.phase = "needs-approval";
            view.attention = _attention("approval", "Waiting for a tailnet administrator to approve this computer", "Approve…");
            view.status = "Waiting for approval";
        } else if (backend === "InUseOtherUser") {
            view.phase = "other-user";
            view.attention = _attention("other-user", "Tailscale is in use by another user of this computer", "");
            view.status = "In use by another user";
        } else if (backend === "Stopped") {
            view.phase = "stopped";
            view.state = operation === "connect" ? "activating" : "";
            view.status = operation === "connect" ? "Connecting…" : "Off";
        } else if (backend === "Starting" || backend === "NoState") {
            view.phase = "starting";
            const stopping = operation === "disconnect" || operation === "logout";
            // NoState with WantRunning off is a daemon that is idle, not one starting
            const wanted = backend === "Starting" || _get(prefs, "wantRunning") === true || loggingIn;
            view.state = stopping ? "deactivating" : (wanted ? "activating" : "");
            view.status = stopping ? "Disconnecting…" : (wanted ? "Starting…" : "Off");
        } else if (backend === "Running") {
            view.phase = "running";
            const stopping = operation === "disconnect" || operation === "logout";
            view.state = stopping ? "deactivating" : "activated";
            view.exitNode = currentExitNode(status, prefs);
            if (stopping)
                view.status = "Disconnecting…";
            else if (view.exitNode)
                view.status = "Via " + view.exitNode.name;
            else
                view.status = "Tailnet only";
            if (view.exitNode && !view.exitNode.online && !stopping) {
                const since = _number(_get(facts, "exitNodeOfflineSince"), 0);
                const lasting = since <= 0 || now <= 0 || now - since >= exitNodeOfflineGraceMs;
                const sentence = "Exit node " + view.exitNode.name + " is offline: no internet traffic until it returns or another is chosen";
                if (lasting)
                    view.attention = _attention("exit-node-offline", sentence, "Use none");
                else
                    warnings.push({ kind: "exit-node-offline", text: sentence });
                view.status = "Via " + view.exitNode.name + " (offline)";
            }
        } else {
            view.phase = "unknown";
            warnings.push({ kind: "unknown-state", text: "Tailscale reports a state this module does not know: " + (backend || "none") });
        }

        // A key about to expire: a warning, never attention — nothing renews it without harm (a
        // bare `login` while logged in drops the connection at once and, with the same
        // account, resets this device's settings: tailscale.md §8 step 2). Within
        // reauthSoonDays the entry's status line says it too (the popup row, the card).
        const expiry = keyExpiryWarning(self, now);
        const key = keyState(self, now);
        if (expiry && expiry.kind === "key-expiring" && view.phase !== "logged-out") {
            warnings.push(expiry);
            if (key.state === "soon" && view.state === "activated" && view.status !== "")
                view.status += " · key " + key.text;
        }
        for (const text of _strings(status.health, 64))
            warnings.push({ kind: "health", text: text });
        if (_isObject(status.clientVersion) && status.clientVersion.runningLatest === false && _string(status.clientVersion.latestVersion, 64) !== "") {
            const managed = _get(facts, "updateManagedBySystem") === true;
            warnings.push({
                kind: "update",
                text: "Tailscale " + status.clientVersion.latestVersion + " is available"
                    + (managed ? " — updated with the system, not here" : "")
            });
        }
        return finish();
    }

    // ---- The provider entry ----

    // The tailnet as the card and the page show it: CurrentTailnet.Name when it is a name (an
    // organisation's tailnet); for a personal tailnet that name IS the account's e-mail
    // address, which belongs in the account row — then the tailnet's MagicDNS suffix
    // ("tail1234.ts.net") names it; else facts.lastTailnet (what the live side remembers, so
    // a logged-out or stopped entry keeps its name), else "".
    function tailnetName(status, facts) {
        const tailnet = _isObject(status) && _isObject(status.tailnet) ? status.tailnet : {};
        const remembered = _string(_get(facts, "lastTailnet"), 200);
        const name = _string(tailnet.name, 200);
        return (isEmailLike(name) ? "" : name) ||_string(tailnet.magicDnsSuffix, 200) || _string(_isObject(status) ? status.magicDnsSuffix : "", 200)
            || (isEmailLike(remembered) ? "" : remembered);
    }

    // An account's e-mail address rather than a name (a personal tailnet is named so)
    function isEmailLike(text) {
        return typeof text === "string" && text.indexOf("@") >= 0;
    }

    // The tailnet's name as the ENTRY's name shows it (the VPN list's label, on a shared
    // screen; the core's page frame titles the page with it): a named (organisation)
    // tailnet's display name, CurrentTailnet.Name — never an e-mail address (a personal
    // tailnet: ""), never the MagicDNS suffix; while no tailnet is current (logged out, the
    // daemon down) facts.lastTailnet. That is also the only thing the live side remembers.
    // The account is on the card.
    function entryTailnet(status, facts) {
        const tailnet = _isObject(status) && _isObject(status.tailnet) ? status.tailnet : {};
        const name = _string(tailnet.name, 200) || _string(_get(facts, "lastTailnet"), 200);
        return isEmailLike(name) ? "" : name;
    }

    // The ONE provider entry, in every state (logged out, daemon down, CLI missing, status
    // unreadable): a provider that reports no entry lets the shell delete the user's "VPN
    // with a network" setting. → { id, name, state, attention { reason, action } | null,
    // detail, active, status, busy }
    //   name     "Tailscale · <tailnet>" (entryTailnet: never an e-mail address), else
    //            "Tailscale"
    //   detail   while up: { server (the exit node, else the control server's host), iface
    //            (tailscale0 unless userspace networking; facts.interfaceName overrides),
    //            interfaceName, addresses (this computer's Tailscale IPs), dns
    //            ([100.100.100.100] while accept-DNS is on) }; else {}
    //   busy     facts.operation is not ""
    function entry(status, prefs, facts) {
        const view = stateOf(status, prefs, facts);
        const tailnet = entryTailnet(status, facts);
        const detail = {};
        if (view.state === "activated" || view.state === "deactivating") {
            const interfaceName = /^[A-Za-z0-9_.-]{1,15}$/.test(_string(_get(facts, "interfaceName"), 15))
                ? _get(facts, "interfaceName") : defaultInterface;
            if (status?.tun !== false) {
                detail.iface = interfaceName;
                detail.interfaceName = interfaceName;
            }
            detail.addresses = _strings(status?.addresses, 8);
            if (view.exitNode)
                detail.server = view.exitNode.node?.dnsName || view.exitNode.name;
            else
                detail.server = _hostOf(_string(_get(prefs, "controlUrl"), 512));
            if (_get(prefs, "acceptDns") !== false && status?.tailnet?.magicDnsEnabled !== false)
                detail.dns = [quadHundred];
        }
        return {
            id: entryId,
            name: tailnet !== "" ? typeName + " · " + tailnet : typeName,
            state: view.state,
            attention: view.attention ? { reason: view.attention.reason, action: view.attention.action } : null,
            detail: detail,
            active: view.state !== "",
            status: view.status,
            busy: _string(_get(facts, "operation"), 32) !== ""
        };
    }

    function _hostOf(url) {
        const match = /^https?:\/\/([^/:?#]+)/i.exec(url);
        return match ? match[1].toLowerCase() : "";
    }

    // ---- Plans: what connect / disconnect / attend do ----
    //
    // `view` is stateOf's, `changeAllowed` canChange's, `origin` the contract's
    // request.origin: "network" (the shell bringing the VPN up or down with a network,
    // unattended: never a password prompt, never a browser — attention instead, state back
    // to ""), anything else "user" (a click; as VpnManager reads it). → { kind, command,
    // privileged, attention, url }:
    //   kind "run"         run `command` (commandFor's); `privileged`: through pkexec
    //                      (privileged(argv, path)) — only ever with origin "user"
    //        "needs-user"  do nothing; set `attention` (lasting until the user acts)
    //        "open-url"    open `url` in the browser (origin "user" only)
    //        "read"        the state is not known (not read yet, or the last read timed
    //                      out): re-read, and do nothing until it is — never a blind `up`
    //        "nothing"     already there, or nothing can be done (`attention` says why, if
    //                      anything should)

    function _plan(kind, extra) {
        return Object.assign({ kind: kind, command: null, privileged: false, attention: null, url: "" }, extra ?? {});
    }

    function _privilegedRun(name, changeAllowed, origin, args, attentionIfUnattended) {
        const command = commandFor(name, args);
        if (!command.ok)
            return _plan("nothing", { attention: _attention("error", command.error, "") });
        if (changeAllowed)
            return _plan("run", { command: command });
        if (origin === "network")
            return _plan("needs-user", { attention: attentionIfUnattended });
        return _plan("run", { command: command, privileged: true });
    }

    function planConnect(view, changeAllowed, origin) {
        const phase = view?.phase ?? "unknown";
        if (phase === "running" || phase === "starting")
            return _plan("nothing");
        if (phase === "logged-out" || phase === "needs-login" || phase === "key-expired") {
            if (origin === "network")
                return _plan("needs-user", { attention: view.attention ?? _attention("login", "Log in to Tailscale to connect", "Log in") });
            return _privilegedRun("login", changeAllowed, origin, {}, null);
        }
        if (phase === "unknown")
            return _plan("read");
        if (phase === "stopped")
            return _privilegedRun("connect", changeAllowed, origin, {},
                _attention("needs-privilege", "Connecting Tailscale with this network needs an administrator's password, or this user as its operator", "Connect"));
        // missing, not running, denied, other user, needs approval: the attention says it
        return origin === "network" && view?.attention ? _plan("needs-user", { attention: view.attention }) : _plan("nothing", { attention: view?.attention ?? null });
    }

    // options { connecting }: a connect is still pending (its `up` waiting for Running): it is
    // no longer waited for, and `down` runs whatever the phase says — the bare `up` set
    // WantRunning, and the daemon would otherwise keep trying
    function planDisconnect(view, changeAllowed, origin, options) {
        const phase = view?.phase ?? "unknown";
        if (phase !== "running" && phase !== "starting" && _get(options, "connecting") !== true)
            return phase === "unknown" ? _plan("read") : _plan("nothing");
        return _privilegedRun("disconnect", changeAllowed, origin, {},
            _attention("needs-privilege", "Disconnecting Tailscale with this network needs an administrator's password, or this user as its operator", "Disconnect"));
    }

    // The attention's action (always the user's: attend is a click)
    function planAttend(view, changeAllowed, origin) {
        const kind = view?.attention?.kind ?? "";
        if (origin === "network")
            return view?.attention ? _plan("needs-user", { attention: view.attention }) : _plan("nothing");
        if (kind === "login" || kind === "key-expired")
            return _privilegedRun("login", changeAllowed, origin, {}, null);
        if (kind === "approval")
            return _plan("open-url", { url: adminMachinesUrl });
        if (kind === "service-not-running")
            return _plan("run", { command: commandFor("startService", {}) });
        if (kind === "exit-node-offline")
            return _privilegedRun("exitNodeNone", changeAllowed, origin, {}, null);
        if (kind === "needs-privilege")
            return view.phase === "running" || view.phase === "starting"
                ? planDisconnect(view, changeAllowed, origin) : planConnect(view, changeAllowed, origin);
        return _plan("nothing");
    }

    // ---- Devices ----

    // How traffic to a peer goes: "offline" | "direct" | "peer-relay" | "relayed" | "idle"
    function connectionOf(node) {
        if (!node || !node.online)
            return "offline";
        if (node.curAddr !== "")
            return "direct";
        if (node.peerRelay !== "")
            return "peer-relay";
        if (node.active && node.relay !== "")
            return "relayed";
        return "idle";
    }

    function isLocationNode(node) {
        return !!node && (/\.mullvad\.ts\.net$/i.test(node.dnsName) || (node.location !== null && node.location.countryCode !== "" && node.exitNodeOption));
    }

    // A node of another tailnet shared into this one: its name is not under this tailnet's
    // MagicDNS suffix, or it was shared by someone else (AltSharerUserID)
    function _sharedIn(node, suffix) {
        if (node.altSharerUserId !== "")
            return true;
        return suffix !== "" && node.dnsName !== "" && !node.dnsName.toLowerCase().endsWith("." + suffix.toLowerCase());
    }

    function _shortName(node) {
        const first = node.dnsName.split(".")[0];
        return first || node.hostName || node.id || "?";
    }

    // The devices for the page: peers(status, now, options) → [{ id, key, name, hostName,
    // dnsName, addresses, ipv4, os, owner, ownerName, tags, online, lastSeen (ms, 0 =
    // unknown or online), lastSeenText, connection, exitNodeOption, isExitNode,
    // subnetRoutes, keyExpired, keyExpiry, rxBytes, txBytes, canReceiveFiles,
    // fileSharingNote, sharedIn, locationNode, location }], online first, then by name
    // (then id: stable). options { includeLocationNodes (false: Mullvad nodes are not
    // devices), includeSharees (false: hidden as the CLI hides them) }
    function peers(status, now, options) {
        const suffix = _string(status?.magicDnsSuffix, 256);
        const users = _isObject(status?.users) ? status.users : _dict();
        const list = [];
        for (const node of _peersOf(status)) {
            if (!options?.includeSharees && node.shareeNode)
                continue;
            const locationNode = isLocationNode(node);
            if (!options?.includeLocationNodes && locationNode)
                continue;
            const user = node.userId !== "" && Object.prototype.hasOwnProperty.call(users, node.userId) ? users[node.userId] : null;
            const taildrop = node.taildropTarget;
            list.push({
                id: node.id, key: node.key, name: _shortName(node), hostName: node.hostName, dnsName: node.dnsName,
                addresses: node.addresses, ipv4: node.addresses.find(address => _parseIpv4(address) !== null) ?? "",
                os: node.os, owner: user?.loginName ?? "", ownerName: user?.displayName ?? "",
                tags: node.tags, online: node.online,
                lastSeen: node.online ? 0 : node.lastSeen,
                lastSeenText: node.online ? "online" : (node.lastSeen > 0 ? ago(node.lastSeen, now) : "never"),
                connection: connectionOf(node), exitNodeOption: node.exitNodeOption, isExitNode: node.exitNode,
                subnetRoutes: node.primaryRoutes.filter(route => route !== "0.0.0.0/0" && route !== "::/0"),
                keyExpired: node.expired || (node.keyExpiry > 0 && now > 0 && node.keyExpiry <= now),
                keyExpiry: node.keyExpiry, rxBytes: node.rxBytes, txBytes: node.txBytes,
                canReceiveFiles: taildrop === 1,
                fileSharingNote: taildrop === 1 ? "" : (node.noFileSharingReason || (taildrop >= 0 && taildrop < _taildropReasons.length ? _taildropReasons[taildrop] : "unknown")),
                sharedIn: _sharedIn(node, suffix), locationNode: locationNode, location: node.location
            });
        }
        return list.sort((a, b) => (a.online === b.online ? 0 : (a.online ? -1 : 1))
            || _compareText(a.name, b.name) || _compareText(a.id, b.id));
    }

    function _compareText(a, b) {
        const left = String(a).toLowerCase();
        const right = String(b).toLowerCase();
        return left < right ? -1 : (left > right ? 1 : (a < b ? -1 : (a > b ? 1 : 0)));
    }

    // ---- Exit nodes ----

    // How an exit node is named: a location node "City, Country" (or the country), any
    // other the first label of its DNS name (its host name, its id)
    function exitNodeLabel(node) {
        if (!node)
            return "";
        if (node.location && (node.location.city || node.location.country) && isLocationNode(node))
            return [node.location.city, node.location.country].filter(part => part).join(", ");
        return _shortName(node);
    }

    // The argument `tailscale set --exit-node=` takes for a node: its IPv4 address (the
    // CLI takes "IP, base name, or auto:any"; an address cannot be ambiguous), else its
    // name. "" when it has neither.
    function exitNodeArgument(node) {
        if (!node)
            return "";
        const ipv4 = (node.addresses ?? []).find(address => _parseIpv4(address) !== null);
        return ipv4 ?? (node.addresses?.[0] ?? node.dnsName ?? "");
    }

    // exitNodes(status, prefs, suggested) → { own [option], countries [{ country,
    // countryCode, cities [{ city, cityCode, best, nodes [option] }] }], current option |
    // null, suggested option | null, count }. An option: { id, name, label, dnsName,
    // argument, online, current, suggested, location, priority }. `suggested`: a node id
    // (the bus's SuggestedExitNode) or a DNS name (`exit-node suggest`'s answer).
    // Own nodes: online first, then by name; countries and cities by name; a city's nodes
    // by priority (highest first), then name; `best` is its first online node.
    function exitNodes(status, prefs, suggested) {
        const current = currentExitNode(status, prefs);
        const wanted = typeof suggested === "string" ? suggested.replace(/\.+$/, "").toLowerCase() : "";
        const options = [];
        for (const node of _peersOf(status)) {
            if (!node.exitNodeOption && !(current && current.id !== "" && node.id === current.id))
                continue;
            options.push({
                id: node.id, name: _shortName(node), label: exitNodeLabel(node), dnsName: node.dnsName,
                argument: exitNodeArgument(node), online: node.online,
                current: !!current && current.id !== "" && node.id === current.id,
                suggested: wanted !== "" && (node.id.toLowerCase() === wanted || node.dnsName.toLowerCase() === wanted),
                location: node.location, priority: node.location?.priority ?? 0, locationNode: isLocationNode(node)
            });
        }
        const own = options.filter(option => !option.locationNode).sort((a, b) =>
            (a.online === b.online ? 0 : (a.online ? -1 : 1)) || _compareText(a.name, b.name) || _compareText(a.id, b.id));
        const byCountry = _dict();
        for (const option of options.filter(option => option.locationNode)) {
            const countryKey = option.location?.countryCode || option.location?.country || "?";
            if (!byCountry[countryKey])
                byCountry[countryKey] = { country: option.location?.country || countryKey, countryCode: option.location?.countryCode ?? "", cityMap: _dict() };
            const cityKey = option.location?.cityCode || option.location?.city || "?";
            const cities = byCountry[countryKey].cityMap;
            if (!cities[cityKey])
                cities[cityKey] = { city: option.location?.city || cityKey, cityCode: option.location?.cityCode ?? "", nodes: [] };
            cities[cityKey].nodes.push(option);
        }
        const countries = Object.keys(byCountry).map(key => {
            const country = byCountry[key];
            const cities = Object.keys(country.cityMap).map(cityKey => {
                const city = country.cityMap[cityKey];
                city.nodes.sort((a, b) => b.priority - a.priority || _compareText(a.name, b.name) || _compareText(a.id, b.id));
                city.best = city.nodes.find(node => node.online) ?? null;
                return city;
            }).sort((a, b) => _compareText(a.city, b.city));
            return { country: country.country, countryCode: country.countryCode, cities: cities };
        }).sort((a, b) => _compareText(a.country, b.country));
        return {
            own: own, countries: countries,
            current: options.find(option => option.current) ?? null,
            suggested: options.find(option => option.suggested) ?? null,
            count: options.length
        };
    }

    // `tailscale exit-node suggest` → { name, none }: "Suggested exit node: <name>" (from
    // the source, cmd/tailscale/cli/exitnode.go), or "No exit node suggestion is available."
    function parseExitNodeSuggest(text) {
        const value = typeof text === "string" ? text.slice(0, 65536) : "";
        const match = /^Suggested exit node:\s*(\S+)/m.exec(value);
        if (match)
            return { name: match[1].replace(/\.+$/, ""), none: false };
        return { name: "", none: /No exit node suggestion is available/.test(value) };
    }

    // ---- Accounts ----

    // `tailscale switch --list` as a table ("ID  Tailnet  Account", the current account
    // with "*" after it) or with --json ([{ id, nickname, tailnet, account, selected }]) →
    // [{ id, nickname, tailnet, account, selected }]; rows that do not fit are skipped.
    function parseSwitchList(input) {
        const result = [];
        const text = typeof input === "string" ? input.slice(0, 1048576) : "";
        const trimmed = text.trim();
        if (Array.isArray(input) || trimmed.startsWith("[")) {
            const parsed = _parseJson(Array.isArray(input) ? input : trimmed);
            if (!Array.isArray(parsed.value))
                return result;
            for (const item of parsed.value.slice(0, 256)) {
                const id = _string(_get(item, "id"), 64);
                if (!accountIdPattern.test(id) || result.some(account => account.id === id))
                    continue;
                result.push({
                    id: id, nickname: _string(_get(item, "nickname"), 200), tailnet: _string(_get(item, "tailnet"), 200),
                    account: _string(_get(item, "account"), 200), selected: _get(item, "selected") === true
                });
            }
            return result;
        }
        for (const line of text.split("\n").slice(0, 257)) {
            const columns = line.trim().split(/\s{2,}/);
            if (columns.length < 3 || columns[0] === "ID")
                continue;
            const id = columns[0];
            if (!accountIdPattern.test(id) || result.some(account => account.id === id))
                continue;
            // A name holding two spaces would split in more columns: the account is last
            let account = columns[columns.length - 1];
            const selected = account.endsWith("*");
            if (selected)
                account = account.slice(0, -1);
            result.push({ id: id, nickname: "", tailnet: columns.slice(1, -1).join("  ").slice(0, 200), account: account.slice(0, 200), selected: selected });
        }
        return result;
    }

    // The accounts as the page lists them: accountRows(accounts) → [{ id, title, subtitle,
    // selected, removable }]. Title: the nickname, else the tailnet when it is a name, else
    // the account; the subtitle the account's e-mail address (it belongs here, on the page's
    // own list — never in the VPN entry's name) and the tailnet when it adds something. The
    // current account cannot be removed from here (Tailscale would leave this computer on an
    // empty profile): switch first, or log out.
    function accountRows(accounts) {
        const list = Array.isArray(accounts) ? accounts : [];
        return list.filter(account => _isObject(account) && typeof account.id === "string" && accountIdPattern.test(account.id)).map(account => {
            const tailnet = _string(account.tailnet, 200);
            const login = _string(account.account, 200);
            const nickname = _string(account.nickname, 200);
            const tailnetIsName = tailnet !== "" && !isEmailLike(tailnet);
            const title = nickname || (tailnetIsName ? tailnet : "") || login || account.id;
            const subtitle = [login !== title ? login : "", tailnetIsName && tailnet !== title ? tailnet : ""].filter(part => part !== "").join(" · ");
            return { id: account.id, title: title, subtitle: subtitle, selected: account.selected === true, removable: account.selected !== true };
        });
    }

    // After a switch or a removal the list read before is updated in place (reading it again
    // asks for a password while this user is not the operator): accountsAfter(accounts,
    // change) — change { switched: id } | { removed: id } → a new list
    function accountsAfter(accounts, change) {
        const list = Array.isArray(accounts) ? accounts.filter(account => _isObject(account)) : [];
        const switched = _string(_get(change, "switched"), 64);
        const removed = _string(_get(change, "removed"), 64);
        if (switched !== "" && list.some(account => account.id === switched))
            return list.map(account => Object.assign({}, account, { selected: account.id === switched }));
        if (removed !== "")
            return list.filter(account => account.id !== removed || account.selected === true);
        return list.slice();
    }

    // The account in use, from what any user may read (status, prefs — the list itself needs
    // root or the operator): { loginName, displayName, tailnet (tailnetName), nickname }
    function currentAccount(status, prefs) {
        const self = _isObject(status) && _isObject(status.self) ? status.self : null;
        const users = _isObject(status) && _isObject(status.users) ? status.users : {};
        const user = self && self.userId !== "" && Object.prototype.hasOwnProperty.call(users, self.userId) ? users[self.userId] : null;
        return {
            loginName: _string(_get(prefs, "loginName"), 200) || _string(user?.loginName, 200),
            displayName: _string(user?.displayName, 200),
            tailnet: tailnetName(status, {}),
            nickname: _string(_get(prefs, "profileName"), 200)
        };
    }

    // Whether the list read before still matches the daemon: false once the account in use
    // (status/prefs) is not the one the list marks — another program switched, or a login
    // added one. Unknown either way: true (nothing to say)
    function accountsCurrent(accounts, loginName) {
        const list = Array.isArray(accounts) ? accounts : [];
        const selected = list.find(account => _isObject(account) && account.selected === true);
        if (!selected || typeof loginName !== "string" || loginName === "")
            return true;
        return _string(selected.account, 200).toLowerCase() === loginName.toLowerCase();
    }

    // ---- This device ----

    // How long before the key expires it is "about to": the entry's status line says so from
    // this many days on (never attention: see stateOf); keyExpiryWarningDays warns
    readonly property int reauthSoonDays: 7

    // The key's state: keyState(self, now) → { state, days, text }:
    //   "unknown"   no self, or no clock
    //   "disabled"  key expiry is off for this computer (KeyExpiry missing / zero time)
    //   "valid"     more than keyExpiryWarningDays away
    //   "warning"   within keyExpiryWarningDays (a warning)
    //   "soon"      within reauthSoonDays (≤ 7 days, the first second of day 8 is "warning"):
    //               the entry's status line says it too
    //   "expired"   past (or the control server says so)
    // `days` whole days left, rounded up (0 expired); `text` "expires in 3 days", "expired".
    function keyState(self, now) {
        const moment = _number(now, 0);
        if (!_isObject(self) || moment <= 0)
            return { state: "unknown", days: 0, text: "" };
        const expiry = _number(self.keyExpiry, 0);
        if (self.expired === true || (expiry > 0 && expiry <= moment))
            return { state: "expired", days: 0, text: "expired" };
        if (expiry <= 0)
            return { state: "disabled", days: 0, text: "never (expiry off)" };
        const remaining = expiry - moment;
        const days = Math.ceil(remaining / 86400000);
        const text = remaining < 86400000 ? "expires within a day" : (days === 1 ? "expires in 1 day" : "expires in " + days + " days");
        const state = days <= reauthSoonDays ? "soon" : (days <= keyExpiryWarningDays ? "warning" : "valid");
        return { state: state, days: days, text: text };
    }

    // This computer for the page's "This device": thisDevice(status, prefs, now) → null (not
    // read) | { hostName (what Tailscale calls it now), customHostname (prefs' --hostname; ""
    // = the system's), dnsName (MagicDNS), ipv4, ipv6, online, relay (home DERP region code),
    // keyExpiry (ms), key (keyState) }
    function thisDevice(status, prefs, now) {
        const self = _isObject(status) && _isObject(status.self) ? status.self : null;
        if (!self)
            return null;
        const addresses = _strings(status.addresses, 16).length > 0 ? _strings(status.addresses, 16) : self.addresses;
        return {
            hostName: self.hostName,
            customHostname: _string(_get(prefs, "hostname"), 256),
            dnsName: self.dnsName,
            ipv4: addresses.find(address => _parseIpv4(address) !== null) ?? "",
            ipv6: addresses.find(address => _parseIpv6(address) !== null) ?? "",
            online: self.online,
            relay: self.relay,
            keyExpiry: self.keyExpiry,
            key: keyState(self, now)
        };
    }

    // A name for `tailscale set --hostname=`, checked as Tailscale's DNS label rules do
    // (util/dnsname: letters, digits and inner dashes, at most 63 bytes) — one label: Tailscale
    // names the device by its first label only, so a dot is refused rather than cut. "" is
    // allowed: back to the system's own name. → "" or what is wrong, as one sentence
    function hostnameProblem(name) {
        if (typeof name !== "string")
            return "Not a name.";
        if (name === "")
            return "";
        if (name.length > 63)
            return "At most 63 characters.";
        if (name.indexOf(".") >= 0)
            return "One name without dots: Tailscale uses only the part before the first dot.";
        const bad = /[^A-Za-z0-9-]/.exec(name);
        if (bad)
            return "Only letters a–z, digits and dashes: " + JSON.stringify(bad[0]) + " is not allowed.";
        if (name.startsWith("-") || name.endsWith("-"))
            return "It must start and end with a letter or a digit.";
        return "";
    }

    // A nickname for the account in use (`tailscale set --nickname=`): plain text, ≤ 64
    // characters, no control characters, not starting with "-" (a flag) → "" or why not.
    // "" is allowed: no nickname
    function nicknameProblem(name) {
        if (typeof name !== "string")
            return "Not a name.";
        if (name.length > 64)
            return "At most 64 characters.";
        if (/[\u0000-\u001f\u007f]/.test(name))
            return "No control characters.";
        if (name.startsWith("-"))
            return "It cannot start with a dash.";
        return "";
    }

    // ---- Diagnostics ----

    // `tailscale debug derp-map` (tailcfg.DERPMap) → { "<region id>": { code, name } }
    function parseDerpMap(input) {
        const result = {};
        const parsed = _parseJson(typeof input === "string" ? _fromFirstBrace(input) : input);
        const regions = _get(parsed.value, "Regions");
        for (const key of _keys(regions).slice(0, 512)) {
            if (!/^\d{1,6}$/.test(key))
                continue;
            const region = _get(regions, key);
            if (!_isObject(region))
                continue;
            result[key] = { code: _string(_get(region, "RegionCode"), 32), name: _string(_get(region, "RegionName"), 100) };
        }
        return result;
    }

    // Some JSON outputs start with a comment line ("# Warning: this JSON format is not yet
    // considered a stable interface", netcheck) or a log line: the JSON from the first "{"
    function _fromFirstBrace(text) {
        const at = text.indexOf("{");
        return at < 0 ? text : text.slice(at);
    }

    // What the latency of a netcheck run means for the page: netcheckSummary(netcheck,
    // derpMap) → { ok, rows [{ label, value }], nearest { id, code, name, ms } | null }.
    // Never this computer's public address (it would show on a shared screen and land in a
    // copied report).
    function netcheckSummary(netcheck, derpMap) {
        if (!_isObject(netcheck) || netcheck.ok !== true)
            return { ok: false, rows: [], nearest: null };
        const regions = _isObject(derpMap) ? derpMap : {};
        const named = region => {
            const known = Object.prototype.hasOwnProperty.call(regions, String(region.id)) ? regions[String(region.id)] : null;
            return known && known.name ? known.name + (known.code ? " (" + known.code + ")" : "") : "region " + region.id;
        };
        const yesNo = value => value === true ? "yes" : (value === false ? "no" : "unknown");
        const preferred = netcheck.regions.find(region => region.id === netcheck.preferredDerp) ?? null;
        const nearest = netcheck.preferredDerp > 0 ? {
            id: netcheck.preferredDerp, code: regions[String(netcheck.preferredDerp)]?.code ?? "",
            name: named({ id: netcheck.preferredDerp }), ms: preferred ? preferred.ms : null
        } : null;
        const mapping = netcheck.portMapping.length > 0 ? netcheck.portMapping.join(", ") : "none";
        const rows = [
            { label: "UDP", value: netcheck.udp ? "yes" : "no — relayed only" },
            { label: "IPv4", value: yesNo(netcheck.ipv4) },
            { label: "IPv6", value: netcheck.ipv6 ? "yes" : (netcheck.osHasIpv6 === true ? "no (the network lacks it)" : "no") },
            { label: "NAT", value: netcheck.mappingVariesByDestIp === true ? "hard — direct connections less likely"
                : netcheck.mappingVariesByDestIp === false ? "easy" : "unknown" },
            { label: "Port mapping", value: mapping },
            { label: "Nearest relay", value: nearest ? nearest.name + (nearest.ms !== null ? ", " + nearest.ms + " ms" : "") : "none" }
        ];
        if (netcheck.captivePortal === true)
            rows.push({ label: "Captive portal", value: "yes — log in to the network" });
        const others = netcheck.regions.filter(region => region.id !== netcheck.preferredDerp).slice(0, 3);
        if (others.length > 0)
            rows.push({ label: "Next relays", value: others.map(region => named(region) + " " + region.ms + " ms").join(", ") });
        return { ok: true, rows: rows, nearest: nearest };
    }

    // `tailscale dns status --json` → { ok, tailscaleDns, magicDns, suffix, selfDnsName,
    // resolvers [address], splitRoutes [{ domain, resolvers [address] }], searchDomains [],
    // systemError }. Real shape from tailscale 1.104.4 (redacted fixture); "Resolvers" is
    // omitted when the tailnet sets none (seen) — its entries are { Addr } as the split
    // routes' are (assumed, the same type)
    function parseDnsStatus(input) {
        const result = { ok: false, tailscaleDns: false, magicDns: false, suffix: "", selfDnsName: "", resolvers: [], splitRoutes: [],
            searchDomains: [], systemError: "" };
        const parsed = _parseJson(typeof input === "string" ? _fromFirstBrace(input) : input);
        if (!_isObject(parsed.value))
            return result;
        const raw = parsed.value;
        const addresses = list => (Array.isArray(list) ? list : []).slice(0, 32)
            .map(item => typeof item === "string" ? item : _string(_get(item, "Addr"), 256)).filter(text => text !== "");
        result.ok = true;
        result.tailscaleDns = _bool(_get(raw, "TailscaleDNS"));
        const tailnet = _get(raw, "CurrentTailnet");
        result.magicDns = _bool(_get(tailnet, "MagicDNSEnabled"));
        result.suffix = _dnsName(_get(tailnet, "MagicDNSSuffix"));
        result.selfDnsName = _dnsName(_get(tailnet, "SelfDNSName"));
        result.resolvers = addresses(_get(raw, "Resolvers"));
        const routes = _get(raw, "SplitDNSRoutes");
        result.splitRoutes = _keys(routes).slice(0, 64).map(domain => ({ domain: domain.slice(0, 256).replace(/\.$/, ""), resolvers: addresses(_get(routes, domain)) }))
            .sort((a, b) => _compareText(a.domain, b.domain));
        result.searchDomains = _strings(_get(raw, "SearchDomains"), 32).map(domain => domain.replace(/\.$/, ""));
        result.systemError = _string(_get(raw, "SystemDNSError"), 300);
        return result;
    }

    // The page's rows for it: dnsSummary(dns) → [{ label, value }]
    function dnsSummary(dns) {
        if (!_isObject(dns) || dns.ok !== true)
            return [];
        const rows = [
            { label: "Tailscale DNS", value: dns.tailscaleDns ? "in use" : "not in use" },
            { label: "MagicDNS", value: dns.magicDns ? "on" + (dns.suffix !== "" ? " — " + dns.suffix : "") : "off" },
            { label: "Resolvers", value: dns.resolvers.length > 0 ? dns.resolvers.join(", ") : "the system's" }
        ];
        if (dns.splitRoutes.length > 0)
            rows.push({ label: "Split DNS", value: dns.splitRoutes.map(route => route.domain + " → " + (route.resolvers.join(", ") || "Tailscale")).join("; ") });
        rows.push({ label: "Search domains", value: dns.searchDomains.length > 0 ? dns.searchDomains.join(", ") : "none" });
        return rows;
    }

    // `tailscale version --json` → { ok, short, long }
    function parseVersion(input) {
        const parsed = _parseJson(typeof input === "string" ? _fromFirstBrace(input) : input);
        if (!_isObject(parsed.value))
            return { ok: false, short: "", long: "" };
        const short = _string(_get(parsed.value, "short"), 64) || _string(_get(parsed.value, "majorMinorPatch"), 64);
        return { ok: short !== "", short: short, long: _string(_get(parsed.value, "long"), 128) || short };
    }

    // A ping's result for a device row: pingSummary(parsed) — parsePing's — → { ok, text }:
    // "direct, 4 ms", "relayed (DERP fra), 31 ms", "via a peer relay, 12 ms", "no reply"
    function pingSummary(parsed) {
        const replies = _isObject(parsed) && Array.isArray(parsed.replies) ? parsed.replies : [];
        const last = replies.length > 0 ? replies[replies.length - 1] : null;
        if (!last)
            return { ok: false, text: "no reply" };
        const route = last.via === "direct" ? "direct" : last.via === "derp" ? "relayed (DERP " + _clip(String(last.detail), 20) + ")"
            : last.via === "peer-relay" ? "via a peer relay" : "replied";
        return { ok: true, text: route + ", " + last.ms + " ms" };
    }

    // The health warnings to show, all of them with their text: the bus's (titles and texts,
    // newer) when it sent any, else status's Health lines. → [{ title, text, severity }]
    function healthList(busHealth, status) {
        if (Array.isArray(busHealth))
            return busHealth.filter(warning => _isObject(warning) && (warning.title || warning.text))
                .map(warning => ({ title: _string(warning.title, 200), text: _string(warning.text, 500), severity: _string(warning.severity, 16) }));
        return _strings(_isObject(status) ? status.health : [], 64).map(text => ({ title: "", text: text, severity: "" }));
    }

    // The text "Copy diagnostics" puts on the clipboard: versions, state, the netcheck and DNS
    // summaries, health — no keys, no login or other URLs, no public address (input has none
    // of those but a health text could carry a URL: cut). report { clientVersion,
    // daemonVersion, backendState, netcheck rows, dns rows, health list, update }
    function diagnosticsText(report) {
        // Links with or without a scheme (a health text may name login.tailscale.com/a/…)
        const strip = text => String(text ?? "").replace(/\b(?:https?:\/\/\S+|[a-z0-9.-]+\.(?:com|net|org|io)\/\S*)/gi, "<link>").replace(/\b(nodekey|privkey|nlpriv|discokey|mkey|tskey)[:-][0-9A-Za-z-]+/gi, "<key>");
        const lines = ["Tailscale diagnostics"];
        lines.push("Client: " + strip(_get(report, "clientVersion") || "unknown") + ", daemon: " + strip(_get(report, "daemonVersion") || "unknown"));
        if (_get(report, "update"))
            lines.push(strip(_get(report, "update")));
        lines.push("State: " + strip(_get(report, "backendState") || "unknown"));
        const section = (title, rows) => {
            if (!Array.isArray(rows) || rows.length === 0)
                return;
            lines.push("", title);
            for (const row of rows)
                lines.push("  " + strip(row.label) + ": " + strip(row.value));
        };
        section("Network (netcheck)", _get(report, "netcheck"));
        section("DNS", _get(report, "dns"));
        const health = _get(report, "health");
        if (Array.isArray(health) && health.length > 0) {
            lines.push("", "Health");
            for (const warning of health)
                lines.push("  " + withoutAddresses(strip([warning.title, warning.text].filter(part => part).join(": "))));
        }
        return lines.join("\n").slice(0, 8000);
    }

    // ---- The IPN bus ----

    // A splitter for a stream of JSON objects, one per line or pretty-printed over many
    // (`tailscale debug watch-ipn` indents them): jsonSplitter() → a state, jsonFeed(state,
    // chunk) → { state, objects [parsed], dropped (pieces that were not JSON objects) }.
    // Text outside an object is skipped; strings and escapes are followed, so braces inside
    // them do not count. An object larger than maxObjectBytes is dropped whole.
    function jsonSplitter() {
        return { buffer: "", depth: 0, inString: false, escaped: false, start: -1, skipping: false };
    }

    function jsonFeed(state, chunk) {
        const next = Object.assign(jsonSplitter(), _isObject(state) ? state : {});
        const objects = [];
        let dropped = 0;
        let text = next.buffer + (typeof chunk === "string" ? chunk : "");
        let index = next.buffer.length;
        // The buffer holds only an object in progress: everything before it was consumed
        for (; index < text.length; index++) {
            const character = text[index];
            if (next.skipping) {
                // Inside an oversized object: follow the nesting to find its end, keep nothing
                if (next.inString) {
                    if (next.escaped)
                        next.escaped = false;
                    else if (character === "\\")
                        next.escaped = true;
                    else if (character === "\"")
                        next.inString = false;
                } else if (character === "\"") {
                    next.inString = true;
                } else if (character === "{") {
                    next.depth++;
                } else if (character === "}") {
                    next.depth--;
                    if (next.depth === 0) {
                        next.skipping = false;
                        dropped++;
                    }
                }
                continue;
            }
            if (next.depth === 0) {
                if (character === "{") {
                    next.start = index;
                    next.depth = 1;
                    next.inString = false;
                    next.escaped = false;
                } else if (character.trim() !== "" && character !== ",") {
                    // Stray text between objects (a warning line, a "[", garbage)
                    if (index === 0 || text[index - 1].trim() === "" || text[index - 1] === "}")
                        dropped++;
                }
                continue;
            }
            if (next.inString) {
                if (next.escaped)
                    next.escaped = false;
                else if (character === "\\")
                    next.escaped = true;
                else if (character === "\"")
                    next.inString = false;
                continue;
            }
            if (character === "\"") {
                next.inString = true;
            } else if (character === "{") {
                next.depth++;
            } else if (character === "}") {
                next.depth--;
                if (next.depth === 0) {
                    const piece = text.slice(next.start, index + 1);
                    try {
                        const value = JSON.parse(piece);
                        if (_isObject(value))
                            objects.push(value);
                        else
                            dropped++;
                    } catch (error) {
                        dropped++;
                    }
                    next.start = -1;
                }
            }
            if (next.depth > 0 && index - next.start + 1 > maxObjectBytes) {
                next.skipping = true;
                next.start = -1;
            }
        }
        if (next.depth > 0 && !next.skipping && next.start >= 0) {
            next.buffer = text.slice(next.start);
            next.start = 0;
        } else {
            next.buffer = "";
            next.start = -1;
        }
        return { state: next, objects: objects, dropped: dropped };
    }

    // One message of the bus (an object, or one line of text) → { ok, kinds [..], state
    // ("" none; the name for the bus's number), browseToUrl, loginFinished, errMessage,
    // health [{ code, severity, title, text, impactsConnectivity }] | null, prefs (parsed)
    // | null, suggestedExitNode, clientVersion | null, files (OutgoingFiles / FilesWaiting
    // / IncomingFiles seen), engine, version }. kinds: "state", "browse", "login-finished",
    // "error", "health", "prefs", "suggested-exit-node", "client-version", "files",
    // "engine", and "changed" when none of those was there.
    function notifyDigest(input) {
        const digest = {
            ok: false, kinds: [], state: "", browseToUrl: "", loginFinished: false, errMessage: "", health: null,
            prefs: null, suggestedExitNode: "", clientVersion: null, files: false, engine: false, version: ""
        };
        const parsed = _parseJson(input);
        if (!_isObject(parsed.value))
            return digest;
        const raw = parsed.value;
        digest.ok = true;
        digest.version = _string(_get(raw, "Version"), 64);
        const stateValue = _get(raw, "State");
        if (typeof stateValue === "number" && Number.isInteger(stateValue) && stateValue >= 0 && stateValue < backendStates.length) {
            digest.state = backendStates[stateValue];
            digest.kinds.push("state");
        } else if (typeof stateValue === "string" && backendStates.includes(stateValue)) {
            digest.state = stateValue;
            digest.kinds.push("state");
        }
        const browse = safeUrl(_get(raw, "BrowseToURL"));
        if (browse !== "") {
            digest.browseToUrl = browse;
            digest.kinds.push("browse");
        }
        const finished = _get(raw, "LoginFinished");
        if (finished !== undefined && finished !== null) {
            digest.loginFinished = true;
            digest.kinds.push("login-finished");
        }
        const message = _get(raw, "ErrMessage");
        if (typeof message === "string" && message !== "") {
            digest.errMessage = message.slice(0, 500);
            digest.kinds.push("error");
        }
        const health = _get(raw, "Health");
        if (_isObject(health)) {
            const warnings = _get(health, "Warnings");
            digest.health = _keys(warnings).slice(0, 64).map(code => {
                const warning = _get(warnings, code);
                return {
                    code: String(code).slice(0, 64), severity: _string(_get(warning, "Severity"), 16),
                    title: _string(_get(warning, "Title"), 200), text: _string(_get(warning, "Text"), 500),
                    impactsConnectivity: _bool(_get(warning, "ImpactsConnectivity"))
                };
            }).sort((a, b) => _compareText(a.code, b.code));
            digest.kinds.push("health");
        }
        const prefs = _get(raw, "Prefs");
        if (_isObject(prefs)) {
            digest.prefs = parsePrefs(prefs);
            digest.kinds.push("prefs");
        }
        const suggestion = _get(raw, "SuggestedExitNode");
        if (typeof suggestion === "string" && suggestion !== "") {
            digest.suggestedExitNode = suggestion.slice(0, 128);
            digest.kinds.push("suggested-exit-node");
        }
        const version = _get(raw, "ClientVersion");
        if (_isObject(version)) {
            digest.clientVersion = {
                runningLatest: _bool(_get(version, "RunningLatest"), true),
                latestVersion: _string(_get(version, "LatestVersion"), 64)
            };
            digest.kinds.push("client-version");
        }
        if (["OutgoingFiles", "FilesWaiting", "IncomingFiles"].some(key => _get(raw, key) !== undefined && _get(raw, key) !== null)) {
            digest.files = true;
            digest.kinds.push("files");
        }
        if (_isObject(_get(raw, "Engine"))) {
            digest.engine = true;
            digest.kinds.push("engine");
        }
        if (digest.kinds.length === 0)
            digest.kinds.push("changed");
        return digest;
    }

    // ---- Output of the CLI ----

    // A URL fit to open or show: http(s), no spaces or control characters, ≤ 2048 — else ""
    function safeUrl(value) {
        if (typeof value !== "string" || value.length > 2048)
            return "";
        return /^https?:\/\/[^\s\u0000-\u001f\u007f"<>\\^`{|}]+$/i.test(value) ? value : "";
    }

    // What `tailscale login` / `up` print while they wait (stderr): → { authUrl,
    // approvalUrl, success }. "To authenticate, visit:" and "To approve your machine, visit
    // (as admin):" are followed by the URL on a line of its own (cmd/tailscale/cli/up.go).
    function parseLoginOutput(text) {
        const value = typeof text === "string" ? text.slice(0, 65536) : "";
        const urlAfter = label => {
            const at = value.indexOf(label);
            if (at < 0)
                return "";
            const match = /^\s*(\S+)/.exec(value.slice(at + label.length));
            return match ? safeUrl(match[1]) : "";
        };
        return {
            authUrl: urlAfter("To authenticate, visit:"),
            approvalUrl: urlAfter("To approve your machine, visit (as admin):"),
            success: /^Success\.\s*$/m.test(value)
        };
    }

    // `tailscale ping` output → [{ via ("direct" | "derp" | "peer-relay" | "other"),
    // detail (the endpoint, the DERP region, the relay), ms }] and timedOut / noReply.
    // Lines: "pong from <name> (<ip>) via <via> in <duration>" (cmd/tailscale/cli/ping.go).
    function parsePing(text) {
        const value = typeof text === "string" ? text.slice(0, 65536) : "";
        const replies = [];
        for (const line of value.split("\n").slice(0, 200)) {
            const match = /^pong from (\S+) \(([^)]*)\) via (\S+) in ([0-9.]+)(ms|s|µs|us)\s*$/.exec(line.trim());
            if (!match)
                continue;
            const factor = match[5] === "s" ? 1000 : (match[5] === "ms" ? 1 : 0.001);
            const via = match[3];
            const derp = /^DERP\(([^)]*)\)$/.exec(via);
            const relay = /^peer-relay\(([^)]*)\)$/.exec(via);
            replies.push({
                name: match[1], address: match[2].split(",")[0].trim(),
                via: derp ? "derp" : (relay ? "peer-relay" : (/^[\[0-9a-fA-F:.\]]+:\d+$/.test(via) ? "direct" : "other")),
                detail: derp ? derp[1] : (relay ? relay[1] : via),
                ms: Math.round(Number(match[4]) * factor * 10) / 10
            });
        }
        return {
            replies: replies, timedOut: /timed out/.test(value), noReply: /\bno reply\b/.test(value),
            directNotEstablished: /direct connection not established/.test(value)
        };
    }

    // `tailscale netcheck --format=json` (netcheck.Report) → { ok, udp, ipv4, ipv6, osHasIpv6
    // (null unknown), mappingVariesByDestIp (null unknown), portMapping ["UPnP", "NAT-PMP",
    // "PCP" — those found], captivePortal (null unknown), preferredDerp, globalV4, regions
    // [{ id, ms }] fastest first }. The shape seen from tailscale 1.104.4 (redacted fixture
    // netcheck-real.json): the JSON comes after a "# Warning: …" line on stdout, and a log line
    // may come before it.
    function parseNetcheck(input) {
        const result = { ok: false, udp: false, ipv4: false, ipv6: false, osHasIpv6: null, mappingVariesByDestIp: null, portMapping: [],
            captivePortal: null, preferredDerp: 0, globalV4: "", regions: [] };
        const parsed = _parseJson(typeof input === "string" ? _fromFirstBrace(input) : input);
        if (!_isObject(parsed.value))
            return result;
        const raw = parsed.value;
        result.ok = true;
        result.udp = _bool(_get(raw, "UDP"));
        result.ipv4 = _bool(_get(raw, "IPv4"));
        result.ipv6 = _bool(_get(raw, "IPv6"));
        const osIpv6 = _get(raw, "OSHasIPv6");
        result.osHasIpv6 = typeof osIpv6 === "boolean" ? osIpv6 : null;
        result.portMapping = [["UPnP", "UPnP"], ["PMP", "NAT-PMP"], ["PCP", "PCP"]].filter(pair => _get(raw, pair[0]) === true).map(pair => pair[1]);
        const portal = _get(raw, "CaptivePortal");
        result.captivePortal = typeof portal === "boolean" ? portal : null;
        const mapping = _get(raw, "MappingVariesByDestIP");
        result.mappingVariesByDestIp = typeof mapping === "boolean" ? mapping : null;
        result.preferredDerp = Math.trunc(_number(_get(raw, "PreferredDERP")));
        result.globalV4 = _string(_get(raw, "GlobalV4"), 64);
        const latency = _get(raw, "RegionLatency");
        result.regions = _keys(latency).slice(0, 256).filter(key => /^\d+$/.test(key) && _number(_get(latency, key), -1) >= 0)
            .map(key => ({ id: Number(key), ms: Math.round(_get(latency, key) / 1e5) / 10 }))
            .sort((a, b) => a.ms - b.ms || a.id - b.id);
        return result;
    }

    // ---- Errors ----

    // A command's failure → { kind, message } — kind:
    //   ""            exit 0
    //   "denied"      "Access denied: …" (LocalAPI's 403 text, the CLI's advice after it):
    //                 this user may not change Tailscale — retry through pkexec (origin user)
    //   "not-running" the daemon cannot be reached
    //   "revert"      `tailscale up` refused because flags would reset settings (the module
    //                 never passes flags to `up`; recognised so that it shows, not hides)
    //   "needs-login" logged out
    //   "timeout"     timed out (the CLI's own, or timeout(1)'s exit 124 — 137 when it had
    //                 to KILL after TERM)
    //   "other"       anything else; `message` its first line
    // `message` is one sentence for a notification's body.
    function errorKind(exitCode, stderr) {
        const text = typeof stderr === "string" ? stderr.slice(0, 65536) : (stderr === null || stderr === undefined ? "" : String(stderr).slice(0, 65536));
        const code = typeof exitCode === "number" ? exitCode : Number(exitCode);
        if (code === 0)
            return { kind: "", message: "" };
        if (/^\s*Access denied:/m.test(text) || /\baccess denied\b/i.test(text))
            return { kind: "denied", message: "Tailscale refused: only an administrator or its operator may change it." };
        if (/Failed to connect to local Tailscale daemon/i.test(text) || /tailscaled\.sock[^\n]*(no such file|connection refused)/i.test(text)
                || /tailscaled[^\n]*not running/i.test(text) || /is Tailscale running\?/i.test(text))
            return { kind: "not-running", message: "The Tailscale service (tailscaled) is not running." };
        if (/changing settings via 'tailscale up' requires mentioning all/.test(text))
            return { kind: "revert", message: "Tailscale refused: 'tailscale up' would have reset other settings. Nothing was changed." };
        if (/^\s*Logged out\./m.test(text) || /\bNeedsLogin\b/.test(text) || /\bnot logged in\b/i.test(text) || /\byou are logged out\b/i.test(text))
            return { kind: "needs-login", message: "Tailscale is logged out: log in first." };
        if (code === 124 || code === 137 || /\btimed? ?out\b/i.test(text) || /context deadline exceeded/i.test(text))
            return { kind: "timeout", message: "Tailscale did not answer in time and was stopped: check its service and the network." };
        const firstLine = text.split("\n").map(line => line.trim()).find(line => line !== "") ?? "";
        return { kind: "other", message: firstLine !== "" ? firstLine.slice(0, 300) : ("Tailscale exited with status " + (isFinite(code) ? code : "?") + ".") };
    }

    // pkexec's own exit codes, as the provider contract (tailscale.md §3, "Cancelled is not
    // failed") and the shell (singletons/network/VpnLockdown.qml, Authentication.qml) read
    // them: 126 the prompt was dismissed or the password refused, 127 no authentication agent
    // answered. → { outcome, failure, message } — outcome "ok" | "dismissed" | "no-agent" |
    // "failed" (the program's own non-zero exit: read its stderr with errorKind).
    //   dismissed  failure false: show nothing, emit nothing, state back to "", busy cleared
    //   no-agent   failure true: failed(entryId, what, message) with the contract's sentence
    function pkexecOutcome(exitCode) {
        if (exitCode === 0)
            return { outcome: "ok", failure: false, message: "" };
        if (exitCode === 126)
            return { outcome: "dismissed", failure: false, message: "Not done: the password was not given." };
        if (exitCode === 127)
            return { outcome: "no-agent", failure: true, message: "No authentication agent answered." };
        return { outcome: "failed", failure: true, message: "" };
    }

    // A command stopped by its time limit (`seconds`, timeLimits) → one sentence for the
    // failure notification
    function timeoutMessage(name, seconds) {
        const value = _number(seconds, 0);
        const limit = value >= 120 ? Math.round(value / 60) + " minutes" : Math.round(value) + " s";
        if (name === "connect")
            return "Tailscale did not connect within " + limit + ". It keeps trying by itself; Disconnect stops it.";
        if (name === "login" || name === "addAccount")
            return "The login was not finished within " + limit + "; nothing was changed.";
        if (name === "status" || name === "prefs" || name === "exitNodeSuggest")
            return "Tailscale did not answer within " + limit + ".";
        return "Tailscale did not answer within " + limit + "; the change may not have been made.";
    }

    // A failure's text without addresses (a notification may show on a shared screen): IPv4
    // and IPv6 addresses (and prefixes) → "<address>"
    function withoutAddresses(text) {
        return String(text ?? "").slice(0, 2000).replace(/[0-9A-Fa-f:.]{3,}(?:\/\d{1,3})?/g, match => {
            const address = match.replace(/\/\d{1,3}$/, "").replace(/[.:]+$/, "");
            return _parseIpv4(address) !== null || (address.indexOf(":") >= 0 && _parseIpv6(address) !== null) ? "<address>" : match;
        });
    }

    // ---- Which programs run ----
    //
    // The live side finds tailscale, timeout, pkexec and curl once (by the tools seam, or on
    // PATH with `command -v`) and, for those found on PATH, `stat`s them: a program this
    // user could replace would be handed to pkexec — run as root. Its probe prints, per
    // program, tab-separated:
    //   tool  <name> <path, "" not found>
    //   real  <name> <readlink -f of it>
    //   stat  <name> <uid> <octal mode> <path>   for the found path's directory, the real
    //                                            file and the real file's directory
    // and `socket <path>` for the first LocalAPI socket (localApiSockets) that exists.
    readonly property var probedTools: ["tailscale", "timeout", "pkexec", "curl"]

    // One `stat` line's verdict: in the Nix store (read-only), or owned by root and writable
    // by nobody else (no group / other write bit)
    function _statTrusted(uid, mode, path) {
        if (typeof path === "string" && path.startsWith("/nix/store/") && !path.split("/").includes(".."))
            return true;
        const bits = /^[0-7]{1,5}$/.test(mode ?? "") ? parseInt(mode, 8) : -1;
        return uid === "0" && bits >= 0 && (bits & 0o022) === 0;
    }

    // probeText: the probe's output; checkTrust: judge each program (false: the seam's
    // programs, chosen by the owner, are taken as they are) → { tools: { <name>: { path,
    // trusted, reason } }, socket, untrusted: [names] }. curl is never judged (it runs as
    // this user only, never through pkexec).
    function toolsProbe(probeText, checkTrust) {
        const tools = {};
        for (const name of probedTools)
            tools[name] = { path: "", real: "", stats: [], trusted: false, reason: "" };
        let socket = "";
        const lines = typeof probeText === "string" ? probeText.slice(0, 65536).split("\n") : [];
        for (const line of lines.slice(0, 200)) {
            const parts = line.split("\t");
            if (parts[0] === "socket" && parts.length === 2 && localApiSockets.includes(parts[1]) && socket === "")
                socket = parts[1];
            if (!probedTools.includes(parts[1]))
                continue;
            const entry = tools[parts[1]];
            if (parts[0] === "tool" && parts.length === 3 && (parts[2] === "" || (_validPath(parts[2]) && !/\s/.test(parts[2]))))
                entry.path = parts[2];
            else if (parts[0] === "real" && parts.length === 3 && _validPath(parts[2]))
                entry.real = parts[2];
            else if (parts[0] === "stat" && parts.length === 5)
                entry.stats.push({ uid: parts[2], mode: parts[3], path: parts[4] });
        }
        const untrusted = [];
        for (const name of probedTools) {
            const entry = tools[name];
            if (entry.path === "")
                continue;
            if (checkTrust !== true || name === "curl") {
                entry.trusted = true;
            } else if (entry.real === "" || entry.stats.length < 3) {
                entry.reason = "The " + name + " found on PATH could not be checked: nothing is run";
            } else {
                const bad = entry.stats.find(stat => !_statTrusted(stat.uid, stat.mode, stat.path));
                entry.trusted = bad === undefined;
                if (bad)
                    entry.reason = "The " + name + " found on PATH is not trusted (this user could replace it: not root's, not in the Nix store): nothing is run";
            }
            if (!entry.trusted)
                untrusted.push(name);
        }
        const result = {};
        for (const name of probedTools)
            result[name] = { path: tools[name].path, trusted: tools[name].trusted, reason: tools[name].reason };
        return { tools: result, socket: socket, untrusted: untrusted };
    }

    // The plain form of a command with its time limit: timed(argv, timeoutPath, seconds) →
    // { ok, error, argv, limited }. argv[0] is the program's absolute path (tailscale's, or
    // systemctl's); timeoutPath coreutils' timeout — "" when it was not found: the argv as it
    // is, limited false (the live side's own watchdog then only stops waiting for it).
    //   [timeout, "-k", killAfter, seconds, program, args…]
    function timed(argv, timeoutPath, seconds) {
        if (!Array.isArray(argv) || argv.length === 0 || !argv.every(item => typeof item === "string") || !_validPath(argv[0]) || /\s/.test(argv[0]))
            return { ok: false, error: "not a command by absolute path", argv: [], limited: false };
        if (!_validSeconds(seconds))
            return { ok: false, error: "not a time limit", argv: [], limited: false };
        if (timeoutPath === "" || timeoutPath === null || timeoutPath === undefined)
            return { ok: true, error: "", argv: argv.slice(), limited: false };
        if (typeof timeoutPath !== "string" || !_validPath(timeoutPath) || /\s/.test(timeoutPath))
            return { ok: false, error: "the path to timeout is not absolute", argv: [], limited: false };
        return { ok: true, error: "", argv: [timeoutPath, "-k", String(timeLimits.killAfter), String(seconds)].concat(argv), limited: true };
    }

    function _validSeconds(seconds) {
        return typeof seconds === "number" && Number.isInteger(seconds) && seconds >= 1 && seconds <= 86400;
    }

    // ---- Commands ----

    // A strict Unix user name, as `--operator=` gets it: refused, never "cleaned" — a
    // cleaned name could be someone else's
    function validUserName(name) {
        return typeof name === "string" && /^[a-z_][a-z0-9_-]{0,31}$/.test(name);
    }

    // A host name for `set --hostname=` (hostnameProblem: one DNS label; "" = the system's own)
    function validHostname(name) {
        return hostnameProblem(name) === "";
    }

    // A peer named for ping, file cp, exit node: an IP address, or a DNS-like name. Never
    // starting with "-" (it would be read as a flag) — and no ":" in a name
    function validTarget(text) {
        if (typeof text !== "string" || text === "" || text.length > 253)
            return false;
        if (_parseIpv4(text) !== null || _parseIpv6(text) !== null)
            return true;
        return /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}))*\.?$/.test(text);
    }

    function _validPath(path) {
        return typeof path === "string" && path.startsWith("/") && path.length <= 4096 && !/[\u0000\n\r]/.test(path)
            && !path.split("/").includes("..");
    }

    function _flag(name, on) {
        return "--" + name + "=" + (on === true ? "true" : "false");
    }

    // timeLimit: the timeLimits key it runs under ("read" for what changes nothing, else
    // "change"; `up` and `login` their own)
    function _command(name, argv, changes, privileged, description, extra) {
        return Object.assign({ ok: true, error: "", name: name, argv: argv, changes: changes, privileged: privileged,
            description: description, writesAsRoot: false, longRunning: false, timeLimit: changes ? "change" : "read" }, extra ?? {});
    }

    function _refused(name, error) {
        return { ok: false, error: error, name: name, argv: [], changes: false, privileged: false, description: "", writesAsRoot: false, longRunning: false };
    }

    // The names commandFor knows
    readonly property var commandNames: ["connect", "disconnect", "login", "addAccount", "logout", "exitNode", "exitNodeNone",
        "exitNodeAuto", "allowLan", "acceptRoutes", "acceptDns", "shieldsUp", "hostname", "advertiseExitNode",
        "advertiseRoutes", "ssh", "webClient", "updateCheck", "operator", "switchAccount", "switchList", "removeAccount", "nickname", "derpMap",
        "ping", "netcheck", "fileCp", "fileGet", "fileTargets", "serveStatus", "serveReset", "serveAdd", "serveRemove",
        "funnelStatus", "funnelReset", "funnelAdd", "funnelRemove", "cert", "lockStatus", "status", "prefs",
        "exitNodeSuggest", "exitNodeList", "dnsStatus", "version", "watch", "startService"]

    // THE command builder: commandFor(name, args) → { ok, error, name, argv, changes,
    // privileged, description, writesAsRoot, longRunning }. `argv` is an array for Process
    // (never a shell line), starting with "tailscale" — privileged(argv, path) puts pkexec
    // and the absolute path in front. `changes`: it changes Tailscale's state. `privileged`:
    // it needs root or the operator (try it plainly; on errorKind "denied" retry through
    // pkexec — only for a user's click). `description`: for the polkit prompt's log and the
    // failure notification ("<description> failed"). `writesAsRoot`: through pkexec it would
    // leave files owned by root (file get, cert): offer "become operator" instead.
    // Never `tailscale up` with a flag: every setting goes through `tailscale set`.
    function commandFor(name, args) {
        const options = _isObject(args) ? args : {};
        const value = key => _get(options, key);
        const set = (flag, description) => _command(name, ["tailscale", "set", flag], true, true, description);
        switch (name) {
        case "connect":
            // Bare, always: never a flag on `up` (or `login`) — not even --timeout: a flag makes
            // `up` demand every non-default setting (the accidental-revert trap). Its time
            // limit is timeout(1)'s, around it
            return _command(name, ["tailscale", "up"], true, true, "Connecting Tailscale", { timeLimit: "up" });
        case "disconnect":
            return _command(name, ["tailscale", "down"], true, true, "Disconnecting Tailscale");
        case "login":
            return _command(name, ["tailscale", "login"], true, true, "Logging in to Tailscale", { longRunning: true, timeLimit: "login" });
        case "addAccount":
            // A bare `login` always moves the daemon to a new, empty profile first
            // (cli/login.go: SwitchToEmptyProfile) — the connection drops until the login is
            // done; another account there becomes a new profile, the same one is merged into
            // its old profile with login's default settings (ipnlocal/profiles.go)
            return _command(name, ["tailscale", "login"], true, true, "Adding a Tailscale account", { longRunning: true, timeLimit: "login" });
        case "logout":
            return _command(name, ["tailscale", "logout"], true, true, "Logging out of Tailscale");
        case "exitNode": {
            const target = value("node");
            if (target === "auto:any")
                return set("--exit-node=auto:any", "Choosing Tailscale's exit node automatically");
            if (!validTarget(target))
                return _refused(name, "not an exit node's address or name");
            // No address or name in the description: it ends up in notifications
            return set("--exit-node=" + target, "Changing Tailscale's exit node");
        }
        case "exitNodeAuto":
            return set("--exit-node=auto:any", "Choosing Tailscale's exit node automatically");
        case "exitNodeNone":
            return set("--exit-node=", "Using no Tailscale exit node");
        case "allowLan":
            return set(_flag("exit-node-allow-lan-access", value("on")), (value("on") === true ? "Allowing" : "Blocking") + " the local network beside the exit node");
        case "acceptRoutes":
            return set(_flag("accept-routes", value("on")), (value("on") === true ? "Accepting" : "Ignoring") + " routes from other Tailscale devices");
        case "acceptDns":
            return set(_flag("accept-dns", value("on")), (value("on") === true ? "Using" : "Ignoring") + " Tailscale's DNS settings");
        case "shieldsUp":
            return set(_flag("shields-up", value("on")), (value("on") === true ? "Blocking" : "Allowing") + " incoming Tailscale connections");
        case "ssh":
            return set(_flag("ssh", value("on")), (value("on") === true ? "Starting" : "Stopping") + " Tailscale's SSH server");
        case "webClient":
            return set(_flag("webclient", value("on")), (value("on") === true ? "Starting" : "Stopping") + " Tailscale's web interface");
        case "advertiseExitNode":
            return set(_flag("advertise-exit-node", value("on")), (value("on") === true ? "Offering" : "No longer offering") + " this computer as an exit node");
        case "updateCheck":
            return set(_flag("update-check", value("on")), (value("on") === true ? "Checking" : "Not checking") + " for Tailscale updates");
        case "hostname": {
            const hostname = value("name") ?? "";
            if (!validHostname(hostname))
                return _refused(name, hostnameProblem(hostname));
            return set("--hostname=" + hostname, hostname === "" ? "Using the system's host name for Tailscale" : "Naming this computer " + hostname + " in Tailscale");
        }
        case "advertiseRoutes": {
            const routes = value("routes");
            if (!Array.isArray(routes))
                return _refused(name, "routes must be a list");
            const checked = [];
            for (const route of routes.slice(0, 257)) {
                const cidr = parseCidr(route);
                if (!cidr)
                    return _refused(name, String(route).slice(0, 60) + " is not a network (address/prefix)");
                if (!cidr.canonical)
                    return _refused(name, String(route) + " has host bits set: " + cidr.network + " is meant");
                if (cidr.bits === 0)
                    return _refused(name, "the default route is not a subnet: offer an exit node instead");
                if (!checked.includes(cidr.network))
                    checked.push(cidr.network);
            }
            if (checked.length > 256)
                return _refused(name, "too many routes");
            return set("--advertise-routes=" + checked.join(","), checked.length > 0 ? "Offering routes " + checked.join(", ") + " to the tailnet" : "No longer offering routes to the tailnet");
        }
        case "nickname": {
            const nickname = value("name") ?? "";
            if (nicknameProblem(nickname) !== "")
                return _refused(name, nicknameProblem(nickname));
            // No nickname in the description: it ends up in notifications
            return set("--nickname=" + nickname, nickname === "" ? "Removing the account's nickname" : "Naming the Tailscale account");
        }
        case "operator": {
            const user = value("user");
            if (!validUserName(user))
                return _refused(name, "not a valid user name");
            return set("--operator=" + user, "Letting " + user + " change Tailscale without a password");
        }
        case "switchAccount": {
            const id = value("id");
            if (typeof id !== "string" || !accountIdPattern.test(id))
                return _refused(name, "not an account id");
            return _command(name, ["tailscale", "switch", id], true, true, "Switching Tailscale account");
        }
        case "switchList":
            // Reading, but denied to all but root and the operator (observed)
            return _command(name, ["tailscale", "switch", "--list", "--json"], false, true, "Listing Tailscale accounts");
        case "removeAccount": {
            const id = value("id");
            if (typeof id !== "string" || !accountIdPattern.test(id))
                return _refused(name, "not an account id");
            return _command(name, ["tailscale", "switch", "remove", id], true, true, "Removing a Tailscale account");
        }
        case "ping": {
            const target = value("target");
            // One ping within 3 s by default: the row says how it went (direct or relayed, the time)
            const count = value("count") ?? 1;
            if (!validTarget(target))
                return _refused(name, "not a device's address or name");
            if (typeof count !== "number" || !Number.isInteger(count) || count < 1 || count > 30)
                return _refused(name, "count must be 1–30");
            return _command(name, ["tailscale", "ping", "--c=" + count, "--timeout=3s", target], false, false, "Pinging a device");
        }
        case "netcheck":
            return _command(name, ["tailscale", "netcheck", "--format=json"], false, false, "Checking the network");
        case "fileCp": {
            const files = value("files");
            const target = value("target");
            if (!Array.isArray(files) || files.length === 0 || files.length > 100 || !files.every(file => _validPath(file)))
                return _refused(name, "files must be absolute paths");
            if (!validTarget(target) || target.includes(":"))
                return _refused(name, "not a device's name or IPv4 address");
            return _command(name, ["tailscale", "file", "cp"].concat(files, [target + ":"]), false, true, "Sending " + files.length + " file(s) to " + target, { longRunning: true });
        }
        case "fileTargets":
            return _command(name, ["tailscale", "file", "cp", "--targets"], false, false, "Listing devices that can receive files");
        case "fileGet": {
            const directory = value("directory");
            const conflict = value("conflict") ?? "rename";
            if (!_validPath(directory))
                return _refused(name, "the folder must be an absolute path");
            if (!["skip", "overwrite", "rename"].includes(conflict))
                return _refused(name, "conflict must be skip, overwrite or rename");
            return _command(name, ["tailscale", "file", "get", "--conflict=" + conflict, directory], true, true, "Receiving files into " + directory, { writesAsRoot: true });
        }
        case "serveStatus":
            return _command(name, ["tailscale", "serve", "status", "--json"], false, false, "Reading what this computer serves");
        case "funnelStatus":
            return _command(name, ["tailscale", "funnel", "status", "--json"], false, false, "Reading what this computer publishes");
        case "serveReset":
            return _command(name, ["tailscale", "serve", "reset"], true, true, "Stopping everything this computer serves");
        case "funnelReset":
            return _command(name, ["tailscale", "funnel", "reset"], true, true, "Stopping everything this computer publishes");
        case "serveAdd":
        case "funnelAdd":
        case "serveRemove":
        case "funnelRemove":
            return _serveCommand(name, options);
        case "cert": {
            const domain = value("domain");
            const certFile = value("certFile");
            const keyFile = value("keyFile");
            if (!validTarget(domain) || _parseIpv4(domain) !== null || _parseIpv6(domain) !== null)
                return _refused(name, "not this computer's DNS name");
            if (!_validPath(certFile) || !_validPath(keyFile))
                return _refused(name, "the certificate and key files must be absolute paths");
            return _command(name, ["tailscale", "cert", "--cert-file=" + certFile, "--key-file=" + keyFile, domain.replace(/\.$/, "")], true, true, "Getting a certificate for " + domain, { writesAsRoot: true });
        }
        case "lockStatus":
            return _command(name, ["tailscale", "lock", "status"], false, false, "Reading tailnet lock's state");
        case "status":
            return _command(name, ["tailscale", "status", "--json"], false, false, "Reading Tailscale's state");
        case "prefs":
            return _command(name, ["tailscale", "debug", "prefs"], false, false, "Reading Tailscale's settings");
        case "exitNodeSuggest":
            return _command(name, ["tailscale", "exit-node", "suggest"], false, false, "Asking for an exit node");
        case "exitNodeList":
            return _command(name, ["tailscale", "exit-node", "list"], false, false, "Listing exit nodes");
        case "dnsStatus":
            return _command(name, ["tailscale", "dns", "status", "--json"], false, false, "Reading Tailscale's DNS state");
        case "version":
            return _command(name, ["tailscale", "version", "--json"], false, false, "Reading Tailscale's version");
        case "derpMap":
            // The relay regions' names for netcheck's region ids (readable by any user)
            return _command(name, ["tailscale", "debug", "derp-map"], false, false, "Reading Tailscale's relay map");
        case "watch":
            // The bus through the CLI (pretty-printed objects: jsonFeed); --initial gives the
            // state and prefs first; peer changes off (status is re-read on any message)
            return _command(name, ["tailscale", "debug", "watch-ipn", "--initial", "--initial-health", "--initial-suggested-exit-node",
                "--initial-client-version", "--peer-changes=false", "--peer-patches=false"], false, false, "Watching Tailscale", { longRunning: true });
        case "startService":
            // Not tailscale: systemd asks polkit (the shell's agent) itself — no pkexec
            return _command(name, ["systemctl", "start", "tailscaled.service"], true, false, "Starting the Tailscale service");
        default:
            return _refused(String(name).slice(0, 40), "no such command");
        }
    }

    // serve / funnel, add and remove. The CLI (tailscale 1.104.4 `serve --help`): `serve
    // --bg --https=<port> <target>` adds in the background; the same with "off" in place of
    // the target removes (from the source and Tailscale's docs; NOT verified on this
    // machine). args { protocol: "https" | "http" | "tcp" (funnel: https or tcp), port,
    // target (add: a local port, or http(s)://localhost|127.0.0.1[:port][/path]) }.
    function _serveCommand(name, options) {
        const funnel = name.startsWith("funnel");
        const adding = name.endsWith("Add");
        const protocol = _get(options, "protocol") ?? "https";
        const port = _get(options, "port");
        const protocols = funnel ? ["https", "tcp"] : ["https", "http", "tcp"];
        if (!protocols.includes(protocol))
            return _refused(name, "protocol must be " + protocols.join(" or "));
        if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535)
            return _refused(name, "port must be 1–65535");
        if (funnel && protocol === "https" && ![443, 8443, 10000].includes(port))
            return _refused(name, "funnel serves HTTPS only on 443, 8443 or 10000");
        const program = funnel ? "funnel" : "serve";
        let target = "off";
        if (adding) {
            const raw = _get(options, "target");
            const local = typeof raw === "number" ? String(raw) : (typeof raw === "string" ? raw : "");
            const isPort = /^\d{1,5}$/.test(local) && Number(local) >= 1 && Number(local) <= 65535;
            const isUrl = /^(https?|https\+insecure|tcp):\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d{1,5})?(\/[A-Za-z0-9._~\/-]*)?$/.test(local);
            if (!isPort && !isUrl)
                return _refused(name, "the target must be a local port or a localhost URL");
            target = local;
        }
        const what = (funnel ? "Publishing on the internet " : "Serving on the tailnet ") + protocol + " port " + port;
        return _command(name, ["tailscale", program, "--bg", "--" + protocol + "=" + port, target], true, true,
            adding ? what : "Stopping " + what.charAt(0).toLowerCase() + what.slice(1));
    }

    // The pkexec form of a command: privileged(argv, tailscalePath, { timeout, seconds,
    // description }) → { ok, error, argv, prompt }:
    //   ["pkexec", <timeout>, "-k", killAfter, <seconds>, <tailscale>, args…]
    // A process run as root cannot be signalled by the shell — cancelling only stops waiting
    // for it — so it must END BY ITSELF: coreutils' timeout around it, under pkexec. Without a
    // timeout (not found) nothing is run as root: { ok: false } with the reason, for the page.
    // pkexec does not search the user's PATH, so both go by absolute path — the live side
    // resolves them once (kept as found: on NixOS /run/current-system/sw/bin/…, links that
    // survive updates, unlike the store paths they point to). `prompt`: what runs, in words,
    // the label of the authentication.
    function privileged(argv, tailscalePath, options) {
        if (!Array.isArray(argv) || argv.length === 0 || argv[0] !== "tailscale" || !argv.every(item => typeof item === "string"))
            return { ok: false, error: "not a tailscale command", argv: [], prompt: "" };
        if (typeof tailscalePath !== "string" || !_validPath(tailscalePath) || /\s/.test(tailscalePath) || tailscalePath.endsWith("/"))
            return { ok: false, error: "the path to tailscale is not absolute", argv: [], prompt: "" };
        const timeoutPath = _get(options, "timeout");
        if (typeof timeoutPath !== "string" || timeoutPath === "")
            return { ok: false, error: "coreutils' timeout was not found: nothing is run as administrator without a time limit", argv: [], prompt: "" };
        const seconds = _get(options, "seconds") ?? timeLimits.change;
        const limited = timed([tailscalePath].concat(argv.slice(1)), timeoutPath, seconds);
        if (!limited.ok)
            return { ok: false, error: limited.error, argv: [], prompt: "" };
        const limit = seconds >= 120 ? Math.round(seconds / 60) + " minutes" : seconds + " s";
        const description = _string(_get(options, "description"), 120);
        return {
            ok: true, error: "", argv: ["pkexec"].concat(limited.argv),
            prompt: (description !== "" ? description + ": " : "") + "runs `tailscale " + argv.slice(1).join(" ") + "` as administrator, stopped after " + limit
        };
    }

    // ---- Warnings ----

    // The key of this computer: → null (no expiry: disabled, unknown) | { kind
    // "key-expiring" (within keyExpiryWarningDays; not attention) | "key-expired", days,
    // text }
    function keyExpiryWarning(self, now) {
        const expiry = _number(self?.keyExpiry, 0);
        const moment = _number(now, 0);
        if (expiry <= 0 || moment <= 0)
            return null;
        const remaining = expiry - moment;
        if (remaining <= 0 || self?.expired === true)
            return { kind: "key-expired", days: 0, text: "This computer's Tailscale key has expired: log in again" };
        const days = Math.ceil(remaining / 86400000);
        if (days > keyExpiryWarningDays)
            return null;
        const when = remaining < 86400000 ? "within a day" : (days === 1 ? "in 1 day" : "in " + days + " days");
        return { kind: "key-expiring", days: days, text: "This computer's Tailscale key expires " + when + ": renew it, or turn expiry off, in the admin console" };
    }

    // Accepted subnet routes that cover the local network — a known trap: traffic for the
    // LAN goes into the tailnet. routeShadowsLan(status, lanSubnets, prefs) → [{ route,
    // lan, device, text }]; none while prefs say routes are not accepted. lanSubnets: the
    // local networks as "address/prefix" (an address with host bits is fine here).
    function routeShadowsLan(status, lanSubnets, prefs) {
        if (prefs && _get(prefs, "acceptRoutes") === false)
            return [];
        const lans = (Array.isArray(lanSubnets) ? lanSubnets : []).slice(0, 64).map(parseCidr).filter(cidr => cidr !== null && cidr.bits > 0);
        const found = [];
        for (const node of _peersOf(status)) {
            for (const route of node.primaryRoutes) {
                const cidr = parseCidr(route);
                if (!cidr || cidr.bits === 0)
                    continue;
                for (const lan of lans) {
                    if (!cidrOverlap(cidr, lan))
                        continue;
                    found.push({
                        route: cidr.network, lan: lan.network, device: _shortName(node),
                        text: "The route " + cidr.network + " from " + _shortName(node) + " covers the local network " + lan.network
                            + ": local traffic may go into the tailnet"
                    });
                    if (found.length >= 64)
                        return found;
                }
            }
        }
        return found;
    }

    // Tailscale beside another VPN: twoVpnsNote({ tailscaleUp, exitNode (name or ""),
    // acceptDns, otherVpns [names] }) → a sentence, or "" when there is nothing to say
    function twoVpnsNote(input) {
        const others = _strings(_get(input, "otherVpns"), 8);
        if (_get(input, "tailscaleUp") !== true || others.length === 0)
            return "";
        const names = others.join(", ");
        const exitNode = _string(_get(input, "exitNode"), 200);
        const parts = [];
        if (exitNode !== "")
            parts.push(names + " and Tailscale's exit node " + exitNode + " compete for internet traffic");
        if (_get(input, "acceptDns") !== false)
            parts.push("Tailscale's DNS (" + quadHundred + ") and " + names + "'s compete: some names may not resolve");
        return parts.length > 0 ? parts.join(". ") + "." : "";
    }

    // ---- Formatting (the shell's Format is a core singleton modules may not import) ----

    // A size in binary units, as the shell's Format.bytes: "742 MB", "15.6 GB"
    function bytes(value) {
        const number = _number(value, 0);
        const units = ["B", "KB", "MB", "GB", "TB"];
        const decimals = [0, 0, 0, 1, 1];
        let unit = 0;
        while (unit < units.length - 1 && Math.abs(number) >= Math.pow(1024, unit + 1))
            unit++;
        return (number / Math.pow(1024, unit)).toFixed(decimals[unit]) + " " + units[unit];
    }

    // How long ago, as the shell's Format.ago but in milliseconds: "just now", "5 min ago",
    // "3 h ago", "yesterday", "4 days ago", "2 months ago"; "never" for 0
    function ago(moment, now) {
        const at = _number(moment, 0);
        if (!(at > 0))
            return "never";
        const elapsed = Math.max(0, _number(now, at) - at) / 1000;
        if (elapsed < 60)
            return "just now";
        if (elapsed < 3600)
            return Math.floor(elapsed / 60) + " min ago";
        if (elapsed < 86400)
            return Math.floor(elapsed / 3600) + " h ago";
        const days = Math.floor(elapsed / 86400);
        if (days === 1)
            return "yesterday";
        if (days < 60)
            return days + " days ago";
        return Math.floor(days / 30) + " months ago";
    }

    // ---- Addresses ----

    function _parseIpv4(text) {
        if (typeof text !== "string")
            return null;
        const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(text);
        if (!match)
            return null;
        const bytes = match.slice(1, 5).map(Number);
        if (bytes.some(byte => byte > 255) || match.slice(1, 5).some(part => part.length > 1 && part[0] === "0"))
            return null;
        return bytes;
    }

    // IPv6 → 16 bytes, or null (zones refused)
    function _parseIpv6(text) {
        if (typeof text !== "string" || text.length > 45 || !/^[0-9A-Fa-f:.]+$/.test(text) || !text.includes(":"))
            return null;
        const halves = text.split("::");
        if (halves.length > 2)
            return null;
        const groupsOf = part => part === "" ? [] : part.split(":");
        const head = groupsOf(halves[0]);
        const tail = halves.length === 2 ? groupsOf(halves[1]) : [];
        const words = [];
        const toWords = groups => {
            const result = [];
            for (let i = 0; i < groups.length; i++) {
                const group = groups[i];
                if (i === groups.length - 1 && group.includes(".")) {
                    const ipv4 = _parseIpv4(group);
                    if (!ipv4)
                        return null;
                    result.push(ipv4[0] * 256 + ipv4[1], ipv4[2] * 256 + ipv4[3]);
                } else if (/^[0-9A-Fa-f]{1,4}$/.test(group)) {
                    result.push(parseInt(group, 16));
                } else {
                    return null;
                }
            }
            return result;
        };
        const headWords = toWords(head);
        const tailWords = toWords(tail);
        if (!headWords || !tailWords)
            return null;
        // An embedded IPv4 is allowed only in the last group of the whole address
        if (halves.length === 2 && head.length > 0 && head[head.length - 1].includes("."))
            return null;
        const missing = 8 - headWords.length - tailWords.length;
        if (halves.length === 1 ? missing !== 0 : missing < 1)
            return null;
        words.push(...headWords);
        for (let i = 0; i < (halves.length === 2 ? missing : 0); i++)
            words.push(0);
        words.push(...tailWords);
        const bytes = [];
        for (const word of words)
            bytes.push(word >> 8, word & 255);
        return bytes;
    }

    function _formatIpv6(bytes) {
        const words = [];
        for (let i = 0; i < 16; i += 2)
            words.push((bytes[i] << 8) | bytes[i + 1]);
        // The longest run of zero words (two or more) becomes "::" (RFC 5952)
        let bestStart = -1;
        let bestLength = 0;
        for (let i = 0; i < 8;) {
            if (words[i] !== 0) {
                i++;
                continue;
            }
            let j = i;
            while (j < 8 && words[j] === 0)
                j++;
            if (j - i > bestLength && j - i >= 2) {
                bestStart = i;
                bestLength = j - i;
            }
            i = j;
        }
        const hex = words.map(word => word.toString(16));
        if (bestStart < 0)
            return hex.join(":");
        return hex.slice(0, bestStart).join(":") + "::" + hex.slice(bestStart + bestLength).join(":");
    }

    // "address/prefix" → { family 4 | 6, bytes, bits, network (canonical text), canonical
    // (no host bits set) } or null. A bare address is a /32 or /128.
    function parseCidr(text) {
        if (typeof text !== "string" || text.length > 64)
            return null;
        const parts = text.split("/");
        if (parts.length > 2)
            return null;
        const ipv4 = _parseIpv4(parts[0]);
        const ipv6 = ipv4 ? null : _parseIpv6(parts[0]);
        const bytes = ipv4 ?? ipv6;
        if (!bytes)
            return null;
        const maxBits = ipv4 ? 32 : 128;
        if (parts.length === 2 && !/^\d{1,3}$/.test(parts[1]))
            return null;
        const bits = parts.length === 2 ? Number(parts[1]) : maxBits;
        if (bits > maxBits)
            return null;
        const masked = bytes.map((byte, index) => {
            const keep = Math.max(0, Math.min(8, bits - index * 8));
            return byte & (keep === 0 ? 0 : (0xff << (8 - keep)) & 0xff);
        });
        const canonical = masked.every((byte, index) => byte === bytes[index]);
        const address = ipv4 ? masked.join(".") : _formatIpv6(masked);
        return { family: ipv4 ? 4 : 6, bytes: masked, bits: bits, network: address + "/" + bits, canonical: canonical };
    }

    // Two networks share addresses (one contains the other)
    function cidrOverlap(a, b) {
        if (!a || !b || a.family !== b.family)
            return false;
        const bits = Math.min(a.bits, b.bits);
        for (let i = 0; i < a.bytes.length; i++) {
            const keep = Math.max(0, Math.min(8, bits - i * 8));
            if (keep === 0)
                break;
            const mask = (0xff << (8 - keep)) & 0xff;
            if ((a.bytes[i] & mask) !== (b.bytes[i] & mask))
                return false;
        }
        return true;
    }
}
