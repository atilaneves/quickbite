module quickbite.ir.runner;

private:

public void runParsedIrTests(imported!"dmd.dmodule".Module module_) {
    import quickbite.executors.ir: IrExecutor;

    auto executor = new IrExecutor;
    executor.runParsedTests(module_);
}
