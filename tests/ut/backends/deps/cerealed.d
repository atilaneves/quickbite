module ut.backends.deps.cerealed;


import ut.backends;
import std.path: buildPath;
import ut.dub_paths: cerealTestsDir, dubImportPaths;


private:

static foreach (backend; backends) {
    @("cerealed.compile_time.d." ~ backend.stringof)
    unittest {
        runBackendFileFixtureTests!backend(
            buildPath(cerealTestsDir, "compile_time.d"),
            dubImportPaths,
        );
    }
}
