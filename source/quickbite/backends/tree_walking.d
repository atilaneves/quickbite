module quickbite.backends.tree_walking;

private:

public final class TreeWalkingExecutor : imported!"quickbite.executor".Executor {
    import dmd.declaration: VarDeclaration;
    import dmd.dmodule: Module;
    import quickbite.executor: TestSummary;

    private long[VarDeclaration] locals;

    public override void runTests(in string source) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source).module_);
    }

    public override void runTests(in string source, in string[] importPaths) {
        import quickbite.frontend.compiler: parseModule;

        runParsedTests(parseModule(source, importPaths).module_);
    }

    public override void runParsedTests(
        Module module_,
    ) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        foreachUnitTestDeclaration(module_, (unitTest) {
            runTest(unitTest);
        });
    }

    private void runTest(imported!"dmd.func".UnitTestDeclaration unitTest) {
        locals = null;
        runStatement(unitTest.fbody);
    }

    private void runStatement(imported!"dmd.statement".Statement statement) {
        if (statement is null)
            return;

        if (auto scope_ = statement.isScopeStatement) {
            runStatement(scope_.statement);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements)
                    runStatement(child);
            return;
        }

        if (auto expressionStatement = statement.isExpStatement) {
            runExpression(expressionStatement.exp);
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    private long runExpression(imported!"dmd.expression".Expression expression) {
        if (auto integer = expression.isIntegerExp)
            return integer.getInteger;

        if (auto var = expression.isVarExp) {
            auto variable = var.var.isVarDeclaration;
            if (variable !is null) {
                if (variable in locals)
                    return locals[variable];
                else
                    return 0;  // Uninitialized variable defaults to 0
            }
        }

        if (auto declaration = expression.isDeclarationExp)
            return runDeclarationExpression(declaration);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign);

        if (auto construct = expression.isConstructExp)
            return runAssignExpression(construct);

        if (auto add = expression.isAddExp)
            return runExpression(add.e1) + runExpression(add.e2);

        if (auto sub = expression.isMinExp)
            return runExpression(sub.e1) - runExpression(sub.e2);

        if (auto mul = expression.isMulExp)
            return runExpression(mul.e1) * runExpression(mul.e2);

        if (auto div = expression.isDivExp)
            return runExpression(div.e1) / runExpression(div.e2);

        if (auto cast_ = expression.isCastExp)
            return runExpression(cast_.e1);

        if (auto blit = expression.isBlitExp)
            return runExpression(blit.e2);

        if (auto addAssign = expression.isAddAssignExp) {
            auto var = addAssign.e1.isVarExp;
            if (var !is null) {
                auto variable = var.var.isVarDeclaration;
                if (variable !is null) {
                    const val = runExpression(addAssign.e2);
                    const result = (variable in locals ? locals[variable] : 0L) + val;
                    locals[variable] = result;
                    return result;
                }
            }
        }

        if (auto minAssign = expression.isMinAssignExp) {
            auto var = minAssign.e1.isVarExp;
            if (var !is null) {
                auto variable = var.var.isVarDeclaration;
                if (variable !is null) {
                    const val = runExpression(minAssign.e2);
                    const result = (variable in locals ? locals[variable] : 0L) - val;
                    locals[variable] = result;
                    return result;
                }
            }
        }

        if (auto equal = expression.isEqualExp)
            return runExpression(equal.e1) == runExpression(equal.e2);

        if (auto assert_ = expression.isAssertExp)
            return runAssertExpression(assert_);

        if (auto post = expression.isPostExp) {
            import dmd.tokens: EXP;

            auto var = post.e1.isVarExp;
            if (var !is null) {
                auto variable = var.var.isVarDeclaration;
                if (variable !is null && variable in locals) {
                    long oldValue = locals[variable];
                    if (post.op == EXP.plusPlus)
                        locals[variable]++;
                    else if (post.op == EXP.minusMinus)
                        locals[variable]--;
                    return oldValue;
                }
            }
        }

        if (auto pre = expression.isPreExp) {
            import dmd.tokens: EXP;

            auto var = pre.e1.isVarExp;
            if (var !is null) {
                auto variable = var.var.isVarDeclaration;
                if (variable !is null && variable in locals) {
                    if (pre.op == EXP.plusPlus)
                        locals[variable]++;
                    else if (pre.op == EXP.minusMinus)
                        locals[variable]--;
                    return locals[variable];
                }
            }
        }

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expression.op));
    }

    private long runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp declaration,
    ) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return 0;

        if (variable._init is null || variable._init.isExpInitializer is null) {
            // No initializer - initialize to 0
            locals[variable] = 0;
            return 0;
        }

        auto expInit = variable._init.isExpInitializer;
        if (expInit is null)
            return 0;

        auto initializer = expInit.exp;
        if (auto assign = initializer.isAssignExp) {
            // AssignExp: extract the RHS
            initializer = assign.e2;
        } else if (auto construct = initializer.isConstructExp) {
            // ConstructExp for things like "long x = expr"
            // The e1 is the type being constructed, e2 is the value
            initializer = construct.e2;
        }
        // else: initializer is used as-is (it's the actual value expression)

        const value = runExpression(initializer);
        locals[variable] = value;
        return value;
    }

    private long runAssignExpression(imported!"dmd.expression".BinExp assign) {
        auto var = assign.e1.isVarExp;
        if (var is null || var.var.isVarDeclaration is null)
            throw new Exception("Unsupported assignment.");

        auto variable = var.var.isVarDeclaration;
        const value = runExpression(assign.e2);
        locals[variable] = value;
        return value;
    }

    private long runAssertExpression(
        imported!"dmd.expression".AssertExp assert_,
    ) {
        if (runExpression(assert_.e1))
            return 1;

        if (auto equal = assert_.e1.isEqualExp) {
            import std.conv: text;

            throw new Exception(text(
                runExpression(equal.e1),
                " != ",
                runExpression(equal.e2),
            ));
        }

        throw new Exception("Unittest assertion failed.");
    }

    public override TestSummary runTestSummary(
        in string source,
    ) {
        return TestSummary.init;
    }

    public override imported!"quickbite.executor".Value eval(in string input) {
        import quickbite.executor: Value;
        import quickbite.frontend.compiler: parseModule;
        import dmd.declaration: VarDeclaration;
        import dmd.func: FuncDeclaration;
        import std.string: lastIndexOf;

        const lastNl = input.lastIndexOf('\n');
        const prior  = lastNl < 0 ? "" : input[0 .. lastNl + 1];
        const last   = lastNl < 0 ? input : input[lastNl + 1 .. $];
        const source = "void f() { " ~ prior ~ "auto __r = " ~ last ~ "; }";

        auto parsed = parseModule(source);
        auto module_ = parsed.module_;

        FuncDeclaration f;
        if (module_.members !is null) {
            foreach (member; *module_.members) {
                auto fd = member.isFuncDeclaration;
                if (fd !is null && fd.ident.toString == "f") {
                    f = fd;
                    break;
                }
            }
        }

        locals = null;
        runStatement(f.fbody);

        foreach (decl, value; locals) {
            if (decl.ident.toString == "__r")
                return Value(cast(int) value);
        }

        return Value(0);
    }

    public override imported!"quickbite.executor".Repl.CellResult evalReplCell(
        in string transcript,
        in string input,
    ) {
        import quickbite.executor: Repl;

        return Repl.CellResult.value_(eval(transcript ~ input));
    }
}
