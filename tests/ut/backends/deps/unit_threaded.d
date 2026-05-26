module ut.backends.deps.unit_threaded;


import ut.backends;


private:

@("shouldThrowFailsWhenExpressionDoesNotThrow")
unittest {
    import ut.dub_paths: dubImportPaths;

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(q{
                import unit_threaded;

                unittest {
                    shouldThrow(1);
                }
            }, dubImportPaths, backend).shouldThrow;
        }
    }
}

@("shouldThrowWithMessageChecksMessage")
unittest {
    import ut.dub_paths: dubImportPaths;

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(q{
                import unit_threaded;

                void throwActual() {
                    throw new Exception("actual");
                }

                unittest {
                    shouldThrowWithMessage(throwActual, "expected");
                }
            }, dubImportPaths, backend).shouldThrow;
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
    }, dubImportPaths, ExecutorBackend.treeWalkingOld).shouldThrowWithMessage(
        "Property failed. Seed: 1. Input: 1",
    );
}
