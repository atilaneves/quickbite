module ut.backends.runner.lang.arrays;


import ut.backends;


/++
    Generic assert message coverage.

    These tests verify expression/value rendering for failed asserts. Array feature
    tests below should not each repeat these same "actual != expected" checks.
+/
static foreach (backend; Matrix!()) {
    @("assertDiagnostic.integerEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(42 == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

// Reinterpreting a signed-byte slice as `ubyte[]` exposes its stored bits,
// rather than converting each signed value.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "native-layout/value-representation frontier (ai/plans/value.md); no raw byte view of array storage"),
)) {
    @("dynamicArray.castSignedBytesToUbytesPreservesRawBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                byte first = 1;
                byte negativeOne = -2;
                byte second = 3;
                byte negativeTwo = -4;
                byte[] signed = [first, second, negativeOne, cast(byte) 5,
                    negativeTwo];
                auto raw = cast(ubyte[]) signed;

                assert(raw[0] == cast(ubyte) 1);
                assert(raw[1] == cast(ubyte) 3);
                assert(raw[2] == cast(ubyte) 254);
                assert(raw[3] == cast(ubyte) 5);
                assert(raw[4] == cast(ubyte) 252);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.characterEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert('e' == 'f');
            }
        }).shouldThrowWithMessage("'e' != 'f'");
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.booleanEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(true == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.arrayElementMismatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 4];

                assert(a[] == b[]);
            }
        }).shouldThrowWithMessage("[1, 2, 3] != [1, 2, 4]");
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.arrayLengthMismatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2];
                ubyte[] b = [1, 2, 3];

                assert(a[] == b[]);
            }
        }).shouldThrowWithMessage("[1, 2] != [1, 2, 3]");
    }
}


/++
    Dynamic array basics.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.lengthCases." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] uninitialized;
                ubyte[] empty = [];
                ubyte[] nonEmpty = [1, 2, 3];

                assert(uninitialized.length == 0);
                assert(empty.length == 0);
                assert(nonEmpty.length == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.literalElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] literal = [1, 2];

                int a = 10;
                int b = 20;
                int[] runtime = [a, b];

                assert(literal[0] == 1);
                assert(literal[1] == 2);
                assert(runtime[0] == 10);
                assert(runtime[1] == 20);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.ubyteLiteralTruncatesElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 258;
                ubyte[] arr = [cast(ubyte) value];

                assert(arr[0] == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.indexReadWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];

                assert(values[0] == 0x29u);

                values[1] = 0x2au;

                assert(values[1] == 0x2au);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.postIncrementIndex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                size_t index = 0;

                assert(values[index++] == 0x29u);
                assert(index == 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.mutableStringLiteralCopiesDoNotShareWrites." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[2] first = "ab";
                first[0] = 'z';

                char[2] second = "ab";

                assert(second[0] == 'a');
            }
        });
    }
}


/++
    Append and concatenation.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.localAppend." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values;
                ubyte value = 42;

                values ~= value;

                assert(values.length == 1);
                assert(values[0] == value);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.appendToNonEmptyArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto values = [0x2au];

                values ~= 0x2bu;

                assert(values.length == 2);
                assert(values[0] == 0x2au);
                assert(values[1] == 0x2bu);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.refParameterAppend." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void append(ref ubyte[] values, ubyte value) {
                values ~= value;
            }

            unittest {
                ubyte[] values;
                ubyte value = 42;

                append(values, value);

                assert(values.length == 1);
                assert(values[0] == value);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.concatenation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] left = [first];
                ubyte[] right = [second];

                const combined = left ~ right;

                assert(combined.length == 2);
                assert(combined[0] == first);
                assert(combined[1] == second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.localConcatenationAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [cast(ubyte) 1];
                ubyte[] chunk = [cast(ubyte) 7, cast(ubyte) 42];

                values ~= chunk;

                assert(values.length == 3);
                assert(values[0] == 1);
                assert(values[1] == 7);
                assert(values[2] == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.elementConcatenatesWithArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte value(ubyte seed) {
                return cast(ubyte)(seed + 1);
            }

            unittest {
                ubyte first = value(9);
                ubyte second = value(first);
                ubyte[] tail = [second];

                const leftElement = first ~ tail;
                const rightElement = tail ~ first;

                assert(leftElement.length == 2);
                assert(leftElement[0] == 10);
                assert(leftElement[1] == 11);

                assert(rightElement.length == 2);
                assert(rightElement[0] == 11);
                assert(rightElement[1] == 10);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.fieldConcatenationAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;
            }

            unittest {
                Writer writer;
                ubyte[] chunk = [cast(ubyte) 7, cast(ubyte) 42];

                writer.bytes ~= chunk;

                assert(writer.bytes.length == 2);
                assert(writer.bytes[0] == 7);
                assert(writer.bytes[1] == 42);
            }
        });
    }
}


