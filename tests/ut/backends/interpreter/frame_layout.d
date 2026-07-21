module ut.backends.interpreter.frame_layout;


import ut;
import ut.backends.interpreter: parseFunction;
import quickbite.backends.interpreter.frame_layout: computeFrameLayout, cachedFrameLayout;

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

    layout.has(b).should == true;
    layout[b].offset.should == 8;
    layout[b].size.should == 8;

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


@("computeFrameLayout.refParameterHasNoSlot")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameRefParam(ref int a) {} },
        "quickbiteFrameRefParam",
    );

    auto layout = computeFrameLayout(function_);
    auto a = (*function_.parameters)[0];

    layout.has(a).should == false;
    layout.byteLength.should == 0;
}


@("computeFrameLayout.outParameterHasNoSlot")
unittest {
    auto function_ = parseFunction(
        q{ void quickbiteFrameOutParam(out int a) {} },
        "quickbiteFrameOutParam",
    );

    auto layout = computeFrameLayout(function_);
    auto a = (*function_.parameters)[0];

    layout.has(a).should == false;
    layout.byteLength.should == 0;
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


@("computeFrameLayout.mixedParametersAndBodyLocalsInEncounterOrder")
unittest {
    auto function_ = parseFunction(
        q{
            void quickbiteFrameMixed(int a, ref int skipped, long b) {
                int x;
            }
        },
        "quickbiteFrameMixed",
    );

    auto layout = computeFrameLayout(function_);
    auto a = (*function_.parameters)[0];
    auto skipped = (*function_.parameters)[1];
    auto b = (*function_.parameters)[2];

    layout.has(a).should == true;
    layout[a].offset.should == 0;

    layout.has(skipped).should == false;

    layout.has(b).should == true;
    layout[b].offset.should == 8;

    size_t xOffset;
    foreach (variable, slot; layout.slots)
        if (variable.ident.toString == "x")
            xOffset = slot.offset;

    xOffset.should == 16;
    layout.byteLength.should == 24;
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
