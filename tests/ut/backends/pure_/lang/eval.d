module ut.backends.pure_.lang.eval;


import ut.backends;
import std.typecons: tuple;


static foreach (backend; backendsWith!(Bytecode, IR, TreeWalker)) {
    @("literal." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("0").should == Value(0);
        newBackend!backend.eval("7").should == Value(7);
    }
}

static foreach (backend; backendsWith!(Bytecode, IR, TreeWalker)) {
    @("add.int.0." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("1 + 2").should == Value(3);
    }

    @("add.int.1." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("2 + 2").should == Value(4);
    }
}

static foreach (backend; backendsWith!(Bytecode, IR, TreeWalker)) {
    @("add.int.2." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("3 + 3").should == Value(6);
    }
}

static foreach (backend; backendsWith!(Bytecode, TreeWalker)) {
    @("add.float." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("1.5f + 2.25f").should == Value(3.75f);
    }
}

static foreach (backend; backendsWith!(Bytecode, TreeWalker)) {
    @("arithmetic." ~ backend.stringof)
    unittest {
        static immutable cases = [
            tuple("4 + 5", 9),
            tuple("10 - 3", 7),
            tuple("3 * 4", 12),
            tuple("8 / 2", 4),
            tuple("7 + 8", 15),
        ];
        foreach (c; cases)
            newBackend!backend.eval(c[0]).should == Value(c[1]);
    }
}

static foreach (backend; backendsWith!TreeWalker) {

    @("multiCell." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("int x;\n++x;\n++x;\nx").should == Value(2);
    }
}

static foreach (backend; backendsWith!TreeWalker) {
    @("preservesScalarValueTypes." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("cast(byte) -3").should ==
            Value(cast(byte) -3);
        newBackend!backend.eval("cast(ubyte) 3").should ==
            Value(cast(ubyte) 3);
        newBackend!backend.eval("cast(short) -3").should ==
            Value(cast(short) -3);
        newBackend!backend.eval("cast(ushort) 3").should ==
            Value(cast(ushort) 3);
        newBackend!backend.eval("3").should == Value(3);
        newBackend!backend.eval("3u").should == Value(3u);
        newBackend!backend.eval("3L").should == Value(3L);
        newBackend!backend.eval("3UL").should == Value(3UL);
        newBackend!backend.eval("cast(char) 65").should ==
            Value(cast(char) 65);
        newBackend!backend.eval("1.25").should == Value(1.25);
    }
}

static foreach (backend; backendsWith!TreeWalker) {
    @("castsFloatingValueNumerically." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("double input = 7.75;\ncast(int) input")
            .should == Value(7);
    }
}

static foreach (backend; backendsWith!TreeWalker) {
    @("castsRuntimeValuesToIntegerTypes." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("int input = 258;\ncast(byte) input")
            .should == Value(cast(byte) 258);
        newBackend!backend.eval("int input = 258;\ncast(ubyte) input")
            .should == Value(cast(ubyte) 258);
        newBackend!backend.eval("int input = 258;\ncast(short) input")
            .should == Value(cast(short) 258);
        newBackend!backend.eval("int input = 258;\ncast(ushort) input")
            .should == Value(cast(ushort) 258);
        newBackend!backend.eval("int input = 258;\ncast(int) input")
            .should == Value(cast(int) 258);
        newBackend!backend.eval("int input = 258;\ncast(uint) input")
            .should == Value(cast(uint) 258);
        newBackend!backend.eval("int input = 258;\ncast(long) input")
            .should == Value(cast(long) 258);
        newBackend!backend.eval("int input = 258;\ncast(ulong) input")
            .should == Value(cast(ulong) 258);
    }
}

static foreach (backend; backendsWith!TreeWalker) {
    @("floatingSubtractionUsesNumericValues." ~ backend.stringof)
    unittest {
        const result = newBackend!backend.eval(
            "double left = 7.75;\ndouble right = 2.25;\nleft - right",
            );

        result.should == Value(5.5);
        result.should.not == Value(0);
    }
}

static foreach (backend; backends) {
    @("floatingUnaryMinusUsesNumericValue." ~ backend.stringof)
    unittest {
        const result = newBackend!backend.eval("double input = 7.75;\n-input");

        result.should == Value(-7.75);
        result.should.not == Value(0);
    }

    @("fabsFloatPreservesReturnType." ~ backend.stringof)
    unittest {
        const result = newBackend!backend.eval(
            "import std.math: fabs;\nfloat input = -1.25f;\nfabs(input)",
            );

        result.should == Value(cast(float) 1.25);
        result.should.not == Value(1.25);
    }

    @("powFloatDoesNotReturnDoubleValue." ~ backend.stringof)
    unittest {
        const result = newBackend!backend.eval(
            "import std.math: pow;\nfloat base = 2.0f;\nfloat exponent = 3.0f;\npow(base, exponent)",
            );

        result.should == Value(cast(float) 8.0);
        result.should.not == Value(8.0);
    }
}

static foreach (backend; backendsWith!Bytecode) {
    @("stringLiteralIsArray." ~ backend.stringof)
    unittest {
        newBackend!backend.eval(q{ "abc" }).should == Value("abc");
    }
}

@("convertsLegacyValuePreservingUbyteType.Ctfe")
unittest {
    newBackend!Ctfe.eval("cast(ubyte) 3").should == Value(cast(ubyte) 3);
}