/++
    Slices.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.sliceFromRuntimeBounds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 1;
                size_t stop = values.length;

                const tail = values[start .. stop];

                assert(tail.length == 1);
                assert(tail[0] == second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.nullZeroLengthSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] values;
                size_t start = values.length;
                size_t stop = start;

                auto slice = values[start .. stop];

                assert(slice.length == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.nestedSliceWritesPropagateToOriginalArray." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 4];
                int[] s2 = s[0 .. 2];

                s2[0] = 99;

                assert(a[1] == 99);
            }
        });
    }
}

// value.md item 7's SLICE guest-local, reverse direction: `int[] s = a[];`
// should alias `a`'s storage exactly like `&a[0]` does, so a later direct
// write to `a` is visible through `s` too -- the opposite direction from
// `nestedSliceWritesPropagateToOriginalArray` above (a write through the
// slice, visible in the source). SystemLinker's `s` aliases `a`'s real
// storage, so the direct write to `a` is visible through `s`.
static foreach (backend; Matrix!()) {
    @("dynamicArray.directArrayWriteIsVisibleThroughEarlierFullSlice." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                int[] a = [one(), two()];
                int[] s = a[];
                a[0] = ninetyNine();
                assert(s[0] == 99);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.nestedSliceAppendKeepsOriginalArrayTail." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 3];
                int[] s2 = s[1 .. 2];

                s2 ~= 99;

                assert(a[3] == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.sliceAssignmentUpdatesArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[] text = ['a', 'b', 'c', 'd'];
                size_t start = 1;
                size_t stop = start + 2;

                text[start .. stop] = "xy";

                assert(text.length == 4);
                assert(text[0] == 'a');
                assert(text[1] == 'x');
                assert(text[2] == 'y');
                assert(text[3] == 'd');

                int[] values = [10, 11, 12, 13];
                values[start .. stop] = [21, 22];

                assert(values.length == 4);
                assert(values[0] == 10);
                assert(values[1] == 21);
                assert(values[2] == 22);
                assert(values[3] == 13);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("dynamicArray.overlappingSliceAssignmentIsRejectedAtCtfe." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1, first + 2];
                size_t targetStart = cast(size_t) seed(1);
                size_t targetStop = cast(size_t) seed(3);
                size_t sourceStart = cast(size_t) seed(0);
                size_t sourceStop = cast(size_t) seed(2);

                values[targetStart .. targetStop] =
                    values[sourceStart .. sourceStop];

                assert(values[1] == first);
            }
        }).shouldThrowWithMessage(
            "overlapping slice assignment `[1..3] = [0..2]`",
        );
    }
}

// Compiled overlapping slice assignment raises druntime's plain
// "Range violation"; the slice-range text is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "see sibling pin above (overlappingSliceAssignmentIsRejectedAtCtfe)"),
)) {
    @("dynamicArray.overlappingSliceAssignmentDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1, first + 2];
                size_t targetStart = cast(size_t) seed(1);
                size_t targetStop = cast(size_t) seed(3);
                size_t sourceStart = cast(size_t) seed(0);
                size_t sourceStop = cast(size_t) seed(2);

                values[targetStart .. targetStop] =
                    values[sourceStart .. sourceStop];

                assert(values[1] == first);
            }
        }).shouldThrowWithMessage("Range violation");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("dynamicArray.sliceIndexPastLengthDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                size_t start = cast(size_t) value(1);
                size_t stop = cast(size_t) value(3);
                auto slice = values[start .. stop];
                size_t index = cast(size_t) value(3);

                assert(slice[index] == first);
            }
        }).shouldThrowWithMessage("index 3 exceeds array length 2");
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text; the
// "exceeds array length" wording is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
)) {
    @("dynamicArray.sliceIndexPastLengthDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                size_t start = cast(size_t) value(1);
                size_t stop = cast(size_t) value(3);
                auto slice = values[start .. stop];
                size_t index = cast(size_t) value(3);

                assert(slice[index] == first);
            }
        }).shouldThrowWithMessage(
            "index [3] is out of bounds for array of length 2",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("dynamicArray.indexPastLengthDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1];
                size_t index = cast(size_t) value(3);

                assert(values[index] == first);
            }
        }).shouldThrowWithMessage("array index 3 is out of bounds `[0..2]`");
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text; the
// backtick-range wording is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
)) {
    @("dynamicArray.indexPastLengthDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1];
                size_t index = cast(size_t) value(3);

                assert(values[index] == first);
            }
        }).shouldThrowWithMessage(
            "index [3] is out of bounds for array of length 2",
        );
    }
}



