module ut.backends.interpreter.lvalue_place;


import ut;
import ut.backends.interpreter: structTypeOf;
import quickbite.frontend.compiler: parseSnippet;
import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;
import quickbite.backends.interpreter.layout: fieldByteOffset, structFields, typeByteSize;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.lang: Value;
import dmd.func: FuncDeclaration;
import dmd.dmodule: Module;
import dmd.arraytypes: Dsymbols;
import dmd.declaration: VarDeclaration;
import dmd.expression: Expression, AssignExp;
import dmd.statement: Statement;

private:


FuncDeclaration findFunction(
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
FuncDeclaration findFunction(
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

// The first assignment's left-hand side found in `statement`, searching
// through `CompoundStatement`/`ScopeStatement` wrapping to reach the
// `ExpStatement` underneath -- every fixture below has exactly one
// assignment in its body, so the first one found is the one under test.
AssignExp firstAssignExp(Statement statement) {
    if (statement is null)
        return null;

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements is null)
            return null;
        foreach (child; *compound.statements)
            if (auto found = firstAssignExp(child))
                return found;
        return null;
    }

    if (auto scope_ = statement.isScopeStatement)
        return firstAssignExp(scope_.statement);

    if (auto expStatement = statement.isExpStatement)
        return expStatement.exp is null ? null : expStatement.exp.isAssignExp;

    return null;
}

Expression lvalueTargetOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);
    auto function_ = findFunction(moduleResult.module_, name);
    assert(function_ !is null, "function `" ~ name ~ "` not found in parsed snippet");

    auto assign = firstAssignExp(function_.fbody);
    assert(assign !is null, "no assignment found in function `" ~ name ~ "`'s body");
    return assign.e1;
}


@("placeOfLvalue.varExp.matchesResolverAddressAndVariableType")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueVar(int v) { v = 0; } },
        "quickbiteLvalueVar",
    );

    auto block = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address);

    place.address.should == block.address;
    (place.type is target.type).should == true;
}


// Shared source for the struct-field shapes below: `S.x` is a direct field,
// `S.inner.z` nests one struct-typed field inside another, and both
// functions' single assignment is the fixture under test.
enum structFieldSource = q{
    struct Inner { int z; }
    struct S { int x; Inner inner; }
    void quickbiteLvalueField(S s) { s.x = 0; }
    void quickbiteLvalueNestedField(S s) { s.inner.z = 0; }
};


@("placeOfLvalue.dotVarExp.structFieldComposesBaseAndOffsetWithScalarRoundTrip")
unittest {
    auto target = lvalueTargetOf(structFieldSource, "quickbiteLvalueField");
    auto sType = structTypeOf(structFieldSource, "S");
    auto xField = structFields(sType)[0];

    auto block = NativeBlock.allocate(typeByteSize(sType), NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address);

    (cast(size_t) place.address).should
        == cast(size_t) block.address + fieldByteOffset(xField);

    // Runtime-computed, not a bare literal passed straight to `Value`.
    int written = 4;
    written = written * 3 + 1;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


@("placeOfLvalue.dotVarExp.nestedStructFieldComposesBothOffsets")
unittest {
    auto target = lvalueTargetOf(structFieldSource, "quickbiteLvalueNestedField");
    auto sType = structTypeOf(structFieldSource, "S");
    auto innerField = structFields(sType)[1];
    auto innerType = structTypeOf(structFieldSource, "Inner");
    auto zField = structFields(innerType)[0];

    auto block = NativeBlock.allocate(typeByteSize(sType), NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address);

    (cast(size_t) place.address).should ==
        cast(size_t) block.address
        + fieldByteOffset(innerField)
        + fieldByteOffset(zField);

    int written = 6;
    written = written * 5 + 2;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


@("placeOfLvalue.dotVarExp.classReceiverThrows")
unittest {
    auto target = lvalueTargetOf(
        q{ class C { int x; } void quickbiteLvalueClassField(C c) { c.x = 0; } },
        "quickbiteLvalueClassField",
    );

    auto block = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.no);

    placeOfLvalue(target, (variable) => block.address).shouldThrowWithMessage(
        "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "DotVarExp receiver is not a struct-typed place",
    );
}


// `placeOfLvalue` must throw before ever reaching a `VarExp`/`DotVarExp` and
// calling the resolver, so this resolver asserts if it is ever called.
void* refuseResolveBase(VarDeclaration variable) @safe {
    assert(false, "resolveBase must not be called for a refused shape");
}


@("placeOfLvalue.indexExp.throws")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueIndex(int[3] arr) { arr[0] = 0; } },
        "quickbiteLvalueIndex",
    );

    placeOfLvalue(target, (variable) => refuseResolveBase(variable)).shouldThrowWithMessage(
        "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "unsupported lvalue expression",
    );
}


@("placeOfLvalue.ptrExp.throws")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvaluePtr(int* p) { *p = 0; } },
        "quickbiteLvaluePtr",
    );

    placeOfLvalue(target, (variable) => refuseResolveBase(variable)).shouldThrowWithMessage(
        "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "unsupported lvalue expression",
    );
}
