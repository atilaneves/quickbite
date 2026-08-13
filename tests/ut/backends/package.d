module ut.backends;


public import ut;
public import quickbite.backends.runner: TestResult;
public import quickbite.lang: Value;
public import quickbite.backends.ctfe;
public import quickbite.backends.interpreter;
public import quickbite.backends.bytecode;
public import quickbite.backends.ir;
public import quickbite.backends.native;
public import std.meta: AliasSeq;

import std.meta: Filter, staticIndexOf;
import std.traits: isInstanceOf;


/++
    Every backend that reproduces `SystemLinker`'s behaviour on the
    hermetic language surface, once mature. `Ctfe` is included because a
    fixture written for it is real D, even though it is not itself an
    oracle (`ai/plans/single-oracle.md`).
+/
public alias LangBackends = AliasSeq!(Ctfe, Interpreter, Bytecode, SystemLinker, LLVMJit);

/++
    `LangBackends` minus `Ctfe`: the backends that can run behaviour
    needing the host environment (libc/OS).
+/
public alias SysBackends = AliasSeq!(Interpreter, Bytecode, SystemLinker, LLVMJit);

/++
    Why a backend is missing from a fixture's `Matrix!(...)`. Every
    `Omit!(...)` names one of these so the omission is documentation, not
    silence.
+/
public enum Because {
    inexpressible, // engine can never run the construct (permanent; note required)
    diverges,      // pinned in a sibling hand-listed characterization block (note required)
    refusal,       // documented refusal (ai/plans/interpreter.md §8; note = verbatim red)
    unconfirmed,   // never tried: the promotion backlog (note optional)
}

/++
    Removes `B` from a fixture's `Matrix!(...)`, with a reason. `B` must
    be one of `LangBackends` (otherwise it is a typo, since it can never
    have been in the matrix to begin with) and must not be
    `SystemLinker` — the oracle can never be omitted from a `Matrix`;
    hand-written `AliasSeq!` characterization pins are unaffected. A
    `Because.inexpressible`, `Because.refusal`, or `Because.diverges`
    omission requires a non-empty `note`.
+/
public struct Omit(B, Because why, string note = "") {
    static assert(staticIndexOf!(B, LangBackends) != -1,
        "Omit!(" ~ B.stringof ~ ", ...): `" ~ B.stringof ~ "` is not in " ~
        "`LangBackends` - typo?");
    static assert(!is(B == SystemLinker),
        "Omit!(SystemLinker, ...): the oracle can never be omitted from a " ~
        "Matrix; use a hand-written `AliasSeq!` characterization pin " ~
        "instead");
    static assert(note.length > 0 || (why != Because.inexpressible
            && why != Because.refusal && why != Because.diverges),
        "Omit!(" ~ B.stringof ~ ", Because.inexpressible|refusal|diverges, " ~
        "...): a non-empty `note` is required for this reason");

    public alias Backend = B;
    public enum reason = why;
    public enum note_ = note;
}

/++
    Adds an in-development backend (not part of `LangBackends`, e.g.
    `IR`) to a fixture's `Matrix!(...)`.
+/
public struct Plus(B) {
    public alias Backend = B;
}

private template BackendsOf(alias Spec, specs...) {
    static if (specs.length == 0)
        alias BackendsOf = AliasSeq!();
    else static if (isInstanceOf!(Spec, specs[0]))
        alias BackendsOf = AliasSeq!(specs[0].Backend, BackendsOf!(Spec, specs[1 .. $]));
    else
        alias BackendsOf = BackendsOf!(Spec, specs[1 .. $]);
}

/++
    The backend matrix for a fixture: `LangBackends` minus every
    `Omit!(...)` spec, plus every `Plus!(...)` spec. Usable directly as
    `static foreach (backend; Matrix!(...))`.
