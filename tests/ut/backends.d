module ut.backends;

private:

import quickbite: ExecutorBackend;

public enum matureExecutorBackends = [
    ExecutorBackend.ir,
    ExecutorBackend.treeWalkingOld,
    ExecutorBackend.dmdCtfe,
];

public enum dmdCodegenRamExecutorBackends = [
    ExecutorBackend.dmdCodegenRam,
];

public bool experimentalBackendTestsEnabled() {
    import std.process: environment;

    return environment.get("QUICKBITE_EXPERIMENTAL_BACKEND_TESTS").length != 0;
}
