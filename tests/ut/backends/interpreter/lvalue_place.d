module ut.backends.interpreter.lvalue_place;


import ut;
import ut.backends.interpreter: structTypeOf, classTypeOf, findFunction;
import quickbite.frontend.compiler: parseSnippet;
import quickbite.backends.interpreter.lvalue_place: placeOfLvalue;
import quickbite.backends.interpreter.layout:
    classFields, classInstanceByteSize, fieldByteOffset, structFields, typeByteSize;
import quickbite.backends.interpreter.native_block: NativeBlock;
import quickbite.backends.interpreter.runtime_value: Value;
import dmd.expression: Expression, AssignExp;
import dmd.statement: Statement;
import dmd.declaration: VarDeclaration;
import dmd.arraytypes: Dsymbols;

private:


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


// The method sibling of `lvalueTargetOf` above: the first assignment's LHS
// inside `aggregateName`'s own method `methodName` -- `findFunction` only
// searches a MODULE's own top-level members, not an aggregate's, so this
// first finds `aggregateName`'s own struct/class declaration among the
// module's top-level members, then reuses `findFunction` on ITS members.
Expression lvalueTargetOfMethod(
    in string source,
    in string aggregateName,
    in string methodName,
) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members) {
        Dsymbols* members;
        if (auto struct_ = member.isStructDeclaration) {
            if (struct_.ident.toString != aggregateName)
                continue;
            members = struct_.members;
        } else if (auto class_ = member.isClassDeclaration) {
            if (class_.ident.toString != aggregateName)
                continue;
            members = class_.members;
        } else
            continue;

        auto function_ = findFunction(members, methodName);
        assert(function_ !is null,
            "method `" ~ methodName ~ "` not found in `" ~ aggregateName ~ "`");

        auto assign = firstAssignExp(function_.fbody);
        assert(assign !is null,
            "no assignment found in method `" ~ methodName ~ "`'s body");
        return assign.e1;
    }

    assert(false, "aggregate `" ~ aggregateName ~ "` not found in parsed snippet");
}


// The right-hand-side sibling of `lvalueTargetOf` above: a `SymOffExp` (DMD's
// constant-offset address-of shape) is itself an rvalue -- the VALUE of
// `&local`/`&arr[2]` -- never something assigned INTO, so a fixture handing
// one to `placeOfLvalue` directly needs the first assignment's RHS rather
// than its LHS.
Expression addressOfTargetOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);
    auto function_ = findFunction(moduleResult.module_, name);
    assert(function_ !is null, "function `" ~ name ~ "` not found in parsed snippet");

    auto assign = firstAssignExp(function_.fbody);
    assert(assign !is null, "no assignment found in function `" ~ name ~ "`'s body");
    return assign.e2;
}


// `placeOfLvalue` must never call `evalIndex` for a shape that has no
// `IndexExp` in it, so this fake asserts if it is ever called.
size_t refuseEvalIndex(Expression expr) @safe {
    assert(false, "evalIndex must not be called for a shape with no IndexExp");
}