/++
    Array allocation, resizing, copying, and operations.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.newUsesRuntimeLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t len = 1;
                ++len;

                auto values = new int[](len);
                values[1] = 42;

                assert(values.length == len);
                assert(values[0] == int.init);
                assert(values[1] == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.newCharArrayUsesRuntimeLengthAndDefaultFill." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            size_t runtimeLength(int seed) {
                return cast(size_t)(seed - 1);
            }

            unittest {
                int seed = 4;
                const len = runtimeLength(seed);

                auto text = new char[](len);

                assert(text.length == 3);
                assert(text[0] == char.init);

                text[1] = cast(char)('a' + seed);

                assert(text[1] == 'e');
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.newMultidimensionalUsesRuntimeLengths." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t rows = 1;
                ++rows;
                size_t cols = 2;
                ++cols;

                auto values = new int[][](rows, cols);
                values[1][2] = 42;

                assert(values.length == rows);
                assert(values[0].length == cols);
                assert(values[1][2] == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.lengthAssignmentResizesArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];

                values.length = 4;

                assert(values.length == 4);
                assert(values[0] == first);
                assert(values[1] == first + 1);
                assert(values[2] == 0);
                assert(values[3] == 0);

                values.length = 1;

                assert(values.length == 1);
                assert(values[0] == first);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("dynamicArray.lengthAssignmentDefaultInitializesStructElements." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Marked {
                int value = 42;
            }

            unittest {
                Marked[] values;
                values.length = 1;

                assert(values[0].value == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.copyFromRuntimeArrayUsesArrayCtor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int seedValue = seed(40);
                int[2] source;
                source[0] = seedValue;
                source[1] = seedValue + 1;

                int[2] copy = source;

                assert(copy[0] == seedValue);
                assert(copy[1] == seedValue + 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.multidimensionalSliceBlockAssignRepeatsRow." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[2][2] matrix;

                matrix[] = [first, first + 1];

                assert(matrix[0][0] == first);
                assert(matrix[0][1] == first + 1);
                assert(matrix[1][0] == first);
                assert(matrix[1][1] == first + 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.arrayOperationAddsRuntimeElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int second = value(first + 1);
                int[] left = [first, second];
                int[] right = [first + 30, second + 40];
                int[] sums = [0, 0];

                sums[] = left[] + right[];

                assert(sums.length == 2);
                assert(sums[0] == 50);
                assert(sums[1] == 62);
            }
        });
    }
}


/++
    Dynamic array return values.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.returnValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                const result = identity(values);

                assert(result.length == 2);
                assert(result[0] == first);
                assert(result[1] == second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.sliceReturnValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] tail(ubyte[] values, size_t start, size_t stop) {
                return values[start .. stop];
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 1;
                size_t stop = values.length;

                const result = tail(values, start, stop);

                assert(result.length == 1);
                assert(result[0] == second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.indexesCallResult." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                assert(identity(values)[1] == second);
            }
        });
    }
}


/++
    Associative arrays.
