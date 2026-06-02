module ut.compiler;


import ut;

private:

@("parseModule.countsAttributedUnittests")
unittest {
    import quickbite.frontend.util: foreachUnitTestDeclaration;
    import quickbite.frontend.compiler: parseModule;

    // auto: DMD owns mutable Module state.
    auto moduleResult = parseModule(q{
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


@("parseModule.importPathsDoNotLeak")
unittest {
    import quickbite.frontend.compiler: parseModule;
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

    parseModule(q{
        import quickbite_leak_import_a;
        enum moduleResultWithPath = quickbiteLeakA;
    }, [importPath]);

    const source = q{
        import quickbite_leak_import_b;
        enum moduleResultWithoutPath = quickbiteLeakB;
    };
    parseModule(source, []).shouldThrowWithMessage(
        "unable to read module `quickbite_leak_import_b`\nunable to read module `quickbite_leak_import_b`\nundefined identifier `quickbiteLeakB`",
    );
}


@("parseModule.errorMessage.containsActualDMDError")
unittest {
    import quickbite.frontend.compiler: parseModule;
    import std.exception: collectExceptionMsg;
    import std.algorithm.searching: canFind;

    const source = q{
        import quickbite_test_missing_module_xyzzy;
    };

    const message = collectExceptionMsg!Exception(parseModule(source, []));
    message.canFind("quickbite_test_missing_module_xyzzy").should == true;
}
