module quickbite;

private:

version (QuickbiteDmdCodegen) {
    public enum ExecutorBackend {
        ir,
        treeWalking,
        dmdCtfe,
        dmdCodegen,
    }
} else {
    public enum ExecutorBackend {
        ir,
        treeWalking,
        dmdCtfe,
    }
}

public void runTests(
    in string source,
    in ExecutorBackend backend = ExecutorBackend.ir,
) {
    executor(backend).runTests(source);
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
    executor(backend).runTests(source, importPaths);
}

public imported!"quickbite.executor".TestSummary runTestSummary(
    in string source,
    in ExecutorBackend backend = ExecutorBackend.ir,
) {
    return executor(backend).runTestSummary(source);
}

private imported!"quickbite.executor".Executor executor(
    in ExecutorBackend backend,
) {
    final switch (backend) {
        case ExecutorBackend.ir:
            import quickbite.backends.ir: IrExecutor;
            return new IrExecutor;
        case ExecutorBackend.treeWalking:
            import quickbite.backends.tree_walking: TreeWalkingExecutor;
            return new TreeWalkingExecutor;
        case ExecutorBackend.dmdCtfe:
            import quickbite.backends.dmd_ctfe: DmdCtfe;
            return new DmdCtfe;
        version (QuickbiteDmdCodegen) {
            case ExecutorBackend.dmdCodegen:
                import quickbite.backends.dmd_codegen: DmdCodegen;
                return new DmdCodegen;
        }
    }
}
