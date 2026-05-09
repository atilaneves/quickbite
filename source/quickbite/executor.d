module quickbite.executor;

private:

public interface Executor {
    public void runTests(in string source);
    public void runTests(in string filePath, in string[] importPaths);
    public void runParsedTests(imported!"dmd.dmodule".Module module_);
}
