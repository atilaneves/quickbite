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
}

@("ir.outParameter")
unittest {
    q{
        void setAnswer(out int value) {
            value = 42;
        }

        unittest {
            int value = 0;
            setAnswer(value);
            assert(value == 42);
        }
    }.runTests(ExecutorBackend.ir).shouldThrowWithMessage("Unsupported function parameters.");
}

@("ir.multipleOutParameters")
unittest {
    q{
        void add(int left, out int right) {
            right = left + 2;
        }

        unittest {
            int value = 0;
            add(40, value);
            assert(value == 42);
        }
    }.runTests(ExecutorBackend.ir).shouldThrowWithMessage("Unsupported function parameters.");
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

@("ir.divisionByZero")
unittest {
    q{
        int answer() {
            int zero = 0;
            return 42 / zero;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests(ExecutorBackend.ir).shouldThrowWithMessage("Integer division by zero.");
}

@("ir.divisionByZeroCall")
unittest {
    q{
        int zero() {
            return 0;
        }

        int answer() {
            return 42 / zero;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests(ExecutorBackend.ir).shouldThrowWithMessage("Integer division by zero.");
}

@("ir.moduloByZero")
unittest {
    q{
        int answer() {
            int zero = 0;
            return 42 % zero;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests(ExecutorBackend.ir).shouldThrowWithMessage("Integer modulo by zero.");
}

@("ir.moduloByZeroCall")
unittest {
    q{
        int zero() {
            return 0;
        }

        int answer() {
            return 42 % zero;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests(ExecutorBackend.ir).shouldThrowWithMessage("Integer modulo by zero.");
}
