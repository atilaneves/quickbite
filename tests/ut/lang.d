module ut.lang;


import unit_threaded; // replace with `ut` later when we can due to `Value`
import std.conv: text;
import quickbite.lang;


@("value.void")
@safe pure unittest {
    Value.void_.should == Value.void_;
    Value.void_.should.not == Value(false);
    Value.void_.should.not == Value(0);
}

@("value.initIsVoid")
@safe pure unittest {
    Value.init.should == Value.void_;
    Value.init.should.not == Value(false);
    Value.init.should.not == Value(0);
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

@("value.assocArray.intInt")
@safe pure unittest {
    Value([1: 10, 2: 20]).should == Value([1: 10, 2: 20]);
    Value([1: 10, 2: 30]).should.not == Value([1: 10, 2: 20]);
}

@("value.text.assocArray")
@safe pure unittest {
    Value([1: 10, 2: 20]).text.should == [1: 10, 2: 20].text;
}

@("value.struct.sameTypeFields")
@safe pure unittest {
    static struct Point {
        int x;
        int y;
    }

    Value(Point(1, 2)).should == Value(Point(1, 2));
    Value(Point(2, 3)).should.not == Value(Point(1, 2));
}

@("value.struct.sameNamedStructsCompareByRenderedValue")
@safe pure unittest {
    Value firstPoint() @safe pure {
        static struct Point {
            int x;
            int y;
        }

        return Value(Point(1, 2));
    }

    Value secondPoint() @safe pure {
        static struct Point {
            int x;
            int y;
        }

        return Value(Point(1, 2));
    }

    firstPoint.should == secondPoint;
}

@("value.mixed.bool.int")
@safe pure unittest {
    Value(false).should.not == Value(0);
}

@("value.mixed.ubyte.int")
@safe pure unittest {
    Value(cast(ubyte) 42).should.not == Value(42);
}

@("value.toString.integerType")
@safe pure unittest {
    Value(3).toString.should == "3: int";
    Value(3u).toString.should == "3: uint";
}

@("value.text.struct")
@safe pure unittest {
    static struct Point {
        int x;
        uint y;
    }

    Value(Point(1, 2)).text.should == Point(1, 2).text;
}

@("value.string")
@safe pure unittest {
    Value("foo").should == Value("foo");
    Value("quux").should.not == Value("foo");
}
