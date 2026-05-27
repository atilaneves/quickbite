module ut.backends.architecture;


import ut;


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