+/
static foreach (backend; Matrix!()) {
    @("assocArray.literalKeepsRuntimeKeysAndValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] values = [first: first + 30, second: second + 30];

                assert(values.length == 2);
                assert(values[first] == 40);
                assert(values[second] == 41);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.literalKeepsLastDuplicateRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int duplicate = key(10);
                int other = key(11);
                int[int] values = [duplicate: 10, duplicate: 20, other: 30];

                assert(values.length == 2);
                assert(values[duplicate] == 20);
                assert(values[other] == 30);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.keysAndValuesUseRuntimeLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(5);
                int second = value(first + 2);
                int third = value(second + 2);
                int[int] values = [
                    first: first + 18,
                    second: second + 20,
                    third: third + 22,
                ];
                int keySum;
                int valueSum;

                foreach (key; values.keys) {
                    keySum += key;
                }

                foreach (entry; values.values) {
                    valueSum += entry;
                }

                assert(keySum == 21);
                assert(valueSum == 81);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.inFindsRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int missing = key(second + 1);
                int[int] values = [
                    first: first + 30,
                    second: second + 30,
                ];

                int* found = first in values;
                int* absent = missing in values;

                assert(found !is null);
                assert(*found == 40);
                assert(absent is null);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.equalityComparesRuntimeEntries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] left = [
                    first: first + 30,
                    second: second + 30,
                ];
                int[int] same = [
                    second: second + 30,
                    first: first + 30,
                ];
                int[int] different = [
                    first: first + 30,
                    second: second + 31,
                ];

                assert(left == same);
                assert(left != different);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.removeRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int removeKey = key(10);
                int remainingKey = key(removeKey + 1);
                int[int] values = [
                    removeKey: removeKey + 30,
                    remainingKey: remainingKey + 30,
                ];

                assert(values.remove(removeKey) == true);
                assert(values.remove(removeKey) == false);
                assert(values.length == 1);
                assert(values[remainingKey] == 41);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.dupCopiesEntries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int seed) {
                return seed;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] original = [
                    first: first + 30,
                    second: second + 30,
                ];
                int[int] copy = original.dup;

                original[first] = key(99);

                assert(copy.length == original.length);
                assert(copy[first] == 40);
                assert(copy[second] == 41);
                assert(original[first] != copy[first]);
            }
        });
    }
}

// Bytecode ("Unsupported bytecode assignment target.") and IR ("Unsupported
// IR expression `null`") cannot run AA insertion.
static foreach (backend; Matrix!()) {
    @("assocArray.insertionGrowsAndOverwrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] values;

                values[first] = first + 30;
                assert(values.length == 1);

                values[second] = second + 30;
                assert(values.length == 2);

                values[first] = first + 32;
                assert(values.length == 2);

                assert(values[first] == 42);
                assert(values[second] == 41);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("assocArray.readMissingKeyThrowsDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int present = key(10);
                int absent = key(present + 1);
                int[int] values = [present: present + 30];

                auto missing = values[absent];

                assert(missing == 0);
            }
        }).shouldThrowWithMessage(
            "key `absent` not found in associative array `values`",
        );
    }
}

// Compiled missing-key reads raise druntime's plain "Range violation"; the
// key/array-name text is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
)) {
    @("assocArray.readMissingKeyThrowsDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int present = key(10);
                int absent = key(present + 1);
                int[int] values = [present: present + 30];

                auto missing = values[absent];

                assert(missing == 0);
            }
        }).shouldThrowWithMessage("Range violation");
    }
}



/++
    Pointer operations over dynamic arrays.
+/
static foreach (backend; Matrix!()) {
    @("pointer.arithmeticOverDynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int offset(int value) {
                return value;
            }

            unittest {
                int first = offset(10);
                int[] values = [first, first + 1, first + 2, first + 3];
                int step = offset(2);
                int one = offset(1);
                int* p = &values[0];
                int* q = p + step;
                int* r = one + p;
                int* s = q - 1;

                assert(*q == 12);
                assert(*r == 11);
                assert(*s == 11);
                assert(q - p == 2);
                assert((p + 3) - r == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("pointer.indexReadsDynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                size_t index = cast(size_t) value(2);
                int* p = values.ptr;
                int found = p[index];

                assert(found == values[2]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("pointer.comparisonWithinArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                int* p = &values[0];
                int* middle = &values[1];
                int* q = &values[2];

                assert(p < q);
                assert(p <= p);
                assert(q > p);
                assert(q >= middle);
                assert(p == &values[0]);
                assert(q != p);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("pointer.relationsAcrossArraysReturnFalse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] left = [first, first + 1];
                int[] right = [first + 2, first + 3];
                size_t len = cast(size_t) value(1);
                int* lp = left.ptr;
                int* rp = right.ptr;

                bool insideSameRangeShape = lp >= rp && lp + len <= rp + len;

                int otherFirst = value(20);
                int[] otherLeft = [otherFirst, otherFirst + 1];
                int[] otherRight = [otherFirst + 2, otherFirst + 3];
                size_t offset = cast(size_t) value(1);
                int* leftStart = otherLeft.ptr;
                int* rightStart = otherRight.ptr;
                int* rightEnd = rightStart + offset;

                bool insideHalfOpenRange =
                    rightStart <= leftStart && leftStart < rightEnd;

                assert(insideSameRangeShape == false);
                assert(insideHalfOpenRange == false);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("pointer.sliceFromDynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                int* p = &values[1];
                size_t start = 0;
                size_t stop = 2;

                auto slice = p[start .. stop];

                assert(slice.length == 2);
                assert(slice[1] == values[2]);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("pointer.slicePastAllocatedBlockDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];
                int* p = &values[0];
                size_t start = cast(size_t) seed(1);
                size_t stop = cast(size_t) seed(3);

                auto tail = p[start .. stop];

                assert(tail.length == 2);
            }
        }).shouldThrowWithMessage(
            "pointer slice `[1..3]` exceeds allocated memory block `[0..2]`",
        );
    }
}

// Compiled pointer slicing is unchecked: the allocated-block diagnostic is
// CTFE-only and the fixture just passes (the slice is never dereferenced).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
)) {
    @("pointer.slicePastAllocatedBlockDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];
                int* p = &values[0];
                size_t start = cast(size_t) seed(1);
                size_t stop = cast(size_t) seed(3);

                auto tail = p[start .. stop];

                assert(tail.length == 2);
            }
        });
    }
}


