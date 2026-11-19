.pragma library
// The suites whose clients run as administrator through the module's one handle
// (ScenarioHandle: the shell's queue). The shell runs a module's suites side by side, and
// the shell's queue, its test polkit agent and the module's on/off state are one for all of
// them: TailscaleModuleTest changes those (another agent, the module turned off, which ends
// every run of the module in the queue) only once these suites are done. One instance for
// every file that imports it (.pragma library).

var suites = [];

function register(suite) {
    if (suites.indexOf(suite) < 0)
        suites.push(suite);
}

// Every registered suite has finished (or is gone)
function allDone() {
    return suites.every(function (suite) {
        try {
            return suite.done === true;
        } catch (error) {
            return true;
        }
    });
}
