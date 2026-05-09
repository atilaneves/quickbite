module ut.cerealed;

private:

import quickbite: ExecutorBackend, runTests;
import std.conv: text;
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

// Derive the unit_threaded source directory from the location of ShouldFail
// so we don't hardcode a dub cache path.
// ShouldFail is in: .../unit-threaded/subpackages/runner/source/unit_threaded/runner/attrs.d
// Going up 6 dirs reaches .../unit-threaded/, then append "source".
private immutable unitThreadedSrcPath = () {
    import std.path: buildPath, dirName;
    const attrsFile = __traits(getLocation, ShouldFail)[0];
    return buildPath(
        attrsFile.dirName.dirName.dirName.dirName.dirName.dirName,
        "source",
    );
}();

private immutable cerealImportPaths = ["vendor/cerealed/src", unitThreadedSrcPath];

// One test per cerealed test file for the IR backend.  Each test exercises
// only the unittest blocks in that file, so failures are localised.
// @ShouldFail: all cerealed tests are currently expected to fail because
// the IR backend does not yet support the required language features.  Remove
// @ShouldFail on a test-by-test basis as features land and tests start
// passing.  An unexpected pass (test passing while still annotated) will
// be flagged by unit-threaded, prompting removal of the annotation.
static foreach (testFile; testFiles) {
    @ShouldFail
    @("ir.cerealed." ~ testFile)
    unittest {
        runTests(testFile, cerealImportPaths, ExecutorBackend.ir);
    }
}
