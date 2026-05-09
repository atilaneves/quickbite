module unit_threaded;

private:

public void writelnUt(T...)(T) {}

public void shouldEqual(T, U)(T t, U u) {
    static if (__traits(compiles, t == u))
        assert(t == u, "shouldEqual failed");
}

public void shouldNotEqual(T, U)(T t, U u) {}
public void shouldThrow(T)(lazy T) {}
public void shouldThrow(E, T)(lazy T) {}
public void shouldThrowWithMessage(T)(lazy T, string) {}
public void shouldNotThrow(T)(lazy T) {}
public void shouldNotThrow(E, T)(lazy T) {}
public void shouldBeTrue(T)(T val) { assert(val); }
public void shouldBeFalse(T)(T val) { assert(!val); }
public struct Types(T...) {}
public void check(alias F, int numFuncCalls = 100)() {}
public enum SingleThreaded;
