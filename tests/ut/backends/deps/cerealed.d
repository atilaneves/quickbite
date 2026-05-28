module ut.backends.deps.cerealed;


import ut.backends;


private:

static foreach (backend; backends) {
    @("cerealed.compile_time.d." ~ backend.stringof)
    unittest {
        import std.path: buildPath;
        import ut.dub_paths: cerealTestsDir, dubImportPaths;

        runBackendFileFixtureTests!backend(
            buildPath(cerealTestsDir, "compile_time.d"),
            dubImportPaths,
        );
    }
}
