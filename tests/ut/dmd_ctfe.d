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
        .shouldThrowWithMessage("unittest failed in CTFE");
}
