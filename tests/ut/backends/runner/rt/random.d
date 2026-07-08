module ut.backends.runner.rt.random;


import ut.backends;


// std.random's `unpredictableSeed` reads std.internal.entropy's module-scope
// `static EntropySource _entropySource = defaultEntropySource;`, where
// `defaultEntropySource` is a symbol from a mixin-template instance in the same
// module. Only root modules get semantic2, so that imported (non-root) Phobos
// module leaves the initializer as an unresolved `IdentifierExp`: the
// interpreter's dataseg materialization fell over with "Unsupported eval
// expression: identifier" (ai/plans/interpreter.md Rung 9). rt/ because the
// green path reads the platform entropy source (getrandom / /dev/urandom via
// the posix FFI machinery). A sandbox import-path module does not reproduce it:
// user imports are root-promoted and get semantic2, so this must lean on a real
// archive (Phobos) module.
//
// Interpreter is omitted (its omission is the documentation, per plan §8): the
// Rung 9 fix (resolveNonRootInitializer) resolves the initializer — the
// `identifier` error is gone — but the entropy read then reaches the getrandom
// scalar-buffer FFI fill (`buffer[0 .. length]` over `&(uint)`), which is a
// deeper marshalling gap owned by ai/plans/ffi.md §35.11, not this rung. The
// Rung 9 fix's own evidence is the cerealed re-measure (the 21x `identifier`
// class is gone). Ctfe (no getrandom source) and BytecodeNewCore are likewise
// omitted.
static foreach (backend; AliasSeq!(SystemLinker, LLVMJit)) {
    @("random.unpredictableSeedReadsNonRootInitializer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                import std.random: Random, uniform, unpredictableSeed;

                auto rng = Random(unpredictableSeed);
                const draw = uniform(0, 10, rng);

                assert(draw >= 0 && draw < 10);
            }
        });
    }
}
