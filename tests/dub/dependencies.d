module dub.dependencies;

private:

public struct PackageInfo {
    string dir;
    string[] importPaths;
    string[] unusedSources;
}

public PackageInfo[string] describeProject(
    in string projectRoot,
    in string packageCacheRoot,
    in string config,
) {
    import std.conv: text;
    import std.exception: enforce;
    import std.process: execute;

    string[] args = ["dub", "describe", "--vquiet", "--root", projectRoot];
    if (config.length != 0)
        args ~= ["--config", config];

    const result = execute(args);
    enforce(
        result.status == 0,
        text("dub describe failed with status ", result.status, ": ", result.output),
    );

    return describePackages(result.output);
}

private PackageInfo[string] describePackages(in string json) {
    import std.json: parseJSON;

    const description = parseJSON(json);
    PackageInfo[string] ret;
    foreach (package_; description["packages"].array) {
        auto info = packageInfo(package_); // mutable because the AA owns it.
        ret[package_["name"].str] = info;
    }
    return ret;
}

private PackageInfo packageInfo(in imported!"std.json".JSONValue package_) {
    import std.path: buildNormalizedPath;

    PackageInfo ret;
    ret.dir = package_["path"].str;

    foreach (importPath; package_["importPaths"].array)
        ret.importPaths ~= buildNormalizedPath(ret.dir, importPath.str);

    foreach (file; package_["files"].array)
        if (file["role"].str == "unusedSource")
            ret.unusedSources ~= buildNormalizedPath(ret.dir, file["path"].str);

    return ret;
}
