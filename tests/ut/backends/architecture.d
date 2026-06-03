module ut.backends.architecture;


import ut;


// This root-level backend test guards package boundaries rather than backend
// behavior. Keep it outside lang, projects, and contracts packages so those
// packages remain focused on executable backend surfaces.
@("backendFilesDoNotImportExecutorCode")
unittest {
    import std.algorithm: canFind;
    import std.file: SpanMode, dirEntries, readText;

    const executor = "quickbite." ~ "executor";
    const executors = executor ~ "s";
    const executorTests = "ut." ~ "executors";
    string[] violations;
    foreach (root; ["source/quickbite/backends", "tests/ut/backends"]) {
        foreach (entry; dirEntries(root, "*.d", SpanMode.depth)) {
            const text = entry.name.readText;
            if (text.canFind("import " ~ executor) ||
                text.canFind(`imported!"` ~ executor) ||
                text.canFind("import " ~ executors) ||
                text.canFind(`imported!"` ~ executors) ||
                text.canFind("import " ~ executorTests) ||
                text.canFind(`imported!"` ~ executorTests))
                violations ~= entry.name;
        }
    }

    violations.should == string[].init;
}
