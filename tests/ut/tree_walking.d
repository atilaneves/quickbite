module ut.tree_walking;

import quickbite.backends.tree_walking: TreeWalkingExecutor;
import unit_threaded;

@("treeWalking.voidFunctionExplicitReturn")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        void foo() {
            return;
        }

        unittest {
            foo;
        }
    });
}

@("treeWalking.externalCallee")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        extern int externalFunc();

        unittest {
            externalFunc;
        }
    }).shouldThrowWithMessage("No function body to execute.");
}

@("treeWalking.externalCalleeWithArg")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        extern int externalFunc(int value);

        unittest {
            externalFunc(42);
        }
    }).shouldThrowWithMessage("No function body to execute.");
}

@("treeWalking.externalCalleeArgNotEvaluated")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        extern int externalFunc(int value);

        int boom() {
            assert(false);
            return 0;
        }

        unittest {
            externalFunc(boom);
        }
    }).shouldThrowWithMessage("No function body to execute.");
}

@("treeWalking.while_")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int i = 0;
            int result = 0;
            while (i < 6) {
                result = result + 7;
                i = i + 1;
            }
            return result;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.whileNeverRuns")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int i = 0;
            while (i > 0) {
                i = i + 1;
            }
            return 42;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.whileRunsOnce")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int i = 0;
            int result = 0;
            while (i < 1) {
                result = 42;
                i = i + 1;
            }
            return result;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.structMethodPostIncrementsSizeTField")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        struct Cursor {
            size_t pos;

            size_t next() {
                return pos++;
            }
        }

        unittest {
            Cursor cursor;
            assert(cursor.next == 0);
            assert(cursor.pos == 1);
        }
    });
}

@("treeWalking.structMethodReadsArrayFieldAtPostIncrementedField")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        struct Reader {
            ubyte[] bytes;
            size_t pos;

            ubyte next() {
                return bytes[pos++];
            }
        }

        unittest {
            Reader reader;
            reader.bytes = [42];
            assert(reader.next == 42);
            assert(reader.pos == 1);
        }
    });
}

@("treeWalking.foreachArray")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [1, 2, 3];
            int sum = 0;
            foreach (x; arr)
                sum = sum + x;
            assert(sum == 6);
        }
    });
}

@("treeWalking.foreachEmptyArray")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [];
            int count = 0;
            foreach (x; arr)
                count = count + 1;
            assert(count == 0);
        }
    });
}
