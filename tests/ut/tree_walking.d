module ut.tree_walking;

import quickbite.backends.tree_walking: TreeWalkingExecutor;
import unit_threaded;

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