// Bytecode ("Unsupported bytecode assignment target."), Bytecode
// ("Unsupported type in bytecode core: int[]"), and IR ("Unsupported IR
// expression `[first, first + 1, first + 2]`") cannot run this .dup fixture.
static foreach (backend; Matrix!()) {
    @("dynamicArray.dupDetachesCopyFromOriginal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];

                int[] copy = values.dup;
                copy[0] = value(99);

                assert(copy.length == 3);
                assert(copy[0] == 99);
                assert(values[0] == 10);
                assert(copy[1] == values[1]);
            }
        });
    }
}

// Bytecode ("Unsupported bytecode assignment target."), Bytecode
// ("Unsupported type in bytecode core: int[]"), and IR (unsupported array
// literal expression) cannot run this .idup fixture.
static foreach (backend; Matrix!()) {
    @("dynamicArray.idupFreezesIndependentCopy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1];

                immutable(int)[] frozen = values.idup;
                values[0] = value(99);

                assert(frozen[0] == 10);
                assert(frozen[1] == 11);
                assert(values[0] == 99);
            }
        });
    }
}

// Bytecode ("Unsupported cast target: Tpointer") and IR (unsupported array
// literal expression) cannot run this .ptr fixture.
static foreach (backend; Matrix!()) {
    @("dynamicArray.ptrPointsAtFirstElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];

                assert(values.ptr is &values[0]);
                assert(*values.ptr == 10);
                assert(values.ptr[2] == 12);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("pointer.indexAssignmentWritesArrayStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                char* data;

                this(char[] storage) {
                    data = storage.ptr;
                }

                void put(size_t index, char value) {
                    data[index] = value;
                }
            }

            unittest {
                char[2] storage;
                auto buffer = Buffer(storage[]);

                buffer.put(1, 'x');

                assert(storage[1] == 'x');
            }
        });
    }
}

// A slice assignment through a D pointer must write the pointed-at array
// storage, not sever the aliasing. This is the silently lost write distilled
// from cerealed.
enum pointerSliceAssignSource = q{
    unittest {
        char[8] tmp;
        auto p = tmp.ptr;

        p[2 .. 5] = "abc";

        assert(tmp[3] == 'b');
    }
};

static foreach (backend; Matrix!()) {
    @("pointer.sliceAssignmentWritesArrayStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(pointerSliceAssignSource);
    }
}

enum pointerSliceArgumentEvaluatesPointerOnceSource = q{
    unittest {
        char[2] first = ['a', 'b'];
        char[2] second = ['c', 'd'];
        int calls;

        char* getPointer() {
            ++calls;
            return calls == 1 ? first.ptr : second.ptr;
        }

        char readFirst(char[] slice) {
            return slice[0];
        }

        char value = readFirst(getPointer()[0 .. 1]);

        assert(calls == 1);
        assert(value == 'a');
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Bytecode, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("pointer.sliceArgumentEvaluatesPointerOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(
            pointerSliceArgumentEvaluatesPointerOnceSource,
        );
    }
}

// An indexed write through a local pointer into a `= void` static array is a
// sibling of the pointer-slice defect distilled from cerealed.
enum pointerIndexAssignVoidInitSource = q{
    unittest {
        char[8] tmp = void;
        auto p = tmp.ptr;

        p[0] = 'x';

        assert(tmp[0] == 'x');
    }
};

static foreach (backend; Matrix!()) {
    @("pointer.indexAssignmentWritesVoidInitialisedArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(pointerIndexAssignVoidInitSource);
    }
}

