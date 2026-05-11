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
    static foreach (fileName; testFileNames) {
        @(backend.text ~ ".cerealed." ~ fileName)
        unittest {
            import ut.dub_paths: dubImportPaths, cerealTestsDir;
            import std.path: buildPath;

            runTestsFromFile(
                buildPath(cerealTestsDir, fileName),
                dubImportPaths,
                backend,
            );
        }
    }
}
