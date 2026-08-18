module quickbite.backends.interpreter.class_info_projection;


private:


// Whether `dot.var` is DMD's synthetic `.classinfo` property rather than a
// real declared field that merely shares the name. The synthetic property
// itself normally lowers before it reaches the Interpreter, but keeping this
// predicate precise makes the symbolic fallback inert for real field reads.
public bool isSyntheticClassInfoMember(
    imported!"dmd.expression".DotVarExp dot,
) @trusted {
    if (declarationName(dot.var) != "classinfo")
        return false;
    if (dot.e1.type is null || dot.e1.type.toBasetype.isTypeClass is null)
        return false;
    auto variable = dot.var.isVarDeclaration;
    return variable is null || !variable.isField;
}


// Whether `dot` reads `TypeInfo_Class.name` through the pointer form DMD
// uses for a class-info projection, rather than an unrelated user field.
public bool isClassInfoNamePointerMember(
    imported!"dmd.expression".DotVarExp dot,
) @trusted {
    import dmd.mtype: Type;

    if (declarationName(dot.var) != "name")
        return false;
    auto pointer = dot.e1.isPtrExp;
    if (pointer is null || pointer.type is null)
        return false;
    auto classType = pointer.type.toBasetype.isTypeClass;
    return classType !is null && classType.sym is Type.typeinfoclass;
}


// Whether `dot`'s field-access spine reads class-info in a form the
// Interpreter answers symbolically. Such a projection has no native place,
// so an address-taking caller needs an activation-frame temporary.
public bool isSymbolicClassInfoProjection(
    imported!"dmd.expression".DotVarExp dot,
) @trusted {
    for (auto current = dot; current !is null; current = current.e1.isDotVarExp) {
        if (isSyntheticClassInfoMember(current))
            return true;
        if (isClassInfoNamePointerMember(current))
            return true;
        if (declarationName(current.var) != "name")
            continue;
        if (auto symbol = current.e1.isSymOffExp)
            if (symbolOffsetTypeInfoType(symbol) !is null)
                return true;
    }
    return false;
}


private imported!"dmd.mtype".Type symbolOffsetTypeInfoType(
    imported!"dmd.expression".SymOffExp symbol,
) {
    auto typeInfo = symbol.var.isTypeInfoDeclaration;
    return typeInfo is null ? null : typeInfo.tinfo;
}


private const(char)[] declarationName(
    imported!"dmd.declaration".Declaration declaration,
) @safe {
    return declaration.ident is null ? "" : declaration.ident.toString;
}
