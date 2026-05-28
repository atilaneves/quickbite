module ut.backends.pure_.lang.control_flow;


import ut.backends;


private:

static foreach (backend; backends) {
    @("supportsContinue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int sum;
                for (int i = 0; i < 4; ++i) {
                    if (i == 2)
                        continue;
                    sum += i;
                }
                assert(sum == 4);
            }
        });
    }

    @("supportsContinueFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int sum;
                for (int i = 0; i < 4; ++i) {
                    if (i == 2)
                        continue;
                    sum += i;
                }
                assert(sum == 5);
            }
        }).shouldThrowWithMessage("4 != 5");
    }

    @("supportsContinueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int sum;
                for (int i = 0; i < 3; ++i) {
                    if (i == 1)
                        continue;
                    sum += i;
                }
                assert(sum == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("supportsSwitch." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("supportsSwitchFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(result == 21);
            }
        }).shouldThrowWithMessage("20 != 21");
    }

    @("supportsSwitchFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 3;
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
                assert(result == 31);
            }
        }).shouldThrowWithMessage("30 != 31");
    }

    @("functionPointerHashCollisionDetected." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("functionPointerHashCollisionDetectedFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                // bAB and a_a produce the same Bernstein hash (602706).
                static int bAB() {
                    return 1;
                }

                static int a_a() {
                    return 2;
                }

                int function() fp = &a_a;
                assert(fp() == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("functionPointerHashCollisionDetectedFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                // bAB and a_a produce the same Bernstein hash (602706).
                static int bAB() {
                    return 1;
                }

                static int a_a() {
                    return 2;
                }

                int function() fp = &bAB;
                assert(fp() == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("functionPointerDispatchesToDistinctCallees." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("functionPointerDispatchesToDistinctCalleesFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bAB() {
                return 11;
            }

            int a_a() {
                return 22;
            }

            unittest {
                int function() first = &bAB;
                int function() second = &a_a;
                assert(first() == 12);
                assert(second() == 22);
            }
        }).shouldThrowWithMessage("11 != 12");
    }

    @("functionPointerDispatchesToDistinctCalleesFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(second() == 23);
            }
        }).shouldThrowWithMessage("22 != 23");
    }

    @("functionPointerCallCanEnterFunctionWithCallee." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int helper() {
                return 7;
            }

            int first() {
                return helper + 10;
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
        });
    }

    @("functionPointerCallCanEnterFunctionWithCalleeFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int helper() {
                return 7;
            }

            int first() {
                return helper + 10;
            }

            int second() {
                return 13;
            }

            unittest {
                int function() fp1 = &first;
                int function() fp2 = &second;
                assert(fp1() == 18);
                assert(fp2() == 13);
            }
        }).shouldThrowWithMessage("17 != 18");
    }

    @("functionPointerCallCanEnterFunctionWithCalleeFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int helper() {
                return 8;
            }

            int first() {
                return helper + 10;
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
        }).shouldThrowWithMessage("18 != 17");
    }

    @("localIntReturn." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 42);
            }
        });
    }

    @("localIntReturnFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                int value = 42;
                return value;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("localIntReturnFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                int value = 7;
                return value;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("voidFunction." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {}

            unittest {
                foo;
            }
        });
    }

    @("voidFunctionFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {
                assert(false);
            }

            unittest {
                foo;
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }

    @("voidFunctionFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {}

            unittest {
                foo;
                assert(false);
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }

    @("foreachArray." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                int sum = 0;
                foreach (x; arr)
                    sum = sum + x;
                assert(sum == 6);
            }
        });
    }

    @("foreachArrayFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1, 2, 3];
                int sum = 0;
                foreach (x; arr)
                    sum = sum + x;
                assert(sum == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }

    @("foreachArrayFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [1, 2, 4];
                int sum = 0;
                foreach (x; arr)
                    sum = sum + x;
                assert(sum == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("foreachEmptyArray." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [];
                int count = 0;
                foreach (x; arr)
                    count = count + 1;
                assert(count == 0);
            }
        });
    }

    @("foreachEmptyArrayFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [];
                int count = 0;
                foreach (x; arr)
                    count = count + 1;
                assert(count == 1);
            }
        }).shouldThrowWithMessage("0 != 1");
    }

    @("foreachEmptyArrayFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] arr = [7];
                int count = 0;
                foreach (x; arr)
                    count = count + 1;
                assert(count == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }

    @("whileNeverRuns." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("whileNeverRunsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                int i = 0;
                while (i > 0) {
                    i = i + 1;
                }
                return 42;
            }

            unittest {
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("whileNeverRunsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                int i = 0;
                while (i > 0) {
                    i = i + 1;
                }
                return 7;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("whileRunsOnce." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("whileRunsOnceFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("whileRunsOnceFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                int i = 0;
                int result = 0;
                while (i < 1) {
                    result = 7;
                    i = i + 1;
                }
                return result;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("while_." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("whileFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(answer == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("whileFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer() {
                int i = 0;
                int result = 0;
                while (i < 1) {
                    result = result + 7;
                    i = i + 1;
                }
                return result;
            }

            unittest {
                assert(answer == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("voidFunctionExplicitReturn." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {
                return;
            }

            unittest {
                foo;
            }
        });
    }

    @("voidFunctionExplicitReturnFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {
                assert(false);
                return;
            }

            unittest {
                foo;
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }

    @("voidFunctionExplicitReturnFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {
                return;
                assert(false);
            }

            unittest {
                foo;
                assert(false);
            }
        }).shouldThrowWithMessage("`assert(false)` failed");
    }

    @("functionParameter." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 42);
            }
        });
    }

    @("functionParameterFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(41) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("functionParameterFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                return value + 1;
            }

            unittest {
                assert(answer(6) == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("functionParameters." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 2) == 42);
            }
        });
    }

    @("functionParametersFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(40, 2) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("functionParametersFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int left, int right) {
                return left + right;
            }

            unittest {
                assert(answer(5, 2) == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("refParameter." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 41;
                addOne(value);
                assert(value == 42);
            }
        });
    }

    @("refParameterFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 41;
                addOne(value);
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("refParameterFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void addOne(ref int value) {
                value = value + 1;
            }

            unittest {
                int value = 6;
                addOne(value);
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("ifBodyAssignment." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    value = 2;

                return value;
            }

            unittest {
                assert(answer(1) == 2);
            }
        });
    }

    @("ifBodyAssignmentFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    value = 2;

                return value;
            }

            unittest {
                assert(answer(1) == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }

    @("ifBodyAssignmentFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    value = 2;

                return value;
            }

            unittest {
                assert(answer(3) == 4);
            }
        }).shouldThrowWithMessage("3 != 4");
    }

    @("ifElse." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("ifElseFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    return 42;
                else
                    return 43;
            }

            unittest {
                assert(answer(1) == 43);
                assert(answer(2) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("ifElseFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    return 42;
                else
                    return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 44);
            }
        }).shouldThrowWithMessage("43 != 44");
    }

    @("ifElseUntakenBranch." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("ifElseUntakenBranchFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(answer(true) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("ifElseUntakenBranchFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int zero() {
                return 0;
            }

            int answer(bool left) {
                if (left)
                    return 7;
                else
                    return 42 / zero;
            }

            unittest {
                assert(answer(true) == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("earlyReturn." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 43);
            }
        });
    }

    @("earlyReturnFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 43);
                assert(answer(2) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("earlyReturnFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 44);
            }
        }).shouldThrowWithMessage("43 != 44");
    }

    @("multipleEarlyReturns." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("multipleEarlyReturnsFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    return 41;

                if (value == 2)
                    return 42;

                return 43;
            }

            unittest {
                assert(answer(1) == 42);
                assert(answer(2) == 42);
                assert(answer(3) == 43);
            }
        }).shouldThrowWithMessage("41 != 42");
    }

    @("multipleEarlyReturnsFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
                assert(answer(3) == 44);
            }
        }).shouldThrowWithMessage("43 != 44");
    }

    @("inFunctionParameters." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void check(in int left, in int right) {
                assert(left + right == 42);
            }

            unittest {
                check(40, 2);
            }
        });
    }

    @("inFunctionParametersFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void check(in int left, in int right) {
                assert(left + right == 43);
            }

            unittest {
                check(40, 2);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("inFunctionParametersFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void check(in int left, in int right) {
                assert(left + right == 8);
            }

            unittest {
                check(5, 2);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("multipleRefParameters." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void add(int left, ref int right) {
                right = left + right;
            }

            unittest {
                int value = 2;
                add(40, value);
                assert(value == 42);
            }
        });
    }

    @("multipleRefParametersFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void add(int left, ref int right) {
                right = left + right;
            }

            unittest {
                int value = 2;
                add(40, value);
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("multipleRefParametersFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void add(int left, ref int right) {
                right = left + right;
            }

            unittest {
                int value = 2;
                add(5, value);
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("refSizeTParameter." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 41;
                advance(pos);
                assert(pos == 42);
            }
        });
    }

    @("refSizeTParameterFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 41;
                advance(pos);
                assert(pos == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("refSizeTParameterFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void advance(ref size_t pos) {
                pos = pos + 1;
            }

            unittest {
                size_t pos = 6;
                advance(pos);
                assert(pos == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("localIntReturnDmdCodegenShape." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value() {
                int ret = 42;
                return ret;
            }

            unittest {
                assert(value == 42);
            }
        });
    }

    @("localIntReturnDmdCodegenShapeFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value() {
                int ret = 42;
                return ret;
            }

            unittest {
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("localIntReturnDmdCodegenShapeFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value() {
                int ret = 7;
                return ret;
            }

            unittest {
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("functionParameterDmdCodegenShape." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int identity(int value) {
                return value;
            }

            unittest {
                assert(identity(42) == 42);
            }
        });
    }

    @("functionParameterDmdCodegenShapeFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int identity(int value) {
                return value;
            }

            unittest {
                assert(identity(42) == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("functionParameterDmdCodegenShapeFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int identity(int value) {
                return value;
            }

            unittest {
                assert(identity(7) == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("ifElseDmdCodegenShape." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }

    @("ifElseDmdCodegenShapeFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int input() {
                return 1;
            }

            unittest {
                int value;
                if (input == 1)
                    value = 42;
                else
                    value = 7;
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("ifElseDmdCodegenShapeFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int input() {
                return 2;
            }

            unittest {
                int value;
                if (input == 1)
                    value = 42;
                else
                    value = 7;
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("whileDmdCodegenShape." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                while (value < 42)
                    value += 7;
                assert(value == 42);
            }
        });
    }

    @("whileDmdCodegenShapeFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                while (value < 42)
                    value += 7;
                assert(value == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("whileDmdCodegenShapeFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value;
                while (value < 7)
                    value += 7;
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("foreachRange." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int sum;
                foreach (i; 0 .. 3)
                    sum += i;
                assert(sum == 3);
            }
        });
    }

    @("foreachRangeFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int sum;
                foreach (i; 0 .. 3)
                    sum += i;
                assert(sum == 4);
            }
        }).shouldThrowWithMessage("3 != 4");
    }

    @("foreachRangeFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int sum;
                foreach (i; 0 .. 4)
                    sum += i;
                assert(sum == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }

    @("freeFunctionCallWithReturn." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int add(int a, int b) {
                return a + b;
            }

            unittest {
                int result = add(1, 2);
                assert(result == 3);
            }
        });
    }

    @("freeFunctionCallWithReturnFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int add(int a, int b) {
                return a + b;
            }

            unittest {
                int result = add(1, 2);
                assert(result == 4);
            }
        }).shouldThrowWithMessage("3 != 4");
    }

    @("freeFunctionCallWithReturnFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int add(int a, int b) {
                return a + b;
            }

            unittest {
                int result = add(3, 3);
                assert(result == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }

    @("freeFunctionCallWithReturnDifferentValues." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int sub(int a, int b) {
                return a - b;
            }

            unittest {
                int result = sub(10, 3);
                assert(result == 7);
            }
        });
    }

    @("freeFunctionCallWithReturnDifferentValuesFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int sub(int a, int b) {
                return a - b;
            }

            unittest {
                int result = sub(10, 3);
                assert(result == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("freeFunctionCallWithReturnDifferentValuesFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int sub(int a, int b) {
                return a - b;
            }

            unittest {
                int result = sub(10, 4);
                assert(result == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }

    @("freeFunctionCallWithArrayParam." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int firstElement(int[] arr) {
                return arr[0];
            }

            unittest {
                int[] arr = [42];
                int result = firstElement(arr);
                assert(result == 42);
            }
        });
    }

    @("freeFunctionCallWithArrayParamFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int firstElement(int[] arr) {
                return arr[0];
            }

            unittest {
                int[] arr = [42];
                int result = firstElement(arr);
                assert(result == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }

    @("freeFunctionCallWithArrayParamFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int firstElement(int[] arr) {
                return arr[0];
            }

            unittest {
                int[] arr = [7];
                int result = firstElement(arr);
                assert(result == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("freeFunctionCallWithArrayParamSecondElement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int secondElement(int[] arr) {
                return arr[1];
            }

            unittest {
                int[] arr = [10, 20];
                int result = secondElement(arr);
                assert(result == 20);
            }
        });
    }

    @("freeFunctionCallWithArrayParamSecondElementFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int secondElement(int[] arr) {
                return arr[1];
            }

            unittest {
                int[] arr = [10, 20];
                int result = secondElement(arr);
                assert(result == 21);
            }
        }).shouldThrowWithMessage("20 != 21");
    }

    @("freeFunctionCallWithArrayParamSecondElementFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int secondElement(int[] arr) {
                return arr[1];
            }

            unittest {
                int[] arr = [10, 7];
                int result = secondElement(arr);
                assert(result == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("refParamWriteback." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 5;
                increment(value);
                assert(value == 6);
            }
        });
    }

    @("refParamWritebackFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 5;
                increment(value);
                assert(value == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }

    @("refParamWritebackFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 6;
                increment(value);
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("refParamWritebackDifferentValue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 10;
                increment(value);
                assert(value == 11);
            }
        });
    }

    @("refParamWritebackDifferentValueFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 10;
                increment(value);
                assert(value == 12);
            }
        }).shouldThrowWithMessage("11 != 12");
    }

    @("refParamWritebackDifferentValueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void increment(ref int x) {
                x += 1;
            }

            unittest {
                int value = 6;
                increment(value);
                assert(value == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }

    @("structMethodReturnDoesNotSkipCallerStatements." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        }).shouldThrowWithMessage("`assert(false)` failed");
    }
}
