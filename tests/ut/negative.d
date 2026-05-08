module ut.negative;

import quickbite: ExecutorBackend, runTests;
import std.conv: text;
import std.traits: EnumMembers;
import unit_threaded;

static foreach (backend; EnumMembers!ExecutorBackend) {
    // CTFE supports local variable declarations in functions — no error.
    static if (backend != ExecutorBackend.dmdCtfe) {
        @(backend.text ~ ".voidFunction")
        unittest {
            runTests(q{
                void foo() {
                    int value;
                }

                unittest {
                    foo;
                }
            }, backend).shouldThrowWithMessage("Unsupported expression: declaration");
        }

        @(backend.text ~ ".multiStatementBody")
        unittest {
            runTests(q{
                int answer() {
                    int value;
                    return value;
                }

                unittest {
                    assert(answer == 0);
                }
            }, backend).shouldThrowWithMessage("Unsupported expression: declaration");
        }

        @(backend.text ~ ".nonLiteralReturn")
        unittest {
            runTests(q{
                int value;

                int answer() {
                    return value;
                }

                unittest {
                    assert(answer == 0);
                }
            }, backend).shouldThrowWithMessage("Unsupported expression: value");
        }

        @(backend.text ~ ".unsupportedAssert")
        unittest {
            runTests(q{
                unittest {
                    int value;
                    assert(value);
                }
            }, backend).shouldThrowWithMessage("Unsupported expression: declaration");
        }

        @(backend.text ~ ".outParameter")
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
            }, backend).shouldThrowWithMessage("Unsupported function parameters.");
        }

        @(backend.text ~ ".multipleOutParameters")
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
            }, backend).shouldThrowWithMessage("Unsupported function parameters.");
        }

        // CTFE silently tolerates extern functions it cannot interpret.
        @(backend.text ~ ".externalCallee")
        unittest {
            runTests(q{
                extern int externalFunc();

                unittest {
                    externalFunc;
                }
            }, backend).shouldThrowWithMessage("No function body to execute.");
        }

        @(backend.text ~ ".externalCalleeWithArg")
        unittest {
            runTests(q{
                extern int externalFunc(int value);

                unittest {
                    externalFunc(42);
                }
            }, backend).shouldThrowWithMessage("No function body to execute.");
        }

        @(backend.text ~ ".externalCalleeArgNotEvaluated")
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
            }, backend).shouldThrowWithMessage("No function body to execute.");
        }
    }

    @(backend.text ~ ".divisionByZero")
    unittest {
        static if (backend == ExecutorBackend.dmdCtfe)
            const msg = "Unittest assertion failed.";
        else
            const msg = "Integer division by zero.";

        runTests(q{
            int answer() {
                int zero = 0;
                return 42 / zero;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend).shouldThrowWithMessage(msg);
    }

    @(backend.text ~ ".divisionByZeroCall")
    unittest {
        static if (backend == ExecutorBackend.dmdCtfe)
            const msg = "Unittest assertion failed.";
        else
            const msg = "Integer division by zero.";

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
        }, backend).shouldThrowWithMessage(msg);
    }

    @(backend.text ~ ".moduloByZero")
    unittest {
        static if (backend == ExecutorBackend.dmdCtfe)
            const msg = "Unittest assertion failed.";
        else
            const msg = "Integer modulo by zero.";

        runTests(q{
            int answer() {
                int zero = 0;
                return 42 % zero;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend).shouldThrowWithMessage(msg);
    }

    @(backend.text ~ ".moduloByZeroCall")
    unittest {
        static if (backend == ExecutorBackend.dmdCtfe)
            const msg = "Unittest assertion failed.";
        else
            const msg = "Integer modulo by zero.";

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
        }, backend).shouldThrowWithMessage(msg);
    }
}
