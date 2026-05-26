module ut.backends.deps.unit_threaded;


import ut.backends;


private:

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
