// Phase 0 spike, finding 3 (the decisive one): an LDC-compiled host calls a
// DMD-compiled extern(C) function and a DMD-compiled extern(D) function with
// the SAME signature and arguments. extern(C) agrees; extern(D) does not,
// because DMD and LDC pass extern(D) parameters in opposite orders. The
// extern(D) mangled symbol is passed as argv[1] (run.sh reads it from the .so).
module callhost;

import core.stdc.stdio : printf;
import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;

extern(C) int main(int argc, char** argv)
{
    if (argc < 2) { printf("usage: callhost <mangled-extern-D-symbol>\n"); return 2; }

    // auto, not const: the handle is passed on to dlsym, whose parameter is a
    // mutable void*, so const(void*) would not convert.
    auto lib = dlopen("./liblib_dmd.so", RTLD_NOW);
    if (lib is null) { printf("dlopen failed\n"); return 100; }

    auto cf = cast(long function(long, long, long, long) nothrow @nogc) dlsym(lib, "c_combine");
    auto df = cast(long function(long, long, long, long) nothrow @nogc) dlsym(lib, argv[1]);
    if (cf is null || df is null) { printf("dlsym null cf=%p df=%p\n", cf, df); return 101; }

    const cr = cf(1, 2, 3, 4);
    const dr = df(1, 2, 3, 4);
    printf("extern(C) DMD-fn from LDC host: got %ld  expected 1234  -> %s\n",
        cr, cr == 1234 ? "OK".ptr : "MISMATCH".ptr);
    printf("extern(D) DMD-fn from LDC host: got %ld  expected 1234  -> %s\n",
        dr, dr == 1234 ? "OK".ptr : "ABI MISMATCH".ptr);
    return (cr == 1234 && dr == 1234) ? 0 : 1;
}
