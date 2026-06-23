module quickbite.dub;

private:

public struct DubBuild {
    string[] rootCompilerArguments;
}

// The import paths a dub package contributes to a build: its own source path
// plus those of its transitive dependencies. Feeding these to a frontend makes
// `import <pkg>` (and any transitive module) resolve the way `dub test` does.
public string[] dubImportPaths(in string name) {
    return dubDescribe(findPkgDir(name), "import-paths");
}

// Build a dub package through a compiler shim that delegates to DMD while
// preserving the exact root-package compiler invocation dub chose. The
// benchmark feeds those args to DMD's own option parser before semantic.
public DubBuild dubBuildWithCompilerShim(
    in string packageName,
    in string pkgDir,
    in string[] sourceFiles,
) {
    import std.conv: text;
    import std.file: mkdirRecurse;
    import std.path: buildPath;
    import std.process: Config, execute;

    const outDir = buildPath(pkgDir, ".quickbite");
    const rspDir = buildPath(outDir, "dub-rsp");
    mkdirRecurse(rspDir);

    const logPath = buildPath(outDir, "dub-compiler-invocations.log");
    const shimPath = buildPath(outDir, "quickbite-dub-dmd");
    writeCompilerShim(shimPath, logPath, rspDir);

    auto buildResult = executeDubBuild(pkgDir, shimPath, false);
    if (buildResult.status != 0)
        throw new Exception(text(
            "dub build failed for ",
            packageName,
            ": ",
            buildResult.output,
        ));

    try
        return DubBuild(rootCompilerArguments(logPath, pkgDir, sourceFiles));
    catch (Exception) {
        writeCompilerShim(shimPath, logPath, rspDir);
        buildResult = executeDubBuild(pkgDir, shimPath, true);
        if (buildResult.status != 0)
            throw new Exception(text(
                "dub build --force failed for ",
                packageName,
                ": ",
                buildResult.output,
            ));
        return DubBuild(rootCompilerArguments(logPath, pkgDir, sourceFiles));
    }
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

private void writeCompilerShim(
    in string shimPath,
    in string logPath,
    in string rspDir,
) {
    import std.file: exists, remove, setAttributes, write;
    import std.path: buildPath;

    if (logPath.exists)
        logPath.remove;

    write(
        shimPath,
        "#!/usr/bin/env bash\n" ~
        "set -euo pipefail\n" ~
        "log=" ~ shellQuote(logPath) ~ "\n" ~
        "rsp_dir=" ~ shellQuote(rspDir) ~ "\n" ~
        "{\n" ~
        "  printf 'CWD\\t%s\\n' \"$PWD\"\n" ~
        "  i=0\n" ~
        "  for arg in \"$@\"; do\n" ~
        "    case \"$arg\" in\n" ~
        "      @*)\n" ~
        "        rsp=\"$rsp_dir/rsp-$$-$i.rsp\"\n" ~
        "        cp \"${arg#@}\" \"$rsp\"\n" ~
        "        printf 'ARG\\t@%s\\n' \"$rsp\"\n" ~
        "        ;;\n" ~
        "      *)\n" ~
        "        printf 'ARG\\t%s\\n' \"$arg\"\n" ~
        "        ;;\n" ~
        "    esac\n" ~
        "    i=$((i + 1))\n" ~
        "  done\n" ~
        "  printf 'END\\n'\n" ~
        "} >> \"$log\"\n" ~
        "exec dmd \"$@\"\n",
    );
    setAttributes(shimPath, 0x1ED); // 0755
}

private auto executeDubBuild(
    in string pkgDir,
    in string shimPath,
    in bool force,
) {
    import std.process: Config, execute;

    const forceArgs = force ? ["--force"] : [];
    auto result = execute(
        ["dub", "build", "--config=unittest", "--compiler=" ~ shimPath]
            ~ forceArgs,
        null, Config.none, size_t.max,
        pkgDir,
    );
    if (result.status == 0)
        return result;

    return execute(
        ["dub", "build", "--compiler=" ~ shimPath] ~ forceArgs,
        null, Config.none, size_t.max,
        pkgDir,
    );
}

private string shellQuote(in string value) {
    import std.array: appender;

    auto quoted = appender!string;
    quoted.put("'");
    foreach (c; value) {
        if (c == '\'')
            quoted.put("'\\''");
        else
            quoted.put(c);
    }
    quoted.put("'");
    return quoted.data;
}

private struct CompilerInvocation {
    string cwd;
    string[] arguments;
}

private string[] rootCompilerArguments(
    in string logPath,
    in string pkgDir,
    in string[] sourceFiles,
) {
    import std.conv: text;

    auto invocations = readCompilerInvocations(logPath);
    size_t bestMatches;
    string[] bestArguments;

    foreach (invocation; invocations) {
        const matches = sourceFileMatches(invocation, pkgDir, sourceFiles);
        if (matches <= bestMatches)
            continue;

        bestMatches = matches;
        bestArguments = invocation.arguments;
    }

    if (bestArguments.length == 0)
        throw new Exception(text(
            "dub compiler shim did not capture a root compiler invocation in ",
            pkgDir,
        ));

    return bestArguments;
}

private CompilerInvocation[] readCompilerInvocations(in string logPath) {
    import std.file: readText;
    import std.string: lineSplitter, startsWith;

    CompilerInvocation[] invocations;
    CompilerInvocation current;
    bool open;

    foreach (line; logPath.readText.lineSplitter) {
        if (line.startsWith("CWD\t")) {
            current = CompilerInvocation.init;
            current.cwd = line["CWD\t".length .. $].idup;
            open = true;
        } else if (line.startsWith("ARG\t")) {
            if (!open)
                continue;
            current.arguments ~= line["ARG\t".length .. $].idup;
        } else if (line == "END" && open) {
            invocations ~= current;
            open = false;
        }
    }

    return invocations;
}

private size_t sourceFileMatches(
    in CompilerInvocation invocation,
    in string pkgDir,
    in string[] sourceFiles,
) {
    import std.algorithm.searching: canFind;
    import std.file: readText;
    import std.path: absolutePath, buildNormalizedPath;

    string[] expandedArguments;
    foreach (argument; invocation.arguments) {
        if (argument.length > 1 && argument[0] == '@') {
            foreach (line; argument[1 .. $].readText.splitResponseLines)
                expandedArguments ~= line;
        } else
            expandedArguments ~= argument;
    }

    size_t matches;
    foreach (argument; expandedArguments) {
        if (!argument.canFind(".d"))
            continue;

        const absolute = argument.absolutePath(invocation.cwd).buildNormalizedPath;
        foreach (sourceFile; sourceFiles)
            if (absolute == sourceFile.absolutePath(pkgDir).buildNormalizedPath) {
                ++matches;
                break;
            }
    }
    return matches;
}

private string[] splitResponseLines(in string response) {
    import std.algorithm.iteration: filter, map;
    import std.array: array;
    import std.string: splitLines, strip;

    return response
        .splitLines
        .map!(line => line.strip.idup)
        .filter!(line => line.length > 0)
        .array;
}
