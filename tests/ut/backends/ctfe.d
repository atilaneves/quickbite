module ut.backends.ctfe;


import ut.backends;


@("runTests.withImportPaths")
unittest {
    import quickbite: ExecutorBackend, runTestsFromFile;
    import ut.dub_paths: dubImportPaths, cerealTestsDir;

    runTestsFromFile(cerealTestsDir ~ "/utils.d", dubImportPaths, ExecutorBackend.dmdCtfe);
}


@("runTests.importPathsRetryAfterFailure")
unittest {
    import quickbite: ExecutorBackend, runTests;
    import quickbite.frontend.compiler: parseModule;
    import std.path: buildPath;
    import std.file: mkdirRecurse, write;

    const importPath = tempModuleDir("retry");
    mkdirRecurse(importPath);
    write(
        buildPath(importPath, "quickbite_retry_import.d"),
        q{
            module quickbite_retry_import;
            enum quickbiteRetryAnswer = 42;
        },
    );
    const source = q{
        import quickbite_retry_import;
        unittest {
            assert(quickbiteRetryAnswer == 42);
        }
    };

    parseModule(source, []).shouldThrowWithMessage(
        "unable to read module `quickbite_retry_import`\nunable to read module `quickbite_retry_import`\nundefined identifier `quickbiteRetryAnswer`",
    );
    runTests(source, [importPath], ExecutorBackend.dmdCtfe);
}

@("runParsedTests.exposes.dmdDiagnostic.callingCFunction")
unittest {
    import quickbite.backends.dmd_ctfe: DmdCtfe;
    import quickbite.frontend.compiler: parseModule;
    import std.exception: collectExceptionMsg;
    import std.algorithm.searching: canFind;

    const source = q{
        unittest {
            import core.stdc.stdlib: malloc;
            auto ptr = malloc(100);
        }
    };

    auto parsed = parseModule(source);
    const message = collectExceptionMsg!Exception(
        (new DmdCtfe).runParsedTests(parsed.module_)
    );
    message.canFind("malloc").should == true;
}
