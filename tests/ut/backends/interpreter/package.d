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


// Finds the `FuncDeclaration` named `name` declared directly in `outer`'s
// own body -- a nested named function appears as a `DeclarationExp` in the
// statement tree exactly like a nested variable (DMD's `statementsem.
// toStatement`, which wraps any nested `Dsymbol` -- variable or function
// alike -- in an `ExpStatement`/`DeclarationExp` pair), just narrowed to
// `.isFuncDeclaration` here instead of `.isVarDeclaration`. Only walks the
// small set of statement shapes a test snippet's straight-line body needs
// (compound/compound-declaration/scope/exp statements); unlike `frame_
// layout.bodyLocals`, this is test-only code with no obligation to mirror
// every statement shape the walker itself runs.
public FuncDeclaration findNestedFunction(
    FuncDeclaration outer,
    in string name,
) {
    return findNestedFunctionIn(outer.fbody, name);
}

private FuncDeclaration findNestedFunctionIn(
    imported!"dmd.statement".Statement statement,
    in string name,
) {
    import dmd.statement: Statement;

    if (statement is null)
        return null;

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements !is null)
            foreach (child; *compound.statements)
                if (auto found = findNestedFunctionIn(child, name))
                    return found;
        return null;
    }

    if (auto compound = statement.isCompoundDeclarationStatement) {
        if (compound.statements !is null)
            foreach (child; *compound.statements)
                if (auto found = findNestedFunctionIn(child, name))
                    return found;
        return null;
    }

    if (auto scope_ = statement.isScopeStatement)
        return findNestedFunctionIn(scope_.statement, name);

    if (auto expression = statement.isExpStatement) {
        if (expression.exp is null)
            return null;

        auto declaration = expression.exp.isDeclarationExp;
        if (declaration is null)
            return null;

        auto function_ = declaration.declaration.isFuncDeclaration;
        if (function_ !is null && function_.ident !is null && function_.ident.toString == name)
            return function_;

        return null;
    }

    return null;
}

// Parses `source`, finds the top-level function `outerName`, and returns
// the `FuncDeclaration` named `nestedName` declared directly in its body --
// the nested-function sibling of `parseFunction` above.
public FuncDeclaration parseNestedFunction(
    in string source,
    in string outerName,
    in string nestedName,
) {
    import dmd.funcsem: functionSemantic3;

    auto outer = parseFunction(source, outerName);
    // `outerVars`/`closureVars` are populated by `checkNestedReference`
    // during the nested function's own body semantic (`funcsem.
    // functionSemantic3`), not by parsing/`dsymbolsem` alone -- force it
    // here so a test can rely on `outerVars` being populated regardless of
    // whether `parseSnippet` already ran it, the same "resolve its body
    // before walking it" precedent `impl.d`'s own constructor/ref-return
    // call sites already apply to a function reached outside normal
    // top-down compilation order.
    functionSemantic3(outer);
    auto nested = findNestedFunction(outer, nestedName);
    assert(nested !is null,
        "nested function `" ~ nestedName ~ "` not found in `" ~ outerName ~ "`'s body");
    functionSemantic3(nested);
    return nested;
}
