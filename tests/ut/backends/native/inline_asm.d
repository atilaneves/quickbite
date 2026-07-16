module ut.backends.native.inline_asm;


import ut.backends;


// libdparse's lexer uses inline-asm SSE4.2 (pcmpestri). quickbite's native
// codegen cannot emit inline asm (source/dmd/iasm.d is a no-op shim that drops
// the asm body), so both native backends must reject such a module with a
// clear error rather than silently miscompiling it into garbage reads.
static foreach (backend; AliasSeq!(SystemLinker, LLVMJit)) {
    @("inlineAsm.rejectedWithClearError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import std.exception: collectExceptionMsg;

        const message = collectExceptionMsg(
            runBackendSourceFixtureTestResults!backend(q{
                ulong fortyTwo() pure nothrow @trusted @nogc {
                    asm pure nothrow @nogc {
                        naked;
                        mov RAX, 42;
                        ret;
                    }
                }

                unittest {
                    assert(fortyTwo() == 42);
                }
            }));

        "inline asm".should.be in message;
    }
}
