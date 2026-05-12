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
) @trusted {
    import dub.description: ProjectDescription, SourceFileRole;
    import dub.generators.generator: GeneratorSettings;
    import dub.platform: determineBuildPlatform;
    import dub.project: Project;
    import std.path: buildNormalizedPath;

    auto packageManager = packageManagerInstance(projectRoot, packageCacheRoot);
    auto pack = packageManager.getOrLoadPackage(projectRoot.nativePath);
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
