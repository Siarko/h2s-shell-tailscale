import QtQuick
import qs.tests
import ".."

// What peers and the control server name is shown as TEXT, never as markup: a device, an
// exit node or a warning named `<b>x</b><img src="http://example.invalid/">` is shown
// literally (Text.PlainText) — with the default AutoText it would be rich text, and the
// <img> a URL the shell would fetch. The device row, the exit-node chooser and the card are
// built with crafted data, and every Text showing it is checked.
TestCase {
    id: suite
    suiteName: "tailscale: peers' names shown as plain text"

    readonly property string crafted: "<b>x</b><img src=\"http://example.invalid/\">"

    property Component _deviceRow: Component {
        DeviceRow {
            width: 600
        }
    }
    property Component _chooser: Component {
        ExitNodeChooser {
            width: 600
            collapsible: false
        }
    }
    property Component _card: Component {
        TailscaleCard {
            width: 600
        }
    }
    property Component _page: Component {
        TailscalePage {
            width: 700
        }
    }
    // The width rich text would take for the same string ("x" in bold, an image)
    property Component _reference: Component {
        Text {
            textFormat: Text.RichText
        }
    }

    // Every Text (and TextEdit) under `item` whose text holds `needle`
    function textsWith(item, needle) {
        const found = [];
        const walk = node => {
            if (!node)
                return;
            if ((node instanceof Text || node instanceof TextEdit) && String(node.text).indexOf(needle) >= 0)
                found.push(node);
            for (const child of node.children ?? [])
                walk(child);
        };
        walk(item);
        return found;
    }

    function checkPlain(item, where) {
        const texts = textsWith(item, "<img");
        assert(texts.length > 0, where + ": the crafted name is shown (" + texts.length + " text(s))");
        for (const text of texts) {
            const plain = text instanceof TextEdit ? text.textFormat === TextEdit.PlainText : text.textFormat === Text.PlainText;
            assert(plain, where + ": shown as plain text: " + JSON.stringify(String(text.text).slice(0, 80)));
            assert(String(text.text).indexOf(crafted) >= 0, where + ": the markup kept literally, not interpreted");
        }
        return texts;
    }

    function run() {
        const device = {
            id: "n1", name: crafted, dnsName: "peer.example-tailnet.ts.net", os: crafted, owner: crafted, tags: [], online: true,
            connection: "direct", addresses: ["100.64.0.9"], exitNodeOption: true, isExitNode: false, sharedIn: false, keyExpired: false,
            rxBytes: 0, txBytes: 0, lastSeenText: ""
        };
        const row = _deviceRow.createObject(null, { device: device });
        const texts = checkPlain(row, "device row");
        assert(texts.length >= 2, "device row: the name and the owner · system line both plain");
        const reference = _reference.createObject(null, { text: crafted });
        const nameText = texts.find(text => text.text === crafted);
        assert(nameText !== undefined && nameText.implicitWidth > reference.implicitWidth,
               "device row: the name takes the width of its characters, wider than the rendered markup (" + nameText?.implicitWidth + " > " + reference.implicitWidth + ")");
        reference.destroy();
        row.destroy();

        const option = { id: "n1", label: crafted, name: crafted, dnsName: crafted, online: true, current: false, argument: "100.64.0.9" };
        const client = {
            busy: false, canChange: true, view: { phase: "running", exitNode: null },
            exitNodes: { own: [option], countries: [], current: Object.assign({}, option, { current: true }), suggested: null, count: 1 },
            setExitNode: () => {}
        };
        const chooser = _chooser.createObject(null, { client: client });
        checkPlain(chooser, "exit-node chooser");
        chooser.destroy();

        const fakeClient = {
            entry: { state: "activated" }, prefs: { acceptDns: true, loginName: crafted }, status: { addresses: [], tailnet: { name: crafted } },
            self: null, lastTailnet: "", keyExpiry: null,
            view: { phase: "running", exitNode: { name: crafted, online: false } },
            warnings: [{ kind: "health", text: crafted }]
        };
        const card = _card.createObject(null, { context: { provider: { client: fakeClient }, otherVpnsUp: [] } });
        checkPlain(card, "card");
        card.destroy();

        // The page (step 2's sections too): accounts, this device, the devices with a ping
        // result, diagnostics open — every crafted name plain
        const pageClient = {
            view: { phase: "running", exitNode: null, attention: null }, prefs: { acceptDns: true, operatorUser: "" }, canChange: false, busy: false,
            entry: { state: "activated", status: "Tailnet only", attention: null }, authUrl: "", busAuthUrl: "", operation: "", elevationProblem: "",
            userName: "tester", cli: "present", tailscalePath: "/x/tailscale", updateManagedBySystem: false, loginTimeoutMs: 600000, _loginElevated: false,
            status: { version: "1.104.4" }, warnings: [], exitNodes: { own: [], countries: [], current: null, suggested: null, count: 0 },
            accounts: [{ id: "a1", nickname: crafted, tailnet: "example.org", account: crafted, selected: true },
                       { id: "b2", nickname: "", tailnet: crafted, account: "u@example.com", selected: false }],
            accountsOutdated: false, loginInterrupted: { id: "a1", title: crafted },
            currentAccount: { loginName: crafted, tailnet: crafted },
            device: { hostName: crafted, customHostname: "x", dnsName: crafted, ipv4: "100.64.0.1", ipv6: "", online: true, relay: crafted, keyExpiry: 0,
                      key: { state: "soon", days: 3, text: crafted }, statusName: crafted, namePending: true, nameNote: "updating" },
            // Step 3: Sharing (tags come from the tailnet) and SSH (Tailscale's health texts)
            sharing: { known: true, connected: true, exitNode: { offered: true, state: "pending", text: "waiting", problem: "" },
                       routes: [{ route: "192.168.7.0/24", family: 4, state: "pending", text: "waiting" }], offersAny: true, families: [4], pendingCount: 1,
                       adminUrl: "https://login.tailscale.com/admin/machines/100.64.0.1", tagsRequested: [crafted], tagsApplied: [crafted], connector: false,
                       snat: true, statefulFiltering: null, netfilterMode: "on", relayServerPort: null, webClient: true, webClientUrl: "http://100.64.0.1:5252",
                       postureChecking: false, autoUpdate: null, updateCheck: true },
            sshServer: { on: true, allowedByTailnet: true, canTurnOn: true, problem: "" },
            forwardingWarning: { text: "IP forwarding is off (IPv4).", families: [4], tailscaleSays: crafted, nixosLines: ["x"] },
            readForwarding: () => {}, autoUpdateProblem: "",
            diagnostics: { running: false, ranAt: 1, clientVersion: crafted, netcheck: [{ label: "Nearest relay", value: crafted }],
                           dns: [{ label: "Search domains", value: crafted }], errors: [crafted], nearest: null },
            health: [{ title: crafted, text: crafted, severity: "" }, { title: "Tailscale SSH", text: crafted, severity: "" }], diagnosticsReport: "", updateNotice: "",
            devices: [Object.assign({}, device, { id: "n1" })], pings: { n1: { running: false, ok: false, text: crafted } },
            watch: () => {}, unwatch: () => {}
        };
        const page = _page.createObject(null, { context: { provider: { client: pageClient } }, _diagnosticsOpen: true });
        const pageTexts = checkPlain(page, "page");
        assert(pageTexts.length >= 12, "page: the crafted names in every new section (" + pageTexts.length + " texts)");
        page.destroy();
    }
}
