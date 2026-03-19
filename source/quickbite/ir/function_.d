module quickbite.ir.function_;

private:

public struct Function
{
    public string name;
    public imported!"quickbite.ir.type".Type returnType;
    public imported!"quickbite.ir.block".Block entry;
}
