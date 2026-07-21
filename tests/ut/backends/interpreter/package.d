module ut.backends.interpreter;


import ut;
import quickbite.frontend.compiler: parseSnippet;
import dmd.mtype: TypeStruct, TypeEnum, TypeClass;
import dmd.func: FuncDeclaration;
import dmd.dmodule: Module;
import dmd.arraytypes: Dsymbols;
import dmd.declaration: VarDeclaration;


// Parses `source`, finds the `struct` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeStruct`.
public TypeStruct structTypeOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members)
        if (auto struct_ = member.isStructDeclaration)
            if (struct_.ident.toString == name) {
                auto structType = struct_.type.isTypeStruct;
                assert(structType !is null,
                    "struct `" ~ name ~ "`'s type is not a TypeStruct");
                return structType;
            }

    assert(false, "struct `" ~ name ~ "` not found in parsed snippet");
}


// Parses `source`, finds the `enum` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeEnum`.
public TypeEnum enumTypeOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members)
        if (auto enum_ = member.isEnumDeclaration)
            if (enum_.ident.toString == name) {
                auto enumType = enum_.type.isTypeEnum;
                assert(enumType !is null,
                    "enum `" ~ name ~ "`'s type is not a TypeEnum");
                return enumType;
            }

    assert(false, "enum `" ~ name ~ "` not found in parsed snippet");
}


// Parses `source`, finds the `class` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeClass` -- the class-typed sibling of `structTypeOf`/`enumTypeOf`
// above.
public TypeClass classTypeOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members)
        if (auto class_ = member.isClassDeclaration)
            if (class_.ident.toString == name) {
                auto classType = class_.type.isTypeClass;
                assert(classType !is null, "class `" ~ name ~ "`'s type is not a TypeClass");
                return classType;
            }

    assert(false, "class `" ~ name ~ "` not found in parsed snippet");
}


// Finds the `FuncDeclaration` named `name` among `module_`'s top-level
// members.
public FuncDeclaration findFunction(
    Module module_,
    in string name,
) {
    return module_.members is null
        ? null
        : findFunction(module_.members, name);
}

// `extern(C)`/`extern(D)`/etc at module scope wraps the declaration in a
// `LinkDeclaration` (an `AttribDeclaration`), so the `FuncDeclaration` is not
// a direct member of the module -- recurse into `AttribDeclaration.decl` to
// find it regardless of how many attribute wrappers surround it.
public FuncDeclaration findFunction(
    Dsymbols* members,
    in string name,
) {
    import dmd.attrib: AttribDeclaration;

    if (members is null)
        return null;

    foreach (member; *members) {
        if (auto function_ = member.isFuncDeclaration)
            if (function_.ident !is null && function_.ident.toString == name)
                return function_;

        if (auto attrib = member.isAttribDeclaration)
            if (auto found = findFunction(attrib.decl, name))
                return found;
    }

    return null;
}

// Parses `source` and returns the `FuncDeclaration` named `name` among its
// top-level members.
public FuncDeclaration parseFunction(in string source, in string name) {
    auto moduleResult = parseSnippet(source);
    auto function_ = findFunction(moduleResult.module_, name);
    assert(function_ !is null, "function `" ~ name ~ "` not found in parsed snippet");
    return function_;
}


// The `VarDeclaration` sibling of `findFunction` above, for a module-level
// variable rather than a function.
public VarDeclaration findVar(
    Module module_,
    in string name,
) {
    return module_.members is null
        ? null
        : findVar(module_.members, name);
}

// Same `AttribDeclaration`-unwrapping recursion as `findFunction` above,
// for a `VarDeclaration` instead of a `FuncDeclaration`.
public VarDeclaration findVar(
    Dsymbols* members,
    in string name,
) {
    import dmd.attrib: AttribDeclaration;

    if (members is null)
        return null;

    foreach (member; *members) {
        if (auto variable = member.isVarDeclaration)
            if (variable.ident !is null && variable.ident.toString == name)
                return variable;

        if (auto attrib = member.isAttribDeclaration)
            if (auto found = findVar(attrib.decl, name))
                return found;
    }

    return null;
}

// Parses `source` and returns the `VarDeclaration` named `name` among its
// top-level members.
public VarDeclaration parseVar(in string source, in string name) {
    auto moduleResult = parseSnippet(source);
    auto variable = findVar(moduleResult.module_, name);
    assert(variable !is null, "variable `" ~ name ~ "` not found in parsed snippet");
    return variable;
}
