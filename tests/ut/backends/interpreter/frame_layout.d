module ut.backends.interpreter.frame_layout;


import ut;
import ut.backends.interpreter: parseFunction, parseNestedFunction;
import quickbite.backends.interpreter.frame_layout:
    FrameLayout, computeFrameLayout, cachedFrameLayout, capturedVariables,
    isReferenceParameter;

private:


@("isReferenceParameter.templateInstantiatedRefSharedUsesCanonicalParameter")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteSharedRef(ref shared(int) value) {} },
        "quickbiteSharedRef",
    );

    auto parameter = (*function_.parameters)[0];
    isReferenceParameter(function_, 0, parameter).should == true;
}


@("isReferenceParameter.capturedLocalIsNotAParameter")
unittest {
    auto nested = parseNestedFunction(
        q{
            void quickbiteCapturedNotParameter() {
                int captured;
                void nested() { captured++; }
            }
        },
        "quickbiteCapturedNotParameter",
        "nested",
    );

    auto captured = capturedVariables(nested)[0];
    isReferenceParameter(nested, 0, captured).should == false;
}


@("computeFrameLayout.parametersPackedInOrderAlignedToTheirOwnType")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameParams(int a, long b) {} },
        "quickbiteFrameParams",
    );

    auto layout = computeFrameLayout(function_);

    auto a = (*function_.parameters)[0];
    auto b = (*function_.parameters)[1];

    layout.has(a).should == true;
    layout[a].offset.should == 0;
    layout[a].size.should == 4;
    layout[a].kind.should == FrameLayout.Slot.Kind.owning;

    layout.has(b).should == true;
    layout[b].offset.should == 8;
    layout[b].size.should == 8;
    layout[b].kind.should == FrameLayout.Slot.Kind.owning;

    layout.byteLength.should == 16;
}


@("computeFrameLayout.bodyLocalsPackedInDeclarationOrder")
unittest {
    auto function_ = parseFunction(
        q{
            void quickbiteFrameBodyLocals() {
                int x;
                double y;
            }
        },
        "quickbiteFrameBodyLocals",
    );

    auto layout = computeFrameLayout(function_);

    layout.slots.length.should == 2;

    size_t xOffset;
    size_t xSize;
    size_t yOffset;
    size_t ySize;
    foreach (variable, slot; layout.slots) {
        slot.kind.should == FrameLayout.Slot.Kind.owning;
        if (variable.ident.toString == "x") {
            xOffset = slot.offset;
            xSize = slot.size;
        } else if (variable.ident.toString == "y") {
            yOffset = slot.offset;
            ySize = slot.size;
        }
    }

    xOffset.should == 0;
    xSize.should == 4;
    yOffset.should == 8;
    ySize.should == 8;
}


@("computeFrameLayout.refParameterGetsAPointerWidthReferenceSlot")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameRefParam(ref int a) {} },
        "quickbiteFrameRefParam",
    );

    auto layout = computeFrameLayout(function_);
    auto a = (*function_.parameters)[0];

    layout.has(a).should == true;
    layout[a].offset.should == 0;
    layout[a].size.should == (void*).sizeof;
    layout[a].kind.should == FrameLayout.Slot.Kind.reference;

    layout.byteLength.should == (void*).sizeof;
}


@("computeFrameLayout.outParameterGetsAPointerWidthReferenceSlot")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameOutParam(out int a) {} },
        "quickbiteFrameOutParam",
    );

    auto layout = computeFrameLayout(function_);
    auto a = (*function_.parameters)[0];

    layout.has(a).should == true;
    layout[a].offset.should == 0;
    layout[a].size.should == (void*).sizeof;
    layout[a].kind.should == FrameLayout.Slot.Kind.reference;

    layout.byteLength.should == (void*).sizeof;
}


// A `ref`/`out` parameter's reference slot is pointer-width regardless of
// its own declared type's size: a `ref` struct larger than a pointer still
// gets exactly one pointer-width slot, holding the caller-supplied
// address, never the struct's own bytes inline.
@("computeFrameLayout.refParameterReferenceSlotIsPointerWidthRegardlessOfItsOwnDeclaredTypeSize")
unittest {
    auto function_ = parseFunction(
        q{
            struct QuickbiteFrameLargeStruct { long a; long b; long c; }
            void quickbiteFrameRefStructParam(ref QuickbiteFrameLargeStruct s) {}
        },
        "quickbiteFrameRefStructParam",
    );

    auto layout = computeFrameLayout(function_);
    auto s = (*function_.parameters)[0];

    layout[s].size.should == (void*).sizeof;
    layout[s].kind.should == FrameLayout.Slot.Kind.reference;
    layout.byteLength.should == (void*).sizeof;
}


