module ut.backends.lang.arrays;


import ut.backends;


static foreach (backend; backends) {
    @("nestedSliceWritesPropagateToOriginalArray." ~ backend.stringof)
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

    @("nestedSliceWritesPropagateToOriginalArrayFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 4];
                int[] s2 = s[0 .. 2];
                s2[0] = 99;
                assert(a[1] == 100);
            }
        }).shouldThrowWithMessage("99 != 100");
    }

    @("nestedSliceWritesPropagateToOriginalArrayFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[2 .. 5];
                int[] s2 = s[0 .. 2];
                s2[0] = 98;
                assert(a[2] == 99);
            }
        }).shouldThrowWithMessage("98 != 99");
    }

    @("nestedSliceAppendKeepsOriginalArrayTail." ~ backend.stringof)
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

    @("nestedSliceAppendKeepsOriginalArrayTailFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 3];
                int[] s2 = s[1 .. 2];
                s2 ~= 99;
                assert(a[3] == 4);
            }
        }).shouldThrowWithMessage("3 != 4");
    }

    @("nestedSliceAppendKeepsOriginalArrayTailFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 4];
                int[] s2 = s[1 .. 2];
                s2 ~= 99;
                assert(a[4] == 5);
            }
        }).shouldThrowWithMessage("4 != 5");
    }

    @("ubyteArrayAppendAssign." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto values = [0x2au];
                values ~= 0x2bu;
                assert(values.length == 2);
            }
        });
    }

    @("ubyteArrayAppendAssignFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto values = [0x2au];
                values ~= 0x2bu;
                assert(values.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("ubyteArrayAppendAssignFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto values = [0x2au];
                values ~= 0x2bu;
                values ~= 0x2cu;
                assert(values.length == 4);
            }
        }).shouldThrowWithMessage("3 != 4");
    }

    @("ubyteArrayIndexRead." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                assert(values[1] == 0x2au);
            }
        });
    }

    @("ubyteArrayIndexReadFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                assert(values[1] == 0x2bu);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("ubyteArrayIndexReadFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                assert(values[0] == 0x2au);
            }
        }).shouldThrowWithMessage("41 != 42");
    }

    @("ubyteArrayIndexWrite." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];
                values[1] = 0x2au;
                assert(values[1] == 0x2au);
            }
        });
    }

    @("ubyteArrayIndexWriteFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];
                values[1] = 0x2au;
                assert(values[1] == 0x2bu);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("ubyteArrayIndexWriteFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];
                values[0] = 0x28u;
                assert(values[0] == 0x29u);
            }
        }).shouldThrowWithMessage("40 != 41");
    }

    @("refUbyteArrayParameterAppend." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void appendAnswer(ref ubyte[] values) {
                values ~= 0x2au;
            }

            unittest {
                ubyte[] values = [];
                appendAnswer(values);
                assert(values.length == 1);
                assert(values[0] == 0x2au);
            }
        });
    }

    @("refUbyteArrayParameterAppendFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void appendAnswer(ref ubyte[] values) {
                values ~= 0x2au;
            }

            unittest {
                ubyte[] values = [];
                appendAnswer(values);
                assert(values.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("refUbyteArrayParameterAppendFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void appendAnswer(ref ubyte[] values) {
                values ~= 0x2au;
            }

            unittest {
                ubyte[] values = [0x29u];
                appendAnswer(values);
                assert(values[1] == 0x2bu);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("arrayLengthFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1, 2];
                assert(arr.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("emptyArrayLengthFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [];
                assert(arr.length == 1);
            }
        }).shouldThrowWithMessage("0 != 1");
    }

    @("emptyArrayLengthFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1];
                assert(arr.length == 0);
            }
        }).shouldThrowWithMessage("1 != 0");
    }

    @("arrayEqualTrue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 3];
                assert(a[] == b[]);
            }
        });
    }

    @("arrayEqualTrueFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 4];
                assert(a[] == b[]);
            }
        }).shouldThrowWithMessage("[1, 2, 3] != [1, 2, 4]");
    }

    @("arrayEqualTrueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2];
                ubyte[] b = [1, 2, 3];
                assert(a[] == b[]);
            }
        }).shouldThrowWithMessage("[1, 2] != [1, 2, 3]");
    }

    @("arrayEqualFalse." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 4];
                assert(a[] == b[]);
            }
        }).shouldThrowWithMessage("[1, 2, 3] != [1, 2, 4]");
    }

    @("arrayEqualFalseFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 3];
                assert((a[] == b[]) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }

    @("arrayEqualFalseFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 4];
                assert((a[] == b[]) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }

    @("ubyteArrayLiteralTruncatesElements." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 258;
                ubyte[] arr = [cast(ubyte) value];
                assert(arr[0] == 2);
            }
        });
    }

    @("ubyteArrayLiteralTruncatesElementsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 258;
                ubyte[] arr = [cast(ubyte) value];
                assert(arr[0] == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("ubyteArrayLiteralTruncatesElementsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 259;
                ubyte[] arr = [cast(ubyte) value];
                assert(arr[0] == 4);
            }
        }).shouldThrowWithMessage("3 != 4");
    }

    @("localDynamicArrayAppend." ~ backend.stringof)
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

    @("localDynamicArrayAppendFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values;
                ubyte value = 42;
                values ~= value;
                assert(values.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("localDynamicArrayAppendFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values;
                ubyte value = 42;
                values ~= value;
                assert(values[0] == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("arrayLiteralElements." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr = [1, 2];
                assert(arr[0] == 1);
                assert(arr[1] == 2);
            }
        });
    }

    @("arrayLiteralElementsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr = [1, 2];
                assert(arr[0] == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("arrayLiteralElementsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr = [1, 2];
                assert(arr[1] == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("arrayLiteralVariableElements." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int a = 10;
                int b = 20;
                int[] arr = [a, b];
                assert(arr[0] == 10);
                assert(arr[1] == 20);
            }
        });
    }

    @("arrayLiteralVariableElementsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int a = 10;
                int b = 20;
                int[] arr = [a, b];
                assert(arr[0] == 11);
            }
        }).shouldThrowWithMessage("10 != 11");
    }

    @("arrayLiteralVariableElementsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int a = 10;
                int b = 20;
                int[] arr = [a, b];
                assert(arr[1] == 21);
            }
        }).shouldThrowWithMessage("20 != 21");
    }

    @("dynamicArrayConcatenation." ~ backend.stringof)
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

    @("dynamicArrayConcatenationFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] left = [first];
                ubyte[] right = [second];

                const combined = left ~ right;

                assert(combined.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("dynamicArrayConcatenationFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] left = [first];
                ubyte[] right = [second];

                const combined = left ~ right;

                assert(combined[1] == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }

    @("arrayElementConcatenatesWithDynamicArray." ~ backend.stringof)
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

    @("arrayElementConcatenatesWithDynamicArrayFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte value(ubyte seed) {
                return cast(ubyte)(seed + 1);
            }

            unittest {
                ubyte first = value(9);
                ubyte second = value(first);
                ubyte[] tail = [second];

                const combined = first ~ tail;

                assert(combined.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("arrayElementConcatenatesWithDynamicArrayFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte value(ubyte seed) {
                return cast(ubyte)(seed + 1);
            }

            unittest {
                ubyte first = value(9);
                ubyte second = value(first);
                ubyte[] tail = [second];

                const combined = tail ~ first;

                assert(combined[1] == 11);
            }
        }).shouldThrowWithMessage("10 != 11");
    }

    @("assocArrayLiteralKeepsRuntimeKeysAndValues." ~ backend.stringof)
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

    @("assocArrayLiteralKeepsRuntimeKeysAndValuesFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] values = [first: first + 30, second: second + 30];

                assert(values.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("assocArrayLiteralKeepsRuntimeKeysAndValuesFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] values = [first: first + 30, second: second + 30];

                assert(values[second] == 42);
            }
        }).shouldThrowWithMessage("41 != 42");
    }

    @("assocArrayLiteralKeepsLastDuplicateRuntimeKey." ~ backend.stringof)
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

    @("assocArrayLiteralKeepsLastDuplicateRuntimeKeyFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int duplicate = key(10);
                int other = key(11);
                int[int] values = [duplicate: 10, duplicate: 20, other: 30];

                assert(values.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("assocArrayLiteralKeepsLastDuplicateRuntimeKeyFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int duplicate = key(10);
                int other = key(11);
                int[int] values = [duplicate: 10, duplicate: 20, other: 30];

                assert(values[duplicate] == 10);
            }
        }).shouldThrowWithMessage("20 != 10");
    }

    @("assocArrayKeysAndValuesUseRuntimeLiteral." ~ backend.stringof)
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

    @("assocArrayKeysAndValuesUseRuntimeLiteralFailureMessage.0." ~ backend.stringof)
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

                foreach (key; values.keys) {
                    keySum += key;
                }

                assert(keySum == 22);
            }
        }).shouldThrowWithMessage("21 != 22");
    }

    @("assocArrayKeysAndValuesUseRuntimeLiteralFailureMessage.1." ~ backend.stringof)
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
                int valueSum;

                foreach (entry; values.values) {
                    valueSum += entry;
                }

                assert(valueSum == 82);
            }
        }).shouldThrowWithMessage("81 != 82");
    }

    @("assocArrayInFindsRuntimeKey." ~ backend.stringof)
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

    @("assocArrayEqualityComparesRuntimeEntries." ~ backend.stringof)
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

    @("assocArrayReadMissingKeyThrowsDiagnostic." ~ backend.stringof)
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
        }).shouldThrowWithMessage("key `absent` not found in associative array `values`");
    }

    @("assocArrayRemoveRuntimeKey." ~ backend.stringof)
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

    @("assocArrayRemoveRuntimeKeyFailureMessage.0." ~ backend.stringof)
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

                assert(values.remove(removeKey) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }

    @("assocArrayRemoveRuntimeKeyFailureMessage.1." ~ backend.stringof)
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

                values.remove(removeKey);

                assert(values.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("arrayOperationAddsRuntimeElements." ~ backend.stringof)
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

    @("arrayOperationAddsRuntimeElementsFailureMessage.0." ~ backend.stringof)
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

                assert(sums.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("arrayOperationAddsRuntimeElementsFailureMessage.1." ~ backend.stringof)
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

                assert(sums[1] == 63);
            }
        }).shouldThrowWithMessage("62 != 63");
    }

    @("assocArrayDupCopiesEntries." ~ backend.stringof)
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

    @("uninitializedDynamicArrayLength." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values;
                assert(values.length == 0);
            }
        });
    }

    @("uninitializedDynamicArrayLengthFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values;
                assert(values.length == 1);
            }
        }).shouldThrowWithMessage("0 != 1");
    }

    @("uninitializedDynamicArrayLengthFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x2au];
                assert(values.length == 0);
            }
        }).shouldThrowWithMessage("1 != 0");
    }

    @("newDynamicArrayUsesRuntimeLength." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t len = 1;
                ++len;

                auto values = new int[](len);
                values[1] = 42;

                assert(values.length == len);
                assert(values[1] == 42);
            }
        });
    }

    @("newDynamicArrayUsesRuntimeLengthFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t len = 1;
                ++len;

                auto values = new int[](len);
                values[1] = 42;

                assert(values.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("newDynamicArrayUsesRuntimeLengthFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t len = 1;
                ++len;

                auto values = new int[](len);
                values[1] = 42;

                assert(values[1] == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("newCharArrayUsesRuntimeLengthAndDefaultFill." ~ backend.stringof)
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

    @("newCharArrayUsesRuntimeLengthAndDefaultFillFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            size_t runtimeLength(int seed) {
                return cast(size_t)(seed - 1);
            }

            unittest {
                int seed = 4;
                const len = runtimeLength(seed);

                auto text = new char[](len);

                assert(text.length == 4);
            }
        }).shouldThrowWithMessage("3 != 4");
    }

    @("newCharArrayUsesRuntimeLengthAndDefaultFillFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            size_t runtimeLength(int seed) {
                return cast(size_t)(seed - 1);
            }

            unittest {
                int seed = 4;
                const len = runtimeLength(seed);

                auto text = new char[](len);
                text[1] = cast(char)('a' + seed);

                assert(text[1] == 'f');
            }
        }).shouldThrowWithMessage("'e' != 'f'");
    }

    @("newMultidimensionalDynamicArrayUsesRuntimeLengths." ~ backend.stringof)
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

    @("newMultidimensionalDynamicArrayUsesRuntimeLengthsFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t rows = 1;
                ++rows;
                size_t cols = 2;
                ++cols;

                auto values = new int[][](rows, cols);
                values[1][2] = 42;

                assert(values.length == rows + 1);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("newMultidimensionalDynamicArrayUsesRuntimeLengthsFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t rows = 1;
                ++rows;
                size_t cols = 2;
                ++cols;

                auto values = new int[][](rows, cols);
                values[1][2] = 42;

                assert(values[1][2] == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("staticArrayCopyFromRuntimeArrayUsesArrayCtor." ~ backend.stringof)
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

    @("staticArrayCopyFromRuntimeArrayUsesArrayCtorFailureMessage.0." ~
        backend.stringof)
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

                assert(copy[0] == seedValue + 1);
            }
        }).shouldThrowWithMessage("40 != 41");
    }

    @("staticArrayCopyFromRuntimeArrayUsesArrayCtorFailureMessage.1." ~
        backend.stringof)
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

                assert(copy[1] == seedValue + 2);
            }
        }).shouldThrowWithMessage("41 != 42");
    }

    @("refDynamicArrayParameterAppend." ~ backend.stringof)
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

    @("refDynamicArrayParameterAppendFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void append(ref ubyte[] values, ubyte value) {
                values ~= value;
            }

            unittest {
                ubyte[] values;
                ubyte value = 42;
                append(values, value);
                assert(values.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("refDynamicArrayParameterAppendFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void append(ref ubyte[] values, ubyte value) {
                values ~= value;
            }

            unittest {
                ubyte[] values;
                ubyte value = 42;
                append(values, value);
                assert(values[0] == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("dynamicArraySliceFromRuntimeBounds." ~ backend.stringof)
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

    @("dynamicArraySliceFromRuntimeBoundsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 1;
                size_t stop = values.length;

                const tail = values[start .. stop];

                assert(tail.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("dynamicArraySliceFromRuntimeBoundsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 0;
                size_t stop = values.length;

                const tail = values[start .. stop];

                assert(tail.length == 1);
            }
        }).shouldThrowWithMessage("2 != 1");
    }

    @("nullDynamicArrayZeroLengthSlice." ~ backend.stringof)
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

    @("nullDynamicArrayZeroLengthSliceFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] values;
                size_t start = values.length;
                size_t stop = start;

                auto slice = values[start .. stop];

                assert(slice.length == 1);
            }
        }).shouldThrowWithMessage("0 != 1");
    }

    @("nullDynamicArrayZeroLengthSliceFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] values;
                size_t start = values.length;
                size_t stop = start + values.length;

                auto slice = values[start .. stop];

                assert(slice.length == 2);
            }
        }).shouldThrowWithMessage("0 != 2");
    }

    @("dynamicArrayLengthAssignmentResizesArray." ~ backend.stringof)
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

    @("dynamicArrayLengthAssignmentResizesArrayFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];

                values.length = 4;

                assert(values.length == 3);
            }
        }).shouldThrowWithMessage("4 != 3");
    }

    @("dynamicArrayLengthAssignmentResizesArrayFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];

                values.length = 4;

                assert(values[1] == first);
            }
        }).shouldThrowWithMessage("11 != 10");
    }

    @("sliceIndexPastLengthDiagnostic." ~ backend.stringof)
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

    @("dynamicArrayIndexPastLengthDiagnostic." ~ backend.stringof)
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

    @("overlappingSliceAssignmentIsRejectedAtCtfe." ~ backend.stringof)
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

    @("sliceAssignmentFromStringUpdatesArray." ~ backend.stringof)
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

    @("sliceAssignmentFromStringUpdatesArrayFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[] text = ['a', 'b', 'c', 'd'];
                size_t start = 1;
                size_t stop = start + 2;

                text[start .. stop] = "xy";

                assert(text.length == 5);
            }
        }).shouldThrowWithMessage("4 != 5");
    }

    @("sliceAssignmentFromStringUpdatesArrayFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[] text = ['a', 'b', 'c', 'd'];
                size_t start = 1;
                size_t stop = start + 2;

                text[start .. stop] = "xy";

                assert(text[2] == 'z');
            }
        }).shouldThrowWithMessage("'y' != 'z'");
    }

    @("pointerArithmeticOverDynamicArray." ~ backend.stringof)
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

    @("pointerArithmeticOverDynamicArrayFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int offset(int value) {
                return value;
            }

            unittest {
                int first = offset(10);
                int[] values = [first, first + 1, first + 2, first + 3];
                int step = offset(2);
                int* p = &values[0];
                int* q = p + step;

                assert(*q == 13);
            }
        }).shouldThrowWithMessage("12 != 13");
    }

    @("pointerArithmeticOverDynamicArrayFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int offset(int value) {
                return value;
            }

            unittest {
                int first = offset(10);
                int[] values = [first, first + 1, first + 2, first + 3];
                int step = offset(2);
                int* p = &values[0];
                int* q = p + step;

                assert(q - p == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("leftIntegralAddsToPointer." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                int* p = values.ptr;
                int* q = 1 + p;

                assert(*q == values[1]);
            }
        });
    }

    @("leftIntegralAddsToPointerFailureMessage." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                int* p = values.ptr;
                int* q = 1 + p;

                assert(*q == values[2]);
            }
        }).shouldThrowWithMessage("11 != 12");
    }

    @("pointerIndexReadsDynamicArray." ~ backend.stringof)
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

    @("pointerIndexReadsDynamicArrayFailureMessage." ~ backend.stringof)
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

                assert(found == values[1]);
            }
        }).shouldThrowWithMessage("12 != 11");
    }

    @("pointerComparisonWithinArray." ~ backend.stringof)
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

    @("pointerComparisonWithinArrayFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                int* p = &values[0];
                int* q = &values[2];

                assert((p < q) == false);
            }
        }).shouldThrowWithMessage("true != false");
    }

    @("pointerComparisonWithinArrayFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                int* p = &values[0];
                int* q = &values[2];

                assert((q == p) == true);
            }
        }).shouldThrowWithMessage("false != true");
    }

    @("fourPointerRelationAcrossArraysReturnsFalse." ~ backend.stringof)
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

                bool inside = lp >= rp && lp + len <= rp + len;

                assert(inside == false);
            }
        });
    }

    @("fourPointerRelationAcrossArraysReturnsFalseFailureMessage." ~
        backend.stringof)
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

                bool inside = lp >= rp && lp + len <= rp + len;

                assert(inside == true);
            }
        }).shouldThrowWithMessage("false != true");
    }

    @("fourPointerRelationAcrossUnrelatedArraysReturnsFalse." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(20);
                int[] left = [first, first + 1];
                int[] right = [first + 2, first + 3];
                size_t offset = cast(size_t) value(1);
                int* leftStart = left.ptr;
                int* rightStart = right.ptr;
                int* rightEnd = rightStart + offset;

                bool inside = rightStart <= leftStart && leftStart < rightEnd;

                assert(inside == false);
            }
        });
    }

    @("fourPointerRelationAcrossUnrelatedArraysReturnsFalseFailureMessage." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(20);
                int[] left = [first, first + 1];
                int[] right = [first + 2, first + 3];
                size_t offset = cast(size_t) value(1);
                int* leftStart = left.ptr;
                int* rightStart = right.ptr;
                int* rightEnd = rightStart + offset;

                bool inside = rightStart <= leftStart && leftStart < rightEnd;

                assert(inside == true);
            }
        }).shouldThrowWithMessage("false != true");
    }

    @("pointerSliceFromDynamicArray." ~ backend.stringof)
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

    @("pointerSliceFromDynamicArrayFailureMessage.0." ~ backend.stringof)
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

                assert(slice.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("pointerSliceFromDynamicArrayFailureMessage.1." ~ backend.stringof)
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

                assert(slice[1] == values[1]);
            }
        }).shouldThrowWithMessage("12 != 11");
    }

    @("pointerSlicePastAllocatedBlockDiagnostic." ~ backend.stringof)
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

    @("multidimensionalStaticArraySliceBlockAssignRepeatsRow." ~
        backend.stringof)
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

    @("multidimensionalStaticArraySliceBlockAssignRepeatsRowFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[2][2] matrix;

                matrix[] = [first, first + 1];

                assert(matrix[1][1] == first);
            }
        }).shouldThrowWithMessage("11 != 10");
    }

    @("multidimensionalStaticArraySliceBlockAssignRepeatsRowFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(7);
                int[2][2] matrix;

                matrix[] = [first, first + 1];

                assert(matrix[1][0] == first + 1);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("dynamicArrayReturnValue." ~ backend.stringof)
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

    @("dynamicArrayReturnValueFailureMessage.0." ~ backend.stringof)
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

                assert(result.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("dynamicArrayReturnValueFailureMessage.1." ~ backend.stringof)
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

                assert(result[1] == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }

    @("dynamicArraySliceReturnValue." ~ backend.stringof)
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

    @("dynamicArraySliceReturnValueFailureMessage.0." ~ backend.stringof)
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

                assert(result.length == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("dynamicArraySliceReturnValueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] tail(ubyte[] values, size_t start, size_t stop) {
                return values[start .. stop];
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 0;
                size_t stop = values.length;

                const result = tail(values, start, stop);

                assert(result.length == 1);
            }
        }).shouldThrowWithMessage("2 != 1");
    }

    @("dynamicArrayReturnValueIndexesCallResult." ~ backend.stringof)
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

    @("dynamicArrayReturnValueIndexesCallResultFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                assert(identity(values)[1] == first);
            }
        }).shouldThrowWithMessage("42 != 10");
    }

    @("dynamicArrayReturnValueIndexesCallResultFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                assert(identity(values)[0] == second);
            }
        }).shouldThrowWithMessage("10 != 42");
    }

    @("postIncrementSizeTIndex." ~ backend.stringof)
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

    @("postIncrementSizeTIndexFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                size_t index = 0;
                assert(values[index++] == 0x2au);
                assert(index == 1);
            }
        }).shouldThrowWithMessage("41 != 42");
    }

    @("postIncrementSizeTIndexFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                size_t index = 0;
                assert(values[index++] == 0x29u);
                assert(index == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("mutableStringLiteralCopiesDoNotShareWrites." ~ backend.stringof)
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

    @("mutableStringLiteralCopiesDoNotShareWritesFailureMessage." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[2] first = "ab";
                first[0] = 'z';
                char[2] second = "ab";

                assert(second[0] == 'z');
            }
        }).shouldThrowWithMessage("'a' != 'z'");
    }
}

static foreach (backend; backendsWith!Interpreter) {
    @("arrayLength." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                assert(arr.length == 3);
            }
        });
    }

    @("arrayLengthFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                assert(arr.length == 4);
            }
        }).shouldThrowWithMessage("3 != 4");
    }

    @("emptyArrayLength." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [];
                assert(arr.length == 0);
            }
        });
    }
}
