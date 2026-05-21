module ut.projects;

private:

public import quickbite: ExecutorBackend, runTests;
public import std.conv: text;
public import unit_threaded;
public import ut.backends: matureExecutorBackends;

public enum projectBackends = matureExecutorBackends ~ [
    ExecutorBackend.treeWalking,
];

public bool bailsOutNewTreeWalker(in ExecutorBackend backend)
    @safe @nogc nothrow pure
{
    return backend == ExecutorBackend.treeWalking;
}
