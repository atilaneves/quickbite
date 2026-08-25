module quickbite.backends.bytecode.impl;

private:

public class Bytecode: imported!"quickbite.backends".TreeNodeBackend,
    imported!"quickbite.backends.runner".GroupedRunner,
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

    public alias eval = Evaluator.eval;

    public override imported!"quickbite.backends.runner".TestResult[] runTests(
        imported!"dmd.dmodule".Module module_,
    ) {
        return runTests([module_]);
    }

    // Each call is a fresh process: module storage is reset to its
    // registration-time bytes (`Compiler.resetModuleData`), then every
    // module's constructors run again -- `syncInitialModuleData` only
    // snapshots newly allocated slots at registration time, so a ctor's
    // writes are never part of that snapshot -- before that module's
    // unittests run.
    public override imported!"quickbite.backends.runner".TestResult[] runTests(
        imported!"dmd.dmodule".Module[] modules,
    ) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        if (_compiler !is null)
            _compiler.resetModuleData;

        imported!"quickbite.backends.runner".TestResult[] cases;
        foreach (module_; modules) {
            runModuleConstructors(module_);
            foreachUnitTestDeclaration(module_, (unitTest) {
                cases ~= runUnitTest(unitTest);
            });
        }
        return cases;
    }

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

    // Runs a module's `shared static this`/`static this` bodies, matching
    // compiled D's startup order. Called from `runTests` for every module on
    // every call, after module storage has been reset to its
    // registration-time bytes: a fresh reset-then-rerun each time matches a
    // fresh process running the module's startup sequence from scratch, so
    // there is nothing here to memoise across calls.
    private void runModuleConstructors(Module module_) {
        import quickbite.frontend.util: foreachStaticCtorDeclaration;

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
        // is fatal, not attributable to a single unittest.
        foreach (ctor; sharedCtors)
            runModuleConstructor(ctor);
        foreach (ctor; plainCtors)
            runModuleConstructor(ctor);
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
