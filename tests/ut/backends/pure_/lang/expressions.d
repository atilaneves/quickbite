module ut.backends.pure_.lang.expressions;


import ut.backends;


static foreach (backend; backends) {
    @("intAddition." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int one() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the addition before the backend sees it.
                return one + 41;
            }

            unittest {
                assert(answer == 42);
            }
        });
    }

    @("intAdditionFailureMessage." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int one() {
                return 1;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the addition before the backend sees it.
                return one + 41;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("intAdditionFailureMessageUsesRuntimeValue." ~ backend.stringof)
    unittest {
        newBackend!backend.runTests(q{
            int two() {
                return 2;
            }

            int answer() {
                // Keep one operand runtime-shaped so DMD does not constant-fold
                // the addition before the backend sees it.
                return two + 5;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}
