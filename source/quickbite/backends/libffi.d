module quickbite.backends.libffi;

// Hand-written extern(C) declarations for the subset of libffi (3.x) that the
// resident native-call chokepoint (quickbite.backends.ffi) needs. No bindbc or
// libffi dev headers: the installed libffi.so exports these symbols, so we
// declare the prototypes ourselves, mirroring
// quickbite.backends.native.llvm_orc. Layout verified against
// /usr/include/ffi.h on x86-64 SysV (sizeof(ffi_cif) == 32,
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

void ffi_call(
    ffi_cif* cif,
    void function() fn,
    void* rvalue,
    void** avalue,
) @nogc;

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
