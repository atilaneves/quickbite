module ut.backends.lang.control_flow;


import ut.backends;


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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

    @("switchFallsThroughToDefault." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int seed = 7;
                int value;
                switch (seed) {
                    case 1:
                        value = 10;
                        break;
                    case 2:
                        value = 20;
                        break;
                    default:
                        value = seed + 5;
                        break;
                }
                assert(value == 12);
            }
        });
    }
}

static foreach (backend; backends) {

    @("switchFallsThroughToDefaultFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int seed = 7;
                int value;
                switch (seed) {
                    case 1:
                        value = 10;
                        break;
                    case 2:
                        value = 20;
                        break;
                    default:
                        value = seed + 5;
                        break;
                }
                assert(value == 13);
            }
        }).shouldThrowWithMessage("12 != 13");
    }
}

static foreach (backend; backends) {

    @("switchFallsThroughToDefaultFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int seed = 3;
                int value;
                switch (seed) {
                    case 1:
                        value = 10;
                        break;
                    case 2:
                        value = 20;
                        break;
                    default:
                        value = seed + 5;
                        break;
                }
                assert(value == 7);
            }
        }).shouldThrowWithMessage("8 != 7");
    }
}

static foreach (backend; backends) {

    @("supportsGotoCase." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 1;
                int result;
                switch (value) {
                    case 1:
                        result += 10;
                        goto case 2;
                    case 2:
                        result += 20;
                        break;
                    default:
                        result += 30;
                        break;
                }
                assert(result == 30);
            }
        });
    }
}

static foreach (backend; backends) {

    @("supportsGotoCaseFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 1;
                int result;
                switch (value) {
                    case 1:
                        result += 10;
                        goto case 2;
                    case 2:
                        result += 20;
                        break;
                    default:
                        result += 30;
                        break;
                }
                assert(result == 31);
            }
        }).shouldThrowWithMessage("30 != 31");
    }
}

static foreach (backend; backends) {

    @("supportsGotoCaseFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 2;
                int result;
                switch (value) {
                    case 1:
                        result += 10;
                        goto case 2;
                    case 2:
                        result += 20;
                        break;
                    default:
                        result += 30;
                        break;
                }
                assert(result == 30);
            }
        }).shouldThrowWithMessage("20 != 30");
    }
}

static foreach (backend; backends) {

    @("supportsGotoDefault." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 1;
                int result;
                switch (value) {
                    case 1:
                        result += 10;
                        goto default;
                    case 2:
                        result += 20;
                        break;
                    default:
                        result += 30;
                        break;
                }
                assert(result == 40);
            }
        });
    }
}

static foreach (backend; backends) {

    @("supportsGotoDefaultFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 1;
                int result;
                switch (value) {
                    case 1:
                        result += 10;
                        goto default;
                    case 2:
                        result += 20;
                        break;
                    default:
                        result += 30;
                        break;
                }
                assert(result == 41);
            }
        }).shouldThrowWithMessage("40 != 41");
    }
}

static foreach (backend; backends) {

    @("supportsGotoDefaultFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 2;
                int result;
                switch (value) {
                    case 1:
                        result += 10;
                        goto default;
                    case 2:
                        result += 20;
                        break;
                    default:
                        result += 30;
                        break;
                }
                assert(result == 40);
            }
        }).shouldThrowWithMessage("20 != 40");
    }
}

static foreach (backend; backends) {

    @("supportsDirectGotoLabel." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(2);
                goto target;
                total += bump(99);
            target:
                total += bump(4);
                assert(total == 8);
            }
        });
    }
}

static foreach (backend; backends) {

    @("supportsDirectGotoLabelFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(2);
                goto target;
                total += bump(99);
            target:
                total += bump(4);
                assert(total == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }
}

static foreach (backend; backends) {

    @("supportsDirectGotoLabelFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int bump(int value) {
                return value + 1;
            }

            unittest {
                int total = bump(3);
                goto target;
                total += bump(99);
            target:
                total += bump(4);
                assert(total == 8);
            }
        }).shouldThrowWithMessage("9 != 8");
    }
}

