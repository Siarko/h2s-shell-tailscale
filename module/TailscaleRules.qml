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
    //   cli          "present" | "missing" (the tailscale program is not on PATH)
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
    // `phase`: "unknown" | "missing" | "not-running" | "denied" | "other-user" |
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
                view.attention = _attention("key-expired", "Tailscale's key for this computer has expired: log in again to reconnect", "Log in");
                view.status = "Key expired";
            } else {
                view.attention = _attention("login", "Log in to Tailscale to connect", "Log in");
                view.status = "Logged out";
            }
        } else if (backend === "NeedsMachineAuth") {
            view.phase = "needs-approval";
            view.attention = _attention("approval", "Waiting for an administrator of the tailnet to approve this computer", "Approve…");
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
                const sentence = "The exit node " + view.exitNode.name + " is offline: internet traffic is blocked until it returns or another is chosen";
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

        const expiry = keyExpiryWarning(self, now);
        if (expiry && expiry.kind === "key-expiring" && view.phase !== "logged-out")
            warnings.push(expiry);
        for (const text of _strings(status.health, 64))
            warnings.push({ kind: "health", text: text });
        if (_isObject(status.clientVersion) && status.clientVersion.runningLatest === false && _string(status.clientVersion.latestVersion, 64) !== "") {
            const managed = _get(facts, "updateManagedBySystem") === true;
            warnings.push({
                kind: "update",
                text: "Tailscale " + status.clientVersion.latestVersion + " is available"
                    + (managed ? " — it is updated with the system, not here" : "")
            });
        }
        return finish();
    }

    // ---- The provider entry ----

    // The tailnet's name for the entry: CurrentTailnet.Name (for a personal tailnet that is
    // the account's e-mail address), else the MagicDNS suffix, else facts.lastTailnet (what
    // the live side remembers, so a logged-out or stopped entry keeps its name), else "".
    function tailnetName(status, facts) {
        const tailnet = _isObject(status) && _isObject(status.tailnet) ? status.tailnet : {};
        return _string(tailnet.name, 200) || _string(tailnet.magicDnsSuffix, 200) || _string(_isObject(status) ? status.magicDnsSuffix : "", 200)
            || _string(_get(facts, "lastTailnet"), 200);
    }

    // The ONE provider entry, in every state (logged out, daemon down, CLI missing, status
    // unreadable): a provider that reports no entry lets the shell delete the user's "VPN
    // with a network" setting. → { id, name, state, attention { reason, action } | null,
    // detail, active, status, busy }
    //   name     "Tailscale · <tailnet>", or "Tailscale" while no tailnet is known
    //   detail   while up: { server (the exit node, else the control server's host), iface
    //            (tailscale0 unless userspace networking; facts.interfaceName overrides),
    //            interfaceName, addresses (this computer's Tailscale IPs), dns
    //            ([100.100.100.100] while accept-DNS is on) }; else {}
    //   busy     facts.operation is not ""
    function entry(status, prefs, facts) {
        const view = stateOf(status, prefs, facts);
        const tailnet = tailnetName(status, facts);
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
        if (phase === "stopped" || phase === "unknown")
            return _privilegedRun("connect", changeAllowed, origin, {},
                _attention("needs-privilege", "Bringing Tailscale up with this network needs an administrator's password — or make this user Tailscale's operator", "Connect"));
        // missing, not running, denied, other user, needs approval: the attention says it
        return origin === "network" && view?.attention ? _plan("needs-user", { attention: view.attention }) : _plan("nothing", { attention: view?.attention ?? null });
    }

    function planDisconnect(view, changeAllowed, origin) {
        const phase = view?.phase ?? "unknown";
        if (phase !== "running" && phase !== "starting")
            return _plan("nothing");
        return _privilegedRun("disconnect", changeAllowed, origin, {},
            _attention("needs-privilege", "Taking Tailscale down with this network needs an administrator's password — or make this user Tailscale's operator", "Disconnect"));
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

    // `tailscale netcheck --format=json` (netcheck.Report) → { ok, udp, ipv4, ipv6,
    // mappingVariesByDestIp (null unknown), preferredDerp, globalV4, regions [{ id, ms }]
    // fastest first }. Field names from the source (net/netcheck); synthetic fixture.
    function parseNetcheck(input) {
        const result = { ok: false, udp: false, ipv4: false, ipv6: false, mappingVariesByDestIp: null, preferredDerp: 0, globalV4: "", regions: [] };
        const parsed = _parseJson(input);
        if (!_isObject(parsed.value))
            return result;
        const raw = parsed.value;
        result.ok = true;
        result.udp = _bool(_get(raw, "UDP"));
        result.ipv4 = _bool(_get(raw, "IPv4"));
        result.ipv6 = _bool(_get(raw, "IPv6"));
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
    //   "timeout"     timed out (the CLI's own, or timeout(1)'s exit 124)
    //   "other"       anything else; `message` its first line
    // `message` is one sentence for a notification's body.
    function errorKind(exitCode, stderr) {
        const text = typeof stderr === "string" ? stderr.slice(0, 65536) : (stderr === null || stderr === undefined ? "" : String(stderr).slice(0, 65536));
        const code = typeof exitCode === "number" ? exitCode : Number(exitCode);
        if (code === 0)
            return { kind: "", message: "" };
        if (/^\s*Access denied:/m.test(text) || /\baccess denied\b/i.test(text))
            return { kind: "denied", message: "Tailscale refused: this user may not change it (an administrator, or Tailscale's operator, may)." };
        if (/Failed to connect to local Tailscale daemon/i.test(text) || /tailscaled\.sock[^\n]*(no such file|connection refused)/i.test(text)
                || /tailscaled[^\n]*not running/i.test(text) || /is Tailscale running\?/i.test(text))
            return { kind: "not-running", message: "The Tailscale service (tailscaled) is not running." };
        if (/changing settings via 'tailscale up' requires mentioning all/.test(text))
            return { kind: "revert", message: "Tailscale refused to change settings through 'tailscale up' (it would have reset others); nothing was changed." };
        if (/^\s*Logged out\./m.test(text) || /\bNeedsLogin\b/.test(text) || /\bnot logged in\b/i.test(text) || /\byou are logged out\b/i.test(text))
            return { kind: "needs-login", message: "Tailscale is logged out: log in first." };
        if (code === 124 || /\btimed? ?out\b/i.test(text) || /context deadline exceeded/i.test(text))
            return { kind: "timeout", message: "Tailscale did not answer in time." };
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

    // ---- Commands ----

    // A strict Unix user name, as `--operator=` gets it: refused, never "cleaned" — a
    // cleaned name could be someone else's
    function validUserName(name) {
        return typeof name === "string" && /^[a-z_][a-z0-9_-]{0,31}$/.test(name);
    }

    // A host name for `set --hostname=` (one DNS label; "" = the system's own)
    function validHostname(name) {
        return typeof name === "string" && (name === "" || /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(name));
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

    function _command(name, argv, changes, privileged, description, extra) {
        return Object.assign({ ok: true, error: "", name: name, argv: argv, changes: changes, privileged: privileged,
            description: description, writesAsRoot: false, longRunning: false }, extra ?? {});
    }

    function _refused(name, error) {
        return { ok: false, error: error, name: name, argv: [], changes: false, privileged: false, description: "", writesAsRoot: false, longRunning: false };
    }

    // The names commandFor knows
    readonly property var commandNames: ["connect", "disconnect", "login", "addAccount", "logout", "exitNode", "exitNodeNone",
        "exitNodeAuto", "allowLan", "acceptRoutes", "acceptDns", "shieldsUp", "hostname", "advertiseExitNode",
        "advertiseRoutes", "ssh", "webClient", "updateCheck", "operator", "switchAccount", "switchList", "removeAccount",
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
            return _command(name, ["tailscale", "up"], true, true, "Connecting Tailscale");
        case "disconnect":
            return _command(name, ["tailscale", "down"], true, true, "Disconnecting Tailscale");
        case "login":
            return _command(name, ["tailscale", "login"], true, true, "Logging in to Tailscale", { longRunning: true });
        case "addAccount":
            // `login` while logged in adds an account (a new profile) — up.go keeps the
            // profile name only for `up`
            return _command(name, ["tailscale", "login"], true, true, "Adding a Tailscale account", { longRunning: true });
        case "logout":
            return _command(name, ["tailscale", "logout"], true, true, "Logging out of Tailscale");
        case "exitNode": {
            const target = value("node");
            if (target === "auto:any")
                return set("--exit-node=auto:any", "Choosing Tailscale's exit node automatically");
            if (!validTarget(target))
                return _refused(name, "not an exit node's address or name");
            return set("--exit-node=" + target, "Using " + target + " as Tailscale's exit node");
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
                return _refused(name, "a host name is letters, digits and inner dashes, up to 63");
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
            const count = value("count") ?? 5;
            if (!validTarget(target))
                return _refused(name, "not a device's address or name");
            if (typeof count !== "number" || !Number.isInteger(count) || count < 1 || count > 30)
                return _refused(name, "count must be 1–30");
            return _command(name, ["tailscale", "ping", "--c=" + count, "--timeout=5s", target], false, false, "Pinging " + target);
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
            return _command(name, ["tailscale", "dns", "status"], false, false, "Reading Tailscale's DNS state");
        case "version":
            return _command(name, ["tailscale", "version"], false, false, "Reading Tailscale's version");
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

    // The pkexec form of a command: privileged(argv, tailscalePath) → { ok, error, argv }.
    // pkexec does not search the user's PATH, so the program goes by its absolute path —
    // the live side resolves it once (`command -v tailscale` through a Process, kept as
    // found: on NixOS /run/current-system/sw/bin/tailscale, a link that survives updates,
    // unlike the store path it points to).
    function privileged(argv, tailscalePath) {
        if (!Array.isArray(argv) || argv.length === 0 || argv[0] !== "tailscale" || !argv.every(item => typeof item === "string"))
            return { ok: false, error: "not a tailscale command", argv: [] };
        if (typeof tailscalePath !== "string" || !_validPath(tailscalePath) || /\s/.test(tailscalePath) || tailscalePath.endsWith("/"))
            return { ok: false, error: "the path to tailscale is not absolute", argv: [] };
        return { ok: true, error: "", argv: ["pkexec", tailscalePath].concat(argv.slice(1)) };
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
            return { kind: "key-expired", days: 0, text: "Tailscale's key for this computer has expired: log in again" };
        const days = Math.ceil(remaining / 86400000);
        if (days > keyExpiryWarningDays)
            return null;
        const when = remaining < 86400000 ? "within a day" : (days === 1 ? "in 1 day" : "in " + days + " days");
        return { kind: "key-expiring", days: days, text: "Tailscale's key for this computer expires " + when + ": log in again before then to stay connected" };
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
                            + ": local devices may be reached through the tailnet instead"
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
            parts.push("Both " + names + " and Tailscale's exit node " + exitNode + " want to carry internet traffic: which one does depends on their routes");
        if (_get(input, "acceptDns") !== false)
            parts.push("Tailscale's DNS (" + quadHundred + ") and " + names + "'s compete: names of one may not resolve while the other answers");
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
