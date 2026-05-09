module ut.cerealed;

private:

import quickbite: ExecutorBackend, runTests;
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

// vendor/ut_stubs provides a single-module stub for the unit_threaded
// symbols used by cerealed tests (shouldEqual, shouldThrow, etc.).
// This allows DMD to resolve `import unit_threaded` without pulling in
// the full multi-subpackage real library.
private immutable cerealImportPaths = ["vendor/cerealed/src", "vendor/ut_stubs"];

// All cerealed test files now pass with the IR backend.
private immutable shouldFailFiles = (string[]).init;

// One test per cerealed test file for the IR backend.  Each test exercises
// only the unittest blocks in that file, so failures are localised.
static foreach (testFile; testFiles) {
    static if (shouldFailFiles.contains(testFile)) {
        @ShouldFail
        @("ir.cerealed." ~ testFile)
        unittest {
            runTests(testFile, cerealImportPaths, ExecutorBackend.ir);
        }
    } else {
        @("ir.cerealed." ~ testFile)
        unittest {
            runTests(testFile, cerealImportPaths, ExecutorBackend.ir);
        }
    }
}

private bool contains(immutable string[] arr, string value) @safe pure nothrow {
    foreach (elem; arr)
        if (elem == value)
            return true;
    return false;
}
