module ut.executors.pure_.lang.arrays;


import ut.executors;


private:

import std.conv: text;
import unit_threaded;


static foreach (executorName; matureExecutorNames) {
    @("nestedSliceWritesPropagateToOriginalArray." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 4];
                int[] s2 = s[0 .. 2];
                s2[0] = 99;
                assert(a[1] == 99);
            }
        }, executorName);
    }

    @("nestedSliceAppendKeepsOriginalArrayTail." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 3];
                int[] s2 = s[1 .. 2];
                s2 ~= 99;
                assert(a[3] == 3);
            }
        }, executorName);
    }

    @("ubyteArrayAppendAssign." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                auto values = [0x2au];
                values ~= 0x2bu;
                assert(values.length == 2);
            }
        }, executorName);
    }

    @("ubyteArrayIndexRead." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                assert(values[1] == 0x2au);
            }
        }, executorName);
    }

    @("ubyteArrayIndexWrite." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];
                values[1] = 0x2au;
                assert(values[1] == 0x2au);
            }
        }, executorName);
    }

    @("refUbyteArrayParameterAppend." ~ executorName.text)
    unittest {
        runTests(q{
            void appendAnswer(ref ubyte[] values) {
                values ~= 0x2au;
            }

            unittest {
                ubyte[] values = [];
                appendAnswer(values);
                assert(values.length == 1);
                assert(values[0] == 0x2au);
            }
        }, executorName);
    }

    @("arrayLength." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                assert(arr.length == 3);
            }
        }, executorName);
    }

    @("emptyArrayLength." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [];
                assert(arr.length == 0);
            }
        }, executorName);
    }

    @("arrayEqualTrue." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 3];
                assert(a[] == b[]);
            }
        }, executorName);
    }

    static if (executorName != ExecutorName.ir) {
        @("arrayEqualFalse." ~ executorName.text)
        unittest {
            runTests(q{
                unittest {
                    ubyte[] a = [1, 2, 3];
                    ubyte[] b = [1, 2, 4];
                    assert(a[] == b[]);
                }
            }, executorName).shouldThrowWithMessage("[1, 2, 3] != [1, 2, 4]");
        }
    }

    @("ubyteArrayLiteralTruncatesElements." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int value = 258;
                ubyte[] arr = [cast(ubyte) value];
                assert(arr[0] == 2);
            }
        }, executorName);
    }
}

static foreach (
    executorName;
    matureExecutorNames ~ [
        ExecutorName.treeWalking,
        ExecutorName.dmdCodegenRam,
    ]
) {
    @("localDynamicArrayAppend." ~ executorName.text)
    unittest {
        if (executorName != ExecutorName.dmdCodegenRam || experimentalExecutorTestsEnabled) {
            runTests(q{
                unittest {
                    ubyte[] values;
                    ubyte value = 42;
                    values ~= value;
                    assert(values.length == 1);
                    assert(values[0] == value);
                }
            }, executorName);
        }
    }
}

static foreach (executorName; matureExecutorNames ~ [ExecutorName.treeWalking]) {
    @("arrayLiteralElements." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int[] arr = [1, 2];
                assert(arr[0] == 1);
                assert(arr[1] == 2);
            }
        }, executorName);
    }

    @("arrayLiteralVariableElements." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int a = 10;
                int b = 20;
                int[] arr = [a, b];
                assert(arr[0] == 10);
                assert(arr[1] == 20);
            }
        }, executorName);
    }

    @("uninitializedDynamicArrayLength." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values;
                assert(values.length == 0);
            }
        }, executorName);
    }

    @("refDynamicArrayParameterAppend." ~ executorName.text)
    unittest {
        runTests(q{
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
        }, executorName);
    }

    @("dynamicArraySliceFromRuntimeBounds." ~ executorName.text)
    unittest {
        runTests(q{
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
        }, executorName);
    }

    @("dynamicArrayReturnValue." ~ executorName.text)
    unittest {
        runTests(q{
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
        }, executorName);
    }

    @("dynamicArraySliceReturnValue." ~ executorName.text)
    unittest {
        runTests(q{
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
        }, executorName);
    }

    @("dynamicArrayReturnValueIndexesCallResult." ~ executorName.text)
    unittest {
        runTests(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                assert(identity(values)[1] == second);
            }
        }, executorName);
    }

    @("postIncrementSizeTIndex." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                size_t index = 0;
                assert(values[index++] == 0x29u);
                assert(index == 1);
            }
        }, executorName);
    }
}
