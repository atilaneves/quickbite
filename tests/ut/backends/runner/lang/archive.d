module ut.backends.runner.lang.archive;


import ut.backends;
import std.algorithm.searching: canFind;


// The archive is built from a body returning 42, then the on-disk source is
// rewritten to return 0 before the fixture is parsed. Sema sees a matching
// signature either way, so a passing run proves the symbol was linked from
// the archive and the archive-backed module was not codegen'd from its
// source. Archive linking is a runtime linking mechanism, so `Ctfe` (which
// wraps dmd.dinterpret) cannot express it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "archive linking is a runtime linking mechanism; Ctfe wraps dmd.dinterpret and cannot express it"),
    Omit!(Interpreter, Because.unconfirmed,
        "no symbol-resolution source for a static archive: `Interpreter` " ~
        "has no `(linkFiles, importPaths)` constructor like " ~
        "`SystemLinker`/`LLVMJit`/`Bytecode` (only `this()` and " ~
        "`this(dependencyImages)`, confirmed by `new Interpreter([archivePath], " ~
        "[importPath])` failing to compile), and its native-call symbol " ~
        "lookup (`quickbite.ffi.core.resolveSymbol`) only resolves " ~
        "`dlsym(RTLD_DEFAULT, ...)` against symbols already in the process " ~
        "or `dlopen`'d from a `.so` via `loadDependencyImage` -- a `.a` " ~
        "archive cannot be `dlopen`'d at all, so this is a new " ~
        "symbol-resolution source (e.g. a --whole-archive .so wrapper, " ~
        "or an ORC-style generator like `LLVMJit`'s), not a language-surface fix"),
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

