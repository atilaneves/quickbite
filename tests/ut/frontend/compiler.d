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
