module ut.backends.evaluator.eval;


import ut.backends;
import std.algorithm.iteration: filter;
import std.algorithm.searching: canFind;
import std.array: replicate;
import std.file: readText;
import std.range: walkLength;
import std.string: lineSplitter;
import std.typecons: tuple;


static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("literal." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("0").should == "0";
        newBackend!backend.eval("7").should == "7";
    }
}

static foreach (backend; AliasSeq!(SystemLinker, LLVMJit)) {
    @("literal." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("0").should == "0";
        newBackend!backend.eval("7").should == "7";
    }
}

@("eval.doesNotLeakJitMappings.LLVMJit")
@Tags("LLVMJit")
unittest {
    auto backend = newBackend!LLVMJit;
    backend.eval("1 + 2").should == "3";
    const before = anonymousExecutableMappings;
    foreach (_; 0 .. 8)
        backend.eval("1 + 2").should == "3";
    const after = anonymousExecutableMappings;
    (after - before < 8).should == true;
}

private size_t anonymousExecutableMappings() {
    return "/proc/self/maps"
        .readText
        .lineSplitter
        .filter!(line => line.canFind("r-xp") && !line.canFind("/"))
        .walkLength;
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("add.int.0." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("1 + 2").should == "3";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {

    @("add.int.1." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("2 + 2").should == "4";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("add.int.2." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("3 + 3").should == "6";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("add.float." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("1.5f + 2.25f").should == "3.75f";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("integerLikeBinaryOperands." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("cast(char) 65 + 1").should == "66";
        newBackend!backend.eval("true + 1").should == "2";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("arithmetic." ~ backend.stringof)
    unittest {
        static immutable cases = [
            tuple("4 + 5", "9"),
            tuple("10 - 3", "7"),
            tuple("3 * 4", "12"),
            tuple("8 / 2", "4"),
            tuple("7 + 8", "15"),
        ];
        foreach (c; cases)
            newBackend!backend.eval(c[0]).should == c[1];
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {

    @("multiCell." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("int x;\n++x;\n++x;\nx").should == "2";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("preservesScalarValueTypes." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("cast(byte) -3").should == "-3";
        newBackend!backend.eval("cast(ubyte) 3").should == "3";
        newBackend!backend.eval("cast(short) -3").should == "-3";
        newBackend!backend.eval("cast(ushort) 3").should == "3";
        newBackend!backend.eval("3").should == "3";
        newBackend!backend.eval("3u").should == "3u";
        newBackend!backend.eval("3L").should == "3L";
        newBackend!backend.eval("3UL").should == "3UL";
        newBackend!backend.eval("cast(char) 65").should == "'A'";
        newBackend!backend.eval("1.25").should == "1.25";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("castsFloatingValueNumerically." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("double input = 7.75;\ncast(int) input")
            .should == "7";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("castsRuntimeValuesToIntegerTypes." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("int input = 258;\ncast(byte) input")
            .should == "2";
        newBackend!backend.eval("int input = 258;\ncast(ubyte) input")
            .should == "2";
        newBackend!backend.eval("int input = 258;\ncast(short) input")
            .should == "258";
        newBackend!backend.eval("int input = 258;\ncast(ushort) input")
            .should == "258";
        newBackend!backend.eval("int input = 258;\ncast(int) input")
            .should == "258";
        newBackend!backend.eval("int input = 258;\ncast(uint) input")
            .should == "258u";
        newBackend!backend.eval("int input = 258;\ncast(long) input")
            .should == "258L";
        newBackend!backend.eval("int input = 258;\ncast(ulong) input")
            .should == "258UL";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("defaultUintPreservesScalarType." ~ backend.stringof)
    unittest {
        newBackend!backend.eval("uint value;\nvalue").should == "0u";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("floatingSubtractionUsesNumericValues." ~ backend.stringof)
    unittest {
        const result = newBackend!backend.eval(
            "double left = 7.75;\ndouble right = 2.25;\nleft - right",
            );

        result.should == "5.5";
        result.should.not == "0";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("floatingUnaryMinusUsesNumericValue." ~ backend.stringof)
    unittest {
        const result = newBackend!backend.eval("double input = 7.75;\n-input");

        result.should == "-7.75";
        result.should.not == "0";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("fabsFloatPreservesReturnType." ~ backend.stringof)
    unittest {
        const result = newBackend!backend.eval(
            "import std.math: fabs;\nfloat input = -1.25f;\nfabs(input)",
            );

        result.should == "1.25f";
        result.should.not == "1.25";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("powFloatDoesNotReturnDoubleValue." ~ backend.stringof)
    unittest {
        const result = newBackend!backend.eval(
            "import std.math: pow;\nfloat base = 2.0f;\nfloat exponent = 3.0f;\npow(base, exponent)",
            );

        result.should == "8.0f";
        result.should.not == "8.0";
    }
}

static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    @("stringLiteralIsArray." ~ backend.stringof)
    unittest {
        newBackend!backend.eval(q{ "abc" }).should == `"abc"`;
    }
}

// The entry materialises `early` before `later` is compiled. Calling `later`
// lazily compiles it and adds enough literal data to move the data segment;
// the already-live slice must still point at valid literal storage.
@("stringLiteralSurvivesLazyDataSegmentGrowth.Bytecode")
@Tags("Bytecode")
unittest {
    enum laterLiteral = "x".replicate(256);
    enum expression = `
        ({
            string later() {
                return "` ~ laterLiteral ~ `";
            }

            string early = "early";
            later();
            return early;
        })()
    `;

    newBackend!Bytecode.eval(expression).should == `"early"`;
}
