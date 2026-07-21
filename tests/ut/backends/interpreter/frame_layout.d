module ut.backends.interpreter.frame_layout;


import ut;
import ut.backends.interpreter: parseFunction;
import quickbite.backends.interpreter.frame_layout: FrameLayout, computeFrameLayout, cachedFrameLayout;

private:


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
