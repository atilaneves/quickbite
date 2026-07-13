module run_wire;


private:


// The wire format shared by the LDC-built benchmark host (SystemLinker, under
// version(LDC)) and the DMD-built run executor (bench-exec/main.d). The host
// cannot run DMD-codegen'd unittests in-process because DMD and LDC disagree on
// the extern(D) ABI (ai/spikes/ldc-eh/FINDINGS.md), so it writes a RunRequest to
// a file, execs the executor, and reads back a result frame. These types and
// their POD (de)serialisation import nothing from the quickbite or dmd packages
// so the executor subPackage builds without the dmd frontend. Both sides are
// the same architecture, so native endianness needs no normalisation.

public struct UnitTestSymbol {
    public string mangled;   // exact mangled symbol to dlsym in the .so
    public string name;      // display name (unitTest.ident)
    public string location;  // source location
}

public enum RunKind: ubyte {
    sharedLibrary,
    orcObjects,
}

public struct RunRequest {
    public RunKind kind;
    public string libPath;      // the linked DMD-codegen .so to load and run
    public string[] depImages;  // dependency images to dlopen RTLD_GLOBAL first
    public string[] objectFiles;
    public string[] archives;
    public UnitTestSymbol[] tests;
}

// Mirrors quickbite.backends.runner.TestResult without importing it (that
// module pulls in dmd.dmodule); the host converts these back into TestResults.
public struct WireResult {
    public bool passed;
    public string name;
    public string location;
    public string message;
}

public ubyte[] encodeRequest(in RunRequest request) @safe pure nothrow {
    ubyte[] bytes;
    bytes ~= ubyte(request.kind);
    bytes.putString(request.libPath);
    bytes.putSizeT(request.depImages.length);
    foreach (image; request.depImages)
        bytes.putString(image);
    bytes.putSizeT(request.objectFiles.length);
    foreach (objectFile; request.objectFiles)
        bytes.putString(objectFile);
    bytes.putSizeT(request.archives.length);
    foreach (archive; request.archives)
        bytes.putString(archive);
    bytes.putSizeT(request.tests.length);
    foreach (test; request.tests) {
        bytes.putString(test.mangled);
        bytes.putString(test.name);
        bytes.putString(test.location);
    }
    return bytes;
}

public RunRequest decodeRequest(in ubyte[] bytes) @safe pure {
    size_t pos;
    RunRequest request;
    request.kind = cast(RunKind) bytes.getByte(pos);
    request.libPath = bytes.getString(pos);
    const imageCount = bytes.getSizeT(pos);
    foreach (_; 0 .. imageCount)
        request.depImages ~= bytes.getString(pos);
    const objectFileCount = bytes.getSizeT(pos);
    foreach (_; 0 .. objectFileCount)
        request.objectFiles ~= bytes.getString(pos);
    const archiveCount = bytes.getSizeT(pos);
    foreach (_; 0 .. archiveCount)
        request.archives ~= bytes.getString(pos);
    const testCount = bytes.getSizeT(pos);
    foreach (_; 0 .. testCount)
        request.tests ~= UnitTestSymbol(
            bytes.getString(pos),
            bytes.getString(pos),
            bytes.getString(pos),
        );
    return request;
}

// The result frame. The first byte is the kind: 1 is a results frame (a count
// followed by that many records), 0 is an error frame (a single message), used
// when the executor cannot even run the tests (bad .so, missing symbol).
public ubyte[] encodeResults(in WireResult[] results) @safe pure nothrow {
    ubyte[] bytes = [ubyte(1)];
    bytes.putSizeT(results.length);
    foreach (result; results) {
        bytes ~= ubyte(result.passed ? 1 : 0);
        bytes.putString(result.name);
        bytes.putString(result.location);
        bytes.putString(result.message);
    }
    return bytes;
}

public ubyte[] encodeError(in string message) @safe pure nothrow {
    ubyte[] bytes = [ubyte(0)];
    bytes.putString(message);
    return bytes;
}

public WireResult[] decodeResults(in ubyte[] bytes) @safe pure {
    size_t pos;
    const kind = bytes.getByte(pos);
    if (kind == 0)
        throw new Exception(bytes.getString(pos));

    const count = bytes.getSizeT(pos);
    WireResult[] results;
    results.reserve(count);
    foreach (_; 0 .. count)
        results ~= WireResult(
            bytes.getByte(pos) != 0,
            bytes.getString(pos),
            bytes.getString(pos),
            bytes.getString(pos),
        );
    return results;
}

private void putSizeT(ref ubyte[] bytes, in size_t value) @trusted pure nothrow {
    bytes ~= (cast(const(ubyte)*) &value)[0 .. size_t.sizeof];
}

private void putString(ref ubyte[] bytes, in char[] str) @trusted pure nothrow {
    bytes.putSizeT(str.length);
    bytes ~= cast(const(ubyte)[]) str;
}

private ubyte getByte(in ubyte[] bytes, ref size_t pos) @safe pure {
    if (pos + 1 > bytes.length)
        throw new Exception("truncated run-wire stream");
    return bytes[pos++];
}

private size_t getSizeT(in ubyte[] bytes, ref size_t pos) @trusted pure {
    if (pos + size_t.sizeof > bytes.length)
        throw new Exception("truncated run-wire stream");
    size_t value;
    (cast(ubyte*) &value)[0 .. size_t.sizeof] = bytes[pos .. pos + size_t.sizeof];
    pos += size_t.sizeof;
    return value;
}

private string getString(in ubyte[] bytes, ref size_t pos) @trusted pure {
    const length = bytes.getSizeT(pos);
    if (pos + length > bytes.length)
        throw new Exception("truncated run-wire stream");
    auto str = (cast(const(char)[]) bytes[pos .. pos + length]).idup;
    pos += length;
    return str;
}
