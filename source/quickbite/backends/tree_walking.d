module quickbite.backends.tree_walking;

private:

// SumType.opAssign is @system in this version of std.sumtype, so all code
// that stores a Value is @system by transitivity.
alias Value = imported!"std.sumtype".SumType!(long, long[]);

public final class TreeWalkingExecutor : imported!"quickbite.executor".Executor {
    public override void runTests(in string source) {
        import quickbite.frontend.compiler;

        // Keep `parsed` mutable: the DMD frontend owns mutable Module state.
        auto parsed = quickbite.frontend.compiler.parseModule(source);
        walkModule(parsed.module_);
    }
}

private void walkModule(imported!"dmd.dmodule".Module module_) {
    if (module_.members is null)
        return;

    Walker walker;
    foreach (member; moduleMembers(module_)) {
        if (auto unitTest = member.isUnitTestDeclaration)
            walker.runTest(unitTest);
    }
}

private struct Walker {
    private Value executeFunction(
        imported!"dmd.func".FuncDeclaration func,
        Value[] args = [],
    ) {
        if (func.fbody is null)
            throw new Exception("No function body to execute.");
        BodyWalker w;
        w.bindParameters(func, args);
        w.runStatement(func.fbody, this);
        if (!w.hasReturn && !isVoidReturn(func))
            throw new Exception("Unsupported function body.");
        return w.returnValue;
    }

    private bool isVoidReturn(
        imported!"dmd.func".FuncDeclaration func,
    ) @trusted {
        import dmd.astenums: TY;
        if (func.type is null) return false;
        const returnType = func.type.nextOf;
        return returnType !is null && returnType.ty == TY.Tvoid;
    }

    private void runTest(
        imported!"dmd.declaration".UnitTestDeclaration unitTest,
    ) {
        BodyWalker w;
        w.runStatement(unitTest.fbody, this);
    }
}

private struct BodyWalker {
    import dmd.declaration: VarDeclaration;

    // DMD's `is*` helpers return concrete AST subclasses. Keep `auto` for
    // those downcasts so the walker stays close to the frontend API.
    private Value[VarDeclaration] locals;
    private long[VarDeclaration][VarDeclaration] structFields;
    private bool hasReturn;
    private Value returnValue;

    private void bindParameters(
        imported!"dmd.func".FuncDeclaration func,
        Value[] args,
    ) {
        if (func.parameters is null && args.length == 0)
            return;
        if (func.parameters is null || args.length != func.parameters.length)
            throw new Exception("Unsupported call.");
        foreach (i, param; functionParameters(func)) {
            import dmd.astenums: STC;
            if (param.storage_class & (STC.ref_ | STC.out_ | STC.lazy_))
                throw new Exception("Unsupported parameter storage class.");
            locals[param] = args[i];
        }
    }

    private void runStatement(
        imported!"dmd.statement".Statement statement,
        ref Walker walker,
    ) {
        // DMD lowers the currently supported `foreach (x; array)` cases to
        // this for-statement shape before the tree-walker sees them.
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

        if (auto compound = statement.isCompoundDeclarationStatement) {
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
            while (for_.condition is null || runExpression(for_.condition, walker).asLong) {
                runStatement(for_._body, walker);
                if (hasReturn)
                    return;
                if (for_.increment !is null)
                    runExpression(for_.increment, walker);
            }
            return;
        }

        if (auto if_ = statement.isIfStatement) {
            const cond = runExpression(if_.condition, walker).asLong;
            if (cond)
                runStatement(if_.ifbody, walker);
            else if (if_.elsebody !is null)
                runStatement(if_.elsebody, walker);
            return;
        }

        if (auto ret = statement.isReturnStatement) {
            if (ret.exp !is null)
                returnValue = runExpression(ret.exp, walker);
            hasReturn = true;
            return;
        }

        import std.conv: text;
        throw new Exception(text("Unsupported statement: ", statement.stmt));
    }