+/
public template Matrix(specs...) {
    static foreach (spec; specs) {
        static assert(isInstanceOf!(Omit, spec) || isInstanceOf!(Plus, spec),
            "Matrix!(...): `" ~ spec.stringof ~ "` is neither `Omit!(...)` " ~
            "nor `Plus!(...)` - a bare backend (or a typo, e.g. `Matrix!(IR)` " ~
            "instead of `Matrix!(Plus!(IR))`) is silently ignored rather than " ~
            "added to or omitted from the matrix");
        static if (isInstanceOf!(Plus, spec))
            static assert(staticIndexOf!(spec.Backend, LangBackends) == -1,
                "Matrix!(Plus!(" ~ spec.Backend.stringof ~ "), ...): `" ~
                spec.Backend.stringof ~ "` is already in `LangBackends` - " ~
                "`Plus!` would duplicate it in the matrix");
    }

    private enum bool notOmitted(B) = staticIndexOf!(B, BackendsOf!(Omit, specs)) == -1;

    public alias Matrix = AliasSeq!(
        Filter!(notOmitted, LangBackends),
        BackendsOf!(Plus, specs),
    );
}


auto newBackend(T)() {
    return new T;
}

public string buildSharedLibrary(
    in Sandbox sandbox,
    in string libraryName,
    in string[] sourcePaths,
) {
    import std.process: execute;

    const imagePath = sandbox.inSandboxPath("lib" ~ libraryName ~ ".so");
    string[] command = [
        "dmd",
        "-shared",
        "-fPIC",
        "-defaultlib=libphobos2.so",
        "-of=" ~ imagePath,
    ];
    foreach (sourcePath; sourcePaths)
        command ~= sandbox.inSandboxPath(sourcePath);

    const build = execute(command);
    build.status.should == 0;

    return imagePath;
}

public void runBackendSourceFixtureTests(T)(
    in string moduleSource,
) {
    runBackendSourceFixtureTests!T(moduleSource, []);
}

public void runBackendSourceFixtureTests(T)(
    in string moduleSource,
    in string[] importPaths,
) {
    runBackendSourceFixtureTestResults!T(moduleSource, importPaths)
        .throwOnTestFailure;
}

// A variant taking frontend compiler flags directly (e.g. `-preview=dip1000`)
// for a fixture whose shape only appears under a preview the default
// snippet parse never enables -- mirrors `dependency_image.d`'s own
// `FrontendFlags(["-preview=dip1000"])` use for the same reason.
public void runBackendSourceFixtureTests(T)(
    in string moduleSource,
    in string[] importPaths,
    in imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags,
) {
    runBackendSourceFixtureTestResults!T(moduleSource, importPaths, frontendFlags)
        .throwOnTestFailure;
}

public TestResult[] runBackendSourceFixtureTestResults(T)(
    in string moduleSource,
) {
    return runBackendSourceFixtureTestResults!T(moduleSource, []);
}

public TestResult[] runBackendSourceFixtureTestResults(T)(
    in string moduleSource,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: FrontendFlags;

    return runBackendSourceFixtureTestResults!T(
        moduleSource, importPaths, FrontendFlags.init,
    );
}

public TestResult[] runBackendSourceFixtureTestResults(T)(
    in string moduleSource,
    in string[] importPaths,
    in imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags,
) {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;

    auto moduleResult = parseSnippetWithCheckActionContext(
        moduleSource, importPaths, frontendFlags,
    );
    auto backend = newBackend!T;
    return backend.runTests(moduleResult.module_);
}

public void runBackendFileFixtureTests(T)(
    in string filePath,
    in string[] importPaths,
) {
    runBackendFileFixtureTestResults!T(filePath, importPaths)
        .throwOnTestFailure;
}

public TestResult[]
runBackendFileFixtureTestResults(T)(
    in string filePath,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: parseModuleWithCheckActionContext;

    auto moduleResult = parseModuleWithCheckActionContext(
        filePath,
        importPaths,
    );
    auto backend = newBackend!T;
    return backend.runTests(moduleResult.module_);
}

private void throwOnTestFailure(in TestResult[] results) {
    foreach (result; results)
        if (!result.passed)
            throw new Exception(result.message);
}
