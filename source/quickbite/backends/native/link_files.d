module quickbite.backends.native.link_files;


private:


package bool isSharedLibraryPath(in string linkFile) @safe pure {
    import std.string: endsWith;

    return linkFile.endsWith(".so");
}

// Import paths under the package belong to the project under test and are
// compiled fresh per run; the rest belong to dependencies, whose code is
// supplied by prebuilt archives or dependency images.
package string[] archiveImportPathsUnder(
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
