module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".TreeNodeBackend,
    imported!"quickbite.backends.runner".CompileTimeReporter
{
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult, displayEvalResult,
        voidEvalResult;
    import quickbite.backends.bytecode.core.compiler: Compiler;
    import quickbite.backends.bytecode.core.machine: CompileFunction;
    import core.time: Duration, MonoTime;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration, StaticCtorDeclaration,
        UnitTestDeclaration;

    private Duration _compileTime;
    // Compiled functions, class infos, and module-variable slots persist
    // here across unittests: dataseg writes stay visible to later unittests
    // (matching compiled D) and shared callees compile once. Only the
    // unittest path reuses it -- see `compile`'s two-argument overload for
    // why eval must not.
    private Compiler* _compiler;
    // A module constructor must run exactly once per (Bytecode instance,
    // module), not once per `runTests` call: the benchmark harness calls
    // `runTests` repeatedly on the same instance and module (warmup plus
    // measured runs), and `_compiler` -- and the dataseg state its module
    // constructors write to -- persists across those calls. Keyed by
    // `Module` identity: a caller that re-parses the same source into a new
    // `Module` against the same persisted `_compiler` (the REPL's
    // `runLoadedTests`) runs that module's constructors again over the same
    // dataseg state, since the new `Module` is not yet in this table.
    private bool[Module] _moduleConstructorsRun;

    public alias eval = Evaluator.eval;

    public this() @safe @nogc nothrow pure {
    }

    public this(const string[] dependencyImages) {
        import quickbite.ffi.ffi: loadDependencyImages;

        loadDependencyImages(dependencyImages);
    }

    public override EvalResult eval(FuncDeclaration function_) {
        import quickbite.backends.bytecode.core.compiler: compile;
        import quickbite.backends.bytecode.core.machine: run;
        import quickbite.backends.bytecode.core.reify: reify;

        return displayEvalResult(() {
            const start = MonoTime.currTime;
            auto compilation = compile(function_);
            _compileTime += MonoTime.currTime - start;
            auto result = run(
                *compilation.program,
                timed(compilation.compileFunction),
                compilation.entryIndex,
            );
            return reify(
                result.bytes,
                compilation.program.functions[compilation.entryIndex].returnType,
                compilation.program.data,
                result.heap,
                compilation.program.literalBlocks,
            );
        }, function_);
    }

    protected override EvalResult executeUnitTest(
        UnitTestDeclaration unitTest,
    ) {
        import quickbite.backends.bytecode.core.compiler: compile;
        import quickbite.backends.bytecode.core.machine: run;

        return voidEvalResult(() {
            const start = MonoTime.currTime;
            auto compilation = compile(unitTest, _compiler);
            _compileTime += MonoTime.currTime - start;
            run(
                *compilation.program,
                timed(compilation.compileFunction),
                compilation.entryIndex,
            );
        });
    }

    protected override void ensureModuleConstructorsRun(Module module_) {
        import quickbite.frontend.util: foreachStaticCtorDeclaration;

        if (module_ in _moduleConstructorsRun)
            return;

        StaticCtorDeclaration[] sharedCtors;
        StaticCtorDeclaration[] plainCtors;

        foreachStaticCtorDeclaration(module_, (ctor) {
            if (ctor.isSharedStaticCtorDeclaration)
                sharedCtors ~= ctor;
            else
                plainCtors ~= ctor;
        });

        // `shared static this` bodies run before `static this` bodies,
        // matching compiled D's startup order; a thrown/asserted ctor
        // propagates like any other host exception -- it is not caught and
        // turned into a diagnostic here, since a module constructor failure
        // is fatal, not attributable to a single unittest. The memo is set
        // only after both loops finish, so a ctor that throws is not
        // recorded as done: the next `runTests` call on this module reruns
        // (and rethrows) it instead of silently treating the module as
        // constructed.
        foreach (ctor; sharedCtors)
            runModuleConstructor(ctor);
        foreach (ctor; plainCtors)
            runModuleConstructor(ctor);

        _moduleConstructorsRun[module_] = true;
    }

    private void runModuleConstructor(FuncDeclaration ctor) {
        import quickbite.backends.bytecode.core.compiler: compile;
        import quickbite.backends.bytecode.core.machine: run;

        const start = MonoTime.currTime;
        auto compilation = compile(ctor, _compiler);
        _compileTime += MonoTime.currTime - start;
        run(
            *compilation.program,
            timed(compilation.compileFunction),
            compilation.entryIndex,
        );
    }

    public override Duration compileTime() @safe @nogc nothrow pure const scope {
        return _compileTime;
    }

    public override void resetCompileTime() @safe @nogc nothrow pure scope {
        _compileTime = Duration.zero;
    }

    // The machine calls the lazy-compile hook mid-execution for each callee's
    // first call; that cost is compile time, not run time.
    private CompileFunction timed(CompileFunction compileFunction) {
        return (in size_t index) {
            const start = MonoTime.currTime;
            scope(exit) _compileTime += MonoTime.currTime - start;
            compileFunction(index);
        };
    }
}
