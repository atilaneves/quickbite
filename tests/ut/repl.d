module ut.repl;

private:

import quickbite: ExecutorBackend, executor;
import quickbite.executor: Value;
import std.conv: text;
import std.traits: EnumMembers;
import unit_threaded;

static foreach (backend; [EnumMembers!ExecutorBackend]) {
    @(backend.text ~ ".eval.add0")
    unittest {
        executor(backend).eval("1 + 2").should == Value(3);
    }

    @(backend.text ~ ".eval.add1")
    unittest {
        executor(backend).eval("2 + 2").should == Value(4);
    }

    @(backend.text ~ ".eval.multiCell")
    unittest {
        executor(backend).eval("int x;\n++x;\n++x;\nx").should == Value(2);
    }
}
