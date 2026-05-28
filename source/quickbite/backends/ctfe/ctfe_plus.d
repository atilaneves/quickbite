module quickbite.backends.ctfe.ctfe_plus;


private:


import quickbite.backends.ctfe.dmd_ctfe: Ctfe;


public class CtfePlus: imported!"quickbite.backend".Backend {
    import quickbite.lang: Value;

    private Ctfe _ctfe;

    public this() {
        _ctfe = new Ctfe;
    }

    public override Value eval(in string expr) {
        return _ctfe.eval(expr);
    }

    public override Value evalRepl(
        in imported!"quickbite.frontend.repl".ReplCell cell,
    ) {
        return _ctfe.evalRepl(cell);
    }

    public override void runParsedTests(
        imported!"dmd.dmodule".Module module_,
    ) {
        if (_ctfe.canHandle(module_)) {
            _ctfe.runParsedTests(module_);
        } else {
            runMutableStaticRegistryTests(module_);
        }
    }

    private void runMutableStaticRegistryTests(
        imported!"dmd.dmodule".Module module_,
    ) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;

        MutableStaticRegistryRunner runner;
        foreachUnitTestDeclaration(module_, (unitTest) {
            runner.runTest(unitTest);
        });
    }
}

private struct RuntimeValue {
    import dmd.func: FuncDeclaration;

    RuntimeKind kind;
    long integer;
    long[] array;
    string text;
    size_t objectId;
    FuncDeclaration function_;

    static RuntimeValue none() {
        return RuntimeValue(RuntimeKind.none);
    }

    static RuntimeValue integerValue(in long value) {
        RuntimeValue result;
        result.kind = RuntimeKind.integer;
        result.integer = value;
        return result;
    }

    static RuntimeValue arrayValue(return scope long[] value) {
        RuntimeValue result;
        result.kind = RuntimeKind.array;
        result.array = value.dup;
        return result;
    }

    static RuntimeValue stringValue(in string value) {
        RuntimeValue result;
        result.kind = RuntimeKind.string_;
        result.text = value;
        return result;
    }

    static RuntimeValue objectValue(in size_t id) {
        RuntimeValue result;
        result.kind = RuntimeKind.object;
        result.objectId = id;
        return result;
    }

    static RuntimeValue delegateValue(FuncDeclaration function_) {
        RuntimeValue result;
        result.kind = RuntimeKind.delegate_;
        result.function_ = function_;
        return result;
    }
}

private enum RuntimeKind {
    none,
    integer,
    array,
    string_,
    object,
    delegate_,
}

private struct StaticRegistrySlot {
    import dmd.declaration: VarDeclaration;

    VarDeclaration registry;
    string key;

    bool opCast(T: bool)() const {
        return registry !is null;
    }
}

private struct MutableStaticRegistryRunner {
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AssignExp,
        BinExp,
        BinAssignExp,
        CallExp,
        CatAssignExp,
        DeclarationExp,
        DotVarExp,
        Expression,
        FuncExp,
        IndexExp,
        NewExp;
    import dmd.func: FuncDeclaration, UnitTestDeclaration;
    import dmd.mtype: Type;
    import dmd.statement: Statement;

    private RuntimeValue[VarDeclaration] locals;
    private RuntimeValue[VarDeclaration][VarDeclaration] structFields;
    private RuntimeValue[VarDeclaration][size_t] objectFields;
    private Type[size_t] objectTypes;
    private RuntimeValue[string][VarDeclaration] staticRegistries;
    private StaticRegistrySlot[VarDeclaration] staticRegistrySlots;
    private VarDeclaration currentThis;
    private size_t nextObjectId = 1;

    public void runTest(UnitTestDeclaration unitTest) {
        runStatement(unitTest.fbody);
    }

