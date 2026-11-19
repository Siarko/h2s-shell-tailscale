pragma Singleton

import QtQuick
import Quickshell

// Serve and Funnel (delivery step 5), pure: the serve config as the daemon holds it
// (`tailscale serve status --json`, ipn.ServeConfig), what the page lists, what is missing
// before anything can be shared, and the argv of each change. Everything from tailscale
// 1.104.4's source:
//   - reading the config: LocalAPI GET serve-config needs read access only (ipn/localapi/serve.go
//     PermitRead) — any user; observed: `serve status --json` prints `{}` with nothing served;
//   - changing it: POST serve-config needs write access (root or the operator: 403 "serve config
//     denied" otherwise); a config holding a Path handler or a unix socket needs a local admin —
//     root, or the operator able to `sudo tailscale` (authorizeServeConfigForGOOSAndUserContext);
//   - the CLI reads the config, changes one handler and writes it back with the ETag it read
//     ("Another client is changing the serve config; please try again."), so one command never
//     drops another's entry. `serve` sets a handler and turns Funnel OFF for its host:port,
//     `funnel` sets it and turns Funnel ON (cli/serve_v2.go setServe → applyFunnel); "off"
//     removes a handler (the port's Funnel goes with its last mount: RemoveWebHandler);
//   - files and folders are served by tailscaled itself — root — at request time, following
//     links (ipnlocal serveFileOrDirectory: os.Stat/os.Open, http.Dir): a path the user chose
//     would be read by root long after any check. So the module never ADDS a path; existing
//     ones are listed and may be removed (removing reads nothing);
//   - `serve` with HTTPS on a node without the "https" capability enters an interactive flow
//     that prints a link and may wait (enableFeatureInteractive): the module checks the
//     capability first and never sends it then;
//   - Funnel needs the "https" and "funnel" node capabilities (ipn.NodeCanFunnel) and a port the
//     funnel-ports capability lists ("https://tailscale.com/cap/funnel-ports?ports=443,8443,10000",
//     ipn.CheckFunnelPort; the CLI only checks 443 itself — the module checks the real port);
//     the daemon refuses Funnel while shields-up is on (ipnlocal setServeConfigLocked).
Singleton {
    id: root

    readonly property string adminDnsUrl: "https://login.tailscale.com/admin/dns"
    readonly property string adminAclsUrl: "https://login.tailscale.com/admin/acls"
    readonly property string httpsCapability: "https"
    readonly property string funnelCapability: "funnel"
    readonly property string funnelPortsCapability: "https://tailscale.com/cap/funnel-ports"
    // Ports offered for HTTPS (Funnel's usual ones, so Funnel can be turned on later)
    readonly property var httpsPorts: [443, 8443, 10000]
    readonly property int maxEntries: 64

    function _isObject(value) {
        return value !== null && typeof value === "object" && !Array.isArray(value);
    }

    function _own(object, key) {
        return _isObject(object) && Object.prototype.hasOwnProperty.call(object, key) ? object[key] : undefined;
    }

    function _text(value, length) {
        return typeof value === "string" ? value.slice(0, length ?? 1024) : "";
    }

    function _port(value) {
        const number = typeof value === "number" ? value : (typeof value === "string" && /^\d{1,5}$/.test(value) ? Number(value) : NaN);
        return Number.isInteger(number) && number >= 1 && number <= 65535 ? number : 0;
    }

    // "host:port" (a HostPort; an IPv6 host in brackets) → { host, port } | null
    function _hostPort(text) {
        const match = /^(.*):(\d{1,5})$/.exec(String(text));
        if (!match || _port(match[2]) === 0)
            return null;
        return { host: match[1].replace(/^\[|\]$/g, ""), port: Number(match[2]) };
    }

    // The link a listener gives (no default port in it)
    function urlFor(scheme, host, port, mount) {
        const shown = (scheme === "https" && port === 443) || (scheme === "http" && port === 80) ? "" : ":" + port;
        return scheme + "://" + host + shown + (mount || "/");
    }

    // A handler → { what: "proxy" | "text" | "path" | "unix" | "redirect" | "unknown", target,
    // complete (the target kept whole: never sent again cut short), appCaps (it forwards app
    // capabilities: sending the target again would drop them) }
    function _handler(raw) {
        const appCaps = Array.isArray(_own(raw, "AcceptAppCaps")) && _own(raw, "AcceptAppCaps").length > 0;
        const make = (what, key, length) => {
            const full = _text(_own(raw, key), Infinity);
            return { what: what, target: full.slice(0, length), complete: full.length <= length, appCaps: appCaps };
        };
        if (_text(_own(raw, "Proxy")) !== "")
            return make(/^unix:/.test(_own(raw, "Proxy")) ? "unix" : "proxy", "Proxy", 300);
        if (_text(_own(raw, "Path")) !== "")
            return make("path", "Path", 300);
        if (_text(_own(raw, "Text")) !== "")
            return make("text", "Text", 2000);
        if (_text(_own(raw, "Redirect")) !== "")
            return make("redirect", "Redirect", 300);
        return { what: "unknown", target: "", complete: false, appCaps: appCaps };
    }

    // `serve status --json` (text or object) → { ok, error, empty, entries, funnelOn, funnelHosts,
    // unlisted, foregroundPorts, servicePorts, services, foreground }. An entry: { key, type
    // ("https" | "http" | "tcp" | "tls-terminated-tcp"), port, mount ("" for TCP), host, what
    // (above, "tcp" for a forwarder), target, complete, appCaps, funnel, url, urls }. Only the
    // node's own background listeners are entries; `services` and `foreground` count what is shown
    // but not managed here (Tailscale Services, `serve` running in a terminal). `funnelHosts`: the
    // host:ports with Funnel on ({ host, port }). `unlisted`: ports holding a handler that is not an
    // entry (malformed, past maxEntries, or a terminal session's) — Funnel is per host:port, so a
    // port with something unseen is never made public. `foregroundPorts`: the ports of terminal
    // sessions (Foreground[*] TCP and Web): they sit on this device's own name and port and the
    // daemon looks them up first (ServeConfigView.FindTCP / FindWeb), so a Funnel on such a port
    // would publish the terminal's handler; tailscaled also refuses a background listener there
    // ("foreground listener already exists"). `servicePorts`: the ports of Tailscale Services
    // (Services[*] TCP and Web): they listen on the service's own address and name, which Funnel
    // does not reach, but the module does not make such a port public either. Unknown fields are
    // ignored; anything not an object is not ok.
    function parseConfig(input) {
        const result = { ok: false, error: "", empty: true, entries: [], funnelOn: false, funnelHosts: [], unlisted: [], foregroundPorts: [], servicePorts: [],
                         services: 0, foreground: 0 };
        let raw = input;
        if (typeof input === "string") {
            try {
                raw = JSON.parse(input.trim() === "" || input.trim() === "null" ? "{}" : input);
            } catch (error) {
                result.error = "not JSON";
                return result;
            }
        }
        if (raw === null)
            raw = {};
        if (!_isObject(raw)) {
            result.error = "not an object";
            return result;
        }
        result.ok = true;
        const tcp = _isObject(_own(raw, "TCP")) ? _own(raw, "TCP") : {};
        const web = _isObject(_own(raw, "Web")) ? _own(raw, "Web") : {};
        const services = _isObject(_own(raw, "Services")) ? _own(raw, "Services") : {};
        const foreground = _isObject(_own(raw, "Foreground")) ? _own(raw, "Foreground") : {};
        result.services = Object.keys(services).length;
        result.foreground = Object.keys(foreground).length;
        result.foregroundPorts = _portsOf(foreground);
        result.servicePorts = _portsOf(services);
        // The host:ports with Funnel on: the top-level AllowFunnel and every terminal session's
        // own, as tailscaled honours both (ServeConfigView.HasFunnelForTarget)
        const funnelKeys = [];
        const addFunnel = map => {
            for (const key of Object.keys(_isObject(map) ? map : {}))
                if (map[key] === true && !funnelKeys.includes(key))
                    funnelKeys.push(key);
        };
        addFunnel(_own(raw, "AllowFunnel"));
        for (const session of Object.keys(foreground))
            addFunnel(_own(_own(foreground, session), "AllowFunnel"));
        const funnelFor = (host, port) => funnelKeys.some(key => {
            const parsed = _hostPort(key);
            return parsed !== null && parsed.port === port && (host === "" || parsed.host === host);
        });
        const entries = [];
        for (const portKey of Object.keys(tcp).sort((a, b) => Number(a) - Number(b))) {
            const port = _port(portKey);
            const handler = _own(tcp, portKey);
            if (port === 0 || !_isObject(handler))
                continue;
            const forward = _text(_own(handler, "TCPForward"), 300);
            if (forward === "")
                continue;
            const terminated = _text(_own(handler, "TerminateTLS"), 300) !== "";
            entries.push({ key: (terminated ? "tls-terminated-tcp" : "tcp") + ":" + port, type: terminated ? "tls-terminated-tcp" : "tcp",
                           port: port, mount: "", host: "", what: "tcp", target: forward, complete: true, appCaps: false,
                           funnel: funnelFor("", port), url: "", urls: [] });
        }
        const unlisted = [];
        for (const hostKey of Object.keys(web).sort()) {
            const parsed = _hostPort(hostKey);
            const server = _own(web, hostKey);
            const handlers = _isObject(_own(server, "Handlers")) ? _own(server, "Handlers") : {};
            if (parsed === null)
                continue;
            const listener = _own(tcp, String(parsed.port));
            const type = _own(listener, "HTTP") === true ? "http" : "https";
            for (const mount of Object.keys(handlers).sort()) {
                if (!_isObject(_own(handlers, mount)) || !mount.startsWith("/")) {
                    unlisted.push(parsed.port);
                    continue;
                }
                const handler = _handler(_own(handlers, mount));
                const url = urlFor(type, parsed.host, parsed.port, mount);
                // The same port and mount under another (older) name of this device: the key
                // names the host too, so the two stay apart
                let key = type + ":" + parsed.port + ":" + mount;
                if (entries.some(entry => entry.key === key))
                    key += "@" + parsed.host;
                entries.push({ key: key, type: type, port: parsed.port, mount: mount.slice(0, 300),
                               host: parsed.host, what: handler.what, target: handler.target, complete: handler.complete && mount.length <= 300,
                               appCaps: handler.appCaps, funnel: funnelFor(parsed.host, parsed.port), url: url, urls: [url] });
            }
        }
        // TCP forwarders' addresses: host:port, filled in by entriesFor (they need status)
        result.entries = entries.slice(0, maxEntries);
        result.unlisted = [...new Set(unlisted.concat(entries.slice(maxEntries).map(entry => entry.port), result.foregroundPorts))];
        result.empty = entries.length === 0 && unlisted.length === 0 && result.services === 0 && result.foreground === 0;
        result.funnelOn = funnelKeys.length > 0;
        result.funnelHosts = funnelKeys.map(key => _hostPort(key)).filter(hostPort => hostPort !== null);
        return result;
    }

    // Every port a map of nested serve configs listens on (Foreground's sessions, Services): the
    // keys of each one's TCP and the ports of its Web host:ports, whatever their handlers hold (a
    // malformed one counts too). Sorted, each once
    function _portsOf(configs) {
        const ports = [];
        for (const name of Object.keys(configs)) {
            const config = _own(configs, name);
            const tcp = _isObject(_own(config, "TCP")) ? _own(config, "TCP") : {};
            const web = _isObject(_own(config, "Web")) ? _own(config, "Web") : {};
            for (const portKey of Object.keys(tcp))
                ports.push(_port(portKey));
            for (const hostKey of Object.keys(web))
                ports.push(_hostPort(hostKey)?.port ?? 0);
        }
        return [...new Set(ports.filter(port => port > 0))].sort((a, b) => a - b);
    }

    // The entries with what status adds: a TCP forwarder's names to copy (MagicDNS name and the
    // Tailscale addresses, with the port)
    function entriesFor(config, status) {
        const self = status?.self ?? null;
        const host = String(self?.dnsName ?? "");
        const addresses = (self?.addresses ?? []).map(address => address.includes(":") ? "[" + address + "]" : address);
        return (config?.entries ?? []).map(entry => entry.what !== "tcp" ? entry
            : Object.assign({}, entry, { urls: [host].concat(addresses).filter(name => name !== "").map(name => name + ":" + entry.port) }));
    }

    // The funnel-ports capability's ports → [numbers] (ranges expanded, at most 64), [] none
    function funnelPorts(caps) {
        for (const cap of (Array.isArray(caps) ? caps : [])) {
            const text = String(cap);
            if (!text.startsWith(funnelPortsCapability + "?"))
                continue;
            const match = /[?&]ports=([0-9,\-]*)/.exec(text);
            const ports = [];
            for (const part of (match ? match[1] : "").split(",")) {
                const range = /^(\d{1,5})(?:-(\d{1,5}))?$/.exec(part);
                if (!range)
                    continue;
                const first = _port(range[1]);
                const last = range[2] ? _port(range[2]) : first;
                for (let port = first; first > 0 && port <= last && ports.length < 64; port++)
                    if (!ports.includes(port))
                        ports.push(port);
            }
            return ports;
        }
        return [];
    }

    // What sharing needs (status and prefs as TailscaleRules parses them) → { connected, https,
    // magicDns, funnelAllowed, funnelPorts, shieldsUp, canServeHttps, canFunnel, problems
    // [{ kind, text, url }], funnelProblems [same] }. Unknown (no status): not connected.
    function preconditions(status, prefs) {
        const caps = status?.self?.caps ?? [];
        const connected = status?.backendState === "Running";
        const https = caps.includes(httpsCapability);
        const magicDns = status?.tailnet?.magicDnsEnabled === true;
        const funnelAllowed = caps.includes(funnelCapability);
        const ports = funnelPorts(caps);
        const shieldsUp = prefs?.shieldsUp === true;
        const problems = [];
        if (!connected)
            problems.push({ kind: "not-connected", text: "Connect to share", url: "" });
        if (connected && !magicDns)
            problems.push({ kind: "magic-dns", text: "MagicDNS is off for this tailnet", url: adminDnsUrl });
        if (connected && !https)
            problems.push({ kind: "https", text: "HTTPS certificates are off for this tailnet", url: adminDnsUrl });
        const funnelProblems = [];
        if (connected && https && !funnelAllowed)
            funnelProblems.push({ kind: "funnel", text: "Funnel is not allowed for this device", url: adminAclsUrl });
        if (connected && shieldsUp)
            funnelProblems.push({ kind: "shields-up", text: "Shields up is on", url: "" });
        return {
            connected: connected, https: https, magicDns: magicDns, funnelAllowed: funnelAllowed, funnelPorts: ports, shieldsUp: shieldsUp,
            canServeHttps: connected && https && magicDns, canFunnel: connected && https && magicDns && funnelAllowed && !shieldsUp,
            problems: problems, funnelProblems: funnelProblems
        };
    }

    // A local port typed by the user → 1–65535 or 0
    function localPort(text) {
        return _port(typeof text === "string" ? text.trim() : text);
    }

    // A path prefix typed by the user ("" or "/" the root) → { ok, mount, error }: letters,
    // digits and . _ ~ - / only, no "..", no "//", as cleanURLPath would keep it
    function mountFor(text) {
        let value = String(text ?? "").trim();
        if (value === "" || value === "/")
            return { ok: true, mount: "/", error: "" };
        if (!value.startsWith("/"))
            value = "/" + value;
        if (value.length > 200 || !/^[A-Za-z0-9._~\/-]+$/.test(value) || value.includes("//") || value.split("/").some(part => part === "." || part === ".."))
            return { ok: false, mount: "", error: "Not a usable path" };
        return { ok: true, mount: value, error: "" };
    }

    // A proxy target the module itself would send again: a local http(s) URL with a port
    function _resendable(target) {
        return /^(https?|https\+insecure):\/\/(127\.0\.0\.1|localhost|\[::1\]):\d{1,5}(\/[A-Za-z0-9._~\/-]*)?$/.test(target);
    }

    function _plan(kind, extra) {
        return Object.assign({ kind: kind, error: "", argv: [], description: "", what: "", publicPort: 0 }, extra ?? {});
    }

    // This device's current DNS name, lower case ("" unknown): the host the CLI puts every
    // handler under (TailscaleRules.parseStatus drops the trailing dot)
    function _selfHost(status) {
        return String(status?.self?.dnsName ?? "").toLowerCase();
    }

    // Whether a web entry is under this device's current name (the one the CLI would change):
    // an entry under an old name is left to a terminal
    function _ownHost(entry, status) {
        const self = _selfHost(status);
        return self !== "" && String(entry?.host ?? "").toLowerCase() === self;
    }

    // What the module would send again for an entry, exactly as it is ("" it cannot): a local
    // proxy URL or a text, kept whole, under this device's name, forwarding no app capabilities.
    // A path, a unix socket, a redirect, a remote proxy are never sent again
    function _resendTarget(entry, status) {
        if (!entry || entry.type !== "https" || !_ownHost(entry, status) || entry.appCaps === true || entry.complete !== true)
            return "";
        if (entry.what === "proxy" && _resendable(entry.target))
            return entry.target;
        if (entry.what === "text" && entry.target !== "" && !/[\u0000]/.test(entry.target))
            return "text:" + entry.target;
        return "";
    }

    // Funnel is per host:PORT (AllowFunnel), not per entry: turning it on publishes every mount
    // on that port, and a retry through pkexec would do it as root. So a port is made public only
    // when everything on it is a module-style local proxy or text under this device's name —
    // never a path (tailscaled serves those files as root), a unix socket, anything unseen, a
    // terminal session's or a service's port.
    // → "" or why not
    function publicProblem(config, port, status) {
        if ((config?.unlisted ?? []).includes(port) || (config?.foregroundPorts ?? []).includes(port) || (config?.servicePorts ?? []).includes(port))
            return "Change this one in a terminal";
        if ((config?.entries ?? []).some(entry => entry.port === port && _resendTarget(entry, status) === ""))
            return "Change this one in a terminal";
        return "";
    }

    // Whether Funnel is on for `port` under this device's name
    function portPublic(config, port, status) {
        const self = _selfHost(status);
        return (config?.entries ?? []).some(entry => entry.port === port && entry.funnel && (entry.host === "" || _ownHost(entry, status)))
            || (config?.funnelHosts ?? []).some(hostPort => hostPort.port === port && self !== "" && hostPort.host.toLowerCase() === self);
    }

    // Whether a share added now would be public: the Funnel box checked, or the port is public
    // already (the add form shows it)
    function addIsPublic(config, port, funnelChecked, status) {
        return funnelChecked === true || portPublic(config, _port(port), status);
    }

    // How many other shares on an entry's port become public with it (Funnel is per port)
    function alsoPublic(config, entry) {
        return (config?.entries ?? []).filter(item => entry && item.key !== entry.key && item.port === entry.port && item.type === "https"
                                                     && String(item.host).toLowerCase() === String(entry.host).toLowerCase() && !item.funnel).length;
    }

    // The question of the two-step "Funnel on"
    function funnelQuestion(config, entry) {
        const others = alsoPublic(config, entry);
        return others > 0 ? "Public, with " + others + " more?" : "Public?";
    }

    // The question of "Stop all": `serve reset` empties the whole config, what this page does not
    // list (terminal sessions, services) and files included — said, so nothing stops unseen
    function resetQuestion(config) {
        const also = [];
        if ((config?.entries ?? []).some(entry => entry.what === "path"))
            also.push("files");
        if ((config?.foreground ?? 0) > 0)
            also.push("terminal shares");
        if ((config?.services ?? 0) > 0)
            also.push("services");
        return also.length > 0 ? "Stop all, " + also.join(", ").replace(/, (?=[^,]*$)/, " and ") + " too?" : "Stop all?";
    }

    // Adding one share, planned from the config as read now: addPlan(config, intent, status,
    // prefs) → { kind: "run" | "refused", error, argv, description }. intent { kind: "proxy",
    // port (HTTPS listener), localPort, path, funnel } or { kind: "tcp", port, localPort }.
    // A web handler goes on with `funnel` when Funnel is asked or already on for that port (so
    // adding a path never turns a port's Funnel off), else `serve`. Public (either way): only on a
    // port publicProblem allows.
    function addPlan(config, intent, status, prefs) {
        const ready = preconditions(status, prefs);
        const local = localPort(intent?.localPort);
        const port = _port(intent?.port);
        if (config?.ok !== true)
            return _plan("refused", { error: "What is shared is not read yet" });
        if (!ready.connected)
            return _plan("refused", { error: "Connect to share" });
        if (local === 0)
            return _plan("refused", { error: "Enter a local port" });
        if (port === 0)
            return _plan("refused", { error: "Choose a port" });
        const entries = config.entries ?? [];
        if (intent?.kind === "tcp") {
            if (entries.some(entry => entry.port === port) || (config.unlisted ?? []).includes(port) || (config.foregroundPorts ?? []).includes(port))
                return _plan("refused", { error: "Port " + port + " is in use" });
            return _plan("run", { argv: ["tailscale", "serve", "--bg", "--yes", "--tcp=" + port, "tcp://127.0.0.1:" + local],
                                  description: "Sharing a local port with the tailnet", what: "Share a port" });
        }
        if (intent?.kind !== "proxy")
            return _plan("refused", { error: "Nothing to add" });
        if (!ready.canServeHttps)
            return _plan("refused", { error: ready.problems[0]?.text ?? "HTTPS is not available" });
        const mount = mountFor(intent?.path);
        if (!mount.ok)
            return _plan("refused", { error: mount.error });
        // A terminal session's port: tailscaled refuses a background listener there
        if (entries.some(entry => entry.port === port && (entry.what === "tcp" || entry.type === "http")) || (config.foregroundPorts ?? []).includes(port))
            return _plan("refused", { error: "Port " + port + " is in use" });
        if (entries.some(entry => entry.port === port && entry.mount === mount.mount))
            return _plan("refused", { error: "Already shared" });
        const funnel = addIsPublic(config, port, intent?.funnel, status);
        if (funnel) {
            const problem = funnelProblem(ready, port) || publicProblem(config, port, status);
            if (problem !== "")
                return _plan("refused", { error: problem });
        }
        return _plan("run", {
            argv: ["tailscale", funnel ? "funnel" : "serve", "--bg", "--yes", "--https=" + port].concat(mount.mount === "/" ? [] : ["--set-path=" + mount.mount],
                ["http://127.0.0.1:" + local]),
            description: funnel ? "Sharing a local port on the internet" : "Sharing a local port with the tailnet",
            what: funnel ? "Share a port on the internet" : "Share a port",
            publicPort: funnel ? port : 0
        });
    }

    // Why Funnel cannot be turned on for `port` ("" it can)
    function funnelProblem(ready, port) {
        if (!ready.canFunnel)
            return ready.funnelProblems[0]?.text ?? ready.problems[0]?.text ?? "Funnel is not available";
        if (!ready.funnelPorts.includes(port))
            return "Funnel works on port " + (ready.funnelPorts.length > 0 ? ready.funnelPorts.join(", ") : "443, 8443 or 10000") + " only";
        return "";
    }

    // Removing one entry (by key) → plan. Always `serve … off` (never `funnel … off`: that would
    // first run Funnel's capability check, and the result is the same); --set-path names the
    // one mount, --yes so a port with several mounts never waits for a question. A web entry
    // under another (old) name of this device is left to a terminal: the CLI would act on the
    // current name's handler instead
    function removePlan(config, key, status) {
        const entry = (config?.entries ?? []).find(item => item.key === key) ?? null;
        if (config?.ok !== true || entry === null)
            return _plan("refused", { error: "Not shared any more" });
        if (entry.what === "tcp")
            return _plan("run", { argv: ["tailscale", "serve", "--bg", "--yes", "--" + entry.type + "=" + entry.port, "off"], description: "Stopping a share",
                                  what: "Stop a share" });
        if (!_ownHost(entry, status) || entry.mount.length >= 300)
            return _plan("refused", { error: "Change this one in a terminal" });
        return _plan("run", { argv: ["tailscale", "serve", "--bg", "--yes", "--" + entry.type + "=" + entry.port, "--set-path=" + entry.mount, "off"],
                              description: "Stopping a share", what: "Stop a share" });
    }

    // Funnel on or off for an entry's port → plan: the entry's handler set again, with `funnel`
    // (on) or `serve` (off) — the only way the CLI turns Funnel off without removing the handler.
    // Only for entries the module could send again exactly (_resendTarget). On: every other entry
    // on the port goes public too, so publicProblem must allow the port. Off: `serve` with HTTPS
    // needs the "https" capability (else the CLI's interactive enable flow) — without it only
    // Remove is offered
    function funnelPlan(config, key, on, status, prefs) {
        const entry = (config?.entries ?? []).find(item => item.key === key) ?? null;
        if (config?.ok !== true || entry === null)
            return _plan("refused", { error: "Not shared any more" });
        if (entry.type !== "https")
            return _plan("refused", { error: "Funnel needs HTTPS" });
        if (!_ownHost(entry, status))
            return _plan("refused", { error: "Change this one in a terminal" });
        if (entry.funnel === (on === true))
            return _plan("nothing");
        const target = _resendTarget(entry, status);
        if (target === "")
            return _plan("refused", { error: "Change this one in a terminal" });
        const ready = preconditions(status, prefs);
        if (on === true) {
            const problem = funnelProblem(ready, entry.port) || publicProblem(config, entry.port, status);
            if (problem !== "")
                return _plan("refused", { error: problem });
        } else if (!ready.canServeHttps) {
            return _plan("refused", { error: ready.problems[0]?.text ?? "HTTPS is not available" });
        }
        return _plan("run", {
            argv: ["tailscale", on === true ? "funnel" : "serve", "--bg", "--yes", "--https=" + entry.port].concat(entry.mount === "/" ? [] : ["--set-path=" + entry.mount], [target]),
            description: on === true ? "Putting a share on the internet" : "Taking a share off the internet",
            what: on === true ? "Turn on Funnel" : "Turn off Funnel",
            publicPort: on === true ? entry.port : 0
        });
    }

    // After Funnel went on for `port`: the plan was made on an earlier read, and the CLI does its
    // own read-modify-write later (through pkexec: after the password dialog), so a handler added
    // on that port in between went public with it. Checked on the config read after the change →
    // { kind: "nothing" (not public, or still only what publicProblem allows) | "run" (Funnel off
    // again: a module-style entry on the port sent again with `serve`, which turns Funnel off for
    // the whole host:port) | "refused" (no entry the module could send again: error) }
    function publicCheck(config, port, status, prefs) {
        if (config?.ok !== true)
            return _plan("refused", { error: funnelNotice("unchecked", port) });
        if (!portPublic(config, port, status) || publicProblem(config, port, status) === "")
            return _plan("nothing");
        const entry = (config.entries ?? []).find(item => item.port === port && _resendTarget(item, status) !== "") ?? null;
        if (entry === null || !preconditions(status, prefs).canServeHttps)
            return _plan("refused", { error: funnelNotice("public", port) });
        return _plan("run", {
            argv: ["tailscale", "serve", "--bg", "--yes", "--https=" + port].concat(entry.mount === "/" ? [] : ["--set-path=" + entry.mount], [_resendTarget(entry, status)]),
            description: "Taking a share off the internet", what: "Turn off Funnel"
        });
    }

    // The title of what the check after a Funnel tells
    readonly property string funnelNoticeTitle: "Funnel"

    // What the check after a Funnel tells, naming the port: "off" (turned off again),
    // "failed" (turning it off failed), "unchecked" (the config could not be read), "public"
    // (still public, nothing the module could send to turn it off)
    function funnelNotice(kind, port) {
        switch (kind) {
        case "off":
            return "Funnel off. Something else is on port " + port + ".";
        case "failed":
            return "Couldn't turn Funnel off on port " + port + ".";
        case "unchecked":
            return "Couldn't check port " + port + ". Funnel may still be on.";
        default:
            return "Port " + port + " is public. Turn Funnel off in a terminal.";
        }
    }

    // Everything off: `serve reset` (empties the whole config, Funnel included)
    function resetPlan() {
        return _plan("run", { argv: ["tailscale", "serve", "reset"], description: "Stopping every share", what: "Stop every share" });
    }

    // An intent ({ action: "add" | "remove" | "funnel" | "reset", … }) planned against a config
    // read now (null: not read; not ok: the read failed — nothing but reset is planned on it);
    // `identity` (TailscaleRules.prefsIdentity at the click) against `freshIdentity`: another
    // profile → "changed"
    function planIntent(intent, config, status, prefs, identity, freshIdentity) {
        if (identity !== "" && freshIdentity !== identity)
            return _plan("changed", { error: "Changed meanwhile" });
        if (intent?.action !== "reset" && config?.ok !== true)
            return _plan("refused", { error: config ? "What is shared could not be read" : "What is shared is not read yet" });
        switch (intent?.action) {
        case "add":
            return addPlan(config, intent, status, prefs);
        case "remove":
            return removePlan(config, intent.key, status);
        case "funnel":
            return funnelPlan(config, intent.key, intent.on, status, prefs);
        case "reset":
            return resetPlan();
        default:
            return _plan("refused", { error: "Nothing to do" });
        }
    }

    // The label of what an entry serves, plain
    function targetLabel(entry) {
        if (!entry)
            return "";
        if (entry.what === "proxy")
            return entry.target.replace(/^http:\/\/127\.0\.0\.1:(\d+)$/, "port $1");
        if (entry.what === "tcp")
            return entry.target.replace(/^127\.0\.0\.1:(\d+)$/, "port $1");
        if (entry.what === "text")
            return "text";
        if (entry.what === "path")
            return entry.target;
        if (entry.what === "redirect")
            return "redirect";
        if (entry.what === "unix")
            return "socket";
        return "unknown";
    }
}
