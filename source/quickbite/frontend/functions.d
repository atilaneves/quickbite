module quickbite.frontend.functions;

private:


public imported!"dmd.func".FuncDeclaration functionDeclaration(
    imported!"dmd.dmodule".Module module_,
    in string name,
) {
    if (module_.members !is null) {
        foreach (member; *module_.members) {
            auto function_ = member.isFuncDeclaration;
            if (function_ !is null && function_.ident.toString == name)
                return function_;
        }
    }

    throw new Exception("Missing frontend function.");
}
