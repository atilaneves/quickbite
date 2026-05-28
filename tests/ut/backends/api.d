module ut.backends.api;


import ut.backends;


private:

static foreach (backend; backends) {
    @("runBackendSourceFixtureTests.withImportPaths." ~ backend.stringof)
    unittest {
        import std.file: mkdirRecurse, write;
        import std.path: buildPath;

        const importPath = tempModuleDir("backend-source-import-paths");
        mkdirRecurse(importPath);
        write(
            buildPath(importPath, "quickbite_backend_api_import.d"),
            q{
                module quickbite_backend_api_import;
                int importedValue() {
                    return 42;
                }
            },
        );

        runBackendSourceFixtureTests!backend(q{
            import quickbite_backend_api_import;

            unittest {
                assert(importedValue == 42);
            }
        }, [importPath]);
    }

    @("runBackendFileFixtureTests.withImportPaths." ~ backend.stringof)
    unittest {
        import std.file: mkdirRecurse, write;
        import std.path: buildPath;

        const importPath = tempModuleDir("backend-file-import-paths");
        mkdirRecurse(importPath);
        write(
            buildPath(importPath, "quickbite_backend_api_file_import.d"),
            q{
                module quickbite_backend_api_file_import;
                int importedValue() {
                    return 42;
                }
            },
        );

        const fixturePath = buildPath(importPath, "fixture.d");
        write(
            fixturePath,
            q{
                import quickbite_backend_api_file_import;

                unittest {
                    assert(importedValue == 42);
                }
            },
        );

        runBackendFileFixtureTests!backend(fixturePath, [importPath]);
    }
}
