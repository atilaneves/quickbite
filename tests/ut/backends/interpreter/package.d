module ut.backends.interpreter;


import ut;
import quickbite.frontend.compiler: parseSnippet;
import dmd.mtype: TypeStruct;


// Parses `source`, finds the `struct` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeStruct`.
public TypeStruct structTypeOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members)
        if (auto struct_ = member.isStructDeclaration)
            if (struct_.ident.toString == name)
                return cast(TypeStruct) struct_.type;

    assert(false, "struct `" ~ name ~ "` not found in parsed snippet");
}