@("computeFrameLayout.lazyParameterHasNoSlot")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameLazyParam(lazy int a) {} },
        "quickbiteFrameLazyParam",
    );

    auto layout = computeFrameLayout(function_);
    auto a = (*function_.parameters)[0];

    layout.has(a).should == false;
    layout.byteLength.should == 0;
}


// A `ref` parameter's own reference slot is packed into the SAME
// encounter-order cursor as every owning slot around it -- not appended
// separately after them -- so a reader can still predict every offset by
// walking parameters then body locals in declaration order, exactly as
// before this slice.
@("computeFrameLayout.mixedParametersAndBodyLocalsInEncounterOrder")
unittest {
    auto function_ = parseFunction(
        q{
            void quickbiteFrameMixed(int a, ref int refParam, long b) {
                int x;
            }
        },
        "quickbiteFrameMixed",
    );

    auto layout = computeFrameLayout(function_);
    auto a = (*function_.parameters)[0];
    auto refParam = (*function_.parameters)[1];
    auto b = (*function_.parameters)[2];

    layout.has(a).should == true;
    layout[a].offset.should == 0;
    layout[a].kind.should == FrameLayout.Slot.Kind.owning;

    // `a` is 4 bytes at offset 0; `refParam`'s pointer-width (8-byte),
    // 8-byte-aligned reference slot packs at the next 8-byte-aligned
    // cursor, i.e. offset 8.
    layout.has(refParam).should == true;
    layout[refParam].offset.should == 8;
    layout[refParam].size.should == (void*).sizeof;
    layout[refParam].kind.should == FrameLayout.Slot.Kind.reference;

    // `b` (a `long`, 8-byte-aligned) packs right after `refParam`'s own
    // 8-byte slot, already 8-byte-aligned, at offset 16.
    layout.has(b).should == true;
    layout[b].offset.should == 16;
    layout[b].kind.should == FrameLayout.Slot.Kind.owning;

    size_t xOffset;
    foreach (variable, slot; layout.slots)
        if (variable.ident.toString == "x")
            xOffset = slot.offset;

    xOffset.should == 24;
    layout.byteLength.should == 32;
}


@("computeFrameLayout.staticLocalAndManifestConstantHaveNoSlotButAPlainLocalDoes")
unittest {
    auto function_ = parseFunction(
        q{
            void quickbiteFrameDataSegAndManifest() {
                static int s;
                enum e = 5;
                int x;
            }
        },
        "quickbiteFrameDataSegAndManifest",
    );

    auto layout = computeFrameLayout(function_);

    layout.slots.length.should == 1;

    size_t xOffset;
    size_t xSize;
    foreach (variable, slot; layout.slots)
        if (variable.ident.toString == "x") {
            xOffset = slot.offset;
            xSize = slot.size;
        }

    xOffset.should == 0;
    xSize.should == 4;
    layout.byteLength.should == 4;
}


@("cachedFrameLayout.equalsComputeFrameLayoutAndIsStableAcrossCalls")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameCached(int a, long b) {} },
        "quickbiteFrameCached",
    );

    auto expected = computeFrameLayout(function_);
    auto first = cachedFrameLayout(function_);
    auto second = cachedFrameLayout(function_);

    first.should == expected;
    second.should == first;
}


@("capturedVariables.emptyForANonNestedFunction")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameNotNested(int a) {} },
        "quickbiteFrameNotNested",
    );

    capturedVariables(function_).length.should == 0;
}


@("capturedVariables.namesTheOuterLocalANestedFunctionReads")
unittest {
    auto nested = parseNestedFunction(
        q{
            void quickbiteFrameCaptureOuter() {
                int captured;

                void quickbiteFrameCaptureNested() {
                    captured = 1;
                }
            }
        },
        "quickbiteFrameCaptureOuter",
        "quickbiteFrameCaptureNested",
    );

    auto captured = capturedVariables(nested);

    captured.length.should == 1;
    captured[0].ident.toString.should == "captured";
}


