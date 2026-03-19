module quickbite.ir.module_;

private:

public struct Module {
    import quickbite.ir.function_: Function;
    import quickbite.ir.test: Test;

    Function[] functions;
    Test[] tests;
}