static foreach (backend; backends) {

    @("gotoRestartsExpressionStatement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total = seed(1);
                goto target;
                total += seed(99);
            target:
                total += seed(2);
                assert(total == 3);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoRestartsCompoundStatement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total = seed(1);
                goto target;
                total += seed(99);
            target:
                {
                    total += seed(2);
                }
                assert(total == 3);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoRestartsBreakStatement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total;
                for (int i = 0; i < seed(2); ++i) {
                    if (i == 0)
                        goto stop;
                    total += seed(99);
                stop:
                    break;
                }

                assert(total == 0);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoRestartsContinueStatement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total;
                for (int i = 0; i < seed(2); ++i) {
                    if (i == 0)
                        goto skip;
                skip:
                    continue;
                    total += seed(100);
                }

                assert(total == 0);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoCaseUsesRuntimeSelector." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int selector = seed(1);
                int total;

                switch (selector) {
                    case 1:
                        total += seed(10);
                        goto case 2;
                    case 2:
                        total += seed(20);
                        break;
                    default:
                        total += seed(30);
                        break;
                }

                assert(total == 30);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoDefaultUsesRuntimeSelector." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int selector = seed(1);
                int total;

                switch (selector) {
                    case 1:
                        total += seed(10);
                        goto default;
                    case 2:
                        total += seed(20);
                        break;
                    default:
                        total += seed(30);
                        break;
                }

                assert(total == 40);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoRestartsBreakStatementInTryFinally." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total;
                for (int i = 0; i < seed(1); ++i) {
                    try {
                        goto resumed;
                        total += seed(99);
                    resumed:
                        break;
                    } finally {
                        total += seed(1);
                    }
                }

                assert(total == 1);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoRestartsContinueStatementInTryFinally." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total;
                for (int i = 0; i < seed(2); ++i) {
                    try {
                        goto resumed;
                        total += seed(99);
                    resumed:
                        continue;
                    } finally {
                        total += seed(1);
                    }
                }

                assert(total == 2);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoRestartsGotoStatementInTryFinally." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total;
                try {
                    goto resumed;
                    total += seed(99);
                resumed:
                    goto outside;
                } finally {
                    total += seed(1);
                }

            outside:
                total += seed(2);
                assert(total == 3);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoRestartsGotoCaseStatementInTryFinally." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int selector = seed(1);
                int total;
                try {
                    switch (selector) {
                        case 1:
                            total += seed(10);
                            goto resumed;
                        resumed:
                            goto case 2;
                        case 2:
                            total += seed(20);
                            break;
                        default:
                            total += seed(30);
                            break;
                    }
                } finally {
                    total += seed(1);
                }

                assert(total == 31);
            }
        });
    }
}

static foreach (backend; backends) {

    @("gotoRestartsGotoDefaultStatementInTryFinally." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int selector = seed(1);
                int total;
                try {
                    switch (selector) {
                        case 1:
                            total += seed(10);
                            goto resumed;
                        resumed:
                            goto default;
                        case 2:
                            total += seed(20);
                            break;
                        default:
                            total += seed(30);
                            break;
                    }
                } finally {
                    total += seed(1);
                }

                assert(total == 41);
            }
        });
    }
}

static foreach (backend; backends) {

    @("catchHandlerGotoRestartsBreakStatement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total;
                for (int i = 0; i < seed(1); ++i) {
                    try {
                        throw new Exception("expected");
                    } catch (Exception) {
                        goto resumed;
                        total += seed(99);
                    resumed:
                        break;
                    }
                }

                assert(total == 0);
            }
        });
    }
}

static foreach (backend; backends) {

    @("catchHandlerGotoRestartsContinueStatement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total;
                for (int i = 0; i < seed(2); ++i) {
                    try {
                        throw new Exception("expected");
                    } catch (Exception) {
                        goto resumed;
                        total += seed(99);
                    resumed:
                        continue;
                    }
                }

                assert(total == 0);
            }
        });
    }
}

static foreach (backend; backends) {

    @("catchHandlerGotoRestartsGotoStatement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int total;
                try {
                    throw new Exception("expected");
                } catch (Exception) {
                    goto resumed;
                    total += seed(99);
                resumed:
                    goto outside;
                }

            outside:
                total += seed(1);
                assert(total == 1);
            }
        });
    }
}

static foreach (backend; backends) {

    @("supportsDoWhileBreakAndContinue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int i;
                int sum;
                do {
                    ++i;
                    if (i == 2)
                        continue;
                    if (i == 5)
                        break;
                    sum += i;
                } while (i < 6);
                assert(sum == 8);
            }
        });
    }
}

static foreach (backend; backends) {

    @("supportsDoWhileBreakAndContinueFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int i;
                int sum;
                do {
                    ++i;
                    if (i == 2)
                        continue;
                    if (i == 5)
                        break;
                    sum += i;
                } while (i < 6);
                assert(sum == 9);
            }
        }).shouldThrowWithMessage("8 != 9");
    }
}

