module ut.backends.runner.sys.gc;


import ut.backends;


// Every `core.memory.GC.*` leaf that takes a `TypeInfo` defaults it as a
// trailing `const TypeInfo ti = null` parameter (a class reference, not a
// raw pointer). `GC.extend` only ever grows large-object (page-allocated)
// blocks; a small, pool-bin allocation can never be extended in place, so
// this leaf deterministically reports zero bytes of growth for a small
// allocation regardless of host GC internals, matching `SystemLinker` byte
// for byte.
enum extendSmallAllocationSource = q{
    unittest {
        import core.memory: GC;

        auto p = GC.malloc(16);
        scope(exit) GC.free(p);

        const grew = GC.extend(p, 1000, 2000);

        assert(grew == 0);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot access the host environment (libc/OS)"),
)) {
    @("extend.smallAllocation.defaultedTypeInfoArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(extendSmallAllocationSource);
    }
}

// Supplying a real TypeInfo object to the host GC is a native ABI operation;
// its address must not be replaced with the interpreter's display-only type.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot access the host environment (libc/OS)"),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("malloc.typeInfoArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                import core.memory: GC;

                auto p = GC.malloc(int.sizeof, 0, typeid(int));
                assert(p !is null);
                GC.free(p);
            }
        });
    }
}

// A dynamic array's contents must survive a collection cycle that runs while
// the array is still reachable only through the local variable holding it, no
// matter how many other allocations happen in between. `GC.collect` can
// reclaim and reuse any block the collector cannot prove reachable, so this
// would read back mixed-up values from unrelated allocations if the backend's
// own storage for the local variable is invisible to the collector.
enum collectDoesNotCorruptReachableArraySource = q{
    unittest {
        import core.memory: GC;

        size_t len = 4;
        ++len; // 5, kept out of `new int[](len)` as a runtime value

        auto original = new int[](len);
        int base = 42;
        foreach (i; 0 .. len)
            original[i] = base + cast(int) i;

        int rounds = 19;
        ++rounds; // 20
        foreach (round; 0 .. rounds) {
            GC.collect;

            int junkCount = 199;
            ++junkCount; // 200
            foreach (junk; 0 .. junkCount) {
                auto scratch = new int[](len);
                foreach (i; 0 .. len)
                    scratch[i] = junk + cast(int) i;
            }
        }

        int sum;
        foreach (v; original)
            sum += v;

        assert(sum == 42 + 43 + 44 + 45 + 46);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot force a collection cycle"),
)) {
    @("collect.doesNotCorruptReachableArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(
            collectDoesNotCorruptReachableArraySource,
        );
    }
}
