module ut.backends.pure_.projects;


public import ut.backends;


private:

public enum projectBackends = matureExecutorBackends ~ [
    ExecutorBackend.treeWalking,
];
