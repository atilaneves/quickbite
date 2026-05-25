module ut.cerealed;

private:

import quickbite: ExecutorBackend, runTests, runTestsFromFile;
import std.conv: text;
import ut.backends: matureExecutorBackends;
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

static foreach (backend; matureExecutorBackends) {
    static if (backend == ExecutorBackend.dmdCtfe) {
        @("cerealed.compile_time.d.dmdCtfe")
        unittest {
            runCerealedTest!(backend, "compile_time.d");
        }
    } else {
        static foreach (fileName; testFileNames) {
            @("cerealed." ~ fileName ~ "." ~ backend.text)
            unittest {
                runCerealedTest!(backend, fileName);
            }
        }
    }
}

@("cerealed.valueArrayUsesExplicitUbyteLengthWidth.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    q{
        import cerealed.decerealiser;

        unittest {
            auto dec = Decerealiser([0, 0, 0, 1, 42]);
            const value = dec.value!(ubyte[], ubyte);
            assert(value.length == 0);
            assert(dec.bytes.length == 4);
            assert(dec.bytes[3] == 42);
        }
    }.runTests(dubImportPaths, ExecutorBackend.treeWalkingOld);
}

@("cerealed.valueArrayUsesExplicitUintLengthWidth.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    q{
        import cerealed.decerealiser;

        unittest {
            auto dec = Decerealiser([0, 0, 0, 1, 42, 99]);
            const value = dec.value!(ubyte[], uint);
            assert(value.length == 1);
            assert(value[0] == 42);
            assert(dec.bytes.length == 1);
            assert(dec.bytes[0] == 99);
        }
    }.runTests(dubImportPaths, ExecutorBackend.treeWalkingOld);
}

@("cerealed.grainDynamicArrayUsesExplicitUintLengthWidth.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    q{
        import cerealed.cereal: grain;
        import cerealed.decerealiser;

        unittest {
            auto dec = Decerealiser([0, 0, 0, 2, 42, 43, 99]);
            ubyte[] value;
            dec.grain!uint(value);
            assert(value.length == 2);
            assert(value[0] == 42);
            assert(value[1] == 43);
            assert(dec.bytes.length == 1);
            assert(dec.bytes[0] == 99);
        }
    }.runTests(dubImportPaths, ExecutorBackend.treeWalkingOld);
}

@("cerealed.valueNestedArrayUsesExplicitUbyteLengthWidth.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    q{
        import cerealed.decerealiser;

        unittest {
            auto dec = Decerealiser([1, 2, 42, 43, 99]);
            const value = dec.value!(ubyte[][], ubyte);
            assert(value.length == 1);
            assert(value[0].length == 2);
            assert(value[0][0] == 42);
            assert(value[0][1] == 43);
            assert(dec.bytes.length == 1);
            assert(dec.bytes[0] == 99);
        }
    }.runTests(dubImportPaths, ExecutorBackend.treeWalkingOld);
}

@("cerealed.decerealiseArrayDefaultsToUshortLengthWidth.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    q{
        import cerealed.decerealiser: decerealise;

        unittest {
            const value = decerealise!(ubyte[])([0, 0, 0, 1, 42]);
            assert(value.length == 0);
        }
    }.runTests(dubImportPaths, ExecutorBackend.treeWalkingOld);
}

@("cerealed.valueAssocArrayUsesExplicitUbyteLengthWidth.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    q{
        import cerealed.decerealiser;

        unittest {
            auto dec = Decerealiser([0, 0, 0, 1, 7, 9]);
            const value = dec.value!(ubyte[ubyte], ubyte);
            assert(value.length == 0);
            assert(dec.bytes.length == 5);
            assert(dec.bytes[4] == 9);
        }
    }.runTests(dubImportPaths, ExecutorBackend.treeWalkingOld);
}

@("cerealed.grainAssocArrayUsesExplicitUbyteLengthWidth.treeWalkingOld")
unittest {
    import ut.dub_paths: dubImportPaths;

    q{
        import cerealed.cereal: grain;
        import cerealed.decerealiser;

        unittest {
            auto dec = Decerealiser([0, 0, 0, 1, 7, 9]);
            ubyte[ubyte] value;
            dec.grain!ubyte(value);
            assert(value.length == 0);
            assert(dec.bytes.length == 5);
            assert(dec.bytes[4] == 9);
        }
    }.runTests(dubImportPaths, ExecutorBackend.treeWalkingOld);
}

private void runCerealedTest(ExecutorBackend backend, string fileName)() {
    import ut.dub_paths: dubImportPaths, cerealTestsDir;
    import std.path: buildPath;

    runTestsFromFile(
        buildPath(cerealTestsDir, fileName),
        dubImportPaths,
        backend,
    );
}
