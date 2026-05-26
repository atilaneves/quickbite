module quickbite;

private:

public enum ExecutorName {
    ir,
    treeWalkingOld,
    treeWalking,
    dmdCtfe,
    dmdCodegen,
    dmdCodegenRam,
    bytecode,
}

public void runTests(
    in string source,
    in ExecutorName executorName = ExecutorName.ir,
) {
    executor(executorName).runTests(source);
}

public void runTestsFromFile(
    in string filePath,
    in string[] importPaths,
    in ExecutorName executorName = ExecutorName.ir,
) {
    import std.file: readText;
    runTests(filePath.readText, importPaths, executorName);
}

public void runTests(
    in string source,
    in string[] importPaths,
    in ExecutorName executorName = ExecutorName.ir,
) {
    executor(executorName).runTests(source, importPaths);
}

public imported!"quickbite.executor".TestSummary runTestSummary(
    in string source,
    in ExecutorName executorName = ExecutorName.ir,
) {
    return executor(executorName).runTestSummary(source);
}

public imported!"quickbite.executor".Executor executor(
    in ExecutorName executorName,
) {
    final switch (executorName) {
        case ExecutorName.ir:
            import quickbite.executors.ir: IrExecutor;
            return new IrExecutor;
        case ExecutorName.treeWalkingOld:
            import quickbite.executors.tree_walking_old: TreeWalkingExecutorOld;
            return new TreeWalkingExecutorOld;
        case ExecutorName.treeWalking:
            import quickbite.executors.tree_walking: TreeWalkingExecutor;
            return new TreeWalkingExecutor;
        case ExecutorName.dmdCtfe:
            import quickbite.executors.dmd_ctfe: DmdCtfe;
            return new DmdCtfe;
        case ExecutorName.dmdCodegen:
            import quickbite.executors.dmd_codegen: DmdCodegenSharedLib;
            return new DmdCodegenSharedLib;
        case ExecutorName.dmdCodegenRam:
            import std.process: environment;

            if (environment.get("QUICKBITE_EXPERIMENTAL_EXECUTOR_TESTS").length == 0)
                throw new Exception(
                    "ExecutorName.dmdCodegenRam is experimental; set "
                    ~ "QUICKBITE_EXPERIMENTAL_EXECUTOR_TESTS to use it.",
                );

            import quickbite.executors.dmd_codegen: DmdCodegenRam;
            return new DmdCodegenRam;
        case ExecutorName.bytecode:
            import quickbite.executors.bytecode: BytecodeExecutor;
            return new BytecodeExecutor;
    }
}
