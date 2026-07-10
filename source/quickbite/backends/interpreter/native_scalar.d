module quickbite.backends.interpreter.native_scalar;


private:


// A leaf codec between the interpreter's boxed scalar `quickbite.lang.Value`
// and the host's native byte layout for a D scalar type. This is
// `ai/plans/value.md` item 7's first production call site for the
// native-layout container types (`native_block.d`/`native_array.d`/
// `native_struct.d`): `impl.d`'s `reinterpretLocalPointerLoad` allocates a
// `NativeBlock`, `writeScalar`s the source local's bits into it, and
// `readScalar`s the target type back out, so `*cast(T*) &local` becomes a
// load of the same bytes at a different static type instead of a hardcoded
// name/type-pair match.
//
// `real`/`TY.Tfloat80` is deliberately excluded from `isNativeScalarType`:
// an x86 80-bit extended-precision `real` occupies a host- and
// ABI-specific padded size (10 significant bytes inside a 12- or 16-byte
// slot, depending on platform and alignment) that `layout.typeByteSize`
// reports correctly for THIS host, but treating it as a byte-for-byte
// portable native scalar the way `float`/`double` are would bake in that
// padding as if it were a stable cross-host fact. Nothing this commit's
// call site needs (the two pinned float/uint and double/ulong fixtures)
// requires `real`; excluding it keeps this codec's claims honest rather
// than silently wrong on a host whose padding differs.
//
// This duplicates a narrower version of `ffi_marshal.d`'s scalar
// encode/decode (`marshalArgument`'s integral/float cases and
// `unmarshalValue`'s counterpart, ~lines 645-660 and 907-923): both convert
// between a boxed `Value` and the same host-native bit pattern for the same
// set of scalar `TY` kinds. `ffi_marshal.d` is deliberately left unchanged
// here (its buffer is a libffi ABI cell, not a `NativeBlock`, and touching
// it is out of scope for this call site); consolidating the two into one
// shared codec is future work, not done in this commit.


// `dmd.mtype.Type.toBasetype` is not `@safe`; this is the `@trusted`
// boundary shared by every function below that needs to classify a type --
// it only reads DMD's own already-resolved base type, no arithmetic of our
// own, matching `layout.d`'s `typeHasPointersImpl`/`typeByteSizeImpl` habit
// of one small trusted wrapper per DMD call. Resolving `toBasetype` here
// (rather than trusting a caller-supplied basetype) also makes an enum
// type's integral base type dispatch correctly without a caller having to
// know to unwrap it first.
private imported!"dmd.astenums".TY nativeScalarKindOf(
    imported!"dmd.mtype".Type type,
) @trusted {
    return type.toBasetype.ty;
}


// True for the D scalar types this codec's `writeScalar`/`readScalar`
// handle: `bool`, the `char`/`wchar`/`dchar` family, every integral width,
// and `float`/`double`. An `enum` whose base type is one of these also
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


// Writes `value`'s bits into `dest` in the host's own native layout for
// `type`. `dest.length` must equal `layout.typeByteSize(type)`; this is
// enforced with an unconditional throw rather than only an `in` contract,
// because contracts are stripped under `-release` and this function's
// safety (the `memcpy` below never running past `dest`'s bounds) must hold
// in every build mode -- the same reasoning `native_array.d`'s
// `readSliceHeaderBytes` gives for its own unconditional length check.
public void writeScalar(
    imported!"dmd.mtype".Type type,
    ubyte[] dest,
    in imported!"quickbite.lang".Value value,
) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize;

    if (dest.length != typeByteSize(type))
        throw new Exception(
            "quickbite.backends.interpreter.native_scalar.writeScalar: "
            ~ "dest.length does not match layout.typeByteSize(type)",
        );

    writeScalarBits(nativeScalarKindOf(type), dest, value);
}


// The integer bits behind an integral/`bool`/character `Value`, widened to
// `long` -- mirrors `ffi_marshal.d`'s local `scalarBits` helper (~lines
// 722-737): a character value's bits are its code point (`castTo!long`),
// matching that module's own scalar marshalling so this codec agrees with
// it rather than silently drifting (see this module's header comment on the
// duplication).
private long scalarLong(in imported!"quickbite.lang".Value value) @safe {
    return value.isCharacter ? value.castTo!long.asLong : value.asLong;
}


// @trusted: `memcpy`s a same-sized native value's bits into `dest`.
// `writeScalar` above has already verified, with an unconditional throw,
// that `dest.length` equals the exact width `kind` needs before calling
// here, so every case below writes precisely `dest.length` bytes -- never
// past its bounds. `memcpy`, not a pointer-typed store: `dest` is an
// interior view into a `NativeBlock` at an arbitrary byte offset, not
// guaranteed to be aligned for a pointer-typed write of its element type,
// the same alignment reason `native_array.d`'s `writeSliceHeaderBytes`/
// `readSliceHeaderBytes` give for using `memcpy` themselves.
private void writeScalarBits(
    imported!"dmd.astenums".TY kind,
    ubyte[] dest,
    in imported!"quickbite.lang".Value value,
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


// The inverse of `writeScalar`: reads `src`'s bytes back as `type`'s own
// native layout. `src.length` must equal `layout.typeByteSize(type)`,
// enforced the same unconditional-throw way `writeScalar` enforces
// `dest.length`, for the same reason.
public imported!"quickbite.lang".Value readScalar(
    imported!"dmd.mtype".Type type,
    in ubyte[] src,
) @safe {
    import quickbite.backends.interpreter.layout: typeByteSize;

    if (src.length != typeByteSize(type))
        throw new Exception(
            "quickbite.backends.interpreter.native_scalar.readScalar: "
            ~ "src.length does not match layout.typeByteSize(type)",
        );

    return readScalarBits(nativeScalarKindOf(type), src);
}


// @trusted: `memcpy`s exactly `src.length` bytes (already verified by
// `readScalar` above to equal the native width for `kind`) into a
// same-sized local, then boxes it -- the read-side counterpart of
// `writeScalarBits`, with the same alignment reasoning for using `memcpy`
// over a pointer-typed load.
private imported!"quickbite.lang".Value readScalarBits(
    imported!"dmd.astenums".TY kind,
    in ubyte[] src,
) @trusted {
    import core.stdc.string: memcpy;
    import dmd.astenums: TY;
    import quickbite.lang: Value;

    switch (kind) with (TY) {
        case Tbool: {
            bool bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tchar: {
            char bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Twchar: {
            wchar bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tdchar: {
            dchar bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tint8: {
            byte bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tuns8: {
            ubyte bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tint16: {
            short bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tuns16: {
            ushort bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tint32: {
            int bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tuns32: {
            uint bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tint64: {
            long bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tuns64: {
            ulong bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tfloat32: {
            float bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        case Tfloat64: {
            double bits;
            memcpy(&bits, src.ptr, bits.sizeof);
            return Value(bits);
        }

        default:
            throw new Exception(
                "quickbite.backends.interpreter.native_scalar.readScalar: "
                ~ "unsupported native scalar type",
            );
    }
}