    private void runStatement(Statement statement) {
        if (statement is null)
            return;

        if (auto scope_ = statement.isScopeStatement) {
            runStatement(scope_.statement);
            return;
        }

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; compoundStatements(compound))
                    runStatement(child);
            return;
        }

        if (auto compound = statement.isCompoundDeclarationStatement) {
            if (compound.statements !is null)
                foreach (child; compoundStatements(compound))
                    runStatement(child);
            return;
        }

        if (statement.isDtorExpStatement !is null)
            return;

        if (auto expression = statement.isExpStatement) {
            runExpression(expression.exp);
            return;
        }

        if (statement.isReturnStatement !is null)
            return;

        import std.conv: text;
        throw new Exception(text("Unsupported CtfePlus statement: ", statement.stmt));
    }

    private RuntimeValue runExpression(Expression expression) {
        if (expression is null)
            return RuntimeValue.none;

        if (auto integer = expression.isIntegerExp)
            return RuntimeValue.integerValue(integer.getInteger);

        if (auto cast_ = expression.isCastExp)
            return runExpression(cast_.e1);

        if (auto comma = expression.isCommaExp) {
            runExpression(comma.e1);
            return runExpression(comma.e2);
        }

        if (auto function_ = expression.isFuncExp)
            return RuntimeValue.delegateValue(function_.fd);

        if (auto declaration = expression.isDeclarationExp)
            return runDeclaration(declaration);

        if (auto assign = expression.isAssignExp)
            return runAssign(assign);

        if (auto construct = expression.isConstructExp)
            return runAssign(construct);

        if (auto blit = expression.isBlitExp)
            return runAssign(blit);

        if (auto append = expression.isCatAssignExp)
            return runAppend(append);

        if (auto append = expression.isCatElemAssignExp)
            return runAppend(append);

        if (auto assign = expression.isBinAssignExp)
            return runAssign(assign);

        if (auto new_ = expression.isNewExp)
            return runNew(new_);

        if (auto call = expression.isCallExp)
            return runCall(call);

        if (auto assert_ = expression.isAssertExp) {
            if (runExpression(assert_.e1).integer == 0)
                throw new Exception(
                    "Unittest assertion failed: " ~ expressionChars(assert_.e1),
                );
            return RuntimeValue.none;
        }

        if (auto equal = expression.isEqualExp)
            return RuntimeValue.integerValue(
                runtimeEquals(runExpression(equal.e1), runExpression(equal.e2)),
            );

        if (auto index = expression.isIndexExp)
            return runIndex(index);

        if (auto dotVar = expression.isDotVarExp)
            return runDotVar(dotVar);

        if (auto length = expression.isArrayLengthExp)
            return RuntimeValue.integerValue(
                cast(long) runExpression(length.e1).array.length,
            );

        if (auto variable = expression.isVarExp) {
            auto declaration = variable.var.isVarDeclaration;
            if (declaration !is null)
                return localValue(declaration);
        }

        if (auto this_ = expression.isThisExp)
            return RuntimeValue.none;

        import std.conv: text;
        throw new Exception(text(
            "Unsupported CtfePlus expression: ",
            expression.op,
            " ",
            expressionChars(expression),
        ));
    }

    private RuntimeValue runDeclaration(DeclarationExp declaration) {
        auto variable = declaration.declaration.isVarDeclaration;
        if (variable is null)
            return RuntimeValue.none;

        if (variable.type !is null && variable.type.toBasetype.isTypeStruct !is null)
            structFields[variable] = defaultStructFields(variable.type);

        if (variable._init !is null)
            if (auto initializer = variable._init.isExpInitializer)
                assignVariable(variable, runExpression(initializer.exp));

        if (variable !in locals)
            locals[variable] = RuntimeValue.integerValue(0);

        return locals[variable];
    }

    private RuntimeValue runAssign(BinExp assign) {
        if (auto index = staticRegistryIndex(assign.e1))
            if (auto registry = staticRegistryDeclaration(index.e1)) {
                auto value = runExpression(assign.e2);
                staticRegistries[registry][runString(index.e2)] = value;
                return value;
            }

        if (auto slot = loweredStaticRegistrySlot(assign.e2))
            if (auto variable = assign.e1.isVarExp)
                if (auto declaration = variable.var.isVarDeclaration) {
                    staticRegistrySlots[declaration] = slot;
                    return RuntimeValue.none;
                }

        auto value = runExpression(assign.e2);

        if (auto variable = assign.e1.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (auto slot = declaration in staticRegistrySlots) {
                    staticRegistries[slot.registry][slot.key] = value;
                    return value;
                }
                assignVariable(declaration, value);
                return value;
            }

        if (auto dotVar = assign.e1.isDotVarExp)
            if (auto field = dotVar.var.isVarDeclaration) {
                assignField(dotVar.e1, field, value);
                return value;
            }

        import std.conv: text;

        throw new Exception(text(
            "Unsupported CtfePlus assignment: ",
            expressionChars(assign),
        ));
    }

    private RuntimeValue runAppend(CatAssignExp append) {
        auto dotVar = append.e1.isDotVarExp;
        if (dotVar is null)
            unsupportedAppend(append);

        auto field = dotVar.var.isVarDeclaration;
        if (field is null)
            unsupportedAppend(append);

        auto fields = fieldsFor(dotVar.e1);
        if (fields is null)
            unsupportedAppend(append);

        long[] elements = fieldValue(
            *fields,
            field,
            RuntimeValue.arrayValue((long[]).init),
        ).array;
        elements ~= runExpression(append.e2).integer;
        setField(*fields, field, RuntimeValue.arrayValue(elements));
        return fieldValue(*fields, field, RuntimeValue.arrayValue(elements));
    }

    private RuntimeValue runNew(NewExp new_) {
        const id = nextObjectId;
        ++nextObjectId;
        objectTypes[id] = new_.newtype;
        objectFields[id] = defaultClassFields(new_.newtype);

        if (new_.member !is null)
            executeFunction(
                new_.member,
                RuntimeValue.objectValue(id),
                new_.arguments is null ? null : newArguments(new_),
            );

        return RuntimeValue.objectValue(id);
    }

    private RuntimeValue runCall(CallExp call) {
        if (auto index = staticRegistryIndex(call.e1))
            if (auto registry = staticRegistryDeclaration(index.e1)) {
                auto delegate_ = staticRegistries[registry][runString(index.e2)];
                runRegistryDelegate(delegate_.function_, callArguments(call));
                return RuntimeValue.none;
            }

        if (call.f is null) {
            import std.conv: text;
            throw new Exception(text(
                "Unsupported CtfePlus callee: ",
                expressionChars(call.e1),
            ));
        }

        if (auto dotVar = call.e1.isDotVarExp)
            if (dotVar.var is call.f)
                if (auto receiver = receiverStruct(dotVar.e1)) {
                    if (call.f.vthis is null)
                        throw new Exception("Unsupported CtfePlus member call.");
                    structFields[call.f.vthis] = structFields[receiver].dup;
                    bindParameters(
                        call.f,
                        call.arguments is null ? null : callArguments(call),
                    );
                    auto previousThis = currentThis;
                    currentThis = call.f.vthis;
                    runStatement(call.f.fbody);
                    currentThis = previousThis;
                    structFields[receiver] = structFields[call.f.vthis].dup;
                    return RuntimeValue.none;
                }

        executeFunction(
            call.f,
            RuntimeValue.none,
            call.arguments is null ? null : callArguments(call),
        );
        return RuntimeValue.none;
    }

    private RuntimeValue runIndex(IndexExp index) {
        const indexed = runExpression(index.e1);
        if (indexed.kind == RuntimeKind.array) {
            const offset = cast(size_t) runExpression(index.e2).integer;
            return RuntimeValue.integerValue(indexed.array[offset]);
        }

        import std.conv: text;
        throw new Exception(text(
            "Unsupported CtfePlus index: ",
            expressionChars(index),
        ));
    }

    private RuntimeValue runDotVar(DotVarExp dotVar) {
        if (fieldNamed(dotVar, "name"))
            if (auto classInfo = dotVar.e1.isDotVarExp)
                if (fieldNamed(classInfo, "classinfo"))
                    return RuntimeValue.stringValue(className(classInfo.e1));
        if (fieldNamed(dotVar, "name"))
            if (dotVar.e1.isTypeidExp)
                return RuntimeValue.stringValue(className(dotVar.e1));
        if (fieldNamed(dotVar, "name"))
            if (dotVar.e1.isSymOffExp)
                return RuntimeValue.stringValue(className(dotVar.e1));
        if (fieldNamed(dotVar, "name"))
            if (dotVar.e1.isPtrExp)
                return RuntimeValue.stringValue(className(dotVar.e1));

        if (fieldNamed(dotVar, "length")) {
            const value = runExpression(dotVar.e1);
            if (value.kind == RuntimeKind.array)
                return RuntimeValue.integerValue(cast(long) value.array.length);
        }

        auto field = dotVar.var.isVarDeclaration;
        if (field !is null)
            if (auto fields = fieldsFor(dotVar.e1))
                return fieldValue(*fields, field, defaultValue(field.type));

        import std.conv: text;
        throw new Exception(text(
            "Unsupported CtfePlus member access: ",
            dotVar.e1.op,
            " ",
            expressionChars(dotVar),
        ));
    }

    private void executeFunction(
        FuncDeclaration function_,
        RuntimeValue thisValue,
        Expression[] arguments,
    ) {
        if (function_.vthis !is null && thisValue.kind == RuntimeKind.object)
            structFields[function_.vthis] = objectFields[thisValue.objectId].dup;
        else if (function_.vthis !is null && thisValue.kind == RuntimeKind.none)
            structFields[function_.vthis] = structFields[function_.vthis].dup;

        bindParameters(function_, arguments);
        runStatement(function_.fbody);

        if (function_.vthis !is null && thisValue.kind == RuntimeKind.object)
            objectFields[thisValue.objectId] = structFields[function_.vthis].dup;
    }

    private void bindParameters(
        FuncDeclaration function_,
        Expression[] arguments,
    ) {
        if (function_.parameters is null)
            return;

        foreach (i, parameter; functionParameters(function_))
            assignVariable(parameter, runExpression(arguments[i]));
    }

    private void runRegistryDelegate(
        FuncDeclaration function_,
        Expression[] arguments,
    ) {
        auto writer = arguments[0].isThisExp;
        if (writer is null)
            throw new Exception("Unsupported CtfePlus registry writer.");

        auto writerVariable = currentThis is null
            ? writer.var.isVarDeclaration
            : currentThis;
        if (writerVariable is null)
            throw new Exception("Unsupported CtfePlus registry writer.");

        foreach (i, parameter; functionParameters(function_)) {
            if (i == 0) {
                structFields[parameter] = structFields[writerVariable].dup;
                locals[parameter] = RuntimeValue.none;
            } else {
                assignVariable(parameter, runExpression(arguments[i]));
            }
        }

        runStatement(function_.fbody);
        structFields[writerVariable] = structFields[functionParameters(function_)[0]]
            .dup;
    }

    private VarDeclaration receiverStruct(Expression expression) {
        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                auto fields = declaration in structFields;
                if (fields is null)
                    throw new Exception("Unsupported CtfePlus receiver.");
                return declaration;
            }

        return null;
    }

    private void assignVariable(VarDeclaration variable, RuntimeValue value) {
        if (variable.type !is null && variable.type.toBasetype.isTypeStruct !is null) {
            structFields[variable] = defaultStructFields(variable.type);
            locals[variable] = RuntimeValue.none;
            return;
        }

        locals[variable] = value;
    }

    private RuntimeValue localValue(VarDeclaration variable) {
        if (auto value = variable in locals)
            return *value;
        if (variable in structFields)
            return RuntimeValue.none;

        import std.conv: text;
        throw new Exception(text("Unsupported CtfePlus variable: ", variableName(variable)));
    }

    private string runString(Expression expression) {
        const value = runExpression(expression);
        if (value.kind == RuntimeKind.string_)
            return value.text;

        import std.conv: text;
        throw new Exception(text(
            "Unsupported CtfePlus string expression: ",
            expressionChars(expression),
        ));
    }

    private long runtimeEquals(RuntimeValue left, RuntimeValue right) {
        if (left.kind == RuntimeKind.integer && right.kind == RuntimeKind.integer)
            return left.integer == right.integer;
        if (left.kind == RuntimeKind.string_ && right.kind == RuntimeKind.string_)
            return left.text == right.text;
        return 0;
    }

    private VarDeclaration staticRegistryDeclaration(Expression expression) {
        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (declaration.isDataseg)
                    return declaration;
                else if (auto registry = knownStaticRegistry(declaration))
                    return registry;
            }

        if (auto dotVar = expression.isDotVarExp)
            if (auto declaration = dotVar.var.isVarDeclaration) {
                if (declaration.isDataseg)
                    return declaration;
                else if (auto registry = knownStaticRegistry(declaration))
                    return registry;
            }

        return null;
    }

    private VarDeclaration knownStaticRegistry(VarDeclaration declaration) {
        foreach (registry; staticRegistries.byKey)
            if (sameVariable(registry, declaration))
                return registry;

        return null;
    }

    private IndexExp staticRegistryIndex(Expression expression) {
        if (auto index = expression.isIndexExp) {
            if (staticRegistryDeclaration(index.e1) !is null)
                return index;
            if (index.loweredFrom !is null)
                return staticRegistryIndex(index.loweredFrom);
        }

        if (auto call = expression.isCallExp)
            if (call.loweredFrom !is null)
                return staticRegistryIndex(call.loweredFrom);

        return null;
    }

    private StaticRegistrySlot loweredStaticRegistrySlot(Expression expression) {
        auto call = expression.isCallExp;
        if (call is null || !functionNamed(call.f, "_d_aaGetY"))
            return StaticRegistrySlot.init;

        auto arguments = callArguments(call);
        if (arguments.length < 2)
            return StaticRegistrySlot.init;

        auto registry = staticRegistryDeclaration(arguments[0]);
        if (registry is null)
            return StaticRegistrySlot.init;

        StaticRegistrySlot slot;
        slot.registry = registry;
        slot.key = runString(arguments[1]);
        return slot;
    }

    private RuntimeValue[VarDeclaration]* fieldsFor(Expression expression) {
        if (auto this_ = expression.isThisExp)
            if (auto declaration = this_.var.isVarDeclaration)
                return declaration in structFields;

        if (auto variable = expression.isVarExp)
            if (auto declaration = variable.var.isVarDeclaration) {
                if (auto value = declaration in locals)
                    if (value.kind == RuntimeKind.object)
                        return value.objectId in objectFields;
                return declaration in structFields;
            }

        RuntimeValue value;
        try {
            value = runExpression(expression);
        } catch (Exception) {
            return null;
        }

        if (value.kind == RuntimeKind.object)
            return value.objectId in objectFields;
        return null;
    }

    private void assignField(
        Expression owner,
        VarDeclaration field,
        RuntimeValue value,
    ) {
        auto fields = fieldsFor(owner);
        if (fields is null)
            throw new Exception("Unsupported CtfePlus field assignment.");
        setField(*fields, field, value);
    }

    private RuntimeValue fieldValue(
        RuntimeValue[VarDeclaration] fields,
        VarDeclaration field,
        RuntimeValue default_,
    ) {
        foreach (storedField, value; fields)
            if (sameVariable(storedField, field))
                return value;
        return default_;
    }

    private void setField(
        ref RuntimeValue[VarDeclaration] fields,
        VarDeclaration field,
        RuntimeValue value,
    ) {
        foreach (storedField; fields.byKey)
            if (sameVariable(storedField, field)) {
                fields[storedField] = value;
                return;
            }
        fields[field] = value;
    }

    private RuntimeValue[VarDeclaration] defaultClassFields(Type type) {
        RuntimeValue[VarDeclaration] fields;
        foreach (field; classFields(type))
            fields[field] = defaultValue(field.type);
        return fields;
    }

    private RuntimeValue[VarDeclaration] defaultStructFields(Type type) {
        RuntimeValue[VarDeclaration] fields;
        foreach (field; aggregateStructFields(type))
            fields[field] = defaultValue(field.type);
        return fields;
    }

    private RuntimeValue defaultValue(Type type) {
        if (type !is null && type.toBasetype.isTypeDArray !is null)
            return RuntimeValue.arrayValue((long[]).init);
        return RuntimeValue.integerValue(0);
    }

    private string className(Expression expression) {
        Type type;
        if (auto typeExp = expression.isTypeExp)
            type = typeExp.type;
        else if (auto ptr = expression.isPtrExp)
            return className(ptr.e1);
        else if (auto typeid_ = expression.isTypeidExp) {
            import dmd.dtemplate: isType;

            type = isType(typeid_.obj);
        }
        else if (auto symbol = expression.isSymOffExp) {
            if (auto typeInfo = symbol.var.isTypeInfoDeclaration)
                type = typeInfo.tinfo;
        }
        else {
            const value = runExpression(expression);
            if (value.kind == RuntimeKind.object)
                type = objectTypes[value.objectId];
        }

        if (type is null)
            throw new Exception("Unsupported CtfePlus classinfo.");
        return typeChars(type);
    }

    private void unsupportedAppend(CatAssignExp append) {
        import std.conv: text;
        throw new Exception(text(
            "Unsupported CtfePlus append: ",
            expressionChars(append),
        ));
    }
}

