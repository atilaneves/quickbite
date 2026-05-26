module ut.executors;


public import ut;
public import quickbite.executor;
public import quickbite: ExecutorName;


private:

import quickbite: ExecutorName;

public enum matureExecutorNames = [
    ExecutorName.ir,
    ExecutorName.treeWalkingOld,
    ExecutorName.dmdCtfe,
];

public enum dmdCodegenRamExecutorNames = [
    ExecutorName.dmdCodegenRam,
];

public enum evalExecutorNames = [
    ExecutorName.ir,
    ExecutorName.treeWalkingOld,
    ExecutorName.treeWalking,
    ExecutorName.dmdCtfe,
];

public bool experimentalExecutorTestsEnabled() {
    import std.process: environment;

    return environment.get("QUICKBITE_EXPERIMENTAL_EXECUTOR_TESTS").length != 0;
}
