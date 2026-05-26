module ut.lang;


import unit_threaded; // replace with `ut` later when we can due to `Value`
import quickbite.lang;


@("value.void")
@safe pure unittest {
    Value(Void.init).should == Value(Void.init);
    Value(Void.init).should.not == Value(false);
    Value(Void.init).should.not == Value(0);
}

@("value.bool")
@safe pure unittest {
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
    @safe pure unittest {
        const T val = 42;
        Value(val).should == Value(val);
        Value(cast(T) 7).should.not == Value(val);
    }
}

static foreach(T; imported!"std.meta".AliasSeq!(char, wchar, dchar)) {
    @("value.char." ~ T.stringof)
    @safe pure unittest {
        const val = cast(T) 42;
        Value(val).should == Value(val);
        Value(cast(T) 7).should.not == Value(val);
    }
}


static foreach(T; imported!"std.meta".AliasSeq!(float, double, real)) {
    @("value.float." ~ T.stringof)
    @safe pure unittest {
        const val = cast(T) 42;
        Value(val).should == Value(val);
        Value(cast(T) 7).should.not == Value(val);
    }
}

@("value.array.d.bool")
@safe pure unittest {
    Value([false, true]).should == Value([false, true]);
    Value([true, false]).should.not == Value([false, true]);
}

@("value.array.d.int")
@safe pure unittest {
    Value([1, 2]).should == Value([1, 2]);
    Value([2, 3]).should.not == Value([1, 2]);
}

@("value.array.d.double")
@safe pure unittest {
    Value([1.1, 2.2]).should == Value([1.1, 2.2]);
    Value([2.2, 3.3]).should.not == Value([1.1, 2.2]);
}
