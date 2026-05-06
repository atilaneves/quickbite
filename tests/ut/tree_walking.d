module ut.tree_walking;

import quickbite: ExecutorBackend, runTests;
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

@("treeWalking.publicApi")
unittest {
    q{
        int answer() {
            return 42;
        }

        unittest {
            assert(answer == 42);
        }
    }.runTests(ExecutorBackend.treeWalking);
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
    });
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
    });
}

@("treeWalking.refParameter")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int setTo43(ref int value) {
            value = 43;
            return 0;
        }

        unittest {
            int value = 42;
            setTo43(value);
            assert(value == 43);
        }
    }).shouldThrowWithMessage("Unsupported parameter storage class.");
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
    });
}

@("treeWalking.if_")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int one() { return 1; }

        int answer() {
            if (one == 1)
                return 42;
            return 0;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.ifElse")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int one() { return 1; }

        int answer() {
            if (one == 2)
                return 0;
            else
                return 42;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.ifFalseNoElse")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int one() { return 1; }

        int answer() {
            if (one == 2)
                return 0;
            return 42;
        }

        unittest {
            assert(answer == 42);
        }
    });
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

@("treeWalking.struct_")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        struct Point {
            int x;
            int y;
        }

        int answer() {
            Point p;
            p.x = 21;
            p.y = 21;
            return p.x + p.y;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.structFieldDefaultsToZero")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        struct Point {
            int x;
            int y;
        }

        int answer() {
            Point p;
            p.x = 42;
            return p.x + p.y;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.structPassedToFunction")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        struct Point {
            int x;
            int y;
        }

        int sum(Point p) {
            return p.x + p.y;
        }

        unittest {
            Point p;
            p.x = 21;
            p.y = 21;
            assert(sum(p) == 42);
        }
    }).shouldThrowWithMessage("Unsupported expression: p");
}

@("treeWalking.notEqual")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three != 5);
        }
    });
}

@("treeWalking.notEqualFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three != 3);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.lessThan")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three < 5);
        }
    });
}

@("treeWalking.lessThanFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five < 3);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.lessThanFailsAtBoundary")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five < 5);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.greaterThan")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five > 3);
        }
    });
}

@("treeWalking.greaterThanFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three > 5);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.greaterThanFailsAtBoundary")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five > 5);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.lessOrEqual")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three <= 5);
            assert(three <= 3);
        }
    });
}

@("treeWalking.lessOrEqualFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five <= 3);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.greaterOrEqual")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int five() { return 5; }

        unittest {
            assert(five >= 3);
            assert(five >= 5);
        }
    });
}

@("treeWalking.greaterOrEqualFails")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int three() { return 3; }

        unittest {
            assert(three >= 5);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
}

@("treeWalking.addition")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int forty() { return 40; }

        int answer() {
            return forty + 2;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.subtraction")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int fifty() { return 50; }

        int answer() {
            return fifty - 8;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.multiplication")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int six() { return 6; }

        int answer() {
            return six * 7;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.division")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int eightyfour() { return 84; }

        int answer() {
            return eightyfour / 2;
        }

        unittest {
            assert(answer == 42);
        }
    });
}

@("treeWalking.modulo")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        int fortyfive() { return 45; }

        int answer() {
            return fortyfive % 3;
        }

        unittest {
            assert(answer == 0);
        }
    });
}

@("treeWalking.rightShift")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        uint input() { return 0b10101000; }

        unittest {
            assert((input >> 2) == 0b00101010);
        }
    });
}

@("treeWalking.leftShift")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        uint input() { return 0b00101010; }

        unittest {
            assert((input << 2) == 0b10101000);
        }
    });
}

@("treeWalking.bitwiseOrAssign")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            // `auto` is intentional: compound assignment needs a mutable local.
            auto value = 0b00101000u;
            value |= 0b10000000u;
            assert(value == 0b10101000u);
        }
    });
}

@("treeWalking.arrayLength")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [1, 2, 3];
            assert(arr.length == 3);
        }
    });
}

@("treeWalking.emptyArrayLength")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [];
            assert(arr.length == 0);
        }
    });
}

@("treeWalking.arrayIndexRead")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [10, 20, 30];
            assert(arr[1] == 20);
        }
    });
}

@("treeWalking.arrayIndexWrite")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr = [10, 20, 30];
            arr[1] = 42;
            assert(arr[1] == 42);
        }
    });
}

@("treeWalking.arrayAppend")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] arr;
            arr ~= cast(ubyte) 42;
            assert(arr.length == 1);
            assert(arr[0] == 42);
        }
    });
}

@("treeWalking.castUbyteTruncates")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            int value = 258;
            assert(cast(ubyte) value == 2);
        }
    });
}

@("treeWalking.ubyteLocalTruncatesOnStore")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            int source = 258;
            ubyte value = cast(ubyte) source;
            assert(value == 2);
        }
    });
}

@("treeWalking.ubyteArrayLiteralTruncatesElements")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            int value = 258;
            ubyte[] arr = [cast(ubyte) value];
            assert(arr[0] == 2);
        }
    });
}

@("treeWalking.arrayEqualTrue")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] a = [1, 2, 3];
            ubyte[] b = [1, 2, 3];
            assert(a[] == b[]);
        }
    });
}

@("treeWalking.arrayEqualFalse")
unittest {
    (new TreeWalkingExecutor).runTests(q{
        unittest {
            ubyte[] a = [1, 2, 3];
            ubyte[] b = [1, 2, 4];
            assert(a[] == b[]);
        }
    }).shouldThrowWithMessage("Unittest assertion failed.");
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
