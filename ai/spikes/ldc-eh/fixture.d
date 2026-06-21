// Phase 0 spike fixture (finding 1): DMD-backend codegen of throw+catch.
// Compiled with `dmd` (same EH ABI as the embedded dmd-backend), then linked
// into a .so WITHOUT DMD's libphobos2 so druntime symbols stay undefined. run.sh
// enumerates that undefined set against LDC's shared druntime to show the
// DMD-only symbol gap. The throw/catch shape is what forces the EH symbols to
// appear; the .so is not executed (finding 3 shows why that would crash).
module fixture;

import core.stdc.stdio : printf;

// returns: 0 = caught nothing (unexpected), 1 = caught the expected throw,
//          2 = caught an unexpected Throwable
extern(C) int run_caught() nothrow
{
    try
    {
        throw new Exception("boom");
    }
    catch (Exception e)
    {
        printf("fixture: caught Exception in DMD frame\n");
        return 1;
    }
    catch (Throwable t)
    {
        return 2;
    }
}

// An assert(false) -> AssertError path, also caught internally.
extern(C) int run_assert() nothrow
{
    try
    {
        assert(false, "assert-boom");
    }
    catch (Throwable t)
    {
        printf("fixture: caught AssertError-class in DMD frame\n");
        return 1;
    }
}
