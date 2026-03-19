module quickbite.ir.instruction;

private:

public enum Kind
{
    constInt,
    call,
    equal,
    assert_,
}

public struct Instruction
{
    public Kind kind;
    public uint destination;
    public int value;
    public string calleeName;
    public uint left;
    public uint right;
    public uint condition;
}
