module ut.repl;

private:

import quickbite: ExecutorBackend, executor;
import quickbite.executor: Value;
import std.conv: text;
import std.traits: EnumMembers;
import unit_threaded;

@("repl.loop.evaluatesExpressionCellsUntilQuit")
unittest {
    import quickbite.repl: runReplLoop;

    auto output = runReplLoop(
        executor(ExecutorBackend.ir),
        ["1", "2", ":q"],
    );

    output.should == ["1", "2"];
}

@("repl.loop.declarationPersistsAcrossCells")
unittest {
    import quickbite.repl: runReplLoop;

    auto output = runReplLoop(
        executor(ExecutorBackend.ir),
        ["int x;", "x", ":q"],
    );

    output.should == ["0"];
}

@("repl.binary.cEvaluatesExpressionCellSilently")
unittest {
    import std.process: execute;

    const result = execute([replExecutable, "-c", "1 + 2"]);
    result.status.should == 0;
    result.output.should == "";
}

@("repl.binary.continuesAfterFrontendDiagnostic")
unittest {
    import std.algorithm.searching: canFind;
    import std.process: Redirect, pipeProcess, wait;

    auto repl = pipeProcess(
        [replExecutable],
        Redirect.stdin | Redirect.stdout,
    );

    repl.stdin.write("int x\n1\n:q\n");
    repl.stdin.close;

    string output;
    foreach (line; repl.stdout.byLine)
        output ~= line.idup ~ "\n";

    wait(repl.pid).should == 0;
    output.canFind("unexpected identifier `x` in declarator").should == true;
    output.canFind("> 1\n>").should == true;
}

private string replExecutable() {
    static bool built;
    if (!built) {
        import std.process: execute;

        const result = execute(["dub", "build", "-c", "repl"]);
        result.status.should == 0;
        built = true;
    }

    return "bin/repl";
}

@("value.uint_vs_long")
unittest {
    (Value(3u) == Value(3L)).should == false;
}

@("value.int_vs_long")
unittest {
    (Value(3) == Value(3L)).should == false;
}

@("value.byte_vs_int")
unittest {
    (Value(cast(byte) 3) == Value(3)).should == false;
}

@("value.bool_vs_byte")
unittest {
    (Value(true) == Value(cast(byte) 1)).should == false;
}

@("value.distinct_integral_pairs")
unittest {
    static foreach (i; 0 .. 4) {
        static if (i == 0) {
            (Value(cast(ubyte) 3) == Value(cast(uint) 3)).should == false;
        } else static if (i == 1) {
            (Value(cast(short) 3) == Value(cast(int) 3)).should == false;
        } else static if (i == 2) {
            (Value(cast(ushort) 3) == Value(cast(uint) 3)).should == false;
        } else static if (i == 3) {
            (Value(cast(ulong) 3) == Value(cast(long) 3)).should == false;
        }
    }
}

static foreach (backend; [EnumMembers!ExecutorBackend]) {
    static if (backend != ExecutorBackend.dmdCodegen) {
    @(backend.text ~ ".eval.add0")
    unittest {
        executor(backend).eval("1 + 2").should == Value(3);
    }

    @(backend.text ~ ".eval.add1")
    unittest {
        executor(backend).eval("2 + 2").should == Value(4);
    }

    @(backend.text ~ ".eval.add2")
    unittest {
        executor(backend).eval("3 + 3").should == Value(6);
    }

    @(backend.text ~ ".eval.arithmetic")
    unittest {
        import std.typecons: tuple;
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

    @(backend.text ~ ".eval.multiCell")
    unittest {
        executor(backend).eval("int x;\n++x;\n++x;\nx").should == Value(2);
    }
    } // static if (backend != ExecutorBackend.dmdCodegen)
}
