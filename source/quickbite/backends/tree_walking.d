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
    long executeFunction(
        imported!"dmd.func".FuncDeclaration func,
        in long[] args = [],
    ) @safe {
        if (func.fbody is null)
            throw new Exception("No function body to execute.");
        BodyWalker w;
        w.bindParameters(func, args);
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
    private long[VarDeclaration][VarDeclaration] structFields;
    public bool hasReturn;
    public long returnValue;

    void bindParameters(
        imported!"dmd.func".FuncDeclaration func,
        in long[] args,
    ) @safe {
        if (func.parameters is null && args.length == 0)
            return;
        if (func.parameters is null || args.length != func.parameters.length)
            throw new Exception("Unsupported call.");
        foreach (i, param; functionParameters(func))
            locals[param] = args[i];
    }

    void runStatement(
        imported!"dmd.statement".Statement statement,
        ref Walker walker,
    ) @safe {
        if (auto scope_ = statement.isScopeStatement) {
            if (scope_.statement !is null)
                runStatement(scope_.statement, walker);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
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

        if (auto for_ = statement.isForStatement) {
            if (for_._init !is null)
                runStatement(for_._init, walker);
            while (for_.condition is null || runExpression(for_.condition, walker)) {
                runStatement(for_._body, walker);
                if (hasReturn)
                    return;
                if (for_.increment !is null)
                    runExpression(for_.increment, walker);
            }
            return;
        }

        if (auto if_ = statement.isIfStatement) {
            const cond = runExpression(if_.condition, walker);
            if (cond)
                runStatement(if_.ifbody, walker);
            else if (if_.elsebody !is null)
                runStatement(if_.elsebody, walker);
            return;
        }

        if (auto ret = statement.isReturnStatement) {
            if (ret.exp is null)
                throw new Exception("Unsupported function body.");
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
            if (call.f is null)
                throw new Exception("Unsupported callee.");
            long[] args;
            if (call.arguments !is null)
                foreach (arg; callArguments(call))
                    args ~= runExpression(arg, walker);
            return walker.executeFunction(call.f, args);
        }

        if (auto equal = expression.isEqualExp) {
            import dmd.tokens: EXP;
            const left = runExpression(equal.e1, walker);
            const right = runExpression(equal.e2, walker);
            if (equal.op == EXP.notEqual)
                return left != right ? 1 : 0;
            return left == right ? 1 : 0;
        }

        if (auto assert_ = expression.isAssertExp) {
            const cond = runExpression(assert_.e1, walker);
            if (!cond)
                throw new Exception("Unittest assertion failed.");
            return cond;
        }

        if (auto decl = expression.isDeclarationExp) {
            void unsupportedDecl() {
                throw new Exception(text("Unsupported expression: ", decl.op));
            }
            auto variable = decl.declaration.isVarDeclaration;
            if (variable is null)
                unsupportedDecl;
            if (variable.type !is null && variable.type.isTypeStruct !is null) {
                structFields[variable] = (long[VarDeclaration]).init;
                return 0;
            }
            if (variable._init is null)
                unsupportedDecl;
            auto initializer = variable._init.isExpInitializer;
            if (initializer is null)
                unsupportedDecl;
            auto construct = initializer.exp.isConstructExp;
            if (construct is null)
                unsupportedDecl;
            const value = runExpression(construct.e2, walker);
            locals[variable] = value;
            return value;
        }

        if (auto dotVar = expression.isDotVarExp) {
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (auto fields = ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration)
                            return (*fields).get(fieldDecl, 0);
            unsupported;
        }

        {
            import dmd.tokens: EXP;
            if (expression.op == EXP.lessThan) {
                auto cmp = expression.isBinExp;
                return runExpression(cmp.e1, walker) < runExpression(cmp.e2, walker) ? 1 : 0;
            }
            if (expression.op == EXP.greaterThan) {
                auto cmp = expression.isBinExp;
                return runExpression(cmp.e1, walker) > runExpression(cmp.e2, walker) ? 1 : 0;
            }
            if (expression.op == EXP.lessOrEqual) {
                auto cmp = expression.isBinExp;
                return runExpression(cmp.e1, walker) <= runExpression(cmp.e2, walker) ? 1 : 0;
            }
            if (expression.op == EXP.greaterOrEqual) {
                auto cmp = expression.isBinExp;
                return runExpression(cmp.e1, walker) >= runExpression(cmp.e2, walker) ? 1 : 0;
            }
        }

        if (auto assign = expression.isAssignExp) {
            const value = runExpression(assign.e2, walker);
            if (auto var = assign.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        locals[varDecl] = value;
                        return value;
                    }
            if (auto dotVar = assign.e1.isDotVarExp)
                if (auto ownerVar = dotVar.e1.isVarExp)
                    if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                        if (ownerDecl in structFields)
                            if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                                structFields[ownerDecl][fieldDecl] = value;
                                return value;
                            }
            unsupported;
        }

        if (auto add = expression.isAddExp)
            return runExpression(add.e1, walker) + runExpression(add.e2, walker);

        if (auto subtract = expression.isMinExp)
            return runExpression(subtract.e1, walker) - runExpression(subtract.e2, walker);

        if (auto multiply = expression.isMulExp)
            return runExpression(multiply.e1, walker) * runExpression(multiply.e2, walker);

        if (auto divide = expression.isDivExp) {
            const right = runExpression(divide.e2, walker);
            if (right == 0)
                throw new Exception("Division by zero.");
            return runExpression(divide.e1, walker) / right;
        }

        if (auto modulo = expression.isModExp) {
            const right = runExpression(modulo.e2, walker);
            if (right == 0)
                throw new Exception("Division by zero.");
            return runExpression(modulo.e1, walker) % right;
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

private ref auto callArguments(
    imported!"dmd.expression".CallExp call,
) @trusted {
    return *call.arguments;
}

private ref auto functionParameters(
    imported!"dmd.func".FuncDeclaration func,
) @trusted {
    return *func.parameters;
}
