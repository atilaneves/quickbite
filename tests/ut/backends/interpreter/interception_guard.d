module ut.backends.interpreter.interception_guard;


import ut;
import quickbite.frontend.compiler: parseSnippet;
import quickbite.backends.interpreter.interception_guard:
    enforceInterceptionPolicy, isLegalInterception;

private:

// ai/plans/interpreter.md §8's interception policy is enforced mechanically
// at the `Walker.runCallExpression` chokepoint via `isLegalInterception`/
// `enforceInterceptionPolicy` (source/quickbite/backends/interpreter/
// interception_guard.d). These exercise the predicate directly rather than
// driving it through a full interpreter fixture, per the plan's own guard
// work item.

imported!"dmd.func".FuncDeclaration findFunction(
    imported!"dmd.dmodule".Module module_,
    in string name,
) {
    return module_.members is null
        ? null
        : findFunction(module_.members, name);
}

// `extern(C)`/`extern(D)`/etc at module scope wraps the declaration in a
// `LinkDeclaration` (an `AttribDeclaration`), so the `FuncDeclaration` is not
// a direct member of the module -- recurse into `AttribDeclaration.decl` to
// find it regardless of how many attribute wrappers surround it.
imported!"dmd.func".FuncDeclaration findFunction(
    imported!"dmd.dsymbol".Dsymbols* members,
    in string name,
) {
    import dmd.attrib: AttribDeclaration;

    if (members is null)
        return null;

    foreach (member; *members) {
        if (auto function_ = member.isFuncDeclaration)
            if (function_.ident !is null && function_.ident.toString == name)
                return function_;

        if (auto attrib = member.isAttribDeclaration)
            if (auto found = findFunction(attrib.decl, name))
                return found;
    }

    return null;
}


@("isLegalInterception.bodyfulNonExemptFunctionIsRejected")
unittest {
    auto moduleResult = parseSnippet(q{
        int quickbiteGuardAddTwo(int a, int b) {
            return a + b;
        }
    });

    auto function_ = findFunction(moduleResult.module_, "quickbiteGuardAddTwo");
    assert(function_ !is null);
    isLegalInterception(function_).should == false;
}


@("isLegalInterception.bodylessFunctionIsAccepted")
unittest {
    auto moduleResult = parseSnippet(q{
        extern(C) void quickbiteGuardNoBody();
    });

    auto function_ = findFunction(moduleResult.module_, "quickbiteGuardNoBody");
    assert(function_ !is null);
    isLegalInterception(function_).should == true;
}


@("isLegalInterception.asmBodiedFunctionIsAccepted")
unittest {
    auto moduleResult = parseSnippet(q{
        void quickbiteGuardAsmBody() {
            asm {
                nop;
            }
        }
    });

    auto function_ = findFunction(moduleResult.module_, "quickbiteGuardAsmBody");
    assert(function_ !is null);
    isLegalInterception(function_).should == true;
}


@("enforceInterceptionPolicy.bodyfulNonExemptFunctionAsserts")
unittest {
    import core.exception: AssertError;

    auto moduleResult = parseSnippet(q{
        int quickbiteGuardAssertAddTwo(int a, int b) {
            return a + b;
        }
    });

    auto function_ =
        findFunction(moduleResult.module_, "quickbiteGuardAssertAddTwo");
    assert(function_ !is null);

    enforceInterceptionPolicy(
        function_,
        "quickbiteTestIntercept",
    ).shouldThrow!AssertError;
}
