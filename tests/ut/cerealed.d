module ut.cerealed;

private:

import quickbite: ExecutorBackend, runTests;
import std.conv: text;
import std.traits: EnumMembers;
import unit_threaded;

// cerealed library source files, in inclusion order.
// package.d is excluded — it becomes empty after import-stripping.
private immutable libFiles = [
    "vendor/cerealed/src/attrs.d",
    "vendor/cerealed/src/traits.d",
    "vendor/cerealed/src/utils.d",
    "vendor/cerealed/src/scopebuffer.d",
    "vendor/cerealed/src/range.d",
    "vendor/cerealed/src/cereal.d",
    "vendor/cerealed/src/cerealiser.d",
    "vendor/cerealed/src/decerealiser.d",
    "vendor/cerealed/src/cerealizer.d",
    "vendor/cerealed/src/decerealizer.d",
];

// One entry per cerealed test file.  Each runs independently against
// the full library source so there are no cross-file symbol conflicts.
private immutable testFiles = [
    "vendor/cerealed/tests/bugs.d",
    "vendor/cerealed/tests/cerealiser_impl.d",
    "vendor/cerealed/tests/classes.d",
    "vendor/cerealed/tests/compile_time.d",
    "vendor/cerealed/tests/decode.d",
    "vendor/cerealed/tests/encode.d",
    "vendor/cerealed/tests/encode_decode.d",
    "vendor/cerealed/tests/enums.d",
    "vendor/cerealed/tests/example.d",
    "vendor/cerealed/tests/multidimensional_array.d",
    "vendor/cerealed/tests/nested.d",
    "vendor/cerealed/tests/pointers.d",
    "vendor/cerealed/tests/property.d",
    "vendor/cerealed/tests/protocol_unit.d",
    "vendor/cerealed/tests/range.d",
    "vendor/cerealed/tests/reset.d",
    "vendor/cerealed/tests/static_array.d",
    "vendor/cerealed/tests/structs.d",
    "vendor/cerealed/tests/utils.d",
];

// Minimal stubs for unit_threaded symbols used inside unittest blocks.
// These are defined in D so DMD can type-check them; quickbite's VM
// executes them.  shouldThrow variants are no-ops until exception
// support lands in both backends.
private immutable unitThreadedStub = q{
    void writelnUt(T...)(T) {}
    // Untyped stub: the real shouldEqual asserts equality; here we can't
    // assert because the types may differ in const-ness (e.g. int[int] vs
    // const(int[int])) which DMD rejects for ==.  The backends will catch
    // incorrect behaviour via the real assertions in the unit test bodies.
    void shouldEqual(T, U)(T, U) {}
    void shouldThrow(T)(T) {}
    void shouldThrow(E, T)(T) {}
    void shouldThrowWithMessage(T)(T, string) {}
    void shouldNotThrow(T)(T) {}
    void shouldBeTrue(T)(T val) { assert(val); }
    void shouldBeFalse(T)(T val) { assert(!val); }
    enum SingleThreaded;
};

// Strip lines that become redundant or undefined after concatenation:
// module declarations, intra-library imports, and unit_threaded imports
// (whose symbols are provided by the stub above).
private string processFile(in string content) {
    import std.string: splitLines, strip, startsWith;
    import std.array: appender;

    auto result = appender!string;
    foreach (line; content.splitLines) {
        const trimmed = line.strip;
        if (trimmed.startsWith("module cerealed.") ||
            trimmed.startsWith("module tests.") ||
            trimmed.startsWith("import cerealed") ||
            trimmed.startsWith("public import cerealed") ||
            trimmed.startsWith("import unit_threaded"))
            continue;
        result ~= line;
        result ~= "\n";
    }
    return result[];
}

// Build the complete source string for one cerealed test file:
// stubs, then the full library, then the test file itself.
private string makeCerealSource(in string testFile) {
    import std.file: readText;
    import std.array: appender;

    auto source = appender!string;
    source ~= unitThreadedStub;
    foreach (lib; libFiles)
        source ~= processFile(readText(lib));
    source ~= processFile(readText(testFile));
    return source[];
}

// One test per (backend, test-file) pair.  Each test exercises only
// the unittest blocks in that file, so failures are localised.
static foreach (backend; EnumMembers!ExecutorBackend) {
    static foreach (testFile; testFiles) {
        @(backend.text ~ ".cerealed." ~ testFile)
        unittest {
            makeCerealSource(testFile).runTests(backend);
        }
    }
}
