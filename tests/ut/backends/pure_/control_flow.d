module ut.backends.pure_.control_flow;


import ut.backends;


private:

import std.conv: text;
import ut.backends:
    dmdCodegenRamExecutorBackends,
    experimentalBackendTestsEnabled,
    matureExecutorBackends;
import unit_threaded;


static foreach (backend; matureExecutorBackends) {
    @("supportsContinue." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int sum;
                for (int i = 0; i < 4; ++i) {
                    if (i == 2)
                        continue;
                    sum += i;
                }
                assert(sum == 4);
            }
        }, backend);
    }

    @("supportsSwitch." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int value = 2;
                int result;
                switch (value) {
                    case 1:
                        result = 10;
                        break;
                    case 2:
                        result = 20;
                        break;
                    default:
                        result = 30;
                        break;
                }
                assert(result == 20);
            }
        }, backend);
    }

    @("functionPointerHashCollisionDetected." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                // bAB and a_a produce the same Bernstein hash (602706).
                static int bAB() {
                    return 1;
                }

                static int a_a() {
                    return 2;
                }

                int function() fp = &a_a;
                assert(fp() == 2);
            }
        }, backend);
    }

    @("functionPointerDispatchesToDistinctCallees." ~ backend.text)
    unittest {
        runTests(q{
            int bAB() {
                return 11;
            }

            int a_a() {
                return 22;
            }

            unittest {
                int function() first = &bAB;
                int function() second = &a_a;
                assert(first() == 11);
                assert(second() == 22);
            }
        }, backend);
    }

    @("functionPointerCallCanEnterFunctionWithCallee." ~ backend.text)
    unittest {
        runTests(q{
            int helper() {
                return 7;
            }

            int first() {
                return helper() + 10;
            }

            int second() {
                return 13;
            }

            unittest {
                int function() fp1 = &first;
                int function() fp2 = &second;
                assert(fp1() == 17);
                assert(fp2() == 13);
            }
        }, backend);
    }

    @("localIntReturn." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("voidFunction." ~ backend.text)
    unittest {
        runTests(q{
            void foo() {}

            unittest {
                foo;
            }
        }, backend);
    }

    @("foreachArray." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                int sum = 0;
                foreach (x; arr)
                    sum = sum + x;
                assert(sum == 6);
            }
        }, backend);
    }

    @("foreachEmptyArray." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [];
                int count = 0;
                foreach (x; arr)
                    count = count + 1;
                assert(count == 0);
            }
        }, backend);
    }

    @("whileNeverRuns." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                while (i > 0) {
                    i = i + 1;
                }
                return 42;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("whileRunsOnce." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                int result = 0;
                while (i < 1) {
                    result = 42;
                    i = i + 1;
                }
                return result;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("while_." ~ backend.text)
    unittest {
        runTests(q{
            int answer() {
                int i = 0;
                int result = 0;
                while (i < 6) {
                    result = result + 7;
                    i = i + 1;
                }
                return result;
            }

            unittest {
                assert(answer == 42);
            }
        }, backend);
    }

    @("voidFunctionExplicitReturn." ~ backend.text)
    unittest {
        runTests(q{
            void foo() {
                return;
            }

            unittest {
                foo;
            }
        }, backend);
    }

    @("functionParameter." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 42);
            }
        }, backend);
    }

    @("functionParameters." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 2) == 42);
            }
        }, backend);
    }

    @("refParameter." ~ backend.text)
    unittest {
        runTests(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 41;
                addOne(value);
                assert(value == 42);
            }
        }, backend);
    }

    @("ifBodyAssignment." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    value = 2;

                return value;
            }

            unittest {
                assert(answer(1) == 2);
            }
        }, backend);
    }

    @("ifElse." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 42;
                else
                    return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 43);
            }
        }, backend);
    }

    @("ifElseUntakenBranch." ~ backend.text)
    unittest {
        runTests(q{
            int zero() {
                return 0;
            }

            int answer(bool left) {
                if (left)
                    return 42;
                else
                    return 42 / zero;
            }

            unittest {
                assert(answer(true) == 42);
            }
        }, backend);
    }

    @("earlyReturn." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 43);
            }
        }, backend);
    }

    @("multipleEarlyReturns." ~ backend.text)
    unittest {
        runTests(q{
            int answer(int value) {
                if (value == 1)
                    return 41;

                if (value == 2)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 41);
                assert(answer(2) == 42);
                assert(answer(3) == 43);
            }
        }, backend);
    }

    @("inFunctionParameters." ~ backend.text)
    unittest {
        runTests(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 2);
            }
        }, backend);
    }

    @("multipleRefParameters." ~ backend.text)
    unittest {
        runTests(q{
            void add(int left, ref int right) {
                right = left + right;
            }

            unittest {
                int value = 2;
                add(40, value);
                assert(value == 42);
            }
        }, backend);
    }

    @("refSizeTParameter." ~ backend.text)
    unittest {
        runTests(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 41;
                advance(pos);
                assert(pos == 42);
            }
        }, backend);
    }

}

