module quickbite.ffi;

// The backend-neutral FFI bridge (ffi.md §5/§6): symbol resolution, the
// Type->ffi_type mapping, CIF prep, ffi_call, and the native-Throwable
// exception guard. The core never names a backend value type; backends inject
// ABI-byte conversion through the NativeMarshaller seam.

public import quickbite.ffi.core;
