module ut.executors.pure_.lang.eval;


import ut.executors;


private:

import quickbite.executor: Value;
import std.conv: text;
import std.typecons: tuple;

static foreach (executorName; evalExecutorNames) {
    @("eval.add0." ~ executorName.text)
    unittest {
        executor(executorName).eval("1 + 2").should == Value(3);
    }

    @("eval.add1." ~ executorName.text)
    unittest {
        executor(executorName).eval("2 + 2").should == Value(4);
    }

    @("eval.add2." ~ executorName.text)
    unittest {
        executor(executorName).eval("3 + 3").should == Value(6);
    }

    @("eval.arithmetic." ~ executorName.text)
    unittest {
        static immutable cases = [
            tuple("4 + 5", 9),
            tuple("10 - 3", 7),
            tuple("3 * 4", 12),
            tuple("8 / 2", 4),
            tuple("7 + 8", 15),
        ];
        foreach (c; cases)
            executor(executorName).eval(c[0]).should == Value(c[1]);
    }

    @("eval.multiCell." ~ executorName.text)
    unittest {
        executor(executorName).eval("int x;\n++x;\n++x;\nx").should == Value(2);
    }

    static if (executorName == ExecutorName.ir) {
        @("eval.preservesScalarValueTypes." ~ executorName.text)
        unittest {
            executor(executorName).eval("cast(ubyte) 3").should ==
                Value(cast(ubyte) 3);
            executor(executorName).eval("cast(char) 65").should ==
                Value(cast(char) 65);
            executor(executorName).eval("1.25").should == Value(1.25);
        }
    }

    static if (
        executorName != ExecutorName.treeWalking &&
        executorName != ExecutorName.treeWalkingOld
    ) {
        @("eval.castsFloatingValueNumerically." ~ executorName.text)
        unittest {
            executor(executorName).eval("double input = 7.75;\ncast(int) input")
                .should == Value(7);
        }
    }

    static if (executorName == ExecutorName.ir) {
        @("eval.floatingSubtractionUsesNumericValues." ~ executorName.text)
        unittest {
            const result = executor(executorName).eval(
                "double left = 7.75;\ndouble right = 2.25;\nleft - right",
            );

            result.should == Value(5.5);
            result.should.not == Value(0);
        }
    }

    static if (executorName == ExecutorName.ir) {
        @("eval.floatingUnaryMinusUsesNumericValue." ~ executorName.text)
        unittest {
            const result = executor(executorName).eval("double input = 7.75;\n-input");

            result.should == Value(-7.75);
            result.should.not == Value(0);
        }
    }

    static if (executorName == ExecutorName.ir) {
        @("eval.fabsFloatPreservesReturnType." ~ executorName.text)
        unittest {
            const result = executor(executorName).eval(
                "import std.math: fabs;\nfloat input = -1.25f;\nfabs(input)",
            );

            result.should == Value(cast(float) 1.25);
            result.should.not == Value(1.25);
        }
    }

    static if (executorName == ExecutorName.ir) {
        @("eval.powFloatDoesNotReturnDoubleValue." ~ executorName.text)
        unittest {
            const result = executor(executorName).eval(
                "import std.math: pow;\nfloat base = 2.0f;\nfloat exponent = 3.0f;\npow(base, exponent)",
            );

            result.should == Value(cast(float) 8.0);
            result.should.not == Value(8.0);
        }
    }
}