// cerealed's `static_array.d(7)` test decodes into a void-initialised static
// array (`Decerealiser.value!(int[2])`'s `T val = void;` overload, taken
// because `int[2]()` does not compile) and writes each element via
// `foreach (ref e; val) cereal.grain(e);` (cereal.d's static-array `grain`).
// dmd's foreach-to-for lowering slices a static array (`T[] __r = val[];`)
// even when `val` is already a plain local, so a write through `__r`'s
// per-element alias reaches `Walker.writeThroughSliceAlias` (impl.d), which
// read the alias source's `locals` entry as-is. A `ref` parameter bound to
// the caller's `= void` local carries the bare `Value.void_` placeholder
// there (interpreter.md §9.7's deferred-read seeding), not a real `Array`,
// so rebuilding it via `withArrayElement` threw "Expected array." instead of
// writing the first element. `Bytecode` omitted: still under active
// development, does not yet write through this `ref` foreach loop variable
// (every element reads back as `0`).
enum staticArrayForeachRefVoidInitSource = q{
    void fillPair(ref int[2] val, int first) {
        int i;
        foreach (ref e; val) {
            e = first + i;
            ++i;
        }
    }

    int[2] decode(int first) {
        int[2] result = void;
        fillPair(result, first);
        return result;
    }

    unittest {
        int seed = 34;
        auto result = decode(seed);
        assert(result[0] == 34);
        assert(result[1] == 35);
    }
};

static foreach (backend; Matrix!()) {
    @("staticArray.foreachRefWritesVoidInitialisedElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(staticArrayForeachRefVoidInitSource);
    }
}

// A zero-length slice assignment through a null pointer is a no-op in
// compiled D: nothing is written, so the null provenance never matters
// (ai/plans/interpreter.md Rung 3). ScopeBuffer's own unittest hits this by
// `put`ting an empty slice into a default-initialised buffer.
enum pointerEmptyNullSliceAssignSource = q{
    struct Buffer {
        char* buf;
        uint used;

        void put(const(char)[] s) {
            const newlen = used + s.length;
            buf[used .. newlen] = s[];
            used = cast(uint) newlen;
        }
    }

    unittest {
        Buffer b;
        string empty;

        b.put(empty);

        assert(b.used == 0);
    }
};

static foreach (backend; Matrix!()) {
    @("pointer.emptySliceAssignmentThroughNullPointerIsNoOp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(pointerEmptyNullSliceAssignSource);
    }
}

// Bytecode ("Unsupported expression `rows.length`"), Bytecode
// ("Unsupported type in bytecode core: int[][]"), and IR (unsupported nested
// array literal) cannot run jagged arrays.
static foreach (backend; Matrix!()) {
    @("dynamicArray.jaggedRowsKeepIndependentLengths." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[][] rows = [[first, first + 1, first + 2], [first + 3]];

                assert(rows.length == 2);
                assert(rows[0].length == 3);
                assert(rows[1].length == 1);
                assert(rows[0][2] == 12);
                assert(rows[1][0] == 13);

                rows[1] ~= first + 4;
                assert(rows[1].length == 2);
                assert(rows[1][1] == 14);
                assert(rows[0].length == 3);
            }
        });
    }
}

// Owed §9.10 gap fixture (ai/plans/interpreter.md): the oracle's real
// `reserve` contract, not the gc_reserveArrayCapacity shim's echoed return
// value. Interpreter omitted: the shim fabricates a capacity number without
// growing the value model's backing allocation, so `arr.ptr` before and
// after filling to the reserved capacity compares unequal (representation
// debt, retires with value.md's native-layout track). Ctfe omitted:
// pointer-identity `is` on a GC-backed slice lowers to an address cast CTFE
// refuses at compile time. Bytecode omitted: `.ptr` of an array is
// not yet implemented there.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "pointer-identity `is` on a GC-backed slice lowers to an address cast CTFE refuses at compile time"),
    Omit!(Interpreter, Because.unconfirmed,
        "gc_reserveArrayCapacity shim doesn't grow the backing allocation; representation debt, retires with value.md's native-layout track"),
    Omit!(Bytecode, Because.unconfirmed, "`.ptr` of an array not yet implemented"),
)) {
    @("dynamicArray.reserveThenAppendWithinCapacityDoesNotReallocate." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr;
                const reserved = arr.reserve(8);
                assert(reserved >= 8);

                auto ptr = arr.ptr;
                foreach (i; 0 .. 8)
                    arr ~= i;

                assert(arr.ptr is ptr);
            }
        });
    }
}