    private Value runExpression(
        imported!"dmd.expression".Expression expression,
        ref Walker walker,
    ) {
        import std.conv: text;

        void unsupported() {
            throw new Exception(
                text("Unsupported expression: ", expressionChars(expression)),
            );
        }

        if (auto integer = expression.isIntegerExp)
            return Value(integerValue(integer));

        if (auto call = expression.isCallExp)
            return runCallExpression(call, walker);

        if (auto equal = expression.isEqualExp)
            return runEqualExpression(equal, walker);

        if (auto assert_ = expression.isAssertExp) {
            const cond = runExpression(assert_.e1, walker).asLong;
            if (!cond)
                throw new Exception("Unittest assertion failed.");
            return Value(cond);
        }

        if (auto decl = expression.isDeclarationExp)
            return runDeclarationExpression(decl, walker);

        if (auto dotVar = expression.isDotVarExp) {
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (auto fields = ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration)
                            return Value((*fields).get(fieldDecl, 0));
            unsupported;
        }

        if (isComparisonExpression(expression))
            return runComparisonExpression(expression, walker);

        if (auto assign = expression.isAssignExp)
            return runAssignExpression(assign, walker);

        if (auto addAssign = expression.isAddAssignExp) {
            if (auto var = addAssign.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const newVal = locals[varDecl].asLong + runExpression(addAssign.e2, walker).asLong;
                        locals[varDecl] = Value(newVal);
                        return Value(newVal);
                    }
            unsupported;
        }

        if (auto add = expression.isAddExp)
            return Value(runExpression(add.e1, walker).asLong + runExpression(add.e2, walker).asLong);

        if (auto subtract = expression.isMinExp)
            return Value(runExpression(subtract.e1, walker).asLong - runExpression(subtract.e2, walker).asLong);

        if (auto multiply = expression.isMulExp)
            return Value(runExpression(multiply.e1, walker).asLong * runExpression(multiply.e2, walker).asLong);

        if (auto divide = expression.isDivExp) {
            const right = runExpression(divide.e2, walker).asLong;
            if (right == 0)
                throw new Exception("Division by zero.");
            return Value(runExpression(divide.e1, walker).asLong / right);
        }

        if (auto modulo = expression.isModExp) {
            const right = runExpression(modulo.e2, walker).asLong;
            if (right == 0)
                throw new Exception("Division by zero.");
            return Value(runExpression(modulo.e1, walker).asLong % right);
        }

        if (auto cast_ = expression.isCastExp)
            return coerceValueToType(runExpression(cast_.e1, walker), cast_.to);

        if (auto slice = expression.isSliceExp) {
            if (slice.lwr is null && slice.upr is null)
                if (auto var = slice.e1.isVarExp)
                    if (auto varDecl = var.var.isVarDeclaration)
                        if (varDecl in locals)
                            return locals[varDecl];
            unsupported;
        }

        if (auto index = expression.isIndexExp) {
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const i = runExpression(index.e2, walker).asLong;
                        return Value(locals[varDecl].asArray[cast(size_t) i]);
                    }
            unsupported;
        }

        if (auto len = expression.isArrayLengthExp) {
            if (auto var = len.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals)
                        return Value(cast(long) locals[varDecl].asArray.length);
            unsupported;
        }

