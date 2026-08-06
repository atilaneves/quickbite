module quickbite.backends.native.link_files;


private:


// Import paths under the package belong to the project under test and are
// compiled fresh per run; the rest belong to dependencies, whose code is
// supplied by the dependency images.
package string[] dependencyImportPathsOutside(
    in string[] importPaths,
    in string packageRoot,
) @safe {
    import std.algorithm.iteration: filter, map;
    import std.algorithm.searching: startsWith;
    import std.array: array;
    import std.path: absolutePath, buildNormalizedPath, dirSeparator;

    if (packageRoot.length == 0)
        return [];

    const root = packageRoot.absolutePath.buildNormalizedPath;
    bool underPackage(in string path) {
        const normalised = path.absolutePath.buildNormalizedPath;
        return normalised == root
            || normalised.startsWith(root ~ dirSeparator);
    }
    return importPaths
        .filter!(path => !underPackage(path))
        .map!(path => path.idup)
        .array;
}
