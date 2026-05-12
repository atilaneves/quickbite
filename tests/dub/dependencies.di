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
) @trusted;