// A captured outer local gets no slot of ITS OWN in the nested function's
// layout -- it lives in the ENCLOSING activation's frame; the nested
// function only gets a REFERENCE slot holding that address.
@("computeFrameLayout.capturedOuterVariableGetsAPointerWidthReferenceSlot")
unittest {
    auto nested = parseNestedFunction(
        q{
            void quickbiteFrameCaptureSlotOuter() {
                int captured;

                void quickbiteFrameCaptureSlotNested() {
                    captured = 1;
                }
            }
        },
        "quickbiteFrameCaptureSlotOuter",
        "quickbiteFrameCaptureSlotNested",
    );

    auto captured = capturedVariables(nested)[0];
    auto layout = computeFrameLayout(nested);

    layout.has(captured).should == true;
    layout[captured].offset.should == 0;
    layout[captured].size.should == (void*).sizeof;
    layout[captured].kind.should == FrameLayout.Slot.Kind.reference;
    layout.byteLength.should == (void*).sizeof;
}


// A nested function's own parameters are packed first, then its captured-
// variable reference slots, then its own body locals -- mirroring
// `mixedParametersAndBodyLocalsInEncounterOrder` above, but with a capture
// standing in for the `ref` parameter there.
@("computeFrameLayout.capturedVariableSlotIsPackedAfterParametersBeforeBodyLocals")
unittest {
    auto nested = parseNestedFunction(
        q{
            void quickbiteFrameCaptureMixedOuter() {
                int captured;

                void quickbiteFrameCaptureMixedNested(int a) {
                    int x;
                    captured = a + x;
                }
            }
        },
        "quickbiteFrameCaptureMixedOuter",
        "quickbiteFrameCaptureMixedNested",
    );

    auto captured = capturedVariables(nested)[0];
    auto layout = computeFrameLayout(nested);
    auto a = (*nested.parameters)[0];

    layout.has(a).should == true;
    layout[a].offset.should == 0;
    layout[a].kind.should == FrameLayout.Slot.Kind.owning;

    // `a` is 4 bytes at offset 0; `captured`'s pointer-width (8-byte),
    // 8-byte-aligned reference slot packs at the next 8-byte-aligned
    // cursor, i.e. offset 8.
    layout.has(captured).should == true;
    layout[captured].offset.should == 8;
    layout[captured].kind.should == FrameLayout.Slot.Kind.reference;

    size_t xOffset;
    foreach (variable, slot; layout.slots)
        if (variable.ident.toString == "x")
            xOffset = slot.offset;

    // `x` (an `int`, 4-byte-aligned) packs right after `captured`'s own
    // 8-byte slot, at offset 16; the final cursor (20) then aligns up to
    // the largest alignment any slot used (8, from the pointer-width
    // reference slot), landing on 24.
    xOffset.should == 16;
    layout.byteLength.should == 24;
}


// A doubly-nested function's own `outerVars` already names a grandparent's
// local directly -- DMD flattens the capture chain itself, so this module
// need not walk it.
@("capturedVariables.namesAGrandparentLocalForADoublyNestedFunction")
unittest {
    auto outer = parseFunction(
        q{
            void quickbiteFrameCaptureGrandparent() {
                int captured;

                void quickbiteFrameCaptureMiddle() {
                    void quickbiteFrameCaptureInner() {
                        captured = 1;
                    }
                }
            }
        },
        "quickbiteFrameCaptureGrandparent",
    );

    import dmd.funcsem: functionSemantic3;
    functionSemantic3(outer);

    import ut.backends.interpreter: findNestedFunction;

    auto middle = findNestedFunction(outer, "quickbiteFrameCaptureMiddle");
    assert(middle !is null);
    functionSemantic3(middle);
    auto inner = findNestedFunction(middle, "quickbiteFrameCaptureInner");
    assert(inner !is null);
    functionSemantic3(inner);

    auto middleCaptures = capturedVariables(middle);
    auto innerCaptures = capturedVariables(inner);

    // `middle` itself never reads `captured`, so it captures nothing.
    middleCaptures.length.should == 0;

    innerCaptures.length.should == 1;
    innerCaptures[0].ident.toString.should == "captured";
}
