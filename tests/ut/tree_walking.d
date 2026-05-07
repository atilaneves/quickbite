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

