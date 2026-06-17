module ut.backends.runner.ct.archive;


import ut.backends;


// The archive is built from a body returning 42, then the on-disk source is
// rewritten to return 0 before the fixture is parsed. Sema sees a matching
// signature either way, so a passing run proves the symbol was linked from
// the archive and the archive-backed module was not codegen'd from its
// source. Archive linking is a runtime linking mechanism, so `Ctfe` (which
// wraps dmd.dinterpret) cannot express it; only `SystemLinker` is listed.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("runTests.archiveBackedImportLinksFromArchive." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
        import std.path: buildPath;
        import std.process: execute;

        with(immutable Sandbox()) {
            const importPath = "imports";
            const depPath = buildPath(importPath, "dep.d");
            writeFile(depPath, q{
                module dep;
                int theAnswer() { return 42; }
            });
            const archivePath = inSandboxPath("libdep.a");
            const build = execute([
                "dmd",
                "-lib",
                "-fPIC",
                "-of=" ~ archivePath,
                inSandboxPath(depPath),
            ]);
            build.status.should == 0;

            writeFile(depPath, q{
                module dep;
                int theAnswer() { return 0; }
            });

            auto moduleResult = parseSnippetWithCheckActionContext(
                q{
                    import dep;
                    unittest {
                        assert(theAnswer == 42);
                    }
                },
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
