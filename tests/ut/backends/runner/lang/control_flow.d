module ut.backends.runner.lang.control_flow;


import ut.backends;


/++
    Basic functions, parameters, and returns.
+/
static foreach (backend; Matrix!()) {
    @("function.localIntReturn." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("function.parameter." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("function.parameters." ~ backend.stringof)
    @Tags(backend.stringof)
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

// DMD lowers a synchronized statement to balanced
// `_d_monitorenter`/`_d_monitorexit` calls around the block. Acquiring the
// lock does not change what the statement does with control: the block runs
// once, and it runs to completion before the lock is released. A
// single-threaded program can observe exactly that much, which is what this
// row checks -- it says nothing about mutual exclusion between threads.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot execute the body-less _d_monitorenter runtime hook"),
    Omit!(Bytecode, Because.refusal,
        "SIGSEGV in the native _d_monitorenter runtime hook"),
)) {
    @("synchronized.objectMonitor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto lock = new Object;
                int entered;
                synchronized (lock) {
                    entered = 1;
                }
                assert(entered == 1);
            }
        });
    }
}

// Synchronization must preserve the object's dynamic class identity. DMD
// lowers the block to runtime monitor calls, after which the same reference
// must still support an ordinary checked downcast.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot execute the body-less _d_monitorenter runtime hook"),
    Omit!(Bytecode, Because.refusal,
        "SIGSEGV in the native _d_monitorenter runtime hook"),
)) {
    @("synchronized.preservesDynamicClassIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Lock: Object {
            }

            unittest {
                Object lock = new Lock;

                synchronized (lock) {
                    assert(cast(Lock) lock !is null);
                }
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("function.inParameters." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("function.refParameter." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("function.multipleRefParameters." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("function.refSizeTParameter." ~ backend.stringof)
    @Tags(backend.stringof)
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

// dmd's own semantic3 merges a synthesized
// zero-init statement for every `out` parameter of a zero-init struct type
// into the callee's body (`BlitExp(VarExp(param), IntegerExp(0))`, with the
// literal's own `.type` retyped to the struct type as a "memset" marker --
// semantic3.d's own comment: "Must do same check in interpreter"). This
// interpreter's `runDeclarationExpression` already special-cases that exact
// shape for a plain local declaration (`S s = 0;`), materializing the
// struct's real default value instead of writing the literal through
// naively -- but this synthesized statement is a bare top-level assignment,
// not wrapped in a `DeclarationExp`, so it fell through
// `runAssignExpression`'s generic `runExpression(assign.e2)` path, which
// evaluated the `IntegerExp` as a scalar `Value(0)` and clobbered `s`'s
// boxed struct value with a bare int. The following `s.x = one();` field
// write then threw ("Expected struct.") from `Value.withStructField`, which
// requires a `Value.Struct` receiver. The bytecode core hit the same
// zero-init-blit shape: a struct-typed local's whole-struct assignment
// dispatch tried to read the `IntegerExp(0)` marker as a struct value via
// `structBaseOffsetOrMaterialise` instead of recognising it as "zero this
// block".
static foreach (backend; Matrix!()) {
    @("function.outStructParameterFieldWriteIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
                int y;
            }

            int one() { return 1; }
            int two() { return 2; }

            void makeS(out S s) {
                s.x = one();
                s.y = two();
            }

            unittest {
                S s;

                makeS(s);

                assert(s.x == 1);
                assert(s.y == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("function.outClassParameterAssignmentIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {}

            void make(out C c) {
                c = new C();
            }

            unittest {
                C c;

                make(c);

                assert(c !is null);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("function.outAssociativeArrayAssignmentIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void make(out int[int] values) {
                values = [1: 9];
            }

            unittest {
                int[int] values;

                make(values);

                assert(values[1] == 9);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("function.nestedLambdaReadsEnclosingThisField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                int value;

                int readThroughNestedLambda() {
                    auto nested = () => value;
                    return nested();
                }
            }

            unittest {
                auto holder = Holder(42);
                assert(holder.readThroughNestedLambda() == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("function.nestedLambdaIifeReadsEnclosingThisField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder {
                int value;

                int readThroughNestedLambda() {
                    return (() => value)();
                }
            }

            unittest {
                auto holder = Holder(42);
                assert(holder.readThroughNestedLambda() == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("function.capturingLambdaCalledThroughAliasParameterInNestedFunction." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void callThroughNested(alias Func)() {
                void inner() {
                    Func();
                }
                inner;
            }

            void outer() @safe {
                uint captured = 42u;
                callThroughNested!({
                    if (captured != 42u)
                        throw new Exception("bad value");
                });
            }

            unittest {
                outer;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("function.voidFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {}

            unittest {
                foo;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("function.voidFunctionExplicitReturn." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("function.explicitReturnSkipsFollowingStatements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void foo() {
                return;
                assert(false);
            }

            unittest {
                foo;
            }
        });
    }
}

// Ctfe diverges from SystemLinker here: CTFE-evaluated `assert(false)` raises
// the message "`assert(false)` failed", so this block characterizes Ctfe
// rather than the SystemLinker oracle below.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("function.structMethodReturnDoesNotSkipCallerStatements." ~
        backend.stringof)
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

// Compiled `assert(false)` in a unittest body raises the plain _d_unittest
// hook message "unittest failure"; "`assert(false)` failed" is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above"),
)) {
    @("function.structMethodReturnDoesNotSkipCallerStatements." ~
        backend.stringof)
    @Tags(backend.stringof)
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
        }).shouldThrowWithMessage("unittest failure");
    }
}

static foreach (backend; Matrix!()) {
    @("function.freeFunctionCallWithReturn." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("function.freeFunctionCallWithDifferentOperation." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("function.freeFunctionCallWithArrayParam." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int firstElement(int[] arr) {
                return arr[0];
            }

            int secondElement(int[] arr) {
                return arr[1];
            }

            unittest {
                int[] arr = [10, 20];

                assert(firstElement(arr) == 10);
                assert(secondElement(arr) == 20);
            }
        });
    }
}

static foreach (backend; Matrix!(Plus!(IR))) {
    @("function.defaultArgumentFillsOmittedParameter." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int add(int a, int b = 10) {
                return a + b;
            }

            int seed() {
                return 32;
            }

            unittest {
                int a = seed;

                assert(add(a) == 42);
                assert(add(a, 1) == 33);
            }
        });
    }
}

// IR is omitted: its VM asserts on f32/f64/ptr values (vm.d execute assert),
// so the double overload cannot run.
static foreach (backend; Matrix!()) {
    @("function.overloadResolutionBySignature." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int kind(int value) {
                return 1;
            }

            int kind(double value) {
                return 2;
            }

            int seed() {
                return 3;
            }

            unittest {
                int i = seed;
                double d = seed;

                assert(kind(i) == 1);
                assert(kind(d) == 2);
            }
        });
    }
}


/++
    If/else and returns.
+/
static foreach (backend; Matrix!()) {
    @("if.bodyAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int answer(int value) {
                if (value == 1)
                    value = 2;

                return value;
            }

            unittest {
                assert(answer(1) == 2);
                assert(answer(3) == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("if.elseBranches." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("if.elseUntakenBranchDoesNotRun." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("if.earlyReturn." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("if.multipleEarlyReturns." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    While, do-while, for, break, and continue.
+/
static foreach (backend; Matrix!()) {
    @("while.neverRuns." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("while.runsOnce." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("while.runsMultipleTimes." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("while.codegenShape." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("for.continue." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("doWhile.breakAndContinue." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("labeledBreak.exitsOuterForLoop." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("labeledContinue.skipsToOuterForIncrement." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Switch, switch control transfer, and labeled breaks.
+/
static foreach (backend; Matrix!()) {
    @("switch.caseMatch." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("switch.defaultCase." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("switch.gotoCase." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("switch.gotoDefault." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("switch.gotoCaseUsesRuntimeSelector." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("switch.gotoDefaultUsesRuntimeSelector." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("switch.breaksOuterLoop." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Interpreter/Bytecode report Switch as an unsupported statement; IR cannot
// map the string type (compiler.d valueType assert).
static foreach (backend; Matrix!()) {
    @("switch.stringCases." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string pick(int n) {
                return n == 1 ? "red" : "green";
            }

            int classify(string s) {
                switch (s) {
                    case "red":
                        return 10;

                    case "green":
                        return 20;

                    default:
                        return 0;
                }
            }

            unittest {
                assert(classify(pick(1)) == 10);
                assert(classify(pick(2)) == 20);
            }
        });
    }
}

// A wide-string switch must compare the full element width: the selector and
// the "ab"w case share their first code unit with "ax"w, so a truncated
// comparison would pick the wrong case.
static foreach (backend; Matrix!()) {
    @("switch.wstringCasesCompareFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            wstring pick(int n) {
                return n == 1 ? "ax"w : "ab"w;
            }

            int classify(wstring s) {
                switch (s) {
                    case "ab"w:
                        return 1;

                    case "ax"w:
                        return 2;

                    default:
                        return 3;
                }
            }

            unittest {
                assert(classify(pick(1)) == 2);
                assert(classify(pick(2)) == 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("switch.dstringCasesCompareFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            dstring pick(int n) {
                return n == 1 ? "ax"d : "ab"d;
            }

            int classify(dstring s) {
                switch (s) {
                    case "ab"d:
                        return 1;

                    case "ax"d:
                        return 2;

                    default:
                        return 3;
                }
            }

            unittest {
                assert(classify(pick(1)) == 2);
                assert(classify(pick(2)) == 1);
            }
        });
    }
}

// Interpreter/Bytecode report Switch as an unsupported statement; IR cannot
// compile the ternary in pick ("Unsupported IR expression").
static foreach (backend; Matrix!()) {
    @("switch.finalSwitchOnEnumCoversAllMembers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            enum Colour {
                red,
                green,
                blue,
            }

            Colour pick(int n) {
                return n == 0 ? Colour.red : n == 1 ? Colour.green : Colour.blue;
            }

            int weight(Colour colour) {
                final switch (colour) {
                    case Colour.red:
                        return 10;

                    case Colour.green:
                        return 20;

                    case Colour.blue:
                        return 30;
                }
            }

            unittest {
                assert(weight(pick(0)) == 10);
                assert(weight(pick(1)) == 20);
                assert(weight(pick(2)) == 30);
            }
        });
    }
}

// Interpreter, Bytecode, and IR all report Switch as an unsupported statement.
static foreach (backend; Matrix!()) {
    @("switch.caseRangesAndMultiValueCases." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int n) {
                return n;
            }

            int classify(int n) {
                switch (n) {
                    case 0: .. case 3:
                        return 10;

                    case 5, 7:
                        return 20;

                    default:
                        return 30;
                }
            }

            unittest {
                assert(classify(seed(0)) == 10);
                assert(classify(seed(3)) == 10);
                assert(classify(seed(5)) == 20);
                assert(classify(seed(7)) == 20);
                assert(classify(seed(4)) == 30);
            }
        });
    }
}


/++
    Goto and restart points.
+/
static foreach (backend; Matrix!()) {
    @("goto.directLabel." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("goto.restartsExpressionStatement." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("goto.restartsCompoundStatement." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("goto.restartsBreakStatement." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("goto.restartsContinueStatement." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Goto, catch, and finally.
+/
static foreach (backend; Matrix!()) {
    @("goto.restartsBreakStatementInTryFinally." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("goto.restartsContinueStatementInTryFinally." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("goto.restartsGotoStatementInTryFinally." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("goto.restartsGotoCaseStatementInTryFinally." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("goto.restartsGotoDefaultStatementInTryFinally." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("catch.gotoRestartsBreakStatement." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("catch.gotoRestartsContinueStatement." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("catch.gotoRestartsGotoStatement." ~ backend.stringof)
    @Tags(backend.stringof)
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


/++
    Foreach.
+/
static foreach (backend; Matrix!()) {
    @("foreach.array." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Bytecode cannot compile the foreach lowering's array slice ("Unsupported
// expression `arr[]`"); IR reports the array literal as unsupported.
static foreach (backend; Matrix!()) {
    @("foreach.arrayWithIndex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr = [10, 20, 30];
                int weighted;

                foreach (i, e; arr)
                    weighted += e * (cast(int) i + 1);

                assert(weighted == 140);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("foreach.emptyArray." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("foreach.range." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("foreach.expressionTupleBreakAndContinue." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("foreach.utf8StringDecodesDchars." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("foreach.utf16StringDecodesDchars." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("foreach.utf32StringEncodesAsUtf8WhenIteratingChar." ~
        backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("foreach.reverseUtf16String." ~ backend.stringof)
    @Tags(backend.stringof)
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

// Interpreter hits the foreach_reverse lowering's post-decrement
// ("Unsupported eval post expression"); Bytecode cannot compile the array
// slice ("Unsupported expression `arr[]`"); IR reports the array literal as
// unsupported.
static foreach (backend; Matrix!()) {
    @("foreach.reverseIntArrayVisitsBackToFront." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr = [1, 2, 3];
                int[] visited;

                foreach_reverse (x; arr)
                    visited ~= x;

                assert(visited.length == 3);
                assert(visited[0] == 3);
                assert(visited[1] == 2);
                assert(visited[2] == 1);
            }
        });
    }
}


/++
    Function pointers.
+/
static foreach (backend; Matrix!()) {
    @("functionPointer.hashCollisionUsesCorrectCallee." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("functionPointer.dispatchesToDistinctCallees." ~ backend.stringof)
    @Tags(backend.stringof)
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

static foreach (backend; Matrix!()) {
    @("functionPointer.callCanEnterFunctionWithCallee." ~ backend.stringof)
    @Tags(backend.stringof)
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
