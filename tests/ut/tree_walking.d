module ut.tree_walking;


import quickbite.backends.tree_walking: TreeWalkingExecutor;
import unit_threaded;


@("treeWalking.ok")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.localIntReturn")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int value = 42;
            return value;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.localIntReturnOops")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int value = 42;
            return value;
        }

        unittest {
            assert(answer == 43);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.oops")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer == 43);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.voidFunction")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        void foo() {}

        unittest {
            foo;
        }
    }).shouldThrowWithMessage("Unsupported function body.");
}

@("treeWalking.voidFunctionExplicitReturn")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        void foo() {
            return;
        }

        unittest {
            foo;
        }
    }).shouldThrowWithMessage("Unsupported function body.");
}

@("treeWalking.externalCallee")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        extern int externalFunc();

        unittest {
            externalFunc;
        }
    }).shouldThrowWithMessage("Unsupported function body.");
}

@("treeWalking.uninitializedDecl")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer() {
            int value;
            return value;
        }

        unittest {
            assert(answer == 0);
        }
    }).shouldThrowWithMessage("Unsupported expression: declaration");
}

@("treeWalking.nonLiteralReturn")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int value;

        int answer() {
            return value;
        }

        unittest {
            assert(answer == 0);
        }
    }).shouldThrowWithMessage("Unsupported expression: value");
}

@("treeWalking.callWithArgs")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int answer(int value) {
            return value;
        }

        unittest {
            assert(answer(42) == 42);
        }
    }).shouldThrowWithMessage("Unsupported call.");
}