        if (auto var = expression.isVarExp) {
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl in locals)
                    return locals[varDecl];
        }

        unsupported;
        assert(false);
    }

    private Value runCallExpression(
        imported!"dmd.expression".CallExp call,
        ref Walker walker,
    ) {
        import std.conv: text;

        if (call.f is null) {
            string argStr;
            if (call.arguments !is null)
                foreach (arg; callArguments(call))
                    argStr ~= " " ~ expressionChars(arg);
            throw new Exception(text(
                "Unsupported callee: ",
                expressionChars(call.e1),
                " args:",
                argStr,
            ));
        }

        {
            import dmd.id: Id;

            if (call.f.ident == Id.__equals) {
                Value[] eqArgs;
                if (call.arguments !is null)
                    foreach (arg; callArguments(call))
                        eqArgs ~= runExpression(arg, walker);
                if (eqArgs.length != 2)
                    throw new Exception("Unsupported expression: call");
                return Value(eqArgs[0] == eqArgs[1] ? 1L : 0L);
            }
        }

        if (call.f.fbody is null)
            throw new Exception("No function body to execute.");

        Value[] args;
        if (call.arguments !is null)
            foreach (arg; callArguments(call))
                args ~= runExpression(arg, walker);
        return walker.executeFunction(call.f, args);
    }

    private Value runEqualExpression(
        imported!"dmd.expression".EqualExp equal,
        ref Walker walker,
    ) {
        import dmd.tokens: EXP;

        const left  = runExpression(equal.e1, walker);
        const right = runExpression(equal.e2, walker);
        if (equal.op == EXP.notEqual)
            return Value(left != right ? 1L : 0L);
        return Value(left == right ? 1L : 0L);
    }

    private Value runDeclarationExpression(
        imported!"dmd.expression".DeclarationExp decl,
        ref Walker walker,
    ) {
        import std.conv: text;

        const unsupportedMessage = text("Unsupported expression: ", decl.op);

        void unsupportedDecl() {
            throw new Exception(unsupportedMessage);
        }

        if (decl.declaration.isAliasDeclaration !is null)
            return Value(0L);

        auto variable = decl.declaration.isVarDeclaration;
        if (variable is null)
            unsupportedDecl;

        if (variable.type !is null && variable.type.isTypeStruct !is null) {
            structFields[variable] = (long[VarDeclaration]).init;
            return Value(0L);
        }

        if (variable.type !is null && variable.type.isTypeDArray !is null)
            return initializeArrayVariable(variable, walker, unsupportedMessage);

        if (variable._init is null)
            unsupportedDecl;
        auto initializer = variable._init.isExpInitializer;
        if (initializer is null)
            unsupportedDecl;
        auto construct = initializer.exp.isConstructExp;
        if (construct is null)
            unsupportedDecl;
        Value value = coerceValueToType(
            runExpression(construct.e2, walker),
            variable.type,
        );
        locals[variable] = value;
        return value;
    }

    private Value initializeArrayVariable(
        VarDeclaration variable,
        ref Walker walker,
        in string unsupportedMessage,
    ) {
        if (variable._init is null) {
            locals[variable] = Value((long[]).init);
            return Value(0L);
        }

        auto initializer = variable._init.isExpInitializer;
        if (initializer is null)
            throw new Exception(unsupportedMessage);

        if (auto construct = initializer.exp.isConstructExp) {
            if (auto literal = construct.e2.isArrayLiteralExp) {
                long[] elements;
                if (literal.elements !is null)
                    foreach (elem; arrayLiteralElements(literal))
                        elements ~= coerceIntegerToType(
                            runExpression(elem, walker).asLong,
                            arrayElementType(variable.type),
                        );
                locals[variable] = Value(elements);
                return Value(0L);
            }

            locals[variable] = coerceValueToType(
                runExpression(construct.e2, walker),
                variable.type,
            );
            return Value(0L);
        }

        locals[variable] = coerceValueToType(
            runExpression(initializer.exp, walker),
            variable.type,
        );
        return Value(0L);
    }

    private bool isComparisonExpression(
        imported!"dmd.expression".Expression expression,
    ) {
        import dmd.tokens: EXP;

        return
            expression.op == EXP.lessThan ||
            expression.op == EXP.greaterThan ||
            expression.op == EXP.lessOrEqual ||
            expression.op == EXP.greaterOrEqual;
    }

    private Value runComparisonExpression(
        imported!"dmd.expression".Expression expression,
        ref Walker walker,
    ) {
        import dmd.tokens: EXP;

        auto cmp = expression.isBinExp;
        const left = runExpression(cmp.e1, walker).asLong;
        const right = runExpression(cmp.e2, walker).asLong;

        if (expression.op == EXP.lessThan)
            return Value(left < right ? 1L : 0L);
        if (expression.op == EXP.greaterThan)
            return Value(left > right ? 1L : 0L);
        if (expression.op == EXP.lessOrEqual)
            return Value(left <= right ? 1L : 0L);
        return Value(left >= right ? 1L : 0L);
    }

    private Value runAssignExpression(
        imported!"dmd.expression".AssignExp assign,
        ref Walker walker,
    ) {
        const value = runExpression(assign.e2, walker);

        if (auto var = assign.e1.isVarExp)
            if (auto varDecl = var.var.isVarDeclaration)
                if (varDecl in locals) {
                    locals[varDecl] = coerceValueToType(value, varDecl.type);
                    return value;
                }

        if (auto dotVar = assign.e1.isDotVarExp)
            if (auto ownerVar = dotVar.e1.isVarExp)
                if (auto ownerDecl = ownerVar.var.isVarDeclaration)
                    if (ownerDecl in structFields)
                        if (auto fieldDecl = dotVar.var.isVarDeclaration) {
                            structFields[ownerDecl][fieldDecl] =
                                coerceIntegerToType(value.asLong, fieldDecl.type);
                            return value;
                        }

        if (auto index = assign.e1.isIndexExp)
            if (auto var = index.e1.isVarExp)
                if (auto varDecl = var.var.isVarDeclaration)
                    if (varDecl in locals) {
                        const i = runExpression(index.e2, walker).asLong;
                        locals[varDecl].asArray[cast(size_t) i] =
                            coerceIntegerToType(
                                value.asLong,
                                arrayElementType(varDecl.type),
                            );
                        return value;
                    }

        import std.conv: text;
        throw new Exception(text("Unsupported expression: ", expressionChars(assign)));
    }
}

