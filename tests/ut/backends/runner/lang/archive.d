module ut.backends.runner.lang.archive;


import ut.backends;


// The archive is built from a body returning 42, then the on-disk source is
// rewritten to return 0 before the fixture is parsed. Sema sees a matching
// signature either way, so a passing run proves the symbol was linked from
// the archive and the archive-backed module was not codegen'd from its
// source. Archive linking is a runtime linking mechanism, so `Ctfe` (which
// wraps dmd.dinterpret) cannot express it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "archive linking is a runtime linking mechanism; Ctfe wraps dmd.dinterpret and cannot express it"),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("runTests.archiveBackedImportLinksFromArchive." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
        import std.conv: text;
        import std.path: buildPath;
        import std.process: execute;

        with(immutable Sandbox()) {
            const importPath = "imports";
            enum depModule = "dep_" ~ backend.stringof;
            const depPath = buildPath(importPath, depModule ~ ".d");
            writeFile(depPath, text(
                "module ", depModule, ";\n",
                "int theAnswer() { return 42; }\n",
            ));
            const archivePath = inSandboxPath("lib" ~ depModule ~ ".a");
            const build = execute([
                "dmd",
                "-lib",
                "-fPIC",
                "-of=" ~ archivePath,
                inSandboxPath(depPath),
            ]);
            build.status.should == 0;

            writeFile(depPath, text(
                "module ", depModule, ";\n",
                "int theAnswer() { return 0; }\n",
            ));

            auto moduleResult = parseSnippetWithCheckActionContext(
                text(
                    "import ", depModule, ";\n",
                    "unittest {\n",
                    "    assert(theAnswer == 42);\n",
                    "}\n",
                ),
                [inSandboxPath(importPath)],
            );
            auto runner = new backend(
                [archivePath],
                [inSandboxPath(importPath)],
            );
            const results = runner.runTests(moduleResult.module_);

            results.length.should == 1;
            results[0].passed.should == true;
        }
    }
}

// A struct method under an archive import path is still an archive-backed
// function per `isArchiveBackedFunction`, but the bytecode native bridge has
// no receiver-passing mechanism for it: routing the call through
// `tryCompileNativeCall` reaches the archive's real `S.add` with no `this`
// argument at all. This must decline loudly, not crash the process by
// calling into native code with a missing receiver.
@("runTests.archiveBackedStructMethodDeclinesRatherThanCrashing.Bytecode")
@Tags(Bytecode.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.algorithm.searching: canFind;
    import std.conv: text;
    import std.path: buildPath;
    import std.process: execute;

    with(immutable Sandbox()) {
        const importPath = "imports";
        enum depModule = "dep_archive_struct_method";
        const depPath = buildPath(importPath, depModule ~ ".d");
        writeFile(depPath, text(
            "module ", depModule, ";\n",
            "struct S { int base; int add(int x) { return base + x; } }\n",
        ));
        const archivePath = inSandboxPath("lib" ~ depModule ~ ".a");
        const build = execute([
            "dmd",
            "-lib",
            "-fPIC",
            "-of=" ~ archivePath,
            inSandboxPath(depPath),
        ]);
        build.status.should == 0;

        auto moduleResult = parseSnippetWithCheckActionContext(
            text(
                "import ", depModule, ";\n",
                "unittest {\n",
                "    S s;\n",
                "    s.base = 40;\n",
                "    assert(s.add(2) == 42);\n",
                "}\n",
            ),
            [inSandboxPath(importPath)],
        );
        auto runner = new Bytecode(
            [archivePath],
            [inSandboxPath(importPath)],
        );
        const results = runner.runTests(moduleResult.module_);

        results.length.should == 1;
        results[0].passed.should == false;
        results[0].message.canFind(
            "is an archive-backed method",
        ).should == true;
    }
}

// A class method under an archive import path: unlike the struct-method
// case above, `layout.hasClassThis` used to skip both the native-call
// attempt and the "no available source" refusal, silently falling through
// to compiling the archive module's own stale rewritten source instead of
// declining. The on-disk source is rewritten to a visibly wrong body after
// the archive is built, so a passing (declining) run is distinguishable
// from a silent compile of that wrong body.
@("runTests.archiveBackedClassMethodDeclinesRatherThanRunningStaleSource.Bytecode")
@Tags(Bytecode.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.algorithm.searching: canFind;
    import std.conv: text;
    import std.path: buildPath;
    import std.process: execute;

    with(immutable Sandbox()) {
        const importPath = "imports";
        enum depModule = "dep_archive_class_method";
        const depPath = buildPath(importPath, depModule ~ ".d");
        writeFile(depPath, text(
            "module ", depModule, ";\n",
            "class C { int base = 40; int add(int x) { return base + x; } }\n",
        ));
        const archivePath = inSandboxPath("lib" ~ depModule ~ ".a");
        const build = execute([
            "dmd",
            "-lib",
            "-fPIC",
            "-of=" ~ archivePath,
            inSandboxPath(depPath),
        ]);
        build.status.should == 0;

        writeFile(depPath, text(
            "module ", depModule, ";\n",
            "class C { int base = 999; int add(int x) { return 0; } }\n",
        ));

        auto moduleResult = parseSnippetWithCheckActionContext(
            text(
                "import ", depModule, ";\n",
                "unittest {\n",
                "    auto c = new C;\n",
                "    assert(c.add(2) == 42);\n",
                "}\n",
            ),
            [inSandboxPath(importPath)],
        );
        auto runner = new Bytecode(
            [archivePath],
            [inSandboxPath(importPath)],
        );
        const results = runner.runTests(moduleResult.module_);

        results.length.should == 1;
        results[0].passed.should == false;
        results[0].message.canFind(
            "is an archive-backed method",
        ).should == true;
    }
}

