// The DMD-built run executor for the LDC benchmark host. Reads a RunRequest
// (a linked DMD-codegen .so plus the unittest symbols to run) from the request
// file, dlopens and runs each unittest across this process boundary so the
// generated code meets a matching DMD druntime/extern(D) ABI, and writes the
// result frame to the results file. See bench-exec/run_wire.d and
// ai/spikes/ldc-eh/FINDINGS.md for why this cannot happen in the LDC host.
import run_wire: RunKind, RunRequest, RunResponse, UnitTestSymbol, WireResult,
    decodeRequest, encodeResults, encodeError, setResultsDgcAllocation;

int main(string[] args) {
    import std.file: read, write;
    import std.stdio: stderr;

    if (args.length != 3) {
        stderr.writeln("usage: bench-exec <request-file> <results-file>");
        return 2;
    }

    // An infrastructure failure (unloadable .so, missing symbol) becomes an
    // error frame the host decodes and rethrows; a failing unittest is a
    // normal result caught per test in runUnitTest, not an error frame.
    const requestBytes = cast(ubyte[]) read(args[1]);
    ubyte[] output;
    try {
        import core.memory: GC;

        const allocationBaseline = GC.allocatedInCurrentThread;
        output = encodeResults(RunResponse(
            0,
            runRequest(decodeRequest(requestBytes)),
        ));
        output.setResultsDgcAllocation(
            GC.allocatedInCurrentThread - allocationBaseline,
        );
    }
    catch (Throwable throwable)
        output = encodeError(throwable.msg);

    write(args[2], output);
    return 0;
}

private WireResult[] runRequest(in RunRequest request) {
    import core.sys.posix.dlfcn: dlopen, RTLD_GLOBAL, RTLD_NOW;
    import std.string: toStringz;

    // Resolve dependency-image symbols in the global scope before loading the
    // generated library, mirroring how SystemLinker/LLVMJit stage the cold
    // dub dependency image.
    foreach (image; request.depImages)
        if (dlopen(image.toStringz, RTLD_NOW | RTLD_GLOBAL) is null)
            throw new Exception("failed to load dependency image: " ~ image);

    final switch (request.kind) with (RunKind) {
    case sharedLibrary:
        return runSharedLibrary(request);
    case orcObjects:
        return runOrcObjects(request);
    }
}

private WireResult[] runSharedLibrary(in RunRequest request) {
    import core.runtime: Runtime;

    // Runtime.loadLibrary registers the library with druntime (module ctors,
    // GC ranges) so the unittests run against a fully set-up runtime, exactly
    // as `dub test` does.
    //
    // Deliberately no unloadLibrary: this is a one-shot process that runs one
    // package's tests and exits, like a `dub test` binary, which never unloads
    // itself. The in-process SystemLinker path (bin/ut) must unload because it
    // runs many libraries in one long-lived process, but copying that here
    // crashes: unloading unmaps the library while GC-managed fixture objects
    // still hold vptrs into it, and druntime's exit-time final collection then
    // dereferences the unmapped vtables. Leaving the library mapped until the
    // process dies (the OS reclaims it) is both correct and what dub does.
    auto library = Runtime.loadLibrary(request.libPath);
    if (library is null)
        throw new Exception("failed to load shared library: " ~ request.libPath);

    WireResult[] results;
    foreach (test; request.tests)
        results ~= runUnitTest(library, test);
    return results;
}

private WireResult[] runOrcObjects(in RunRequest request) {
    import orc.loader: createJit, runSymbol;

    // The executor is one-shot. Keep JIT mappings alive until process exit,
    // rather than disposing them while druntime may retain fixture metadata.
    auto jit = createJit(request.objectFiles);
    WireResult[] results;
    foreach (test; request.tests) {
        const run = runSymbol(jit, test.mangled);
        results ~= WireResult(run.passed, test.name, test.location, run.message);
    }
    return results;
}

private WireResult runUnitTest(void* library, in UnitTestSymbol test) {
    import core.sys.posix.dlfcn: dlsym;
    import std.string: toStringz;

    auto run = cast(void function()) dlsym(library, test.mangled.toStringz);
    if (run is null)
        throw new Exception("unittest symbol not found: " ~ test.mangled);

    auto result = WireResult(true, test.name, test.location, "");
    try
        run();
    catch (Throwable throwable) // assert failures are Errors, not Exceptions
        result = WireResult(false, test.name, test.location, throwable.msg.idup);
    return result;
}
