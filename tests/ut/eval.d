module ut.eval;

private:

import ut;
import quickbite: executor;
import quickbite.executor: Value;
import std.conv: text;
import std.typecons: tuple;
import ut.backends: evalBackends;

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
