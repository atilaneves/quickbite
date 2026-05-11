module ut.cerealed;

private:

import quickbite: ExecutorBackend, runTests;
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

// dmdCtfe: three files use unit_threaded APIs that the stub does not provide
// (.should property, shouldNotThrow on complex template types, void expressions).
private enum bool dmdCtfeShouldFail(in string fileName) {
    return fileName == "bugs.d" ||
        fileName == "cerealiser_impl.d" ||
        fileName == "encode.d";
}

static foreach (backend; EnumMembers!ExecutorBackend) {
    static foreach (fileName; testFileNames) {
        static if (
            backend == ExecutorBackend.dmdCtfe && dmdCtfeShouldFail(fileName)
        ) {
            @ShouldFail
            @(backend.text ~ ".cerealed." ~ fileName)
            unittest {
                import ut.dub_paths: cerealImportPaths, cerealTestsDir;
                import std.file: readText;
                import std.path: buildPath;

                runTests(
                    readText(buildPath(cerealTestsDir, fileName)),
                    cerealImportPaths,
                    backend,
                );
            }
        }
        else {
            @(backend.text ~ ".cerealed." ~ fileName)
            unittest {
                import ut.dub_paths: cerealImportPaths, cerealTestsDir;
                import std.file: readText;
                import std.path: buildPath;

                runTests(
                    readText(buildPath(cerealTestsDir, fileName)),
                    cerealImportPaths,
                    backend,
                );
            }
        }
    }
}
