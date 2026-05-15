module ut.cerealed;

private:

import quickbite: ExecutorBackend, runTestsFromFile;
import std.conv: text;
import std.traits: EnumMembers;
import unit_threaded;

private immutable string[] testFileNames = [
    "bugs.d",
    "cerealiser_impl.d",
    "classes.d",
    "compile_time.d",
    "decode.d",
    "encode.d",
    "encode_decode.d",
    "enums.d",
    "example.d",
    "multidimensional_array.d",
    "nested.d",
    "pointers.d",
    "property.d",
    "protocol_unit.d",
    "range.d",
    "reset.d",
    "static_array.d",
    "structs.d",
    "utils.d",
];

static foreach (backend; EnumMembers!ExecutorBackend) {
    // dmdCtfe cannot run real-world tests that use GC, exceptions, and
    // dynamic dispatch at runtime; exclude it from the cerealed matrix.
    static if (backend != ExecutorBackend.dmdCtfe) {
        static foreach (fileName; testFileNames) {
            static if (shouldFailCerealedTest!(backend, fileName)) {
                @(backend.text ~ ".cerealed." ~ fileName, ShouldFail)
                unittest {
                    runCerealedTest!(backend, fileName);
                }
            } else {
                @(backend.text ~ ".cerealed." ~ fileName)
                unittest {
                    runCerealedTest!(backend, fileName);
                }
            }
        }
    }
}

private enum bool shouldFailCerealedTest(
    ExecutorBackend backend,
    string fileName,
) = fileName != "compile_time.d" &&
    (
        backend != ExecutorBackend.treeWalking ||
        (
            fileName != "cerealiser_impl.d" &&
            fileName != "bugs.d" &&
            fileName != "classes.d" &&
            fileName != "utils.d"
        )
    ) &&
    (
        backend != ExecutorBackend.ir ||
        (
            fileName != "cerealiser_impl.d" &&
            fileName != "bugs.d" &&
            fileName != "classes.d" &&
            fileName != "decode.d" &&
            fileName != "encode.d" &&
            fileName != "encode_decode.d" &&
            fileName != "enums.d" &&
            fileName != "example.d" &&
            fileName != "utils.d"
        )
    );

private void runCerealedTest(ExecutorBackend backend, string fileName)() {
    import ut.dub_paths: dubImportPaths, cerealTestsDir;
    import std.path: buildPath;

    runTestsFromFile(
        buildPath(cerealTestsDir, fileName),
        dubImportPaths,
        backend,
    );
}
