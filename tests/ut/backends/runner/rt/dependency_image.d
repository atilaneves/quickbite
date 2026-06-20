module ut.backends.runner.rt.dependency_image;


import ut.backends;


@("dependencyImage.externDFunction.Interpreter")
@Tags("Interpreter")
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;
    import std.process: execute;

    with(immutable Sandbox()) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_fixture.d");
        writeFile(depPath, q{
            module dep_image_fixture;

            int dependencyAdd(int value) {
                return value + 17;
            }
        });

        const imagePath = inSandboxPath("libdep_image_fixture.so");
        const build = execute([
            "dmd",
            "-shared",
            "-fPIC",
            "-defaultlib=libphobos2.so",
            "-of=" ~ imagePath,
            inSandboxPath(depPath),
        ]);
        build.status.should == 0;

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
