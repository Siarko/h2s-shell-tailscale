//@ pragma UseQApplication
import QtQuick
import Quickshell
import Quickshell.Io
import qs.tests

// The stand-in for the shell's tests-modules.qml, used by tests/run.sh while the shell
// checkout it runs against has no tests/run-modules.sh yet. tests/run.sh copies the shell's
// tree to a private directory and puts this file at its root, so `qs.*` is that shell
// (the suites extend its TestCase through `import qs.tests`) and the module directory
// (H2S_TEST_MODULE_DIR, canonical) is loaded by file:// URL as the module host will load it:
// its qmldir makes its singletons real singletons, shared by its suites.
//
// What it does NOT do (the real host does): check the manifest beyond its "tests" list,
// check the API version, imports or required programs, create the module's `main`. It
// prints "MODULE-SUITES-EXPECTED: <n>" before creating any suite, as tests-modules.qml
// does, so the runner can tell a crash from a pass.
QtObject {
    id: root

    property var _suites: []
    property int _waited: 0

    property FileView _manifest: FileView {
        blockLoading: true
    }

    function _fail(message) {
        console.error("  FAIL: " + message);
    }

    property Timer _clock: Timer {
        interval: 50
        repeat: true
        onTriggered: {
            root._waited += interval;
            const pending = root._suites.filter(suite => suite.asynchronous && !suite.done);
            if (pending.length > 0 && root._waited < 20000)
                return;
            pending.forEach(suite => {
                suite.fail("timed out");
                suite.finish();
            });
            Qt.quit();
        }
    }

    Component.onCompleted: {
        console.log("\n=== module (harness) ===");
        const directory = Quickshell.env("H2S_TEST_MODULE_DIR") ?? "";
        if (typeof directory !== "string" || !directory.startsWith("/")) {
            _fail("H2S_TEST_MODULE_DIR is not an absolute directory");
            console.log("MODULE-SUITES-EXPECTED: 1");
            _clock.start();
            return;
        }
        _manifest.path = directory + "/module.json";
        let manifest = null;
        try {
            manifest = JSON.parse(_manifest.text());
        } catch (error) {
            _fail("module.json does not parse: " + error);
        }
        const tests = Array.isArray(manifest?.tests) ? manifest.tests.filter(test => typeof test === "string") : [];
        if (tests.length === 0)
            _fail("the module lists no test suites (\"tests\" in its module.json)");
        console.log("  module " + (manifest?.id ?? "?") + " " + (manifest?.version ?? "?") + " (" + directory + ")");
        console.log("MODULE-SUITES-EXPECTED: " + tests.length);
        const suites = [];
        for (const test of tests) {
            const component = Qt.createComponent("file://" + directory + "/" + test, Component.PreferSynchronous);
            if (component.status !== Component.Ready) {
                _fail(test + " does not compile: " + component.errorString().trim());
                continue;
            }
            let suite = null;
            try {
                suite = component.createObject(root);
            } catch (error) {
                _fail(test + " threw while being created: " + error);
            }
            if (!suite) {
                _fail(test + " could not be created");
                continue;
            }
            suites.push(suite);
        }
        _suites = suites;
        _clock.start();
    }
}
