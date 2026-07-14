module quickbite.backends.native.run_executor;


private:


// The LDC benchmark host uses a DMD-built executor for generated code. Keep
// process spawning here so SystemLinker and LLVMJit share the same boundary.
public void runExecutor(in string requestFile, in string resultsFile) {
    import std.conv: text;
    import std.process: spawnProcess, wait;
    import std.stdio: File, stdin;

    auto devNull = File("/dev/null", "w");
    auto pid = spawnProcess(
        [executorPath, requestFile, resultsFile],
        stdin,
        devNull,
        devNull,
    );
    const status = wait(pid);
    if (status != 0)
        throw new Exception(text(
            "run executor exited with status ", status,
            " (a fixture may have crashed the process)",
        ));
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