// Owed §9.10 gap fixture (ai/plans/interpreter.md): `assumeSafeAppend`
// through an interior pointer (a slice that does not start at its backing
// block's base). Interpreter omitted: `gc_getArrayUsed` rebuilds its walk
// from the incoming pointer's offset but loops the full backing-block
// length, so it overruns and throws for any interior pointer
// (representation debt, retires with value.md's native-layout track). Ctfe
// omitted: `gc_getArrayUsed` has no D source, so Ctfe cannot intercept it at
// all. Bytecode omitted: same `.ptr`-of-array gap as above.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "gc_getArrayUsed has no D source, so Ctfe cannot intercept it at all"),
    Omit!(Interpreter, Because.unconfirmed,
        "gc_getArrayUsed overruns for interior pointers; representation debt, retires with value.md's native-layout track"),
    Omit!(Bytecode, Because.unconfirmed, "same `.ptr`-of-array gap as above"),
)) {
    @("dynamicArray.assumeSafeAppendOnInteriorSliceAppendsInPlace." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr;
                arr.reserve(8);
                arr ~= 1;
                arr ~= 2;
                arr ~= 3;
                arr ~= 4;

                auto tail = arr[2 .. $];
                tail.assumeSafeAppend();
                auto tailPtr = tail.ptr;
                tail ~= 99;

                assert(tail.ptr is tailPtr);
                assert(tail[2] == 99);
            }
        });
    }
}

// cerealed's decode loop grows an array one element at a time and reads the
// element it just appended via `$` (`val.length++; cereal.grain(val[$ - 1])`,
// cereal.d's grainRawArray/grainWithLengthInBytesAttr): `$` must reflect the
// array's length as of *this* index expression, computed after the growth
// that precedes it, not a stale value from before the growth ran.
// ai/plans/interpreter.md §9.7 (size_t underflow rung). The write inside
// `grown` deliberately indexes via `arr.length - 1`, not `$`, so this fixture
// isolates the read-side `$` defect the fix targets.
static foreach (backend; Matrix!()) {
    @("dynamicArray.dollarReflectsLengthAfterInPlaceGrowth." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[] grown(int count) {
                int[] arr;
                foreach (i; 0 .. count) {
                    arr.length++;
                    arr[arr.length - 1] = i + 1;
                }
                return arr;
            }

            unittest {
                assert(grown(3)[$ - 1] == 3);
            }
        });
    }
}

// cerealed's `grainWithLengthInBytesAttr` shape:
// `cereal.grain(val.arr[$ - 1])`, where `grain` takes a `ref T` parameter,
// so the callee's write must land back in the caller's array element.
// ai/plans/interpreter.md §9.7 (ref-argument array-element write-back root).
static foreach (backend; Matrix!()) {
    @("dynamicArray.refParamWriteBackThroughIndexArgument." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void setTo(ref int x, int v) {
                x = v;
            }

            unittest {
                int[] arr;
                arr.length = 3;
                setTo(arr[1], 7);
                assert(arr[1] == 7);
            }
        });
    }
}

// value.md item 7 review, finding 1: a nested `foreach` re-declares the
// inner loop's slice temporary (dmd lowers `foreach (v; row)` to a fresh
// `auto __r = row[];` every OUTER iteration) over the SAME `VarDeclaration`
// at every outer pass. `promoteSliceArrayCell` promotes `row` itself
// (the slice source) eagerly as a side effect -- no address-of needed --
// and, without dropping that stale cell on `row`'s own fresh re-declaration
// each outer iteration, the second outer iteration's inner loop reads back
// the FIRST iteration's stale cell bytes instead of its own row's values.
// SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("dynamicArray.nestedForeachDropsStaleArrayCellOnFreshRowBinding." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int three() {
                return 3;
            }

            int f() {
                int sum;
                foreach (row; [[one(), two()], [three()]])
                    foreach (v; row)
                        sum += v;
                return sum;
            }

            unittest {
                assert(f() == 6);
            }
        });
    }
}

