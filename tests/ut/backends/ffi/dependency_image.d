module ut.backends.ffi.dependency_image;


import ut.backends;
import dmd.dmodule: Module;


// Give each (fixture, backend) a globally-unique dependency-image module name.
// Every fixture builds its own `.so` and loads it `dlopen(RTLD_GLOBAL)`; the
// image's native writeback is not unloaded, so it leaks into the long-lived
// `bin/ut` parent. Because the `LLVMJit` and `Interpreter` variants of one
// fixture share a module + symbol names, under `--random` ordering a leaked,
// already-mutated image from one variant shadows the other's fresh image
// (RTLD_GLOBAL first-loaded wins), so the fixture reads a stale global and its
// initial-value assert fails. Suffixing the module name with `backend.stringof`
// makes every unittest's D-mangled symbol unique, so no leak can collide.
//
// This is generic identifier rewriting: `base` is any identifier (a module
// name, or an `extern(C)` symbol) rewritten everywhere it appears in `source`
// (declaration, imports, references). Module renaming covers all D-mangled
// symbols; `extern(C)` symbols are unmangled, so the two `extern(C)`
// ctor-ordering globals (`seedBase`, `dtNeededSeed`) are suffixed with a second
// call to keep their variants isolated. The remaining shared-named `extern(C)`
// *functions* are stateless and identical across variants, so they cannot
// carry stale state and are left alone.
private string uniqueDepModule(string source, string base, string suffix) {
    import std.string: replace;
    return source.replace(base, base ~ "_" ~ suffix);
}


// Construct `backend` for a dependency-image fixture, regardless of whether
// its constructor also wants an oracle-style `importPaths` argument
// (`SystemLinker`/`LLVMJit`) or just the link files (`Interpreter`/
// `Bytecode`).
private auto runDependencyImage(alias backend)(
    const string[] linkFiles,
    const string[] importPaths,
    Module module_,
) {
    static if (is(backend == SystemLinker) || is(backend == LLVMJit))
        return (new backend(linkFiles, importPaths)).runTests(module_);
    else
        return (new backend(linkFiles)).runTests(module_);
}

// These fixtures each build their own dependency `.so` by hand and call
// `runDependencyImage!backend` directly instead of going through
// `runBackendSourceFixtureTests`/`Matrix!()`, so `SystemLinker` -- normally
// the oracle every matrix carries automatically -- is not implied here. Each
// fixture below constructs its own `SystemLinker` inline as that oracle
// instead. `Ctfe` is excluded because it cannot `dlopen` a compiled shared
// library at compile time (the same `Because.inexpressible` reason automem's
// `Mallocator`-based fixtures give elsewhere in this suite). `Bytecode` is
// included on purpose even where its dependency boundary does not yet call
// into the compiled image, to characterize its current refusal message.
private alias DependencyImageBackends = AliasSeq!(Interpreter, Bytecode, LLVMJit);

// A dependency is compiled under its own compiler flags. Enabling DIP1000 for
// the importing project cannot retroactively reject a dependency method that
// was already compiled without it; calls resolve to the dependency image.
static foreach (backend; DependencyImageBackends) {
@("dependencyImage.projectPreviewDoesNotReanalyseDependencyBody." ~
    backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler:
        FrontendFlags,
        parseRootModules;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const moduleName =
            "dep_image_project_preview_fixture_" ~ backend.stringof;
        const dependencyPath = buildPath(importPath, moduleName ~ ".d");
        writeFile(dependencyPath, q{
            module dep_image_project_preview_fixture;

            struct ByteRange {
                void* pointer;
                size_t length;
            }

            struct Ranges {
                ByteRange[] entries;

                bool discard(void[] bytes) scope @safe {
                    import std.algorithm: remove;

                    bool matches(ByteRange other) {
                        return other.pointer == bytes.ptr &&
                            other.length == bytes.length;
                    }

                    entries = entries.remove!matches;
                    return true;
                }
            }
        }.uniqueDepModule(
            "dep_image_project_preview_fixture",
            backend.stringof,
        ));

        const imagePath = buildSharedLibrary(
            sandbox,
            moduleName,
            [dependencyPath],
        );

        const projectPath = buildPath("project", "fixture.d");
        writeFile(projectPath, q{
            module root_preview_fixture;

            import dep_image_project_preview_fixture;

            unittest {
                ubyte[2] first;
                ubyte[3] second;
                auto ranges = Ranges([
                    ByteRange(first.ptr, first.length),
                    ByteRange(second.ptr, second.length),
                ]);
                assert(ranges.discard(first[]));
                assert(ranges.entries.length == 1);
                assert(ranges.entries[0].pointer == second.ptr);
            }
        }.uniqueDepModule(
            "dep_image_project_preview_fixture",
            backend.stringof,
        ).uniqueDepModule(
            "root_preview_fixture",
            backend.stringof,
        ));

        auto moduleResult = parseRootModules(
            [inSandboxPath(projectPath)],
            [inSandboxPath(importPath)],
            FrontendFlags(["-preview=dip1000"]),
        )[0];

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        static if (is(backend == Bytecode)) {
            // Bytecode's dependency boundary currently refuses the lazily
            // rejected source body instead of calling the compiled image.
            actual[0].passed.should == false;
            actual[0].message.should ==
                "Unsupported statement in bytecode core: Error";
        } else
            actual[0].passed.should == true;
    }
}
}


// Mutating a dependency struct through a pointer runs against the pointed-to
// object. If a later dependency method must execute from the compiled image,
// it must receive that same object, including slice fields changed by the
// interpreted method.
static foreach (backend; DependencyImageBackends) {
@("dependencyImage.nativeMethodSeesInterpretedPointerReceiverState." ~
    backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler:
        FrontendFlags,
        parseRootModules;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const moduleName =
            "dep_image_pointer_receiver_fixture_" ~ backend.stringof;
        const dependencyPath = buildPath(importPath, moduleName ~ ".d");
        writeFile(dependencyPath, q{
            module dep_image_pointer_receiver_fixture;

            struct ByteRange {
                void* pointer;
                size_t length;
            }

            struct Ranges {
                ByteRange[] entries;

                void remember(void* pointer, size_t length) scope @safe {
                    entries ~= ByteRange(pointer, length);
                }

                bool discard(void[] bytes) scope @safe {
                    import std.algorithm: remove;

                    bool matches(ByteRange other) {
                        return other.pointer == bytes.ptr &&
                            other.length == bytes.length;
                    }

                    entries = entries.remove!matches;
                    return true;
                }
            }
        }.uniqueDepModule(
            "dep_image_pointer_receiver_fixture",
            backend.stringof,
        ));

        const imagePath = buildSharedLibrary(
            sandbox,
            moduleName,
            [dependencyPath],
        );

        const projectPath = buildPath("project", "fixture.d");
        writeFile(projectPath, q{
            module root_pointer_receiver_fixture;

            import dep_image_pointer_receiver_fixture;

            unittest {
                ubyte[2] first;
                ubyte[3] second;
                Ranges ranges;
                auto pointer = &ranges;
                pointer.remember(first.ptr, first.length);
                pointer.remember(second.ptr, second.length);
                assert(pointer.entries.length == 2);
                assert(pointer.discard(first[]));
                assert(pointer.entries.length == 1);
                assert(pointer.entries[0].pointer == second.ptr);
            }
        }.uniqueDepModule(
            "dep_image_pointer_receiver_fixture",
            backend.stringof,
        ).uniqueDepModule(
            "root_pointer_receiver_fixture",
            backend.stringof,
        ));

        auto moduleResult = parseRootModules(
            [inSandboxPath(projectPath)],
            [inSandboxPath(importPath)],
            FrontendFlags(["-preview=dip1000"]),
        )[0];

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        static if (is(backend == Bytecode)) {
            // Bytecode's dependency boundary currently refuses the lazily
            // rejected source body instead of calling the compiled image.
            actual[0].passed.should == false;
            actual[0].message.should ==
                "Unsupported statement in bytecode core: Error";
        } else
            actual[0].passed.should == true;
    }
}
}


