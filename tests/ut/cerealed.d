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

// One test per (backend, test-file) pair.
// @ShouldFail: remove on a test-by-test basis as features land.
static foreach (backend; EnumMembers!ExecutorBackend) {
    static foreach (testFile; testFiles) {
        static if (testFile == "vendor/cerealed/tests/compile_time.d" ||
            testFile == "vendor/cerealed/tests/example.d" ||
            testFile == "vendor/cerealed/tests/pointers.d" ||
            testFile == "vendor/cerealed/tests/reset.d" ||
            testFile == "vendor/cerealed/tests/utils.d")
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
private string processFile(in string content) @safe {
    import std.string: splitLines, strip, startsWith, endsWith;
    import std.array: appender;

    auto result = appender!string; // auto: appender result must be mutable
    bool strippingImport; // true while consuming continuation lines of a stripped import
    foreach (line; content.splitLines) {
        const trimmed = line.strip;

        if (strippingImport) {
            // Keep stripping until we find the terminating semicolon.
            if (trimmed.endsWith(";"))
                strippingImport = false;
            continue;
        }

        if (trimmed.startsWith("module cerealed.") ||
            trimmed.startsWith("module tests.") ||
            trimmed.startsWith("import cerealed") ||
            trimmed.startsWith("public import cerealed") ||
            trimmed.startsWith("import unit_threaded")) {
            // If the stripped line does not end with ';', it is a multi-line
            // import; flag that we need to skip continuation lines too.
            if (!trimmed.endsWith(";"))
                strippingImport = true;
            continue;
        }
        result ~= line;
        result ~= "\n";
    }
    return result[];
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
