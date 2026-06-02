module quickbite.backends.ir.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.ir.language".Expression expression,
) {
    import quickbite.backends.ir.language: Literal;
    import std.sumtype: match;

    return expression.match!(
        (const(Literal) literal) => literal.value,
    );
}
