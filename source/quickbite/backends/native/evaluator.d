module quickbite.backends.native.evaluator;


private:


public imported!"quickbite.backends.evaluator".EvalResult evalNativeFunction(
    scope string delegate() call,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.evaluator: displayEvalResult;

    return displayEvalResult(call, function_);
}

public string callNativeFunction(
    void* address,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: TY;
    import std.conv: text;

    auto returnType = function_.type.nextOf.toBasetype;
    switch (returnType.ty) with (TY) {
        case Tvoid:
            (cast(void function()) address)();
            return "";
        case Tint32:
            return text((cast(int function()) address)());
        case Tuns32:
            return text((cast(uint function()) address)(), "u");
        case Tbool:
            return text((cast(bool function()) address)());
        case Tint8:
            return text((cast(byte function()) address)());
        case Tuns8:
            return text((cast(ubyte function()) address)());
        case Tint16:
            return text((cast(short function()) address)());
        case Tuns16:
            return text((cast(ushort function()) address)());
        case Tint64:
            return text((cast(long function()) address)(), "L");
        case Tuns64:
            return text((cast(ulong function()) address)(), "UL");
        case Tchar:
            return text("'", (cast(char function()) address)(), "'");
        case Tfloat32:
            return decimalText((cast(float function()) address)()) ~ "f";
        case Tfloat64:
            return decimalText((cast(double function()) address)());
        case Tfloat80:
            return decimalText((cast(real function()) address)()) ~ "L";
        case Tnull:
            (cast(void* function()) address)();
            return "null";
        default:
            throw new Exception(text(
                "native evaluator does not support return type ",
                returnType.toChars,
            ));
    }
}

private string decimalText(T)(in T value) @safe pure {
    import std.algorithm: canFind;
    import std.conv: text;

    const result = text(value);
    return result.canFind('.', 'e', 'E', "inf", "nan") ? result : result ~ ".0";
}
