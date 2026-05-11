module quickbite_dub_library.package_resolver;

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

public string resolvePackagePath(
    in string projectRoot,
    in string packageCacheRoot,
    in string name,
    in string ver,
) @trusted;
