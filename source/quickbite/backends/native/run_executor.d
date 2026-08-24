module quickbite.backends.native.run_executor;


private:


// The LDC benchmark host uses a DMD-built executor for generated code. Keep
// process spawning here so SystemLinker and LLVMJit share the same boundary.
public struct RunExecutorConfig {
    public string workingDirectory;
    public string executable;
}

public void runExecutor(
    in string requestFile,
    in string resultsFile,
    in RunExecutorConfig config = RunExecutorConfig.init,
) {
    import std.conv: text;
    import std.file: exists, readText, remove;
    import std.process: Config, spawnProcess, wait;
    import std.stdio: File, stdin;
    import std.string: stripRight;

    auto devNull = File("/dev/null", "w");
    const stderrPath = resultsFile ~ ".stderr";
    scope(exit)
        if (stderrPath.exists)
            stderrPath.remove;
    auto stderrFile = File(stderrPath, "w");
    const executable = config.executable.length > 0
        ? config.executable
        : executorPath;
    auto pid = spawnProcess(
        [executable, requestFile, resultsFile],
        stdin,
        devNull,
        stderrFile,
        null,
        Config.none,
        config.workingDirectory,
    );
    const status = wait(pid);
    stderrFile.close;
    if (status != 0) {
        const diagnostics = stderrPath.readText.stripRight;
        const detail = diagnostics.length == 0 ? "" : ":\n" ~ diagnostics;
        throw new Exception(text(
            "run executor exited with status ", status,
            " (a fixture may have crashed the process)",
            detail,
        ));
    }
}

private string executorPath() {
    import std.file: exists, thisExePath;
    import std.path: buildPath, dirName;

    const path = buildPath(thisExePath.dirName, "bench-exec");
    if (!path.exists)
        throw new Exception(
            "run executor not found at " ~ path
            ~ " (build it with `dub build :bench-exec`)",
        );
    return path;
}
