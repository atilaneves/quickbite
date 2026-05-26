module ut.backends.eval;


import ut.backends;


private:

import quickbite.executor: Value;
import std.conv: text;
import std.typecons: tuple;

static foreach (backend; evalBackends) {
    @("eval.add0." ~ backend.text)
    unittest {
        executor(backend).eval("1 + 2").should == Value(3);
    }

    @("eval.add1." ~ backend.text)
    unittest {
        executor(backend).eval("2 + 2").should == Value(4);
    }

    @("eval.add2." ~ backend.text)
    unittest {
        executor(backend).eval("3 + 3").should == Value(6);
    }

    @("eval.arithmetic." ~ backend.text)
    unittest {
        static immutable cases = [
            tuple("4 + 5", 9),
            tuple("10 - 3", 7),
            tuple("3 * 4", 12),
            tuple("8 / 2", 4),
            tuple("7 + 8", 15),
        ];
        foreach (c; cases)
            executor(backend).eval(c[0]).should == Value(c[1]);
    }

    @("eval.multiCell." ~ backend.text)
    unittest {
        executor(backend).eval("int x;\n++x;\n++x;\nx").should == Value(2);
    }

    static if (backend == ExecutorBackend.ir) {
        @("eval.preservesScalarValueTypes." ~ backend.text)
        unittest {
            executor(backend).eval("cast(ubyte) 3").should ==
                Value(cast(ubyte) 3);
            executor(backend).eval("cast(char) 65").should ==
                Value(cast(char) 65);
            executor(backend).eval("1.25").should == Value(1.25);
        }
    }

    static if (
        backend != ExecutorBackend.treeWalking &&
        backend != ExecutorBackend.treeWalkingOld
    ) {
        @("eval.castsFloatingValueNumerically." ~ backend.text)
        unittest {
            executor(backend).eval("double input = 7.75;\ncast(int) input")
                .should == Value(7);
        }
    }

    static if (backend == ExecutorBackend.ir) {
        @("eval.floatingSubtractionUsesNumericValues." ~ backend.text)
        unittest {
            const result = executor(backend).eval(
                "double left = 7.75;\ndouble right = 2.25;\nleft - right",
            );

            result.should == Value(5.5);
            result.should.not == Value(0);
        }
    }

    static if (backend == ExecutorBackend.ir) {
        @("eval.floatingUnaryMinusUsesNumericValue." ~ backend.text)
        unittest {
            const result = executor(backend).eval("double input = 7.75;\n-input");

            result.should == Value(-7.75);
            result.should.not == Value(0);
        }
    }

    static if (backend == ExecutorBackend.ir) {
        @("eval.fabsFloatPreservesReturnType." ~ backend.text)
        unittest {
            const result = executor(backend).eval(
                "import std.math: fabs;\nfloat input = -1.25f;\nfabs(input)",
            );

            result.should == Value(cast(float) 1.25);
            result.should.not == Value(1.25);
        }
    }

    static if (backend == ExecutorBackend.ir) {
        @("eval.powFloatDoesNotReturnDoubleValue." ~ backend.text)
        unittest {
            const result = executor(backend).eval(
                "import std.math: pow;\nfloat base = 2.0f;\nfloat exponent = 3.0f;\npow(base, exponent)",
            );

            result.should == Value(cast(float) 8.0);
            result.should.not == Value(8.0);
        }
    }
}
