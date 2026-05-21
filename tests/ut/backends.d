module ut.backends;

private:

import quickbite: ExecutorBackend;

public enum matureExecutorBackends = [
    ExecutorBackend.ir,
    ExecutorBackend.treeWalkingOld,
    ExecutorBackend.dmdCtfe,
];
