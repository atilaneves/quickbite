module ut.backends.runner.lang.pollution;


import ut.backends;
import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;


/++
    Cross-fixture pollution (ai/plans/dmd-backend.md, lesson 13): druntime
    template instances parameterized on one fixture's types accumulate on the
    lightning rod, and compiling a different fixture must not drag them — and
    their references to the first fixture's symbols — into its link. Fixture B
    is parsed before A ever compiles and is compiled from that stale parse
    afterwards, so by the time B's codegen runs the rod holds instances
    parameterized on A's class (e.g. _d_newclassT!PollutionWidget). This is
    the spike scenario slice 1 could not run: a cached parse, codegen'd after
    another fixture's compilation.
+/
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("pollution.staleParseCompilesAfterOtherFixture." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum sourceA = q{
            class PollutionWidget { int x; }

            unittest {
                auto widget = new PollutionWidget;
                widget.x = 1;
                int lhs = 1;
                int rhs = 2;
                assert(lhs == rhs);
            }
        };
        enum sourceB = q{
            class PollutionGadget { int y; }

            unittest {
                auto gadget = new PollutionGadget;
                gadget.y = 3;
                int left = 3;
                int right = 4;
                assert(left == right);
            }
        };

        // B parsed before A compiles; compiled from this stale parse below.
        auto moduleB = parseSnippetWithCheckActionContext(sourceB, []).module_;
        auto moduleA = parseSnippetWithCheckActionContext(sourceA, []).module_;

        auto backend_ = newBackend!backend;

        const resultsA = backend_.runTests(moduleA);
        resultsA.length.should == 1;
        resultsA[0].passed.should == false;
        resultsA[0].message.should == "1 != 2";

        const resultsB = backend_.runTests(moduleB);
        resultsB.length.should == 1;
        resultsB[0].passed.should == false;
        resultsB[0].message.should == "3 != 4";
    }
}
