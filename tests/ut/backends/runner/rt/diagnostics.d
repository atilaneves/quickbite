module ut.backends.runner.rt.diagnostics;


import ut.backends;


// Compiled `assert(0)` in a non-unittest function raises the plain _d_assert
// message "Assertion failure" (checkaction=context adds no operands for a
// literal condition); "`assert(0)` failed" is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("voidFunctionOops." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {
                assert(0);
            }

            unittest {
                foo;
            }
        }).shouldThrowWithMessage("Assertion failure");
    }
}

// Compiled `assert(false)` in a unittest body raises the plain _d_unittest
// hook message "unittest failure"; "`assert(false)` failed" is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("literalFalseAssertionMatchesDmd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(false);
            }
        }).shouldThrowWithMessage("unittest failure");
    }
}
