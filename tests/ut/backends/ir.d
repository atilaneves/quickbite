module ut.backends.ir;


import ut.backends;


@("runTestSummary.countsAssertErrorsAsFailures")
unittest {
    import quickbite: ExecutorBackend, runTestSummary;

    const summary = runTestSummary(q{
        import core.exception: AssertError;

        unittest {
            throw new AssertError("expected");
        }
    }, ExecutorBackend.ir);

    summary.total.should == 1;
    summary.passed.should == 0;
    summary.failed.should == 1;
}

@("lowerModule.functionPointerValuesAreAssignedIds")
unittest {
    import quickbite.frontend.compiler: lowerModule, parseModule;
    import quickbite.ir.instruction: ConstInt;
    import std.algorithm.sorting: sort;
    import std.sumtype: match;

    auto parsed = parseModule(q{
        void bAB() {
        }

        void a_a() {
        }

        unittest {
            void function() first = &bAB;
            void function() second = &a_a;
        }
    });
    // auto: lowered IR owns mutable SumType instructions for match.
    auto lowered = lowerModule(parsed.module_);

    long[] ids;
    foreach (instruction; lowered.tests[0].instructions) {
        instruction.match!(
            (ConstInt instruction) {
                const value = instruction.value.asLong;
                if (value != 0)
                    ids ~= value;
            },
            (_) {},
        );
    }

    ids.sort;
    ids.should == [1L, 2L];
}

@("runTests.functionPointerDenseIdsDispatchToMatchingCallees")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        int bAB() {
            return 11;
        }

        int a_a() {
            return 22;
        }

        unittest {
            int function() first = &bAB;
            int function() second = &a_a;
            assert(first() == 11);
            assert(second() == 22);
        }
    }, ExecutorBackend.ir);
}

@("runTests.functionPointerDispatchUsesLoweredFunctionIds")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        int helper() {
            return 7;
        }

        int first() {
            return helper() + 10;
        }

        int second() {
            return 13;
        }

        unittest {
            int function() fp1 = &first;
            int function() fp2 = &second;
            assert(fp1() == 17);
            assert(fp2() == 13);
        }
    }, ExecutorBackend.ir);
}

@("eval.preservesScalarValueTypes")
unittest {
    import quickbite: ExecutorBackend;
    import quickbite.executor: Value;
    import ut.backends: executor;

    auto ir = executor(ExecutorBackend.ir);
    ir.eval("cast(ubyte) 3").should == Value(cast(ubyte) 3);
    ir.eval("cast(char) 65").should == Value(cast(char) 65);
    ir.eval("1.25").should == Value(1.25);
}

@("eval.castsFloatingValueNumerically")
unittest {
    import quickbite: ExecutorBackend;
    import quickbite.executor: Value;
    import ut.backends: executor;

    auto ir = executor(ExecutorBackend.ir);
    ir.eval("double input = 7.75;\ncast(int) input").should == Value(7);
}

@("eval.floatingSubtractionUsesNumericValues")
unittest {
    import quickbite: ExecutorBackend;
    import quickbite.executor: Value;
    import ut.backends: executor;

    auto ir = executor(ExecutorBackend.ir);
    const result = ir.eval("double left = 7.75;\ndouble right = 2.25;\nleft - right");

    result.should == Value(5.5);
    result.should.not == Value(0);
}

@("eval.floatingUnaryMinusUsesNumericValue")
unittest {
    import quickbite: ExecutorBackend;
    import quickbite.executor: Value;
    import ut.backends: executor;

    auto ir = executor(ExecutorBackend.ir);
    const result = ir.eval("double input = 7.75;\n-input");

    result.should == Value(-7.75);
    result.should.not == Value(0);
}

@("eval.fabsFloatPreservesReturnType")
unittest {
    import quickbite: ExecutorBackend;
    import quickbite.executor: Value;
    import ut.backends: executor;

    auto ir = executor(ExecutorBackend.ir);
    const result = ir.eval(
        "import std.math: fabs;\nfloat input = -1.25f;\nfabs(input)",
    );

    result.should == Value(cast(float) 1.25);
    result.should.not == Value(1.25);
}
