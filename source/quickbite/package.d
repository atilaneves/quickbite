module quickbite;

private:

public enum ExecutorBackend {
    ir,
    treeWalking,
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
    }
}
