pragma Singleton

import Quickshell
import QtQuick
import qs.api

// The Tailscale module's decisions — pure, so module/tests/ check them on fixtures without a
// daemon: what `tailscale status --json`, `tailscale debug prefs` and the IPN bus say,
// mapped onto the shell's VPN provider contract (components/VpnProvider.qml in the shell;
// docs/plans/tailscale.md §3), the devices and exit nodes for the views, the accounts, what
// an error or a run as administrator's result means, and the argv of every command the module
// runs.
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
//     AltSharerUserID, AllowedIPs (own addresses + approved routes), sshHostKeys (a count:
//     it runs Tailscale SSH), CapMap (its keys only) — each missing: "", 0, false, [] or null.
//   debug prefs (ipn.Prefs; its keys are zeroed for a non-root reader): ControlURL,
//     RouteAll (accept routes, default false), ExitNodeID, ExitNodeIP,
//     ExitNodeAllowLANAccess, CorpDNS (accept DNS, default true), RunSSH, RunWebClient,
//     WantRunning, LoggedOut, ShieldsUp, AdvertiseTags, Hostname, AdvertiseRoutes,
//     OperatorUser, ProfileName, AutoUpdate { Check, Apply }, Config.UserProfile.LoginName;
//     since step 3 NoSNAT, NoStatefulFiltering (opt.Bool), NetfilterMode (0/1/2),
//     AppConnector { Advertise }, PostureChecking, RelayServerPort (omitted while off).
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
    // Time limits, in seconds: every command runs with one, kept by the shell's command runner
    // (runLimits(); a run as administrator by the shell's own timeout inside pkexec,
    // privilegedRun()'s timeoutMs), so nothing it runs can wait for ever — not a `status --json`
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
    //   send      `file cp`, as the user: 6 hours — about 10 GB at 0.5 MB/s over a relay. A stalled
    //             send is stopped long before by TaildropClient (no bus progress for 2 minutes)
    //   save      each LocalAPI request of the save script (one received file each)
    //   killAfter KILL this long after TERM, for a program that ignores TERM (the runner's killAfterMs)
    readonly property var timeLimits: ({ read: 15, change: 60, up: 60, login: 600, diagnose: 30, ping: 10, send: 21600, save: 600, cert: 180, killAfter: 5 })
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
            // The prefixes this node may route: its own addresses plus the routes an admin
            // approved (tailcfg.Node.AllowedIPs; ipnlocal peerStatusFromNode copies it)
            allowedIps: _strings(_get(raw, "AllowedIPs"), 512),
            // ipnstate.PeerStatus.SSH_HostKeys (JSON "sshHostKeys"): the node runs Tailscale SSH
            sshHostKeys: _strings(_get(raw, "sshHostKeys"), 16).length,
            // The capability names (CapMap's keys; null: no CapMap sent)
            caps: _isObject(_get(raw, "CapMap")) ? _keys(_get(raw, "CapMap")).slice(0, 128).map(key => String(key).slice(0, 200)) : null,
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
    // version, peersCut, peersRead }. ok false (and everything empty) when it is not a JSON object.
    function parseStatus(input) {
        const result = {
            ok: false, error: "", backendState: "", haveNodeKey: false, authUrl: "", addresses: [], self: null,
            health: [], tailnet: null, magicDnsSuffix: "", peers: [], users: _dict(), clientVersion: null,
            exitNodeStatus: null, tun: true, version: "", peersCut: false, peersRead: false, certDomains: []
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
        // The names this computer may get a TLS certificate for (step 5: certificates, HTTPS)
        result.certDomains = _strings(_get(raw, "CertDomains"), 8).map(name => _dnsName(name));
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
        // A peer list arrived (a map, even an empty one): before the first network map the daemon
        // has none (null), and "no exit node" then means "not known yet" (NetworkExitRules)
        result.peersRead = _isObject(peerMap) || Array.isArray(peerMap);
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
            autoUpdate: null, advertiseRoutesAll: [], snat: true, statefulFiltering: null, netfilterMode: "",
            advertiseConnector: false, postureChecking: false, relayServerPort: null, advertiseRoutesCut: false, nodeId: ""
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
        // More than the 256 read: an edit built from this list would drop the rest
        result.advertiseRoutesCut = Array.isArray(_get(raw, "AdvertiseRoutes")) && _get(raw, "AdvertiseRoutes").length > 256;
        // The exit node is advertised as the two default routes (ipn/prefs.go)
        result.advertiseExitNode = routes.includes("0.0.0.0/0") && routes.includes("::/0");
        result.advertiseRoutes = routes.filter(route => route !== "0.0.0.0/0" && route !== "::/0");
        result.operatorUser = _string(_get(raw, "OperatorUser"), 64);
        result.profileName = _string(_get(raw, "ProfileName"), 200);
        const config = _get(raw, "Config");
        result.loginName = _string(_get(_get(config, "UserProfile"), "LoginName"), 200);
        // The node of this profile (Config.NodeID, readable without root): with the login it
        // tells whether the profile changed between two reads (prefsIdentity)
        result.nodeId = _string(_get(config, "NodeID"), 128);
        const update = _get(raw, "AutoUpdate");
        result.updateCheck = _bool(_get(update, "Check"), true);
        const apply = _get(update, "Apply");
        result.autoUpdate = typeof apply === "boolean" ? apply : null;
        // Step 3 (ipn/prefs.go): the whole AdvertiseRoutes list as the daemon has it
        result.advertiseRoutesAll = routes;
        // NoSNAT false (the default) = source NAT on
        result.snat = !_bool(_get(raw, "NoSNAT"));
        // NoStatefulFiltering is an opt.Bool: true → off, false → on, missing → unknown (null)
        const noStateful = _get(raw, "NoStatefulFiltering");
        result.statefulFiltering = noStateful === false || noStateful === "false" ? true
            : (noStateful === true || noStateful === "true" ? false : null);
        // preftype.NetfilterMode: 0 off, 1 nodivert, 2 on
        const netfilter = _get(raw, "NetfilterMode");
        result.netfilterMode = netfilter === 0 ? "off" : netfilter === 1 ? "nodivert" : netfilter === 2 ? "on" : "";
        result.advertiseConnector = _bool(_get(_get(raw, "AppConnector"), "Advertise"));
        result.postureChecking = _bool(_get(raw, "PostureChecking"));
        // *uint16, omitted while off
        const relayPort = _get(raw, "RelayServerPort");
        result.relayServerPort = typeof relayPort === "number" && Number.isInteger(relayPort) && relayPort >= 0 && relayPort <= 65535 ? relayPort : null;
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
        // Both may change without the shell knowing (installed, replaced): the action looks again
        if (_get(facts, "cli") === "missing") {
            view.phase = "missing";
            view.attention = _attention("not-installed", "Tailscale isn't installed", "Check again");
            view.status = "Not installed";
            return finish();
        }
        if (_get(facts, "cli") === "untrusted") {
            view.phase = "untrusted";
            view.attention = _attention("untrusted", _string(_get(facts, "untrustedReason"), 300)
                || "Tailscale isn't trusted: this user could change it.", "Check again");
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
        const wantRunning = _get(prefs, "wantRunning") === true;
        // A daemon with no node key that is not trying to run (a fresh install often stays in
        // NoState until someone logs in) needs a login like NeedsLogin — Connect there must log
        // in, not wait for a start that never comes
        const freshNoState = backend === "NoState" && !status.haveNodeKey && (!wantRunning || loggingIn);

        if (backend === "NeedsLogin" || freshNoState || (loggedOut && (backend === "Stopped" || backend === "NoState"))) {
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
        } else if (backend === "NoState" && !wantRunning && !loggingIn) {
            // Logged in but idle (WantRunning off): off, as Stopped — Connect runs `up`
            view.phase = "stopped";
            view.status = "Off";
        } else if (backend === "Starting" || backend === "NoState") {
            view.phase = "starting";
            const stopping = operation === "disconnect" || operation === "logout";
            view.state = stopping ? "deactivating" : "activating";
            view.status = stopping ? "Disconnecting…" : "Starting…";
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
            warnings.push({ kind: "unknown-state", text: "Tailscale reports a state this module does not know: " + (plainText(backend, 32) || "none") });
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
            warnings.push({ kind: "health", text: plainText(text, 500) });
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
        const carried = traffic(status, prefs, view);
        return {
            id: entryId,
            name: tailnet !== "" ? typeName + " · " + tailnet : typeName,
            state: view.state,
            attention: view.attention ? { reason: view.attention.reason, action: view.attention.action } : null,
            detail: detail,
            active: view.state !== "",
            status: view.status,
            busy: _string(_get(facts, "operation"), 32) !== "",
            fullTunnel: carried.fullTunnel,
            setsDns: carried.setsDns,
            routes: carried.routes
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
    //   kind "run"         run `command` (commandFor's); `privileged`: may be run again as
    //                      administrator when denied (privilegedRun, the shell's
    //                      module.privileged) — only ever with origin "user"
    //        "needs-user"  do nothing; set `attention` (lasting until the user acts)
    //        "open-url"    open `url` in the browser (origin "user" only)
    //        "read"        the state is not known (not read yet, or the last read timed
    //                      out): re-read, and do nothing until it is — never a blind `up`
    //        "recheck"     look for the programs (or the service) again: Tailscale was not
    //                      found or not trusted, and may have been installed or fixed since
    //                      (origin "user" only)
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
        if ((phase === "missing" || phase === "untrusted") && origin !== "network")
            return _plan("recheck");
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
        // The action its button says, whatever the phase reads now (label and effect are one)
        if (kind === "needs-privilege")
            return view.attention.action === "Disconnect" ? planDisconnect(view, changeAllowed, origin, { connecting: true })
                : planConnect(view, changeAllowed, origin);
        if (kind === "not-installed" || kind === "untrusted")
            return _plan("recheck");
        return _plan("nothing");
    }

    // ---- A failed click: its reason on the entry's status line ----
    //
    // A connect, disconnect, login or start the user asked for that failed leaves its reason
    // as the entry's status text — never as attention: the remedy is the same button again (or
    // the attention the STATE has: Log in, Start), and attention would stop the shell's "VPN
    // with a network" from connecting. Its life (failureAfter), `failure` null or
    // { text, phase, settling }:
    //   "failed"     a new one: { text, phase (the view's now), settling true }
    //   "read"       a read answered: settling → up after all (running): gone; else it keeps
    //                the phase it left Tailscale in; settled → gone when the phase changed
    //   "view"       the view changed: gone when settled and the phase changed
    //   "acted"      the user acted again, "succeeded" a change went through, "connecting"
    //                a connect started (any origin), "stopped" the client stopped: gone
    function failureAfter(failure, event, phase, text) {
        const now = _string(phase, 32);
        if (event === "failed")
            return { text: _string(text, 200) || "That didn't work.", phase: now, settling: true };
        if (!_isObject(failure))
            return null;
        if (event === "read") {
            if (failure.settling === true)
                return now === "running" ? null : { text: failure.text, phase: now, settling: false };
            return now !== failure.phase ? null : failure;
        }
        if (event === "view")
            return failure.settling !== true && now !== failure.phase ? null : failure;
        return null;
    }

    // Text from Tailscale (the CLI's stderr, the daemon's errors and health) as plain text:
    // one line, no control characters, and nothing a Text could take for markup — angle
    // brackets and ampersands become look-alikes
    // A name from another device or from the system on one line: control characters (C0, DEL,
    // C1) as spaces, the invisible ones that reorder or hide text (bidi controls, zero-width
    // marks, the BOM) dropped, white space collapsed, cut with "…" past `maxLength` (100)
    function oneLine(value, maxLength) {
        const text = (typeof value === "string" ? value : value === null || value === undefined ? "" : String(value)).slice(0, 4000)
            .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/[\u061c\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff\ufff9-\ufffb]/g, "")
            .replace(/\s+/g, " ").trim();
        return _clip(text, maxLength ?? 100);
    }

    function plainText(value, maxLength) {
        const text = _string(value, 4000).replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim()
            .replace(/</g, "‹").replace(/>/g, "›").replace(/&/g, "＆");
        return _clip(text, maxLength ?? 200);
    }

    // The status text of a failure: `reason` (the failure's sentence). `daemonSays`
    // (optional): what the daemon reported meanwhile — the bus's ErrMessage, then its health
    // warnings (notifyDigest's { severity, text, impactsConnectivity }) — used only when the
    // failure has no words of its own (a time limit, a bare exit status), and of the health
    // only warnings that cut the connection or are severe: a daemon that cannot make its
    // network device (a kernel updated without a reboot) lets `up` wait while only its
    // health says why; an update notice says nothing about it. ≤ 80 characters (the entry's
    // status line).
    function failureText(reason, daemonSays) {
        let text = plainText(reason, 600);
        const generic = text === "" || /^Still connecting after|did not answer within|exited with status|^Tailscale did not answer in time/.test(text);
        if (generic) {
            const error = plainText(_get(daemonSays, "error"), 600);
            const serious = item => _isObject(item) && (item.impactsConnectivity === true || item.severity === "high");
            const list = Array.isArray(_get(daemonSays, "health")) ? _get(daemonSays, "health").slice(0, 64) : [];
            const health = list.filter(serious).sort((a, b) => (a.impactsConnectivity === true ? 0 : 1) - (b.impactsConnectivity === true ? 0 : 1))
                .map(item => plainText(item.text || item.title, 600)).find(line => line !== "") ?? "";
            const own = error !== "" ? "Tailscale said: " + error : health;
            if (own !== "")
                text = own;
        }
        return _clip(text, 80) || "That didn't work.";
    }

    // ---- Logging: once per change of outcome, not once per attempt ----

    // The line for one attempt at `what` (module.log keeps one per key: the same line again is
    // not written): `ok` its outcome, `reason` its failure, `wasFailing` the last line written
    // for it was a failure → null (nothing to say: answering, as before) | { level, text }:
    // a failure with its reason (a new reason is a new line), the recovery once
    function logLine(what, ok, reason, wasFailing) {
        const name = plainText(what, 80);
        if (ok === true)
            return wasFailing === true ? { level: "info", text: name + " answers again" } : null;
        return { level: "warn", text: name + " failed: " + (plainText(reason, 300) || "failed") };
    }

    // ---- Looking again: Tailscale installed, started or fixed while the shell runs ----

    // facts { cli ("unknown" | "present" | "missing" | "untrusted"), daemon, phase, readFailing
    // (the last status read failed: not answering, an answer that could not be read) }, `asked`
    // true for the user's own "Check again" (else a view coming on screen, the timer) →
    //   "probe"  look for the programs again (not found, not trusted, or not looked for yet)
    //   "read"   read the state again and restart the event stream (the service was not
    //            running or its reads fail — these reads follow the backoff, not a faster loop;
    //            or asked while all is well)
    //   "none"   nothing is missing: the stream and the slow poll keep it current
    function recheckPlan(facts, asked) {
        const cli = _string(_get(facts, "cli"), 16);
        if (cli !== "present")
            return "probe";
        const daemon = _string(_get(facts, "daemon"), 16);
        const phase = _string(_get(facts, "phase"), 32);
        if (daemon === "not-running" || phase === "not-running" || phase === "denied" || _get(facts, "readFailing") === true || asked === true)
            return "read";
        return "none";
    }

    // The wait before the next look while something is missing: `minMs` doubling with each
    // look (`attempt`, from 0), at most `maxMs` (the slow poll)
    function recheckDelayMs(attempt, minMs, maxMs) {
        const low = Math.max(100, _number(minMs, 5000));
        const high = Math.max(low, _number(maxMs, 60000));
        const step = Math.min(20, Math.max(0, Math.trunc(_number(attempt, 0))));
        return Math.min(high, low * Math.pow(2, step));
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
                addresses: node.addresses, ipv4: node.addresses.find(address => Api.address.isIpv4(address)) ?? "",
                os: node.os, owner: user?.loginName ?? "", ownerName: user?.displayName ?? "",
                tags: node.tags, online: node.online,
                lastSeen: node.online ? 0 : node.lastSeen,
                lastSeenText: node.online ? "online" : (node.lastSeen > 0 ? Api.format.ago(node.lastSeen, now) : "never"),
                connection: connectionOf(node), exitNodeOption: node.exitNodeOption, isExitNode: node.exitNode,
                subnetRoutes: node.primaryRoutes.filter(route => route !== "0.0.0.0/0" && route !== "::/0"),
                keyExpired: node.expired || (node.keyExpiry > 0 && now > 0 && node.keyExpiry <= now),
                keyExpiry: node.keyExpiry, rxBytes: node.rxBytes, txBytes: node.txBytes,
                canReceiveFiles: taildrop === 1,
                fileSharingNote: taildrop === 1 ? "" : (node.noFileSharingReason || (taildrop >= 0 && taildrop < _taildropReasons.length ? _taildropReasons[taildrop] : "unknown")),
                sshHostKeys: node.sshHostKeys,
                sharedIn: _sharedIn(node, suffix), locationNode: locationNode, location: node.location
            });
            list[list.length - 1].sshCommand = sshCommand(list[list.length - 1]);
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
        const ipv4 = (node.addresses ?? []).find(address => Api.address.isIpv4(address));
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
                // Names and labels on one line: shown in the chooser and kept with a network's choice
                id: node.id, name: oneLine(_shortName(node), 64), label: oneLine(exitNodeLabel(node), 64), dnsName: node.dnsName,
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

    // This computer for the page's "This device": thisDevice(status, prefs, now,
    // systemHostname) → null (not read) | { hostName (the name it HAS: prefs' --hostname when
    // set, else status's), customHostname (prefs' --hostname; "" = the system's), statusName
    // (what the tailnet shows now: status's Self), namePending (the tailnet does not show
    // hostName yet), nameNote ("" | "the tailnet shows it after connecting" | "updating"),
    // dnsName (MagicDNS, as the tailnet has it — stale while namePending), ipv4, ipv6,
    // online, relay (home DERP region code), keyExpiry (ms), key (keyState) }.
    // Why: `set --hostname` changes prefs at once, but status's Self (HostName, DNSName) comes
    // from the control plane, which learns the name only once connected (observed: set while
    // Stopped, status still had the old name). systemHostname: the OS's name ("" unknown) —
    // only to tell whether going back to the system's name has reached the tailnet yet.
    function thisDevice(status, prefs, now, systemHostname) {
        const self = _isObject(status) && _isObject(status.self) ? status.self : null;
        if (!self)
            return null;
        const addresses = _strings(status.addresses, 16).length > 0 ? _strings(status.addresses, 16) : self.addresses;
        const custom = _string(_get(prefs, "hostname"), 256);
        const system = _string(systemHostname, 256).split(".")[0];
        const label = name => String(name).split(".")[0].toLowerCase();
        const wanted = custom !== "" ? custom : system;
        const pending = wanted !== "" && self.hostName !== "" && label(wanted) !== label(self.hostName);
        const running = _isObject(status) && status.backendState === "Running";
        return {
            hostName: custom !== "" ? custom : (system !== "" ? system : self.hostName),
            customHostname: custom,
            statusName: self.hostName,
            namePending: pending,
            nameNote: !pending ? "" : (running ? "updating" : "the tailnet shows it after connecting"),
            dnsName: self.dnsName,
            ipv4: addresses.find(address => Api.address.isIpv4(address)) ?? "",
            ipv6: addresses.find(address => Api.address.isIpv6(address)) ?? "",
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

    // ---- Sharing this computer (delivery step 3) ----
    //
    // Everything here is a preference changed with `tailscale set` (cmd/tailscale/cli/set.go of
    // 1.104.4). The exit node and the subnet routes are ONE preference, AdvertiseRoutes (the
    // exit node = the pair 0.0.0.0/0 and ::/0). set.go's calcAdvertiseRoutesForSet composes
    // them: `--advertise-routes=<list>` alone keeps the exit-node pair when it is advertised
    // (netutil.CalcAdvertiseRoutes(list, curPrefs.AdvertisesExitNode())); `--advertise-exit-node=
    // <bool>` alone keeps the subnet routes (it filters the /0s out or appends them). So the
    // module never passes both flags in one command, and never puts a /0 into the route list.
    // Approval: status's Self.AllowedIPs holds the node's own addresses plus the routes an admin
    // approved; PrimaryRoutes those it currently serves as the primary router; ExitNodeOption is
    // ContainsExitRoutes(AllowedIPs) (ipnlocal peerStatusFromNode).

    readonly property string adminAclsUrl: "https://login.tailscale.com/admin/acls"
    // The web interface's port (tsconst.WebListenPort)
    readonly property int webClientPort: 5252
    // The capability that lets this node run Tailscale SSH (nodecap.SSH; the daemon refuses
    // `--ssh` without it: ipnlocal checkSSHPrefsLocked)
    readonly property string sshCapability: "https://tailscale.com/cap/ssh"
    // Tailscale's own ranges: a route inside them is warned about
    readonly property var tailscaleRanges: ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]

    function _isDefaultControl(prefs) {
        const url = _string(_get(prefs, "controlUrl"), 2048);
        return url === "" || /^https:\/\/(controlplane|login)\.tailscale\.com\/?$/.test(url);
    }

    // The admin console's page of this machine (the default control server only; else "")
    function adminMachineUrl(status, prefs) {
        if (!_isDefaultControl(prefs))
            return "";
        const self = _isObject(status) && _isObject(status.self) ? status.self : null;
        const ipv4 = self ? (self.addresses.find(address => Api.address.isIpv4(address)) ?? "") : "";
        return ipv4 !== "" ? adminMachinesUrl + "/" + ipv4 : adminMachinesUrl;
    }

    // A route the user types: routeProblem(text, offered [networks]) → { network, error, warning }.
    // As the CLI checks it (net/netutil/routes.go CalcAdvertiseRoutes: netip.ParsePrefix — an
    // address/prefix, no host bits set) and more: no duplicates, no default route (that is the
    // exit-node switch). A warning (not refusing) for Tailscale's own ranges.
    function routeProblem(text, offered) {
        const value = typeof text === "string" ? text.trim() : "";
        const result = { network: "", error: "", warning: "" };
        if (value === "") {
            result.error = "Write a network as address/prefix, e.g. 192.168.1.0/24.";
            return result;
        }
        const slash = value.indexOf("/");
        if (slash < 0 || !/^\d{1,3}$/.test(value.slice(slash + 1)) || (value.length - slash > 2 && value[slash + 1] === "0")) {
            result.error = "Not a network: write it as address/prefix, e.g. 192.168.1.0/24.";
            return result;
        }
        const cidr = Api.address.parseCidr(value);
        if (!cidr) {
            result.error = "Not a network: write it as address/prefix, e.g. 192.168.1.0/24.";
            return result;
        }
        if (cidr.bits === 0) {
            result.error = "That is the default route: offer this computer as an exit node instead.";
            return result;
        }
        if (!cidr.canonical) {
            result.error = "Host bits are set: the network is " + cidr.network + ".";
            return result;
        }
        result.network = cidr.network;
        const existing = (Array.isArray(offered) ? offered : []).map(item => Api.address.parseCidr(item)).filter(item => item !== null).map(item => item.network);
        if (existing.includes(cidr.network)) {
            result.error = "Already offered.";
            return result;
        }
        const range = tailscaleRanges.find(item => Api.address.overlap(Api.address.parseCidr(item), cidr));
        if (range)
            result.warning = "It overlaps Tailscale's own addresses (" + range + ").";
        return result;
    }

    // The subnet routes after adding or removing one (never the exit-node pair: see above)
    function routesWith(routes, network) {
        const list = _strings(routes, 256).filter(route => { const cidr = Api.address.parseCidr(route); return cidr !== null && cidr.bits > 0; });
        const added = Api.address.parseCidr(network);
        if (!added || added.bits === 0 || list.some(route => Api.address.parseCidr(route).network === added.network))
            return list;
        return list.concat([added.network]);
    }

    function routesWithout(routes, network) {
        const removed = Api.address.parseCidr(network);
        return _strings(routes, 256).filter(route => {
            const cidr = Api.address.parseCidr(route);
            return cidr !== null && cidr.bits > 0 && (!removed || cidr.network !== removed.network);
        });
    }

    // Which profile prefs belong to: its login, its node, its control server ("" not known).
    // Two reads with different identities are two profiles (a switch, a login in between).
    function prefsIdentity(prefs) {
        if (!_isObject(prefs) || prefs.ok !== true)
            return "";
        const login = _string(prefs.loginName, 200);
        const node = _string(prefs.nodeId, 128);
        return login === "" && node === "" ? "" : login + "|" + node + "|" + _string(prefs.controlUrl, 2048);
    }

    // A route edit is an INTENT — { add: <network> } or { remove: <network> } — planned against
    // prefs read just before the command runs (the live side reads them again under its
    // operation lock, also right before a retry through pkexec): routeEditPlan(prefs, intent,
    // identity) → { kind, error, routes, command }:
    //   "run"      command: `set --advertise-routes=<the whole new list>`; routes: that list
    //   "nothing"  already as asked (the route already offered / not offered): nothing to send
    //              — the live side refuses that at the click, and accepts it at a re-check
    //   "changed"  prefs belong to another profile than `identity` (the one clicked in)
    //   "refused"  error: prefs unknown, the list cut, the route invalid
    function routeEditPlan(prefs, intent, identity) {
        const plan = (kind, extra) => Object.assign({ kind: kind, error: "", routes: [], command: null }, extra ?? {});
        if (!_isObject(prefs) || prefs.ok !== true)
            return plan("refused", { error: "Tailscale's settings are not read yet: try again in a moment." });
        if (prefs.advertiseRoutesCut === true)
            return plan("refused", { error: "More routes are offered than the module reads (256): change them with `tailscale set`." });
        if (typeof identity === "string" && identity !== "" && prefsIdentity(prefs) !== identity)
            return plan("changed", { error: "Changed meanwhile (another account?): try again." });
        const current = _strings(prefs.advertiseRoutes, 256);
        const adding = _isObject(intent) && typeof intent.add === "string";
        const removing = _isObject(intent) && typeof intent.remove === "string";
        if (adding === removing)
            return plan("refused", { error: "Not a route change." });
        const offered = current.map(item => Api.address.parseCidr(item)).filter(item => item !== null).map(item => item.network);
        let routes;
        if (adding) {
            const check = routeProblem(intent.add, []);
            if (check.error !== "")
                return plan("refused", { error: check.error });
            if (offered.includes(check.network))
                return plan("nothing");
            routes = routesWith(current, check.network);
        } else {
            const removed = Api.address.parseCidr(intent.remove);
            if (!removed)
                return plan("refused", { error: "Not a network." });
            if (!offered.includes(removed.network))
                return plan("nothing");
            routes = routesWithout(current, removed.network);
        }
        const command = commandFor("advertiseRoutes", { routes: routes });
        if (!command.ok)
            return plan("refused", { error: command.error });
        return plan("run", { routes: routes, command: command });
    }

    // Prefs as they are after a route edit succeeded (the list sent, the exit node unchanged):
    // held at once, so a second edit before the next read builds on the first
    function prefsWithRoutes(prefs, routes) {
        if (!_isObject(prefs))
            return prefs;
        const list = _strings(routes, 256);
        return Object.assign({}, prefs, {
            advertiseRoutes: list,
            advertiseRoutesAll: prefs.advertiseExitNode === true ? ["0.0.0.0/0", "::/0"].concat(list) : list
        });
    }

    // Why this computer cannot offer an exit node now ("" it can): the daemon refuses to
    // advertise one while it uses one (ipnlocal checkExitNodePrefsLocked: "Cannot advertise an
    // exit node and use an exit node at the same time.")
    function exitNodeOfferProblem(prefs) {
        if (!_isObject(prefs))
            return "";
        return _string(prefs.exitNodeId) !== "" || _string(prefs.exitNodeIp) !== ""
            ? "It uses an exit node itself: Tailscale cannot do both. Stop using it first." : "";
    }

    // The reverse: choosing an exit node while this computer offers itself as one
    function exitNodeUseProblem(prefs) {
        return _isObject(prefs) && prefs.advertiseExitNode === true
            ? "This computer offers itself as an exit node: Tailscale cannot also use one. Stop offering it first." : "";
    }

    // What this computer offers to the tailnet, for the page's Sharing section:
    // sharing(status, prefs) → {
    //   known (prefs read), connected (Running: approval states are current),
    //   exitNode { offered, state "off" | "pending" | "approved" | "unknown", text, problem },
    //   routes [{ route, family, state "pending" | "approved" | "standby" | "unknown", text }],
    //   offersAny (routes, exit node or app connector: forwarding matters), families [4, 6]
    //   (those that need forwarding), pendingCount, adminUrl,
    //   tagsRequested, tagsApplied, connector, snat, statefulFiltering, netfilterMode,
    //   relayServerPort, webClient, webClientUrl, postureChecking, autoUpdate, updateCheck }
    function sharing(status, prefs) {
        const known = _isObject(prefs) && prefs.ok !== false;
        const self = _isObject(status) && _isObject(status.self) ? status.self : null;
        const connected = _isObject(status) && status.backendState === "Running" && self !== null;
        const allowed = self ? self.allowedIps.map(item => Api.address.parseCidr(item)).filter(item => item !== null).map(item => item.network) : [];
        const primary = self ? self.primaryRoutes.map(item => Api.address.parseCidr(item)).filter(item => item !== null).map(item => item.network) : [];
        const offeredExit = known && prefs.advertiseExitNode === true;
        const exitApproved = self !== null && (self.exitNodeOption === true || (allowed.includes("0.0.0.0/0") && allowed.includes("::/0")));
        const exitState = !offeredExit ? "off" : (!connected ? "unknown" : (exitApproved ? "approved" : "pending"));
        const stateText = { pending: "waiting for an admin's approval", approved: "approved", standby: "approved; another device serves it now",
            unknown: "approval shown when connected", off: "" };
        const routes = (known ? prefs.advertiseRoutes : []).map(route => {
            const cidr = Api.address.parseCidr(route);
            if (!cidr)
                return null;
            const state = !connected ? "unknown" : (!allowed.includes(cidr.network) ? "pending" : (primary.includes(cidr.network) ? "approved" : "standby"));
            return { route: cidr.network, family: cidr.family, state: state, text: stateText[state] };
        }).filter(item => item !== null);
        const families = [];
        if (offeredExit || (known && prefs.advertiseConnector === true))
            families.push(4, 6);
        for (const route of routes)
            if (!families.includes(route.family))
                families.push(route.family);
        const selfIpv4 = self ? (self.addresses.find(address => Api.address.isIpv4(address)) ?? "") : "";
        return {
            known: known, connected: connected,
            exitNode: { offered: offeredExit, state: exitState, text: stateText[exitState], problem: known ? exitNodeOfferProblem(prefs) : "" },
            routes: routes,
            offersAny: offeredExit || routes.length > 0 || (known && prefs.advertiseConnector === true),
            families: families.sort(),
            pendingCount: routes.filter(route => route.state === "pending").length + (exitState === "pending" ? 1 : 0),
            adminUrl: adminMachineUrl(status, prefs),
            tagsRequested: known ? _strings(prefs.advertiseTags, 64) : [],
            tagsApplied: self ? self.tags : [],
            connector: known && prefs.advertiseConnector === true,
            snat: !known || prefs.snat !== false,
            statefulFiltering: known ? prefs.statefulFiltering : null,
            netfilterMode: known ? _string(prefs.netfilterMode, 16) : "",
            relayServerPort: known ? prefs.relayServerPort : null,
            webClient: known && prefs.webClient === true,
            webClientUrl: known && prefs.webClient === true && selfIpv4 !== "" ? "http://" + selfIpv4 + ":" + webClientPort : "",
            postureChecking: known && prefs.postureChecking === true,
            autoUpdate: known ? prefs.autoUpdate : null,
            updateCheck: !known || prefs.updateCheck !== false
        };
    }

    // The forwarding warning for the Sharing section: forwardingWarning(sharing, forwarding,
    // busHealth, status, nixos) → null | { text, families [4|6 that are off], tailscaleSays
    // (Tailscale's own health text, or ""), nixosLines [] }. Only while something is offered
    // (routes, the exit node, an app connector — set.go's warnOnAdvertiseRoutes asks then too).
    // The module writes no sysctl: it says what to do.
    function forwardingWarning(share, forwarding, busHealth, status, nixos) {
        if (!_isObject(share) || share.offersAny !== true)
            return null;
        const off = (share.families ?? []).filter(family => _get(forwarding, family === 4 ? "ipv4" : "ipv6") === false);
        // Tailscale's own: health warnable "ip-forwarding-off" (health/warnings.go), or its text
        const fromBus = Array.isArray(busHealth) ? busHealth.find(warning => _isObject(warning) && warning.code === "ip-forwarding-off") : null;
        const fromStatus = _strings(_isObject(status) ? status.health : [], 64).find(text => /IP forwarding is (disabled|off)/i.test(text)) ?? "";
        const tailscaleSays = fromBus ? _string(fromBus.text, 300) || _string(fromBus.title, 200) : fromStatus;
        if (off.length === 0 && tailscaleSays === "")
            return null;
        const names = off.map(family => family === 4 ? "IPv4" : "IPv6").join(" and ");
        return {
            text: off.length > 0 ? "IP forwarding is off (" + names + "): other devices cannot reach the offered networks through this computer."
                : "Tailscale says IP forwarding is off.",
            families: off,
            tailscaleSays: tailscaleSays,
            nixosLines: nixos === true ? [
                "services.tailscale.useRoutingFeatures = \"server\";",
                "# or: boot.kernel.sysctl.\"net.ipv4.ip_forward\" = 1; boot.kernel.sysctl.\"net.ipv6.conf.all.forwarding\" = 1;"
            ] : ["net.ipv4.ip_forward = 1", "net.ipv6.conf.all.forwarding = 1"]
        };
    }

    // Tailscale SSH for the page: sshServer(status, prefs) → { on, allowedByTailnet (true,
    // false, null unknown: no CapMap), canTurnOn, problem }
    function sshServer(status, prefs) {
        const self = _isObject(status) && _isObject(status.self) ? status.self : null;
        const caps = self && Array.isArray(self.caps) ? self.caps : null;
        const allowed = caps === null ? null : caps.includes(sshCapability);
        return {
            on: _isObject(prefs) && prefs.ssh === true,
            allowedByTailnet: allowed,
            canTurnOn: allowed !== false,
            problem: allowed === false ? "Not enabled for this tailnet: Tailscale refuses to start its SSH server." : ""
        };
    }

    // The command a device row copies: "ssh <MagicDNS name>" (else its IPv4 address) for a
    // device that runs Tailscale SSH (sshHostKeys), or "" — never a name that could be read
    // as an option or holds anything but DNS characters (names come from the tailnet)
    function sshCommand(device) {
        if (!_isObject(device) || !(device.sshHostKeys > 0))
            return "";
        const name = _string(device.dnsName, 253);
        if (name !== "" && validTarget(name) && !Api.address.isIpv4(name))
            return "ssh " + name;
        const ipv4 = (device.addresses ?? []).find(address => Api.address.isIpv4(address)) ?? "";
        return ipv4 !== "" ? "ssh " + ipv4 : "";
    }

    // A relay server port as typed: "" (off) or 0–65535 (0: any free port), digits only
    // (set.go: strconv.ParseUint(…, 10, 16)) → "" or why not
    function relayPortProblem(text) {
        if (typeof text !== "string")
            return "Not a port.";
        if (text === "")
            return "";
        if (!/^\d{1,5}$/.test(text) || Number(text) > 65535 || (text.length > 1 && text[0] === "0"))
            return "A port 0–65535 (0: any free port).";
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
                .map(warning => ({ title: plainText(warning.title, 200), text: plainText(warning.text, 500), severity: _string(warning.severity, 16) }));
        return _strings(_isObject(status) ? status.health : [], 64).map(text => ({ title: "", text: plainText(text, 500), severity: "" }));
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
                lines.push("  " + Api.address.redact(strip([warning.title, warning.text].filter(part => part).join(": "))));
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
    //   "aborted"     a risk confirmation answered no (set --ssh inside an SSH session)
    //   "other"       anything else; `message` its first line
    // `message` is one sentence for a notification's body.
    function errorKind(exitCode, stderr) {
        const text = typeof stderr === "string" ? stderr.slice(0, 65536) : (stderr === null || stderr === undefined ? "" : String(stderr).slice(0, 65536));
        const code = typeof exitCode === "number" ? exitCode : Number(exitCode);
        if (code === 0)
            return { kind: "", message: "" };
        if (/^\s*Access denied:/m.test(text) || /\baccess denied\b/i.test(text)
                // A serve config holding a path (set by root before) needs root even from the operator
                // (ipn/localapi/serve.go): the module itself never adds one
                || /must be root, or be an operator and able to run/.test(text))
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
        // The risk check of `set --ssh` (cli/up.go presentSSHToggleRisk) asks "Continue?" only
        // when the CLI runs inside an SSH session over Tailscale (SSH_CLIENT): with no terminal
        // it answers no (cli/risks.go errAborted)
        if (/aborted, no changes made/.test(text))
            return { kind: "aborted", message: "Tailscale asked for a confirmation (it runs inside an SSH session over Tailscale) and nothing was changed: run the command in a terminal there." };
        // The CLI's own "Warning: …" lines (a version mismatch, IP forwarding) are not the error,
        // nor what a waiting `login` / `up` printed before it failed ("To authenticate, visit:"
        // and the link: a login link is never a reason)
        const waitingLine = line => /^To (authenticate|approve your machine)\b/i.test(line) || /^[a-z][a-z0-9+.-]*:\/\/\S+$/i.test(line);
        const candidates = text.split("\n").map(line => line.trim().replace(/\bhttps?:\/\/\S*\/a\/\S*/gi, "").trim())
            .filter(line => line !== "" && !waitingLine(line));
        const firstLine = candidates.find(line => !/^Warning:/.test(line)) ?? candidates[0] ?? "";
        return { kind: "other", message: firstLine !== "" ? firstLine.slice(0, 300) : ("Tailscale exited with status " + (isFinite(code) ? code : "?") + ".") };
    }

    // How a run as administrator ended — module.privileged's result (module API 1.11) →
    // { kind: "ok" | "dismissed" | "cancelled" | "failed", notify, message }:
    //   ok         exit 0
    //   cancelled  the module cancelled it itself: nothing to say
    //   dismissed  the prompt was dismissed or the password not accepted, or the run was
    //              refused because the session is locked (blocked "locked"): show nothing,
    //              emit nothing (the provider contract: "Cancelled is not failed")
    //   failed     `message` for the entry and the page; `notify` false for `refused` (not
    //              authorised, or no authentication agent answered), which the shell itself
    //              tells once, and true for the rest (the provider's failed())
    // `name` and `seconds`: the command's, for the time limit's sentence.
    // The shell's refusals before pkexec (module API 1.11 `blocked`) in plain words; one it
    // may add later is said without a reason, never as its code word
    readonly property var blockedReasons: ({
        "unprintable": "the command holds characters that can't be shown",
        "no-purpose": "it doesn't say what it is for",
        "locked": "the screen is locked"
    })

    function privilegedOutcome(result, name, seconds) {
        const field = key => _get(result, key);
        const failed = (message, notify) => ({ kind: "failed", notify: notify !== false, message: message });
        if (field("ok") === true)
            return { kind: "ok", notify: false, message: "" };
        if (field("cancelled") === true)
            return { kind: "cancelled", notify: false, message: "" };
        if (field("dismissed") === true)
            return { kind: "dismissed", notify: false, message: "" };
        if (field("refused") === true)
            return failed("Not allowed.", false);
        if (field("timedOut") === true)
            return failed(timeoutMessage(name, seconds));
        if (field("notFound") === true)
            return failed("It could not be run as administrator: tailscale was not found.");
        const blocked = _string(field("blocked"), 40);
        if (blocked !== "")
            return failed("It was not run as administrator"
                          + (Object.prototype.hasOwnProperty.call(blockedReasons, blocked) ? ": " + blockedReasons[blocked] : "") + ".");
        const error = _string(field("error"), 300);
        if (error !== "")
            return failed("It could not be run as administrator: " + error);
        return failed(errorKind(field("code"), _string(field("stderr"), 65536)).message);
    }

    // A command stopped by its time limit (`seconds`, timeLimits) → one sentence for the
    // failure notification
    function timeoutMessage(name, seconds) {
        const value = _number(seconds, 0);
        const limit = value >= 120 ? Math.round(value / 60) + " minutes" : Math.round(value) + " s";
        if (name === "connect")
            return "Still connecting after " + limit + ". Disconnect to stop.";
        if (name === "login" || name === "addAccount")
            return "The login was not finished within " + limit + "; nothing was changed.";
        if (name === "status" || name === "prefs" || name === "exitNodeSuggest")
            return "Tailscale did not answer within " + limit + ".";
        return "Tailscale did not answer within " + limit + "; the change may not have been made.";
    }


    // ---- Which programs run ----
    //
    // The shell looks the module's programs up (the manifest's optionalPrograms) and judges
    // them: module.programs (module API 1.9) — { <name>: { path, trusted, reason } }, or, in
    // module test mode, the stand-ins of the manifest's testPrograms. The module runs each by
    // that absolute path. Only tailscale has to be trusted (only root can change it): it is
    // the one program handed to pkexec. timeout, curl, systemctl and openssl run as this user
    // only — one the user could change gives nothing the user could not do anyway. pkexec is
    // named in the manifest only for module test mode, where the shell takes its stand-in
    // from there; outside it the shell uses its own.
    readonly property var programNames: ["tailscale", "timeout", "curl", "systemctl", "openssl"]

    // programsFound(programs) → { known, cli ("unknown" while not looked up | "present" |
    // "missing" | "untrusted": nothing runs), untrustedReason, and each of programNames: its
    // absolute path or "" }. A path that is not absolute, or holds white space, counts as not
    // found; an untrusted tailscale's path is not given.
    function programsFound(programs) {
        const result = { known: false, cli: "unknown", untrustedReason: "" };
        for (const name of programNames)
            result[name] = "";
        if (programs === null || typeof programs !== "object" || Array.isArray(programs))
            return result;
        result.known = true;
        for (const name of programNames) {
            const path = _get(_get(programs, name), "path");
            result[name] = _validPath(path) && !/\s/.test(path) && !path.endsWith("/") ? path : "";
        }
        if (result.tailscale === "") {
            result.cli = "missing";
            return result;
        }
        if (_get(_get(programs, "tailscale"), "trusted") !== true) {
            const reason = plainText(_string(_get(_get(programs, "tailscale"), "reason"), 300), 200).replace(/[.\s]+$/, "");
            result.cli = "untrusted";
            result.untrustedReason = "Tailscale isn't trusted (" + (reason !== "" ? reason : "it could not be checked") + "): nothing runs.";
            result.tailscale = "";
            return result;
        }
        result.cli = "present";
        return result;
    }

    // Why nothing can be run as administrator ("" it can): only while Tailscale is there.
    // `available` and `reason`: module.privileged's (the shell's trusted pkexec and timeout)
    function elevationProblem(cli, available, reason) {
        if (cli !== "present" || available === true)
            return "";
        const why = plainText(_string(reason, 300), 200).replace(/[.\s]+$/, "");
        return "Changes that need an administrator are not offered" + (why !== "" ? ": " + why : "") + ".";
    }

    // ---- Running a command (the shell's command runner, module API 1.8) ----

    // A command by its program's absolute path: commandLine(argv, path) → the argv with `path`
    // in place of its first word (commandFor's argv starts with "tailscale", startService's with
    // "systemctl"); [] when the path is not absolute or the argv not a list of words
    function commandLine(argv, path) {
        if (!Array.isArray(argv) || argv.length === 0 || !argv.every(item => typeof item === "string") || !_validPath(path) || /\s/.test(path))
            return [];
        return [path].concat(argv.slice(1));
    }

    // A run's limits for the runner: runLimits(limitMs) → { ok, timeoutMs, killAfterMs }.
    // `limitMs` milliseconds, rounded, at most a day (maxRunMs) — or 0: no limit (the event
    // stream, which lives as long as the daemon answers). Past the limit the runner sends
    // TERM, and KILL timeLimits.killAfter later. Not a number, or below 0: not ok
    readonly property int maxRunMs: 86400000
    function runLimits(limitMs) {
        const killAfterMs = timeLimits.killAfter * 1000;
        if (typeof limitMs !== "number" || !isFinite(limitMs) || limitMs < 0)
            return { ok: false, timeoutMs: 0, killAfterMs: killAfterMs };
        return { ok: true, timeoutMs: Math.min(maxRunMs, Math.round(limitMs)), killAfterMs: killAfterMs };
    }

    // The event stream's argv: curl on the LocalAPI's watch-ipn-bus (any user may read it),
    // both by absolute path; [] without them
    function streamArgv(curlPath, socket) {
        if (!_validPath(curlPath) || /\s/.test(curlPath) || !_validPath(socket) || /\s/.test(socket))
            return [];
        return [curlPath, "-sN", "--unix-socket", socket, "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus?mask=" + watchMask];
    }

    // Where the runner cuts what a run prints (its maxOutputBytes, in characters): room for
    // `status --json` of a large tailnet (some 2 KB a device). A cut answer is a failed run
    // (runError's "too-long"), never a partial one read as whole
    readonly property int maxAnswerChars: 33554432

    // How a plain run ended — the runner's result ({ ok, code, stdout, stderr, timedOut,
    // cancelled, failedToStart, truncated, error }) → { kind, message }: kind "" (ok),
    // "timeout" (its time limit ended it), "too-long" (its output was cut: what was kept is not
    // the whole answer, even with exit 0), "not-run" (the runner refused it: `error`; or the
    // program could not be started), else errorKind's of its exit status and its error output
    function runError(result) {
        const field = key => _get(result, key);
        if (field("timedOut") === true)
            return { kind: "timeout", message: errorKind(124, "").message };
        if (field("truncated") === true)
            return { kind: "too-long", message: "The answer was too long." };
        if (field("ok") === true)
            return { kind: "", message: "" };
        const refusal = plainText(_string(field("error"), 300), 200);
        if (refusal !== "")
            return { kind: "not-run", message: "It could not be run: " + refusal };
        if (field("failedToStart") === true)
            return { kind: "not-run", message: "The program could not be started." };
        return errorKind(field("code"), _string(field("stderr"), 65536));
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
        if (Api.address.isIp(text))
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
        "advertiseRoutes", "ssh", "webClient", "updateCheck", "autoUpdate", "snat", "statefulFiltering", "connector", "posture",
        "relayServerPort", "operator", "switchAccount", "switchList", "removeAccount", "nickname", "derpMap",
        "ping", "netcheck", "fileCp", "fileGet", "fileTargets", "serveStatus", "serveReset",
        "funnelStatus", "funnelReset", "lockStatus", "status", "prefs",
        "exitNodeSuggest", "exitNodeList", "dnsStatus", "version", "watch", "startService"]

    // THE command builder: commandFor(name, args) → { ok, error, name, argv, changes,
    // privileged, description, what, writesAsRoot, longRunning }. `argv` is an array for
    // Process (never a shell line), starting with "tailscale" — the live side puts the
    // absolute path in front (privilegedRun for a run as administrator). `changes`: it
    // changes Tailscale's state. `privileged`: it needs root or the operator (try it plainly;
    // on errorKind "denied" retry as administrator — only for a user's click).
    // `description`: for the failure notification ("<description> failed"). `what` (a
    // privileged command's only): a few words saying what it does, for the shell's password
    // prompt ("Authorization: Connect") — never a name, an address or a path. `writesAsRoot`:
    // as administrator it would leave files owned by root (file get): offer "become operator"
    // instead. Never `tailscale up` with a flag: every setting goes through `tailscale set`.
    function commandFor(name, args) {
        const command = _commandFor(name, args);
        if (command.ok && command.privileged)
            command.what = _what(name, _isObject(args) ? args : {});
        return command;
    }

    // The prompt's words for a privileged command (commandFor's `what`)
    function _what(name, options) {
        const on = _get(options, "on") === true;
        switch (name) {
        case "connect":
            return "Connect";
        case "disconnect":
            return "Disconnect";
        case "login":
            return "Log in";
        case "addAccount":
            return "Add an account";
        case "logout":
            return "Log out";
        case "exitNode":
        case "exitNodeAuto":
        case "exitNodeNone":
            return "Change the exit node";
        case "allowLan":
            return on ? "Allow the local network" : "Block the local network";
        case "acceptRoutes":
            return on ? "Accept routes" : "Ignore routes";
        case "acceptDns":
            return on ? "Use Tailscale DNS" : "Ignore Tailscale DNS";
        case "shieldsUp":
            return on ? "Block incoming connections" : "Allow incoming connections";
        case "ssh":
            return on ? "Start the SSH server" : "Stop the SSH server";
        case "webClient":
            return on ? "Start the web interface" : "Stop the web interface";
        case "advertiseExitNode":
            return on ? "Offer an exit node" : "Stop offering an exit node";
        case "autoUpdate":
            return on ? "Turn on automatic updates" : "Turn off automatic updates";
        case "snat":
            return on ? "Turn on source NAT" : "Turn off source NAT";
        case "statefulFiltering":
            return on ? "Turn on stateful filtering" : "Turn off stateful filtering";
        case "connector":
            return on ? "Offer an app connector" : "Stop the app connector";
        case "posture":
            return on ? "Report device posture" : "Stop posture reports";
        case "relayServerPort":
            return String(_get(options, "port") ?? "") === "" ? "Turn off the peer relay" : "Run a peer relay";
        case "updateCheck":
            return on ? "Check for updates" : "Stop update checks";
        case "hostname":
            return "Rename this device";
        case "advertiseRoutes":
            return "Change offered routes";
        case "nickname":
            return "Name the account";
        case "operator":
            return _get(options, "user") === "" ? "Give up the operator role" : "Become the operator";
        case "switchAccount":
            return "Switch account";
        case "switchList":
            return "List accounts";
        case "removeAccount":
            return "Remove an account";
        case "fileCp":
            return (_get(options, "files") ?? []).length === 1 ? "Send a file" : "Send files";
        case "fileGet":
            return "Receive files";
        case "serveReset":
            return "Stop every share";
        case "funnelReset":
            return "Stop Funnel";
        default:
            return "";
        }
    }

    function _commandFor(name, args) {
        const options = _isObject(args) ? args : {};
        const value = key => _get(options, key);
        const set = (flag, description) => _command(name, ["tailscale", "set", flag], true, true, description);
        switch (name) {
        case "connect":
            // Bare, always: never a flag on `up` (or `login`) — not even --timeout: a flag makes
            // `up` demand every non-default setting (the accidental-revert trap). Its time
            // limit is the runner's (runLimits)
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
        case "autoUpdate":
            // The daemon refuses it where it cannot update itself (NixOS: clientupdate's
            // updateNixos is not an auto-updater; ipnlocal checkAutoUpdatePrefsLocked)
            return set(_flag("auto-update", value("on")), (value("on") === true ? "Turning on" : "Turning off") + " Tailscale's automatic updates");
        case "snat":
            return set(_flag("snat-subnet-routes", value("on")), (value("on") === true ? "Turning on" : "Turning off") + " source NAT for offered routes");
        case "statefulFiltering":
            return set(_flag("stateful-filtering", value("on")), (value("on") === true ? "Turning on" : "Turning off") + " stateful filtering of forwarded traffic");
        case "connector":
            return set(_flag("advertise-connector", value("on")), (value("on") === true ? "Offering" : "No longer offering") + " this computer as an app connector");
        case "posture":
            // --report-posture (prefs PostureChecking); there is no --posture-checking flag
            return set(_flag("report-posture", value("on")), (value("on") === true ? "Reporting" : "Not reporting") + " device posture to the tailnet");
        case "relayServerPort": {
            const port = value("port") ?? "";
            const text = typeof port === "number" ? String(port) : port;
            if (relayPortProblem(text) !== "")
                return _refused(name, relayPortProblem(text));
            return set("--relay-server-port=" + text, text === "" ? "Turning off the peer relay" : "Running a peer relay");
        }
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
            // The subnet routes only: set.go keeps the exit-node pair as it is when only
            // --advertise-routes is given (calcAdvertiseRoutesForSet)
            const checked = [];
            for (const route of routes.slice(0, 257)) {
                const problem = routeProblem(route, []);
                if (problem.error !== "")
                    return _refused(name, String(route).slice(0, 60) + ": " + problem.error);
                if (!checked.includes(problem.network))
                    checked.push(problem.network);
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
            // "" gives the operator up: only root may change Tailscale again
            if (user === "")
                return set("--operator=", "Ending this user's right to change Tailscale without a password");
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
            // "--" before the paths (absolute anyway); no address in the description: it reaches
            // notifications. Its limit: timeLimits.send. Run as the user only (TaildropClient)
            return _command(name, ["tailscale", "file", "cp", "--"].concat(files, [target + ":"]), false, true,
                files.length === 1 ? "Sending a file with Taildrop" : "Sending " + files.length + " files with Taildrop", { longRunning: true, timeLimit: "send" });
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

    // A command as administrator, for module.privileged.start (module API 1.11):
    // privilegedRun(command, facts) → { ok, error, argv, what, timeoutMs, environment }. facts:
    // { program (module.programs.tailscale), available (module.privileged.available),
    // unavailableReason, seconds (the command's time limit), environment (the client's) }.
    //   argv       [<tailscale by its absolute path>, args…] — only a TRUSTED tailscale: the
    //              shell does not judge what it is given to run as root, and a program this
    //              user could change would let any of the user's processes become root
    //   what       the command's few words for the prompt ("Connect"): commandFor's `what`
    //   timeoutMs  the limit, 1 s to 1 h: the shell's own `timeout` inside pkexec ends the
    //              command there, as root, even when the shell is gone (a root process cannot
    //              be signalled from here)
    //   environment  null — or, when the client was given variables (only a suite gives
    //              them: the stand-ins' state), a copy of them for the stand-in pkexec
    //              (module API 1.14, taken in module test mode only). Never a variable
    //              otherwise: the shell refuses a run with an environment outside test mode
    function privilegedRun(command, facts) {
        const refuse = error => ({ ok: false, error: error, argv: [], what: "", timeoutMs: 0, environment: null });
        const argv = _get(command, "argv");
        if (!Array.isArray(argv) || argv.length === 0 || argv[0] !== "tailscale" || !argv.every(item => typeof item === "string"))
            return refuse("not a tailscale command");
        const what = _string(_get(command, "what"), 60).trim();
        if (what === "")
            return refuse("nothing says what it does");
        if (_get(facts, "available") !== true)
            return refuse(elevationProblem("present", false, _get(facts, "unavailableReason")));
        const program = _get(facts, "program");
        const path = _get(program, "path");
        if (!_validPath(path) || /\s/.test(path) || path.endsWith("/"))
            return refuse("Tailscale was not found: nothing is run as administrator.");
        if (_get(program, "trusted") !== true)
            return refuse("Tailscale isn't trusted: it is not run as administrator.");
        const seconds = _get(facts, "seconds");
        if (!_validSeconds(seconds) || seconds > 3600)
            return refuse("not a time limit for a run as administrator");
        return { ok: true, error: "", argv: [path].concat(argv.slice(1)), what: what, timeoutMs: seconds * 1000,
                 environment: _environmentCopy(_get(facts, "environment")) };
    }

    // { NAME: "value" | null } with at least one name → a plain copy; anything else → null
    function _environmentCopy(given) {
        if (given === null || typeof given !== "object" || Array.isArray(given))
            return null;
        const copy = {};
        for (const name of Object.keys(given)) {
            const value = given[name];
            if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && (typeof value === "string" || value === null))
                copy[name] = value;
        }
        return Object.keys(copy).length > 0 ? copy : null;
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

    // The local networks for routeShadowsLan, from the shell's Api.localNetworks rows ({ device,
    // kind, family, address, network }: VPN devices left out already) → their networks
    // ("192.168.1.0/24"), each once; a row without a network (a lone /32 or /128 address) adds
    // nothing
    function lanSubnets(localNetworks) {
        const result = [];
        for (const row of Array.isArray(localNetworks) ? localNetworks.slice(0, 64) : []) {
            const network = _isObject(row) && typeof row.network === "string" ? Api.address.parseCidr(row.network) : null;
            if (network !== null && network.bits > 0 && !result.includes(network.network))
                result.push(network.network);
        }
        return result;
    }

    // Accepted subnet routes that cover the local network — a known trap: traffic for the
    // LAN goes into the tailnet. routeShadowsLan(status, lanSubnets, prefs) → [{ route,
    // lan, device, text }]; none while prefs say routes are not accepted. lanSubnets: the
    // local networks as "address/prefix" (an address with host bits is fine here).
    function routeShadowsLan(status, lanSubnets, prefs) {
        if (prefs && _get(prefs, "acceptRoutes") === false)
            return [];
        const lans = (Array.isArray(lanSubnets) ? lanSubnets : []).slice(0, 64).map(item => Api.address.parseCidr(item)).filter(cidr => cidr !== null && cidr.bits > 0);
        const found = [];
        for (const node of _peersOf(status)) {
            for (const route of node.primaryRoutes) {
                const cidr = Api.address.parseCidr(route);
                if (!cidr || cidr.bits === 0)
                    continue;
                for (const lan of lans) {
                    if (!Api.address.overlap(cidr, lan))
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

    // Tailscale beside another VPN: twoVpnsNote({ tailscaleUp, exitNode (name or ""), acceptDns,
    // routes (traffic().routes: what Tailscale carries, null not known), otherVpns: the other
    // VPNs up as the shell's Api.vpnsUp rows ({ name, fullTunnel, setsDns, routes }, module API
    // 1.16) }) → a sentence, or "" when there is nothing to say. An exit node competes only with
    // a VPN that takes all traffic, Tailscale's DNS only with one that brings its own servers;
    // what the shell does not know (null) may compete. A VPN whose routes overlap the tailnet or
    // the subnet routes Tailscale carries competes for those addresses (overlappingVpns). A split
    // VPN that sets no DNS and carries none of Tailscale's addresses is no conflict.
    function twoVpnsNote(input) {
        const others = _otherVpns(_get(input, "otherVpns"));
        if (_get(input, "tailscaleUp") !== true || others.length === 0)
            return "";
        const exitNode = _string(_get(input, "exitNode"), 200);
        const parts = [];
        const traffic = others.filter(vpn => vpn.fullTunnel !== false).map(vpn => vpn.name);
        if (exitNode !== "" && traffic.length > 0)
            parts.push(traffic.join(", ") + " and Tailscale's exit node " + exitNode + " compete for internet traffic");
        for (const found of _overlaps(others, _get(input, "routes")))
            parts.push(found.name + " and Tailscale both route " + found.route + ": some devices may be out of reach");
        const dns = others.filter(vpn => vpn.setsDns !== false).map(vpn => vpn.name);
        if (_get(input, "acceptDns") !== false && dns.length > 0)
            parts.push("Tailscale's DNS (" + quadHundred + ") and " + dns.join(", ") + "'s compete: some names may not resolve");
        return parts.length > 0 ? parts.join(". ") + "." : "";
    }

    // The other VPNs that may take all traffic (fullTunnel true, or not known), by name:
    // fullTunnelVpns(vpnsUp (Api.vpnsUp's rows), ownProvider (this module's id: its own row
    // left out)) — beside an exit node, "another VPN is also on"
    function fullTunnelVpns(vpnsUp, ownProvider) {
        return _otherVpns(_withoutOwn(vpnsUp, ownProvider)).filter(vpn => vpn.fullTunnel !== false).map(vpn => vpn.name);
    }

    // The other VPNs whose routes overlap the tailnet's ranges or the routes Tailscale carries,
    // by name: overlappingVpns(vpnsUp, ownProvider, routes (traffic().routes; null: the
    // tailnet's ranges only)) — "another VPN is also on", with or without an exit node. A VPN
    // whose routes are not known (null) is not counted here; routes of all of a family (/0, or
    // its halves) are the full tunnel's case, not an overlap.
    function overlappingVpns(vpnsUp, ownProvider, routes) {
        const names = [];
        for (const found of _overlaps(_otherVpns(_withoutOwn(vpnsUp, ownProvider)), routes))
            if (!names.includes(found.name))
                names.push(found.name);
        return names;
    }

    function _withoutOwn(vpnsUp, ownProvider) {
        const own = _string(ownProvider, 64);
        const list = Array.isArray(vpnsUp) ? vpnsUp
            : (vpnsUp !== null && typeof vpnsUp === "object" && typeof vpnsUp.length === "number" ? Array.from(vpnsUp) : []);
        return list.filter(vpn => !(_isObject(vpn) && own !== "" && vpn.provider === own));
    }

    // [{ name, route (the other VPN's, canonical) }]: the first route of each other VPN that
    // overlaps the tailnet's ranges or `routes` (Tailscale's, more than a /1 each)
    function _overlaps(others, routes) {
        const specific = list => list.map(text => Api.address.parseCidr(text)).filter(cidr => cidr !== null && cidr.bits > 1);
        const ours = specific(tailscaleRanges.concat(Array.isArray(routes) ? routes.slice(0, maxTrafficRoutes) : []));
        const found = [];
        for (const vpn of others) {
            const hit = specific(vpn.routes ?? []).find(theirs => ours.some(own => Api.address.overlap(own, theirs)));
            if (hit !== undefined)
                found.push({ name: vpn.name, route: hit.network });
        }
        return found;
    }

    // At most 8 rows { name, fullTunnel, setsDns, routes } of Api.vpnsUp's (true / false / null
    // each; routes a list of at most 256 texts, else null), named. A list handed through an
    // element's context may come as a list-like object rather than an array
    function _otherVpns(rows) {
        const tri = value => value === true || value === false ? value : null;
        const asList = value => Array.isArray(value) ? value
            : (value !== null && typeof value === "object" && typeof value.length === "number" ? Array.from(value) : null);
        const list = asList(rows) ?? [];
        return list.slice(0, 64).filter(row => _isObject(row))
            .map(row => {
                const routes = asList(row.routes);
                return { name: plainText(row.name, 64), fullTunnel: tri(row.fullTunnel), setsDns: tri(row.setsDns),
                         routes: routes === null ? null : routes.slice(0, maxTrafficRoutes).filter(route => typeof route === "string") };
            })
            .filter(row => row.name !== "").slice(0, 8);
    }

    // At most this many routes on the entry, as the shell takes them (Api.vpnsUp's routes:
    // null rather than more than 256)
    readonly property int maxTrafficRoutes: 256

    // What Tailscale does with the traffic while it is up, for the shell's Api.vpnsUp (the
    // provider entry's fullTunnel, setsDns, routes; module API 1.16): traffic(status, prefs,
    // view) → { fullTunnel, setsDns, routes }, each null where it is not known (not running,
    // prefs not read). fullTunnel: an exit node is in use. setsDns: false with Tailscale's DNS
    // not accepted, true with it accepted and MagicDNS on; otherwise null — with MagicDNS off
    // the tailnet may still push nameservers or split DNS, which status does not show. routes:
    // the tailnet's own ranges, the subnet routes of peers while routes are accepted, and all
    // of both families through an exit node; null while the peers are not read whole (none
    // yet, or more than maxPeers) or when there would be more than maxTrafficRoutes.
    function traffic(status, prefs, view) {
        const unknown = { fullTunnel: null, setsDns: null, routes: null };
        if (_get(view, "phase") !== "running" || !_isObject(status) || !_isObject(prefs) || prefs.ok !== true)
            return unknown;
        const exitNode = _get(view, "exitNode") !== null && _get(view, "exitNode") !== undefined;
        let routes = tailscaleRanges.slice();
        if (_get(prefs, "acceptRoutes") === true) {
            if (status.peersRead !== true || status.peersCut === true)
                routes = null;
            for (const node of routes === null ? [] : _peersOf(status)) {
                // A peer's list is read up to 256 (_strings): one that long may have been cut
                if (node.primaryRoutes.length >= 256) {
                    routes = null;
                    break;
                }
                for (const route of node.primaryRoutes) {
                    const cidr = Api.address.parseCidr(route);
                    if (cidr !== null && cidr.bits > 0 && !routes.includes(cidr.network))
                        routes.push(cidr.network);
                }
                if (routes.length > maxTrafficRoutes) {
                    routes = null;
                    break;
                }
            }
        }
        if (exitNode && routes !== null)
            routes.push("0.0.0.0/0", "::/0");
        const acceptDns = _get(prefs, "acceptDns");
        return {
            fullTunnel: exitNode,
            setsDns: acceptDns === false ? false
                : acceptDns === true && status?.tailnet?.magicDnsEnabled === true ? true : null,
            routes: routes !== null && routes.length <= maxTrafficRoutes ? routes : null
        };
    }
}
