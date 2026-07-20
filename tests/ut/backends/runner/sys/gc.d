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
