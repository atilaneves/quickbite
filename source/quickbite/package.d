module quickbite;

public void runTests(in string source) {
    import quickbite.backends.ir: IrExecutor;
    new IrExecutor().runTests(source);
}
