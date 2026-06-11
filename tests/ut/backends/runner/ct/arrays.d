module ut.backends.runner.ct.arrays;


import ut.backends;


/++
    Generic assert message coverage.

    These tests verify expression/value rendering for failed asserts. Array feature
    tests below should not each repeat these same "actual != expected" checks.
+/
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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


/++
    Slices.
+/
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
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



/++
    Array allocation, resizing, copying, and operations.
+/
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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



/++
    Pointer operations over dynamic arrays.
+/
static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

static foreach (backend; AliasSeq!(Ctfe, Interpreter, SystemLinker)) {
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

