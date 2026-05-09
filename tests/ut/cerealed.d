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

// Strip the module declaration so DMD registers each snippet under its unique
// snippet_N filename rather than the shared `module tests.*` name — which would
// collide across backends running the same file.
private string processFile(in string content) @safe {
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
