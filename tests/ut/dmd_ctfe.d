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
    import std.conv: text;

    auto parsed = parseModule(q{
        unittest {
            assert(false);
        }
    });
    const fname = parsed.module_.srcfile.toString.idup;
    (new DmdCtfe).runParsedTests(parsed.module_)
        .shouldThrowWithMessage(text(fname, "(2): unittest failed in CTFE"));
}

@("runParsedTests.throwingTest")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;
    import std.conv: text;

    auto parsed = parseModule(q{
        unittest {
            throw new Exception("boom");
        }
    });
    const fname = parsed.module_.srcfile.toString.idup;
    (new DmdCtfe).runParsedTests(parsed.module_)
        .shouldThrowWithMessage(text(fname, "(2): unittest failed in CTFE"));
}

@("runParsedTests.noUnittests")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;

    auto parsed = parseModule(q{ int x = 1; });
    (new DmdCtfe).runParsedTests(parsed.module_);
}
