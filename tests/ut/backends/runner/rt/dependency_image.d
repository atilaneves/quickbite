module ut.backends.runner.rt.dependency_image;


import ut.backends;


@("dependencyImage.externDFunction.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_fixture.d");
        writeFile(depPath, q{
            module dep_image_fixture;

            int dependencyAdd(int value) {
                return value + 17;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_fixture;

            int dependencyAdd(int value);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_fixture;

                unittest {
                    int value = 25;
                    assert(dependencyAdd(value) == 42);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDTwoArgumentFunction.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_order_fixture.d");
        writeFile(depPath, q{
            module dep_image_order_fixture;

            int dependencySub(int a, int b) {
                return a - b;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_order_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_order_fixture;

            int dependencySub(int a, int b);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_order_fixture;

                unittest {
                    int left = 10;
                    int right = 3;
                    assert(dependencySub(left, right) == 7);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDStringArgumentFunction.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_string_fixture.d");
        writeFile(depPath, q{
            module dep_image_string_fixture;

            int dependencyStringScore(string value) {
                return cast(int) value.length * 10 + value[0];
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_string_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_string_fixture;

            int dependencyStringScore(string value);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_string_fixture;

                unittest {
                    string value = "abc";
                    assert(dependencyStringScore(value) == 127);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDStringReturnFunction.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_string_return_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_string_return_fixture;

            string dependencyGreeting() {
                return "quickbite";
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_string_return_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_string_return_fixture;

            string dependencyGreeting();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_string_return_fixture;

                unittest {
                    string value = dependencyGreeting();
                    assert(value == "quickbite");
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDTypedSliceFunction.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_typed_slice_fixture.d");
        writeFile(depPath, q{
            module dep_image_typed_slice_fixture;

            long dependencySum(const(long)[] values) {
                long result;
                foreach (value; values)
                    result += value;
                return result;
            }

            const(int)[] dependencyTriple(int value) {
                return [value, value * 2, value * 3];
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_typed_slice_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_typed_slice_fixture;

            long dependencySum(const(long)[] values);
            const(int)[] dependencyTriple(int value);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_typed_slice_fixture;

                unittest {
                    long[] values = [5, 7, 11];
                    assert(dependencySum(values) == 23);

                    const(int)[] result = dependencyTriple(4);
                    assert(result.length == 3);
                    assert(result[0] == 4);
                    assert(result[1] == 8);
                    assert(result[2] == 12);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDStackSpillFunction.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_stack_spill_fixture.d");
        writeFile(depPath, q{
            module dep_image_stack_spill_fixture;

            int dependencyEncodePositions(
                int first,
                int second,
                int third,
                int fourth,
                int fifth,
                int sixth,
                int seventh,
                int eighth,
            ) {
                return first * 10000000 +
                    second * 1000000 +
                    third * 100000 +
                    fourth * 10000 +
                    fifth * 1000 +
                    sixth * 100 +
                    seventh * 10 +
                    eighth;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_stack_spill_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_stack_spill_fixture;

            int dependencyEncodePositions(
                int first,
                int second,
                int third,
                int fourth,
                int fifth,
                int sixth,
                int seventh,
                int eighth,
            );
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_stack_spill_fixture;

                unittest {
                    int first = 1;
                    int second = 2;
                    int third = 3;
                    int fourth = 4;
                    int fifth = 5;
                    int sixth = 6;
                    int seventh = 7;
                    int eighth = 8;
                    assert(dependencyEncodePositions(
                        first,
                        second,
                        third,
                        fourth,
                        fifth,
                        sixth,
                        seventh,
                        eighth,
                    ) == 12345678);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDMemberFunction.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_member_fixture.d");
        writeFile(depPath, q{
            module dep_image_member_fixture;

            struct Counter {
                int value;

                int read() const {
                    return value + 17;
                }
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_member_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_member_fixture;

            struct Counter {
                int value;
                int read() const;
            }
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_member_fixture;

                unittest {
                    Counter counter = Counter(25);
                    assert(counter.read == 42);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDMemberFunctionWithArguments.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_member_args_fixture.d");
        writeFile(depPath, q{
            module dep_image_member_args_fixture;

            struct Counter {
                int value;

                int addSub(int addend, int subtrahend) const {
                    return value + addend - subtrahend;
                }
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_member_args_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_member_args_fixture;

            struct Counter {
                int value;
                int addSub(int addend, int subtrahend) const;
            }
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_member_args_fixture;

                unittest {
                    Counter counter = Counter(25);
                    int addend = 20;
                    int subtrahend = 3;
                    assert(counter.addSub(addend, subtrahend) == 42);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// Characterization (ffi.md §34.7): a >16-byte struct returns through the hidden
// `sret` pointer, which libffi issues transparently from the struct ffi_type and
// the bridge reifies via NativeMarshaller.readResult. Already works; this pins
// that behaviour across the §5 seam. The asymmetric fields also re-exercise the
// §27 extern(D) argument reversal alongside the sret return.
@("dependencyImage.externDLargeStructReturn.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_struct_return_fixture.d");
        writeFile(depPath, q{
            module dep_image_struct_return_fixture;

            struct Quad {
                long a;
                long b;
                long c;
                long d;
            }

            Quad dependencyQuad(int first, int second) {
                return Quad(first, second, first - second, first * second);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_struct_return_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_struct_return_fixture;

            struct Quad { long a; long b; long c; long d; }
            Quad dependencyQuad(int first, int second);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_struct_return_fixture;

                unittest {
                    int first = 9;
                    int second = 4;
                    Quad q = dependencyQuad(first, second);
                    assert(q.a == 9);
                    assert(q.b == 4);
                    assert(q.c == 5);
                    assert(q.d == 36);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.nativeException.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_exception_fixture.d");
        writeFile(depPath, q{
            module dep_image_exception_fixture;

            void dependencyThrow() {
                throw new Exception("dependency failed");
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_exception_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_exception_fixture;

            void dependencyThrow();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_exception_fixture;

                unittest {
                    try {
                        dependencyThrow();
                        assert(false);
                    } catch (Exception caught) {
                        assert(caught.msg == "dependency failed");
                    }
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.nativeCustomException.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_custom_exception_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_custom_exception_fixture;

            class DependencyException: Exception {
                this(string msg) {
                    super(msg);
                }
            }

            void dependencyThrowCustom() {
                throw new DependencyException("dependency failed");
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_custom_exception_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_custom_exception_fixture;

            class DependencyException: Exception {
                this(string msg);
            }

            void dependencyThrowCustom();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_custom_exception_fixture;

                unittest {
                    try {
                        dependencyThrowCustom();
                        assert(false);
                    } catch (DependencyException caught) {
                        assert(caught.msg == "dependency failed");
                    }
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.nativeChainedException.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_chained_exception_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_chained_exception_fixture;

            void dependencyThrowChained() {
                auto inner = new Exception("inner failure");
                auto outer = new Exception("outer failure");
                outer.next = inner;
                throw outer;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_chained_exception_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_chained_exception_fixture;

            void dependencyThrowChained();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_chained_exception_fixture;

                unittest {
                    try {
                        dependencyThrowChained();
                        assert(false);
                    } catch (Exception caught) {
                        assert(caught.msg == "outer failure");
                        assert(caught.next.msg == "inner failure");
                    }
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externCVariadic.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_variadic_fixture.d");
        writeFile(depPath, q{
            module dep_image_variadic_fixture;

            import core.stdc.stdarg;

            extern(C) int dependencyCombine(int count, ...) {
                va_list args;
                va_start(args, count);
                int result;
                foreach (_; 0 .. count)
                    result = result * 10 + va_arg!int(args);
                va_end(args);
                return result;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_variadic_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_variadic_fixture;

            extern(C) int dependencyCombine(int count, ...);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_variadic_fixture;

                unittest {
                    int count = 3;
                    int first = 1;
                    int second = 2;
                    int third = 3;
                    assert(
                        dependencyCombine(count, first, second, third) == 123,
                    );
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externCppFunctionAndMember.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_cpp_fixture.d");
        writeFile(depPath, q{
            module dep_image_cpp_fixture;

            extern(C++) int dependencyCppSub(int a, int b) {
                return a - b;
            }

            extern(C++) struct CppCounter {
                int value;

                int combine(int x, int y) {
                    return value * 100 + x * 10 + y;
                }
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_cpp_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_cpp_fixture;

            extern(C++) int dependencyCppSub(int a, int b);

            extern(C++) struct CppCounter {
                int value;
                int combine(int x, int y);
            }
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_cpp_fixture;

                unittest {
                    int a = 9;
                    int b = 4;
                    assert(dependencyCppSub(a, b) == 5);

                    CppCounter counter = CppCounter(7);
                    int x = 2;
                    int y = 3;
                    assert(counter.combine(x, y) == 723);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDMutatingMember.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_mutating_member_fixture.d");
        writeFile(depPath, q{
            module dep_image_mutating_member_fixture;

            struct Counter {
                int value;

                void bump(int by) {
                    value += by;
                }
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_mutating_member_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_mutating_member_fixture;

            struct Counter {
                int value;
                void bump(int by);
            }
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_mutating_member_fixture;

                unittest {
                    Counter counter = Counter(25);
                    int by = 5;
                    counter.bump(by);
                    assert(counter.value == 30);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDMutableSliceWriteback.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_mutable_slice_fixture.d");
        writeFile(depPath, q{
            module dep_image_mutable_slice_fixture;

            void dependencyFill(int[] xs, int value) {
                foreach (ref x; xs)
                    x = value;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_mutable_slice_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_mutable_slice_fixture;

            void dependencyFill(int[] xs, int value);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_mutable_slice_fixture;

                unittest {
                    int[] xs = [1, 2, 3];
                    int value = 9;
                    dependencyFill(xs, value);
                    assert(xs[0] == 9);
                    assert(xs[1] == 9);
                    assert(xs[2] == 9);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// Characterization (ffi.md §34.11): a by-value struct with a slice field
// crosses in both directions through the existing recursive struct walk reusing
// the {length, ptr} slice descriptor; already works, so this pins it. Covers the
// argument direction (reading `s.name`/`s.id`) and the struct-returning variant.
@("dependencyImage.externDNestedSliceStruct.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_nested_slice_fixture.d");
        writeFile(depPath, q{
            module dep_image_nested_slice_fixture;

            struct Tagged {
                string name;
                int id;
            }

            int dependencyScore(Tagged tagged) {
                return cast(int) tagged.name.length * 100 + tagged.id;
            }

            Tagged dependencyTag(int id) {
                return Tagged("abcd", id);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_nested_slice_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_nested_slice_fixture;

            struct Tagged { string name; int id; }
            int dependencyScore(Tagged tagged);
            Tagged dependencyTag(int id);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_nested_slice_fixture;

                unittest {
                    Tagged tagged = Tagged("abcd", 7);
                    assert(dependencyScore(tagged) == 407);

                    int id = 9;
                    Tagged made = dependencyTag(id);
                    assert(made.name == "abcd");
                    assert(made.id == 9);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externCScalarOutParameter.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_out_param_fixture.d");
        writeFile(depPath, q{
            module dep_image_out_param_fixture;

            extern(C) void dependencyDouble(int* result, int value) {
                *result = value * 2;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_out_param_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_out_param_fixture;

            extern(C) void dependencyDouble(int* result, int value);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_out_param_fixture;

                unittest {
                    int value = 21;
                    int result;
                    dependencyDouble(&result, value);
                    assert(result == 42);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}


// A dependency-image class with a virtual method and a subclass override (ffi.md
// §34.12): the factory returns a base `Widget` reference to a derived `Button`,
// and the call must dispatch through the object's vtable to the override rather
// than to the statically-resolved base method.
@("dependencyImage.externDClassVirtualDispatch.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_widget_fixture.d");
        writeFile(depPath, q{
            module dep_image_widget_fixture;

            class Widget {
                int draw() {
                    return 0;
                }
            }

            class Button: Widget {
                override int draw() {
                    return 42;
                }
            }

            Widget makeButton() {
                return new Button();
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_widget_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_widget_fixture;

            class Widget {
                int draw();
            }

            class Button: Widget {
                override int draw();
            }

            Widget makeButton();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_widget_fixture;

                unittest {
                    Widget w = makeButton();
                    assert(w.draw() == 42);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// A dependency-image interface method call dispatched through the interface
// table (ffi.md §34.12): the factory returns a `Drawable` interface reference to
// a `Button`, and the call must dispatch through the object's interface table to
// the implementation. `draw` reads an instance field, so a wrong `this`
// (interface pointer not adjusted back to the object base) returns the wrong
// value — that itable `this`-adjustment is what distinguishes interfaces from a
// plain class vtable.
@("dependencyImage.externDInterfaceDispatch.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_interface_fixture.d");
        writeFile(depPath, q{
            module dep_image_interface_fixture;

            interface Drawable {
                int draw();
            }

            class Button: Drawable {
                int color;

                this(int color) {
                    this.color = color;
                }

                override int draw() {
                    return color + 2;
                }
            }

            Drawable makeButton() {
                return new Button(40);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_interface_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_interface_fixture;

            interface Drawable {
                int draw();
            }

            class Button: Drawable {
                int color;
                this(int color);
                override int draw();
            }

            Drawable makeButton();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_interface_fixture;

                unittest {
                    Drawable d = makeButton();
                    assert(d.draw() == 42);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// A dependency-image struct constructed through its native extern(D)
// `this(int)` constructor (ffi.md §34.13). The ctor computes the field rather
// than plain field-init, so a passing read proves the native constructor body
// ran across the boundary rather than an aggregate struct-literal fallback.
@("dependencyImage.externDStructConstructor.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_ctor_fixture.d");
        writeFile(depPath, q{
            module dep_image_ctor_fixture;

            struct Tracked {
                int value;

                this(int seed) {
                    value = seed + 17;
                }
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_ctor_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_ctor_fixture;

            struct Tracked {
                int value;
                this(int seed);
            }
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ctor_fixture;

                unittest {
                    int seed = 25;
                    Tracked tracked = Tracked(seed);
                    assert(tracked.value == 42);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// A dependency-image struct whose body-less extern(D) destructor runs at scope
// exit (ffi.md §34.13). The destructor increments a shared native counter, read
// back through a body-less accessor, proving `~this()` fired across the boundary.
@("dependencyImage.externDStructDestructor.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_dtor_fixture.d");
        writeFile(depPath, q{
            module dep_image_dtor_fixture;

            __gshared int dtorCount;

            struct Tracked {
                int value;

                ~this() {
                    dtorCount += 1;
                }
            }

            int dtorCalls() {
                return dtorCount;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_dtor_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_dtor_fixture;

            struct Tracked {
                int value;
                ~this();
            }

            int dtorCalls();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_dtor_fixture;

                unittest {
                    int seed = 7;
                    {
                        Tracked tracked = Tracked(seed);
                    }
                    assert(dtorCalls() == 1);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// A dependency-image struct whose body-less extern(D) postblit runs on copy
// (ffi.md §34.13). The postblit increments a shared native counter, read back
// through a body-less accessor, proving `this(this)` fired across the boundary.
@("dependencyImage.externDStructPostblit.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_postblit_fixture.d");
        writeFile(depPath, q{
            module dep_image_postblit_fixture;

            __gshared int postblitCount;

            struct Tracked {
                int value;

                this(this) {
                    postblitCount += 1;
                }
            }

            int postblitCalls() {
                return postblitCount;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_postblit_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_postblit_fixture;

            struct Tracked {
                int value;
                this(this);
            }

            int postblitCalls();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_postblit_fixture;

                unittest {
                    int seed = 9;
                    Tracked original = Tracked(seed);
                    Tracked copy = original;
                    assert(copy.value == 9);
                    assert(postblitCalls() == 1);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

@("dependencyImage.externDDelegateCallback.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_callback_fixture.d");
        writeFile(depPath, q{
            module dep_image_callback_fixture;

            int dependencyApply(int x, int delegate(int) callback) {
                return callback(x);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_callback_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_callback_fixture;

            int dependencyApply(int x, int delegate(int) callback);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_callback_fixture;

                unittest {
                    int base = 100;
                    int x = 5;
                    int delegate(int) callback = (int n) => n + base;
                    assert(dependencyApply(x, callback) == 105);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// A multi-argument interpreted delegate passed into native code (ffi.md §34.16).
// The callback subtracts its arguments, so a wrong explicit-argument order would
// return -7; a passing result proves the trampoline restores the reversed
// extern(D) callback arguments to source order.
@("dependencyImage.externDMultiArgDelegateCallback.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_callback2_fixture.d");
        writeFile(depPath, q{
            module dep_image_callback2_fixture;

            int dependencyApply2(int x, int y, int delegate(int, int) callback) {
                return callback(x, y);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_callback2_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_callback2_fixture;

            int dependencyApply2(int x, int y, int delegate(int, int) callback);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_callback2_fixture;

                unittest {
                    int x = 10;
                    int y = 3;
                    int delegate(int, int) callback = (int a, int b) => a - b;
                    assert(dependencyApply2(x, y, callback) == 7);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// A dependency-image struct whose body-less extern(D) postblit MUTATES the copy
// (ffi.md §34.13). Unlike externDStructPostblit (which only counts), this writes
// through `this`, so the copied variable must reflect the post-call receiver
// bytes — the BlitExp receiver writeback half of the rung.
@("dependencyImage.externDMutatingPostblit.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_mut_postblit_fixture.d");
        writeFile(depPath, q{
            module dep_image_mut_postblit_fixture;

            struct Tracked {
                int value;

                this(this) {
                    value += 1;
                }
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_mut_postblit_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_mut_postblit_fixture;

            struct Tracked {
                int value;
                this(this);
            }
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_mut_postblit_fixture;

                unittest {
                    int seed = 9;
                    Tracked original = Tracked(seed);
                    Tracked copy = original;
                    assert(copy.value == 10);
                    assert(original.value == 9);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// A `new T(args)` expression where T's extern(D) constructor is body-less
// (ffi.md §34.13). Unlike externDStructConstructor (`T(seed)` value
// construction), the new-expression path must route a body-less ctor through the
// FFI bridge instead of running its (null) body, which would leave the heap
// struct default-initialised (value == 0).
@("dependencyImage.externDNewStructConstructor.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_new_struct_fixture.d");
        writeFile(depPath, q{
            module dep_image_new_struct_fixture;

            struct Tracked {
                int value;

                this(int seed) {
                    value = seed + 17;
                }
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_new_struct_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_new_struct_fixture;

            struct Tracked {
                int value;
                this(int seed);
            }
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_new_struct_fixture;

                unittest {
                    int seed = 25;
                    Tracked* tracked = new Tracked(seed);
                    assert(tracked.value == 42);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imagePath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}
