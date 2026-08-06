module ut.ffi.ffi;


import dmd.astenums: LINK;
import dmd.mtype: Type;
import quickbite.ffi.ffi: Callable, CompilerAbi, TypedAddress, call;
import unit_threaded;


@("ffi.addressOnlyExternCScalarCall")
unittest {
    int lhs = 4;
    int rhs = 7;
    int result;

    call(
        Callable(cast(void*) &encodeArguments, LINK.c, CompilerAbi.dmd),
        [
            TypedAddress(Type.tint32, &lhs),
            TypedAddress(Type.tint32, &rhs),
        ],
        TypedAddress(Type.tint32, &result),
    ).should == true;

    result.should == 47;
}


private extern(C) int encodeArguments(int lhs, int rhs) {
    return lhs * 10 + rhs;
}
