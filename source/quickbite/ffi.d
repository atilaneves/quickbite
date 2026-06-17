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

    return false;
}

private imported!"dmd.mtype".Type parameterType(
    imported!"dmd.mtype".TypeFunction functionType,
    in size_t index,
) {
    return (*functionType.parameterList.parameters)[index].type.toBasetype;
}
