module quickbite.ffi.libffi;

// Hand-written extern(C) declarations for the subset of libffi (3.x) that the
// resident native-call chokepoint (quickbite.ffi) needs. No bindbc or libffi
// dev headers: the installed libffi.so exports these symbols, so we declare the
// prototypes ourselves, mirroring orc.bindings. Layout
// verified against /usr/include/ffi.h on x86-64 SysV (sizeof(ffi_cif) == 32,
// sizeof(ffi_type) == 24, no FFI_EXTRA_CIF_FIELDS).

private:

// The dub.sdl `libs "ffi"` drives the actual link; pragma(lib) documents the
// dependency for non-dub builds.
pragma(lib, "ffi");

public:

extern(C):

struct ffi_type {
    size_t size;
    ushort alignment;
    ushort type;
    ffi_type** elements;   // null-terminated; populated for FFI_TYPE_STRUCT
}

struct ffi_cif {
    uint abi;              // ffi_abi
    uint nargs;
    ffi_type** arg_types;
    ffi_type* rtype;
    uint bytes;
    uint flags;
}

enum ffi_status {
    FFI_OK = 0,
    FFI_BAD_TYPEDEF,
    FFI_BAD_ABI,
    FFI_BAD_ARGTYPE,
}

// FFI_DEFAULT_ABI == FFI_UNIX64 == 2 on x86-64 SysV (ffitarget.h).
enum uint FFI_DEFAULT_ABI = 2;

// The `type` tag of a struct ffi_type (ffi.h FFI_TYPE_STRUCT).
enum ushort FFI_TYPE_STRUCT = 13;

ffi_status ffi_prep_cif(
    ffi_cif* cif,
    uint abi,
    uint nargs,
    ffi_type* rtype,
    ffi_type** atypes,
) @nogc nothrow;

// Variadic CIF: `nfixedargs` are the declared fixed parameters, `ntotalargs`
// includes the per-call variadic arguments. Variadic calls cannot share a
// cached non-variadic CIF (ffi.md §34.14).
ffi_status ffi_prep_cif_var(
    ffi_cif* cif,
    uint abi,
    uint nfixedargs,
    uint ntotalargs,
    ffi_type* rtype,
    ffi_type** atypes,
) @nogc nothrow;

void ffi_call(
    ffi_cif* cif,
    void function() fn,
    void* rvalue,
    void** avalue,
) @nogc;

// A libffi closure: a runtime-generated native function pointer whose calls are
// routed back into a handler. The reverse bridge (ffi.md §34.16) uses one per
// interpreted delegate passed into native code. libffi defines it as
// `{ char tramp[FFI_TRAMPOLINE_SIZE]; ffi_cif*; void function(...); void* }`,
// 56 bytes on x86-64 SysV (tramp[32] + three pointers); the opaque blob is
// over-sized so ffi_closure_alloc reserves enough.
struct ffi_closure {
    ubyte[64] _opaque;
}

// The closure handler libffi calls (with the C ABI) when native code invokes
// the trampoline; it must be extern(C) so the (cif, ret, args, user_data)
// arguments are read in C order.
alias ffi_closure_fun =
    extern(C) void function(ffi_cif*, void*, void**, void*);

// ffi_closure_alloc returns the writable closure and writes the executable
// address to `code`; ffi_prep_closure_loc binds the handler; ffi_closure_free
// releases the writable closure.
void* ffi_closure_alloc(size_t size, void** code) @nogc nothrow;
void ffi_closure_free(void* closure) @nogc nothrow;
ffi_status ffi_prep_closure_loc(
    ffi_closure* closure,
    ffi_cif* cif,
    ffi_closure_fun fun,
    void* userData,
    void* codeloc,
) @nogc nothrow;

extern __gshared {
    ffi_type ffi_type_void;
    ffi_type ffi_type_uint8;
    ffi_type ffi_type_sint8;
    ffi_type ffi_type_uint16;
    ffi_type ffi_type_sint16;
    ffi_type ffi_type_uint32;
    ffi_type ffi_type_sint32;
    ffi_type ffi_type_uint64;
    ffi_type ffi_type_sint64;
    ffi_type ffi_type_float;
    ffi_type ffi_type_double;
    ffi_type ffi_type_pointer;
    ffi_type ffi_type_longdouble;
}
