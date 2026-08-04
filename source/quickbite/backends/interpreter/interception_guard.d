// Mechanical enforcement of ai/plans/interpreter.md §8's interception
// policy: name-based interception of a called function at the
// `Walker.runCallExpression` chokepoint is reserved for functions the
// frontend has no body for, or whose body is (or contains) inline asm the
// walker cannot execute. Every other name-based intercept must call
// `enforceInterceptionPolicy` before dispatching to its special-cased
// handler, so a future intercept cannot silently bypass the policy.
module quickbite.backends.interpreter.interception_guard;

private:

// A body-ful, non-asm callee that isn't on the exemption list below is an
// interpreter/value-model gap masked by a shim -- fail with `assert`, not a
// thrown `Exception`. An `Exception` could be caught by an interpreted
// `catch` handler or swallowed by unit-threaded's `shouldThrow`, silently
// hiding the very violation this guard exists to surface; `assert` raises an
// `AssertError` (a `Throwable`, not an `Exception`), so it propagates past
// interpreted code and fails the enclosing unittest outright. The check only
// runs on the already-rare path where a name-based intercept has matched, so
// there is no hot-path cost to justify gating it behind `debug`.
public void enforceInterceptionPolicy(
    imported!"dmd.func".FuncDeclaration function_,
    in string interceptorName,
) {
    import std.conv: text;

    assert(
        isLegalInterception(function_),
        text(
            "Interception policy violation (ai/plans/interpreter.md §8): `",
            interceptorName,
            "` intercepted `",
            function_ is null ? "<null>" : text(function_.toPrettyChars),
            "`, which has interpretable D source and is not inline asm. Add ",
            "it to the exemption list in `interception_guard.d` with a ",
            "§9.10 retirement condition, or fix the interpreter/value-model ",
            "gap at the root instead of intercepting by name.",
        ),
    );
}

public bool isLegalInterception(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.frontend.dmd.functions: hasNoAvailableSource;

    // Ordered cheapest-first so `||`'s short-circuiting skips the expensive
    // disjuncts whenever a cheaper one already decides the outcome:
    // `hasNoAvailableSource` is an `is null` check, `isExemptInterception` is
    // a handful of string comparisons against a pretty-printed name, and
    // `bodyContainsAsm` walks the callee's entire statement tree. The common
    // case -- a body-ful, exempt shim like `emplaceRef` or the AA hooks --
    // would otherwise pay for a full-body walk just to fall through to the
    // name check that was going to accept it anyway.
    return
        function_ !is null &&
        (
            hasNoAvailableSource(function_) ||
            isExemptInterception(function_) ||
            bodyContainsAsm(function_)
        );
}

// dmd exposes no direct "does this body contain asm" query; walk the
// statement tree with dmd's own generic recursive statement visitor (used
// elsewhere in dmd, e.g. `resetExpressionObjState`, to rewrite/traverse
// arbitrary control flow) and look for a `CompoundAsmStatement` (the whole
// `asm { ... }` block). Quickbite
// runs dmd frontend-only (`-version=NoBackend`): the individual instructions
// inside an `asm { ... }` block are only resolved into real `AsmStatement`/
// `InlineAsmStatement` nodes as part of code generation, which never runs
// here -- `CompoundAsmStatement.statements` stays an array of `null`
// placeholders even after `functionSemantic3`. The `CompoundAsmStatement`
// node itself, unlike its deferred children, exists from parse time onward,
// so checking for it (rather than for the leaf `AsmStatement` kinds) is what
// actually works in this environment. The finder class must be
// `extern (C++)` like `StatementRewriteWalker` and the rest of dmd's visitor
// hierarchy: a plain D class derived from an `extern (C++)` base does not
// share its Itanium-ABI vtable layout, so dmd does not recognise the
// override at all (as opposed to silently misbehaving).
public bool bodyContainsAsm(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.statement: CompoundStatement;
    import dmd.visitor.statement_rewrite_walker: StatementRewriteWalker;

    if (function_.fbody is null)
        return false;

    extern (C++) final class AsmStatementFinder: StatementRewriteWalker {
        alias visit = typeof(super).visit;

        bool found;

        override void visit(CompoundStatement statement) {
            found = found || statement.isCompoundAsmStatement !is null;
            super.visit(statement);
        }
    }

    scope finder = new AsmStatementFinder;
    finder.visitStmt(function_.fbody);
    return finder.found;
}

