module ut.cerealed;

private:

import quickbite: ExecutorBackend, runTests;
import std.conv: text;
import std.file: readText;
import std.traits: EnumMembers;
import unit_threaded;

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

// Tests that are expected to fail because they expose current frontend
// limitations on unmodified source.  Four files fail during fullSemantic:
//   - cerealiser_impl.d: type-mismatch in unit_threaded.assertions template
//     (const(ubyte)[] vs void[] in shouldEqual instantiation)
//   - encode.d: `pure` unittest calls impure cerealize template
//   - property.d: `Types!(...)` template from unit_threaded.property not found
//   - reset.d: same type-mismatch as cerealiser_impl.d
// Because fullSemantic fails, the source-content cache is never populated for
// these files.  All three backends encounter the same frontend error, so all
// three are marked @ShouldFail.
private enum shouldFail(ExecutorBackend backend, string testFile) =
    testFile == "vendor/cerealed/tests/cerealiser_impl.d" ||
    testFile == "vendor/cerealed/tests/encode.d" ||
    testFile == "vendor/cerealed/tests/property.d" ||
    testFile == "vendor/cerealed/tests/reset.d";

// One test per (backend, test-file) pair.  Each test exercises only
// the unittest blocks in that file, so failures are localised.
static foreach (backend; EnumMembers!ExecutorBackend) {
    static foreach (testFile; testFiles) {
        static if (shouldFail!(backend, testFile)) {
            @ShouldFail
            @(backend.text ~ ".cerealed." ~ testFile)
            unittest {
                runTests(readText(testFile), cerealImportPaths, backend);
            }
        } else {
            @(backend.text ~ ".cerealed." ~ testFile)
            unittest {
                runTests(readText(testFile), cerealImportPaths, backend);
            }
        }
    }
}

// Use the real unit-threaded package that dub compiled the test runner with.
// ShouldFail lives under:
// unit-threaded/subpackages/runner/source/unit_threaded/runner/attrs.d
private string[] cerealImportPaths() {
    import std.path: buildPath, dirName;
    import unit_threaded.runner.attrs: ShouldFail;

    const attrsFile = __traits(getLocation, ShouldFail)[0];
    const packageRoot = attrsFile
        .dirName
        .dirName
        .dirName
        .dirName
        .dirName
        .dirName;
    return [
        "vendor/cerealed/src",
        buildPath(packageRoot, "source"),
        buildPath(packageRoot, "subpackages", "assertions", "source"),
        buildPath(packageRoot, "subpackages", "behave", "source"),
        buildPath(packageRoot, "subpackages", "exception", "source"),
        buildPath(packageRoot, "subpackages", "from", "source"),
        buildPath(packageRoot, "subpackages", "integration", "source"),
        buildPath(packageRoot, "subpackages", "mocks", "source"),
        buildPath(packageRoot, "subpackages", "property", "source"),
        buildPath(packageRoot, "subpackages", "runner", "source"),
    ];
}
