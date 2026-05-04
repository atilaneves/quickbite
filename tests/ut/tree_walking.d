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
