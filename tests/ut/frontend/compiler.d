module ut.frontend.compiler;


import ut;

private:

@("parseSnippet.countsAttributedUnittests")
unittest {
    import quickbite.frontend.util: foreachUnitTestDeclaration;
    import quickbite.frontend.compiler: parseSnippet;

    // auto: DMD owns mutable Module state.
    auto moduleResult = parseSnippet(q{
        unittest {
        }

        // The UDA makes DMD wrap the unittest in an AttribDeclaration, as
        // unit-threaded and cerealed tests do.
        @("quickbite regression")
        unittest {
        }
    });

    size_t count;
    foreachUnitTestDeclaration(moduleResult.module_, (unitTest) {
        ++count;
    });

    count.should == 2;
}


@("parseSnippet.importPathsDoNotLeak")
unittest {
    import quickbite.frontend.compiler: parseSnippet;
    import std.path: buildPath;
    import std.file: mkdirRecurse, write;

    const importPath = tempModuleDir("leak");
    mkdirRecurse(importPath);
    write(
        buildPath(importPath, "quickbite_leak_import_a.d"),
        q{
            module quickbite_leak_import_a;
            enum quickbiteLeakA = 42;
        },
    );
    write(
        buildPath(importPath, "quickbite_leak_import_b.d"),
        q{
            module quickbite_leak_import_b;
            enum quickbiteLeakB = 42;
        },
    );

    parseSnippet(q{
        import quickbite_leak_import_a;
        enum moduleResultWithPath = quickbiteLeakA;
    }, [importPath]);

    const source = q{
        import quickbite_leak_import_b;
        enum moduleResultWithoutPath = quickbiteLeakB;
    };
    parseSnippet(source, []).shouldThrowWithMessage(
        "unable to read module `quickbite_leak_import_b`\nunable to read module `quickbite_leak_import_b`\nundefined identifier `quickbiteLeakB`",
    );
}


@("parseSnippet.errorMessage.containsActualDMDError")
unittest {
    import quickbite.frontend.compiler: parseSnippet;
    import std.exception: collectExceptionMsg;
    import std.algorithm.searching: canFind;

    const source = q{
        import quickbite_test_missing_module_xyzzy;
    };

    const message = collectExceptionMsg!Exception(parseSnippet(source, []));
    message.canFind("quickbite_test_missing_module_xyzzy").should == true;
}


@("parseRootModules.importedRootKeepsRunnableUnittestBody")
unittest {
    import quickbite.frontend.compiler: parseRootModules;
    import quickbite.backends.ctfe: Ctfe;
    import std.path: buildPath;

    with(immutable Sandbox()) {
        // Two package-shaped roots where the importer imports the imported.
        // Parsed one file at a time, the importer pulls `imported` in as a
        // non-root import first, and DMD drops its unittest body (leaving a
        // bodyless placeholder). Establishing both as roots before any import
        // traversal keeps the imported root's unittest body runnable.
        const importPath = "src";
        const importedPath = buildPath(importPath, "qb_root_imported.d");
        const importerPath = buildPath(importPath, "qb_root_importer.d");

        writeFile(importedPath, q{
            module qb_root_imported;
            int qbRootAnswer() { return 42; }
            unittest {
                assert(qbRootAnswer == 42);
            }
        });
        writeFile(importerPath, q{
            module qb_root_importer;
            import qb_root_imported;
            unittest {
                assert(qbRootAnswer == 42);
            }
        });

        // Importer first: the order that loads `imported` as a non-root import
        // before it is reached as a root in the one-file-at-a-time path.
        auto results = parseRootModules(
            [inSandboxPath(importerPath), inSandboxPath(importedPath)],
            [inSandboxPath(importPath)],
        );

        results.length.should == 2;

        // The imported root (second in input order) must run its unittest, not
        // report a bodyless-unittest diagnostic.
        auto runner = new Ctfe;
        const importedResults = runner.runTests(results[1].module_);
        importedResults.length.should == 1;
        importedResults[0].passed.should == true;
    }
}


@("parseRootModules.versionUnittestBlockCompilesIn")
unittest {
    import quickbite.frontend.compiler: parseRootModules;
    import quickbite.backends.ctfe: Ctfe;
    import std.path: buildPath;

    with(immutable Sandbox()) {
        // A helper declared inside `version (unittest) { ... }` and called from
        // a unittest body. `dmd -unittest` sets the predefined `unittest`
        // version identifier, so the block compiles in and the helper is
        // declared. quickbite must do the same, or the call is an "undefined
        // identifier".
        const importPath = "src";
        const modPath = buildPath(importPath, "qb_version_unittest.d");

        writeFile(modPath, q{
            module qb_version_unittest;
            version (unittest) {
                int qbVersionUnittestHelper() { return 42; }
            }
            unittest {
                assert(qbVersionUnittestHelper == 42);
            }
        });

        // Fails before the fix with "undefined identifier
        // `qbVersionUnittestHelper`"; the parse should succeed and the
        // unittest body should run.
        auto results = parseRootModules(
            [inSandboxPath(modPath)],
            [inSandboxPath(importPath)],
        );

        results.length.should == 1;

        auto runner = new Ctfe;
        const testResults = runner.runTests(results[0].module_);
        testResults.length.should == 1;
        testResults[0].passed.should == true;
    }
}