static foreach (backend; backends) {

    @("supportsDoWhileBreakAndContinueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int i;
                int sum;
                do {
                    ++i;
                    if (i == 3)
                        continue;
                    if (i == 5)
                        break;
                    sum += i;
                } while (i < 6);
                assert(sum == 8);
            }
        }).shouldThrowWithMessage("7 != 8");
    }
}

static foreach (backend; backends) {

    @("labeledContinueSkipsToOuterForIncrement." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int limit(int value) {
                return value;
            }

            unittest {
                int count;
            outer:
                for (int i = 0; i < limit(3); ++i) {
                    for (int j = 0; j < limit(4); ++j) {
                        if (j == i + 1)
                            continue outer;
                        ++count;
                    }
                    count += limit(10);
                }
                assert(count == 6);
            }
        });
    }
}

static foreach (backend; backends) {

    @("labeledContinueSkipsToOuterForIncrementFailureMessage.0." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int limit(int value) {
                return value;
            }

            unittest {
                int count;
            outer:
                for (int i = 0; i < limit(3); ++i) {
                    for (int j = 0; j < limit(4); ++j) {
                        if (j == i + 1)
                            continue outer;
                        ++count;
                    }
                    count += limit(10);
                }
                assert(count == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }
}

static foreach (backend; backends) {

    @("labeledContinueSkipsToOuterForIncrementFailureMessage.1." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int limit(int value) {
                return value;
            }

            unittest {
                int count;
            outer:
                for (int i = 0; i < limit(2); ++i) {
                    for (int j = 0; j < limit(4); ++j) {
                        if (j == i + 1)
                            continue outer;
                        ++count;
                    }
                    count += limit(10);
                }
                assert(count == 6);
            }
        }).shouldThrowWithMessage("3 != 6");
    }
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

    @("voidFunction." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {}

            unittest {
                foo;
            }
        });
    }
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

    @("foreachExpressionTupleBreakAndContinue." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.meta: AliasSeq;

            int helper(int value) {
                return value + 1;
            }

            unittest {
                int first = helper(1);
                int second = helper(3);
                int third = helper(5);
                int sum;
                foreach (value; AliasSeq!(first, second, third)) {
                    if (value == second)
                        continue;
                    if (value == third)
                        break;
                    sum += value;
                }
                assert(sum == 2);
            }
        });
    }
}

static foreach (backend; backends) {

    @("foreachExpressionTupleBreakAndContinueFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.meta: AliasSeq;

            int helper(int value) {
                return value + 1;
            }

            unittest {
                int first = helper(1);
                int second = helper(3);
                int third = helper(5);
                int sum;
                foreach (value; AliasSeq!(first, second, third)) {
                    if (value == second)
                        continue;
                    if (value == third)
                        break;
                    sum += value;
                }
                assert(sum == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }
}

static foreach (backend; backends) {

    @("foreachExpressionTupleBreakAndContinueFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import std.meta: AliasSeq;

            int helper(int value) {
                return value + 1;
            }

            unittest {
                int first = helper(2);
                int second = helper(3);
                int third = helper(5);
                int sum;
                foreach (value; AliasSeq!(first, second, third)) {
                    if (value == second)
                        continue;
                    if (value == third)
                        break;
                    sum += value;
                }
                assert(sum == 2);
            }
        }).shouldThrowWithMessage("3 != 2");
    }
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

    @("foreachUtf8String." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[] bytes;
                bytes ~= 'a';
                bytes ~= cast(char) 0xC3;
                bytes ~= cast(char) 0xA9;

                string s = bytes.idup;
                dchar[] chars;
                foreach (dchar c; s)
                    chars ~= c;

                assert(chars.length == 2);
                assert(chars[0] == 'a');
                assert(chars[1] == '\u00e9');
            }
        });
    }
}

static foreach (backend; backends) {

    @("foreachUtf16String." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                wchar[] units;
                units ~= cast(wchar) 0x0061;
                units ~= cast(wchar) 0xD83C;
                units ~= cast(wchar) 0xDF4C;

                wstring s = units.idup;
                dchar[] chars;
                foreach (dchar c; s)
                    chars ~= c;

                assert(chars.length == 2);
                assert(chars[0] == 'a');
                assert(chars[1] == cast(dchar) 0x1F34C);
            }
        });
    }
}

static foreach (backend; backends) {

    @("foreachUtf32StringEncodesAsUtf8." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                dchar[] codepoints;
                codepoints ~= cast(dchar) 0x0061;
                codepoints ~= cast(dchar) 0x00E9;

                dstring s = codepoints.idup;
                char[] bytes;
                foreach (char c; s)
                    bytes ~= c;

                assert(bytes.length == 3);
                assert(bytes[0] == 'a');
                assert(bytes[1] == cast(char) 0xC3);
                assert(bytes[2] == cast(char) 0xA9);
            }
        });
    }
}

