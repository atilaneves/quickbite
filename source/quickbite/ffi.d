module quickbite.ffi;

private:


public bool tryCallResidentNative(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"quickbite.lang".Value[] arguments,
    out imported!"quickbite.lang".Value result,
) {
    import core.sys.posix.dlfcn: dlsym;
    version (DragonFlyBSD) import core.sys.dragonflybsd.dlfcn: RTLD_DEFAULT;
    version (FreeBSD) import core.sys.freebsd.dlfcn: RTLD_DEFAULT;
    version (linux) import core.sys.linux.dlfcn: RTLD_DEFAULT;
    version (NetBSD) import core.sys.netbsd.dlfcn: RTLD_DEFAULT;
    version (OpenBSD) import core.sys.openbsd.dlfcn: RTLD_DEFAULT;
    version (OSX) import core.sys.darwin.dlfcn: RTLD_DEFAULT;
    version (Solaris) import core.sys.solaris.dlfcn: RTLD_DEFAULT;
    import dmd.astenums: LINK, TY;
    import dmd.mangle: mangleExact;
    import dmd.mtype: TypeFunction;
    import quickbite.lang: Value;
    import std.string: fromStringz;

    if (function_._linkage != LINK.c)
        return false;

    auto type = cast(TypeFunction) function_.type;
    if (type is null)
        return false;

    const returnType = type.next.toBasetype;
    const symbol = dlsym(RTLD_DEFAULT, mangleExact(function_));
    if (symbol is null)
        throw new Exception(
            "Resident native symbol `" ~
            fromStringz(mangleExact(function_)).idup ~
            "` is not loaded",
        );

    if (
        returnType.ty == TY.Tpointer &&
        arguments.length == 1 &&
        parameterType(type, 0).ty == TY.Tuns64
    ) {
        alias NativeFunction = extern(C) void* function(size_t);
        auto nativeFunction = cast(NativeFunction) symbol;
        result = Value.nativePointerValue(nativeFunction(
            cast(size_t) arguments[0].asLong,
        ));
        return true;
    }

    if (
        returnType.ty == TY.Tpointer &&
        arguments.length == 2 &&
        parameterType(type, 0).ty == TY.Tuns64 &&
        parameterType(type, 1).ty == TY.Tuns64
    ) {
        alias NativeFunction = extern(C) void* function(size_t, size_t);
        auto nativeFunction = cast(NativeFunction) symbol;
        result = Value.nativePointerValue(nativeFunction(
            cast(size_t) arguments[0].asLong,
            cast(size_t) arguments[1].asLong,
        ));
        return true;
    }

    if (
        returnType.ty == TY.Tpointer &&
        arguments.length == 2 &&
        parameterType(type, 0).ty == TY.Tpointer &&
        parameterType(type, 1).ty == TY.Tuns64
    ) {
        alias NativeFunction = extern(C) void* function(void*, size_t);
        auto nativeFunction = cast(NativeFunction) symbol;
        result = Value.nativePointerValue(nativeFunction(
            arguments[0].asNativePointer,
            cast(size_t) arguments[1].asLong,
        ));
        return true;
    }

    if (
        returnType.ty == TY.Tvoid &&
        arguments.length == 1 &&
        parameterType(type, 0).ty == TY.Tpointer
    ) {
        alias NativeFunction = extern(C) void function(void*);
        auto nativeFunction = cast(NativeFunction) symbol;
        nativeFunction(arguments[0].asNativePointer);
        result = Value.void_;
        return true;
    }

    if (
        returnType.ty == TY.Tint32 &&
        arguments.length == 1 &&
        parameterType(type, 0).ty == TY.Tpointer
    ) {
        alias NativeFunction = extern(C) int function(const(char)*);
        auto nativeFunction = cast(NativeFunction) symbol;
        result = Value(nativeFunction(nativeString(arguments[0])));
        return true;
    }

    // div(int, int) / ldiv(long, long): a {quot, rem} struct returned by
    // value through the SysV ABI, mapped back to a backend struct value.
    if (
        returnType.ty == TY.Tstruct &&
        arguments.length == 2 &&
        parameterType(type, 0).ty == TY.Tint32 &&
        parameterType(type, 1).ty == TY.Tint32
    ) {
        static struct DivResult { int quot; int rem; }
        alias NativeFunction = extern(C) DivResult function(int, int);
        const divided = (cast(NativeFunction) symbol)(
            cast(int) arguments[0].asLong,
            cast(int) arguments[1].asLong,
        );
        result = Value.structValue(
            "div_t",
            [Value(divided.quot), Value(divided.rem)],
        );
        return true;
    }

    if (
        returnType.ty == TY.Tstruct &&
        arguments.length == 2 &&
        parameterType(type, 0).ty == TY.Tint64 &&
        parameterType(type, 1).ty == TY.Tint64
    ) {
        static struct LDivResult { long quot; long rem; }
        alias NativeFunction = extern(C) LDivResult function(long, long);
        const divided = (cast(NativeFunction) symbol)(
            arguments[0].asLong,
            arguments[1].asLong,
        );
        result = Value.structValue(
            "ldiv_t",
            [Value(divided.quot), Value(divided.rem)],
        );
        return true;
    }

    return false;
}

// Marshal a backend value into a NUL-terminated C string valid for the
// duration of the native call. A native pointer is passed straight through;
// a backend char array is copied into a GC-owned NUL-terminated buffer.
private const(char)* nativeString(in imported!"quickbite.lang".Value value) {
    import std.string: toStringz;

    if (value.isNativePointer)
        return cast(const(char)*) value.asNativePointer;

    return value.asCharArrayString.toStringz;
}

private imported!"dmd.mtype".Type parameterType(
    imported!"dmd.mtype".TypeFunction functionType,
    in size_t index,
) {
    return (*functionType.parameterList.parameters)[index].type.toBasetype;
}