static foreach (backend; dmdCodegenRamExecutorBackends) {
    @(text("localIntReturn.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int value() {
                    int ret = 42;
                    return ret;
                }

                unittest {
                    assert(value == 42);
                }
            }, backend);
        }
    }

    @(text("functionParameter.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int identity(int value) {
                    return value;
                }

                unittest {
                    assert(identity(42) == 42);
                }
            }, backend);
        }
    }

    @(text("ifElse.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                int input() {
                    return 1;
                }

                unittest {
                    int value;
                    if (input == 1)
                        value = 42;
                    else
                        value = 7;
                    assert(value == 42);
                }
            }, backend);
        }
    }

    @(text("while_.", backend))
    unittest {
        if (experimentalBackendTestsEnabled) {
            runTests(q{
                unittest {
                    int value;
                    while (value < 42)
                        value += 7;
                    assert(value == 42);
                }
            }, backend);
        }
    }
}

static foreach (backend; matureExecutorBackends ~ [ExecutorBackend.treeWalking]) {
    @("foreachRange." ~ backend.text)
    unittest {
        runTests(q{
            unittest {
                int sum;
                foreach (i; 0 .. 3)
                    sum += i;
                assert(sum == 3);
            }
        }, backend);
    }

    @("freeFunctionCallWithReturn." ~ backend.text)
    unittest {
        runTests(q{
            int add(int a, int b) {
                return a + b;
            }

            unittest {
                int result = add(1, 2);
                assert(result == 3);
            }
        }, backend);
    }

    @("freeFunctionCallWithReturnDifferentValues." ~ backend.text)
    unittest {
        runTests(q{
            int sub(int a, int b) {
                return a - b;
            }

            unittest {
                int result = sub(10, 3);
                assert(result == 7);
            }
        }, backend);
    }

    @("freeFunctionCallWithArrayParam." ~ backend.text)
    unittest {
        runTests(q{
            int firstElement(int[] arr) {
                return arr[0];
            }

            unittest {
                int[] arr = [42];
                int result = firstElement(arr);
                assert(result == 42);
            }
        }, backend);
    }

    @("freeFunctionCallWithArrayParamSecondElement." ~ backend.text)
    unittest {
        runTests(q{
            int secondElement(int[] arr) {
                return arr[1];
            }

            unittest {
                int[] arr = [10, 20];
                int result = secondElement(arr);
                assert(result == 20);
            }
        }, backend);
    }

    @("refParamWriteback." ~ backend.text)
    unittest {
        runTests(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 5;
                increment(value);
                assert(value == 6);
            }
        }, backend);
    }

    @("refParamWritebackDifferentValue." ~ backend.text)
    unittest {
        runTests(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 10;
                increment(value);
                assert(value == 11);
            }
        }, backend);
    }
}

static foreach (backend; [
    ExecutorBackend.treeWalking,
    ExecutorBackend.dmdCtfe,
]) {
    @("structMethodReturnDoesNotSkipCallerStatements." ~ backend.text)
    unittest {
        static if (backend == ExecutorBackend.dmdCtfe)
            enum expected = "unittest failure";
        else
            enum expected = "Unittest assertion failed.";

        runTests(q{
            struct Worker {
                void stop() {
                    return;
                }
            }

            unittest {
                Worker worker;
                worker.stop;
                assert(false);
            }
        }, backend).shouldThrowWithMessage(expected);
    }
}
