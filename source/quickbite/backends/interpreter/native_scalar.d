module quickbite.backends.interpreter.native_scalar;


private:


// A typed leaf codec between a D scalar type and its host-native byte layout.
// Frame, module, aggregate, and borrowed places use it through typed reads and
// writes, so `*cast(T*) &local` loads the same bytes at the pointee's static
// type.
//
// `real`/`TY.Tfloat80` is deliberately excluded from `isNativeScalarType`:
// an x86 80-bit extended-precision `real` occupies a host- and
// ABI-specific padded size (10 significant bytes inside a 12- or 16-byte
// slot, depending on platform and alignment) that `layout.typeByteSize`
// reports correctly for THIS host, but treating it as a byte-for-byte portable
// native scalar the way `float`/`double` are would bake in that padding as if
// it were a stable cross-host fact. `place_value.d` owns the host-specific
// `real` codec instead.
//
// Native-call operands and results now cross the FFI seam as typed places, so
// this codec remains the interpreter's single scalar<->bytes authority there
// too. A closure/callback result for a narrow scalar is first written through
// that ordinary typed place, then `native_call_adapter.d` extends only the
// libffi `ffi_arg` scratch tail for ABI correctness.


// `dmd.mtype.Type.toBasetype` is not `@safe`; this is the `@trusted`
// boundary shared by every function below that needs to classify a type --
// it only reads DMD's own already-resolved base type, no arithmetic of our
// own, matching `layout.d`'s `typeHasPointersImpl`/`typeByteSizeImpl` habit
// of one small trusted wrapper per DMD call. Resolving `toBasetype` here
// (rather than trusting a caller-supplied basetype) also makes an enum
// type's integral base type dispatch correctly without a caller having to
// know to unwrap it first.
public imported!"dmd.astenums".TY nativeScalarKindOf(
    imported!"dmd.mtype".Type type,
) @trusted {
    return type.toBasetype.ty;
}


// True for the D scalar types this codec's typed operations handle: `bool`,
// the `char`/`wchar`/`dchar` family, every integral width, and
// `float`/`double`. An `enum` whose base type is one of these also
// answers `true`, since `nativeScalarKindOf` dispatches on the resolved
// base type. See this module's header comment for why `real` (`TY.
// Tfloat80`) is excluded.
public bool isNativeScalarType(imported!"dmd.mtype".Type type) @safe {
    import dmd.astenums: TY;

    switch (nativeScalarKindOf(type)) with (TY) {
        case Tbool, Tchar, Twchar, Tdchar,
             Tint8, Tuns8, Tint16, Tuns16,
             Tint32, Tuns32, Tint64, Tuns64,
             Tfloat32, Tfloat64:
            return true;

        default:
            return false;
    }
}


// Writes a scalar that is already in the host type selected by the caller.
// Construction helpers use this path when DMD has already fixed the guest
// type. It avoids creating an ExpressionResult only to write its bytes out.
public void writeNativeScalar(T)(
    imported!"dmd.mtype".Type type,
    ubyte[] dest,
    in T value,
) @trusted {
    import core.stdc.string: memcpy;
    import quickbite.backends.interpreter.layout: typeByteSize;

    if (dest.length != typeByteSize(type) || dest.length != T.sizeof)
        throw new Exception(
            "quickbite.backends.interpreter.native_scalar.writeNativeScalar: "
            ~ "destination size does not match the scalar type",
        );

    // @trusted: memcpy handles the possibly unaligned interior destination;
    // the checks above prove that it writes exactly the destination width.
    memcpy(&dest[0], &value, T.sizeof);
}


// Reads `src`'s bytes into the host scalar type selected by the caller.
// The caller selects `T` from the DMD expression type; this leaf codec does
// not reconstruct a transient interpreter value. `src.length` must equal
// both the DMD layout size and `T.sizeof`, enforced with unconditional
// throws for the same safety reason as `writeNativeScalar`.
public T readNativeScalar(T)(
    imported!"dmd.mtype".Type type,
    in ubyte[] src,
) @trusted {
    import core.stdc.string: memcpy;
    import quickbite.backends.interpreter.layout: typeByteSize;

    if (src.length != typeByteSize(type) || src.length != T.sizeof)
        throw new Exception(
            "quickbite.backends.interpreter.native_scalar.readNativeScalar: "
            ~ "source size does not match the scalar type",
        );

    T value;
    // @trusted: the checks above prove the copy reads exactly the scalar
    // local's width, and memcpy accepts an unaligned source address.
    memcpy(&value, src.ptr, T.sizeof);
    return value;
}
