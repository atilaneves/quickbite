module ut.backends.tree;


import ut.backends;


@("runTests.emptyUnittestCompletes")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        unittest {
        }
    }, ExecutorBackend.treeWalking);
}

@("runTests.failingUnittestThrows")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        unittest {
            int value = 1;
            assert(value == 2);
        }
    }, ExecutorBackend.treeWalking).shouldThrowWithMessage("1 != 2");
}

@("runTests.failingUnittestAfterAssignmentThrows")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        unittest {
            int value = 1;
            value = value + 1;
            assert(value == 3);
        }
    }, ExecutorBackend.treeWalking).shouldThrowWithMessage("2 != 3");
}

@("runTests.unsupportedArrayExpressionReportsExpressionKind")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        int[] values() {
            int first = 40;
            int second = first + 2;
            return [first, second];
        }

        unittest {
            assert(values[0] == 40);
        }
    }, ExecutorBackend.treeWalking).shouldThrowWithMessage(
        "Unsupported array expression: call",
    );
}
