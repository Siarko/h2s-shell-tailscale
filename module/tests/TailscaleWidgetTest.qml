import QtQuick
import qs.api
import qs.tests
import ".."

// The bar widget and its popup (step 6): TailscaleWidgetRules — the icon's state for every
// phase, the text beside it, the Taildrop badge, the popup's devices (online
// first, capped), who may send — then the popup and the widget built with plain clients: a
// state for no client, a missing daemon, logged out, connected; crafted tailnet names shown
// as plain text; the buttons each state offers; Taildrop's choices through the chooser (a
// recording handle: the page's files and folder, the popup's, late answers dropped).
TestCase {
    id: suite
    suiteName: "tailscale: the bar widget and its popup"

    readonly property var rules: TailscaleWidgetRules
    readonly property string crafted: "<b>x</b><img src=\"http://example.invalid/\">"

    property Component _popup: Component {
        TailscalePopup {
            width: 320
        }
    }
    property Component _widget: Component {
        TailscaleWidget {}
    }
    property Component _settings: Component {
        TailscaleWidgetSettings {
            width: 400
        }
    }
    property Component _section: Component {
        TaildropSection {
            width: 600
        }
    }
    property Component _taildrop: Component {
        TaildropClient {}
    }
    property Component _chips: Component {
        CopyChips {
            width: 200
        }
    }
    // A client with what TaildropClient and its section read (a QtObject: Connections need one)
    function fakeClient(operator) {
        return Qt.createQmlObject("import QtQuick\nQtObject { property bool running: false; property string cli: \"present\"; "
            + "property bool canChange: " + operator + "; property string curlPath: \"\"; property bool busy: false; property string operation: \"\"; "
            + "property bool streamUp: false; property var module: null; property var taildrop: null; property string userName: \"tester\"; property var view: ({ phase: \"running\" }); "
            + "property var devices: [{ id: \"p1\", name: \"peer\", online: true, canReceiveFiles: true, ipv4: \"100.64.0.9\", addresses: [\"100.64.0.9\"], fileSharingNote: \"\" }, "
            + "{ id: \"p2\", name: \"other\", online: true, canReceiveFiles: true, ipv4: \"100.64.0.10\", addresses: [\"100.64.0.10\"], fileSharingNote: \"\" }] }",
            suite, "fakeClient");
    }

    function client(phase, state, extra) {
        return Object.assign({
            cli: "present", busy: false, canChange: false, authUrl: "", pendingAttention: null,
            view: { phase: phase, exitNode: null, attention: null },
            entry: { state: state, status: "", attention: null },
            currentAccount: { loginName: "", tailnet: "" }, device: null, devices: [],
            exitNodes: { own: [], countries: [], current: null, suggested: null, count: 0 },
            taildrop: { waitingCount: -1, busWaiting: false, statusText: "", isOperator: false, canSave: false, saved: [], saveError: "" }
        }, extra ?? {});
    }

    function attention(kind, action) {
        return { phase: "logged-out", exitNode: null, attention: { kind: kind, reason: "why", action: action } };
    }

    // Every Text under `item` that is visible (with its parents) and holds `needle`
    function shownTexts(item, needle) {
        const found = [];
        const walk = (node, shown) => {
            if (!node)
                return;
            const visible = shown && node.visible !== false;
            if (visible && node instanceof Text && String(node.text).indexOf(needle) >= 0)
                found.push(node);
            for (const child of node.children ?? [])
                walk(child, visible);
        };
        walk(item, true);
        return found;
    }

    function find(item, name) {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (const child of item.children ?? []) {
            const hit = find(child, name);
            if (hit)
                return hit;
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

    function run() {
        // --- the icon's state ---
        const kind = value => rules.summaryOf(value).kind;
        const tone = value => rules.summaryOf(value).tone;
        assertEqual(kind(null), "absent", "no client (the module's main not there): absent");
        assertEqual(tone(null), "disabled", "… dim");
        assertEqual(kind(client("missing", "", { cli: "missing" })), "missing", "not installed");
        assertEqual(kind(client("not-running", "", { view: { phase: "not-running", exitNode: null, attention: { kind: "service-not-running" } } })),
                    "not-running", "the daemon not running: its own state, before the attention");
        assertEqual(tone(client("not-running", "")), "disabled", "… dim");
        assertEqual(kind(client("stopped", "")), "off", "stopped: off");
        assertEqual(tone(client("stopped", "")), "primary", "… plain, like a link that is on but not connected");
        assertEqual(kind(client("stopped", "activating")), "connecting", "connecting");
        assertEqual(tone(client("stopped", "activating")), "pending", "… the accent, dimmed");
        assertEqual(kind(client("running", "deactivating")), "disconnecting", "disconnecting");
        assertEqual(kind(client("running", "activated")), "connected", "running: connected");
        assertEqual(tone(client("running", "activated")), "accent", "… the accent");
        const via = client("running", "activated", { view: { phase: "running", exitNode: { name: "exit-home", online: true }, attention: null } });
        same([kind(via), rules.summaryOf(via).mark, rules.summaryOf(via).exitNode], ["exit-node", true, "exit-home"], "an exit node in use: its own state, the mark, its name");
        assertEqual(kind(client("running", "", { view: attention("login", "Log in") })), "attention", "logged out: attention");
        assertEqual(tone(client("running", "", { view: attention("login", "Log in") })), "warning", "… the warning colour");
        assertEqual(rules.summaryOf(client("x", "", { view: attention("key-expired", "Log in") })).word, "Key expired", "key expired: its word");
        assertEqual(rules.summaryOf(client("stopped", "", { pendingAttention: { kind: "approval" }, entry: { state: "", attention: { reason: "r", action: "a" } } })).kind,
                    "attention", "the attention an action found (the client's pendingAttention)");
        assertEqual(rules.summaryOf(client("stopped", "", { entry: { state: "", attention: { reason: "r", action: "" } } })).word, "Check",
                    "an attention of no known kind: a plain word");
        const offline = client("running", "activated", { view: { phase: "running", exitNode: { name: "exit-home", online: false }, attention: { kind: "exit-node-offline" } } });
        same([kind(offline), rules.summaryOf(offline).mark], ["attention", true], "the exit node offline: attention, the mark kept");
        assertEqual(kind(client("unknown", "")), "unknown", "not read yet: unknown");

        // --- the words ---
        assertEqual(rules.summaryOf(client("x", "", { view: attention("approval", "") })).word, "Needs approval", "approval: Needs approval");
        assertEqual(rules.summaryOf(client("x", "", { view: attention("other-user", "") })).word, "Other user", "another user: Other user");
        assertEqual(rules.summaryOf(client("x", "", { view: attention("read-denied", "") })).word, "No access", "not readable: No access");
        assert(!("tooltip" in rules.summaryOf(via)), "no tooltip text: the widget has no tooltip");

        // --- the text beside the icon ---
        assertEqual(rules.barText(rules.summaryOf(via), "none"), "", "text none: nothing");
        assertEqual(rules.barText(rules.summaryOf(via), "state"), "On", "text state: the word");
        assertEqual(rules.barText(rules.summaryOf(via), "exitNode"), "exit-home", "text exit node: its name");
        assertEqual(rules.barText(rules.summaryOf(client("running", "activated")), "exitNode"), "", "… nothing without one");
        assertEqual(rules.barText({ exitNode: "a-very-long-exit-node-name" }, "exitNode", 10), "a-very-lo…", "… a long name cut");
        assertEqual(rules.textMode("bogus"), "none", "an unknown text mode: none");
        same([rules.deviceCap(10), rules.deviceCap("x"), rules.deviceCap(0), rules.deviceCap(2.5), rules.deviceCap(99)], [10, 5, 5, 5, 5], "the device cap checked");

        // --- the badge ---
        same(rules.badge(2, false, true), { shown: true, text: "2" }, "badge: the count");
        same(rules.badge(12, false, true), { shown: true, text: "9+" }, "… past 9: 9+");
        same(rules.badge(-1, true, true), { shown: true, text: "" }, "… count unknown, files waiting (not the operator): a dot");
        same(rules.badge(0, true, true), { shown: false, text: "" }, "… none waiting: nothing");
        same(rules.badge(3, false, false), { shown: false, text: "" }, "… turned off in the preset: nothing");

        // --- the popup's devices ---
        const devices = [{ id: "a", online: false }, { id: "b", online: true }, { id: "c", online: false }, { id: "d", online: true }, null, { id: "e", online: true }];
        const listed = rules.deviceList(devices, 3);
        same(listed.shown.map(device => device.id), ["b", "d", "e"], "devices: online first, in the list's order, at most the cap");
        same([listed.more, listed.online], [2, 3], "… two left out, three online");
        same(rules.deviceList(devices, 10).shown.map(device => device.id), ["b", "d", "e", "a", "c"], "… offline ones after");
        same(rules.deviceList(null, 5), { shown: [], more: 0, online: 0 }, "… no list: nothing");
        const keeping = rules.deviceList(devices, 1, ["c"]);
        same([keeping.shown.map(device => device.id), keeping.more], [["b", "c"], 3], "… a device Taildrop works with in the popup: shown past the cap");

        // --- who may send ---
        assert(rules.canSendTo({ canReceiveFiles: true }, "running", true), "send: the operator, connected, a target");
        assert(!rules.canSendTo({ canReceiveFiles: true }, "running", false), "… not without the operator");
        assert(!rules.canSendTo({ canReceiveFiles: true }, "stopped", true), "… not while off");
        assert(!rules.canSendTo({ canReceiveFiles: false }, "running", true), "… not to a device that cannot receive");

        // --- Taildrop's choices go through the shell's chooser (a stand-in that behaves like
        // the shell's: one open at a time, a second ask answered "busy" after the call returns,
        // a lock or an error answered the same way) ---
        {
            const fake = fakeClient(true);
            const asked = [];
            const later = [];
            const chooser = { open: null, refuse: "" };
            const answer = changes => Object.assign({ paths: [], cancelled: false, blocked: "", error: "" }, changes);
            fake.module = { chooseFiles: (options, done) => {
                const call = { options: options, raw: done, open: false, cancelled: false };
                asked.push(call);
                const refusal = chooser.open !== null ? answer({ blocked: "busy" })
                    : chooser.refuse === "locked" ? answer({ blocked: "locked" })
                    : chooser.refuse !== "" ? answer({ error: chooser.refuse }) : null;
                if (refusal !== null) {
                    later.push(() => done(refusal));
                    return { open: false, cancel: () => {} };
                }
                call.open = true;
                chooser.open = call;
                call.done = result => {
                    if (!call.open)
                        return;
                    call.open = false;
                    chooser.open = null;
                    done(result);
                };
                return { get open() { return call.open; }, cancel: () => {
                    call.cancelled = true;
                    call.done(answer({ cancelled: true }));
                } };
            } };
            const deliver = () => {
                while (later.length > 0)
                    later.shift()();
            };
            const drop = _taildrop.createObject(suite, { client: fake });
            fake.taildrop = drop;
            fake.running = true;
            const section = _section.createObject(null, { client: fake });
            find(section, "taildropChooseFiles").clicked();
            same([asked.length, asked[0].options.mode, asked[0].options.title], [1, "openMany", "Files to send"], "the page's \"Choose files…\": the shell's chooser, several files");
            asked[0].done(answer({ paths: ["/home/u/a.txt", "/home/u/b.txt"] }));
            same(drop.chosen, ["/home/u/a.txt", "/home/u/b.txt"], "… the files join the page's list");
            same(drop.popupChoices, {}, "… not the popup's choice");
            find(section, "taildropChooseFolder").clicked();
            same([asked[1].options.mode, asked[1].options.title], ["folder", "Save received files to"], "the folder's \"Choose…\": the chooser, a folder");
            asked[1].done(answer({ paths: ["/home/u/Received"] }));
            assertEqual(drop.folder, "/home/u/Received", "… taken as the folder");

            // Two clicks before an answer: the open chooser stays, its answer the user's
            assert(drop.chooseForPopup("p1"), "the popup's \"Send file…\"");
            assert(!drop.chooseForPopup("p1"), "… clicked again before an answer: not asked again");
            assertEqual(asked.length, 3, "… the shell asked once");
            assertEqual(drop.popupNotes.p1, "Another file chooser is open", "… the second click says why nothing opened");
            asked[2].done(answer({ paths: ["/home/u/first.txt"] }));
            same(drop.popupChoices.p1, ["/home/u/first.txt"], "the open chooser's answer is kept");
            same(drop.popupNotes, {}, "… the note gone with the answer");

            // One choice per device; none while that device's send from the popup runs
            assert(drop.chooseForPopup("p2"), "another device's \"Send file…\"");
            asked[3].done(answer({ paths: ["/home/u/second.txt"] }));
            same([drop.popupChoices.p1, drop.popupChoices.p2], [["/home/u/first.txt"], ["/home/u/second.txt"]], "… each device keeps its own choice");
            assert(drop.chooseForPopup("p1"), "p1 again");
            asked[4].done(answer({ cancelled: true }));
            same(drop.popupChoices.p1, ["/home/u/first.txt"], "… closed: its choice stays");
            drop.send = { state: "sending", targetName: "peer", targetId: "p1", origin: "popup", files: [], message: "", startedAt: 0, pageCleared: false, popupCleared: false };
            assert(!drop.chooseForPopup("p1"), "p1's send from the popup runs: not asked");
            assertEqual(asked.length, 5, "… the chooser not opened");
            assertEqual(drop.popupNotes.p1, "A send to this device is running", "… said under the device");
            same(drop.popupKept, ["p1", "p2"], "the popup keeps both devices shown");
            drop.dropPopupNote("p1");
            drop.send = { state: "done", targetName: "peer", targetId: "p1", origin: "popup", files: [], message: "", startedAt: 0, pageCleared: false, popupCleared: false };

            // The page and the popup clear the result for themselves
            assertEqual(find(section, "taildropSendState").text, "Sent to peer", "the popup's send shows on the page");
            drop.dismissPopupSend("p1");
            assertEqual(find(section, "taildropSendState").text, "Sent to peer", "… the popup's \"×\" leaves it on the page");
            same(TaildropRules.popupRow({}, drop.send, "p1", false), null, "… gone from the popup");
            drop.send = Object.assign({}, drop.send, { popupCleared: false });
            find(section, "taildropClear").clicked();
            assert(!shown(find(section, "taildropSendState")), "the page's Clear: gone from the page");
            assertEqual(TaildropRules.popupRow({}, drop.send, "p1", false)?.kind, "result", "… still in the popup");
            drop.dismissPopupSend("p1");
            assertEqual(drop.send.state, "", "cleared in both: gone");

            // Another module's chooser open, a lock, an error
            chooser.open = { foreign: true };
            assert(drop.chooseForPopup("p1"), "another module's chooser open: asked");
            deliver();
            assertEqual(drop.popupNotes.p1, "Another file chooser is open", "… \"busy\": a note under the device");
            same(drop.popupChoices.p1, ["/home/u/first.txt"], "… its choice untouched");
            find(section, "taildropChooseFiles").clicked();
            deliver();
            assertEqual(find(section, "taildropInputProblem")?.text, "Another file chooser is open", "… the page's \"Choose files…\": on its message line");
            find(section, "taildropChooseFolder").clicked();
            deliver();
            assert(shown(find(section, "taildropFolderNote")) && find(section, "taildropFolderNote").text === "Another file chooser is open", "… the folder's \"Choose…\": under the folder");
            chooser.open = null;
            chooser.refuse = "locked";
            drop.chooseForPopup("p1");
            find(section, "taildropChooseFolder").clicked();
            deliver();
            same(drop.popupNotes, {}, "locked: nothing said under the device");
            assert(!shown(find(section, "taildropFolderNote")), "… nor under the folder");
            chooser.refuse = "the dialog could not be opened\n<b>x</b>";
            drop.chooseForPopup("p1");
            deliver();
            assertEqual(drop.popupNotes.p1, "the dialog could not be opened <b>x</b>", "an error: its text, on one line");
            chooser.refuse = "";

            // An account switch drops the popup's choices; a stop cancels the open chooser
            fake.operation = "account";
            same([drop.popupChoices, drop.popupNotes], [{}, {}], "an account switch: the choices and notes dropped");
            fake.operation = "";
            assert(drop.chooseForPopup("p1"), "asked once more");
            const open = asked[asked.length - 1];
            fake.running = false;
            assert(open.cancelled, "the client stops: its open chooser cancelled");
            open.raw(answer({ paths: ["/home/u/late.txt"] }));
            same(drop.popupChoices, {}, "an answer after the client stopped is dropped");
            const count = asked.length;
            assert(!drop.chooseForPopup("p1"), "stopped: the chooser is not asked");
            assertEqual(asked.length, count, "… nothing more asked");
            section.destroy();
            drop.destroy();
            fake.destroy();
        }

        // --- the popup: never empty ---
        const none = _popup.createObject(null, { client: null });
        assertEqual(find(none, "tailscalePopupStatus")?.text, "Not available", "popup without a client: says so");
        assert(shown(find(none, "tailscalePopupSettings")), "… Settings… offered");
        assert(!shown(find(none, "tailscalePopupConnect")) && !shown(find(none, "tailscalePopupAdmin")), "… no Connect, no admin console");
        none.destroy();

        const stoppedDaemon = _popup.createObject(null, { client: client("not-running", "", {
            view: { phase: "not-running", exitNode: null, attention: { kind: "service-not-running", reason: "r", action: "Start" } },
            entry: { state: "", status: "Service not running", attention: { reason: "The service is not running", action: "Start" } } }) });
        assertEqual(find(stoppedDaemon, "tailscalePopupStatus")?.text, "Service not running", "popup, daemon stopped: the entry's line");
        assert(shown(find(stoppedDaemon, "tailscalePopupAttend")) && find(stoppedDaemon, "tailscalePopupAttend").label === "Start", "… Start offered");
        assert(!shown(find(stoppedDaemon, "tailscalePopupConnect")), "… no Connect");
        stoppedDaemon.destroy();

        const loggedOut = _popup.createObject(null, { client: client("logged-out", "", {
            view: attention("login", "Log in"), entry: { state: "", status: "Logged out", attention: { reason: "Log in to Tailscale to connect", action: "Log in" } } }) });
        assert(shown(find(loggedOut, "tailscalePopupAttend")) && find(loggedOut, "tailscalePopupAttend").label === "Log in", "popup, logged out: Log in");
        assert(!shown(find(loggedOut, "tailscalePopupConnect")) && !shown(find(loggedOut, "tailscalePopupDisconnect")), "… neither Connect nor Disconnect");
        assert(!shown(find(loggedOut, "tailscalePopupSelf")) && !shown(find(loggedOut, "tailscalePopupAccount")), "… no addresses, no account");
        loggedOut.destroy();

        const stopped = _popup.createObject(null, { client: client("stopped", "", { entry: { state: "", status: "Off", attention: null } }) });
        assert(shown(find(stopped, "tailscalePopupConnect")), "popup, off: Connect");
        assert(shown(find(stopped, "tailscalePopupMark")), "… not the operator: the lock beside it");
        stopped.destroy();
        // The lock only beside a button: none shown, nothing to mark, no room taken
        const waiting = _popup.createObject(null, { client: client("needs-approval", "", { entry: { state: "", status: "Waiting", attention: null } }) });
        assert(!shown(find(waiting, "tailscalePopupConnect")) && !shown(find(waiting, "tailscalePopupDisconnect")) && !shown(find(waiting, "tailscalePopupAttend")),
               "popup, waiting for approval: no button");
        same([shown(find(waiting, "tailscalePopupMark")), find(waiting, "tailscalePopupMark").implicitWidth], [false, 0], "… and no lock");
        waiting.destroy();

        // Connected, with crafted names everywhere the tailnet names something
        const peer = { id: "p1", name: crafted, online: true, ipv4: "100.64.0.9", canReceiveFiles: true };
        const live = client("running", "activated", {
            canChange: true,
            view: { phase: "running", exitNode: null, attention: null },
            entry: { state: "activated", status: "Tailnet only", attention: null },
            currentAccount: { loginName: crafted, tailnet: crafted },
            device: { ipv4: "100.64.0.1", ipv6: "fd7a::1", dnsName: crafted, namePending: false },
            devices: [peer, { id: "p2", name: "off", online: false, ipv4: "100.64.0.10", canReceiveFiles: true }],
            exitNodes: { own: [{ id: "n", label: crafted, name: crafted, dnsName: "", online: true, current: false }], countries: [], current: null, suggested: null, count: 1 },
            taildrop: { waitingCount: 2, busWaiting: true, statusText: "2 files received", isOperator: true, canSave: true,
                        saved: [{ name: crafted, savedAs: crafted, outcome: "saved" }], saveError: "", chooseForPopup: () => {}, save: () => {} }
        });
        const popup = _popup.createObject(null, { client: live, _ready: true });
        assert(shown(find(popup, "tailscalePopupDisconnect")), "popup, connected: Disconnect");
        assert(!shown(find(popup, "tailscalePopupConnect")), "… no Connect");
        assert(!shown(find(popup, "tailscalePopupMark")), "… the operator: no lock beside it");
        assert(shown(find(popup, "tailscaleExitNodeChooser")), "… the exit-node chooser (the row's own)");
        assert(shown(find(popup, "tailscalePopupSelf")), "… this device's addresses");
        assert(shown(find(popup, "tailscalePopupSave")), "… Save for the operator");
        assertEqual(find(popup, "tailscalePopupWaiting")?.text, "2 files received", "… the waiting files (the client's own line)");
        assert(shown(find(popup, "tailscalePopupAdmin")), "… the admin console");
        popup.availableHeight = 200;
        assertEqual(popup.implicitHeight, 200, "… taller than the popup allows: cut to its available height");
        assert(find(popup, "tailscalePopupScroll").interactive, "… and scrolls");
        popup.availableHeight = Infinity;
        assert(popup.implicitHeight > 200 && !find(popup, "tailscalePopupScroll").interactive, "… room enough: its own height, no scrolling");
        const texts = shownTexts(popup, "<img");
        assert(texts.length >= 3, "… the crafted names shown: account, device, last save (" + texts.length + ")");
        for (const text of texts)
            assert(text.textFormat === Text.PlainText, "… as plain text: " + String(text.text).slice(0, 60));
        popup.destroy();

        // --- module API 1.15: the client is the module's main's; the preset is the opener's ---
        {
            const asked = [];
            const handle = {
                main: { client: live },
                presetValue: (type, preset, key) => {
                    asked.push([type, preset, key]);
                    return preset === "small" && key === "devices" ? 2 : undefined;
                }
            };
            // Assigned, not handed to createObject (which copies a plain object): the same client
            const opened = _popup.createObject(null, { opener: { widgetType: "tailscale", preset: "small", edge: "top", byTouch: false } });
            opened.module = handle;
            assert(opened.client === live, "popup: the client is module.main.client");
            assertEqual(opened.deviceCap, 2, "popup: the device cap of the preset that opened it (opener.preset)");
            assert(asked.some(call => call[0] === "tailscale" && call[1] === "small" && call[2] === "devices"), "… read through the handle for that preset");
            opened.opener = { widgetType: "tailscale", preset: "", edge: "top", byTouch: false };
            assertEqual(opened.deviceCap, 5, "… another entry (no value in its preset): the default");
            opened.opener = null;
            assertEqual(opened.deviceCap, 5, "… opened by no widget: the default");
            opened.destroy();
            const off = _popup.createObject(null, { module: { main: null } });
            assertEqual(off.client, null, "popup: the module off (no main): no client");
            assertEqual(find(off, "tailscalePopupStatus")?.text, "Not available", "… says so");
            off.destroy();
            const handled = _widget.createObject(null);
            handled.module = handle;
            assert(handled.client === live, "widget: the client is module.main.client");
            handled.destroy();
        }

        // --- the widget, built with a client ---
        const widget = _widget.createObject(null, { client: via });
        assertEqual(widget.summary.kind, "exit-node", "the widget: the client's state");
        assert(shown(find(widget, "tailscaleWidgetExitMark")), "… the exit-node mark shown");
        assertEqual(widget.barText, "", "… no text by default");
        assert(!shown(find(widget, "tailscaleWidgetBadge")), "… no badge without files");
        widget.client = live;
        assert(shown(find(widget, "tailscaleWidgetBadge")), "… the badge while files wait");
        assert(!shown(find(widget, "tailscaleWidgetExitMark")), "… no mark without an exit node");
        widget.destroy();

        // --- a long name on a chip is cut, never wider than the chips
        {
            const longName = "a-very-long-device-name-" + "x".repeat(120) + ".example-tailnet.ts.net";
            const chips = _chips.createObject(null, { texts: [longName] });
            const chip = chips.children.find(child => child.modelData !== undefined);
            assert(chip !== undefined && chip.implicitWidth <= 200, "a long MagicDNS name: the chip within the chips' width (" + chip?.implicitWidth + ")");
            chips.destroy();
        }

        // --- the settings pane builds (no handle: the defaults, nothing changes) ---
        const pane = _settings.createObject(null, { presetName: "Tailscale" });
        assert(pane !== null && pane.implicitHeight > 0, "the widget settings pane builds");
        same([pane._text, pane._badge, pane._devices], ["none", true, 5], "… the defaults without a handle");
        // Its pills: the public Pill (module API 1.32), the body text, the medium height
        for (const name of ["tailscaleWidgetText-none", "tailscaleWidgetDevices-5"]) {
            const pill = find(pane, name);
            const label = shownTexts(pill, name.endsWith("none") ? "None" : "5")[0];
            same([pill !== null, pill?.fontSize === undefined, pill?.size, pill?.textSize], [true, true, "m", "body"],
                 name + ": the public pill (no fontSize of the shell's own), medium, body text");
            same([label?.font.pixelSize, pill?.implicitHeight], [Api.theme.fontSizeBody, Math.max(Api.theme.pill.mediumHeight, 26)],
                 "… its label at the theme's body size, as tall as before (the medium pill, 26 by default)");
        }
        pane.destroy();
    }
}