// value.md item 7 review, finding 2: `writeCelledLocal`'s `arrayCells`
// branch treated ANY same-length whole-array assignment as an in-place byte
// mutation -- correct for the ref-writeback case it was built for, but a
// plain source-level `s = b;` REBINDS `s` to `b`'s storage; it must not
// write `b`'s bytes into whatever `s` used to alias. Here `s` is a slice
// view over `a`'s cell, so the buggy in-place refresh corrupted `a` itself.
// SystemLinker is the oracle; other backends omitted per the omit-don't-pin
// convention (unconfirmed there).
static foreach (backend; Matrix!(
)) {
    @("dynamicArray.wholeArrayRebindDoesNotWriteThroughStaleSliceCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int eight() {
                return 8;
            }

            int nine() {
                return 9;
            }

            int f() {
                int[] a = [one(), two()];
                int[] s = a[];
                int[] b = [eight(), nine()];
                s = b;
                return a[0];
            }

            unittest {
                assert(f() == 1);
            }
        });
    }
}

// value.md item 7 review, finding 3: `a ~= x` (`runArrayAppendAssignExpression`'s
// plain-`VarExp` arm) grew `locals` but left a promoted `arrayCells` entry at
// its OLD length -- a slice (`int[] s = a[];`) eagerly promotes `a`'s cell via
// `promoteSliceArrayCell`, with no address-of needed at all. A later read of
// the newly-appended element then goes through `readIndexExpression`'s cell
// arm against the stale, too-short cell. SystemLinker is the oracle; other
// backends omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed),
)) {
    @("dynamicArray.appendRefreshesSlicePromotedStaleCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int f() {
                int[] a = [one()];
                int[] s = a[];
                a ~= two();
                return a[1];
            }

            unittest {
                assert(f() == 2);
            }
        });
    }
}

// value.md item 7 review, finding 4: `runSliceAssignExpression` (`a[] = x` /
// `a[i .. j] = x`) writes `locals[variable]` directly but never refreshes a
// promoted `arrayCells` entry, which `readIndexExpression`'s cell arm reads
// in preference to the boxed mirror. Here `s = a[]` promotes `a`'s cell
// eagerly (no address-of), so `a[] = ninetyNine()` fills the boxed array but
// a later `a[0]` read returns the stale cell's original value instead. See
// the sibling `pointer.boundedSliceAssignmentWritesThroughAddressOfPromotedCell`
// fixture in expressions.d for the bounded/`&a[0]` variant. SystemLinker is
// the oracle; other backends omitted per the omit-don't-pin convention
// (unconfirmed there).
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed),
)) {
    @("dynamicArray.sliceFillAssignmentWritesThroughSlicePromotedCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int two() {
                return 2;
            }

            int ninetyNine() {
                return 99;
            }

            int f() {
                int[] a = [one(), two()];
                int[] s = a[];
                a[] = ninetyNine();
                return a[0];
            }

            unittest {
                assert(f() == 99);
            }
        });
    }
}

// value.md item 7 review, final-review finding 7: `runSliceAssignExpression`'s
// cell-refresh loop indexed `lower .. upper` unconditionally against
// `elements` (built with only `current.length` entries), so an out-of-bounds
// guest `a[0 .. 5] = x` on a 2-element array indexed `elements` past its own
// bounds and died with a HOST `core.exception.RangeError` -- even when
// `variable` never had a promoted cell at all, since `elements[index]` is
// built as the call argument before `writeThroughArrayCell`'s own no-op
// check ever runs. Fix: reject an out-of-bounds `upper` up front, before
// `elements` is built (or `rhs` is even evaluated), with the interpreter's
// own guest-visible `RangeError`, using the exact wording compiled D's own
// `ArraySliceError` raises for the identical slice assignment (confirmed
// against a real `dmd`-compiled `int[] a = [1, 2]; a[0 .. 5] = 9;`).
// SystemLinker is the oracle; other backends omitted per the omit-don't-pin
// convention (unconfirmed there).
// Ctfe omitted (unconfirmed, no sibling pin yet): DMD's CTFE engine is
// expected to reject the out-of-bounds slice assignment with its own
// compile-time diagnostic wording ("slice `[0..5]` exceeds array bounds
// `[0..2]`") rather than the runtime `RangeError` message this fixture pins,
// but that has not been characterized with a dedicated test.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "DMD's CTFE engine reports its own compile-time diagnostic wording here, but no sibling pin test captures it"),
    Omit!(Bytecode, Because.unconfirmed),
)) {
    @("dynamicArray.sliceAssignPastLengthThrowsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(1);
                int[] a = [first, first + 1];
                size_t lower = cast(size_t) value(0);
                size_t upper = cast(size_t) value(5);

                a[lower .. upper] = value(9);
            }
        }).shouldThrowWithMessage(
            "slice [0 .. 5] extends past source array of length 2",
        );
    }
}