// A struct method under an archive import path: `SystemLinker`/`LLVMJit`
// link and call the archive's real method normally, proven (as above) by
// poisoning the on-disk source after the archive is built. `Bytecode`'s own
// safety-net test below covers why it is omitted here.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "archive linking is a runtime linking mechanism; Ctfe wraps dmd.dinterpret and cannot express it"),
    Omit!(Interpreter, Because.unconfirmed,
        "no symbol-resolution source for a static archive: `Interpreter` " ~
        "has no `(linkFiles, importPaths)` constructor like " ~
        "`SystemLinker`/`LLVMJit`/`Bytecode` (only `this()` and " ~
        "`this(dependencyImages)`, confirmed by `new Interpreter([archivePath], " ~
        "[importPath])` failing to compile), and its native-call symbol " ~
        "lookup (`quickbite.ffi.core.resolveSymbol`) only resolves " ~
        "`dlsym(RTLD_DEFAULT, ...)` against symbols already in the process " ~
        "or `dlopen`'d from a `.so` via `loadDependencyImage` -- a `.a` " ~
        "archive cannot be `dlopen`'d at all, so this is a new " ~
        "symbol-resolution source (e.g. a --whole-archive .so wrapper, " ~
        "or an ORC-style generator like `LLVMJit`'s), not a language-surface fix"),
)) {
    @("runTests.archiveBackedStructMethod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
        import std.conv: text;
        import std.path: buildPath;
        import std.process: execute;

        with(immutable Sandbox()) {
            const importPath = "imports";
            enum depModule = "dep_struct_method_" ~ backend.stringof;
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
                    "    assert(s.add(2) == 42);\n",
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

// A class method under an archive import path: `SystemLinker`/`LLVMJit`
// link and call the archive's real method normally. `Bytecode`'s own
// safety-net test below covers why it is omitted here.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "archive linking is a runtime linking mechanism; Ctfe wraps dmd.dinterpret and cannot express it"),
    Omit!(Interpreter, Because.unconfirmed,
        "no symbol-resolution source for a static archive: `Interpreter` " ~
        "has no `(linkFiles, importPaths)` constructor like " ~
        "`SystemLinker`/`LLVMJit`/`Bytecode` (only `this()` and " ~
        "`this(dependencyImages)`, confirmed by `new Interpreter([archivePath], " ~
        "[importPath])` failing to compile), and its native-call symbol " ~
        "lookup (`quickbite.ffi.core.resolveSymbol`) only resolves " ~
        "`dlsym(RTLD_DEFAULT, ...)` against symbols already in the process " ~
        "or `dlopen`'d from a `.so` via `loadDependencyImage` -- a `.a` " ~
        "archive cannot be `dlopen`'d at all, so this is a new " ~
        "symbol-resolution source (e.g. a --whole-archive .so wrapper, " ~
        "or an ORC-style generator like `LLVMJit`'s), not a language-surface fix"),
)) {
    @("runTests.archiveBackedClassMethod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
        import std.conv: text;
        import std.path: buildPath;
        import std.process: execute;

        with(immutable Sandbox()) {
            const importPath = "imports";
            enum depModule = "dep_class_method_" ~ backend.stringof;
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

// `Bytecode`-specific archive bridge check. The on-disk source is rewritten
// to a visibly wrong body after the archive is built, so a passing run proves
// the native class method, rather than rewritten source, was called.
@("runTests.archiveBackedClassMethod.Bytecode")
@Tags(Bytecode.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
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
        results[0].passed.should == true;
    }
}

// A delegate of an archive-backed struct method (`&s.add`): `SystemLinker`/
// `LLVMJit` call through it normally. `Bytecode`'s own safety-net test below
// covers why it is omitted here.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "archive linking is a runtime linking mechanism; Ctfe wraps dmd.dinterpret and cannot express it"),
    Omit!(Interpreter, Because.unconfirmed,
        "no symbol-resolution source for a static archive: `Interpreter` " ~
        "has no `(linkFiles, importPaths)` constructor like " ~
        "`SystemLinker`/`LLVMJit`/`Bytecode` (only `this()` and " ~
        "`this(dependencyImages)`, confirmed by `new Interpreter([archivePath], " ~
        "[importPath])` failing to compile), and its native-call symbol " ~
        "lookup (`quickbite.ffi.core.resolveSymbol`) only resolves " ~
        "`dlsym(RTLD_DEFAULT, ...)` against symbols already in the process " ~
        "or `dlopen`'d from a `.so` via `loadDependencyImage` -- a `.a` " ~
        "archive cannot be `dlopen`'d at all, so this is a new " ~
        "symbol-resolution source (e.g. a --whole-archive .so wrapper, " ~
        "or an ORC-style generator like `LLVMJit`'s), not a language-surface fix"),
    Omit!(Bytecode, Because.refusal,
        "`add` is an archive-backed function reached by address: routing " ~
        "it through the native bridge or its stale rewritten source is " ~
        "unsupported"),
)) {
    @("runTests.archiveBackedDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
        import std.conv: text;
        import std.path: buildPath;
        import std.process: execute;

        with(immutable Sandbox()) {
            const importPath = "imports";
            enum depModule = "dep_delegate_" ~ backend.stringof;
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

// `Bytecode`-specific safety net: taking a delegate of an archive-backed
// struct method reaches `registerFunction`/`compileFunctionBody` directly,
// bypassing `compileCall`'s own guard entirely (that guard only runs for a
// direct call expression). Without a guard at that chokepoint too, this
// silently compiled and ran the archive module's stale rewritten source.
@("runTests.archiveBackedDelegate.Bytecode")
@Tags(Bytecode.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
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

// A function pointer to an archive-backed free function (`&theAnswer`, no
// receiver at all): `SystemLinker`/`LLVMJit` call through it normally.
// `Bytecode`'s own safety-net test below covers why it is omitted here.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "archive linking is a runtime linking mechanism; Ctfe wraps dmd.dinterpret and cannot express it"),
    Omit!(Interpreter, Because.unconfirmed,
        "no symbol-resolution source for a static archive: `Interpreter` " ~
        "has no `(linkFiles, importPaths)` constructor like " ~
        "`SystemLinker`/`LLVMJit`/`Bytecode` (only `this()` and " ~
        "`this(dependencyImages)`, confirmed by `new Interpreter([archivePath], " ~
        "[importPath])` failing to compile), and its native-call symbol " ~
        "lookup (`quickbite.ffi.core.resolveSymbol`) only resolves " ~
        "`dlsym(RTLD_DEFAULT, ...)` against symbols already in the process " ~
        "or `dlopen`'d from a `.so` via `loadDependencyImage` -- a `.a` " ~
        "archive cannot be `dlopen`'d at all, so this is a new " ~
        "symbol-resolution source (e.g. a --whole-archive .so wrapper, " ~
        "or an ORC-style generator like `LLVMJit`'s), not a language-surface fix"),
)) {
    @("runTests.archiveBackedFunctionPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
        import std.conv: text;
        import std.path: buildPath;
        import std.process: execute;

        with(immutable Sandbox()) {
            const importPath = "imports";
            enum depModule = "dep_function_pointer_" ~ backend.stringof;
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

// `Bytecode`-specific safety net: a function pointer to an archive-backed
// free function reaches its native forwarding wrapper by address, whereas a
// direct call uses `compileCall`'s native-leaf path.
@("runTests.archiveBackedFunctionPointerBytecodeSafetyNet")
@Tags(Bytecode.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
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
        results[0].passed.should == true;
    }
}
