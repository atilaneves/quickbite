module quickbite.backends.interpreter.native_scalar;


private:


// A typed leaf codec between a D scalar type and its host-native byte layout.
// Frame, module, aggregate, and borrowed places use it through typed reads and
// writes, so `*cast(T*) &local` loads the same bytes at the pointee's static
// type. The carrier adapters below exist only for unit tests.
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


// Unit-test adapter for the former scalar carrier boundary. Production code
// uses typed `Place.storeNativeScalar` or `runtime_casts.castValue`.
// `dest.length` must equal `layout.typeByteSize(type)`.
deprecated("Use typed native scalar writes or runtime_casts.castValue.")
public void writeScalar(
    imported!"dmd.mtype".Type type,
    ubyte[] dest,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize;

    if (dest.length != typeByteSize(type))
        throw new Exception(
            "quickbite.backends.interpreter.native_scalar.writeScalar: "
            ~ "dest.length does not match layout.typeByteSize(type)",
        );

    writeScalarBits(nativeScalarKindOf(type), dest, value);
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


// @trusted: `memcpy`s a same-sized native value's bits into `dest`.
// The unit-test adapter above has already verified, with an unconditional
// throw, that `dest.length` equals the exact width `kind` needs before calling
// here, so every case below writes precisely `dest.length` bytes -- never
// past its bounds. `memcpy`, not a pointer-typed store: `dest` is an
// interior view into a `NativeBlock` at an arbitrary byte offset, not
// guaranteed to be aligned for a pointer-typed write of its element type,
// the same alignment reason `native_array.d`'s `writeSliceHeaderBytes`/
// `readSliceHeaderBytes` give for using `memcpy` themselves.
private void writeScalarBits(
    imported!"dmd.astenums".TY kind,
    ubyte[] dest,
    in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value,
) @trusted {
    import core.stdc.string: memcpy;
    import dmd.astenums: TY;

    switch (kind) with (TY) {
        case Tbool: {
            const bits = cast(ubyte) (scalarLong(value) != 0);
            memcpy(dest.ptr, &bits, bits.sizeof);
            return;
        }

        case Tint8, Tuns8, Tchar: {
            const bits = cast(ubyte) scalarLong(value);
            memcpy(dest.ptr, &bits, bits.sizeof);
            return;
        }

        case Tint16, Tuns16, Twchar: {
            const bits = cast(ushort) scalarLong(value);
            memcpy(dest.ptr, &bits, bits.sizeof);
            return;
        }

        case Tint32, Tuns32, Tdchar: {
            const bits = cast(uint) scalarLong(value);
            memcpy(dest.ptr, &bits, bits.sizeof);
            return;
        }

        case Tint64, Tuns64: {
            const bits = cast(ulong) scalarLong(value);
            memcpy(dest.ptr, &bits, bits.sizeof);
            return;
        }

        case Tfloat32: {
            const bits = cast(float) value.asReal;
            memcpy(dest.ptr, &bits, bits.sizeof);
            return;
        }

        case Tfloat64: {
            const bits = cast(double) value.asReal;
            memcpy(dest.ptr, &bits, bits.sizeof);
            return;
        }

        default:
            throw new Exception(
                "quickbite.backends.interpreter.native_scalar.writeScalar: "
                ~ "unsupported native scalar type",
            );
    }
}


// The integer bits behind an integral/`bool`/character `ExpressionResult`,
// widened to `long`. A character value's bits are its code point
// (`castTo!long`).
private long scalarLong(in imported!"quickbite.backends.interpreter.expression_result".ExpressionResult value) @safe {
    return value.isCharacter ? value.castTo!long.asLong : value.asLong;
}


// Reads `src`'s bytes into the host scalar type selected by the caller.
// The caller selects `T` from the DMD expression type; this leaf codec does
// not reconstruct a transient interpreter value. `src.length` must equal
// both the DMD layout size and `T.sizeof`, enforced with unconditional throws
// for the same safety reason as `writeScalar`.
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


// Unit-test adapter for the former scalar carrier boundary. Production code
// uses `readNativeScalar` or `Place.loadNativeScalar` with a statically
// selected host type. This wrapper reconstructs the legacy carrier only after
// the typed read has completed.
deprecated("Use readNativeScalar with a statically selected host type.")
public imported!"quickbite.backends.interpreter.expression_result".ExpressionResult readScalar(
    imported!"dmd.mtype".Type type,
    in ubyte[] src,
) @safe {
    import dmd.astenums: TY;
    import quickbite.backends.interpreter.expression_result: ExpressionResult;

    switch (nativeScalarKindOf(type)) with (TY) {
        case Tbool:
            return ExpressionResult(readNativeScalar!bool(type, src));
        case Tchar:
            return ExpressionResult(readNativeScalar!char(type, src));
        case Twchar:
            return ExpressionResult(readNativeScalar!wchar(type, src));
        case Tdchar:
            return ExpressionResult(readNativeScalar!dchar(type, src));
        case Tint8:
            return ExpressionResult(readNativeScalar!byte(type, src));
        case Tuns8:
            return ExpressionResult(readNativeScalar!ubyte(type, src));
        case Tint16:
            return ExpressionResult(readNativeScalar!short(type, src));
        case Tuns16:
            return ExpressionResult(readNativeScalar!ushort(type, src));
        case Tint32:
            return ExpressionResult(readNativeScalar!int(type, src));
        case Tuns32:
            return ExpressionResult(readNativeScalar!uint(type, src));
        case Tint64:
            return ExpressionResult(readNativeScalar!long(type, src));
        case Tuns64:
            return ExpressionResult(readNativeScalar!ulong(type, src));
        case Tfloat32:
            return ExpressionResult(readNativeScalar!float(type, src));
        case Tfloat64:
            return ExpressionResult(readNativeScalar!double(type, src));
        default:
            throw new Exception(
                "quickbite.backends.interpreter.native_scalar.readScalar: "
                ~ "unsupported native scalar type",
            );
    }
}
