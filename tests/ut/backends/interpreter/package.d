module ut.backends.interpreter;


import ut;
import quickbite.frontend.compiler: parseSnippet;
import dmd.mtype: TypeStruct, TypeEnum;


// Parses `source`, finds the `struct` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeStruct`.
public TypeStruct structTypeOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members)
        if (auto struct_ = member.isStructDeclaration)
            if (struct_.ident.toString == name) {
                auto structType = struct_.type.isTypeStruct;
                assert(structType !is null,
                    "struct `" ~ name ~ "`'s type is not a TypeStruct");
                return structType;
            }

    assert(false, "struct `" ~ name ~ "` not found in parsed snippet");
}


// Parses `source`, finds the `enum` named `name` among the module's
// top-level members, and returns its (now semantically analysed)
// `TypeEnum`.
public TypeEnum enumTypeOf(in string source, in string name) {
    auto moduleResult = parseSnippet(source);

    foreach (member; *moduleResult.module_.members)
        if (auto enum_ = member.isEnumDeclaration)
            if (enum_.ident.toString == name) {
                auto enumType = enum_.type.isTypeEnum;
                assert(enumType !is null,
                    "enum `" ~ name ~ "`'s type is not a TypeEnum");
                return enumType;
            }

    assert(false, "enum `" ~ name ~ "` not found in parsed snippet");
}