// The `resolveBase` sibling of `refuseEvalIndex` above: a shape that
// `placeOfLvalue` refuses outright must never resolve any variable's base
// address first.
void* refuseResolveBase(VarDeclaration variable) @safe {
    assert(false, "resolveBase must not be called for an unsupported lvalue shape");
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
// reference, so the receiver's `Place.deref` must land on the
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

    auto body_ = NativeBlock.allocate(
        classInstanceByteSize(classType.sym), NativeBlock.Scan.no);

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

// The centrepiece for a struct `ThisExp`: the hidden `this` resolves to
// its own `vthis` variable exactly like a bare local, so `resolveBase`'s
// address IS the receiver's own storage directly -- no `deref` needed,
// matching how a plain struct-typed variable already composes above.
@("placeOfLvalue.thisExp.structResolvesReceiverStorageAddressAndType")
unittest {
    enum source = q{ struct S { int x; void reset() { this = S.init; } } };
    auto target = lvalueTargetOfMethod(source, "S", "reset");
    auto sType = structTypeOf(source, "S");

    auto block = NativeBlock.allocate(typeByteSize(sType), NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address, (expr) => refuseEvalIndex(expr));

    place.address.should == block.address;
    (place.type is target.type).should == true;
}


// The centrepiece for a CLASS `ThisExp`: unlike a struct's, a class
// receiver's `vthis` slot holds a stored REFERENCE, so `this.field` must
// `Place.deref` through it to reach the object body before composing the
// field's own offset -- the exact same composition `DotVarExp`'s class
// receiver already performs for an ordinary class-typed variable, just
// reached through `this` instead of a named variable.
@("placeOfLvalue.thisExp.classFieldWriteDerefsThisThenComposesOffsetWithScalarRoundTrip")
unittest {
    enum source = q{ class C { int x; void reset() { this.x = 0; } } };
    auto target = lvalueTargetOfMethod(source, "C", "reset");
    auto classType = classTypeOf(source, "C");
    auto fields = classFields(classType.sym);
    auto xField = fields[0];

    auto body_ = NativeBlock.allocate(
        classInstanceByteSize(classType.sym), NativeBlock.Scan.no);

    auto referenceBlock = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.conservative);
    *(cast(void**) referenceBlock.address) = body_.address;

    auto place = placeOfLvalue(target, (variable) => referenceBlock.address, (expr) => refuseEvalIndex(expr));

    (cast(size_t) place.address).should == cast(size_t) body_.address + fieldByteOffset(xField);

    int written = 11;
    written = written * 6 + 3;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


// An `IndexExp` chained onto a `DotVarExp` field access chained onto a
// struct `ThisExp`: `this.arr[1]` composes `this`'s own place (directly at
// the receiver's storage), then the `arr` field's own offset, then the
// element stride -- three of this slice's/the module's shapes nested
// together.
@("placeOfLvalue.thisExp.structArrayFieldIndexChainsFieldThenStrideWithScalarRoundTrip")
unittest {
    enum source = q{ struct S2 { int[3] arr; void setElement() { this.arr[1] = 0; } } };
    auto target = lvalueTargetOfMethod(source, "S2", "setElement");
    auto sType = structTypeOf(source, "S2");
    auto arrField = structFields(sType)[0];

    auto block = NativeBlock.allocate(typeByteSize(sType), NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address, (index) => 1);

    (cast(size_t) place.address).should ==
        cast(size_t) block.address + fieldByteOffset(arrField) + 1 * int.sizeof;

    int written = 13;
    written = written * 2 + 9;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


// The base case for a `SymOffExp` reached the only way production ever
// reaches one -- RECURSIVELY, under a `PtrExp`. `*&p` is DMD's own shape for
// a `ref` argument written that way (`optimize.d` folds `&p` to a
// `SymOffExp` and stops at `keepLvalue` before folding the `PtrExp` away),
// and the place it composes is `p`'s OWN storage at `p`'s own declared
// type -- the address-of and the dereference cancel. A composition that
// dereferences twice instead lands on whatever `p` happens to point AT,
// which for a pointer local is a real, non-null address a caller would go
// on to write through.
@("placeOfLvalue.ptrExp.symOffOperandCancelsRatherThanDerefencingTwice")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvaluePtrSymOff(int* p) { *&p = null; } },
        "quickbiteLvaluePtrSymOff",
    );

    auto pointee = NativeBlock.allocate(int.sizeof, NativeBlock.Scan.no);
    auto pointerBlock = NativeBlock.allocate((void*).sizeof, NativeBlock.Scan.no);
    *(cast(void**) pointerBlock.address) = pointee.address;

    auto place = placeOfLvalue(target, (variable) => pointerBlock.address, (expr) => refuseEvalIndex(expr));

    place.address.should == pointerBlock.address;
    (place.type.isTypePointer !is null).should == true;
}


// The centrepiece for `SymOffExp`'s non-zero-offset case, again through the
// recursive path: `*&buf[2]` carries a `SymOffExp` whose own `offset` is
// DMD's already-computed byte offset -- `2 * int.sizeof` -- which must be
// applied DIRECTLY to `buf`'s own cell address rather than re-derived as an
// element index (`value.md`'s Layout authority contract).
@("placeOfLvalue.ptrExp.symOffOperandAppliesDmdsOwnByteOffsetWithScalarRoundTrip")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvaluePtrSymOffElement(int[4] buf) { *&buf[2] = 0; } },
        "quickbiteLvaluePtrSymOffElement",
    );

    auto block = NativeBlock.allocate(4 * int.sizeof, NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address, (expr) => refuseEvalIndex(expr));

    (cast(size_t) place.address).should == cast(size_t) block.address + 2 * int.sizeof;

    int written = 17;
    written = written * 5 + 6;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


