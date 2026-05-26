module quickbite.backends.ctfe;


private:


public class Ctfe: imported!"quickbite.backend".Backend {
    import quickbite.lang: Value;
    import quickbite.executors.dmd_ctfe: Impl = DmdCtfe;

    private Impl _impl;

    this() {
        _impl = new typeof(_impl);
    }

    public override Value eval(in string str) {
        const oldVal = _impl.eval(str);
        return Value(cast(int) oldVal.asLong);
    }
}
