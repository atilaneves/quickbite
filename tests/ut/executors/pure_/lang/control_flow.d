module ut.executors.pure_.lang.control_flow;


import ut.executors;


private:

import std.conv: text;
import ut.executors:
    dmdCodegenRamExecutorNames,
    experimentalExecutorTestsEnabled,
    matureExecutorNames;
import unit_threaded;


static foreach (executorName; matureExecutorNames) {
    @("supportsContinue." ~ executorName.text)
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
        }, executorName);
    }

    @("supportsSwitch." ~ executorName.text)
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
        }, executorName);
    }

    @("functionPointerHashCollisionDetected." ~ executorName.text)
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
        }, executorName);
    }

    @("functionPointerDispatchesToDistinctCallees." ~ executorName.text)
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
        }, executorName);
    }

    @("functionPointerCallCanEnterFunctionWithCallee." ~ executorName.text)
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
        }, executorName);
    }

    @("localIntReturn." ~ executorName.text)
    unittest {
        runTests(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 42);
            }
        }, executorName);
    }

    @("voidFunction." ~ executorName.text)
    unittest {
        runTests(q{
            void foo() {}

            unittest {
                foo;
            }
        }, executorName);
    }

    @("foreachArray." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                int sum = 0;
                foreach (x; arr)
                    sum = sum + x;
                assert(sum == 6);
            }
        }, executorName);
    }

    @("foreachEmptyArray." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                ubyte[] arr = [];
                int count = 0;
                foreach (x; arr)
                    count = count + 1;
                assert(count == 0);
            }
        }, executorName);
    }

    @("whileNeverRuns." ~ executorName.text)
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
        }, executorName);
    }

    @("whileRunsOnce." ~ executorName.text)
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
        }, executorName);
    }

    @("while_." ~ executorName.text)
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
        }, executorName);
    }

    @("voidFunctionExplicitReturn." ~ executorName.text)
    unittest {
        runTests(q{
            void foo() {
                return;
            }

            unittest {
                foo;
            }
        }, executorName);
    }

    @("functionParameter." ~ executorName.text)
    unittest {
        runTests(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 42);
            }
        }, executorName);
    }

    @("functionParameters." ~ executorName.text)
    unittest {
        runTests(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 2) == 42);
            }
        }, executorName);
    }

    @("refParameter." ~ executorName.text)
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
        }, executorName);
    }

    @("ifBodyAssignment." ~ executorName.text)
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
        }, executorName);
    }

    @("ifElse." ~ executorName.text)
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
        }, executorName);
    }

    @("ifElseUntakenBranch." ~ executorName.text)
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
        }, executorName);
    }

    @("earlyReturn." ~ executorName.text)
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
        }, executorName);
    }

    @("multipleEarlyReturns." ~ executorName.text)
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
        }, executorName);
    }

    @("inFunctionParameters." ~ executorName.text)
    unittest {
        runTests(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 2);
            }
        }, executorName);
    }

    @("multipleRefParameters." ~ executorName.text)
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
        }, executorName);
    }

    @("refSizeTParameter." ~ executorName.text)
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
        }, executorName);
    }

}

static foreach (executorName; dmdCodegenRamExecutorNames) {
    @(text("localIntReturn.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int value() {
                    int ret = 42;
                    return ret;
                }

                unittest {
                    assert(value == 42);
                }
            }, executorName);
        }
    }

    @(text("functionParameter.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                int identity(int value) {
                    return value;
                }

                unittest {
                    assert(identity(42) == 42);
                }
            }, executorName);
        }
    }

    @(text("ifElse.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
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
            }, executorName);
        }
    }

    @(text("while_.", executorName))
    unittest {
        if (experimentalExecutorTestsEnabled) {
            runTests(q{
                unittest {
                    int value;
                    while (value < 42)
                        value += 7;
                    assert(value == 42);
                }
            }, executorName);
        }
    }
}

static foreach (executorName; matureExecutorNames ~ [ExecutorName.treeWalking]) {
    @("foreachRange." ~ executorName.text)
    unittest {
        runTests(q{
            unittest {
                int sum;
                foreach (i; 0 .. 3)
                    sum += i;
                assert(sum == 3);
            }
        }, executorName);
    }

    @("freeFunctionCallWithReturn." ~ executorName.text)
    unittest {
        runTests(q{
            int add(int a, int b) {
                return a + b;
            }

            unittest {
                int result = add(1, 2);
                assert(result == 3);
            }
        }, executorName);
    }

    @("freeFunctionCallWithReturnDifferentValues." ~ executorName.text)
    unittest {
        runTests(q{
            int sub(int a, int b) {
                return a - b;
            }

            unittest {
                int result = sub(10, 3);
                assert(result == 7);
            }
        }, executorName);
    }

    @("freeFunctionCallWithArrayParam." ~ executorName.text)
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
        }, executorName);
    }

    @("freeFunctionCallWithArrayParamSecondElement." ~ executorName.text)
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
        }, executorName);
    }

    @("refParamWriteback." ~ executorName.text)
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
        }, executorName);
    }

    @("refParamWritebackDifferentValue." ~ executorName.text)
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
        }, executorName);
    }
}

static foreach (executorName; [
    ExecutorName.treeWalking,
    ExecutorName.dmdCtfe,
]) {
    @("structMethodReturnDoesNotSkipCallerStatements." ~ executorName.text)
    unittest {
        static if (executorName == ExecutorName.dmdCtfe)
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
        }, executorName).shouldThrowWithMessage(expected);
    }
}
