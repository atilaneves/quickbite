module ut.backends.runner.sys.concurrency;


import ut.backends;
import std.algorithm.searching: canFind;


// fearless's ut.concurrency tests evaluate thisTid (phobos
// std.concurrency), which executes `thisInfo.ident = Tid(new MessageBox)`.
// MessageBox is a private phobos class in a non-root module, so dmd never
// ran semantic3 on its constructor; its fbody is a raw parse tree with
// null expression types. This was distilled from fearless.
enum thisTidSource = q{
    unittest {
        import std.concurrency: thisTid;

        auto tid = thisTid;
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run std.concurrency's thisTid (no host threads)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin below (matches oracle or raises structured Unsupported diagnostic)"),
    Omit!(Bytecode, Because.unconfirmed,
        "order-dependent: std.concurrency's Scheduler.thisInfo path reaches " ~
        "a second core.internal.atomic inline-asm atomic-load shape (EDX/EAX " ~
        "32-bit value registers) distinct from the already-supported 8-byte " ~
        "RDX/RAX shape, on a Scheduler-typed (8-byte reference) load whose " ~
        "register width does not yet have a characterized explanation; only " ~
        "reached when this row runs before whatever else in the suite " ~
        "otherwise satisfies it first"),
)) {
    @("concurrency.thisTid." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(thisTidSource);
    }
}

// The interpreter must either match the oracle or raise its structured
// unsupported diagnostic — never die: a backend crash kills the whole
// bench process and its buffered output.
@("concurrency.thisTid.Interpreter")
@Tags(Interpreter.stringof)
unittest {
    try
        runBackendSourceFixtureTests!Interpreter(thisTidSource);
    catch (Exception exception) {
        const structured =
            exception.msg.canFind("Unsupported") ||
            exception.msg.canFind("no available source");
        assert(structured, exception.msg);
    }
}
