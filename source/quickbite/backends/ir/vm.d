module quickbite.backends.ir.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.ir.language".Function function_,
) {
    import quickbite.backends.ir.language:
        BinaryOp,
        BinaryOperation,
        Const,
        ReturnValue;
    import quickbite.lang: Value;
    import std.sumtype: match;

    long[] values;
    values.length = function_.valueCount;
    foreach (instruction; function_.blocks[0].instructions) {
        instruction.match!(
            (const Const const_) {
                values[const_.destination.id] = cast(int) const_.bits;
            },
            (const BinaryOp binary) {
                final switch (binary.operation) with (BinaryOperation) {
                    case add:
                        values[binary.destination.id] =
                            values[binary.lhs] + values[binary.rhs];
                        break;
                }
            },
        );
    }

    return function_.blocks[0].terminator.match!(
        (const ReturnValue return_) => Value(cast(int) values[return_.value]),
        (_) {
            assert(0);
            return Value.void_;
        },
    );
}
