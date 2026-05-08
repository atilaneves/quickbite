module ut.language_ir;

private:

import unit_threaded;
import quickbite: ExecutorBackend, runTests;

// Regression test: setting arr.length triggers _d_newarrayU during
// DMD-as-library fullSemantic.  This requires the patched druntime
// object.d that re-exports _d_newarrayU so system phobos std/array.d
// can resolve it.  Uses dmdCtfe backend so both compilation and
// execution are exercised without hitting IR lowering limitations.
@("dmdCtfe.arrayLengthSet")
unittest {
    q{
        unittest {
            int[] arr;
            arr.length = 3;
            assert(arr.length == 3);
        }
    }.runTests(ExecutorBackend.dmdCtfe);
}

@("ir.structFieldReadWrite")
unittest {
    q{
        struct Foo { int x; }
        unittest {
            Foo f;
            f.x = 42;
            assert(f.x == 42);
        }
    }.runTests(ExecutorBackend.ir);
}

// Regression test: std.conv.text() with an enum argument triggers
// std.conv.enumRep → Appender → _d_arraysetlengthTImpl during DMD-as-library
// fullSemantic.  After processLibraryFile patches the enum grain overload in
// cereal.d to use a string literal instead, this code pattern compiles and runs.
// This test verifies the FIXED pattern (string literal) works in dmdCtfe.
@("dmdCtfe.cereal.enumGrainStringLiteral")
unittest {
    q{
        enum MyEnum { Foo, Bar, Baz }
        void grainEnum(ref MyEnum val) {
            if (val < MyEnum.min || val > MyEnum.max)
                throw new Exception("Illegal enum value");
        }
        unittest {
            MyEnum v = MyEnum.Bar;
            grainEnum(v);
        }
    }.runTests(ExecutorBackend.dmdCtfe);
}
