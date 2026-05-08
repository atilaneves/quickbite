module ut.dmd_ctfe;

private:

import unit_threaded;

@("runParsedTests.minicereal")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;
    import std.file: readText;

    const source = readText("tests/minicereal.d");
    auto parsed = parseModule(source);
    (new DmdCtfe).runParsedTests(parsed.module_);
}

@("runParsedTests.failingTest")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(q{
        unittest {
            assert(false);
        }
    });
    (new DmdCtfe).runParsedTests(parsed.module_)
        .shouldThrowWithMessage("Unittest assertion failed.");
}

@("runParsedTests.throwingTest")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(q{
        unittest {
            throw new Exception("boom");
        }
    });
    (new DmdCtfe).runParsedTests(parsed.module_)
        .shouldThrowWithMessage("Unittest assertion failed.");
}

@("runParsedTests.noUnittests")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(q{ int x = 1; });
    (new DmdCtfe).runParsedTests(parsed.module_);
}

// Out-parameters and multi-statement bodies are rejected by the custom VM
// backends but are natively supported by CTFE; verify they pass here.
@("runParsedTests.outParameter")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(q{
        void setAnswer(out int value) {
            value = 42;
        }

        unittest {
            int value = 0;
            setAnswer(value);
            assert(value == 42);
        }
    });
    (new DmdCtfe).runParsedTests(parsed.module_);
}

@("runParsedTests.multipleOutParameters")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(q{
        void add(int left, out int right) {
            right = left + 2;
        }

        unittest {
            int value = 0;
            add(40, value);
            assert(value == 42);
        }
    });
    (new DmdCtfe).runParsedTests(parsed.module_);
}
