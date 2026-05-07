module ut.negative;

import quickbite: ExecutorBackend, runTests;
import std.conv: to;
import std.traits: EnumMembers;
import unit_threaded;

static foreach (b; EnumMembers!ExecutorBackend) {
    @(b.to!string ~ ".voidFunction")
    unittest {
        runTests(q{
            void foo() {
                int value;
            }

            unittest {
                foo;
            }
        }, b).shouldThrowWithMessage("Unsupported expression: declaration");
    }

    @(b.to!string ~ ".multiStatementBody")
    unittest {
        runTests(q{
            int answer() {
                int value;
                return value;
            }

            unittest {
                assert(answer == 0);
            }
        }, b).shouldThrowWithMessage("Unsupported expression: declaration");
    }

    @(b.to!string ~ ".nonLiteralReturn")
    unittest {
        runTests(q{
            int value;

            int answer() {
                return value;
            }

            unittest {
                assert(answer == 0);
            }
        }, b).shouldThrowWithMessage("Unsupported expression: value");
    }

    @(b.to!string ~ ".unsupportedAssert")
    unittest {
        runTests(q{
            unittest {
                int value;
                assert(value);
            }
        }, b).shouldThrowWithMessage("Unsupported expression: declaration");
    }

    @(b.to!string ~ ".outParameter")
    unittest {
        runTests(q{
            void setAnswer(out int value) {
                value = 42;
            }

            unittest {
                int value = 0;
                setAnswer(value);
                assert(value == 42);
            }
        }, b).shouldThrowWithMessage("Unsupported function parameters.");
    }

    @(b.to!string ~ ".multipleOutParameters")
    unittest {
        runTests(q{
            void add(int left, out int right) {
                right = left + 2;
            }

            unittest {
                int value = 0;
                add(40, value);
                assert(value == 42);
            }
        }, b).shouldThrowWithMessage("Unsupported function parameters.");
    }

    @(b.to!string ~ ".externalCallee")
    unittest {
        runTests(q{
            extern int externalFunc();

            unittest {
                externalFunc;
            }
        }, b).shouldThrowWithMessage("No function body to execute.");
    }

    @(b.to!string ~ ".externalCalleeWithArg")
    unittest {
        runTests(q{
            extern int externalFunc(int value);

            unittest {
                externalFunc(42);
            }
        }, b).shouldThrowWithMessage("No function body to execute.");
    }

    @(b.to!string ~ ".externalCalleeArgNotEvaluated")
    unittest {
        runTests(q{
            extern int externalFunc(int value);

            int boom() {
                assert(false);
                return 0;
            }

            unittest {
                externalFunc(boom);
            }
        }, b).shouldThrowWithMessage("No function body to execute.");
    }

    @(b.to!string ~ ".divisionByZero")
    unittest {
        runTests(q{
            int answer() {
                int zero = 0;
                return 42 / zero;
            }

            unittest {
                assert(answer == 42);
            }
        }, b).shouldThrowWithMessage("Integer division by zero.");
    }

    @(b.to!string ~ ".divisionByZeroCall")
    unittest {
        runTests(q{
            int zero() {
                return 0;
            }

            int answer() {
                return 42 / zero;
            }

            unittest {
                assert(answer == 42);
            }
        }, b).shouldThrowWithMessage("Integer division by zero.");
    }

    @(b.to!string ~ ".moduloByZero")
    unittest {
        runTests(q{
            int answer() {
                int zero = 0;
                return 42 % zero;
            }

            unittest {
                assert(answer == 42);
            }
        }, b).shouldThrowWithMessage("Integer modulo by zero.");
    }

    @(b.to!string ~ ".moduloByZeroCall")
    unittest {
        runTests(q{
            int zero() {
                return 0;
            }

            int answer() {
                return 42 % zero;
            }

            unittest {
                assert(answer == 42);
            }
        }, b).shouldThrowWithMessage("Integer modulo by zero.");
    }
}

@("ir.ifBodyAssignment")
unittest {
    q{
        int answer(int value) {
            if (value == 1)
                value = 2;

            return value;
        }

        unittest {
            assert(answer(1) == 2);
        }
    }.runTests(ExecutorBackend.ir).shouldThrowWithMessage("Unsupported if-branch: expected return");
}

