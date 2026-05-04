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
