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

public string[] dubImportPaths() {
    string[] ret;
    foreach (paths; dubDescription.packageImportPaths)
        ret ~= paths;
    return ret;
}

public string cerealSrcDir() {
    return packageImportPath("cerealed");
}

public string cerealTestsDir() {
    import std.path: dirName;

    return packageUnusedSource("cerealed", "tests/utils.d").dirName;
}

private string cerealPackageDir() {
    return packageDir("cerealed");
}

private string conceptsSrcDir() {
    return packageImportPath("concepts");
}

private string packageDir(in string name) {
    import std.exception: enforce;
    import std.conv: text;

    const found = name in dubDescription.packageDirs;
    enforce(found !is null, text("dub describe did not return package: ", name));
    return *found;
}

private string packageImportPath(in string name) {
    import std.exception: enforce;
    import std.conv: text;

    const found = name in dubDescription.packageImportPaths;
    enforce(found !is null, text("dub describe did not return package: ", name));
    enforce(found.length == 1, text("dub describe returned multiple import paths for ", name));
    return (*found)[0];
}

private string packageUnusedSource(in string name, in string path) {
    import std.algorithm.searching: endsWith;
    import std.exception: enforce;
    import std.conv: text;

    const found = name in dubDescription.packageUnusedSources;
    enforce(found !is null, text("dub describe did not return package: ", name));
    foreach (source; *found)
        if (source.endsWith(path))
            return source;

    throw new Exception(text("dub describe did not return ", path, " for ", name));
}

private DubDescription dubDescription() {
    if (!cachedDubDescriptionInitialized) {
        cachedDubDescription = loadDubDescription;
        cachedDubDescriptionInitialized = true;
    }

    return cachedDubDescription;
}

private DubDescription loadDubDescription() {
    import dub.dependencies: describeProject;
    import std.path: buildPath;
    import std.process: environment;

    DubDescription ret;
    // The returned associative array owns mutable arrays copied below.
    auto packages = describeProject(
        projectRoot,
        buildPath(environment["HOME"], ".dub"),
        "unittest",
    );
    foreach (name, package_; packages) {
        ret.packageDirs[name] = package_.dir;
        ret.packageImportPaths[name] = package_.importPaths;
        ret.packageUnusedSources[name] = package_.unusedSources;
    }

    return ret;
}
