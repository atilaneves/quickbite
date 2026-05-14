module quickbite;

private:

public enum ExecutorBackend {
    ir,
    treeWalking,
    dmdCtfe,
}

public void runTests(
    in string source,
    in ExecutorBackend backend = ExecutorBackend.ir,
) {
    final switch (backend) {
        case ExecutorBackend.ir:
            import quickbite.backends.ir: IrExecutor;
            (new IrExecutor).runTests(source);
            return;
        case ExecutorBackend.treeWalking:
            import quickbite.backends.tree_walking: TreeWalkingExecutor;
            (new TreeWalkingExecutor).runTests(source);
            return;
        case ExecutorBackend.dmdCtfe:
            import quickbite.backends.dmd_ctfe: DmdCtfe;
            (new DmdCtfe).runTests(source);
            return;
    }
}

public void runTestsFromFile(
    in string filePath,
    in string[] importPaths,
    in ExecutorBackend backend = ExecutorBackend.ir,
) {
    import std.file: readText;
    runTests(filePath.readText, importPaths, backend);
}

public void runTests(
    in string source,
    in string[] importPaths,
    in ExecutorBackend backend = ExecutorBackend.ir,
) {
    final switch (backend) {
        case ExecutorBackend.ir:
            import quickbite.backends.ir: IrExecutor;
            (new IrExecutor).runTests(source, importPaths);
            return;
        case ExecutorBackend.treeWalking:
            import quickbite.backends.tree_walking: TreeWalkingExecutor;
            (new TreeWalkingExecutor).runTests(source, importPaths);
            return;
        case ExecutorBackend.dmdCtfe:
            import quickbite.backends.dmd_ctfe: DmdCtfe;
            (new DmdCtfe).runTests(source, importPaths);
            return;
    }
}

public imported!"quickbite.executor".TestSummary runTestSummary(
    in string source,
    in ExecutorBackend backend = ExecutorBackend.ir,
) {
    final switch (backend) {
        case ExecutorBackend.ir:
            import quickbite.backends.ir: IrExecutor;
            return (new IrExecutor).runTestSummary(source);
        case ExecutorBackend.treeWalking:
            import quickbite.backends.tree_walking: TreeWalkingExecutor;
            return (new TreeWalkingExecutor).runTestSummary(source);
        case ExecutorBackend.dmdCtfe:
            import quickbite.backends.dmd_ctfe: DmdCtfe;
            return (new DmdCtfe).runTestSummary(source);
    }
}