// The other recursive path onto a `SymOffExp`: an `IndexExp` whose BASE is
// one. `arr.ptr[1]` is the everyday shape that reaches here, and the
// pointer it indexes is an rvalue -- there is no storage holding it for
// `Place.index`'s own pointer case to read back out, so the stride applies
// straight to the address the `SymOffExp` names.
@("placeOfLvalue.indexExp.symOffBaseStepsFromTheAddressItNamesWithScalarRoundTrip")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueIndexSymOff(int[4] arr) { arr.ptr[1] = 0; } },
        "quickbiteLvalueIndexSymOff",
    );

    auto block = NativeBlock.allocate(4 * int.sizeof, NativeBlock.Scan.no);
    auto place = placeOfLvalue(target, (variable) => block.address, (index) => 1);

    (cast(size_t) place.address).should == cast(size_t) block.address + int.sizeof;

    int written = 19;
    written = written * 4 + 7;
    place.storeScalar(Value(written));
    place.loadScalar.asLong.should == written;
}


// The same `IndexExp`-over-`SymOffExp` path where following a stored
// pointer instead of stepping from the named address is actually
// observable: the element type is ITSELF a pointer, so `Place.index`'s
// pointer case would read `a[1]`'s own stored contents and index from
// THERE. `(&a[1])[0]` is `a[1]` itself.
@("placeOfLvalue.indexExp.symOffBaseOverPointerElementsDoesNotFollowStoredPointer")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueIndexSymOffPointers(int*[4] a) { (&a[1])[0] = null; } },
        "quickbiteLvalueIndexSymOffPointers",
    );

    auto block = NativeBlock.allocate(4 * (void*).sizeof, NativeBlock.Scan.conservative);
    auto stray = NativeBlock.allocate(4 * (void*).sizeof, NativeBlock.Scan.conservative);
    *(cast(void**) (block.address + (void*).sizeof)) = stray.address;

    auto place = placeOfLvalue(target, (variable) => block.address, (index) => 0);

    (cast(size_t) place.address).should == cast(size_t) block.address + (void*).sizeof;
}


// A bare `SymOffExp` is an RVALUE -- the VALUE of `&v`, not a location --
// so `placeOfLvalue` has no place to return for it and must refuse rather
// than hand back the place of what it points at, which every recursive
// caller would then dereference a second time.
@("placeOfLvalue.stillUnsupported.bareSymOffExpRefuses")
unittest {
    auto target = addressOfTargetOf(
        q{ void quickbiteLvalueSymOffBare(int v) { int* p; p = &v; } },
        "quickbiteLvalueSymOffBare",
    );

    placeOfLvalue(
        target,
        (variable) => refuseResolveBase(variable),
        (expr) => refuseEvalIndex(expr),
    ).shouldThrowWithMessage(
        "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "unsupported lvalue expression",
    );
}


// A shape this slice deliberately leaves unsupported: `a[1..3] = 0` is a
// legal assignment target (DMD's own `SliceExp`), but composing its place
// would need a RANGE, not a single address -- outside this module's "one
// address plus a static type" contract. It must refuse honestly rather
// than guess, the same as any other still-unhandled shape, and must not
// call either delegate first.
@("placeOfLvalue.stillUnsupported.sliceExpAssignTargetRefuses")
unittest {
    auto target = lvalueTargetOf(
        q{ void quickbiteLvalueSlice(int[4] a) { a[1..3] = 0; } },
        "quickbiteLvalueSlice",
    );

    placeOfLvalue(
        target,
        (variable) => refuseResolveBase(variable),
        (expr) => refuseEvalIndex(expr),
    ).shouldThrowWithMessage(
        "quickbite.backends.interpreter.lvalue_place.placeOfLvalue: "
        ~ "unsupported lvalue expression",
    );
}
