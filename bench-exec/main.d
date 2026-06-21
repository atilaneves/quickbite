// The DMD-built run executor for the LDC benchmark host. Reads a RunRequest
// (a linked DMD-codegen .so plus the unittest symbols to run) from the request
// file, dlopens and runs each unittest across this process boundary so the
// generated code meets a matching DMD druntime/extern(D) ABI, and writes the
// result frame to the results file. See bench-exec/run_wire.d and
// ai/spikes/ldc-eh/FINDINGS.md for why this cannot happen in the LDC host.
import run_wire: RunRequest, UnitTestSymbol, WireResult,
    decodeRequest, encodeResults, encodeError;

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
    ubyte[] output;
    try
        output = encodeResults(runRequest(decodeRequest(cast(ubyte[]) read(args[1]))));
    catch (Throwable throwable)
        output = encodeError(throwable.msg);

    write(args[2], output);
    return 0;
}

private WireResult[] runRequest(in RunRequest request) {
    import core.runtime: Runtime;
    import core.sys.posix.dlfcn: dlopen, RTLD_GLOBAL, RTLD_NOW;
    import std.string: toStringz;

    // Resolve dependency-image symbols in the global scope before loading the
    // generated library, mirroring how SystemLinker/LLVMJit stage the cold
    // dub dependency image.
    foreach (image; request.depImages)
        if (dlopen(image.toStringz, RTLD_NOW | RTLD_GLOBAL) is null)
            throw new Exception("failed to load dependency image: " ~ image);

    // Runtime.loadLibrary registers the library with druntime (module ctors,
    // GC ranges, unloadable later), matching the host's in-process path.
    auto library = Runtime.loadLibrary(request.libPath);
    if (library is null)
        throw new Exception("failed to load shared library: " ~ request.libPath);
    scope(exit) {
        import core.memory: GC;
        // Collect dead fixture objects whose vptrs point into the library
        // while it is still mapped, then unload.
        GC.collect;
        Runtime.unloadLibrary(library);
    }

    WireResult[] results;
    foreach (test; request.tests)
        results ~= runUnitTest(library, test);
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
