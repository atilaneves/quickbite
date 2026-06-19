module quickbite.dub;

private:

// The import paths a dub package contributes to a build: its own source path
// plus those of its transitive dependencies. Feeding these to a frontend makes
// `import <pkg>` (and any transitive module) resolve the way `dub test` does.
public string[] dubImportPaths(in string name) {
    return dubDescribe(findPkgDir(name), "import-paths");
}

// Run `dub describe ... --data=<dataKind> --data-list` in pkgDir and return its
// lines. Prefer the unittest config so test-only deps (e.g. unit-threaded) are
// included; fall back to the default config for packages without one.
public string[] dubDescribe(in string pkgDir, in string dataKind) {
    import std.process: Config, execute;

    const describe = ["dub", "describe"];
    const dataArgs = ["--data=" ~ dataKind, "--data-list"];

    auto withUnittest = execute(  // auto: need status and output, not just lines
        describe ~ ["--config=unittest"] ~ dataArgs,
        null, Config.none, size_t.max, pkgDir,
    );
    if (withUnittest.status == 0)
        return parseDescribeList(withUnittest.output);

    const fallback = execute(
        describe ~ dataArgs,
        null, Config.none, size_t.max, pkgDir,
    );
    if (fallback.status != 0)
        throw new Exception(
            "dub describe " ~ dataKind ~ " failed in " ~ pkgDir ~ ": "
            ~ fallback.output,
        );

    return parseDescribeList(fallback.output);
}

// Split a `dub describe --data-list` block into its non-empty, trimmed lines.
public string[] parseDescribeList(in string output) @safe pure {
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.string: splitLines, strip;

    return output
        .splitLines
        .map!(l => l.strip.idup)
        .filter!(l => l.length > 0)
        .array;
}

// Keep only the package's own modules (under pkgDir, so the generated test
// runner in the dub cache and dependency sources drop out) that are not
// non-standalone runner/package files.
public string[] discoverFixtures(in string pkgDir, in string[] sourceFiles) {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.path: baseName, dirSeparator;
    import std.string: startsWith;

    const prefix = pkgDir ~ dirSeparator;
    auto fixtures = sourceFiles
        .filter!(f => f.startsWith(prefix))
        .filter!(f => !f.baseName.isTestRunnerFile)
        .map!(f => f.idup)
        .array;
    fixtures.sort;
    return fixtures;
}

bool isTestRunnerFile(in string basename) {
    import std.string: endsWith;
    // Exclude non-standalone files: runner entry points and package modules.
    return basename == "main.d"
        || basename == "package.d"
        || basename.endsWith("_main.d");
}

public string findPkgDir(in string name) {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.file: dirEntries, exists, SpanMode;
    import std.path: baseName, buildPath, expandTilde;
    import std.process: execute;
    import std.string: startsWith;

    const cache = expandTilde("~/.dub/packages");

    // Handles both cache layouts:
    //   new: ~/.dub/packages/<name>/<version>/<name>/
    //   old: ~/.dub/packages/<name>-<version>/<name>/
    string[] scan() {
        if (!cache.exists) return [];
        const newStyle = buildPath(cache, name);
        if (newStyle.exists)
            return dirEntries(newStyle, SpanMode.shallow)
                .filter!(e => e.isDir)
                .map!(e => buildPath(e.name, name))
                .filter!(p => p.exists)
                .array;
        return dirEntries(cache, SpanMode.shallow)
            .filter!(e => e.isDir && e.name.baseName.startsWith(name ~ "-"))
            .map!(e => buildPath(e.name, name))
            .filter!(p => p.exists)
            .array;
    }

    auto found = scan;  // auto: mutable for sort and re-fetch
    if (found.length == 0) {
        execute(["dub", "fetch", name]);
        found = scan;
    }
    if (found.length == 0)
        throw new Exception("could not find package '" ~ name ~ "' in dub cache");
    found.sort;
    return found[$ - 1];
}
