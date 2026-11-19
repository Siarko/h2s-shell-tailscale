import QtQuick
import qs.api

// Taildrop's live side (delivery step 4): I/O only, every decision TaildropRules'. Made by
// the live client (TailscaleClient.taildrop), on its process runner (ended with the module).
//
// WHO: Taildrop — sending and receiving — needs this user to be Tailscale's operator. The
// LocalAPI's file-put and files/ need write access (root or the operator), and nothing of
// Taildrop runs through pkexec: a root `file cp` would open paths the user chose long after
// any check (a swapped file or parent link makes root read and send what the user cannot
// read), and a root `file get` would leave root's files in the user's folder. Not the
// operator: the page offers becoming it.
//
// SENDING — `tailscale file cp -- <paths…> <IPv4>:` as the user, OUTSIDE the client's change
// lock (a long send must not block Disconnect or the settings): one send at a time, its own
// process. A user-side `find -P` first, only for a clear message (links, folders, unreadable,
// missing). Progress from the bus's OutgoingFiles. Cancel kills it (the user's own process);
// so do Disconnect, logout, an account switch and the module going away. Limits: no progress
// on the bus for idleLimitMs (2 minutes) → stopped as stalled; overall TailscaleRules'
// timeLimits.send. Files come from the shell's chooser (module.chooseFiles): the page's list
// (`chosen`, also pasted or dropped paths) or the bar popup's choice for one device
// (`popupChoice`), sent from the row under that device, which shows the send's progress.
//
// RECEIVING — anyone sees that files arrived (the bus's IncomingFiles with Done, FilesWaiting):
// a notification per arrival, the count on the page and the entry's status line. The operator
// saves them as the user (TaildropRules.saveScript) under the client's change lock.
// Auto-save runs only for an arrival (and once at start-up or when switched on, when files
// wait); names it tried and left are not tried again until the next arrival or a manual Save.
QtObject {
    id: root

    // ---- Set by the owner ----

    property var client: null
    // The default save folder ("" = the system's download folder: Api.system's, through the
    // client — TaildropRules.defaultFolder)
    property string defaultFolder: ""
    // A send with no progress on the bus for this long is stopped (only while the bus is up)
    property int idleLimitMs: 120000

    readonly property bool running: client !== null && client.running && client.cli === "present"
    readonly property var module: client?.module ?? null
    readonly property var store: module?.store ?? null

    // ---- Settings (the module's store) ----

    property string _folderSetting: String(store?.get("taildrop.folder", "") ?? "")
    property string _conflictSetting: String(store?.get("taildrop.conflict", "") ?? "")
    property bool _autoSaveSetting: store?.get("taildrop.autoSave", false) === true
    readonly property string _systemDefault: TaildropRules.defaultFolder(String(client?.system?.downloadDirectory ?? ""), String(client?.system?.home ?? ""))
    readonly property string folder: TaildropRules.folderProblem(_folderSetting) === "" ? _folderSetting
        : (defaultFolder !== "" ? defaultFolder : _systemDefault)
    readonly property bool folderIsDefault: TaildropRules.folderProblem(_folderSetting) !== ""
    readonly property string conflict: TaildropRules.conflictPolicies.includes(_conflictSetting) ? _conflictSetting : TaildropRules.defaultConflict
    readonly property bool autoSave: _autoSaveSetting
    // Saving by itself never replaces a file: any device allowed to send could replace
    // same-named files in the folder
    readonly property string autoConflict: conflict === "overwrite" ? "rename" : conflict

    function setFolder(path) {
        const clean = TaildropRules.cleanFolder(path);
        if (TaildropRules.folderProblem(clean) !== "")
            return false;
        _folderSetting = clean;
        store?.set("taildrop.folder", clean);
        _autoTried = [];
        return true;
    }

    function resetFolder() {
        _folderSetting = "";
        store?.remove("taildrop.folder");
        _autoTried = [];
    }

    function setConflict(policy) {
        if (!TaildropRules.conflictPolicies.includes(policy))
            return false;
        _conflictSetting = policy;
        store?.set("taildrop.conflict", policy);
        return true;
    }

    // Only while files can be saved without a prompt (the operator)
    function setAutoSave(on) {
        _autoSaveSetting = on === true && canSave;
        store?.set("taildrop.autoSave", _autoSaveSetting);
        if (_autoSaveSetting)
            _requestAutoSave();
    }

    // ---- Who ----

    // Taildrop needs the operator (or root): the LocalAPI's write access
    readonly property bool isOperator: client?.canChange === true
    readonly property bool canSend: isOperator
    readonly property bool canSave: isOperator && (client?.curlPath ?? "") !== ""

    // ---- Receiving ----

    property bool busWaiting: false
    property var waiting: []
    property bool waitingKnown: false
    readonly property int waitingCount: waitingKnown ? waiting.length : -1
    property var incoming: []
    // The saves' results, newest first ([{ outcome, name, savedAs, path, kept, reason }])
    property var saved: []
    property string saveError: ""
    // Arrival notifications made (for the suites: { names, actions })
    property var notices: []
    property var _seen: []
    readonly property string statusText: TaildropRules.waitingText(waitingCount, busWaiting)

    property bool _listing: false
    property bool _listAgain: false
    // Auto-save: one request pending (run when the listing is read and no change runs), the
    // Tailscale names it tried and left, whether the start-up check was made
    property bool _autoPending: false
    property var _autoTried: []
    property bool _autoStartChecked: false
    // Counters, for the suites
    property int autoRuns: 0

    // ---- Sending ----

    readonly property var targets: TaildropRules.targets(client?.devices ?? [])
    property string targetId: ""
    readonly property var target: targets.find(item => item.id === targetId) ?? null
    property var chosen: []
    property var inputProblems: []
    // { state: "" | "checking" | "sending" | "done" | "failed" | "cancelled", targetName,
    //   targetId, files [{ path, name, size, problem, sent, percent, outcome }], message }
    // origin: "page" | "popup" (whose Send started it)
    property var send: ({ state: "", targetName: "", targetId: "", origin: "", files: [], message: "", startedAt: 0 })
    readonly property bool sending: send.state === "checking" || send.state === "sending"
    // The send's run (the runner's handle: the check, then `file cp`), null none
    property var _sendRun: null
    property int _sendToken: 0
    property real _progressAt: 0
    property var _outgoing: []
    // The bar popup's choice: the files picked for a device there, waiting for its Send
    // ({ targetId, paths }; TaildropRules.popupRow says what the row under the device shows)
    property var popupChoice: ({ targetId: "", paths: [] })
    // The chooser this client asked for (the shell's: one for the whole shell), null none;
    // an answer to an older one, or after the client stopped, is dropped
    property var _chooser: null
    property int _chooserToken: 0

    // Asks the shell's chooser (module API 1.17), then done(result) with the answer — only
    // while the client still runs and no newer chooser was asked for
    function _choose(options, done) {
        if (!running || typeof module?.chooseFiles !== "function")
            return false;
        const token = ++_chooserToken;
        const handle = module.chooseFiles(Object.assign({ startDirectory: String(client?.system?.home ?? "") }, options), result => {
            if (token !== _chooserToken)
                return;
            _chooser = null;
            if (running)
                done(result);
        });
        _chooser = handle?.open === true ? handle : null;
        return true;
    }

    // The popup's "Send file…": the files for this device, kept for its row's Send. Nothing
    // chosen (closed, the session locked, another chooser open): no row
    function chooseForPopup(deviceId) {
        const id = String(deviceId ?? "");
        return id !== "" && _choose({ mode: "openMany", title: "Files to send" }, result => {
            const paths = TaildropRules.chosenPaths(result);
            if (paths.length > 0)
                popupChoice = { targetId: id, paths: paths };
        });
    }

    function dropChoice() {
        popupChoice = { targetId: "", paths: [] };
    }

    // The popup row's Send: the choice becomes the send (one at a time); the row then shows
    // its progress and result
    function sendChoice() {
        if (!running || sending || popupChoice.paths.length === 0)
            return false;
        const request = { targetId: popupChoice.targetId, paths: popupChoice.paths.slice(), origin: "popup" };
        dropChoice();
        return sendFiles(request);
    }

    // The popup row's "×" on a result
    function dismissPopupSend(deviceId) {
        if (send.origin === "popup" && send.targetId === String(deviceId ?? ""))
            dismissSend();
    }

    // The page's "Choose files…", and a device row's "Send file…" there (that device as the
    // target): the files chosen join the list
    function chooseFor(deviceId) {
        if (deviceId !== undefined && deviceId !== null && String(deviceId) !== "")
            targetId = String(deviceId);
        return _choose({ mode: "openMany", title: "Files to send" }, result => {
            const paths = TaildropRules.chosenPaths(result);
            if (paths.length > 0)
                addPaths(paths);
        });
    }

    // The page's "Choose…" for the folder received files are saved to
    function chooseFolder() {
        return _choose({ mode: "folder", title: "Save received files to", startDirectory: folder }, result => {
            const path = TaildropRules.chosenFolder(result);
            if (path !== "")
                setFolder(path);
        });
    }

    function addPaths(input) {
        const parsed = TaildropRules.parsePaths(input);
        const next = chosen.slice();
        for (const path of parsed.paths)
            if (!next.includes(path) && next.length < TaildropRules.maxFiles)
                next.push(path);
        const dropped = parsed.paths.length - (next.length - chosen.length);
        inputProblems = parsed.problems.concat(dropped > 0 ? [{ text: "", problem: "at most " + TaildropRules.maxFiles + " files" }] : []);
        chosen = next;
        return parsed.paths.length;
    }

    function removePath(path) {
        chosen = chosen.filter(item => item !== path);
    }

    function clearPaths() {
        chosen = [];
        inputProblems = [];
    }

    function _setSend(changes) {
        send = Object.assign({}, send, changes);
    }

    // Sends files to a device, as this user (the operator); never a prompt. `request`
    // { targetId, paths, origin }: the popup's; none: the page's `chosen` to `targetId`
    function sendFiles(request) {
        if (!running || sending)
            return false;
        const origin = request?.origin === "popup" ? "popup" : "page";
        const wantedId = request ? String(request.targetId ?? "") : targetId;
        const wanted = request ? (Array.isArray(request.paths) ? request.paths : []) : chosen;
        const failed = message => _setSend({ state: "failed", message: message, files: [], origin: origin, targetId: wantedId, targetName: "" });
        if (!canSend) {
            failed("Needs the operator");
            return false;
        }
        const device = targets.find(item => item.id === wantedId) ?? null;
        if (device === null || !device.available) {
            failed(device === null ? "Choose a device" : "Device is offline");
            return false;
        }
        if (wanted.length === 0) {
            failed("Choose files");
            return false;
        }
        const paths = wanted.slice();
        const token = ++_sendToken;
        _setSend({ state: "checking", targetName: device.name, targetId: device.id, origin: origin, message: "", startedAt: Date.now(),
                   files: paths.map(path => ({ path: path, name: TaildropRules.displayName(TaildropRules.baseName(path)), size: 0, problem: "", sent: 0, percent: -1, outcome: "" })) });
        // Only for a clear message (the CLI opens the files itself, as this user)
        _sendRun = client._run(TaildropRules.checkArgv(paths), TaildropRules.checkLimitMs, result => {
            if (token !== _sendToken)
                return;
            _sendRun = null;
            const checked = TaildropRules.parseCheck(result.stdout, paths).map(file => Object.assign(file, { sent: 0, percent: -1, outcome: file.ok ? "" : "refused" }));
            const good = checked.filter(file => file.ok);
            if (good.length === 0) {
                _setSend({ state: "failed", files: checked, message: "Nothing to send" });
                return;
            }
            const command = TailscaleRules.commandFor("fileCp", TaildropRules.sendCommandArgs(good.map(file => file.path), device));
            if (!command.ok || client.tailscalePath === "") {
                _setSend({ state: "failed", files: checked, message: "Not sent" });
                return;
            }
            _setSend({ state: "sending", files: checked, startedAt: Date.now() });
            _progressAt = Date.now();
            _applyProgress();
            const seconds = client._limit("send");
            _sendRun = client._run(client._tailscaleArgv(command), seconds * 1000, sendResult => {
                if (token !== _sendToken)
                    return;
                _sendRun = null;
                _sendEnded(sendResult, seconds);
            });
            _idleCheck.start();
        });
        return true;
    }

    function _applyProgress() {
        if (send.state !== "sending" && send.state !== "done" && send.state !== "failed")
            return;
        const names = send.files.filter(file => file.ok).map(file => TaildropRules.baseName(file.path));
        const progress = TaildropRules.sendProgress(_outgoing, send.targetId, names, send.startedAt);
        let changed = false;
        const files = send.files.map(file => {
            const entry = progress[TaildropRules.baseName(file.path)];
            if (!file.ok || !entry)
                return file;
            const size = entry.size > 0 ? entry.size : file.size;
            const next = Object.assign({}, file, { sent: entry.sent, percent: TaildropRules.percent(entry.finished && entry.succeeded ? size : entry.sent, size),
                outcome: entry.finished ? (entry.succeeded ? "sent" : "failed") : (file.outcome === "" || file.outcome === "sending" ? "sending" : file.outcome) });
            changed = changed || JSON.stringify(next) !== JSON.stringify(file);
            return next;
        });
        if (changed) {
            if (send.state === "sending")
                _progressAt = Date.now();
            _setSend({ files: files });
        }
    }

    function _sendEnded(result, seconds) {
        _idleCheck.stop();
        if (send.state !== "sending")
            return;
        _applyProgress();
        if (result.ok) {
            _setSend({ state: "done", message: "",
                       files: send.files.map(file => file.ok ? Object.assign({}, file, { outcome: "sent", percent: 100, sent: file.size }) : file) });
            if (send.origin === "page")
                chosen = chosen.filter(path => !send.files.some(file => file.ok && file.path === path));
            return;
        }
        const error = result.timedOut === true ? { message: "Took too long, stopped" }
            : result.failedToStart === true || result.error !== "" ? { message: "Not sent" } : TaildropRules.sendError(result.code, result.stderr);
        _setSend({ state: "failed", message: error.message, files: _unsent() });
    }

    function _unsent() {
        return send.files.map(file => file.ok && file.outcome !== "sent" ? Object.assign({}, file, { outcome: file.outcome === "failed" ? "failed" : "not sent" }) : file);
    }

    // Kills the send (this user's own process) → true when one was running
    function _stopSend(state, message) {
        if (!sending)
            return false;
        _sendToken++;
        _idleCheck.stop();
        _sendRun?.cancel();
        _sendRun = null;
        _setSend({ state: state, message: message, files: _unsent() });
        return true;
    }

    function cancelSend() {
        return _stopSend("cancelled", "Cancelled");
    }

    function dismissSend() {
        if (!sending)
            _setSend({ state: "", files: [], message: "", origin: "" });
    }

    // No progress on the bus for idleLimitMs: stalled (only judged while the bus is up — without
    // it there is no progress to see, and the overall limit applies)
    property Timer _idleCheck: Timer {
        interval: Math.max(200, Math.min(5000, Math.floor(root.idleLimitMs / 4)))
        repeat: true
        onTriggered: {
            if (!root.sending) {
                stop();
                return;
            }
            if (root.client.streamUp && Date.now() - root._progressAt > root.idleLimitMs)
                root._stopSend("failed", "Stalled, stopped");
        }
    }

    // Disconnecting, logging out or switching accounts ends a send
    property Connections _operations: Connections {
        target: root.client
        function onOperationChanged() {
            if (["disconnect", "logout", "account", "login", "addAccount"].includes(root.client.operation))
                root._stopSend("cancelled", "Stopped: disconnected");
        }
    }

    // ---- The bus ----

    function _onBus(object) {
        const files = TaildropRules.notifyFiles(object);
        const wasWaiting = busWaiting;
        if (files.waiting === true)
            busWaiting = true;
        else if (!files.initial)
            busWaiting = false;
        if (files.outgoing !== null) {
            _outgoing = files.outgoing;
            _applyProgress();
        }
        let arrivedAny = false;
        if (files.incoming !== null) {
            incoming = files.incoming.filter(item => !item.done).map(item => ({ name: TaildropRules.displayName(item.name), size: item.size, received: item.received }));
            const found = TaildropRules.arrivals(_seen, files.incoming);
            _seen = found.seen;
            if (found.arrived.length > 0) {
                arrivedAny = true;
                _arrived(found.arrived.map(item => item.name));
            }
        }
        if (arrivedAny || busWaiting !== wasWaiting)
            refreshWaiting();
    }

    // A notification per arrival batch: the names (other people's) as plain text (module API
    // 1.12, format "plain": one line, never read as markup), separated by commas
    function _arrived(names) {
        const actions = canSave && !autoSave ? [{ id: "save", label: "Save", onTriggered: () => root.save("user") }] : [];
        notices = notices.concat([{ names: names, actions: actions.map(action => action.id) }]).slice(-20);
        module?.notify(names.length === 1 ? "File received" : names.length + " files received", {
            // One name per line again once the module asks for module API 1.28 (a plain body keeps its line breaks)
            body: names.map(name => String(name)).join(", "),
            actions: actions,
            format: "plain"
        });
        // A new arrival: everything may be tried again
        _autoTried = [];
        if (autoSave && canSave)
            _requestAutoSave();
    }

    // ---- The waiting list (operator only: GET files/, which lists and changes nothing) ----

    function refreshWaiting() {
        if (!running || !canSave) {
            waitingKnown = false;
            waiting = [];
            return;
        }
        if (_listing) {
            _listAgain = true;
            return;
        }
        _listing = true;
        // Not answered when the client stopped meanwhile (onRunningChanged resets `_listing`)
        client._run(TaildropRules.listArgv(client.curlPath, client.socketPath), client._limitMs("read"), result => {
            _listing = false;
            const parsed = result.ok ? TaildropRules.parseWaiting(result.stdout) : { ok: false, files: [] };
            waitingKnown = parsed.ok;
            waiting = parsed.files;
            if (_listAgain) {
                _listAgain = false;
                refreshWaiting();
                return;
            }
            // Once at start-up: files that waited before
            if (parsed.ok && !_autoStartChecked) {
                _autoStartChecked = true;
                if (autoSave && parsed.files.length > 0)
                    _autoPending = true;
            }
            // Consumes a pending request (made by an arrival); never makes one
            _runPendingAutoSave();
        });
    }

    // A request is run on a fresh listing (the arrival's file may not be in the last one)
    function _requestAutoSave() {
        _autoPending = true;
        refreshWaiting();
    }

    // Runs the pending auto-save when nothing else runs; else it waits for the change to end
    function _runPendingAutoSave() {
        if (!_autoPending || !autoSave || !canSave || !waitingKnown || _listing || client.busy)
            return;
        _autoPending = false;
        const files = waiting.filter(file => !_autoTried.includes(file.name));
        if (files.length > 0)
            _save(files, autoConflict, true);
    }

    property Connections _busy: Connections {
        target: root.client
        function onBusyChanged() {
            if (!root.client.busy)
                root._runPendingAutoSave();
        }
    }

    // Saves every waiting file into `folder` (the operator, as the user, no prompt)
    function save(origin) {
        saveError = "";
        if (!running)
            return false;
        if (!canSave) {
            saveError = isOperator ? "Needs curl" : "Needs the operator";
            return false;
        }
        if (client.busy) {
            saveError = "Another Tailscale change is running.";
            return false;
        }
        if (!waitingKnown || waiting.length === 0) {
            saveError = waitingKnown ? "Nothing waiting" : "Not read yet";
            refreshWaiting();
            return false;
        }
        // A manual Save: everything may be tried again
        _autoTried = [];
        return _save(waiting, conflict, false);
    }

    function _save(files, policy, automatic) {
        const seconds = client._limit("save");
        const prepared = TaildropRules.saveArgv({ curl: client.curlPath, socket: client.socketPath, timeout: client.timeoutPath, seconds: seconds,
            policy: policy, folder: folder, files: files });
        if (!prepared.ok) {
            saveError = prepared.error;
            if (automatic)
                _autoTried = _autoTried.concat(files.map(file => file.name));
            return false;
        }
        const target = folder;
        const sentAs = {};
        for (const file of files)
            sentAs[file.saveAs] = file;
        if (automatic)
            autoRuns++;
        // Two requests a file, each under the script's own limit, and the script's start. The
        // runner's limit is at most a day (TailscaleRules.runLimits, maxRunMs): a save of more
        // files than fit in a day (some 70 at the default 600 s each) is ended there, and the
        // files it had not reached stay waiting in Tailscale's inbox for the next Save
        const limitMs = (files.length * 2 + 1) * (seconds + 10) * 1000;
        const started = client._runLocked("taildrop-save", prepared.argv, limitMs, result => {
            const parsed = TaildropRules.parseSave(result.stdout, target);
            const left = [];
            for (const item of parsed.results) {
                const file = Object.prototype.hasOwnProperty.call(sentAs, item.rawName) ? sentAs[item.rawName] : null;
                if (file !== null) {
                    item.name = file.shown;
                    if (item.outcome !== "saved")
                        left.push(file.name);
                }
            }
            saveError = parsed.error !== "" ? parsed.error : (!result.ok && parsed.results.length === 0 ? "Saving failed" : "");
            // A folder error leaves every file: one message, no retry until something changes
            if (automatic)
                _autoTried = _autoTried.concat(parsed.error !== "" ? files.map(file => file.name) : left);
            _addSaved(parsed.results);
            refreshWaiting();
        });
        if (!started) {
            saveError = "Another Tailscale change is running.";
            if (automatic)
                _autoPending = true;
        }
        return started;
    }

    // Newest first; a file left again replaces its older line (no repeated "left waiting")
    function _addSaved(results) {
        const keyOf = item => item.outcome + "\n" + item.name;
        const fresh = results.filter(item => item.outcome !== "saved").map(keyOf);
        saved = results.concat(saved.filter(item => item.outcome === "saved" || !fresh.includes(keyOf(item)))).slice(0, 20);
    }

    // The folder in the file manager — checked to be a directory first (as this user)
    function openFolder() {
        const url = TaildropRules.folderUrl(folder);
        if (url === "" || !running)
            return false;
        const path = folder;
        client._run(["test", "-d", path], TaildropRules.checkLimitMs, result => {
            if (result.ok && path === folder)
                client.openFolder(url);
            else if (!result.ok)
                saveError = "Folder not found";
        });
        return true;
    }

    // ---- Start and stop ----

    onRunningChanged: {
        if (running) {
            refreshWaiting();
        } else {
            _listing = false;
            _listAgain = false;
            _autoPending = false;
            _autoStartChecked = false;
            _stopSend("cancelled", "Stopped");
            _chooserToken++;
            _chooser?.cancel();
            _chooser = null;
            dropChoice();
        }
    }
    onCanSaveChanged: refreshWaiting()
    Component.onDestruction: {
        _stopSend("cancelled", "Stopped");
        _chooserToken++;
        _chooser?.cancel();
    }
}
