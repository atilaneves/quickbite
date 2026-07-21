module ut.backends.interpreter.frame_block;


import ut;
import ut.backends.interpreter: parseFunction;
import quickbite.backends.interpreter.frame_layout: computeFrameLayout;
import quickbite.backends.interpreter.frame_block: FrameBlock;
import quickbite.backends.interpreter.native_block: NativeBlock;
import dmd.declaration: VarDeclaration;

private:


@("FrameBlock.allocate.slotAddressIsBlockBasePlusSlotOffset")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameBlockParams(int a, long b) {} },
        "quickbiteFrameBlockParams",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);

    auto a = (*function_.parameters)[0];
    auto b = (*function_.parameters)[1];

    auto base = frame.block.address;
    frame.slotAddress(a).should == base;
    frame.slotAddress(b).should == base + 8;

    const baseAddress = cast(size_t) base;
    const endAddress = baseAddress + frame.byteLength;
    const aAddress = cast(size_t) frame.slotAddress(a);
    const bAddress = cast(size_t) frame.slotAddress(b);

    (aAddress >= baseAddress && aAddress < endAddress).should == true;
    (bAddress >= baseAddress && bAddress < endAddress).should == true;
}


@("FrameBlock.allocate.distinctLocalsGetDistinctNonOverlappingAddresses")
unittest {
    auto function_ = parseFunction(
        q{
            void quickbiteFrameBlockDistinctLocals() {
                int x;
                double y;
            }
        },
        "quickbiteFrameBlockDistinctLocals",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);

    VarDeclaration x;
    VarDeclaration y;
    foreach (variable, slot; layout.slots) {
        if (variable.ident.toString == "x")
            x = variable;
        else if (variable.ident.toString == "y")
            y = variable;
    }

    const xAddress = cast(size_t) frame.slotAddress(x);
    const yAddress = cast(size_t) frame.slotAddress(y);

    (xAddress != yAddress).should == true;
    // `x` is `int` (4 bytes); its range must not reach into `y`'s slot.
    (xAddress + int.sizeof <= yAddress).should == true;
}


@("FrameBlock.allocate.allScalarSlotsGetNoScanPolicy")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameBlockScalarScan(int a, long b) {} },
        "quickbiteFrameBlockScalarScan",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);

    frame.block.scan.should == NativeBlock.Scan.no;
}


@("FrameBlock.allocate.pointerContainingLocalGetsConservativeScanPolicy")
unittest {
    auto function_ = parseFunction(
        q{
            void quickbiteFrameBlockPointerScan() {
                int* p;
            }
        },
        "quickbiteFrameBlockPointerScan",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);

    frame.block.scan.should == NativeBlock.Scan.conservative;
}


// `hasSlot` answers `true` for EITHER slot kind -- an owning param and a
// reference param alike -- since both have a real slot in this frame;
// `hasOwningSlot`/`hasReferenceSlot` are the kind-specific predicates
// `impl.d`'s verified mirror and reference-slot binding actually gate on.
@("FrameBlock.hasSlot.trueForOwningAndReferenceParamsFalseForUnrelatedVariable")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameBlockHasSlot(int a, ref int b) {} },
        "quickbiteFrameBlockHasSlot",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);

    auto a = (*function_.parameters)[0];
    auto b = (*function_.parameters)[1];

    auto other = parseFunction(
        q{ void quickbiteFrameBlockHasSlotUnrelated(int c) {} },
        "quickbiteFrameBlockHasSlotUnrelated",
    );
    auto c = (*other.parameters)[0];

    frame.hasSlot(a).should == true;
    frame.hasSlot(b).should == true;
    frame.hasSlot(c).should == false;
}


@("FrameBlock.hasOwningSlot.hasReferenceSlot.distinguishTheTwoSlotKinds")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameBlockSlotKinds(int a, ref int b) {} },
        "quickbiteFrameBlockSlotKinds",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);

    auto a = (*function_.parameters)[0];
    auto b = (*function_.parameters)[1];

    auto other = parseFunction(
        q{ void quickbiteFrameBlockSlotKindsUnrelated(int c) {} },
        "quickbiteFrameBlockSlotKindsUnrelated",
    );
    auto c = (*other.parameters)[0];

    frame.hasOwningSlot(a).should == true;
    frame.hasReferenceSlot(a).should == false;

    frame.hasOwningSlot(b).should == false;
    frame.hasReferenceSlot(b).should == true;

    frame.hasOwningSlot(c).should == false;
    frame.hasReferenceSlot(c).should == false;
}


// `referenceSlotValue`/`setReferenceSlot` round-trip an arbitrary address
// through a `ref` parameter's own reference slot -- the raw pointer
// read/write `impl.d`'s `bindReferenceSlot`/`callerReferenceBase` build on.
@("FrameBlock.setReferenceSlot.referenceSlotValue.roundTripsAnArbitraryAddress")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameBlockRefRoundTrip(ref int a) {} },
        "quickbiteFrameBlockRefRoundTrip",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);
    auto a = (*function_.parameters)[0];

    int target = 42;
    frame.setReferenceSlot(a, &target);

    frame.referenceSlotValue(a).should == &target;
}


@("FrameBlock.allocate.zeroSlotFunctionYieldsZeroByteLengthBlock")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameBlockZeroSlots(lazy int a) {} },
        "quickbiteFrameBlockZeroSlots",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);

    frame.byteLength.should == 0;
    frame.block.byteLength.should == 0;
    frame.block.scan.should == NativeBlock.Scan.no;
}


// A `ref` parameter's slot holds an address regardless of its OWN
// declared type's pointer-ness -- `ref int` carries no pointer in its own
// type, but the SLOT does, so the frame must still scan conservatively.
@("FrameBlock.allocate.refParameterGetsConservativeScanPolicyRegardlessOfItsOwnDeclaredType")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameBlockRefScan(ref int a) {} },
        "quickbiteFrameBlockRefScan",
    );
    auto layout = computeFrameLayout(function_);
    auto frame = FrameBlock.allocate(layout);

    frame.block.scan.should == NativeBlock.Scan.conservative;
}
