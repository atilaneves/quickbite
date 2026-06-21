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
