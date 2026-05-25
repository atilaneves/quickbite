module ut.backends.codegen;


import ut.backends;


private:

import std.conv: text;

@("benchmark.preParseReportsMissingFixture")
unittest {
    import quickbite.benchmarks: populateDmdCodegenModuleSet;
    import std.algorithm.searching: canFind, startsWith;
    import std.path: buildPath;

    const importPath = tempModuleDir("benchmark-preparse");
    const missingFixture = buildPath(importPath, "missing_fixture.d");

    try {
        populateDmdCodegenModuleSet([missingFixture], [importPath]);
        assert(false, "missing fixture did not throw");
    } catch (Exception e) {
        assert(e.msg.startsWith("failed to pre-parse missing_fixture: "));
        assert(e.msg.canFind("missing_fixture.d"));
    }
}

static foreach (backend; dmdCodegenRamExecutorBackends) {
    @(text("runTests.localIntegerArithmetic.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            import quickbite: runTests;

            runTests(q{
                int input() {
                    return 40;
                }

                unittest {
                    int value = input;
                    value += 2;
                    assert(value == 42);
                }
            }, backend);
        }
    }
}
