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

// All unit_threaded import directories, initialized at runtime because
// discovering subpackage directories requires OS calls that cannot run at
// compile time.
private string[] unitThreadedImportPaths;
private string[] cerealImportPaths;

// Derive all unit_threaded import directories from the location of a known
// symbol so we don't hardcode a dub cache path.
//
// unit_threaded 2.2.3 splits its source across a main directory and several
// subpackages under `subpackages/*/source/`.  All of them must appear on the
// import path for `import unit_threaded;` to resolve fully.
//
// ShouldFail lives in the runner subpackage at:
//   unit-threaded/subpackages/runner/source/unit_threaded/runner/attrs.d
// The package root is 6 directories up from attrs.d.
shared static this() {
    import std.path: buildPath, dirName;
    import std.file: dirEntries, SpanMode, exists;
    import unit_threaded.runner.attrs: ShouldFail;
    const attrsFile = __traits(getLocation, ShouldFail)[0];
    // 6 dirNames up: attrs.d → runner → unit_threaded → source → runner → subpackages → root
    const packageRoot = attrsFile
        .dirName  // runner
        .dirName  // unit_threaded
        .dirName  // source (subpackage source)
        .dirName  // runner (subpackage dir)
        .dirName  // subpackages
        .dirName; // unit-threaded (package root)
    unitThreadedImportPaths = [buildPath(packageRoot, "source")];
    foreach (entry; dirEntries(buildPath(packageRoot, "subpackages"), SpanMode.shallow)) {
        const subSrc = buildPath(entry.name, "source");
        if (exists(subSrc))
            unitThreadedImportPaths ~= subSrc;
    }
    cerealImportPaths = ["vendor/cerealed/src"] ~ unitThreadedImportPaths;
}

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
