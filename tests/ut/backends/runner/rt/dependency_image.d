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

@("dependencyImage.externDRefReturn.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_ref_return_fixture.d");
        writeFile(depPath, q{
            module dep_image_ref_return_fixture;

            private int stored = 41;

            ref int dependencySlot() {
                return stored;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_ref_return_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_ref_return_fixture;

            ref int dependencySlot();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ref_return_fixture;

                unittest {
                    assert(dependencySlot == 41);

                    dependencySlot = 42;
                    assert(dependencySlot == 42);
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

@("dependencyImage.nativeCustomExceptionField.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_custom_exception_field_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_custom_exception_field_fixture;

            class DependencyException: Exception {
                int code;

                this(string msg, int code) {
                    super(msg);
                    this.code = code;
                }
            }

            void dependencyThrowCustomField() {
                throw new DependencyException("dependency failed", 73);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_custom_exception_field_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_custom_exception_field_fixture;

            class DependencyException: Exception {
                int code;
                this(string msg, int code);
            }

            void dependencyThrowCustomField();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_custom_exception_field_fixture;

                unittest {
                    try {
                        dependencyThrowCustomField();
                        assert(false);
                    } catch (DependencyException caught) {
                        assert(caught.msg == "dependency failed");
                        assert(caught.code == 73);
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

@("dependencyImage.nativeCustomExceptionFieldViaBaseCatch.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_custom_exception_base_catch_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_custom_exception_base_catch_fixture;

            class DependencyException: Exception {
                int code;

                this(string msg, int code) {
                    super(msg);
                    this.code = code;
                }
            }

            void dependencyThrowCustomField() {
                throw new DependencyException("dependency failed", 73);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_custom_exception_base_catch_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_custom_exception_base_catch_fixture;

            class DependencyException: Exception {
                int code;
                this(string msg, int code);
            }

            void dependencyThrowCustomField();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import core.memory;
                import dep_image_custom_exception_base_catch_fixture;

                unittest {
                    try {
                        dependencyThrowCustomField();
                        assert(false);
                    } catch (Exception caught) {
                        GC.collect;
                        auto dependency = cast(DependencyException) caught;
                        assert(dependency !is null);
                        assert(dependency.msg == "dependency failed");
                        assert(dependency.code == 73);
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

@("dependencyImage.nativeCustomExceptionFieldAcrossHelperCatch.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_custom_exception_helper_catch_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_custom_exception_helper_catch_fixture;

            __gshared int dependencyFinalized;

            class DependencyException: Exception {
                int code;

                this(string msg, int code) {
                    super(msg);
                    this.code = code;
                }

                ~this() {
                    dependencyFinalized = 1;
                }
            }

            void dependencyThrowCustomField() {
                dependencyFinalized = 0;
                throw new DependencyException("dependency failed", 73);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_custom_exception_helper_catch_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_custom_exception_helper_catch_fixture;

            class DependencyException: Exception {
                int code;
                this(string msg, int code);
            }

            extern __gshared int dependencyFinalized;

            void dependencyThrowCustomField();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import core.memory;
                import dep_image_custom_exception_helper_catch_fixture;

                void helper() {
                    dependencyThrowCustomField();
                }

                unittest {
                    try {
                        helper();
                        assert(false);
                    } catch (Exception caught) {
                        GC.collect;
                        assert(dependencyFinalized == 0);
                        auto dependency = cast(DependencyException) caught;
                        assert(dependency !is null);
                        assert(dependency.msg == "dependency failed");
                        assert(dependency.code == 73);
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

// C default argument promotions on the variadic tail: a char argument must
// arrive as int and a float as double (ffi_prep_cif_var rejects unpromoted
// small-int/float variadic types), whether the frontend promotes at the call
// site or the bridge has to.
@("dependencyImage.externCVariadicPromotion.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_variadic_promotion_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_variadic_promotion_fixture;

            import core.stdc.stdarg;

            extern(C) int dependencyPromote(int count, ...) {
                va_list args;
                va_start(args, count);
                const number = va_arg!int(args);
                const fraction = va_arg!double(args);
                va_end(args);
                return number * 100 + cast(int) (fraction * 10.0);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_variadic_promotion_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_variadic_promotion_fixture;

            extern(C) int dependencyPromote(int count, ...);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_variadic_promotion_fixture;

                unittest {
                    char letter = 'a';
                    float fraction = 2.5;
                    assert(dependencyPromote(2, letter, fraction) == 9725);
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

// A by-value struct with a static-array field (ffi.md §34.3.1 item 0): the
// static array crosses as a STRUCT ffi_type of `dim` element copies, so the
// containing struct is no longer refused. Covers the argument direction.
@("dependencyImage.externDStaticArrayField.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_static_array_fixture.d");
        writeFile(depPath, q{
            module dep_image_static_array_fixture;

            struct Fixed {
                int[4] values;
                int tag;
            }

            int dependencyFixedSum(Fixed fixed) {
                return fixed.values[0] + fixed.values[1] + fixed.values[2]
                    + fixed.values[3] + fixed.tag;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_static_array_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_static_array_fixture;

            struct Fixed {
                int[4] values;
                int tag;
            }
            int dependencyFixedSum(Fixed fixed);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_static_array_fixture;

                unittest {
                    int base = 10;
                    Fixed fixed = Fixed([base, base + 1, base + 2, base + 3], 100);
                    assert(dependencyFixedSum(fixed) == 146);
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


// An in-out scalar parameter (ffi.md §34.8): the callee reads the pointed-to
// value before writing it back, so the marshalled cell must carry the
// argument's current value into the call, not start zeroed.
@("dependencyImage.externCInOutScalarParameter.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_inout_param_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_inout_param_fixture;

            extern(C) void dependencyBump(int* value) {
                *value += 1;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_inout_param_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_inout_param_fixture;

            extern(C) void dependencyBump(int* value);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_inout_param_fixture;

                unittest {
                    int value = 41;
                    dependencyBump(&value);
                    assert(value == 42);
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


// A pointer-to-pointer parameter the callee reads through (ffi.md §34.8): the
// `char**` shape alone does not make it an out slot, so the argument's current
// pointer value must reach the callee. The fixture null-checks so the flaw
// shows as a wrong return value rather than a crash.
@("dependencyImage.externCPointerToPointerInput.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_ptr_ptr_in_fixture.d");
        writeFile(depPath, q{
            module dep_image_ptr_ptr_in_fixture;

            extern(C) const(char)* dependencyWord() {
                return "hello";
            }

            extern(C) int dependencyFirstLength(const(char)** words) {
                import core.stdc.string: strlen;

                if (words is null || *words is null)
                    return -1;
                return cast(int) strlen(*words);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_ptr_ptr_in_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_ptr_ptr_in_fixture;

            extern(C) const(char)* dependencyWord();
            extern(C) int dependencyFirstLength(const(char)** words);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ptr_ptr_in_fixture;

                unittest {
                    const(char)* word = dependencyWord();
                    assert(dependencyFirstLength(&word) == 5);
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


// A union crossing the boundary by value: DMD lays the fields out overlapped,
// but ffiStructType walks them as if sequential, so libffi's computed size
// disagrees with DMD's and the layout cross-check assert kills the call
// instead of either calling correctly or falling back gracefully.
@("dependencyImage.externCUnionReturn.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_union_fixture.d");
        writeFile(depPath, q{
            module dep_image_union_fixture;

            union Overlay {
                int number;
                float precise;
            }

            extern(C) Overlay dependencyOverlay() {
                Overlay result;
                result.number = 42;
                return result;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_union_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_union_fixture;

            union Overlay {
                int number;
                float precise;
            }

            extern(C) Overlay dependencyOverlay();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_union_fixture;

                unittest {
                    Overlay overlay = dependencyOverlay();
                    assert(overlay.number == 42);
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


// A delegate crossing the boundary as a RETURN value: the type mapper claims
// delegates (ffiTypeFor handles Tdelegate) so the call proceeds, but the
// marshaller only handles delegates as direct arguments — reifying the
// returned {context, funcptr} pair dies on the unmarshalValue default assert
// instead of either working or falling back gracefully before the call.
@("dependencyImage.externDDelegateReturn.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_delegate_return_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_delegate_return_fixture;

            int delegate() dependencyMakeAdder(int base) {
                return () => base + 1;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_delegate_return_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_delegate_return_fixture;

            int delegate() dependencyMakeAdder(int base);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_delegate_return_fixture;

                unittest {
                    int delegate() adder = dependencyMakeAdder(41);
                    assert(adder() == 42);
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

// A scoped delegate is contractually consumed within this native call, so it
// remains on the call-scoped reverse bridge (ffi.md §34.16).
@("dependencyImage.externDScopedVoidDelegateCallback.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_scoped_void_callback_fixture.d");
        writeFile(depPath, q{
            module dep_image_scoped_void_callback_fixture;

            void dependencyVisit(int value, scope void delegate(int) callback) {
                callback(value);
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_scoped_void_callback_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_scoped_void_callback_fixture;

            void dependencyVisit(int value, scope void delegate(int) callback);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_scoped_void_callback_fixture;

                unittest {
                    int seen;
                    int value = 42;
                    void delegate(int) callback = (int n) { seen = n; };

                    dependencyVisit(value, callback);
                    assert(seen == 42);
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

// A dependency image retains an interpreted extern(D) delegate beyond the
// registering FFI call, then invokes it through a later native call (ffi.md
// §35.4). SystemLinker proves D permits this; until the durable inbound
// trampoline registry exists, Interpreter must reject the registration with a
// named diagnostic rather than hand native code a call-scoped trampoline.
@("dependencyImage.externDDurableDelegateCallback.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_durable_callback_fixture.d");
        writeFile(depPath, q{
            module dep_image_durable_callback_fixture;

            extern(D) {
                int delegate(int) storedCallback;

                void registerCallback(int delegate(int) callback) {
                    storedCallback = callback;
                }

                int invokeRegisteredCallback(int value) {
                    return storedCallback(value);
                }
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_durable_callback_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_durable_callback_fixture;

            extern(D) {
                void registerCallback(int delegate(int) callback);
                int invokeRegisteredCallback(int value);
            }
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_durable_callback_fixture;

                unittest {
                    int base = 40;
                    int value = 2;
                    int delegate(int) callback = (int n) => n + base;

                    registerCallback(callback);
                    assert(invokeRegisteredCallback(value) == 42);
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
        interpreted[0].passed.should == false;
        interpreted[0].message.should ==
            "`registerCallback` cannot be called natively: durable inbound " ~
            "trampoline unsupported";
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

// Characterization pin for native class-handle GC visibility (ffi.md §34.12):
// a returned class reference reifies as an opaque NativePointer whose raw
// `void*` field lives inside a boxed Value, and every place the interpreter
// keeps Values (the locals AA, the host stack) is GC-scanned memory — so a
// collection between the factory call and a later use keeps the object alive,
// with no explicit rooting. The plan's feared hole exists only where a
// handle's sole reference lives in NO_SCAN memory (the native-layout
// backend's raw byte frames); that is the value.md handle-table work, not a
// boxed-interpreter defect.
@("dependencyImage.externDClassHandleSurvivesCollection.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_gc_root_fixture.d");
        writeFile(depPath, q{
            module dep_image_gc_root_fixture;

            class Thing {
                int payload;

                this(int payload) {
                    this.payload = payload;
                }
            }

            Object makeThing() {
                return new Thing(42);
            }

            void collectNow() {
                import core.memory: GC;
                GC.collect;
            }

            bool isLive(Object o) {
                import core.memory: GC;
                return GC.addrOf(cast(void*) o) !is null;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_gc_root_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_gc_root_fixture;

            Object makeThing();
            void collectNow();
            bool isLive(Object o);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_gc_root_fixture;

                unittest {
                    Object thing = makeThing;
                    collectNow;
                    assert(isLive(thing));
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

// A union-typed out-pointer written by one extern(C) call and read back
// through a second (ffi.md §35.10), mirroring externCScalarOutParameter but
// with a union behind the pointer. `Handle*` passed as `&handle` is an
// out-struct-pointer whose pointed-to type is a union, so `canMarshalToNative`
// (ffi_marshal.d) refuses it toNative and `canRepresentCall`'s out-cell check
// (core.d) rejects the call: the Interpreter degrades to the
// no-available-source refusal today even though the sentinel byte would
// round-trip. SystemLinker is the behaviour oracle; the Interpreter leg is red
// pending the union-gate fix.
@("dependencyImage.externCUnionOutParameter.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_union_out_fixture.d");
        writeFile(depPath, q{
            module dep_image_union_out_fixture;

            union Handle {
                long aligned;
                byte[16] bytes;
            }

            extern(C) void dependencyInitHandle(Handle* h) {
                h.bytes[0] = 7;
            }

            extern(C) int dependencyReadHandle(Handle* h) {
                return h.bytes[0];
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_union_out_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_union_out_fixture;

            union Handle {
                long aligned;
                byte[16] bytes;
            }

            extern(C) void dependencyInitHandle(Handle* h);
            extern(C) int dependencyReadHandle(Handle* h);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_union_out_fixture;

                unittest {
                    Handle handle;
                    dependencyInitHandle(&handle);
                    assert(dependencyReadHandle(&handle) == 7);
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

// A dynamic slice whose element is a by-value struct (ffi.md §34.3.1 item 0):
// the slice ABI descriptor is element-agnostic, so once the element gate is
// representability-driven the slice crosses both as an argument and a return.
@("dependencyImage.externDSliceOfStructs.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_slice_of_structs_fixture.d");
        writeFile(depPath, q{
            module dep_image_slice_of_structs_fixture;

            struct Point {
                int x;
                int y;
            }

            long dependencyPointSum(const(Point)[] points) {
                long total = 0;
                foreach (point; points)
                    total += point.x + point.y;
                return total;
            }

            const(Point)[] dependencyMakePoints(int seed) {
                return [Point(seed, seed + 1), Point(seed + 2, seed + 3)];
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_slice_of_structs_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_slice_of_structs_fixture;

            struct Point {
                int x;
                int y;
            }

            long dependencyPointSum(const(Point)[] points);
            const(Point)[] dependencyMakePoints(int seed);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_slice_of_structs_fixture;

                unittest {
                    int base = 5;
                    Point[] points =
                        [Point(base, base + 1), Point(base + 2, base + 3)];
                    assert(dependencyPointSum(points) == 26);

                    const made = dependencyMakePoints(base);
                    assert(made.length == 2);
                    assert(made[0].x == 5);
                    assert(made[1].y == 8);
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

// An associative-array parameter crossing the boundary (ffi.md §34.3.1 item 0):
// the boxed interpreter cannot reproduce the AA's hashing, allocation, and
// layout across the ABI, so the crossing stays refused — but the diagnostic
// must name the associative array rather than blame missing source. The native
// oracle crosses it fine (the KEPT supported-behavior leg); the Interpreter
// refuses it honestly (unsupportedNativeTypeMessage). extern(C) keeps argument
// ordering irrelevant.
@("dependencyImage.externCAssocArrayRejected.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_assoc_array_fixture.d");
        writeFile(depPath, q{
            module dep_image_assoc_array_fixture;

            extern(C) int dependencyCountEntries(int[string] table) {
                return cast(int) table.length;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_assoc_array_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_assoc_array_fixture;

            extern(C) int dependencyCountEntries(int[string] table);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_assoc_array_fixture;

                unittest {
                    int[string] table;
                    table["a"] = 1;
                    table["b"] = 2;
                    assert(dependencyCountEntries(table) == 2);
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
        interpreted[0].passed.should == false;
        // Honest diagnostic: names the associative array and its type spelling,
        // not missing source (ffi.md §34.3.1 item 0).
        "associative array".should.be in interpreted[0].message;
        "int[string]".should.be in interpreted[0].message;
    }
}


@("dependencyImage.externGsharedGlobalRead.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_gshared_fixture.d");
        writeFile(depPath, q{
            module dep_image_gshared_fixture;

            __gshared int dependencyCounter;

            void bump() {
                dependencyCounter += 1;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_gshared_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_gshared_fixture;

            extern __gshared int dependencyCounter;
            void bump();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_gshared_fixture;

                unittest {
                    bump;
                    bump;
                    assert(dependencyCounter == 2);
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

@("dependencyImage.externGsharedGlobalWrite.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_gshared_write_fixture.d");
        writeFile(depPath, q{
            module dep_image_gshared_write_fixture;

            __gshared int dependencyCounter;

            void bump() {
                dependencyCounter += 1;
            }

            int readCounter() {
                return dependencyCounter;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_gshared_write_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_gshared_write_fixture;

            extern __gshared int dependencyCounter;
            void bump();
            int readCounter();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_gshared_write_fixture;

                unittest {
                    dependencyCounter = 5;
                    assert(readCounter == 5);
                    bump;
                    assert(dependencyCounter == 6);
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


// Pins §35.2b: the dependency image's `static this()` runs when the image is
// dlopened (RTLD_NOW | RTLD_GLOBAL), so `seed` is 42 for both the SystemLinker
// oracle and the Interpreter. The direct `seed` read also exercises the §35.2a
// symbol-read path, proving the ctor's write is visible through the resolved
// symbol.
@("dependencyImage.moduleCtorRanAtDlopen.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_modulector_fixture.d");
        writeFile(depPath, q{
            module dep_image_modulector_fixture;

            __gshared int seed;

            static this() {
                seed = 42;
            }

            int readSeed() {
                return seed;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_modulector_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_modulector_fixture;

            extern __gshared int seed;
            int readSeed();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_modulector_fixture;

                unittest {
                    assert(readSeed == 42);
                    assert(seed == 42);
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


// Pins §35.2: a plain module-level `int` is thread-local by default (STT_TLS)
// in D — the common case for dub-package globals, unlike the minority
// `__gshared`. It crosses the boundary via the same dlsym data-symbol path as
// `__gshared`: the §35.2a predicate matches `extern int` (extern_ set, dataseg,
// no _init) and `dlsym` resolves the STT_TLS symbol to the interpreter thread's
// instance, so reads and write-through both work with no extra code.
@("dependencyImage.tlsGlobalReadWrite.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_tls_fixture.d");
        writeFile(depPath, q{
            module dep_image_tls_fixture;

            int tlsCounter = 100;                 // thread-local by default in D

            void bumpTls() {
                tlsCounter += 1;
            }

            int readTls() {
                return tlsCounter;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_tls_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_tls_fixture;

            extern int tlsCounter;
            void bumpTls();
            int readTls();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_tls_fixture;

                unittest {
                    assert(tlsCounter == 100);
                    tlsCounter = 5;
                    assert(readTls == 5);
                    bumpTls;
                    assert(tlsCounter == 6);
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


// Pins §35.2: an aggregate (struct) native global crosses via the recursive
// marshaller on the same dlsym data-symbol path as a scalar. The read reifies
// the struct `Value` from the symbol's bytes through `unmarshalStruct`, and an
// interpreted field write (`config.width = 7`) composes the `DotVarExp`
// read-modify-write with the §35.2 write branch: `writeLocation` reads the
// receiver from native, rebuilds it with `withStructField`, and recurses onto
// the `VarExp`, pushing the struct bytes back to the symbol. No per-shape code.
@("dependencyImage.structGlobalReadWrite.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_struct_global_fixture.d");
        writeFile(depPath, q{
            module dep_image_struct_global_fixture;

            struct Config { int width; int height; }
            __gshared Config config = Config(80, 25);

            void setConfig(int w, int h) {
                config.width = w;
                config.height = h;
            }

            int configWidth() { return config.width; }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_struct_global_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_struct_global_fixture;

            struct Config { int width; int height; }
            extern __gshared Config config;
            void setConfig(int w, int h);
            int configWidth();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_struct_global_fixture;

                unittest {
                    assert(config.width == 80);
                    assert(config.height == 25);
                    setConfig(3, 4);
                    assert(config.width == 3);
                    assert(config.height == 4);
                    config.width = 7;
                    assert(configWidth == 7);
                    assert(config.height == 4);
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


// Pins §35.2: reading a dynamic-array native global. The slice `{length,ptr}`
// descriptor is reified from the symbol via the same dlsym data-symbol path
// used for scalars — `unmarshalValue`'s `Tarray` case reads `length`, reads
// `ptr`, and copies `length` elements. The image's `static this()` populates
// the slice at dlopen (pinned in an earlier commit). Read only;
// slice-global writeback is a later rung.
@("dependencyImage.sliceGlobalRead.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_slice_global_fixture.d");
        writeFile(depPath, q{
            module dep_image_slice_global_fixture;

            __gshared int[] numbers;

            static this() {
                numbers = [10, 20, 30];
            }

            int total() {
                int s = 0;
                foreach (n; numbers) s += n;
                return s;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_slice_global_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_slice_global_fixture;

            extern __gshared int[] numbers;
            int total();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_slice_global_fixture;

                unittest {
                    assert(total() == 60);        // native sums its slice
                    assert(numbers.length == 3);  // reads {length,ptr}
                    assert(numbers[0] == 10);
                    assert(numbers[1] == 20);
                    assert(numbers[2] == 30);
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

// Pins §35.2: writing a whole new slice into a dynamic-array native global.
// The interpreter's `writeLocation` (VarExp case) routes the assignment
// through the generic `marshalNative` descriptor path: for a `Tarray` it
// allocates a fresh element buffer, writes `{length, ptr=buffer.ptr}` into the
// symbol's 16 bytes, and pins the buffer for the process lifetime (§5). Native
// code then reads the interpreter-written `{length,ptr}` and elements back.
@("dependencyImage.sliceGlobalWriteback.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_slice_write_fixture.d");
        writeFile(depPath, q{
            module dep_image_slice_write_fixture;

            __gshared int[] payload;

            int sumPayload() {
                int s = 0;
                foreach (v; payload) s += v;
                return s;
            }

            size_t payloadLength() {
                return payload.length;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_slice_write_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_slice_write_fixture;

            extern __gshared int[] payload;
            int sumPayload();
            size_t payloadLength();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_slice_write_fixture;

                unittest {
                    payload = [7, 8, 9];          // slice-rebind write-through
                    assert(payloadLength() == 3); // native sees new length
                    assert(sumPayload() == 24);   // native sees new elements
                    payload = [100];              // overwrite with a new slice
                    assert(payloadLength() == 1);
                    assert(sumPayload() == 100);
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


// Pins that native globals of different scalar widths (64-bit int, double,
// unsigned byte, bool) reify correctly through the data-symbol read path
// (ffi.md §35.2).
@("dependencyImage.scalarWidthGlobalRead.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_scalar_width_fixture.d");
        writeFile(depPath, q{
            module dep_image_scalar_width_fixture;

            __gshared long   bigCount    = 5_000_000_000;
            __gshared double ratio       = 1.5;
            __gshared ubyte  flagByte    = 200;
            __gshared bool   enabledFlag = true;
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_scalar_width_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_scalar_width_fixture;

            extern __gshared long   bigCount;
            extern __gshared double ratio;
            extern __gshared ubyte  flagByte;
            extern __gshared bool   enabledFlag;
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_scalar_width_fixture;

                unittest {
                    assert(bigCount == 5_000_000_000); // 64-bit, exceeds int
                    assert(ratio == 1.5);              // double
                    assert(flagByte == 200);           // unsigned byte
                    assert(enabledFlag == true);       // bool
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

// Pins §35.2: a whole-struct rebind assignment (`origin = Point(9, 8)`) to a
// native struct global writes through via `writeLocation`'s VarExp branch +
// `marshalNative`. The target is the `VarExp` of the struct global, so the
// assignment drives the VarExp write branch directly with a struct `Value`,
// distinct from the field-write read-modify-write path (`config.width = 7`,
// a `DotVarExp`) pinned by `structGlobalReadWrite`.
@("dependencyImage.structGlobalRebindWriteback.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_struct_rebind_fixture.d");
        writeFile(depPath, q{
            module dep_image_struct_rebind_fixture;

            struct Point { int x; int y; }
            __gshared Point origin = Point(1, 2);

            int pointX() { return origin.x; }
            int pointY() { return origin.y; }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_struct_rebind_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_struct_rebind_fixture;

            struct Point { int x; int y; }
            extern __gshared Point origin;
            int pointX();
            int pointY();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_struct_rebind_fixture;

                unittest {
                    assert(pointX() == 1);  // native reads its initializer
                    origin = Point(9, 8);   // WHOLE-struct rebind write-through
                    assert(pointX() == 9);  // native sees the rebind
                    assert(pointY() == 8);
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

// Pins §35.2: reading a static-array (Tsarray) native global. A
// `__gshared int[4]` stores its elements INLINE in the symbol (no
// {length,ptr} descriptor), so the data-symbol path reifies the inline
// element bytes through `unmarshalValue`'s `Tsarray` case. This is distinct
// from the dynamic-slice descriptor case pinned by `sliceGlobalRead`.
@("dependencyImage.staticArrayGlobalRead.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_static_array_global_fixture.d");
        writeFile(depPath, q{
            module dep_image_static_array_global_fixture;

            __gshared int[4] grid = [11, 22, 33, 44];

            int gridAt(int i) { return grid[i]; }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_static_array_global_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_static_array_global_fixture;

            extern __gshared int[4] grid;
            int gridAt(int i);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_static_array_global_fixture;

                unittest {
                    assert(grid.length == 4);  // static-array length is compile-time
                    assert(grid[0] == 11);     // interpreter reads inline elements
                    assert(grid[3] == 44);
                    assert(gridAt(2) == 33);   // native reads its static-array global
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

// Pins §35.2 and §34.11: reading a struct-with-slice-field native global. The
// recursive marshaller reifies the nested `{length,ptr}` field from the
// symbol's struct bytes: `unmarshalNative` -> `unmarshalStruct` recurses into
// the `string` field just as §34.11's by-value nested-slice struct crossing
// does, but here the struct comes from the data-symbol read path. The string
// field points at a literal in rodata that survives for the process. Read only.
@("dependencyImage.nestedStructGlobalRead.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_nested_struct_global_fixture.d");
        writeFile(depPath, q{
            module dep_image_nested_struct_global_fixture;

            struct Named { string label; int id; }
            __gshared Named entry = Named("hello", 7);

            size_t labelLength() { return entry.label.length; }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_nested_struct_global_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_nested_struct_global_fixture;

            struct Named { string label; int id; }
            extern __gshared Named entry;
            size_t labelLength();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_nested_struct_global_fixture;

                unittest {
                    assert(entry.id == 7);           // scalar field
                    assert(entry.label == "hello");  // slice field reified by
                                                     // recursing into the struct
                    assert(entry.label.length == 5);
                    assert(labelLength() == 5);      // native reads its own
                                                     // nested global
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

// Pins §35.2 cross-image dependency-image initialization ordering: A's module
// ctor runs before B's because images load in list order under RTLD_GLOBAL, so
// B's ctor (which reads A's shared `seedBase`) sees A's initialized value.
// Image B references A's symbol as an undefined extern, resolved at load time
// through RTLD_GLOBAL. The shared global is `extern(C)` so both images agree on
// the symbol name `seedBase`; a plain extern(D) global mangles the module name
// in (`_D21dep_image_ctororder_a...` vs `..._b...`), so B's reference would not
// resolve to A's definition. First multi-image fixture.
@("dependencyImage.crossImageCtorOrdering.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";

        const depAPath =
            buildPath(importPath, "dep_image_ctororder_a.d");
        writeFile(depAPath, q{
            module dep_image_ctororder_a;

            extern(C) __gshared int seedBase;

            static this() {
                seedBase = 10;
            }
        });
        const imageAPath = buildSharedLibrary(
            sandbox,
            "dep_image_ctororder_a",
            [depAPath],
        );

        const depBPath =
            buildPath(importPath, "dep_image_ctororder_b.d");
        writeFile(depBPath, q{
            module dep_image_ctororder_b;

            extern(C) extern __gshared int seedBase;
            __gshared int seedDerived;

            static this() {
                seedDerived = seedBase + 5;
            }

            int readDerived() {
                return seedDerived;
            }
        });
        const imageBPath = buildSharedLibrary(
            sandbox,
            "dep_image_ctororder_b",
            [depBPath],
        );

        writeFile(depBPath, q{
            module dep_image_ctororder_b;

            int readDerived();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ctororder_b;

                unittest {
                    assert(readDerived() == 15);  // B's ctor ran after A's:
                                                  // 10 + 5
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imageAPath, imageBPath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imageAPath, imageBPath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// Pins §35.2 DT_NEEDED-driven dependency-image initialization ordering: the
// caller only names image B. B has a dynamic-loader dependency on A, so dlopen(B)
// must load A first, run A's module ctor, then run B's module ctor.
@("dependencyImage.dtNeededCtorOrdering.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;
    import std.process: execute;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";

        const depAPath = buildPath(importPath, "dep_image_dtneeded_a.d");
        writeFile(depAPath, q{
            module dep_image_dtneeded_a;

            extern(C) __gshared int dtNeededSeed;

            static this() {
                dtNeededSeed = 20;
            }
        });
        const imageAPath = buildSharedLibrary(
            sandbox,
            "dep_image_dtneeded_a",
            [depAPath],
        );

        const depBPath = buildPath(importPath, "dep_image_dtneeded_b.d");
        writeFile(depBPath, q{
            module dep_image_dtneeded_b;

            extern(C) extern __gshared int dtNeededSeed;
            __gshared int derived;

            static this() {
                derived = dtNeededSeed + 4;
            }

            int readDerived() {
                return derived;
            }
        });

        const imageBPath =
            inSandboxPath("libdep_image_dtneeded_b.so");
        const buildB = execute([
            "dmd",
            "-shared",
            "-fPIC",
            "-defaultlib=libphobos2.so",
            "-of=" ~ imageBPath,
            inSandboxPath(depBPath),
            imageAPath,
        ]);
        buildB.status.should == 0;

        writeFile(depBPath, q{
            module dep_image_dtneeded_b;

            int readDerived();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_dtneeded_b;

                unittest {
                    assert(readDerived() == 24);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imageBPath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imageBPath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// Pins §35.2 TLS through a DT_NEEDED dependency image: the caller only loads
// image B, but B depends on image A. A owns a default thread-local D global;
// interpreted direct reads/writes and native B calls must all observe the same
// TLS instance after dlopen(B) loads A.
@("dependencyImage.dtNeededTlsGlobalReadWrite.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;
    import std.process: execute;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";

        const depAPath = buildPath(importPath, "dep_image_dtneeded_tls_a.d");
        writeFile(depAPath, q{
            module dep_image_dtneeded_tls_a;

            int dtNeededTlsCounter = 30;
        });
        const imageAPath = buildSharedLibrary(
            sandbox,
            "dep_image_dtneeded_tls_a",
            [depAPath],
        );

        const depBPath = buildPath(importPath, "dep_image_dtneeded_tls_b.d");
        writeFile(depBPath, q{
            module dep_image_dtneeded_tls_b;

            import dep_image_dtneeded_tls_a: dtNeededTlsCounter;

            int readTlsFromB() {
                return dtNeededTlsCounter;
            }

            void bumpTlsFromB() {
                dtNeededTlsCounter += 2;
            }
        });

        const imageBPath = inSandboxPath("libdep_image_dtneeded_tls_b.so");
        const buildB = execute([
            "dmd",
            "-shared",
            "-fPIC",
            "-defaultlib=libphobos2.so",
            "-I=" ~ inSandboxPath(importPath),
            "-of=" ~ imageBPath,
            inSandboxPath(depBPath),
            imageAPath,
        ]);
        buildB.status.should == 0;

        writeFile(depAPath, q{
            module dep_image_dtneeded_tls_a;

            extern int dtNeededTlsCounter;
        });
        writeFile(depBPath, q{
            module dep_image_dtneeded_tls_b;

            int readTlsFromB();
            void bumpTlsFromB();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_dtneeded_tls_a;
                import dep_image_dtneeded_tls_b;

                unittest {
                    assert(dtNeededTlsCounter == 30);
                    assert(readTlsFromB == 30);
                    dtNeededTlsCounter = 7;
                    assert(readTlsFromB == 7);
                    bumpTlsFromB;
                    assert(dtNeededTlsCounter == 9);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imageBPath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const interpreted = (new Interpreter([imageBPath]))
            .runTests(moduleResult.module_);
        interpreted.length.should == 1;
        interpreted[0].passed.should == true;
    }
}

// Pins §35.2: reading a pointer-typed native global. The data-symbol path routes
// through `unmarshalValue`'s `Tpointer` case, reifying `anchorPtr` as a non-null
// native-pointer Value. To exercise the read without interpreted native-pointer
// deref (out of scope, §35.2), the interpreter reads the pointer global and
// passes it to a native callee that dereferences it.
@("dependencyImage.pointerGlobalRead.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_pointer_global_fixture.d");
        writeFile(depPath, q{
            module dep_image_pointer_global_fixture;

            __gshared int anchor = 77;
            __gshared int* anchorPtr = &anchor;

            int derefArg(int* p) { return *p; }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_pointer_global_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_pointer_global_fixture;

            extern __gshared int anchor;
            extern __gshared int* anchorPtr;
            int derefArg(int* p);
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_pointer_global_fixture;

                unittest {
                    assert(anchorPtr !is null);          // pointer global reified
                                                         // as a non-null native
                                                         // pointer
                    assert(derefArg(anchorPtr) == 77);   // interpreter reads the
                                                         // pointer global, passes
                                                         // it to native which
                                                         // derefs it
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

// A native call site only ever catches `Exception` at the FFI boundary
// (ffi/core.d: "Only Exception is caught at the call site; Error stays
// fatal."), so an Error can only reach `nativeExceptionRoot` (interpreter.md
// §9.10) indirectly, via the `.next` chain of a caught Exception (ffi.md
// §34.13's chainedNext recursion follows `.next` regardless of its dynamic
// type). The chained class's fully-qualified name does not match
// "core.exception."/"object." + "Error", so the name-prefix heuristic
// misclassifies it as Exception, and catch(Error) on the rethrown link
// wrongly misses it.
@("dependencyImage.nativeChainedErrorSubclass.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_chained_error_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_chained_error_fixture;

            class DependencyError : Error {
                this(string msg) {
                    super(msg);
                }
            }

            void dependencyThrowChainedError() {
                auto inner = new DependencyError("root cause");
                auto outer = new Exception("outer failure");
                outer.next = inner;
                throw outer;
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_chained_error_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_chained_error_fixture;

            class DependencyError : Error {
                this(string msg);
            }

            void dependencyThrowChainedError();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_chained_error_fixture;

                unittest {
                    try {
                        dependencyThrowChainedError();
                        assert(false);
                    } catch (Exception caught) {
                        assert(caught.msg == "outer failure");
                        try {
                            throw caught.next;
                        } catch (Error rethrown) {
                            assert(rethrown.msg == "root cause");
                        }
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

// A natively-thrown class two levels below Exception (interpreter.md §9.10's
// nativeExceptionRoot defect): the fabricated type-name list jumps straight
// from the thrown class to its root, omitting the intermediate base, so
// catch(DependencyBaseException) wrongly misses a DependencyException.
@("dependencyImage.nativeIntermediateBaseException.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_intermediate_exception_fixture.d",
        );
        writeFile(depPath, q{
            module dep_image_intermediate_exception_fixture;

            class DependencyBaseException : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            class DependencyException : DependencyBaseException {
                this(string msg) {
                    super(msg);
                }
            }

            void dependencyThrowIntermediate() {
                throw new DependencyException("dependency failed");
            }
        });

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_intermediate_exception_fixture",
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_intermediate_exception_fixture;

            class DependencyBaseException : Exception {
                this(string msg);
            }

            class DependencyException : DependencyBaseException {
                this(string msg);
            }

            void dependencyThrowIntermediate();
        });

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_intermediate_exception_fixture;

                unittest {
                    try {
                        dependencyThrowIntermediate();
                        assert(false);
                    } catch (DependencyBaseException caught) {
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
