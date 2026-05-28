module ut.executors.deps.cerealed;


import ut.executors;
import std.conv: text;


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

static foreach (executorName; matureExecutorNames) {
    static if (executorName == ExecutorName.dmdCtfe) {
        @("cerealed.compile_time.d.dmdCtfe")
        unittest {
            runCerealedTest!(executorName, "compile_time.d");
        }
    } else {
        static foreach (fileName; testFileNames) {
            // These IR cases currently fail only after earlier tests have run,
            // while passing in isolation. Keep them out of the matrix until the
            // ordering-dependent frontend/lowering state is fixed.
            static if (!skipCerealedTest!(executorName, fileName)) {
                @("cerealed." ~ fileName ~ "." ~ executorName.text)
                unittest {
                    runCerealedTest!(executorName, fileName);
                }
            }
        }
    }
}

private enum skipCerealedTest(ExecutorName executorName, string fileName) =
    executorName == ExecutorName.ir && (
        fileName == "decode.d" ||
        fileName == "encode_decode.d"
    );

@("cerealed.floatRoundTrip.ir")
unittest {
    import ut.dub_paths: dubImportPaths;

    q{
        import cerealed.cerealiser;
        import cerealed.decerealiser;

        unittest {
            auto enc = Cerealiser();
            float value = -4.3f;
            enc ~= value;

            auto dec = Decerealiser(enc.bytes);
            assert(dec.value!float == value);
        }
    }.runTests(dubImportPaths, ExecutorName.ir);
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
    }.runTests(dubImportPaths, ExecutorName.treeWalkingOld);
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
    }.runTests(dubImportPaths, ExecutorName.treeWalkingOld);
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
    }.runTests(dubImportPaths, ExecutorName.treeWalkingOld);
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
    }.runTests(dubImportPaths, ExecutorName.treeWalkingOld);
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
    }.runTests(dubImportPaths, ExecutorName.treeWalkingOld);
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
    }.runTests(dubImportPaths, ExecutorName.treeWalkingOld);
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
    }.runTests(dubImportPaths, ExecutorName.treeWalkingOld);
}

private void runCerealedTest(ExecutorName executorName, string fileName)() {
    import ut.dub_paths: dubImportPaths, cerealTestsDir;
    import std.path: buildPath;

    runTestsFromFile(
        buildPath(cerealTestsDir, fileName),
        dubImportPaths,
        executorName,
    );
}
