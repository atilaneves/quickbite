module quickbite_dub_library.package_resolver;

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
) @trusted {
    import dub.description: ProjectDescription, SourceFileRole;
    import dub.generators.generator: GeneratorSettings;
    import dub.platform: determineBuildPlatform;
    import dub.project: Project;
    import std.path: buildNormalizedPath;

    // dub's project construction API mutates/cache-fills these handles.
    auto packageManager = packageManagerInstance(projectRoot, packageCacheRoot);
    auto pack = packageManager.getOrLoadPackage(projectRoot.nativePath);
    pack.removeHelperDependency;
    auto project = new Project(packageManager, pack);
    auto buildPlatform = determineBuildPlatform;
    buildPlatform.compilerBinary = buildPlatform.compiler;

    GeneratorSettings settings;
    settings.platform = buildPlatform;
    settings.config = config.length == 0
        ? project.getDefaultConfiguration(buildPlatform)
        : config;

    registerDefaultCompilers;
    const ProjectDescription description = project.describe(settings);

    PackageInfo[string] ret;
    foreach (package_; description.packages) {
        PackageInfo info;
        info.dir = package_.path;

        foreach (importPath; package_.importPaths)
            info.importPaths ~= buildNormalizedPath(package_.path, importPath);

        foreach (file; package_.files)
            if (file.role == SourceFileRole.unusedSource)
                info.unusedSources ~= buildNormalizedPath(package_.path, file.path);

        ret[package_.name] = info;
    }

    return ret;
}

private void registerDefaultCompilers() @trusted {
    import dub.compilers.compiler: registerCompiler;
    import dub.compilers.dmd: DMDCompiler;
    import dub.compilers.gdc: GDCCompiler;
    import dub.compilers.ldc: LDCCompiler;

    static bool registered;
    if (registered)
        return;

    registerCompiler(new DMDCompiler);
    registerCompiler(new GDCCompiler);
    registerCompiler(new LDCCompiler);
    registered = true;
}

private void removeHelperDependency(
    imported!"dub.package_".Package pack,
) @trusted {
    enum helperPackage = "quickbite-dub-library";

    pack.recipe.buildSettings.dependencies.remove(helperPackage);
    foreach (ref configuration; pack.recipe.configurations)
        configuration.buildSettings.dependencies.remove(helperPackage);
}

public string resolvePackagePath(
    in string projectRoot,
    in string packageCacheRoot,
    in string name,
    in string ver,
) @trusted {
    import dub.dependency: PackageName, Version;
    import std.exception: enforce;

    auto pkg = packageManagerInstance(projectRoot, packageCacheRoot)
        .getPackage(PackageName(name), Version(ver));
    enforce(pkg !is null, "dub package not found: " ~ name ~ "@" ~ ver);

    const path = pkg.path.toNativeString;
    return path.length > 0 && path[$ - 1] == '/' ? path[0 .. $ - 1] : path;
}

private imported!"dub.internal.vibecompat.inet.path".NativePath nativePath(
    in string path,
) @trusted {
    import dub.internal.vibecompat.inet.path: NativePath;

    return NativePath(path);
}

private imported!"dub.packagemanager".PackageManager packageManagerInstance(
    in string projectRoot,
    in string packageCacheRoot,
) @trusted {
    import dub.internal.logging: LogLevel, setLogLevel;
    import dub.internal.vibecompat.inet.path: NativePath;
    import dub.packagemanager: PackageManager;

    static PackageManager instance;
    if (instance is null) {
        setLogLevel(LogLevel.none);
        instance = new PackageManager(
            NativePath(projectRoot),
            NativePath(packageCacheRoot),
            NativePath.init,
        );
    }
    return instance;
}
