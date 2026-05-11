module ut.compiler_api;

private:

import unit_threaded;

// parseModule(source, importPaths): parse a cerealed test file whose imports
// require explicit paths.  The cerealed src path comes from dub describe;
// unit_threaded is satisfied by the stub in vendor/ut_stubs.
@("parseModule.withImportPaths")
unittest {
    import quickbite.frontend.compiler: parseModule;
    import ut.dub_paths: cerealImportPaths, cerealTestsDir;
    import std.file: readText;

    parseModule(readText(cerealTestsDir ~ "/utils.d"), cerealImportPaths);
}

@("runTests.withImportPaths.dmdCtfe")
unittest {
    import quickbite: ExecutorBackend, runTests;
    import ut.dub_paths: cerealImportPaths, cerealTestsDir;
    import std.file: readText;

    runTests(readText(cerealTestsDir ~ "/utils.d"), cerealImportPaths, ExecutorBackend.dmdCtfe);
}