private bool fieldNamed(
    imported!"dmd.expression".DotVarExp dotVar,
    in string name,
) {
    return dotVar.var !is null &&
        dotVar.var.ident !is null &&
        dotVar.var.ident.toString == name;
}

private bool functionNamed(
    imported!"dmd.func".FuncDeclaration function_,
    in string name,
) {
    return function_ !is null &&
        function_.ident !is null &&
        function_.ident.toString == name;
}

private bool sameVariable(
    imported!"dmd.declaration".VarDeclaration left,
    imported!"dmd.declaration".VarDeclaration right,
) {
    if (left is right)
        return true;
    if (left is null ||
        right is null ||
        left.ident is null ||
        right.ident is null ||
        left.ident.toString != right.ident.toString)
        return false;
    if (left.type is null || right.type is null)
        return left.type is right.type;
    return typeChars(left.type) == typeChars(right.type);
}

private imported!"dmd.declaration".VarDeclaration[] classFields(
    imported!"dmd.mtype".Type type,
) {
    import dmd.dclass: ClassDeclaration;

    imported!"dmd.declaration".VarDeclaration[] fields;
    if (type is null)
        return fields;

    ClassDeclaration[] classes;
    for (auto class_ = type.toBasetype.isTypeClass.sym;
        class_ !is null;
        class_ = class_.baseClass)
        classes ~= class_;

    foreach_reverse (class_; classes)
        foreach (field; class_.fields)
            fields ~= field;

    return fields;
}