private bool isExemptInterception(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import std.algorithm: startsWith;
    import std.conv: text;

    const prettyName = text(function_.toPrettyChars);

    // `std.conv.text`: the one pre-existing, deliberate exemption named in
    // §8 (perf scaffolding).
    if (isStdConvTextName(function_))
        return true;

    // `core.internal.array.operations.arrayOp!(...)` has D source (a mixin-
    // generated element-wise loop); `Walker.runArrayOpAddAssignCall`
    // interprets the element-wise semantics directly instead. Discovered
    // while adding this guard, not previously in §9.10's inventory. Retire
    // together with §9.10: once arrays are native layout the druntime body
    // can execute directly and this intercept can be deleted.
    if (prettyName.startsWith("core.internal.array.operations.arrayOp!("))
        return true;

    // Associative-array runtime hooks (`core.internal.newaa._d_aa*`,
    // `object.dup`/`keys`/`values`, `_d_aaApply2`) all have D source;
    // `Walker.runAssocArrayHookCall` models their semantics directly
    // instead. Discovered while adding this guard, not previously in
    // §9.10's inventory. Retire when the associative-array representation
    // moves to native layout (§9.10).
    if (isAssocArrayHookName(prettyName))
        return true;

    // `rt.aApply`'s `_aApplycd1`/`_aApplywd1`/`_aApplydc1`/`_aApplyRwd1` are
    // `extern (C)`-mangled but have D source (they implement `foreach` over
    // string types with implicit UTF decoding); `Walker.
    // runStringForeachApplyCall` decodes directly instead. Discovered while
    // adding this guard, not previously in §9.10's inventory. Retire when
    // string/array native layout lands and the interpreter can iterate the
    // real druntime body.
    if (isStringForeachApplyName(prettyName))
        return true;

    // `core.internal.util.array.enforceRawArraysConformableNogc` has D
    // source (a real length/no-overlap check); the raw function-pointer
    // branch of `Walker.runCallExpression` fakes it by always returning
    // `Value(false)` -- worse than the other shims here, since it does not
    // even reproduce the real function's contract (the real function
    // returns `void`, not `bool`). Discovered while adding this guard, not
    // previously in §9.10's inventory. Retire by executing the real body
    // once static-array element-wise operations are interpretable
    // end-to-end.
    if (prettyName == "core.internal.util.array.enforceRawArraysConformableNogc")
        return true;

    // `core.atomic.atomicValueIsProperlyAligned`/`atomicPtrIsProperlyAligned`
    // are plain D (bit arithmetic on a `size_t`, no asm) despite living
    // alongside `core.internal.atomic`'s genuinely asm-bodied primitives, and
    // `AtomicHook.aligned` intercepts them by name regardless. Discovered
    // while adding this guard, not previously in §9.10's inventory. Retire
    // once interpreter values carry real addresses (native layout), so
    // alignment can be computed from an actual pointer instead of assumed.
    if (
        prettyName.startsWith("core.atomic.atomicValueIsProperlyAligned!") ||
        prettyName.startsWith("core.atomic.atomicPtrIsProperlyAligned!")
    )
        return true;

    // `core.internal.atomic.atomicFetchSub!(...)` and `atomicStore!(...)`
    // have D source, but for the ordinary (non-128-bit) case that source is
    // only a one-line forward (`return atomicFetchAdd(dest, -value);` /
    // `atomicExchange!(order, false)(dest, value);` under a store barrier)
    // to a sibling primitive that genuinely does contain asm -- so the
    // asm-body check above, which only looks at the callee's own body, does
    // not see it. Discovered while adding this guard, not previously in
    // §9.10's inventory. Retire together with the rest of the `AtomicHook`
    // family (§8's `core.internal.atomic` exemption): once native layout
    // makes single-threaded load/store equivalence unnecessary, the whole
    // hook can go.
    if (
        prettyName.startsWith("core.internal.atomic.atomicFetchSub!(") ||
        prettyName.startsWith("core.internal.atomic.atomicStore!(")
    )
        return true;

    // `tryInterpreterBuiltin`'s whole matched set --
    // `std.math.algebraic.fabs`/`sqrt`, `std.math.exponential.pow`,
    // `std.math.traits.isInfinity`, and (via a bare-identifier fallback with
    // no corresponding `dmd.func.BUILTIN` entry) `std.math.traits.signbit`
    // -- has D source: dmd's own `isBuiltin()` recognises these by
    // module+identifier for its own CTFE builtin-evaluation table
    // (`dmd.builtin.determine_builtin`), independent of whether the matched
    // declaration has a body, so quickbite's use of the same table inherits
    // the same body-independence. Discovered while adding this guard, not
    // previously in §9.10's inventory. The `signbit` fallback specifically
    // is also an unreported latent bug in its own right (it would misfire on
    // an unrelated user function literally named `signbit`, having no
    // module check at all), separate from this exemption. Retire once
    // `InterpreterBuiltin` computes each of these from the value's real
    // representation (float bits for `signbit`, a real element-wise
    // algorithm for the rest) in a native-layout world, at which point the
    // name-based match can be deleted outright.
    if (isInterpreterBuiltinName(function_))
        return true;

    return false;
}

private bool isStdConvTextName(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.interpreter.builtins: isStdConvText;

    return isStdConvText(function_);
}

private bool isAssocArrayHookName(in string prettyName) {
    import std.algorithm: canFind, startsWith;

    static immutable prefixes = [
        "core.internal.newaa._d_aaLen!(",
        "core.internal.newaa._d_aaGetRvalueX!(",
        "core.internal.newaa._d_aaGetY!(",
        "core.internal.newaa._d_aaIn!(",
        "core.internal.newaa._d_aaDel!(",
        "core.internal.newaa._d_aaEqual!(",
        "object.dup!(",
        "object.keys!(",
        "object.values!(",
    ];

    if (prettyName.canFind("_d_aaApply2!("))
        return true;

    foreach (prefix; prefixes)
        if (prettyName.startsWith(prefix))
            return true;

    return false;
}

private bool isStringForeachApplyName(in string prettyName) {
    import std.algorithm: canFind;

    return
        prettyName.canFind("_aApplycd1") ||
        prettyName.canFind("_aApplywd1") ||
        prettyName.canFind("_aApplydc1") ||
        prettyName.canFind("_aApplyRwd1");
}

private bool isInterpreterBuiltinName(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.interpreter.builtins:
        InterpreterBuiltin, tryInterpreterBuiltin;

    InterpreterBuiltin builtin;
    return tryInterpreterBuiltin(function_, builtin);
}
