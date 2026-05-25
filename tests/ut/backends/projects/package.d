module ut.backends.projects;


public import ut.backends;


private:

public enum projectBackends = matureExecutorBackends ~ [
    ExecutorBackend.treeWalking,
];

public bool bailsOutNewTreeWalker(in ExecutorBackend backend)
    @safe @nogc nothrow pure
{
    return backend == ExecutorBackend.treeWalking;
}
