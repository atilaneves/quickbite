module ut.compiler_api;

private:

import quickbite: ExecutorBackend;
import ut.backends: matureExecutorBackends;
import unit_threaded;

@("parseModule.withImportPaths")
unittest {
    import quickbite.frontend.compiler: parseModule;
    import ut.dub_paths: dubImportPaths, cerealTestsDir;
    import std.file: readText;

    parseModule(readText(cerealTestsDir ~ "/utils.d"), dubImportPaths);
}

@("runTests.withImportPaths.dmdCtfe")
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

@("runTests.treeWalking.emptyUnittestCompletes")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        unittest {
        }
    }, ExecutorBackend.treeWalking);
}

@("runTests.treeWalking.failingUnittestThrows")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        unittest {
            int value = 1;
            assert(value == 2);
        }
    }, ExecutorBackend.treeWalking).shouldThrowWithMessage("1 != 2");
}

@("runTests.treeWalking.failingUnittestAfterAssignmentThrows")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        unittest {
            int value = 1;
            value = value + 1;
            assert(value == 3);
        }
    }, ExecutorBackend.treeWalking).shouldThrowWithMessage("2 != 3");
}

@("runTests.runsAttributedUnittests")
unittest {
    import quickbite: runTests;

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(q{
                // The UDA makes DMD wrap the unittest in an AttribDeclaration,
                // as unit-threaded and cerealed tests do.
                @("quickbite regression")
                unittest {
                    assert(1 == 2);
                }
            }, backend).shouldThrow;
        }
    }
}

@("runTests.runsAttributedThrowingUnittests")
unittest {
    import quickbite: runTests;

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(q{
                // The UDA makes DMD wrap the unittest in an AttribDeclaration,
                // as unit-threaded and cerealed tests do.
                @("quickbite regression")
                unittest {
                    throw new Exception("quickbite regression");
                }
            }, backend).shouldThrow;
        }
    }
}

@("runTestSummary.countsAttributedPassingAndFailingUnittests")
unittest {
    import quickbite: runTestSummary;

    static foreach (backend; matureExecutorBackends) {
        {
            const summary = runTestSummary(q{
                @("passes")
                unittest {
                    assert(1 == 1);
                }

                @("fails")
                unittest {
                    assert(1 == 2);
                }

                unittest {
                    assert(2 == 2);
                }
            }, backend);

            summary.total.should == 3;
            summary.passed.should == 2;
            summary.failed.should == 1;
        }
    }
}

@("runTestSummary.countsAllPassingUnittests")
unittest {
    import quickbite: runTestSummary;

    static foreach (backend; matureExecutorBackends) {
        {
            const summary = runTestSummary(q{
                unittest {
                    assert(1 == 1);
                }

                @("also passes")
                unittest {
                    assert(2 == 2);
                }
            }, backend);

            summary.total.should == 2;
            summary.passed.should == 2;
            summary.failed.should == 0;
        }
    }
}

@("runTestSummary.ir.countsAssertErrorsAsFailures")
unittest {
    import quickbite: ExecutorBackend, runTestSummary;

    const summary = runTestSummary(q{
        import core.exception: AssertError;

        unittest {
            throw new AssertError("expected");
        }
    }, ExecutorBackend.ir);

    summary.total.should == 1;
    summary.passed.should == 0;
    summary.failed.should == 1;
}

@("parseModule.countsAttributedUnittests")
unittest {
    import quickbite.dmd_util: foreachUnitTestDeclaration;
    import quickbite.frontend.compiler: parseModule;

    // auto: DMD owns mutable Module state.
    auto parsed = parseModule(q{
        unittest {
        }

        // The UDA makes DMD wrap the unittest in an AttribDeclaration, as
        // unit-threaded and cerealed tests do.
        @("quickbite regression")
        unittest {
        }
    });

    size_t count;
    foreachUnitTestDeclaration(parsed.module_, (unitTest) {
        ++count;
    });

    count.should == 2;
}

@("lowerModule.ir.functionPointerValuesAreAssignedIds")
unittest {
    import quickbite.frontend.compiler: lowerModule, parseModule;
    import quickbite.ir.instruction: ConstInt;
    import std.algorithm.sorting: sort;
    import std.sumtype: match;

    auto parsed = parseModule(q{
        void bAB() {
        }

        void a_a() {
        }

        unittest {
            void function() first = &bAB;
            void function() second = &a_a;
        }
    });
    // auto: lowered IR owns mutable SumType instructions for match.
    auto lowered = lowerModule(parsed.module_);

    long[] ids;
    foreach (instruction; lowered.tests[0].instructions) {
        instruction.match!(
            (ConstInt instruction) {
                if (instruction.value != 0)
                    ids ~= instruction.value;
            },
            (_) {},
        );
    }

    ids.sort;
    ids.should == [1L, 2L];
}

@("runTests.ir.functionPointerDenseIdsDispatchToMatchingCallees")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        int bAB() {
            return 11;
        }

        int a_a() {
            return 22;
        }

        unittest {
            int function() first = &bAB;
            int function() second = &a_a;
            assert(first() == 11);
            assert(second() == 22);
        }
    }, ExecutorBackend.ir);
}

@("runTests.ir.functionPointerDispatchUsesLoweredFunctionIds")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        int helper() {
            return 7;
        }

        int first() {
            return helper() + 10;
        }

        int second() {
            return 13;
        }

        unittest {
            int function() fp1 = &first;
            int function() fp2 = &second;
            assert(fp1() == 17);
            assert(fp2() == 13);
        }
    }, ExecutorBackend.ir);
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
        enum parsedWithPath = quickbiteLeakA;
    }, [importPath]);

    const source = q{
        import quickbite_leak_import_b;
        enum parsedWithoutPath = quickbiteLeakB;
    };
    parseModule(source, []).shouldThrowWithMessage(
        "unable to read module `quickbite_leak_import_b`\nunable to read module `quickbite_leak_import_b`\nundefined identifier `quickbiteLeakB`",
    );
}

@("runModulesTests.runsBothModules")
unittest {
    import quickbite.executor: runModulesTests;
    import quickbite.frontend.compiler: parseModule;
    import quickbite: ExecutorBackend, executor;
    import std.traits: EnumMembers;

    auto module1 = parseModule(q{ // auto: DMD owns mutable Module state
        unittest {
            assert(1 == 1);
        }
    }).module_;

    auto module2 = parseModule(q{ // auto: DMD owns mutable Module state
        unittest {
            throw new Exception("second module ran");
        }
    }).module_;

    static foreach (backend; EnumMembers!ExecutorBackend) {
        {
            executor(backend).runModulesTests([module1, module2,]).shouldThrowWithMessage(
                "second module ran",
            );
        }
    }
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

@("runParsedTests.ctfe.exposes.dmdDiagnostic.callingCFunction")
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

private string tempModuleDir(in string suffix) {
    import std.path: buildPath;
    import std.file: tempDir;

    return buildPath(tempDir, "quickbite-compiler-api", suffix);
}
