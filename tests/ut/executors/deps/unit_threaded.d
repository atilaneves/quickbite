module ut.executors.deps.unit_threaded;


import ut.executors;


private:

@("shouldThrowFailsWhenExpressionDoesNotThrow")
unittest {
    import ut.dub_paths: dubImportPaths;

    static foreach (executorName; matureExecutorNames) {
        {
            runTests(q{
                import unit_threaded;

                unittest {
                    shouldThrow(1);
                }
            }, dubImportPaths, executorName).shouldThrow;
        }
    }
}

@("shouldThrowWithMessageChecksMessage")
unittest {
    import ut.dub_paths: dubImportPaths;

    static foreach (executorName; matureExecutorNames) {
        {
            runTests(q{
                import unit_threaded;

                void throwActual() {
                    throw new Exception("actual");
                }

                unittest {
                    shouldThrowWithMessage(throwActual, "expected");
                }
            }, dubImportPaths, executorName).shouldThrow;
        }
    }
}

@("unitThreadedCheckRunsPredicate.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    runTests(q{
        import unit_threaded;

        unittest {
            check!((int value) => false);
        }
    }, dubImportPaths, ExecutorName.treeWalkingOld).shouldThrowWithMessage(
        "Property failed. Seed: 1. Input: 1",
    );
}
