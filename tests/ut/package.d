module ut;


public import unit_threaded;
public import quickbite;


private:

public string tempModuleDir(in string suffix) {
    import std.path: buildPath;
    import std.file: tempDir;

    return buildPath(tempDir, "quickbite-compiler-api", suffix);
}
