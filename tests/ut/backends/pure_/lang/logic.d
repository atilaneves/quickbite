module ut.backends.pure_.lang.logic;


import ut.backends;


private:

static foreach (backend; backends) {
    @("assertNonzeroIntCondition." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int mask() {
                return 2;
            }

            unittest {
                assert(0x28 | mask);
            }
        });
    }

    @("assertNonzeroIntConditionFailureMessage.0." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int mask() {
                return 2;
            }

            unittest {
                assert((0x28 | mask) == 0x2b);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("assertNonzeroIntConditionFailureMessage.1." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int mask() {
                return 1;
            }

            unittest {
                assert((0x28 | mask) == 0x2a);
            }
        }).shouldThrowWithMessage("41 != 42");
    }
}
