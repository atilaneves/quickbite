module ut.lang;


import unit_threaded; // replace with `ut` later when we can due to `Value`
import quickbite.lang;


@("value.void")
unittest {
    Value(Void.init).should == Value(Void.init);
    Value(Void.init).should.not == Value(false);
    Value(Void.init).should.not == Value(0);
}

@("value.bool")
unittest {
    Value(false).should == Value(false);
    Value(true).should.not == Value(false);
}

static foreach(
    T;
    imported!"std.meta".AliasSeq!(
        ubyte, byte, short, ushort, int, uint, long, ulong,
    )
)
{
    @("value.integer." ~ T.stringof)
    unittest {
        const T val = 42;
        Value(val).should == Value(val);
        Value(cast(T) 7).should.not == Value(val);
    }
}

static foreach(T; imported!"std.meta".AliasSeq!(char, wchar, dchar)) {
    @("value.char." ~ T.stringof)
    unittest {
        const val = cast(T) 42;
        Value(val).should == Value(val);
        Value(cast(T) 7).should.not == Value(val);
    }
}


static foreach(T; imported!"std.meta".AliasSeq!(float, double, real)) {
    @("value.float." ~ T.stringof)
    unittest {
        const val = cast(T) 42;
        Value(val).should == Value(val);
        Value(cast(T) 7).should.not == Value(val);
    }
}
