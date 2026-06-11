module ut.backends.runner.rt.exceptions;


import ut.backends;


// Compiled code (dmd -unittest -checkaction=context) reports the exception's
// own message; the "uncaught CTFE exception" wrapper is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("exception.uncaughtThrowReportsMessage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                throw new Exception("boom");
            }
        }).shouldThrowWithMessage("boom");
    }
}

// Compiled code reports the exception's own message (see above).
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("exception.uncaughtThrowPreservesExceptionMessage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                throw new Exception("domain failure");
            }
        }).shouldThrowWithMessage("domain failure");
    }
}

// Compiled `assert(false)` in a unittest body raises the plain _d_unittest
// hook message "unittest failure"; "`assert(false)` failed" is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("exception.catchExceptionDoesNotCatchAssertFailure." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                try {
                    assert(false);
                } catch (Exception) {
                }
            }
        }).shouldThrowWithMessage("unittest failure");
    }
}
