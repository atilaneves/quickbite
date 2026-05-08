module quickbite.backends.dmd_ctfe;

private:

public final class DmdCtfe : imported!"quickbite.executor".Executor {
    public void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;
        runParsedTests(parseModule(source).module_);
    }

    public void runParsedTests(imported!"dmd.dmodule".Module module_) {
        foreach (member; moduleMembers(module_)) {
            if (auto utd = member.isUnitTestDeclaration)
                runCtfe(utd);
        }
    }
}

private void runCtfe(imported!"dmd.func".UnitTestDeclaration utd) @trusted {
    import dmd.arraytypes: Expressions;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.expression: CallExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.location: Loc;
    import dmd.mtype: Type;

    FuncDeclaration fd = utd;
    auto varExp = new VarExp(Loc.initial, fd);
    varExp.type = fd.type;
    auto callExp = new CallExp(Loc.initial, varExp, new Expressions);
    callExp.type = Type.tvoid;
    callExp.f    = fd;

    const result = ctfeInterpret(callExp);
    if (result.isErrorExp)
        throw new Exception("unittest failed in CTFE");
}

private ref auto moduleMembers(
    imported!"dmd.dmodule".Module module_,
) @trusted pure {
    return *module_.members;
}
