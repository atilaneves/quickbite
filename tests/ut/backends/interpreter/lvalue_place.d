module ut.backends.interpreter.lvalue_place;


import ut;
import ut.backends.interpreter: structTypeOf;
import quickbite.frontend.compiler: parseSnippet;
import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;
import quickbite.backends.interpreter.layout: classFields, fieldByteOffset, structFields, typeByteSize;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.lang: Value;
import dmd.func: FuncDeclaration;
import dmd.dmodule: Module;
import dmd.arraytypes: Dsymbols;
import dmd.expression: Expression, AssignExp;
import dmd.statement: Statement;
import dmd.mtype: TypeClass;

private:


// Parses `source`, finds the `class` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeClass` -- mirroring `place.d`'s own local `classTypeOf`, needed here
// too, for the class-field lvalue fixture below.
TypeClass classTypeOf(in string source, in string name) {
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


// `placeOfLvalue` must never call `evalIndex` for a shape that has no
// `IndexExp` in it, so this fake asserts if it is ever called.
size_t refuseEvalIndex(Expression expr) @safe {
    assert(false, "evalIndex must not be called for a shape with no IndexExp");
}


@("placeOfLvalue.varExp.matchesResolverAddressAndVariableType")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueVar(int v) { v = 0; } },
        "quickbiteLvalueVar",
    );

    auto block = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address, (expr) => refuseEvalIndex(expr));

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
    auto place = placeOfLvalue(target, (variable) => block.address, (expr) => refuseEvalIndex(expr));

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
    auto place = placeOfLvalue(target, (variable) => block.address, (expr) => refuseEvalIndex(expr));

    (cast(size_t) place.address).should ==
        cast(size_t) block.address
        + fieldByteOffset(innerField)
        + fieldByteOffset(zField);

    int written = 6;
    written = written * 5 + 2;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


// The centrepiece for a CLASS receiver: `c`'s own place holds a stored
// reference (decision 15), so the receiver's `Place.deref` must land on the
// referenced object body before `.field` composes at that body's own
// `layout.fieldByteOffset` -- the object body block here is sized and laid
// out from `layout.classFields`/`fieldByteOffset` alone, exactly as `place.d`'s
// own `Place.deref` class fixture builds one, never a guessed offset.
@("placeOfLvalue.dotVarExp.classFieldDerefsReceiverThenComposesOffsetWithScalarRoundTrip")
unittest {
    enum source = q{ class C { int x; } void quickbiteLvalueClassField(C c) { c.x = 0; } };

    auto target = lvalueTargetOf(source, "quickbiteLvalueClassField");
    auto classType = classTypeOf(source, "C");
    auto fields = classFields(classType.sym);
    auto xField = fields[0];

    auto bodyByteSize = fieldByteOffset(xField) + typeByteSize(xField.type);
    auto body_ = NativeBlock.allocate(bodyByteSize, NativeBlock.Scan.no);

    auto referenceBlock = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
    *(cast(void**) referenceBlock.address) = body_.address;

    auto place = placeOfLvalue(target, (variable) => referenceBlock.address, (expr) => refuseEvalIndex(expr));

    (cast(size_t) place.address).should == cast(size_t) body_.address + fieldByteOffset(xField);

    int written = 8;
    written = written * 9 + 5;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


@("placeOfLvalue.indexExp.staticArrayBaseComposesStrideWithScalarRoundTrip")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueIndexArray(int[4] a) { a[2] = 0; } },
        "quickbiteLvalueIndexArray",
    );

    auto block = NativeBlock.allocate(4 * int.sizeof, NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address, (index) => 2);

    (cast(size_t) place.address).should == cast(size_t) block.address + 2 * int.sizeof;

    // Runtime-computed, not a bare literal passed straight to `Value`.
    int written = 3;
    written = written * 7 + 1;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


@("placeOfLvalue.indexExp.pointerBaseFollowsStoredPointerWithScalarRoundTrip")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueIndexPointer(int* p) { p[1] = 0; } },
        "quickbiteLvalueIndexPointer",
    );

    auto ints = NativeBlock.allocate(4 * int.sizeof, NativeBlock.Scan.no);
    auto pointerBlock = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.no);
    *(cast(void**) pointerBlock.address) = ints.address;

    auto place = placeOfLvalue(target, (variable) => pointerBlock.address, (index) => 1);

    (cast(size_t) place.address).should == cast(size_t) ints.address + int.sizeof;

    int written = 5;
    written = written * 4 + 3;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


@("placeOfLvalue.indexExp.sliceBaseFollowsHeaderPointerWithScalarRoundTrip")
unittest {
    import quickbite.backends.interpreter.native_array: NativeArray;

    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueIndexSlice(int[] s) { s[1] = 0; } },
        "quickbiteLvalueIndexSlice",
    );
    auto elementType = target.isIndexExp.e1.type.nextOf;

    auto elements = NativeBlock.allocate(3 * int.sizeof, NativeBlock.Scan.no);
    auto elementsArray = NativeArray.adopt(elements, elementType, 3);
    auto headerBlock = NativeBlock.allocate(NativeArray.sliceHeaderByteLength, NativeBlock.Scan.conservative);
    elementsArray.writeSliceHeader(headerBlock, 0);

    auto place = placeOfLvalue(target, (variable) => headerBlock.address, (index) => 1);

    (cast(size_t) place.address).should == cast(size_t) elements.address + int.sizeof;

    int written = 9;
    written = written * 2 + 6;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


// The centrepiece for a `PtrExp` (`*p`): `p`'s own place holds a stored
// pointer, so `placeOfLvalue` on the operand followed by `Place.deref` must
// land ON the stored pointer's own target address, at the pointee's type.
@("placeOfLvalue.ptrExp.derefsOperandPlaceToPointeeWithScalarRoundTrip")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvaluePtr(int* p) { *p = 0; } },
        "quickbiteLvaluePtr",
    );

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto pointerBlock = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.no);
    *(cast(void**) pointerBlock.address) = pointee.address;

    auto place = placeOfLvalue(target, (variable) => pointerBlock.address, (expr) => refuseEvalIndex(expr));

    place.address.should == pointee.address;

    int written = 7;
    written = written * 8 + 2;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}
