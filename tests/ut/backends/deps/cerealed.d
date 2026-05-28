module ut.backends.deps.cerealed;


import ut.backends;
import std.path: buildPath;
import ut.dub_paths: cerealTestsDir, dubImportPaths;


private:

static foreach (backend; backends) {
    @("cerealed.bugs.d." ~ backend.stringof)
    unittest {
        runBackendFileFixtureTests!backend(
            buildPath(cerealTestsDir, "bugs.d"),
            dubImportPaths,
        );
    }

    @("cerealed.cerealiser_impl.d." ~ backend.stringof)
    unittest {
        runBackendFileFixtureTests!backend(
            buildPath(cerealTestsDir, "cerealiser_impl.d"),
            dubImportPaths,
        );
    }

    @("cerealed.compile_time.d." ~ backend.stringof)
    unittest {
        runBackendFileFixtureTests!backend(
            buildPath(cerealTestsDir, "compile_time.d"),
            dubImportPaths,
        );
    }
}
