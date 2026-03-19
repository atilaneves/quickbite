module quickbite.ir.type;

private:

public enum Kind
{
    int32,
    bool_,
    void_,
}

public struct Type
{
    public Kind kind;
}
