module ut.backends.runner.rt.control_flow;


import ut.backends;


// Compiled `assert(false)` in a unittest body raises the plain _d_unittest
// hook message "unittest failure"; "`assert(false)` failed" is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("function.structMethodReturnDoesNotSkipCallerStatements." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Worker {
                void stop() {
                    return;
                }
            }

            unittest {
                Worker worker;
                worker.stop;
                assert(false);
            }
        }).shouldThrowWithMessage("unittest failure");
    }
}
