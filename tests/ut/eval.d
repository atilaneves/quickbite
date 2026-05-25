module ut.eval;

private:

import quickbite: executor;
import quickbite.executor: Value;
import std.conv: text;
import std.typecons: tuple;
import ut.backends: evalBackends;
import unit_threaded;

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
}
