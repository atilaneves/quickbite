module ut.backends.interpreter.native_scalar;


import ut;
import ut.backends.interpreter: enumTypeOf;
import quickbite.backends.interpreter.native_scalar: isNativeScalarType;
import dmd.mtype: Type;

private:


@("isNativeScalarType.trueForBool")
unittest {
    isNativeScalarType(Type.tbool).should == true;
}


@("isNativeScalarType.trueForEveryIntegralWidth")
unittest {
    foreach (type; [
        Type.tint8, Type.tuns8,
        Type.tint16, Type.tuns16,
        Type.tint32, Type.tuns32,
        Type.tint64, Type.tuns64,
    ])
        isNativeScalarType(type).should == true;
}


@("isNativeScalarType.trueForEveryCharacterWidth")
unittest {
    foreach (type; [Type.tchar, Type.twchar, Type.tdchar])
        isNativeScalarType(type).should == true;
}


@("isNativeScalarType.trueForFloatAndDouble")
unittest {
    isNativeScalarType(Type.tfloat32).should == true;
    isNativeScalarType(Type.tfloat64).should == true;
}


// `real` is deliberately unsupported: its 80-bit extended-precision layout
// is host- and ABI-specific padding, not a portable byte-for-byte native
// scalar (see native_scalar.d's header comment).
@("isNativeScalarType.falseForReal")
unittest {
    isNativeScalarType(Type.tfloat80).should == false;
}


@("isNativeScalarType.falseForPointer")
unittest {
    isNativeScalarType(Type.tvoidptr).should == false;
}


@("isNativeScalarType.trueForAnEnumWithAnIntegralBaseType")
unittest {
    auto type = enumTypeOf(q{ enum E : int { a, b, c } }, "E");

    isNativeScalarType(type).should == true;
}
