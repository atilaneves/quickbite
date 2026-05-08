module ut.cerealed;

private:

import quickbite: ExecutorBackend, runTests;
import quickbite.frontend.compiler: addImportPath;
import std.conv: text;
import std.traits: EnumMembers;
import unit_threaded;

shared static this() {
    import std.path: buildPath, dirName;
    // __FILE_FULL_PATH__ is tests/ut/cerealed.d; project root is 3 levels up.
    const projectRoot = __FILE_FULL_PATH__.dirName.dirName.dirName;
    addImportPath(buildPath(projectRoot, "vendor", "cerealed", "src"));
    addImportPath(buildPath(projectRoot, "vendor", "ut_stubs"));
}

// One entry per cerealed test file.  Each runs independently; DMD resolves
// cerealed imports from the import path set up in shared static this().
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
    void shouldThrow(E, T)(T) {}
    void shouldThrowWithMessage(T)(T, string) {}
    void shouldNotThrow(T)(T) {}
    void shouldNotThrow(E, T)(T) {}
    void shouldBeTrue(T)(T val) { assert(val); }
    void shouldBeFalse(T)(T val) { assert(!val); }
    void shouldNotEqual(T, U)(T t, U u) {
        static if (__traits(compiles, t == u))
            assert(t != u, "shouldNotEqual failed");
    }
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
            testFile == "vendor/cerealed/tests/static_array.d" ||
            testFile == "vendor/cerealed/tests/enums.d" ||
            testFile == "vendor/cerealed/tests/multidimensional_array.d" ||
            testFile == "vendor/cerealed/tests/protocol_unit.d" ||
            testFile == "vendor/cerealed/tests/range.d" ||
            testFile == "vendor/cerealed/tests/cerealiser_impl.d" ||
            testFile == "vendor/cerealed/tests/decode.d" ||
            testFile == "vendor/cerealed/tests/nested.d" ||
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

private string makeCerealSource(in string testFile) @safe {
    import std.file: readText;
    return processFile(readText(testFile));
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
// Inline `// comments` are ignored when checking for the terminating `;`.
private string processFile(in string content) @safe {
    import std.string: splitLines, strip, startsWith;
    import std.array: appender;

    auto result = appender!string; // auto: appender result must be mutable
    bool strippingImport; // true while consuming continuation lines of a stripped import
    foreach (line; content.splitLines) {
        const trimmed = line.strip;

        if (strippingImport) {
            // Keep stripping until we find the terminating semicolon.
            // Strip inline comments before checking so that a line like
            //   `import foo; // comment`
            // is not mistaken for a continuation line.
            if (lineHasSemicolon(trimmed))
                strippingImport = false;
            continue;
        }

        if (trimmed.startsWith("module cerealed.") ||
            trimmed.startsWith("module tests.") ||
            trimmed.startsWith("import cerealed") ||
            trimmed.startsWith("public import cerealed") ||
            trimmed.startsWith("import unit_threaded")) {
            // If the stripped line does not contain ';' before any inline
            // comment, it is a multi-line import; flag continuation lines.
            if (!lineHasSemicolon(trimmed))
                strippingImport = true;
            continue;
        }
        result ~= line;
        result ~= "\n";
    }
    return result[];
}

// Returns true when `line` contains a `;` that is not preceded by `//`.
// This correctly handles single-line imports with trailing comments such as
//   `import cerealed.scopebuffer; // some comment`
private bool lineHasSemicolon(in string line) @safe pure nothrow {
    import std.string: indexOf;

    const semi  = line.indexOf(';');
    if (semi < 0)
        return false;
    const slash = line.indexOf("//");
    return slash < 0 || semi < slash;
}

private string stripUnittestBlocks(in string content) @safe {
    import std.array: appender;
    import std.string: splitLines, startsWith, strip;

    auto result = appender!string; // auto: appender result must be mutable
    foreach (line; content.splitLines) {
        if (line.strip.startsWith("module "))
            continue;
        result ~= line;
        result ~= "\n";
    }
    return result[];
}
