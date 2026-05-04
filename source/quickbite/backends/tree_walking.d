module quickbite.backends.tree_walking;

private:


public final class TreeWalkingExecutor : imported!"quickbite.executor".Executor {
    void runTests(in string source) {
        import quickbite.frontend.compiler;

        auto parsed = quickbite.frontend.compiler.parseModule(source);
        walkModule(parsed.module_);
    }
}

void walkModule(imported!"dmd.dmodule".Module module_) @safe {
    if (module_.members is null)
        return;

    Walker walker;
    foreach (member; moduleMembers(module_)) {
        if (auto unitTest = member.isUnitTestDeclaration)
            walker.runTest(unitTest);
    }
}

struct Walker {
    long executeFunction(imported!"dmd.func".FuncDeclaration func) @safe {
        BodyWalker w;
        w.runStatement(func.fbody, this);
        if (!w.hasReturn)
            throw new Exception("Unsupported function body.");
        return w.returnValue;
    }

    void runTest(
        imported!"dmd.declaration".UnitTestDeclaration unitTest,
    ) @safe {
        BodyWalker w;
        w.runStatement(unitTest.fbody, this);
    }
}

struct BodyWalker {
    import dmd.declaration: VarDeclaration;

    private long[VarDeclaration] locals;
    public bool hasReturn;
    public long returnValue;

    void runStatement(
        imported!"dmd.statement".Statement statement,
        ref Walker walker,
    ) @safe {
        if (auto compound = statement.isCompoundStatement) {
            foreach (child; compoundStatements(compound)) {
                runStatement(child, walker);
                if (hasReturn)
                    return;
            }
            return;
        }

        if (auto expr = statement.isExpStatement) {
            runExpression(expr.exp, walker);
            return;
        }

        if (auto ret = statement.isReturnStatement) {
            returnValue = runExpression(ret.exp, walker);
            hasReturn = true;
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    long runExpression(
        imported!"dmd.expression".Expression expression,
        ref Walker walker,
    ) @safe {
        import std.conv: text;

        void unsupported() {
            throw new Exception(
                text("Unsupported expression: ", expressionChars(expression)),
            );
        }

        if (auto integer = expression.isIntegerExp)
            return integerValue(integer);

        if (auto call = expression.isCallExp) {
            if (call.arguments !is null && call.arguments.length != 0)
                throw new Exception("Unsupported call.");
            if (call.f is null)
                throw new Exception("Unsupported callee.");
            return walker.executeFunction(call.f);
        }

        if (auto equal = expression.isEqualExp) {
            const left = runExpression(equal.e1, walker);
            const right = runExpression(equal.e2, walker);
            return left == right ? 1 : 0;
        }

        if (auto assert_ = expression.isAssertExp) {
            const cond = runExpression(assert_.e1, walker);
            if (!cond)
                throw new Exception("Unittest assertion failed.");
            return cond;
        }

        if (auto decl = expression.isDeclarationExp) {
            auto variable = decl.declaration.isVarDeclaration;
            if (variable is null || variable._init is null)
                unsupported;
            auto initializer = variable._init.isExpInitializer;
            if (initializer is null)
                unsupported;
            auto construct = initializer.exp.isConstructExp;
            if (construct is null)
                unsupported;
            const value = runExpression(construct.e2, walker);
            locals[variable] = value;
            return value;
        }

        if (auto var = expression.isVarExp) {
            if (auto varDecl = var.var.isVarDeclaration)
                if (auto val = varDecl in locals)
                    return *val;
        }

        unsupported;
        assert(false);
    }
}

private ref auto moduleMembers(
    imported!"dmd.dmodule".Module module_,
) @trusted {
    return *module_.members;
}

private ref auto compoundStatements(
    imported!"dmd.statement".CompoundStatement compound,
) @trusted {
    return *compound.statements;
}

private long integerValue(
    imported!"dmd.expression".IntegerExp integer,
) @trusted {
    return integer.getInteger;
}

private string expressionChars(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import std.string: fromStringz;
    return fromStringz(expression.toChars).idup;
}
