pragma Singleton

import QtQuick
import Quickshell

// Tailnet lock (delivery step 5), status only, pure. `tailscale lock status --json` reads the
// LocalAPI's tka/status — read access, any user (ipn/localapi/tailnetlock.go PermitRead;
// observed on 1.104.4). Its shape (cmd/tailscale/tslockjsonv1, schema "1"): Enabled, PublicKey
// ("tlpub:…"), NodeKey ("nodekey:…"); only while enabled: NodeKeySigned, TrustedKeys,
// VisiblePeers, FilteredPeers, Head, State. A node with lock on whose key is not signed is
// LOCKED OUT: it reaches no peer until a trusted device signs it (cli/tailnet-lock.go
// printTailnetLockStatus). Nothing here changes the lock: init, sign, add, remove, disable are
// the tailnet's administration, left to Tailscale's own tools.
Singleton {
    id: root

    function _isObject(value) {
        return value !== null && typeof value === "object" && !Array.isArray(value);
    }

    function _own(object, key) {
        return _isObject(object) && Object.prototype.hasOwnProperty.call(object, key) ? object[key] : undefined;
    }

    function _key(value, prefix) {
        return typeof value === "string" && value.startsWith(prefix) && /^[a-z]+:[0-9a-f]{1,128}$/.test(value) ? value : "";
    }

    // → { ok, error, enabled, publicKey, nodeKey, signed (true / false / null unknown),
    // trustedKeys (count), filteredPeers (count), lockedOut }
    function parse(input) {
        const result = { ok: false, error: "", enabled: false, publicKey: "", nodeKey: "", signed: null, trustedKeys: 0, filteredPeers: 0, lockedOut: false };
        let raw = input;
        if (typeof input === "string") {
            try {
                raw = JSON.parse(input);
            } catch (error) {
                result.error = "not JSON";
                return result;
            }
        }
        if (!_isObject(raw)) {
            result.error = "not an object";
            return result;
        }
        result.ok = true;
        result.enabled = _own(raw, "Enabled") === true;
        result.publicKey = _key(_own(raw, "PublicKey"), "tlpub:");
        result.nodeKey = _key(_own(raw, "NodeKey"), "nodekey:");
        const signed = _own(raw, "NodeKeySigned");
        result.signed = typeof signed === "boolean" ? signed : null;
        result.trustedKeys = Array.isArray(_own(raw, "TrustedKeys")) ? _own(raw, "TrustedKeys").length : 0;
        result.filteredPeers = Array.isArray(_own(raw, "FilteredPeers")) ? _own(raw, "FilteredPeers").length : 0;
        // As the CLI says it: enabled, a node key and a lock key, and not signed
        result.lockedOut = result.enabled && result.nodeKey !== "" && result.publicKey !== "" && result.signed === false;
        return result;
    }

    // The entry's attention while locked out (a lasting state the user must act on), else null
    function attention(lock) {
        return lock?.lockedOut === true ? { kind: "locked-out", reason: "Locked out by tailnet lock: a trusted device must sign this one", action: "Open admin console" } : null;
    }

    // One line for the page
    function summary(lock) {
        if (!lock || lock.ok !== true)
            return "";
        if (!lock.enabled)
            return "Off";
        if (lock.lockedOut)
            return "Locked out";
        return lock.signed === true ? "On, this device is signed" : "On";
    }
}
