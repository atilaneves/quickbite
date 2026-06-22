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
