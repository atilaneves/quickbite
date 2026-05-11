module ut.dub_paths;

private:

// __FILE_FULL_PATH__ is tests/ut/dub_paths.d; project root is 3 levels up.
// Anchoring here makes all paths work regardless of the test runner's cwd.
private enum projectRoot = __FILE_FULL_PATH__[0 .. $ - "/tests/ut/dub_paths.d".length];
private string[] cachedDubImportPaths;
private bool cachedDubImportPathsInitialized;

public string[] cerealImportPaths() @safe {
    import std.path: buildPath;
    return [cerealSrcDir, conceptsSrcDir, buildPath(projectRoot, "vendor", "ut_stubs")];
}

public string cerealSrcDir() @safe {
    return cerealPackageDir ~ "/src";
}

public string cerealTestsDir() @safe {
    return cerealPackageDir ~ "/tests";
}

private string cerealPackageDir() @safe {
    return dubPackageDir("cerealed");
}

private string conceptsSrcDir() @safe {
    return dubImportPath("concepts/source");
}

private string dubPackageDir(in string name) @safe {
    import std.path: dirName;

    return dubImportPath(name ~ "/src").dirName;
}

private string dubImportPath(in string suffix) @safe {
    import std.algorithm.searching: endsWith;
    import std.exception: enforce;
    import std.path: dirSeparator;

    const wanted = dirSeparator ~ suffix ~ dirSeparator;
    foreach (path; dubImportPaths)
        if (path.endsWith(wanted))
            return path;

    throw new Exception("dub describe did not return import path: " ~ suffix);
}

private string[] dubImportPaths() @safe {
    if (!cachedDubImportPathsInitialized) {
        cachedDubImportPaths = loadDubImportPaths;
        cachedDubImportPathsInitialized = true;
    }

    return cachedDubImportPaths;
}

private string[] loadDubImportPaths() @safe {
    import std.exception: enforce;
    import std.process: Config, execute;
    import std.string: splitLines, strip;

    const result = execute(
        [
            "dub",
            "describe",
            "--config=unittest",
            "--data=import-paths",
            "--data-list",
        ],
        null,
        Config.none,
        size_t.max,
        projectRoot,
    );
    enforce(result.status == 0, result.output);

    string[] ret;
    foreach (line; result.output.splitLines) {
        const path = line.strip;
        if (path.length == 0)
            continue;

        ret ~= path;
    }
    return ret;
}