// A local declared inside a try statement is destroyed before control leaves
// that statement. If its dependency-image destructor throws, the following
// catch handles that exception just as it handles one thrown by the body.
static foreach (backend; DependencyImageBackends) {
@("dependencyImage.nativeDestructorExceptionIsCaughtAtTryScopeExit." ~
    backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const moduleName =
            "dep_image_destructor_exception_fixture_" ~ backend.stringof;
        const dependencyPath = buildPath(importPath, moduleName ~ ".d");
        writeFile(dependencyPath, q{
            module dep_image_destructor_exception_fixture;

            struct Resource {
                ~this() {
                    assert(false, "expected destructor failure");
                }
            }
        }.uniqueDepModule(
            "dep_image_destructor_exception_fixture",
            backend.stringof,
        ));

        const imagePath = buildSharedLibrary(
            sandbox,
            moduleName,
            [dependencyPath],
        );

        writeFile(dependencyPath, q{
            module dep_image_destructor_exception_fixture;

            struct Resource {
                ~this();
            }
        }.uniqueDepModule(
            "dep_image_destructor_exception_fixture",
            backend.stringof,
        ));

        auto moduleResult = parseSnippetWithCheckActionContext(q{
            import core.exception: AssertError;
            import dep_image_destructor_exception_fixture;

            unittest {
                bool caught;
                try {
                    Resource resource;
                } catch (AssertError) {
                    caught = true;
                }
                assert(caught);
            }
        }.uniqueDepModule(
            "dep_image_destructor_exception_fixture",
            backend.stringof,
        ), [inSandboxPath(importPath)]);

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        static if (is(backend == Bytecode)) {
            // Bytecode reaches the native destructor, but reports its
            // exception as an uncaught test failure.
            actual[0].passed.should == false;
            actual[0].message.should == "expected destructor failure";
        } else
            actual[0].passed.should == true;
    }
}
}


private struct CtorOrderingFixture {
    string[] imagePaths;
    string[] importPaths;
    Module module_;
}

private CtorOrderingFixture buildCtorOrderingFixture(
    in Sandbox sandbox,
    in string suffix,
) {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    with(sandbox) {
        const importPath = "imports";

        const depAPath = buildPath(importPath, "dep_image_ctororder_a_" ~ suffix ~ ".d");
        writeFile(depAPath, q{
            module dep_image_ctororder_a;

            extern(C) __gshared int seedBase;

            static this() {
                seedBase = 10;
            }
        }.uniqueDepModule("dep_image_ctororder_a", suffix)
         .uniqueDepModule("seedBase", suffix));
        const imageAPath = buildSharedLibrary(
            sandbox,
            "dep_image_ctororder_a_" ~ suffix,
            [depAPath],
        );

        const depBPath = buildPath(importPath, "dep_image_ctororder_b_" ~ suffix ~ ".d");
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
        }.uniqueDepModule("dep_image_ctororder_b", suffix)
         .uniqueDepModule("seedBase", suffix));
        const imageBPath = buildSharedLibrary(
            sandbox,
            "dep_image_ctororder_b_" ~ suffix,
            [depBPath],
        );

        writeFile(depBPath, q{
            module dep_image_ctororder_b;

            int readDerived();
        }.uniqueDepModule("dep_image_ctororder_b", suffix));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ctororder_b;

                unittest {
                    assert(readDerived() == 15);  // B's ctor ran after A's:
                                                  // 10 + 5
                }
            }.uniqueDepModule("dep_image_ctororder_b", suffix),
            [inSandboxPath(importPath)],
        );

        return CtorOrderingFixture(
            [imageAPath, imageBPath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
    }
}

