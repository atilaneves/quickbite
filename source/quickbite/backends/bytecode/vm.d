module quickbite.backends.bytecode.vm;

private:

package imported!"quickbite.lang".Value eval(
    in imported!"quickbite.backends.bytecode.bytecode".Program program,
)
{
    import quickbite.backends.bytecode.bytecode: Op;

    foreach (instruction; program.instructions) {
        final switch (instruction.op) {
            case Op.literal:
                return instruction.value;
        }
    }

    throw new Exception("Empty bytecode program");
}