static foreach (backend; backends) {

    @("foreachReverseUtf16String." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                wchar[] units;
                units ~= cast(wchar) 0xD83C;
                units ~= cast(wchar) 0xDF4C;
                units ~= cast(wchar) 0x007A;

                wstring s = units.idup;
                dchar[] chars;
                foreach_reverse (dchar c; s)
                    chars ~= c;

                assert(chars.length == 2);
                assert(chars[0] == 'z');
                assert(chars[1] == cast(dchar) 0x1F34C);
            }
        });
    }
}

static foreach (backend; backends) {

    @("foreachUtf8StringFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[] bytes;
                bytes ~= 'a';
                bytes ~= cast(char) 0xC3;
                bytes ~= cast(char) 0xA9;

                string s = bytes.idup;
                dchar[] chars;
                foreach (dchar c; s)
                    chars ~= c;

                assert(chars.length == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }
}

static foreach (backend; backends) {

    @("foreachUtf8StringFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[] bytes;
                bytes ~= 'a';
                bytes ~= cast(char) 0xC3;
                bytes ~= cast(char) 0xA9;

                string s = bytes.idup;
                dchar[] chars;
                foreach (dchar c; s)
                    chars ~= c;

                assert(chars[0] == 'b');
            }
        }).shouldThrowWithMessage("'a' != 'b'");
    }
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

    @("labeledBreakExitsOuterForLoop." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int outerLimit = 1;
                ++outerLimit;
                int innerLimit = 2;
                ++innerLimit;
                int count;

            outer:
                for (int i = 0; i < outerLimit; ++i) {
                    for (int j = 0; j < innerLimit; ++j) {
                        ++count;
                        if (i == 0 && j == 1)
                            break outer;
                    }
                }

                assert(count == 2);
            }
        });
    }
}

static foreach (backend; backends) {

    @("labeledBreakExitsOuterForLoopFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int outerLimit = 1;
                ++outerLimit;
                int innerLimit = 2;
                ++innerLimit;
                int count;

            outer:
                for (int i = 0; i < outerLimit; ++i) {
                    for (int j = 0; j < innerLimit; ++j) {
                        ++count;
                        if (i == 0 && j == 1)
                            break outer;
                    }
                }

                assert(count == 3);
            }
        }).shouldThrowWithMessage("2 != 3");
    }
}

static foreach (backend; backends) {

    @("labeledBreakExitsOuterForLoopFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int outerLimit = 1;
                ++outerLimit;
                int innerLimit = 1;
                ++innerLimit;
                int count;

            outer:
                for (int i = 0; i < outerLimit; ++i) {
                    for (int j = 0; j < innerLimit; ++j) {
                        ++count;
                        if (i == 0 && j == 0)
                            break outer;
                    }
                }

                assert(count == 2);
            }
        }).shouldThrowWithMessage("1 != 2");
    }
}

static foreach (backend; backends) {

    @("switchBreaksOuterLoop." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int limit(int value) {
                return value;
            }

            unittest {
                int total;

            outer:
                for (int i = 0; i < limit(3); ++i) {
                    total += limit(1);
                    switch (i) {
                        case 1:
                            total += limit(10);
                            break outer;
                        default:
                            total += limit(2);
                            break;
                    }
                }

                assert(total == 14);
            }
        });
    }
}

static foreach (backend; backends) {

    @("switchBreaksOuterLoopFailureMessage.0." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int limit(int value) {
                return value;
            }

            unittest {
                int total;

            outer:
                for (int i = 0; i < limit(3); ++i) {
                    total += limit(1);
                    switch (i) {
                        case 1:
                            total += limit(10);
                            break outer;
                        default:
                            total += limit(2);
                            break;
                    }
                }

                assert(total == 15);
            }
        }).shouldThrowWithMessage("14 != 15");
    }
}

static foreach (backend; backends) {

    @("switchBreaksOuterLoopFailureMessage.1." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int limit(int value) {
                return value;
            }

            unittest {
                int total;

            outer:
                for (int i = 0; i < limit(2); ++i) {
                    total += limit(1);
                    switch (i) {
                        case 0:
                            total += limit(10);
                            break outer;
                        default:
                            total += limit(2);
                            break;
                    }
                }

                assert(total == 14);
            }
        }).shouldThrowWithMessage("11 != 14");
    }
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
}

static foreach (backend; backends) {

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