// Every fixture below builds its own dependency `.so` and constructs a
// `SystemLinker` inline as the oracle its result is compared against. The
// `SystemLinker` row therefore runs compiled code against itself, which checks
// the fixture's own scaffolding -- that the image builds, loads, and answers --
// independently of whichever backend is under test.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call a native dependency image"),
    Omit!(Bytecode, Because.unconfirmed,
        "calls into a dependency image for plain function arguments and " ~
        "returns, but not for member functions, class and interface " ~
        "dispatch, delegates, exceptions or module-level variables: those " ~
        "read wrong values or crash"),
)) {
@("dependencyImage.externDFunction." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_fixture;

            int dependencyAdd(int value) {
                return value + 17;
            }
        }.uniqueDepModule("dep_image_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_fixture;

            int dependencyAdd(int value);
        }.uniqueDepModule("dep_image_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_fixture;

                unittest {
                    int value = 25;
                    assert(dependencyAdd(value) == 42);
                }
            }.uniqueDepModule("dep_image_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


@("dependencyImage.externDTwoArgumentFunction." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_order_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_order_fixture;

            int dependencySub(int a, int b) {
                return a - b;
            }
        }.uniqueDepModule("dep_image_order_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_order_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_order_fixture;

            int dependencySub(int a, int b);
        }.uniqueDepModule("dep_image_order_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_order_fixture;

                unittest {
                    int left = 10;
                    int right = 3;
                    assert(dependencySub(left, right) == 7);
                }
            }.uniqueDepModule("dep_image_order_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

static if (is(backend == Interpreter)) {
@("dependencyImage.ldcExternDCompilerAbi")
@Tags(Interpreter.stringof)
unittest {
    import quickbite.ffi.ffi: CompilerAbi, DependencyImage;
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;
    import std.process: execute;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_ldc_order_fixture.d");
        writeFile(depPath, q{
            module dep_image_ldc_order_fixture;

            int dependencyDifference(int left, int right) {
                return left - right;
            }
        });

        const dmdImagePath = buildSharedLibrary(
            sandbox,
            "dep_image_dmd_order_oracle",
            [depPath],
        );
        const ldcImagePath = inSandboxPath("libdep_image_ldc_order_fixture.so");
        const ldcBuild = execute([
            "ldc2",
            "-shared",
            "-relocation-model=pic",
            "-link-defaultlib-shared",
            "-of=" ~ ldcImagePath,
            inSandboxPath(depPath),
        ]);
        ldcBuild.status.should == 0;

        writeFile(depPath, q{
            module dep_image_ldc_order_fixture;

            int dependencyDifference(int left, int right);
        });
        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ldc_order_fixture;

                unittest {
                    int left = 10;
                    int right = 3;
                    assert(dependencyDifference(left, right) == 7);
                }
            },
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [dmdImagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = (new Interpreter([
            DependencyImage(ldcImagePath, CompilerAbi.ldc),
        ])).runTests(moduleResult.module_);
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}
}
@("dependencyImage.externDStringArgumentFunction." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_string_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_string_fixture;

            int dependencyStringScore(string value) {
                return cast(int) value.length * 10 + value[0];
            }
        }.uniqueDepModule("dep_image_string_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_string_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_string_fixture;

            int dependencyStringScore(string value);
        }.uniqueDepModule("dep_image_string_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_string_fixture;

                unittest {
                    string value = "abc";
                    assert(dependencyStringScore(value) == 127);
                }
            }.uniqueDepModule("dep_image_string_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}
@("dependencyImage.externDStringReturnFunction." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_string_return_fixture_" ~ backend.stringof ~ ".d",
        );
        writeFile(depPath, q{
            module dep_image_string_return_fixture;

            string dependencyGreeting() {
                return "quickbite";
            }
        }.uniqueDepModule("dep_image_string_return_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_string_return_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_string_return_fixture;

            string dependencyGreeting();
        }.uniqueDepModule("dep_image_string_return_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_string_return_fixture;

                unittest {
                    string value = dependencyGreeting();
                    assert(value == "quickbite");
                }
            }.uniqueDepModule("dep_image_string_return_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externDRefReturn." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_ref_return_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_ref_return_fixture;

            private int stored = 41;

            ref int dependencySlot() {
                return stored;
            }
        }.uniqueDepModule("dep_image_ref_return_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_ref_return_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_ref_return_fixture;

            ref int dependencySlot();
        }.uniqueDepModule("dep_image_ref_return_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ref_return_fixture;

                unittest {
                    assert(dependencySlot == 41);

                    dependencySlot = 42;
                    assert(dependencySlot == 42);
                }
            }.uniqueDepModule("dep_image_ref_return_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A `ref`-returning member function yields the receiver's own field, not a
// copy of it. Assigning through the call writes that field, and a later read
// of the same call observes the write.
@("dependencyImage.externDMemberRefReturn." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_member_ref_return_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_member_ref_return_fixture;

            struct Holder {
                private int stored;

                this(int value) {
                    stored = value;
                }

                ref int slot() {
                    return stored;
                }
            }
        }.uniqueDepModule("dep_image_member_ref_return_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_member_ref_return_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_member_ref_return_fixture;

            struct Holder {
                private int stored;

                this(int value);
                ref int slot();
            }
        }.uniqueDepModule("dep_image_member_ref_return_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_member_ref_return_fixture;

                unittest {
                    auto holder = Holder(41);
                    assert(holder.slot == 41);

                    holder.slot = 42;
                    assert(holder.slot == 42);
                }
            }.uniqueDepModule("dep_image_member_ref_return_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externDTypedSliceFunction." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_typed_slice_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_typed_slice_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_typed_slice_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_typed_slice_fixture;

            long dependencySum(const(long)[] values);
            const(int)[] dependencyTriple(int value);
        }.uniqueDepModule("dep_image_typed_slice_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_typed_slice_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externDStackSpillFunction." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_stack_spill_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_stack_spill_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_stack_spill_fixture_" ~ backend.stringof,
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
        }.uniqueDepModule("dep_image_stack_spill_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_stack_spill_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externDMemberFunction." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_member_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_member_fixture;

            struct Counter {
                int value;

                int read() const {
                    return value + 17;
                }
            }
        }.uniqueDepModule("dep_image_member_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_member_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_member_fixture;

            struct Counter {
                int value;
                int read() const;
            }
        }.uniqueDepModule("dep_image_member_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_member_fixture;

                unittest {
                    Counter counter = Counter(25);
                    assert(counter.read == 42);
                }
            }.uniqueDepModule("dep_image_member_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A struct that is a field of a class object is one object, not a copy of
// one. Calling a member function on it lets that function write the field's
// own members, and a later read of the field observes those writes.
@("dependencyImage.externDMemberFunctionOnClassField." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_class_field_fixture_" ~ backend.stringof ~ ".d",
        );
        writeFile(depPath, q{
            module dep_image_class_field_fixture;

            struct Tracker {
                int[] entries;

                void dropFirst() {
                    entries = entries[1 .. $];
                }
            }
        }.uniqueDepModule("dep_image_class_field_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_class_field_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_class_field_fixture;

            struct Tracker {
                int[] entries;
                void dropFirst();
            }
        }.uniqueDepModule("dep_image_class_field_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_class_field_fixture;

                class Holder {
                    Tracker tracker;

                    void dropFirstEntry() {
                        tracker.dropFirst;
                    }
                }

                unittest {
                    auto holder = new Holder;
                    holder.tracker.entries = [10, 20, 30];

                    holder.dropFirstEntry;

                    assert(holder.tracker.entries.length == 2);
                    assert(holder.tracker.entries[0] == 20);
                }
            }.uniqueDepModule("dep_image_class_field_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externDMemberFunctionWithArguments." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_member_args_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_member_args_fixture;

            struct Counter {
                int value;

                int addSub(int addend, int subtrahend) const {
                    return value + addend - subtrahend;
                }
            }
        }.uniqueDepModule("dep_image_member_args_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_member_args_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_member_args_fixture;

            struct Counter {
                int value;
                int addSub(int addend, int subtrahend) const;
            }
        }.uniqueDepModule("dep_image_member_args_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_member_args_fixture;

                unittest {
                    Counter counter = Counter(25);
                    int addend = 20;
                    int subtrahend = 3;
                    assert(counter.addSub(addend, subtrahend) == 42);
                }
            }.uniqueDepModule("dep_image_member_args_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A 32-byte struct returned by value from an `extern(D)` dependency-image
// function. On x86-64 a value that large cannot come back in registers, so the
// callee writes it through a hidden pointer into the caller's storage; every
// field must still read back exactly as the callee computed it. The asymmetric
// field expressions (`first - second`, `first * second`) additionally make a
// swapped argument pair observable, which matters for `extern(D)` because DMD
// and LDC pass explicit D arguments in opposite orders.
@("dependencyImage.externDLargeStructReturn." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_struct_return_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_struct_return_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_struct_return_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_struct_return_fixture;

            struct Quad { long a; long b; long c; long d; }
            Quad dependencyQuad(int first, int second);
        }.uniqueDepModule("dep_image_struct_return_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_struct_return_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.nativeException." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_exception_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_exception_fixture;

            void dependencyThrow() {
                throw new Exception("dependency failed");
            }
        }.uniqueDepModule("dep_image_exception_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_exception_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_exception_fixture;

            void dependencyThrow();
        }.uniqueDepModule("dep_image_exception_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_exception_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.nativeCustomException." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_custom_exception_fixture_" ~ backend.stringof ~ ".d",
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
        }.uniqueDepModule("dep_image_custom_exception_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_custom_exception_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_custom_exception_fixture;

            class DependencyException: Exception {
                this(string msg);
            }

            void dependencyThrowCustom();
        }.uniqueDepModule("dep_image_custom_exception_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_custom_exception_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.nativeCustomExceptionField." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_custom_exception_field_fixture_" ~ backend.stringof ~ ".d",
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
        }.uniqueDepModule("dep_image_custom_exception_field_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_custom_exception_field_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_custom_exception_field_fixture;

            class DependencyException: Exception {
                int code;
                this(string msg, int code);
            }

            void dependencyThrowCustomField();
        }.uniqueDepModule("dep_image_custom_exception_field_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_custom_exception_field_fixture;

                unittest {
                    try {
                        dependencyThrowCustomField();
                        assert(false);
                    } catch (DependencyException caught) {
                        DependencyException* caughtAddress = &caught;

                        assert(*caughtAddress is caught);
                        assert(caught.msg == "dependency failed");
                        assert(caught.code == 73);
                    }
                }
            }.uniqueDepModule("dep_image_custom_exception_field_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.nativeCustomExceptionFieldViaBaseCatch." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_custom_exception_base_catch_fixture_" ~ backend.stringof ~ ".d",
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
        }.uniqueDepModule("dep_image_custom_exception_base_catch_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_custom_exception_base_catch_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_custom_exception_base_catch_fixture;

            class DependencyException: Exception {
                int code;
                this(string msg, int code);
            }

            void dependencyThrowCustomField();
        }.uniqueDepModule("dep_image_custom_exception_base_catch_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_custom_exception_base_catch_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.nativeCustomExceptionFieldAcrossHelperCatch." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_custom_exception_helper_catch_fixture_" ~ backend.stringof ~ ".d",
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
        }.uniqueDepModule("dep_image_custom_exception_helper_catch_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_custom_exception_helper_catch_fixture_" ~ backend.stringof,
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
        }.uniqueDepModule("dep_image_custom_exception_helper_catch_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_custom_exception_helper_catch_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.nativeChainedException." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_chained_exception_fixture_" ~ backend.stringof ~ ".d",
        );
        writeFile(depPath, q{
            module dep_image_chained_exception_fixture;

            void dependencyThrowChained() {
                auto inner = new Exception("inner failure");
                auto outer = new Exception("outer failure");
                outer.next = inner;
                throw outer;
            }
        }.uniqueDepModule("dep_image_chained_exception_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_chained_exception_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_chained_exception_fixture;

            void dependencyThrowChained();
        }.uniqueDepModule("dep_image_chained_exception_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_chained_exception_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externCVariadic." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_variadic_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_variadic_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_variadic_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_variadic_fixture;

            extern(C) int dependencyCombine(int count, ...);
        }.uniqueDepModule("dep_image_variadic_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_variadic_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// C default argument promotions on the variadic tail: a char argument must
// arrive as int and a float as double (ffi_prep_cif_var rejects unpromoted
// small-int/float variadic types), whether the frontend promotes at the call
// site or the bridge has to.
@("dependencyImage.externCVariadicPromotion." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_variadic_promotion_fixture_" ~ backend.stringof ~ ".d",
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
        }.uniqueDepModule("dep_image_variadic_promotion_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_variadic_promotion_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_variadic_promotion_fixture;

            extern(C) int dependencyPromote(int count, ...);
        }.uniqueDepModule("dep_image_variadic_promotion_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_variadic_promotion_fixture;

                unittest {
                    char letter = 'a';
                    float fraction = 2.5;
                    assert(dependencyPromote(2, letter, fraction) == 9725);
                }
            }.uniqueDepModule("dep_image_variadic_promotion_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externCppFunctionAndMember." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_cpp_fixture_" ~ backend.stringof ~ ".d");
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

                void add(int amount) {
                    value += amount;
                }
            }
        }.uniqueDepModule("dep_image_cpp_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_cpp_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_cpp_fixture;

            extern(C++) int dependencyCppSub(int a, int b);

            extern(C++) struct CppCounter {
                int value;
                int combine(int x, int y);
                void add(int amount);
            }
        }.uniqueDepModule("dep_image_cpp_fixture", backend.stringof));

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

                    struct Holder {
                        CppCounter counter;
                    }

                    Holder holder = Holder(CppCounter(7));
                    holder.counter.add(5);
                    assert(holder.counter.combine(x, y) == 1223);
                }
            }.uniqueDepModule("dep_image_cpp_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externDMutatingMember." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_mutating_member_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_mutating_member_fixture;

            struct Counter {
                int value;

                void bump(int by) {
                    value += by;
                }
            }
        }.uniqueDepModule("dep_image_mutating_member_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_mutating_member_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_mutating_member_fixture;

            struct Counter {
                int value;
                void bump(int by);
            }
        }.uniqueDepModule("dep_image_mutating_member_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_mutating_member_fixture;

                unittest {
                    Counter counter = Counter(25);
                    int by = 5;
                    counter.bump(by);
                    assert(counter.value == 30);
                }
            }.uniqueDepModule("dep_image_mutating_member_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externDMutableSliceWriteback." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_mutable_slice_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_mutable_slice_fixture;

            void dependencyFill(int[] xs, int value) {
                foreach (ref x; xs)
                    x = value;
            }
        }.uniqueDepModule("dep_image_mutable_slice_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_mutable_slice_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_mutable_slice_fixture;

            void dependencyFill(int[] xs, int value);
        }.uniqueDepModule("dep_image_mutable_slice_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_mutable_slice_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A by-value struct with a `string` field, crossing in both directions. The
// struct is not a flat block of scalars — one of its fields is itself a
// `{length, ptr}` descriptor — so `dependencyScore` reaches 407 only if it sees
// both the four characters of `name` and the `int` beside them, and the
// `Tagged` it returns must carry a readable `name` back out with its `id`.
@("dependencyImage.externDNestedSliceStruct." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_nested_slice_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_nested_slice_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_nested_slice_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_nested_slice_fixture;

            struct Tagged { string name; int id; }
            int dependencyScore(Tagged tagged);
            Tagged dependencyTag(int id);
        }.uniqueDepModule("dep_image_nested_slice_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_nested_slice_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A by-value struct whose first field is a static array. `int[4]` stores its
// four elements inline rather than behind a pointer, so passing `Fixed` by
// value hands the callee five ints in one block: the sum 146 is reachable only
// if every element and the trailing `tag` arrive where the callee reads them.
@("dependencyImage.externDStaticArrayField." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_static_array_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_static_array_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_static_array_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_static_array_fixture;

            struct Fixed {
                int[4] values;
                int tag;
            }
            int dependencyFixedSum(Fixed fixed);
        }.uniqueDepModule("dep_image_static_array_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_static_array_fixture;

                unittest {
                    int base = 10;
                    Fixed fixed = Fixed([base, base + 1, base + 2, base + 3], 100);
                    assert(dependencyFixedSum(fixed) == 146);
                }
            }.uniqueDepModule("dep_image_static_array_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externCScalarOutParameter." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_out_param_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_out_param_fixture;

            extern(C) void dependencyDouble(int* result, int value) {
                *result = value * 2;
            }
        }.uniqueDepModule("dep_image_out_param_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_out_param_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_out_param_fixture;

            extern(C) void dependencyDouble(int* result, int value);
        }.uniqueDepModule("dep_image_out_param_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_out_param_fixture;

                unittest {
                    int value = 21;
                    int result;
                    dependencyDouble(&result, value);
                    assert(result == 42);
                }
            }.uniqueDepModule("dep_image_out_param_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// An in-out scalar parameter: `dependencyBump(&value)` hands the callee the
// address of the caller's own `int`, and `*value += 1` reads that storage
// before writing to it. Both directions therefore have to work — a call that
// only carried the result back out would still leave `value` at 1, not 42.
@("dependencyImage.externCInOutScalarParameter." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_inout_param_fixture_" ~ backend.stringof ~ ".d",
        );
        writeFile(depPath, q{
            module dep_image_inout_param_fixture;

            extern(C) void dependencyBump(int* value) {
                *value += 1;
            }
        }.uniqueDepModule("dep_image_inout_param_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_inout_param_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_inout_param_fixture;

            extern(C) void dependencyBump(int* value);
        }.uniqueDepModule("dep_image_inout_param_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_inout_param_fixture;

                unittest {
                    int value = 41;
                    dependencyBump(&value);
                    assert(value == 42);
                }
            }.uniqueDepModule("dep_image_inout_param_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// A `const(char)**` parameter the callee reads through. The extra level of
// indirection does not make it an output slot: `&word` designates the caller's
// own pointer variable, and the callee dereferences it, so the pointer already
// stored there has to reach `dependencyFirstLength`. The callee null-checks, so
// a pointer that did not arrive shows up as -1 rather than as a crash.
@("dependencyImage.externCPointerToPointerInput." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_ptr_ptr_in_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_ptr_ptr_in_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_ptr_ptr_in_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_ptr_ptr_in_fixture;

            extern(C) const(char)* dependencyWord();
            extern(C) int dependencyFirstLength(const(char)** words);
        }.uniqueDepModule("dep_image_ptr_ptr_in_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ptr_ptr_in_fixture;

                unittest {
                    const(char)* word = dependencyWord();
                    assert(dependencyFirstLength(&word) == 5);
                }
            }.uniqueDepModule("dep_image_ptr_ptr_in_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// A union crossing the boundary by value: DMD lays the fields out overlapped,
// but ffiStructType walks them as if sequential, so libffi's computed size
// disagrees with DMD's and the layout cross-check assert kills the call
// instead of either calling correctly or falling back gracefully.
@("dependencyImage.externCUnionReturn." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_union_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_union_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_union_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_union_fixture;

            union Overlay {
                int number;
                float precise;
            }

            extern(C) Overlay dependencyOverlay();
        }.uniqueDepModule("dep_image_union_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_union_fixture;

                unittest {
                    Overlay overlay = dependencyOverlay();
                    assert(overlay.number == 42);
                }
            }.uniqueDepModule("dep_image_union_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// A delegate crossing the boundary as a RETURN value rather than as an
// argument. A D delegate is a `{context, funcptr}` pair, so both halves have to
// survive the return: `adder()` yields 42 only if calling the returned delegate
// reaches the dependency image's closure body with the `base` it captured.
@("dependencyImage.externDDelegateReturn." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_delegate_return_fixture_" ~ backend.stringof ~ ".d",
        );
        writeFile(depPath, q{
            module dep_image_delegate_return_fixture;

            int delegate() dependencyMakeAdder(int base) {
                return () => base + 1;
            }
        }.uniqueDepModule("dep_image_delegate_return_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_delegate_return_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_delegate_return_fixture;

            int delegate() dependencyMakeAdder(int base);
        }.uniqueDepModule("dep_image_delegate_return_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_delegate_return_fixture;

                unittest {
                    int delegate() adder = dependencyMakeAdder(41);
                    assert(adder() == 42);
                }
            }.uniqueDepModule("dep_image_delegate_return_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// A dependency-image class with a virtual method and a subclass override: the
// factory returns a base `Widget` reference to a derived `Button`, and the call
// must dispatch through the object's vtable to the override rather than to the
// statically-resolved base method.
@("dependencyImage.externDClassVirtualDispatch." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_widget_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_widget_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_widget_fixture_" ~ backend.stringof,
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
        }.uniqueDepModule("dep_image_widget_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_widget_fixture;

                unittest {
                    Widget w = makeButton();
                    assert(w.draw() == 42);
                }
            }.uniqueDepModule("dep_image_widget_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A dependency-image interface method call dispatched through the interface
// table: the factory returns a `Drawable` interface reference to a `Button`,
// and the call must dispatch through the object's interface table to the
// implementation. `draw` reads an instance field, so a wrong `this`
// (interface pointer not adjusted back to the object base) returns the wrong
// value — that itable `this`-adjustment is what distinguishes interfaces from a
// plain class vtable.
@("dependencyImage.externDInterfaceDispatch." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_interface_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_interface_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_interface_fixture_" ~ backend.stringof,
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
        }.uniqueDepModule("dep_image_interface_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_interface_fixture;

                unittest {
                    Drawable d = makeButton();
                    assert(d.draw() == 42);
                }
            }.uniqueDepModule("dep_image_interface_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A dependency-image struct constructed through its `extern(D)` `this(int)`
// constructor, whose body lives only in the compiled image. The constructor
// computes `value` from `seed` instead of storing it, so reading 42 back out of
// `Tracked(25)` is possible only if that body ran: a struct built from the
// argument alone would hold 25.
@("dependencyImage.externDStructConstructor." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_ctor_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_ctor_fixture;

            struct Tracked {
                int value;

                this(int seed) {
                    value = seed + 17;
                }
            }
        }.uniqueDepModule("dep_image_ctor_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_ctor_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_ctor_fixture;

            struct Tracked {
                int value;
                this(int seed);
            }
        }.uniqueDepModule("dep_image_ctor_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_ctor_fixture;

                unittest {
                    int seed = 25;
                    Tracked tracked = Tracked(seed);
                    assert(tracked.value == 42);
                }
            }.uniqueDepModule("dep_image_ctor_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A dependency-image struct whose `~this()` is declared to the importing module
// but defined only in the compiled image. D runs it when `tracked` leaves the
// inner scope; the destructor bumps a counter inside the image, so `dtorCalls`
// reporting 1 afterwards is what shows it fired.
@("dependencyImage.externDStructDestructor." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_dtor_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_dtor_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_dtor_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_dtor_fixture;

            struct Tracked {
                int value;
                ~this();
            }

            int dtorCalls();
        }.uniqueDepModule("dep_image_dtor_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_dtor_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A dependency-image struct whose `this(this)` is declared to the importing
// module but defined only in the compiled image. D runs it when `copy` is
// initialised from `original`; the postblit bumps a counter inside the image,
// so `postblitCalls` reporting 1 is what shows it fired.
@("dependencyImage.externDStructPostblit." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_postblit_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_postblit_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_postblit_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_postblit_fixture;

            struct Tracked {
                int value;
                this(this);
            }

            int postblitCalls();
        }.uniqueDepModule("dep_image_postblit_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_postblit_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externDDelegateCallback." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_callback_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_callback_fixture;

            int dependencyApply(int x, int delegate(int) callback) {
                return callback(x);
            }
        }.uniqueDepModule("dep_image_callback_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_callback_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_callback_fixture;

            int dependencyApply(int x, int delegate(int) callback);
        }.uniqueDepModule("dep_image_callback_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_callback_fixture;

                unittest {
                    int base = 100;
                    int x = 5;
                    int delegate(int) callback = (int n) => n + base;
                    assert(dependencyApply(x, callback) == 105);
                }
            }.uniqueDepModule("dep_image_callback_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// Native code may synchronously re-enter an interpreted delegate. A class
// reference caught during that re-entry must retain the native object identity
// created by the runtime when the callback passes it to another native call.
@("dependencyImage.callbackPreservesCaughtNativeClassIdentity." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath,
            "dep_image_caught_class_callback_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_caught_class_callback_fixture;

            void dependencyVisit(scope void delegate() callback) {
                callback();
            }

            void accept(Throwable value) {
                assert(value !is null);
            }
        }.uniqueDepModule("dep_image_caught_class_callback_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_caught_class_callback_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_caught_class_callback_fixture;

            void dependencyVisit(scope void delegate() callback);
            void accept(Throwable value);
        }.uniqueDepModule("dep_image_caught_class_callback_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import core.exception: RangeError;
                import dep_image_caught_class_callback_fixture;

                unittest {
                    void delegate() callback = () {
                        int[] values;
                        try {
                            auto ignored = values[0];
                        } catch (RangeError error) {
                            accept(error);
                        }
                    };
                    dependencyVisit(callback);
                }
            }.uniqueDepModule(
                "dep_image_caught_class_callback_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A class field name is ordinary guest data and cannot change which object a
// native function receives.
@("dependencyImage.classFieldNameDoesNotChangeNativeIdentity." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath,
            "dep_image_class_field_identity_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_class_field_identity_fixture;

            class Ordinary: Exception {
                int __quickbiteNativeThrowableObjectPointer;
                int payload;

                this(int first, int second) {
                    super("ordinary");
                    __quickbiteNativeThrowableObjectPointer = first;
                    payload = second;
                }
            }

            void throwOrdinary() {
                throw new Ordinary(17, 25);
            }

            int inspect(Ordinary value) {
                return value.__quickbiteNativeThrowableObjectPointer + value.payload;
            }
        }.uniqueDepModule("dep_image_class_field_identity_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_class_field_identity_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_class_field_identity_fixture;

            class Ordinary: Exception {
                int __quickbiteNativeThrowableObjectPointer;
                int payload;

                this(int first, int second);
            }

            void throwOrdinary();
            int inspect(Ordinary value);
        }.uniqueDepModule("dep_image_class_field_identity_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_class_field_identity_fixture;

                unittest {
                    try {
                        throwOrdinary();
                        assert(false);
                    } catch (Ordinary value) {
                        assert(value.__quickbiteNativeThrowableObjectPointer == 17);
                        assert(value.payload == 25);
                        Throwable base = value;
                        assert((cast(Ordinary) base)
                            .__quickbiteNativeThrowableObjectPointer == 17);
                        auto recovered = cast(Ordinary) base;
                        assert(recovered.__quickbiteNativeThrowableObjectPointer == 17);
                        assert(recovered.payload == 25);
                        assert(inspect(recovered) == 42);
                    }
                }
            }.uniqueDepModule(
                "dep_image_class_field_identity_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A `scope void delegate(int)` handed to a dependency-image function that calls
// it back before returning. `scope` says the callee will not retain it, so the
// delegate need only stay callable for the duration of that one call — and the
// value it is passed (42) has to reach the closure, which writes it to `seen`.
@("dependencyImage.externDScopedVoidDelegateCallback." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_scoped_void_callback_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_scoped_void_callback_fixture;

            void dependencyVisit(int value, scope void delegate(int) callback) {
                callback(value);
            }
        }.uniqueDepModule("dep_image_scoped_void_callback_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_scoped_void_callback_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_scoped_void_callback_fixture;

            void dependencyVisit(int value, scope void delegate(int) callback);
        }.uniqueDepModule("dep_image_scoped_void_callback_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_scoped_void_callback_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A dependency image retains an `extern(D)` delegate beyond the call that
// registered it, then invokes it from a later, separate call. D permits an
// unscoped delegate to outlive the call it was passed to, so both its entry
// point and the closure it captured have to stay valid across the gap between
// the two calls, not just for the duration of the first.
@("dependencyImage.externDDurableDelegateCallback." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_durable_callback_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_durable_callback_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_durable_callback_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_durable_callback_fixture;

            extern(D) {
                void registerCallback(int delegate(int) callback);
                int invokeRegisteredCallback(int value);
            }
        }.uniqueDepModule("dep_image_durable_callback_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_durable_callback_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A two-argument delegate handed to a dependency-image function that calls it
// back. The callback subtracts its arguments, which makes their order
// observable: `(10, 3)` must arrive as `a == 10, b == 3` and yield 7, not -7.
@("dependencyImage.externDMultiArgDelegateCallback." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_callback2_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_callback2_fixture;

            int dependencyApply2(int x, int y, int delegate(int, int) callback) {
                return callback(x, y);
            }
        }.uniqueDepModule("dep_image_callback2_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_callback2_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_callback2_fixture;

            int dependencyApply2(int x, int y, int delegate(int, int) callback);
        }.uniqueDepModule("dep_image_callback2_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_callback2_fixture;

                unittest {
                    int x = 10;
                    int y = 3;
                    int delegate(int, int) callback = (int a, int b) => a - b;
                    assert(dependencyApply2(x, y, callback) == 7);
                }
            }.uniqueDepModule("dep_image_callback2_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A dependency-image struct whose `this(this)` mutates the copy. Unlike
// externDStructPostblit (which only counts calls), this one writes through
// `this`, and D runs a postblit on the newly copied object: `copy` must read
// back 10 while `original` is left at 9.
@("dependencyImage.externDMutatingPostblit." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_mut_postblit_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_mut_postblit_fixture;

            struct Tracked {
                int value;

                this(this) {
                    value += 1;
                }
            }
        }.uniqueDepModule("dep_image_mut_postblit_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_mut_postblit_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_mut_postblit_fixture;

            struct Tracked {
                int value;
                this(this);
            }
        }.uniqueDepModule("dep_image_mut_postblit_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_mut_postblit_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// `new T(args)` where T's `extern(D)` constructor is defined only in the
// compiled image. Unlike externDStructConstructor (`T(seed)` value
// construction), the constructed value lives on the heap and is reached through
// a `Tracked*`; the constructor still has to run, so `tracked.value` is 42
// rather than the default-initialised 0.
@("dependencyImage.externDNewStructConstructor." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_new_struct_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_new_struct_fixture;

            struct Tracked {
                int value;

                this(int seed) {
                    value = seed + 17;
                }
            }
        }.uniqueDepModule("dep_image_new_struct_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_new_struct_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_new_struct_fixture;

            struct Tracked {
                int value;
                this(int seed);
            }
        }.uniqueDepModule("dep_image_new_struct_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_new_struct_fixture;

                unittest {
                    int seed = 25;
                    Tracked* tracked = new Tracked(seed);
                    assert(tracked.value == 42);
                }
            }.uniqueDepModule("dep_image_new_struct_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A class reference returned by a dependency image has to survive a garbage
// collection that runs while the only reference to it is the caller's own
// local: `makeThing` hands back an `Object`, `collectNow` runs a full
// collection, and `isLive` then asks the GC whether that address is still a
// live allocation. Nothing in the fixture roots the object explicitly, so
// holding it in `thing` is what must keep it reachable.
@("dependencyImage.externDClassHandleSurvivesCollection." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_gc_root_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_gc_root_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_gc_root_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_gc_root_fixture;

            Object makeThing();
            void collectNow();
            bool isLive(Object o);
        }.uniqueDepModule("dep_image_gc_root_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_gc_root_fixture;

                unittest {
                    Object thing = makeThing;
                    collectNow;
                    assert(isLive(thing));
                }
            }.uniqueDepModule("dep_image_gc_root_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A union-typed out-pointer written by one extern(C) call and read back
// through a second, mirroring externCScalarOutParameter but with a union
// behind the pointer. `&handle` designates the caller's own storage, so the
// byte `dependencyInitHandle` writes through one union member must still be
// there when a separate `dependencyReadHandle` call reads it: the union has to
// cross as an address, not as a copy of whichever member looks active.
@("dependencyImage.externCUnionOutParameter." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_union_out_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_union_out_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_union_out_fixture_" ~ backend.stringof,
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
        }.uniqueDepModule("dep_image_union_out_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_union_out_fixture;

                unittest {
                    Handle handle;
                    dependencyInitHandle(&handle);
                    assert(dependencyReadHandle(&handle) == 7);
                }
            }.uniqueDepModule("dep_image_union_out_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A dynamic array whose element type is a struct rather than a scalar, crossing
// in both directions. `dependencyPointSum` must walk the caller's own elements
// (26 is the sum of all four ints), and the `const(Point)[]` returned by
// `dependencyMakePoints` must come back with both its length and each field
// intact.
@("dependencyImage.externDSliceOfStructs." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_slice_of_structs_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_slice_of_structs_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_slice_of_structs_fixture_" ~ backend.stringof,
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
        }.uniqueDepModule("dep_image_slice_of_structs_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_slice_of_structs_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// An associative-array parameter crossing the boundary. The native oracle makes
// the call, so the language permits it; the Interpreter refuses it, because it
// cannot reproduce an `int[string]`'s hashing, allocation, and layout across
// the ABI. What is pinned is that the refusal is honest: the diagnostic names
// the associative array and its type spelling rather than blaming missing
// source. `extern(C)` keeps argument ordering irrelevant.
static if (is(backend == Interpreter)) {
@("dependencyImage.externCAssocArrayRejected." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_assoc_array_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_assoc_array_fixture;

            extern(C) int dependencyCountEntries(int[string] table) {
                return cast(int) table.length;
            }
        }.uniqueDepModule("dep_image_assoc_array_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_assoc_array_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_assoc_array_fixture;

            extern(C) int dependencyCountEntries(int[string] table);
        }.uniqueDepModule("dep_image_assoc_array_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_assoc_array_fixture;

                unittest {
                    int[string] table;
                    table["a"] = 1;
                    table["b"] = 2;
                    assert(dependencyCountEntries(table) == 2);
                }
            }.uniqueDepModule("dep_image_assoc_array_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == false;
        // Honest diagnostic: names the associative array and its type spelling,
        // not missing source.
        "associative array".should.be in actual[0].message;
        "int[string]".should.be in actual[0].message;
    }
}
}


@("dependencyImage.externGsharedGlobalRead." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_gshared_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_gshared_fixture;

            __gshared int dependencyCounter;

            void bump() {
                dependencyCounter += 1;
            }
        }.uniqueDepModule("dep_image_gshared_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_gshared_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_gshared_fixture;

            extern __gshared int dependencyCounter;
            void bump();
        }.uniqueDepModule("dep_image_gshared_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_gshared_fixture;

                unittest {
                    bump;
                    bump;
                    assert(dependencyCounter == 2);
                }
            }.uniqueDepModule("dep_image_gshared_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

@("dependencyImage.externGsharedGlobalWrite." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_gshared_write_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_gshared_write_fixture;

            __gshared int dependencyCounter;

            void bump() {
                dependencyCounter += 1;
            }

            int readCounter() {
                return dependencyCounter;
            }
        }.uniqueDepModule("dep_image_gshared_write_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_gshared_write_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_gshared_write_fixture;

            extern __gshared int dependencyCounter;
            void bump();
            int readCounter();
        }.uniqueDepModule("dep_image_gshared_write_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_gshared_write_fixture;

                unittest {
                    dependencyCounter = 5;
                    assert(readCounter == 5);
                    bump;
                    assert(dependencyCounter == 6);
                }
            }.uniqueDepModule("dep_image_gshared_write_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// A dependency image's `static this()` must already have run by the time the
// importing code executes, so the `__gshared seed` it sets reads as 42 — both
// through the image's own `readSeed` and through a direct read of `seed` from
// D, which has to see the same object the module constructor wrote.
@("dependencyImage.moduleCtorRanAtDlopen." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_modulector_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_modulector_fixture;

            __gshared int seed;

            static this() {
                seed = 42;
            }

            int readSeed() {
                return seed;
            }
        }.uniqueDepModule("dep_image_modulector_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_modulector_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_modulector_fixture;

            extern __gshared int seed;
            int readSeed();
        }.uniqueDepModule("dep_image_modulector_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_modulector_fixture;

                unittest {
                    assert(readSeed == 42);
                    assert(seed == 42);
                }
            }.uniqueDepModule("dep_image_modulector_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// A plain module-level `int` in a dependency image is thread-local by default
// in D, not `__gshared` — the common case for a dub package's globals. Declared
// to the importer as `extern int`, it still names one object per thread: a read
// from D, an assignment from D, and the image's own `bumpTls` must all land on
// that same instance, making the sequence 100, 5, 6 observable from both sides.
@("dependencyImage.tlsGlobalReadWrite." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(importPath, "dep_image_tls_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_tls_fixture;

            int tlsCounter = 100;                 // thread-local by default in D

            void bumpTls() {
                tlsCounter += 1;
            }

            int readTls() {
                return tlsCounter;
            }
        }.uniqueDepModule("dep_image_tls_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_tls_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_tls_fixture;

            extern int tlsCounter;
            void bumpTls();
            int readTls();
        }.uniqueDepModule("dep_image_tls_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_tls_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// An `extern __gshared` struct global names the same object as the definition
// in the compiled dependency image, so reads and writes from either side land
// on that one object. The fixture drives both directions and both kinds of
// write: a native whole-object update (`setConfig`), then a D single-field
// assignment (`config.width = 7`) that native code reads back — while the
// untouched `height` field keeps the value native code last gave it.
@("dependencyImage.structGlobalReadWrite." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_struct_global_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_struct_global_fixture;

            struct Config { int width; int height; }
            __gshared Config config = Config(80, 25);

            void setConfig(int w, int h) {
                config.width = w;
                config.height = h;
            }

            int configWidth() { return config.width; }
        }.uniqueDepModule("dep_image_struct_global_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_struct_global_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_struct_global_fixture;

            struct Config { int width; int height; }
            extern __gshared Config config;
            void setConfig(int w, int h);
            int configWidth();
        }.uniqueDepModule("dep_image_struct_global_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_struct_global_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// Reading a dynamic-array `extern __gshared` global. The image's `static
// this()` fills the slice when the image is loaded, so by the time the
// importing code runs, `numbers` already denotes those elements: its length and
// every element must agree with what native code sums out of the same global.
// Read only — assigning a new array to such a global is `sliceGlobalWriteback`.
@("dependencyImage.sliceGlobalRead." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_slice_global_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_slice_global_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_slice_global_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_slice_global_fixture;

            extern __gshared int[] numbers;
            int total();
        }.uniqueDepModule("dep_image_slice_global_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_slice_global_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// Writing a whole new array into a dynamic-array `extern __gshared` global.
// The assignment rebinds the shared variable itself, so native code reading
// that same global must observe the new length and the new elements, and the
// elements must stay alive for as long as the global refers to them. Assigning
// a second array has to replace the first outright, not extend or alias it.
@("dependencyImage.sliceGlobalWriteback." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_slice_write_fixture_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_slice_write_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_slice_write_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_slice_write_fixture;

            extern __gshared int[] payload;
            int sumPayload();
            size_t payloadLength();
        }.uniqueDepModule("dep_image_slice_write_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_slice_write_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}


// Reading `extern __gshared` scalar globals of four different shapes: a `long`
// whose initializer does not fit in an `int`, a `double`, a `ubyte` above 127,
// and a `bool`. Each must read back at its own width and signedness, so a read
// that assumed one common scalar shape would lose the high bits of `bigCount`,
// the fraction of `ratio`, or sign-extend `flagByte` to a negative value.
@("dependencyImage.scalarWidthGlobalRead." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_scalar_width_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_scalar_width_fixture;

            __gshared long   bigCount    = 5_000_000_000;
            __gshared double ratio       = 1.5;
            __gshared ubyte  flagByte    = 200;
            __gshared bool   enabledFlag = true;
        }.uniqueDepModule("dep_image_scalar_width_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_scalar_width_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_scalar_width_fixture;

            extern __gshared long   bigCount;
            extern __gshared double ratio;
            extern __gshared ubyte  flagByte;
            extern __gshared bool   enabledFlag;
        }.uniqueDepModule("dep_image_scalar_width_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_scalar_width_fixture;

                unittest {
                    assert(bigCount == 5_000_000_000); // 64-bit, exceeds int
                    assert(ratio == 1.5);              // double
                    assert(flagByte == 200);           // unsigned byte
                    assert(enabledFlag == true);       // bool
                }
            }.uniqueDepModule("dep_image_scalar_width_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// Assigning a whole struct value (`origin = Point(9, 8)`) to a native struct
// global: every field is replaced at once, and native code reads both back from
// the same object. This is the counterpart to the single-field assignment
// (`config.width = 7`) pinned by `structGlobalReadWrite`, which instead has to
// leave the fields it does not name alone.
@("dependencyImage.structGlobalRebindWriteback." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_struct_rebind_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_struct_rebind_fixture;

            struct Point { int x; int y; }
            __gshared Point origin = Point(1, 2);

            int pointX() { return origin.x; }
            int pointY() { return origin.y; }
        }.uniqueDepModule("dep_image_struct_rebind_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_struct_rebind_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_struct_rebind_fixture;

            struct Point { int x; int y; }
            extern __gshared Point origin;
            int pointX();
            int pointY();
        }.uniqueDepModule("dep_image_struct_rebind_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_struct_rebind_fixture;

                unittest {
                    assert(pointX() == 1);  // native reads its initializer
                    origin = Point(9, 8);   // WHOLE-struct rebind write-through
                    assert(pointX() == 9);  // native sees the rebind
                    assert(pointY() == 8);
                }
            }.uniqueDepModule("dep_image_struct_rebind_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// Reading a static-array `extern __gshared` global. A static array's length is
// part of its type and its elements live INLINE in the object itself, unlike a
// dynamic array, which is a `{length, ptr}` reference to elements stored
// elsewhere (`sliceGlobalRead`). So `grid.length` is a compile-time constant
// and indexing reads the shared object's own bytes — the same bytes native
// `gridAt` indexes.
@("dependencyImage.staticArrayGlobalRead." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_static_array_global_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_static_array_global_fixture;

            __gshared int[4] grid = [11, 22, 33, 44];

            int gridAt(int i) { return grid[i]; }
        }.uniqueDepModule("dep_image_static_array_global_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_static_array_global_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_static_array_global_fixture;

            extern __gshared int[4] grid;
            int gridAt(int i);
        }.uniqueDepModule("dep_image_static_array_global_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_static_array_global_fixture;

                unittest {
                    assert(grid.length == 4);  // static-array length is compile-time
                    assert(grid[0] == 11);     // interpreter reads inline elements
                    assert(grid[3] == 44);
                    assert(gridAt(2) == 33);   // native reads its static-array global
                }
            }.uniqueDepModule("dep_image_static_array_global_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// Reading an `extern __gshared` struct global that mixes an array field with a
// scalar one. `Named.label` is a `string`, so the shared object holds a
// reference to characters stored elsewhere — here a literal that lives for the
// whole program — while `id` is stored inline. Reading the global therefore has
// to follow the reference for one field and read bytes directly for the other,
// and native `labelLength` must agree about the very same object. Read only.
@("dependencyImage.nestedStructGlobalRead." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_nested_struct_global_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_nested_struct_global_fixture;

            struct Named { string label; int id; }
            __gshared Named entry = Named("hello", 7);

            size_t labelLength() { return entry.label.length; }
        }.uniqueDepModule("dep_image_nested_struct_global_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_nested_struct_global_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_nested_struct_global_fixture;

            struct Named { string label; int id; }
            extern __gshared Named entry;
            size_t labelLength();
        }.uniqueDepModule("dep_image_nested_struct_global_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_nested_struct_global_fixture;

                unittest {
                    assert(entry.id == 7);           // scalar field
                    assert(entry.label == "hello");  // array field: a reference
                                                     // to the literal's chars
                    assert(entry.label.length == 5);
                    assert(labelLength() == 5);      // native reads its own
                                                     // nested global
                }
            }.uniqueDepModule("dep_image_nested_struct_global_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// Cross-image dependency-image initialization ordering: A's module ctor runs
// before B's because images load in list order under RTLD_GLOBAL, so B's ctor
// (which reads A's shared `seedBase`) sees A's initialized value.
// Image B references A's symbol as an undefined extern, resolved at load time
// through RTLD_GLOBAL. The shared global is `extern(C)` so both images agree on
// the symbol name `seedBase`; a plain extern(D) global mangles the module name
// in (`_D21dep_image_ctororder_a...` vs `..._b...`), so B's reference would not
// resolve to A's definition. First multi-image fixture.
//
// Not registered on Linux: there it fails even in a fresh process, and it is
// not yet established whether the fault lies in the fixture, in the
// SystemLinker oracle, or in loading the images.
version (linux) {
} else {
    @("dependencyImage.crossImageCtorOrdering." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = immutable Sandbox();
        auto oracleFixture = buildCtorOrderingFixture( // Module must stay mutable.
            sandbox,
            backend.stringof ~ "_oracle",
        );
        const oracle = (new SystemLinker(
            oracleFixture.imagePaths,
            oracleFixture.importPaths,
        )).runTests(oracleFixture.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        auto actualFixture = buildCtorOrderingFixture( // Module must stay mutable.
            sandbox,
            backend.stringof ~ "_actual",
        );
        const actual = runDependencyImage!backend(
            actualFixture.imagePaths,
            actualFixture.importPaths,
            actualFixture.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// DT_NEEDED-driven dependency-image initialization ordering: the caller only
// names image B. B has a dynamic-loader dependency on A, so dlopen(B) must load
// A first, run A's module ctor, then run B's module ctor.
@("dependencyImage.dtNeededCtorOrdering." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;
    import std.process: execute;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";

        const depAPath = buildPath(importPath, "dep_image_dtneeded_a_" ~ backend.stringof ~ ".d");
        writeFile(depAPath, q{
            module dep_image_dtneeded_a;

            extern(C) __gshared int dtNeededSeed;

            static this() {
                dtNeededSeed = 20;
            }
        }.uniqueDepModule("dep_image_dtneeded_a", backend.stringof)
         .uniqueDepModule("dtNeededSeed", backend.stringof));
        const imageAPath = buildSharedLibrary(
            sandbox,
            "dep_image_dtneeded_a_" ~ backend.stringof,
            [depAPath],
        );

        const depBPath = buildPath(importPath, "dep_image_dtneeded_b_" ~ backend.stringof ~ ".d");
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
        }.uniqueDepModule("dep_image_dtneeded_b", backend.stringof)
         .uniqueDepModule("dtNeededSeed", backend.stringof));

        const imageBPath =
            inSandboxPath("libdep_image_dtneeded_b_" ~ backend.stringof ~ ".so");
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
        }.uniqueDepModule("dep_image_dtneeded_b", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_dtneeded_b;

                unittest {
                    assert(readDerived() == 24);
                }
            }.uniqueDepModule("dep_image_dtneeded_b", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imageBPath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imageBPath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// TLS through a DT_NEEDED dependency image: the caller only loads image B, but
// B depends on image A. A owns a default thread-local D global; direct reads
// and writes from D and native calls into B must all observe the same TLS
// instance once dlopen(B) has pulled A in.
@("dependencyImage.dtNeededTlsGlobalReadWrite." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;
    import std.process: execute;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";

        const depAPath = buildPath(importPath, "dep_image_dtneeded_tls_a_" ~ backend.stringof ~ ".d");
        writeFile(depAPath, q{
            module dep_image_dtneeded_tls_a;

            int dtNeededTlsCounter = 30;
        }.uniqueDepModule("dep_image_dtneeded_tls_a", backend.stringof));
        const imageAPath = buildSharedLibrary(
            sandbox,
            "dep_image_dtneeded_tls_a_" ~ backend.stringof,
            [depAPath],
        );

        const depBPath = buildPath(importPath, "dep_image_dtneeded_tls_b_" ~ backend.stringof ~ ".d");
        writeFile(depBPath, q{
            module dep_image_dtneeded_tls_b;

            import dep_image_dtneeded_tls_a: dtNeededTlsCounter;

            int readTlsFromB() {
                return dtNeededTlsCounter;
            }

            void bumpTlsFromB() {
                dtNeededTlsCounter += 2;
            }
        }.uniqueDepModule("dep_image_dtneeded_tls_b", backend.stringof).uniqueDepModule("dep_image_dtneeded_tls_a", backend.stringof));

        const imageBPath = inSandboxPath("libdep_image_dtneeded_tls_b_" ~ backend.stringof ~ ".so");
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
        }.uniqueDepModule("dep_image_dtneeded_tls_a", backend.stringof));
        writeFile(depBPath, q{
            module dep_image_dtneeded_tls_b;

            int readTlsFromB();
            void bumpTlsFromB();
        }.uniqueDepModule("dep_image_dtneeded_tls_b", backend.stringof));

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
            }.uniqueDepModule("dep_image_dtneeded_tls_a", backend.stringof).uniqueDepModule("dep_image_dtneeded_tls_b", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imageBPath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imageBPath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// Reading a pointer-typed `extern __gshared` global. `anchorPtr` holds the
// address the image stored in it, so it must read back non-null and still
// denote `anchor`. The fixture proves the second part by handing the pointer to
// a native callee that dereferences it, which keeps the test about the value of
// the pointer global rather than about dereferencing a foreign address from D.
@("dependencyImage.pointerGlobalRead." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath =
            buildPath(importPath, "dep_image_pointer_global_fixture_" ~ backend.stringof ~ ".d");
        writeFile(depPath, q{
            module dep_image_pointer_global_fixture;

            __gshared int anchor = 77;
            __gshared int* anchorPtr = &anchor;

            int derefArg(int* p) { return *p; }
        }.uniqueDepModule("dep_image_pointer_global_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_pointer_global_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_pointer_global_fixture;

            extern __gshared int anchor;
            extern __gshared int* anchorPtr;
            int derefArg(int* p);
        }.uniqueDepModule("dep_image_pointer_global_fixture", backend.stringof));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_pointer_global_fixture;

                unittest {
                    assert(anchorPtr !is null);          // the global holds the
                                                         // address of `anchor`
                    assert(derefArg(anchorPtr) == 77);   // interpreter reads the
                                                         // pointer global, passes
                                                         // it to native which
                                                         // derefs it
                }
            }.uniqueDepModule("dep_image_pointer_global_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A native call site only ever catches `Exception` at the FFI boundary
// (native_call_adapter.d wraps the native call in `catch (Exception)` and
// rethrows it; an Error stays fatal), so an Error can only reach
// `nativeExceptionRoot` (interpreter.md §9.10) indirectly, via the `.next`
// chain of a caught Exception: the rethrow copies that chain, following
// `.next` regardless of its dynamic type. The chained class's
// fully-qualified name does not match
// "core.exception."/"object." + "Error", so the name-prefix heuristic
// misclassifies it as Exception, and catch(Error) on the rethrown link
// wrongly misses it.
@("dependencyImage.nativeChainedErrorSubclass." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_chained_error_fixture_" ~ backend.stringof ~ ".d",
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
        }.uniqueDepModule("dep_image_chained_error_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_chained_error_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_chained_error_fixture;

            class DependencyError : Error {
                this(string msg);
            }

            void dependencyThrowChainedError();
        }.uniqueDepModule("dep_image_chained_error_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_chained_error_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}

// A natively-thrown class two levels below Exception (interpreter.md §9.10's
// nativeExceptionRoot defect): the fabricated type-name list jumps straight
// from the thrown class to its root, omitting the intermediate base, so
// catch(DependencyBaseException) wrongly misses a DependencyException.
@("dependencyImage.nativeIntermediateBaseException." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_intermediate_exception_fixture_" ~ backend.stringof ~ ".d",
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
        }.uniqueDepModule("dep_image_intermediate_exception_fixture", backend.stringof));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_intermediate_exception_fixture_" ~ backend.stringof,
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
        }.uniqueDepModule("dep_image_intermediate_exception_fixture", backend.stringof));

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
            }.uniqueDepModule("dep_image_intermediate_exception_fixture", backend.stringof),
            [inSandboxPath(importPath)],
        );

        const oracle = (new SystemLinker(
            [imagePath],
            [inSandboxPath(importPath)],
        )).runTests(moduleResult.module_);
        oracle.length.should == 1;
        oracle[0].passed.should == true;

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}
}

// A struct-typed native-call return whose field layout mixes a scalar with
// a dynamic-array (`string`) field, unlike every all-scalar struct-return
// fixture above: both fields of the returned value must read back with the
// same contents the callee gave them. The expected
// values are D's real compiled-code semantics, checked directly in the
// asserted source rather than diffed against a separately computed oracle
// result, so `SystemLinker` running the same asserts through the matrix
// below already serves as the oracle (`ai/plans/single-oracle.md`).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call a native dependency image"),
)) {
@("dependencyImage.structWithSliceFieldReturn." ~ backend.stringof)
@Tags(backend.stringof)
unittest {
    import quickbite.frontend.compiler: parseSnippetWithCheckActionContext;
    import std.path: buildPath;

    const sandbox = immutable Sandbox();
    with(sandbox) {
        const importPath = "imports";
        const depPath = buildPath(
            importPath,
            "dep_image_struct_slice_return_fixture_" ~ backend.stringof ~ ".d",
        );
        writeFile(depPath, q{
            module dep_image_struct_slice_return_fixture;

            struct Pair {
                int count;
                string label;
            }

            Pair dependencyMakePair(int count) {
                return Pair(count, "hello");
            }
        }.uniqueDepModule(
            "dep_image_struct_slice_return_fixture", backend.stringof,
        ));

        const imagePath = buildSharedLibrary(
            sandbox,
            "dep_image_struct_slice_return_fixture_" ~ backend.stringof,
            [depPath],
        );

        writeFile(depPath, q{
            module dep_image_struct_slice_return_fixture;

            struct Pair {
                int count;
                string label;
            }

            Pair dependencyMakePair(int count);
        }.uniqueDepModule(
            "dep_image_struct_slice_return_fixture", backend.stringof,
        ));

        auto moduleResult = parseSnippetWithCheckActionContext(
            q{
                import dep_image_struct_slice_return_fixture;

                unittest {
                    int count = 10;
                    Pair pair = dependencyMakePair(count);
                    assert(pair.count == 10);
                    assert(pair.label == "hello");
                }
            }.uniqueDepModule(
                "dep_image_struct_slice_return_fixture", backend.stringof,
            ),
            [inSandboxPath(importPath)],
        );

        const actual = runDependencyImage!backend(
            [imagePath],
            [inSandboxPath(importPath)],
            moduleResult.module_,
        );
        actual.length.should == 1;
        actual[0].passed.should == true;
    }
}
}
