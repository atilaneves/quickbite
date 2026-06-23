module quickbite.dub;

private:

// The import paths a dub package contributes to a build: its own source path
// plus those of its transitive dependencies. Feeding these to a frontend makes
// `import <pkg>` (and any transitive module) resolve the way `dub test` does.
public string[] dubImportPaths(in string name) {
    return dubDescribe(findPkgDir(name), "import-paths");
}

// Build the package so its dependency archives exist on disk for the dependency
// image (`buildDubDependencyImage`). Plain `dub build`, no compiler shim: dub
// already knows the build, and the frontend-relevant flags are asked for
// directly via `dubCompilerArguments`. dmd, so the archives' druntime and
// extern(D) ABI match the DMD-codegen'd project and the DMD-built run executor.
public void dubBuild(in string packageName, in string pkgDir) {
    import std.process: Config, execute;

    auto result = execute(
        ["dub", "build", "--config=unittest", "--compiler=dmd"],
        null, Config.none, size_t.max, pkgDir,
    );
    // Packages without a unittest configuration still build under the default.
    if (result.status != 0)
        result = execute(
            ["dub", "build", "--compiler=dmd"],
            null, Config.none, size_t.max, pkgDir,
        );
    if (result.status != 0)
        throw new Exception(
            "dub build failed for " ~ packageName ~ ": " ~ result.output,
        );
}

// The frontend-relevant compiler flags dub chose for the unittest build, asked
// for directly via `dub describe` and forwarded verbatim: dflags (e.g.
// -preview=dip1000/dip1008), versions, debug versions, and string-import paths.
// This replaces the old compiler-shim that scraped dub's intercepted dmd
// invocation; dub already reports all of this, so quickbite just relays it.
public string[] dubCompilerArguments(in string pkgDir) {
    string[] args = dubDescribe(pkgDir, "dflags");
    foreach (version_; dubDescribe(pkgDir, "versions"))
        args ~= "-version=" ~ version_;
    foreach (debugVersion; dubDescribe(pkgDir, "debug-versions"))
        args ~= "-debug=" ~ debugVersion;
    foreach (stringImportPath; dubDescribe(pkgDir, "string-import-paths"))
        args ~= "-J=" ~ stringImportPath;
    return args;
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

// Collapse dub-built dependency archives into the native dependency image used
// by the hot project link. The project itself is not part of this image.
public string buildDubDependencyImage(
    in string packageName,
    in string[] dependencyArchives,
    in string outDir,
) {
    import std.conv: text;
    import std.file: mkdirRecurse;
    import std.path: buildPath;
    import std.process: execute;

    mkdirRecurse(outDir);
    const imagePath = buildPath(outDir, "lib" ~ packageName ~ "_dub_deps.so");
    auto command = [ // const fails: appended to below
        "cc",
        "-shared",
        "-o",
        imagePath,
        "-Wl,--whole-archive",
    ];
    command ~= dependencyArchives
        ~ "-Wl,--no-whole-archive"
        ~ "-lphobos2";

    const result = execute(command);
    if (result.status != 0)
        throw new Exception(text(
            "dependency image link failed for ",
            packageName,
            ": ",
            result.output,
        ));

    return imagePath;
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
