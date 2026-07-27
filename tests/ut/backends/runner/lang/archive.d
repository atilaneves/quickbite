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
