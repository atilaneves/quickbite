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
