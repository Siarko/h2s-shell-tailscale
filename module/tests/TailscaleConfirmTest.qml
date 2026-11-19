import QtQuick
import qs.tests
import ".."

// The six buttons that ask first (Log out, an account's Remove, a share's Remove, Funnel on,
// Stop all, a route's Remove): the first click only asks and runs nothing, the second acts
// through the client. A question is taken back when the button hides (the state changed
// elsewhere while it asked) and when what it acts on changes, so a button shown again
// never acts on one click. The views are built on stand-in clients that record each call.
TestCase {
    id: suite
    suiteName: "tailscale: buttons that ask first"

    // A parent for the views: an item without one counts as hidden once its own `visible`
    // changes (a section's binding does, when its client arrives)
    property Item _holder: Item {}

    property Component _page: Component {
        TailscalePage {
            width: 700
        }
    }
    property Component _serve: Component {
        ServeSection {
            width: 700
            open: true
        }
    }
    property Component _sharing: Component {
        SharingSection {
            width: 700
        }
    }

    function run() {
        logOut();
        accountRemove();
        serveButtons();
        routeRemove();
    }

    // ---- the page: Log out, an account's Remove ----

    function pageClient(calls, options) {
        const loggedIn = options.loggedIn !== false;
        return {
            view: { phase: loggedIn ? "running" : "logged-out", exitNode: null, attention: null }, prefs: { acceptDns: true, operatorUser: "" },
            canChange: true, busy: false, entry: { state: "activated", status: "Tailnet only", attention: null }, authUrl: "", busAuthUrl: "",
            operation: "", elevationProblem: "", userName: "tester", cli: "present", tailscalePath: "/x/tailscale", updateManagedBySystem: false,
            loginTimeoutMs: 600000, _loginElevated: false, status: { version: "1.104.4" }, warnings: [],
            exitNodes: { own: [], countries: [], current: null, suggested: null, count: 0 },
            accounts: options.accounts ?? [{ id: "a1", nickname: "", tailnet: "example.org", account: "one@example.com", selected: true },
                                           { id: "b2", nickname: "", tailnet: "example.net", account: "two@example.com", selected: false }],
            accountsOutdated: false, loginInterrupted: null,
            currentAccount: { loginName: options.loginName ?? "one@example.com", tailnet: "example.org" },
            device: null, sharing: null, sshServer: null, forwardingWarning: null, readForwarding: () => {}, autoUpdateProblem: "",
            diagnostics: { running: false, ranAt: 0, clientVersion: "", netcheck: [], dns: [], errors: [], nearest: null },
            health: [], diagnosticsReport: "", updateNotice: "", devices: [], pings: {},
            watch: () => {}, unwatch: () => {},
            logout: () => calls.push("logout"),
            removeAccount: id => calls.push("remove " + id),
            switchAccount: id => calls.push("switch " + id)
        };
    }

    function pageModule(client) {
        return { main: { client: client }, value: key => undefined, setValue: (key, value) => {} };
    }

    function logOut() {
        const calls = [];
        // The module after the page is made: given to createObject, its lists would arrive as
        // the engine's own lists, not arrays (as in TailscaleUiTest)
        const page = _page.createObject(_holder);
        page.module = pageModule(pageClient(calls, {}));
        const button = named(page, "tailscaleLogout");
        assert(button !== null && shown(button), "Log out is shown while logged in");
        firstAsksSecondActs(button, calls, ["logout"], "Log out");

        // Asked, then logged out elsewhere (the button hides), then logged in again
        click(button);
        assert(button.asking, "Log out asked again");
        page.module = pageModule(pageClient(calls, { loggedIn: false }));
        assertEqual(shown(button), false, "logged out elsewhere: Log out hidden");
        page.module = pageModule(pageClient(calls, {}));
        assert(shown(button), "logged in again: Log out shown");
        assertEqual(button.asking, false, "… not asking: the question was taken back when it hid");
        click(button);
        same(calls, ["logout"], "… so one click only asks again, nothing run");

        // Asked, then another account is in use (switched elsewhere): the question goes
        page.module = pageModule(pageClient(calls, { loginName: "two@example.com" }));
        assertEqual(button.asking, false, "another account in use: Log out no longer asking");
        page.destroy();
    }

    function accountRemove() {
        const calls = [];
        const page = _page.createObject(_holder);
        page.module = pageModule(pageClient(calls, {}));
        const button = named(page, "tailscaleAccountRemove-b2");
        assert(button !== null && shown(button), "Remove is offered on the account not in use");
        assertEqual(shown(named(page, "tailscaleAccountRemove-a1")), false, "… not on the one in use");
        firstAsksSecondActs(button, calls, ["remove b2"], "an account's Remove");

        // Asked, then that account became the one in use elsewhere (Remove hides), then not
        click(button);
        page.module = pageModule(pageClient(calls, { accounts: [{ id: "a1", nickname: "", tailnet: "example.org", account: "one@example.com", selected: false },
                                                                { id: "b2", nickname: "", tailnet: "example.net", account: "two@example.com", selected: true }] }));
        const hidden = named(page, "tailscaleAccountRemove-b2");
        assertEqual(shown(hidden), false, "the account in use now: its Remove hidden");
        page.module = pageModule(pageClient(calls, {}));
        const again = named(page, "tailscaleAccountRemove-b2");
        assertEqual(again?.asking, false, "not in use again: its Remove does not ask yet");
        page.destroy();
    }

    // ---- Serve: Funnel on, a share's Remove, Stop all ----

    function entry(key, port, funnel) {
        return { key: key, type: "https", port: port, mount: "/", host: "laptop.example-tailnet.ts.net", what: "proxy",
                 target: "http://127.0.0.1:3000", complete: true, appCaps: [], funnel: funnel,
                 url: "https://laptop.example-tailnet.ts.net:" + port + "/", urls: ["https://laptop.example-tailnet.ts.net:" + port + "/"] };
    }

    function serveClient(calls, entries) {
        const config = { entries: entries, foreground: 0, services: 0, unlisted: [], foregroundPorts: [], empty: entries.length === 0 };
        return {
            cli: "present", prefs: {}, busy: false, status: null,
            serve: {
                config: config, entries: entries, checking: false, message: "", readError: "", funnelOffNeeded: null,
                ready: { problems: [], funnelProblems: [], connected: true, https: true, canFunnel: true, canServeHttps: true },
                read: () => true,
                setFunnel: (key, on) => calls.push((on ? "funnel on " : "funnel off ") + key),
                remove: key => calls.push("remove " + key),
                reset: () => calls.push("reset")
            }
        };
    }

    function serveButtons() {
        const calls = [];
        const section = _serve.createObject(_holder);
        section.client = serveClient(calls, [entry("https:443:/", 443, false)]);
        const funnelOn = named(section, "tailscaleServeFunnelOn");
        assert(funnelOn !== null && shown(funnelOn), "Funnel on is offered on a private share");
        assertEqual(funnelOn.kind, "warning", "Funnel on is a warning: it goes on, but think");
        firstAsksSecondActs(funnelOn, calls, ["funnel on https:443:/"], "Funnel on");

        // The review's case: asked, Funnel turned on elsewhere (the button hides, the row is
        // the same one), turned off again — the button must ask again, not act on one click
        calls.length = 0;
        click(funnelOn);
        assert(funnelOn.asking, "Funnel on asked");
        section.client = serveClient(calls, [entry("https:443:/", 443, true)]);
        assertEqual(shown(funnelOn), false, "Funnel on elsewhere: the button hidden (the same row)");
        section.client = serveClient(calls, [entry("https:443:/", 443, false)]);
        assert(shown(funnelOn), "Funnel off elsewhere: the button shown again");
        assertEqual(funnelOn.asking, false, "… not asking");
        click(funnelOn);
        same(calls, [], "… one click only asks, Funnel not turned on");
        section.client = serveClient(calls, [entry("https:443:/", 443, false)]);
        funnelOn.asking = false;

        const remove = named(section, "tailscaleServeRemove");
        assert(remove !== null && shown(remove), "a share's Remove is shown");
        firstAsksSecondActs(remove, calls, ["remove https:443:/"], "a share's Remove");

        const stopAll = named(section, "tailscaleServeStopAll");
        assert(stopAll !== null && shown(stopAll), "Stop all is shown");
        calls.length = 0;
        firstAsksSecondActs(stopAll, calls, ["reset"], "Stop all");

        // Stop all asked, then a share added elsewhere: another set to stop, asked again
        click(stopAll);
        section.client = serveClient(calls, [entry("https:443:/", 443, false), entry("https:8443:/", 8443, false)]);
        assertEqual(stopAll.asking, false, "one more share: Stop all asks again");
        section.destroy();
    }

    // ---- Sharing: a route's Remove ----

    function sharingClient(calls, routes) {
        return {
            busy: false, canChange: true, prefs: { advertiseRoutes: routes.map(route => route.route) }, forwardingWarning: null,
            sharing: { known: true, connected: true, exitNode: { offered: false, state: "", text: "", problem: "" }, routes: routes,
                       offersAny: routes.length > 0, families: [4], pendingCount: 0, adminUrl: "", tagsRequested: [], tagsApplied: [],
                       connector: false, snat: true, statefulFiltering: null, netfilterMode: "on", relayServerPort: null, webClient: false,
                       webClientUrl: "", postureChecking: false, autoUpdate: null, updateCheck: true },
            readForwarding: () => {}, autoUpdateProblem: "",
            removeRoute: route => calls.push("remove " + route)
        };
    }

    function routeRemove() {
        const calls = [];
        const section = _sharing.createObject(_holder);
        const route = { route: "192.168.7.0/24", family: 4, state: "approved", text: "approved" };
        section.client = sharingClient(calls, [route]);
        const button = named(section, "tailscaleRouteRemove");
        assert(button !== null && shown(button), "a route's Remove is shown");
        firstAsksSecondActs(button, calls, ["remove 192.168.7.0/24"], "a route's Remove");

        // Asked, then the section hidden around it (the user's view changed): taken back
        click(button);
        section.visible = false;
        section.visible = true;
        assertEqual(button.asking, false, "hidden around it: a route's Remove no longer asking");
        section.destroy();
    }

    // ---- helpers ----

    // The first click asks and runs nothing; the second runs `expected` once
    function firstAsksSecondActs(button, calls, expected, what) {
        const before = calls.slice();
        assertEqual(button.asking, false, what + ": not asking before a click");
        click(button);
        assert(button.asking, what + ": the first click asks");
        same(calls, before, what + ": … and runs nothing");
        click(button);
        same(calls, before.concat(expected), what + ": the second click acts, once");
        assertEqual(button.asking, false, what + ": … and the question is gone");
    }

    // A click on the button's own face (the first pointer area inside it: the "×" comes after)
    function click(button) {
        const area = firstArea(button);
        assert(area !== null, "a pointer area inside " + button.objectName);
        area?.clicked(null);
    }

    function firstArea(item) {
        if (!item)
            return null;
        if (item instanceof MouseArea)
            return item;
        for (const child of item.children ?? []) {
            const found = firstArea(child);
            if (found)
                return found;
        }
        return null;
    }

    function named(item, name) {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (const child of item.children ?? []) {
            const found = named(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function shown(item) {
        for (let node = item; node; node = node.parent)
            if (node.visible === false)
                return false;
        return item !== null;
    }

    function same(actual, expected, message) {
        assertEqual(JSON.stringify(actual), JSON.stringify(expected), message);
    }
}
