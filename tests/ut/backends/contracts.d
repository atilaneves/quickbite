module ut.backends.contracts;


import ut.backends;


private:

@("runTests.shouldThrowFailsWhenExpressionDoesNotThrow")
unittest {
    import quickbite: runTests;
    import ut.dub_paths: dubImportPaths;

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(q{
                import unit_threaded;

                unittest {
                    shouldThrow(1);
                }
            }, dubImportPaths, backend).shouldThrow;
        }
    }
}

@("runTests.shouldThrowWithMessageChecksMessage")
unittest {
    import quickbite: runTests;
    import ut.dub_paths: dubImportPaths;

    static foreach (backend; matureExecutorBackends) {
        {
            runTests(q{
                import unit_threaded;

                void throwActual() {
                    throw new Exception("actual");
                }

                unittest {
                    shouldThrowWithMessage(throwActual, "expected");
                }
            }, dubImportPaths, backend).shouldThrow;
        }
    }
}

@("runTests.dmdCtfeFallbackReportsFailingUnittest")
unittest {
    import quickbite: ExecutorBackend, runTests;

    runTests(q{
        void set(out int x) {
            x = 42;
        }

        unittest {
            int x;
            set(x);
            assert(x == 42);
        }

        bool nope() {
            return false;
        }

        void fail() {
            assert(nope());
        }

        unittest {
            fail();
        }
    }, ExecutorBackend.dmdCtfe).shouldThrowWithMessage("false != true");
}
