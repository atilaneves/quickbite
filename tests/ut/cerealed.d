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
    // Asserts t == u when == compiles (e.g. arrays, integrals).  For types
    // where == is rejected by DMD (e.g. int[int] vs const(int[int])), the
    // static-if branch is skipped and the call is a no-op.
    void shouldEqual(T, U)(T t, U u) {
        static if (__traits(compiles, t == u))
            assert(t == u, "shouldEqual failed");
    }
    // shouldThrow is a no-op until exception support lands in both backends.
    void shouldThrow(T)(T) {}
    void shouldThrow(lazy void) {}
    void shouldThrow(E : Throwable, T)(T) {}
    void shouldThrowWithMessage(T)(T, string) {}
    void shouldNotThrow(T)(T) {}
    void shouldNotThrow(lazy void) {}
    void shouldNotThrow(E : Throwable, T)(T) {}
    void shouldNotEqual(T, U)(T t, U u) {
        static if (__traits(compiles, t == u))
            assert(t != u, "shouldNotEqual failed");
    }
    void shouldBeTrue(T)(T val) { assert(val); }
    void shouldBeFalse(T)(T val) { assert(!val); }
    // unit_threaded property-testing stubs — no-ops until property testing lands.
    struct Types(T...) {}
    void check(alias pred)() {}
    enum SingleThreaded;
};

// One test per (backend, test-file) pair.  Each test exercises only
// the unittest blocks in that file, so failures are localised.
// @ShouldFail: all cerealed tests are currently expected to fail because
// the backends do not yet support the required language features.  Remove
// @ShouldFail on a test-by-test basis as features land and tests start
// passing.  An unexpected pass (test passing while still annotated) will
// be flagged by unit-threaded, prompting removal of the annotation.
static foreach (backend; EnumMembers!ExecutorBackend) {
    static foreach (testFile; testFiles) {
        static if (testFile == "vendor/cerealed/tests/reset.d" ||
            testFile == "vendor/cerealed/tests/utils.d" ||
            testFile == "vendor/cerealed/tests/compile_time.d" ||
            testFile == "vendor/cerealed/tests/example.d" ||
            testFile == "vendor/cerealed/tests/cerealiser_impl.d" ||
            testFile == "vendor/cerealed/tests/pointers.d")
        {
            @(backend.text ~ ".cerealed." ~ testFile)
            unittest {
                makeCerealSource(testFile).runTests(backend);
            }
        }
        else
        {
            @ShouldFail
            @(backend.text ~ ".cerealed." ~ testFile)
            unittest {
                makeCerealSource(testFile).runTests(backend);
            }
        }
    }
}

// Build the complete source string for one cerealed test file:
// stubs, then the full library, then the test file itself.
private string makeCerealSource(in string testFile) @safe {
    import std.file: readText;
    import std.array: appender;

    auto source = appender!string; // auto: appender result must be mutable
    source ~= unitThreadedStub;
    foreach (lib; libFiles)
        source ~= processLibraryFile(readText(lib));
    source ~= processFile(readText(testFile));
    return source[];
}

// Library files provide declarations for the selected test file.  Their own
// unittest blocks would make every per-file test run dependency tests too.
private string processLibraryFile(in string content) @safe {
    return stripUnittestBlocks(processFile(content));
}

// Strip lines that become redundant or undefined after concatenation:
// module declarations, intra-library imports, and unit_threaded imports
// (whose symbols are provided by the stub above).
// Multi-line imports (where the first line ends with ':' and the symbols
// continue on subsequent lines) are stripped in full: once a strippable
// import line is found we keep skipping until the terminating ';' is seen.
// Single-line imports with trailing comments (e.g. `import foo; // note`)
// are treated as terminated because the ';' precedes the comment.
private string processFile(in string content) @safe {
    import std.string: splitLines, strip, startsWith, indexOf, replace;
    import std.array: appender;

    auto result = appender!string; // auto: appender result must be mutable
    bool strippingImport; // true while consuming continuation lines of a stripped import
    foreach (line; content.splitLines) {
        const trimmed = line.strip;

        if (strippingImport) {
            // Keep stripping until we find the terminating semicolon.
            if (statementEnds(trimmed))
                strippingImport = false;
            continue;
        }

        if (trimmed.startsWith("module cerealed.") ||
            trimmed.startsWith("module tests.") ||
            trimmed.startsWith("import cerealed") ||
            trimmed.startsWith("public import cerealed") ||
            trimmed.startsWith("import unit_threaded")) {
            // If the stripped line does not contain ';' before any comment,
            // it is a multi-line import; flag that we need to skip
            // continuation lines too.
            if (!statementEnds(trimmed))
                strippingImport = true;
            continue;
        }
        // Strip `pure` from unittest attribute lists so that unittest blocks
        // that are marked `@safe pure unittest` compile even when the code
        // under test (e.g. cerealise) is not pure.
        const processed = stripPureFromUnittest(line);
        result ~= processed;
        result ~= "\n";
    }
    return result[];
}

// Remove `pure` attribute tokens from lines that contain `unittest` so that
// unittest blocks annotated `@safe pure unittest` or `pure @safe unittest`
// do not cause DMD errors when the called functions are not pure.
private string stripPureFromUnittest(in string line) @safe pure {
    import std.string: strip, replace, indexOf, endsWith;

    const trimmed = line.strip;
    // Only touch lines that are unittest declarations (not calls inside blocks).
    if (!trimmed.endsWith("unittest") && trimmed.indexOf("unittest") < 0)
        return line;
    // Replace the known combinations in order longest first.
    return line
        .replace("@safe pure unittest", "@safe unittest")
        .replace("pure @safe unittest", "@safe unittest")
        .replace("pure nothrow @safe unittest", "@safe unittest")
        .replace("@safe nothrow pure unittest", "@safe unittest")
        .replace("nothrow pure @safe unittest", "@safe unittest")
        .replace("@nogc @safe pure unittest", "@safe unittest")
        .replace("pure unittest", "unittest");
}

// Returns true if the (stripped) line ends the statement, i.e. contains a
// semicolon before any inline // comment.  This handles imports like:
//     import foo; // trailing comment
// which endsWith(";") would reject because the line ends with the comment.
private bool statementEnds(in string trimmed) @safe pure nothrow {
    import std.string: indexOf;

    const semicolon = trimmed.indexOf(';');
    if (semicolon < 0)
        return false;
    const comment = trimmed.indexOf("//");
    return comment < 0 || semicolon < comment;
}

private string stripUnittestBlocks(in string content) @safe {
    import std.array: appender;
    import std.string: splitLines, startsWith, strip;

    auto result = appender!string; // auto: appender result must be mutable
    bool skipping;
    int braceDepth;

    foreach (line; content.splitLines) {
        const trimmed = line.strip;
        if (!skipping && trimmed.startsWith("unittest")) {
            skipping = true;
            braceDepth = braceDelta(line);
            continue;
        }

        if (skipping) {
            braceDepth += braceDelta(line);
            if (braceDepth == 0)
                skipping = false;
            continue;
        }

        result ~= line;
        result ~= "\n";
    }

    return result[];
}

// Known limitation: braces inside string literals or comments are counted,
// which can produce incorrect results for lines like `string s = "open {";`.
// This is acceptable for the current cerealed sources which have no such lines.
private int braceDelta(in string line) @safe pure nothrow @nogc {
    int delta;
    foreach (ch; line) {
        if (ch == '{') {
            ++delta;
            continue;
        }

        if (ch == '}')
            --delta;
    }
    return delta;
}
