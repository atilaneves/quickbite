module quickbite.benchmarks;

private:

public void populateDmdCodegenModuleSet(
    in string[] fixtures,
    in string[] importPaths,
) {
    import quickbite.frontend.compiler: parseModule;

    // DMD-codegen walks Module.amodules, so parse every fixture before the
    // first timed run of this executor. Other benchmark executors keep their
    // existing per-fixture parse/skip behaviour.
    foreach (path; fixtures) {
        try {
            parseModule(path, importPaths);
        } catch (Exception e) {
            throw new Exception(
                "failed to pre-parse " ~ moduleDisplayName(path, importPaths)
                ~ ": " ~ e.msg,
                e,
            );
        }
    }
}

public string moduleDisplayName(in string path, in string[] importPaths) {
    import std.algorithm.searching: startsWith;
    import std.path:
        absolutePath,
        baseName,
        buildNormalizedPath,
        relativePath,
        stripExtension;
    import std.string: replace;

    const absPath = path.absolutePath.buildNormalizedPath;
    foreach (ip; importPaths) {
        const rel = absPath.relativePath(ip.absolutePath.buildNormalizedPath);
        if (!rel.startsWith(".."))
            return rel.stripExtension.replace("/", ".").replace("\\", ".");
    }
    return absPath.baseName.stripExtension;
}