private imported!"dmd.declaration".VarDeclaration[] aggregateStructFields(
    imported!"dmd.mtype".Type type,
) {
    imported!"dmd.declaration".VarDeclaration[] fields;
    if (type is null)
        return fields;

    if (auto structType = type.toBasetype.isTypeStruct)
        foreach (field; structType.sym.fields)
            fields ~= field;

    return fields;
}

private ref auto compoundStatements(
    imported!"dmd.statement".CompoundStatement compound,
) @trusted pure {
    return *compound.statements;
}

private imported!"dmd.expression".Expression[] callArguments(
    imported!"dmd.expression".CallExp call,
) @trusted pure {
    return (*call.arguments)[];
}

private ref auto functionParameters(
    imported!"dmd.func".FuncDeclaration function_,
) @trusted pure {
    return *function_.parameters;
}

private imported!"dmd.expression".Expression[] newArguments(
    imported!"dmd.expression".NewExp new_,
) @trusted {
    return (*new_.arguments)[];
}

private string expressionChars(
    imported!"dmd.expression".Expression expression,
) @trusted {
    import std.string: fromStringz;

    return fromStringz(expression.toChars).idup;
}

private string variableName(
    imported!"dmd.declaration".VarDeclaration variable,
) @trusted {
    import std.string: fromStringz;

    return fromStringz(variable.toChars).idup;
}

private string typeChars(imported!"dmd.mtype".Type type) @trusted {
    import std.string: fromStringz;

    return fromStringz(type.toChars).idup;
}
