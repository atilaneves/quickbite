module quickbite.backends.ctfe.plus;


private:


public class CtfePlus: imported!"quickbite.backend".Backend {
    import quickbite.backends.ctfe.dmd_ctfe: Ctfe;
    import quickbite.lang: Value;

    private Ctfe _ctfe;

    public this() {
        _ctfe = new Ctfe;
    }

    public override Value eval(in string expr) {
        return _ctfe.eval(expr);
    }

    public override Value evalRepl(
        in imported!"quickbite.frontend.repl".ReplCell cell,
    ) {
        return _ctfe.evalRepl(cell);
    }

    public override void runParsedTests(
        imported!"dmd.dmodule".Module module_,
    ) {
        try {
            return _ctfe.runParsedTests(module_);
        } catch (Exception e) {
            return _runParsedTests(module_);
        }
    }

    private void _runParsedTests(imported!"dmd.dmodule".Module module_) {
    }
}
