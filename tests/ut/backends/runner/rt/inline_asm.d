module ut.backends.runner.rt.inline_asm;


import ut.backends;


// libdparse's lexer uses inline-asm SSE4.2 (pcmpestri). quickbite's native
// codegen cannot emit inline asm (source/dmd/iasm.d is a no-op shim that drops
// the asm body), so SystemLinker must reject such a module with a clear error
// rather than silently miscompiling it into garbage reads.
@("inlineAsm.rejectedWithClearError.SystemLinker")
@Tags("SystemLinker")
unittest {
    import std.exception: collectExceptionMsg;

    const message = collectExceptionMsg(
        runBackendSourceFixtureTestResults!SystemLinker(q{
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
