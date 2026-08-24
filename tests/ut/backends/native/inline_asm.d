module ut.backends.native.inline_asm;


import ut.backends;
import std.meta: AliasSeq;


static foreach (backend; AliasSeq!(SystemLinker, LLVMJit)) {
    @("inlineAsm.executes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
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
        });
    }
}
