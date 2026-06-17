module quickbite.backends.native.evaluator;


private:


public imported!"quickbite.backends.evaluator".EvalResult evalNativeFunction(
    scope imported!"quickbite.lang".Value delegate() call,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.evaluator: displayEvalResult;

    return displayEvalResult(call, function_);
}

public imported!"quickbite.lang".Value callNativeFunction(
    void* address,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.lang: Value;
    import dmd.astenums: TY;
    import std.conv: text;

    auto returnType = function_.type.nextOf.toBasetype;
    switch (returnType.ty) with (TY) {
        case Tvoid:
            (cast(void function()) address)();
            return Value.void_;
        case Tint32:
            return Value((cast(int function()) address)());
        case Tuns32:
            return Value((cast(uint function()) address)());
        case Tbool:
            return Value((cast(bool function()) address)());
        case Tint8:
            return Value((cast(byte function()) address)());
        case Tuns8:
            return Value((cast(ubyte function()) address)());
        case Tint16:
            return Value((cast(short function()) address)());
        case Tuns16:
            return Value((cast(ushort function()) address)());
        case Tint64:
            return Value((cast(long function()) address)());
        case Tuns64:
            return Value((cast(ulong function()) address)());
        case Tchar:
            return Value((cast(char function()) address)());
        case Tfloat32:
            return Value((cast(float function()) address)());
        case Tfloat64:
            return Value((cast(double function()) address)());
        case Tfloat80:
            return Value((cast(real function()) address)());
        case Tnull:
            (cast(void* function()) address)();
            return Value.null_;
        default:
            throw new Exception(text(
                "native evaluator does not support return type ",
                returnType.toChars,
            ));
    }
}
