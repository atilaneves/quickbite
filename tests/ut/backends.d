module ut.backends;

private:

import quickbite: ExecutorBackend;

public enum matureExecutorBackends = [
    ExecutorBackend.ir,
    ExecutorBackend.treeWalkingOld,
    ExecutorBackend.dmdCtfe,
];

public enum evalBackends = [
    ExecutorBackend.ir,
    ExecutorBackend.treeWalkingOld,
    ExecutorBackend.treeWalking,
    ExecutorBackend.dmdCtfe,
    ExecutorBackend.bytecode,
];

public bool experimentalBackendTestsEnabled() {
    import std.process: environment;

    return environment.get("QUICKBITE_EXPERIMENTAL_BACKEND_TESTS").length != 0;
}
