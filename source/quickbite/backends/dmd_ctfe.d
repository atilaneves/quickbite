module quickbite.backends.dmd_ctfe;

private:

public final class DmdCtfe : imported!"quickbite.executor".Executor {
    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;
        runParsedTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;
        runParsedTests(parseModule(source, importPaths).module_);
    }

    public override void runParsedTests(imported!"dmd.dmodule".Module module_) {
        import quickbite.dmd_util: moduleMembers;

        if (module_.members is null)
            return;

        foreach (member; moduleMembers(module_)) {
            if (auto utd = member.isUnitTestDeclaration)
                runCtfe(utd);
        }
    }
}

private void runCtfe(imported!"dmd.func".UnitTestDeclaration utd) @trusted {
    import quickbite.frontend.compiler: withCompilerLock;
    import dmd.arraytypes: Expressions;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.expression: CallExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.location: Loc;
    import dmd.mtype: Type;

    // auto: both nodes are mutated after construction (type and f fields).
    FuncDeclaration fd = utd;
    auto varExp = new VarExp(Loc.initial, fd);
    varExp.type = fd.type;
    auto callExp = new CallExp(Loc.initial, varExp, new Expressions);
    callExp.type = Type.tvoid;
    // Direct field write: skipping expressionSemantic because all type
    // information is already set from the fully-semantic'd FuncDeclaration.
    callExp.f    = fd;

    bool failed;
    withCompilerLock(() {
        failed = ctfeInterpret(callExp).isErrorExp !is null;
    });

    if (failed)
        throw new Exception("Unittest assertion failed.");
}
