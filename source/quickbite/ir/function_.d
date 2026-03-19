module quickbite.ir.function_;

private:

public struct Function {
    import quickbite.ir.block: Block;
    import quickbite.ir.type: Type;

    string name;
    Type returnType;
    Block entry;
}
