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
    backendExecutor(backend).runTests(source);
}

public void runTests(
    in string source,
    in string[] importPaths,
    in ExecutorBackend backend = ExecutorBackend.ir,
) {
    backendExecutor(backend).runTests(source, importPaths);
}

private imported!"quickbite.executor".Executor backendExecutor(
    in ExecutorBackend backend,
) {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.backends.ir: IrExecutor;
    import quickbite.backends.tree_walking: TreeWalkingExecutor;

    final switch (backend) {
        case ExecutorBackend.ir:
            return new IrExecutor;
        case ExecutorBackend.treeWalking:
            return new TreeWalkingExecutor;
        case ExecutorBackend.dmdCtfe:
            return new DmdCtfe;
    }
}