private long asLong(Value value) {
    import std.sumtype: match;
    return value.match!(
        (long l) => l,
        (long[] _) {
            throw new Exception("Expected scalar, got array.");
            return 0L;
        },
    );
}

private long[] asArray(Value value) {
    import std.sumtype: match;
    return value.match!(
        (long[] a) => a,
        (long _) {
            throw new Exception("Expected array, got scalar.");
            return (long[]).init;
        },
    );
}

private Value coerceValueToType(
    Value value,
    imported!"dmd.mtype".Type type,
) {
    import std.sumtype: match;

    if (type is null)
        return value;

    return value.match!(
        (long l) => Value(coerceIntegerToType(l, type)),
        (long[] a) => Value(a),
    );
}

private long coerceIntegerToType(
    in long value,
    imported!"dmd.mtype".Type type,
) @trusted {
    import dmd.astenums: TY;

    if (type is null)
        return value;

    const basetype = type.toBasetype;
    switch (basetype.ty) {
        case TY.Tint8:
            return cast(long) cast(byte) value;
        case TY.Tuns8:
            return cast(long) cast(ubyte) value;
        case TY.Tint16:
            return cast(long) cast(short) value;
        case TY.Tuns16:
            return cast(long) cast(ushort) value;
        case TY.Tint32:
            return cast(long) cast(int) value;
        case TY.Tuns32:
            return cast(long) cast(uint) value;
        case TY.Tint64:
            return cast(long) value;
        case TY.Tuns64:
            return cast(long) cast(ulong) value;
        default:
            return value;
    }
}

private imported!"dmd.mtype".Type arrayElementType(
    imported!"dmd.mtype".Type type,
) @trusted {
    if (type is null)
        return null;

    return type.toBasetype.nextOf;
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

private ref auto arrayLiteralElements(
    imported!"dmd.expression".ArrayLiteralExp literal,
) @trusted {
    return *literal.elements;
}
