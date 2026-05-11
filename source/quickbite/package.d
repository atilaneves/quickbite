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
    import quickbite.executor: Executor;

    // Explicit type: the AA values must be widened to the Executor interface.
    Executor[ExecutorBackend] executors = [
        ExecutorBackend.ir: cast(Executor) new IrExecutor,
        ExecutorBackend.treeWalking: cast(Executor) new TreeWalkingExecutor,
        ExecutorBackend.dmdCtfe: cast(Executor) new DmdCtfe,
    ];

    return executors[backend];
}
