module ut.backends.runner.lang.imports;


import ut.backends;
import std.conv: text;
import std.path: buildPath;


// An imported, non-template function only gets semantic1/2 when pulled in from
// another module; its body and parameter VarDeclarations stay un-analyzed until
// something forces semantic3. The interpreter must run semantic3 on demand
// before binding call arguments, otherwise a call such as
// `File("/tmp/foo.txt", "w")` dies with the bogus "Unsupported interpreter call
// arguments." instead of interpreting the callee.
static foreach (backend; AliasSeq!(Interpreter)) {
    @("call.importedFunctionWithArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        with(immutable Sandbox()) {
            const importPath = "imports";
            const moduleName = text("quickbite_imported_call_", backend.stringof);
            writeFile(
                buildPath(importPath, moduleName ~ ".d"),
                text(
                    "module ", moduleName, ";\n",
                    "int addImported(int a, int b) { return a + b; }\n",
                ),
            );
            const source = text(
                "import ", moduleName, q{;
                unittest {
                    int a = 2;
                    int b = 3;
                    assert(addImported(a, b) == 5);
                }
            });

            runBackendSourceFixtureTests!backend(
                source,
                [inSandboxPath(importPath)],
            );
        }
    }
}

// Calling an imported method must complete semantic analysis for its nested
// predicate and the range-algorithm templates instantiated by that predicate.
// Imported modules are not roots, so those bodies are analyzed on demand.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "backend process exits with status 139"),
)) {
    @("call.importedMethodWithNestedPredicate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        with(immutable Sandbox()) {
            const importPath = "imports";
            const moduleName = text(
                "quickbite_imported_predicate_",
                backend.stringof,
            );
            writeFile(
                buildPath(importPath, moduleName ~ ".d"),
                text(
                    "module ", moduleName, ";\n",
                    q{
                        struct ByteRange {
                            void* ptr;
                            size_t length;
                        }

                        struct Allocations {
                            @safe @nogc nothrow:

                            ByteRange[] entries;
                            char[1024] textBuffer;

                            bool remove(void[] bytes) scope pure {
                                import std.algorithm: canFind, countUntil;

                                bool matches(ByteRange other) {
                                    return other.ptr == bytes.ptr &&
                                    other.length == bytes.length;
                                }

                                // @trusted: `&this` is disallowed in @safe
                                // code because the compiler cannot verify a
                                // taken address of `this` never escapes; the
                                // pointer here is only ever compared to
                                // `null` in this same expression and never
                                // stored or returned.
                                const isNull = () @trusted {
                                    return &this is null;
                                }();
                                assert(!isNull);

                                if (!entries.canFind!matches) {
                                    const index = pureSprintf(
                                        &textBuffer[0],
                                        "unknown range: %p %ld",
                                        // @trusted: `bytes` is `scope`, so
                                        // @safe code cannot take `.ptr` off
                                        // it; the pointer is only ever
                                        // handed to `pureSprintf`'s `%p`
                                        // formatting below, never
                                        // dereferenced or retained.
                                        () @trusted { return bytes.ptr; }(),
                                        bytes.length,
                                    );
                                    debug
                                        assert(false, textBuffer[0 .. index].dup);
                                    else
                                        assert(false, "unknown range");
                                }
                                const index = entries.countUntil!matches;
                                foreach (i; index .. entries.length - 1)
                                    entries[i] = entries[i + 1];
                                entries = entries[0 .. $ - 1];
                                return true;
                            }
                        }

                        // @trusted: calls the @system extern(C) bindings
                        // below. Every call site in this fixture passes
                        // `&textBuffer[0]` (a fixed 1024-byte buffer) as
                        // `output` together with the hardcoded
                        // `"unknown range: %p %ld"` format, whose two `%p`/
                        // `%ld` conversions match `arguments`' two callers
                        // exactly, so this can neither overflow the buffer
                        // nor read past `arguments`.
                        private int pureSprintf(A...)(
                            scope char* output,
                            scope const(char*) format,
                            A arguments,
                        ) @trusted pure nothrow {
                            const savedErrno = fakePureErrno();
                            const result = fakePureSprintf(
                                output,
                                format,
                                arguments,
                            );
                            fakePureErrno() = savedErrno;
                            return result;
                        }

                        extern(C) private @system @nogc nothrow
                            ref int fakePureErrnoImpl();

                        extern(C) private pure @system @nogc nothrow {
                            pragma(mangle, "fakePureErrnoImpl")
                                ref int fakePureErrno();
                            pragma(mangle, "sprintf")
                                int fakePureSprintf(
                                    scope char* output,
                                    scope const(char*) format,
                                    ...
                                );
                        }
                    },
                ),
            );
            const source = text(
                "import ", moduleName, q{;
                unittest {
                    ubyte[2] first;
                    ubyte[3] second;
                    auto allocations = Allocations([
                        ByteRange(first.ptr, first.length),
                        ByteRange(second.ptr, second.length),
                    ]);
                    assert(allocations.remove(first[]));
                    assert(allocations.entries.length == 1);
                    assert(allocations.entries[0].ptr == second.ptr);
                }
            });

            runBackendSourceFixtureTests!backend(
                source,
                [inSandboxPath(importPath)],
            );
        }
    }
}
