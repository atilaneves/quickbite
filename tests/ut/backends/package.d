module ut.backends;


public import ut;
public import quickbite.executor;
public import quickbite: ExecutorBackend;


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

public enum evalBackends = [
    ExecutorBackend.ir,
    ExecutorBackend.treeWalkingOld,
    ExecutorBackend.treeWalking,
    ExecutorBackend.dmdCtfe,
];

public bool experimentalBackendTestsEnabled() {
    import std.process: environment;

    return environment.get("QUICKBITE_EXPERIMENTAL_BACKEND_TESTS").length != 0;
}
