module quickbite.backends.bytecode.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.bytecode.bytecode".Program program,
) {
    import quickbite.backends.bytecode.bytecode: Op;
    import quickbite.lang: Value;

    Value[] stack;

    foreach (instruction; program.instructions) {
        final switch (instruction.op) {
            case Op.literal:
                stack ~= instruction.value;
                break;

            case Op.add:
                if (stack.length < 2)
                    throw new Exception("Bytecode stack underflow");

                auto rhs = stack[$ - 1];
                auto lhs = stack[$ - 2];
                stack.length -= 2;

                stack ~= lhs + rhs;
                break;
        }
    }

    if (stack.length != 1)
        throw new Exception("Bytecode program did not leave exactly one value");

    return stack[0];
}
