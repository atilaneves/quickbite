module ut.backends.pure_.lang.arrays;


import ut.backends;


private:

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

    @("arrayLengthFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1, 2];
                assert(arr.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
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
}
