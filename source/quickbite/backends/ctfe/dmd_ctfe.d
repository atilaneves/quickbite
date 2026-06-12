module quickbite.backends.ctfe.dmd_ctfe;


private:


public class Ctfe: imported!"quickbite.backends".TreeNodeBackend {
    import quickbite.backends: TreeNodeBackend;
    import quickbite.backends.evaluator: Evaluator, EvalResult;
    import quickbite.backends.runner: ExecutionMode;
    import quickbite.lang: Value;
    import dmd.func: FuncDeclaration;

    public alias eval = Evaluator.eval;

    // CTFE is inherently compile-time; the mode exists for constructor
    // uniformity across backends and is ignored.
    public this(in ExecutionMode mode = ExecutionMode.runtime) @safe @nogc nothrow pure {
        super(mode);
    }

    public override EvalResult eval(FuncDeclaration function_) {
        string diagnostic;
        auto interpreted = interpretCtfeWithDiagnostic(
            callExpression(function_),
            diagnostic,
        );
        return diagnostic.length == 0
            ? EvalResult(ctfeValue(interpreted))
            : EvalResult(EvalResult.Diagnostic(diagnostic));
    }
}

private imported!"dmd.expression".Expression interpretCtfeWithDiagnostic(
    imported!"dmd.expression".Expression expression,
    out string diagnostic,
) {
    import quickbite.frontend.compiler: resetErrors, withCompilerLock;
    import dmd.dinterpret: ctfeInterpret;
    import dmd.globals: global;

    imported!"dmd.expression".Expression result;
    withCompilerLock(() {
        resetErrors;
        result = ctfeInterpret(expression);
        if (result.isErrorExp !is null || global.errors != 0)
            diagnostic = diagnosticMessage;
    });

    return result;
}

private string diagnosticMessage() {
    import dmd.errors: diagnostics, ErrorKind;
    import std.algorithm.iteration: filter, map;
    import std.array: array, join;

    const messages = diagnostics
        .filter!(diagnostic => diagnostic.kind == ErrorKind.error)
        .map!(diagnostic => diagnostic.message)
        .array;

    if (messages.length == 0)
        return "DMD reported an error without a diagnostic message.";

    return messages.join("\n");
}

private imported!"dmd.expression".CallExp callExpression(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.arraytypes: Expressions;
    import dmd.expression: CallExp, VarExp;
    import dmd.location: Loc;
    import dmd.mtype: TypeFunction;

    auto varExp = new VarExp(Loc.initial, function_);
    varExp.type = function_.type;
    auto callExp = new CallExp(Loc.initial, varExp, new Expressions);
    auto tf = cast(TypeFunction) function_.type;
    callExp.type = tf.next;
    callExp.f = function_;

    return callExp;
}

private imported!"quickbite.lang".Value ctfeValue(
    imported!"dmd.expression".Expression expression,
) {
    import quickbite.lang: Value;

    if (auto integer = expression.isIntegerExp)
        return integerValue(integer);

    if (auto real_ = expression.isRealExp)
        return realValue(real_);

    if (auto string_ = expression.isStringExp)
        return stringValue(string_);

    if (auto null_ = expression.isNullExp)
        return Value.null_();

    if (auto construct = expression.isConstructExp)
        return ctfeValue(construct.e2);

    if (auto array = expression.isArrayLiteralExp)
        return arrayValue(array);

    if (auto assocArray = expression.isAssocArrayLiteralExp)
        return assocArrayValue(assocArray);

    if (auto struct_ = expression.isStructLiteralExp)
        return structValue(struct_);

    return Value.undisplayable;
}

private imported!"quickbite.lang".Value integerValue(
    imported!"dmd.expression".IntegerExp integer,
) {
    import dmd.astenums: TY;
    import quickbite.frontend.dmd.values: frontendIntegerValue = integerValue;
    import quickbite.lang: Value;

    if (
        integer.type !is null &&
        integer.type.ty == TY.Tenum
    )
        return Value.enumValue(expressionChars(integer));

    return frontendIntegerValue(integer);
}

private string expressionChars(imported!"dmd.expression".Expression expression) @trusted {
    import std.string: fromStringz;

    return expression.toChars.fromStringz.idup;
}

private imported!"quickbite.lang".Value realValue(
    imported!"dmd.expression".RealExp real_,
) {
    import quickbite.frontend.dmd.values: frontendRealValue = realValue;

    return frontendRealValue(real_);
}

private imported!"quickbite.lang".Value stringValue(
    imported!"dmd.expression".StringExp string_,
) {
    import quickbite.lang: Value;

    return Value.stringValue(stringChars(string_));
}

private char[] stringChars(
    imported!"dmd.expression".StringExp string_,
) {
    import std.utf: encode;

    char[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits) {
        const codeUnit = string_.getIndex(index);
        if (string_.sz == 1) {
            values ~= cast(char) codeUnit;
        } else {
            char[4] encoded;
            const length = encode(encoded, cast(dchar) codeUnit);
            values ~= encoded[0 .. length];
        }
    }

    return values;
}

private imported!"quickbite.lang".Value arrayValue(
    imported!"dmd.expression".ArrayLiteralExp array,
) {
    import quickbite.lang: Value;

    Value[] values;
    foreach (index; 0 .. array.elements.length)
        values ~= ctfeValue(array[index]);

    return Value.arrayValue(values);
}

private imported!"quickbite.lang".Value assocArrayValue(
    imported!"dmd.expression".AssocArrayLiteralExp assocArray,
) {
    import quickbite.lang: Value;

    Value[] keys;
    Value[] values;
    foreach (index; 0 .. assocArray.keys.length) {
        keys ~= ctfeValue((*assocArray.keys)[index]);
        values ~= ctfeValue((*assocArray.values)[index]);
    }

    return Value.assocArrayValue(keys, values);
}

private imported!"quickbite.lang".Value structValue(
    imported!"dmd.expression".StructLiteralExp struct_,
) {
    import quickbite.lang: Value;

    Value[] fields;
    if (struct_.elements !is null) {
        foreach (index, element; *struct_.elements) {
            if (element is null)
                continue;

            auto field = structLiteralField(struct_, index);
            if (field is null)
                continue;
            if (isUndisplayableCtfeStructField(field, element))
                continue;

            fields ~= ctfeValue(element);
        }
    }

    return Value.structValue(
        struct_.sd.ident.toString.idup,
        fields,
    );
}

private bool isUndisplayableCtfeStructField(
    imported!"dmd.declaration".VarDeclaration field,
    imported!"dmd.expression".Expression element,
) {
    if (element.isNullExp is null)
        return false;
    if (isSyntheticThisField(field))
        return true;
    return isFunctionLikeType(field.type);
}

private bool isSyntheticThisField(
    imported!"dmd.declaration".VarDeclaration field,
) {
    import dmd.declaration: ThisDeclaration;

    return cast(ThisDeclaration) field !is null;
}

private imported!"dmd.declaration".VarDeclaration structLiteralField(
    imported!"dmd.expression".StructLiteralExp literal,
    in size_t index,
) {
    if (literal.sd is null || index >= literal.sd.fields.length)
        return null;
    return literal.sd.fields[index];
}

private bool isFunctionLikeType(imported!"dmd.mtype".Type type) {
    if (type is null)
        return false;

    auto basetype = type.toBasetype;
    if (basetype.isTypeFunction !is null)
        return true;
    if (basetype.isTypeDelegate !is null)
        return true;
    if (auto pointer = basetype.isTypePointer)
        return pointer.nextOf.isTypeFunction !is null;

    return false;
}

private __gshared uint _diagnosticModuleCounter;
