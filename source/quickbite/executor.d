module quickbite.executor;

private:

public interface Executor {
    public void runTests(in string source);
    public void runParsedTests(imported!"dmd.dmodule".Module module_);
}
