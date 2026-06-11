module ut.backends.runner.rt.logic;


import ut.backends;


// Compiled `assert(0)` in a non-unittest function raises the plain _d_assert
// message "Assertion failure"; "`assert(0)` failed" is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("logicalAndCallShortCircuitFailureMessage.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            bool isReady() {
                return true;
            }

            bool failIfCalled() {
                assert(0);
                return true;
            }

            unittest {
                assert(!(isReady && failIfCalled));
            }
        }).shouldThrowWithMessage("Assertion failure");
    }
}
