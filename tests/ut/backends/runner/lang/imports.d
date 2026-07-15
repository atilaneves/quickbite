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
