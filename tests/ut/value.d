module ut.value;

private:


import ut;
import quickbite.executor: Value;


@("value.uint_vs_long")
unittest {
    (Value(3u) == Value(3L)).should == false;
}

@("value.int_vs_long")
unittest {
    (Value(3) == Value(3L)).should == false;
}

@("value.byte_vs_int")
unittest {
    (Value(cast(byte) 3) == Value(3)).should == false;
}

@("value.bool_vs_byte")
unittest {
    (Value(true) == Value(cast(byte) 1)).should == false;
}

@("value.distinct_integral_pairs")
unittest {
    static foreach (i; 0 .. 4) {
        static if (i == 0) {
            (Value(cast(ubyte) 3) == Value(cast(uint) 3)).should == false;
        } else static if (i == 1) {
            (Value(cast(short) 3) == Value(cast(int) 3)).should == false;
        } else static if (i == 2) {
            (Value(cast(ushort) 3) == Value(cast(uint) 3)).should == false;
        } else static if (i == 3) {
            (Value(cast(ulong) 3) == Value(cast(long) 3)).should == false;
        }
    }
}

@("value.distinct_scalar_identity")
unittest {
    (Value(cast(char) 65) == Value(cast(ubyte) 65)).should == false;
    (Value(cast(wchar) 65) == Value(cast(ushort) 65)).should == false;
    (Value(cast(dchar) 65) == Value(cast(uint) 65)).should == false;
    (Value(1.25f) == Value(1.25)).should == false;
    (Value(1.25) == Value(1.25L)).should == false;
    (Value(cast(ifloat) 1.25i) == Value(cast(float) 1.25)).should == false;
    (Value(cast(idouble) 1.25i) == Value(cast(double) 1.25)).should == false;
    (Value(cast(ireal) 1.25i) == Value(cast(real) 1.25)).should == false;
    (Value(cast(cfloat) (1.0f + 2.0fi)) == Value(1.0f)).should == false;
    (Value(cast(cdouble) (1.0 + 2.0i)) == Value(1.0)).should == false;
    (Value(cast(creal) (1.0L + 2.0Li)) == Value(1.0L)).should == false;
    (Value.void_ == Value(0)).should == false;
}

@("value.toStringShowsDistinctScalarIdentity")
unittest {
    Value(8.0f).toString.should.not == Value(8.0).toString;
}
