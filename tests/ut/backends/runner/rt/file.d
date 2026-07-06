module ut.backends.runner.rt.file;


import ut.backends;
import std.conv: text;


// File IO needs the host filesystem: the fixture creates a file in a
// sandbox, writes to it, and reads it back. The path is spliced into the
// source because the snippet runs under the backend, which cannot see the
// host test's sandbox object.
static foreach (backend; AliasSeq!(Interpreter, SystemLinker)) {
    @("file.createWriteRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import unit_threaded.integration: Sandbox;

        with (immutable Sandbox()) {
            const path = inSandboxPath("file_fixture.txt");
            const source = text(
                "unittest {\n",
                "    import std.stdio: File;\n",
                "    import std.file: readText;\n",
                "\n",
                "    enum path = `", path, "`;\n",
                "    {\n",
                "        auto f = File(path, `w`);\n",
                "        f.write(`hello`);\n",
                "    }\n",
                "    assert(readText(path) == `hello`);\n",
                "}\n",
            );
            runBackendSourceFixtureTests!backend(source);
        }
    }
}
