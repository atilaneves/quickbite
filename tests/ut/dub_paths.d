module ut.dub_paths;

private:

// __FILE_FULL_PATH__ is tests/ut/dub_paths.d; project root is 3 levels up.
// Anchoring here makes all paths work regardless of the test runner's cwd.
private enum projectRoot = __FILE_FULL_PATH__[0 .. $ - "/tests/ut/dub_paths.d".length];
private struct DubDescription {
    string[string] packageDirs;
    string[][string] packageImportPaths;
    string[][string] packageUnusedSources;
}
private DubDescription cachedDubDescription;
private bool cachedDubDescriptionInitialized;

public string[] dubImportPaths() @safe {
    string[] ret;
    foreach (paths; dubDescription.packageImportPaths)
        ret ~= paths;
    return ret;
}

private string packageImportPath(in string name) @safe {
    import std.exception: enforce;
    import std.conv: text;

    const found = name in dubDescription.packageImportPaths;
    enforce(found !is null, text("dub describe did not return package: ", name));
    enforce(found.length == 1, text("dub describe returned multiple import paths for ", name));
    return (*found)[0];
}

private DubDescription dubDescription() @safe {
    if (!cachedDubDescriptionInitialized) {
        cachedDubDescription = loadDubDescription;
        cachedDubDescriptionInitialized = true;
    }

    return cachedDubDescription;
}

private DubDescription loadDubDescription() @safe {
    import std.exception: enforce;
    import std.process: Config, execute;

    const result = execute(
        [
            "dub",
            "describe",
            "--vquiet",
            "--config=unittest",
        ],
        null,
        Config.none,
        size_t.max,
        projectRoot,
    );
    enforce(result.status == 0, result.output);

    return parseDubDescription(result.output);
}

private DubDescription parseDubDescription(in string json) @trusted {
    import std.json: parseJSON;
    import std.path: buildNormalizedPath;

    const root = parseJSON(json);

    DubDescription ret;
    foreach (package_; root["packages"].array) {
        const name = package_["name"].str;
        const packageDir = package_["path"].str;
        ret.packageDirs[name] = packageDir;

        string[] importPaths;
        foreach (importPath; package_["importPaths"].array)
            importPaths ~= buildNormalizedPath(packageDir, importPath.str);
        ret.packageImportPaths[name] = importPaths;

        string[] unusedSources;
        foreach (file; package_["files"].array) {
            if (file["role"].str != "unusedSource")
                continue;

            unusedSources ~= buildNormalizedPath(packageDir, file["path"].str);
        }
        ret.packageUnusedSources[name] = unusedSources;
    }
    return ret;
}
