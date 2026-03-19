module quickbite.ir.module_;

private:

public struct Module {
    public imported!"quickbite.ir.function_".Function[] functions;
    public imported!"quickbite.ir.test".Test[] tests;
}