// Taking a delegate of an archive-backed struct method (`&s.add`) reaches
// `registerFunction`/`compileFunctionBody` directly, bypassing
// `compileCall`'s own guard entirely (that guard only runs for a direct
// call expression). Without a guard at that chokepoint too, this silently
// compiled and ran the archive module's stale rewritten source.
@("runTests.archiveBackedDelegateDeclinesRatherThanRunningStaleSource.Bytecode")
@Tags(Bytecode.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.algorithm.searching: canFind;
    import std.conv: text;
    import std.path: buildPath;
    import std.process: execute;

    with(immutable Sandbox()) {
        const importPath = "imports";
        enum depModule = "dep_archive_delegate_method";
        const depPath = buildPath(importPath, depModule ~ ".d");
        writeFile(depPath, text(
            "module ", depModule, ";\n",
            "struct S { int base; int add(int x) { return base + x; } }\n",
        ));
        const archivePath = inSandboxPath("lib" ~ depModule ~ ".a");
        const build = execute([
            "dmd",
            "-lib",
            "-fPIC",
            "-of=" ~ archivePath,
            inSandboxPath(depPath),
        ]);
        build.status.should == 0;

        writeFile(depPath, text(
            "module ", depModule, ";\n",
            "struct S { int base; int add(int x) { return 0; } }\n",
        ));

        auto moduleResult = parseSnippetWithCheckActionContext(
            text(
                "import ", depModule, ";\n",
                "unittest {\n",
                "    S s;\n",
                "    s.base = 40;\n",
                "    auto dg = &s.add;\n",
                "    assert(dg(2) == 42);\n",
                "}\n",
            ),
            [inSandboxPath(importPath)],
        );
        auto runner = new Bytecode(
            [archivePath],
            [inSandboxPath(importPath)],
        );
        const results = runner.runTests(moduleResult.module_);

        results.length.should == 1;
        results[0].passed.should == false;
        results[0].message.canFind(
            "is an archive-backed function reached by address",
        ).should == true;
    }
}

// A function pointer to an archive-backed FREE function (`&theAnswer`, no
// receiver at all) also reaches `compileFunctionBody` by address: a direct
// call would go through `compileCall`'s native-leaf path and never reach
// here, so any archive-backed function arriving here was registered by
// address instead, regardless of whether it has a receiver. Confirms the
// `compileFunctionBody` guard declines unconditionally, not just for the
// receiver-bearing shapes above.
@("runTests.archiveBackedFunctionPointerDeclinesRatherThanRunningStaleSource.Bytecode")
@Tags(Bytecode.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.algorithm.searching: canFind;
    import std.conv: text;
    import std.path: buildPath;
    import std.process: execute;

    with(immutable Sandbox()) {
        const importPath = "imports";
        enum depModule = "dep_archive_function_pointer";
        const depPath = buildPath(importPath, depModule ~ ".d");
        writeFile(depPath, text(
            "module ", depModule, ";\n",
            "int theAnswer() { return 42; }\n",
        ));
        const archivePath = inSandboxPath("lib" ~ depModule ~ ".a");
        const build = execute([
            "dmd",
            "-lib",
            "-fPIC",
            "-of=" ~ archivePath,
            inSandboxPath(depPath),
        ]);
        build.status.should == 0;

        writeFile(depPath, text(
            "module ", depModule, ";\n",
            "int theAnswer() { return 0; }\n",
        ));

        auto moduleResult = parseSnippetWithCheckActionContext(
            text(
                "import ", depModule, ";\n",
                "unittest {\n",
                "    auto fp = &theAnswer;\n",
                "    assert(fp() == 42);\n",
                "}\n",
            ),
            [inSandboxPath(importPath)],
        );
        auto runner = new Bytecode(
            [archivePath],
            [inSandboxPath(importPath)],
        );
        const results = runner.runTests(moduleResult.module_);

        results.length.should == 1;
        results[0].passed.should == false;
        results[0].message.canFind(
            "is an archive-backed function reached by address",
        ).should == true;
    }
}
