import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.api

// The exit-node chooser (the popup row's extras and the page's "Exit node" section): the
// current node or "None", the suggested node as a one-tap choice, this tailnet's own exit
// nodes, location nodes (Mullvad) grouped by country — collapsed — and by city (the city's
// best online server is the one chosen), offline nodes disabled, a filter when the list is
// long. A change that asks for a password carries the privileged mark. Collapsible (the
// popup): a header that opens the list, closed again after a choice. A choice here is "for
// now" over the networks' choices (NetworkExitClient); while one overrides a network's choice
// the list starts with "Default", which goes back to it, and the header says which is in
// effect ("for now", "for Café").
ColumnLayout {
    id: root
    objectName: "tailscaleExitNodeChooser"

    // TailscaleClient
    property var client: null
    property bool collapsible: true
    property bool expanded: !collapsible
    // How many rows before a filter is offered
    property int filterFrom: 8

    readonly property var nodes: client?.exitNodes ?? ({ own: [], countries: [], current: null, suggested: null, count: 0 })
    readonly property string need: client && !client.canChange ? "auth" : ""
    readonly property bool _available: client !== null && !client.busy && client.view.phase === "running"
    // What decides the exit node now (NetworkExitRules.effect), and the header's words for it
    readonly property var effect: client?.networkExit?.effect ?? ({ kind: "", network: "", label: "" })
    readonly property string effectText: NetworkExitRules.effectText(effect)
    property string _filter: ""
    // Countries opened, by key
    property var _openCountries: ({})

    spacing: 2

    function _matches(texts) {
        const wanted = _filter.trim().toLowerCase();
        return wanted === "" || texts.some(text => String(text ?? "").toLowerCase().includes(wanted));
    }

    function _choose(option) {
        if (!_available)
            return;
        client.setExitNode(option);
        if (collapsible)
            expanded = false;
    }

    // "Default": the choice made by hand ends, the network's choice applies again
    function _useDefault() {
        if (!_available)
            return;
        client.networkExit?.dropOverride();
        if (collapsible)
            expanded = false;
    }

    // The list as rows: { key, kind ("choice" | "heading" | "country"), label, detail, option,
    // current, enabled, depth }
    readonly property var _rows: {
        const rows = [];
        const filtering = _filter.trim() !== "";
        if (effect.kind === "override" && !filtering)
            rows.push({ key: "default", kind: "choice", label: "Default", detail: NetworkExitRules.defaultDetail(effect), option: null, isDefault: true,
                        current: false, enabled: true, depth: 0 });
        rows.push({ key: "none", kind: "choice", label: "None", detail: "Internet traffic goes out directly", option: null,
                    current: nodes.current === null, enabled: true, depth: 0 });
        const suggested = nodes.suggested;
        if (suggested && !filtering)
            rows.push({ key: "suggested", kind: "choice", label: "Suggested: " + suggested.label, detail: suggested.online ? "Tailscale's pick for this network" : "offline",
                        option: suggested, current: suggested.current, enabled: suggested.online, depth: 0 });
        const own = nodes.own.filter(option => _matches([option.label, option.name, option.dnsName]));
        if (own.length > 0)
            rows.push({ key: "h-own", kind: "heading", label: "This tailnet's exit nodes", detail: "", option: null, current: false, enabled: false, depth: 0 });
        for (const option of own)
            rows.push({ key: "own-" + option.id, kind: "choice", label: option.label, detail: option.online ? option.dnsName : "offline",
                        option: option, current: option.current, enabled: option.online, depth: 1 });
        const countries = nodes.countries.map(country => ({
            country: country,
            cities: country.cities.filter(city => _matches([country.country, country.countryCode, city.city].concat(city.nodes.map(node => node.name))))
        })).filter(entry => entry.cities.length > 0);
        if (countries.length > 0)
            rows.push({ key: "h-locations", kind: "heading", label: "Locations (Mullvad)", detail: "", option: null, current: false, enabled: false, depth: 0 });
        for (const entry of countries) {
            const key = entry.country.countryCode || entry.country.country;
            const open = filtering || _openCountries[key] === true;
            const holdsCurrent = entry.cities.some(city => city.nodes.some(node => node.current));
            rows.push({ key: "c-" + key, kind: "country", label: entry.country.country, countryKey: key,
                        detail: entry.cities.length + (entry.cities.length === 1 ? " city" : " cities") + (holdsCurrent ? " · in use" : ""),
                        option: null, current: holdsCurrent, enabled: true, depth: 1, open: open });
            if (!open)
                continue;
            for (const city of entry.cities) {
                const best = city.best;
                const current = city.nodes.some(node => node.current);
                rows.push({ key: "city-" + key + "-" + (city.cityCode || city.city), kind: "choice", label: city.city,
                            detail: best ? (city.nodes.length > 1 ? city.nodes.length + " servers" : best.name) : "offline",
                            option: current ? city.nodes.find(node => node.current) : best, current: current, enabled: best !== null, depth: 2 });
            }
        }
        return rows;
    }
    readonly property int _choiceCount: nodes.count + 1

    // The header: what is in use; opens the list
    Rectangle {
        objectName: "tailscaleExitNodeHeader"
        visible: root.collapsible
        Layout.fillWidth: true
        implicitHeight: 30
        radius: Api.theme.row.radius
        color: _headerArea.lit ? Api.theme.surfaceHover : Api.theme.surface

        RowLayout {
            anchors { fill: parent; leftMargin: Api.theme.row.horizontalPadding; rightMargin: Api.theme.row.horizontalPadding }
            spacing: 6
            Text {
                textFormat: Text.PlainText
                text: "Exit node"
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: Api.theme.textMuted
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.nodes.current ? root.nodes.current.label + (root.nodes.current.online ? "" : " (offline)") : "None"
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: root.nodes.current && !root.nodes.current.online ? Api.theme.warning : Api.theme.textPrimary
            }
            Text {
                objectName: "tailscaleExitNodeEffect"
                visible: text !== ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                Layout.maximumWidth: root.width * 0.4
                text: root.effectText
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeXSmall
                color: Api.theme.textMuted
            }
            PrivilegedMark {
                need: root.need
            }
            Text {
                textFormat: Text.PlainText
                text: root.expanded ? "▾" : "▸"
                font.family: Api.theme.fontFamily
                font.pixelSize: Api.theme.fontSizeSmall
                color: Api.theme.textMuted
            }
        }
        PointerArea {
            id: _headerArea
            anchors.fill: parent
            centred: false
            onClicked: root.expanded = !root.expanded
        }
    }

    InputField {
        visible: root.expanded && root._choiceCount > root.filterFrom
        Layout.fillWidth: true
        placeholder: "Filter: a name, a country, a city"
        size: "s"
        onTextEdited: root._filter = text
    }

    Repeater {
        // ScriptModel, never the bare array (the shell's rule), keyed for reuse
        model: ScriptModel {
            objectProp: "key"
            values: root.expanded ? root._rows : []
        }

        Rectangle {
            id: _row
            required property var modelData
            required property int index
            objectName: "tailscaleExitNode-" + index
            Layout.fillWidth: true
            implicitHeight: modelData.kind === "heading" ? _rowLabel.implicitHeight + 8 : 28
            radius: Api.theme.row.radius
            readonly property bool _choosable: modelData.kind === "country" || (modelData.kind === "choice" && modelData.enabled && root._available)
            color: modelData.kind === "heading" ? "transparent"
                : modelData.current && modelData.kind === "choice" ? Api.theme.accentTint
                : _area.lit && _choosable ? Api.theme.surfaceHover : "transparent"

            RowLayout {
                anchors { fill: parent; leftMargin: Api.theme.row.horizontalPadding + _row.modelData.depth * 12; rightMargin: Api.theme.row.horizontalPadding }
                spacing: 6
                Text {
                    textFormat: Text.PlainText
                    visible: _row.modelData.kind === "country"
                    text: _row.modelData.open ? "▾" : "▸"
                    font.family: Api.theme.fontFamily
                    font.pixelSize: Api.theme.fontSizeSmall
                    color: Api.theme.textMuted
                }
                Text {
                    textFormat: Text.PlainText
                    id: _rowLabel
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: _row.modelData.label
                    font.family: Api.theme.fontFamily
                    font.pixelSize: _row.modelData.kind === "heading" ? Api.theme.fontSizeXSmall : Api.theme.fontSizeSmall
                    font.bold: _row.modelData.kind === "heading"
                    color: _row.modelData.kind === "heading" ? Api.theme.textMuted
                        : !_row.modelData.enabled ? Api.theme.textDisabled
                        : _row.modelData.current ? Api.theme.accent : Api.theme.textPrimary
                }
                Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: _row.modelData.detail
                    elide: Text.ElideRight
                    Layout.maximumWidth: root.width * 0.45
                    font.family: Api.theme.fontFamily
                    font.pixelSize: Api.theme.fontSizeXSmall
                    color: _row.modelData.detail === "offline" ? Api.theme.textDisabled : Api.theme.textMuted
                }
                Text {
                    textFormat: Text.PlainText
                    visible: _row.modelData.kind === "choice" && _row.modelData.current
                    text: "✓"
                    font.family: Api.theme.fontFamily
                    font.pixelSize: Api.theme.fontSizeSmall
                    color: Api.theme.accent
                }
            }
            PointerArea {
                id: _area
                anchors.fill: parent
                centred: false
                enabled: _row.modelData.kind !== "heading"
                onClicked: {
                    if (_row.modelData.kind === "country") {
                        const open = Object.assign({}, root._openCountries);
                        open[_row.modelData.countryKey] = !_row.modelData.open;
                        root._openCountries = open;
                    } else if (_row._choosable && !_row.modelData.current) {
                        if (_row.modelData.isDefault === true)
                            root._useDefault();
                        else
                            root._choose(_row.modelData.option);
                    }
                }
            }
        }
    }
}
