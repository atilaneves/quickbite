module quickbite.backend;

private:

public interface Backend {
    public imported!"quickbite.lang".Value eval(in string expr);

    public imported!"quickbite.lang".Value evalRepl(
        in imported!"quickbite.frontend.repl".ReplCell cell,
    );

    public void runParsedTests(imported!"dmd.dmodule".Module module_);
}
