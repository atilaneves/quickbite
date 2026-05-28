module quickbite.backend;

private:

public interface Backend {
    public imported!"quickbite.lang".Value eval(in string expr);

    public void runParsedTests(imported!"dmd.dmodule".Module module_);
}
