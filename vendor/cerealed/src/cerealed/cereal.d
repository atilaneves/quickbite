module cerealed.cereal;

import cerealed.traits: isCereal, isCerealiser, isDecerealiser;
import std.traits; // too many to bother listing
import std.range: isInputRange, isOutputRange, isInfinite;

class CerealException: Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure {
        super(msg, file, line, next);
    }
}

enum CerealType { WriteBytes, ReadBytes };

void grain(C, T)(auto ref C cereal, ref T val) if(isCereal!C && is(T == ubyte)) {
    cereal.grainUByte(val);
}

//catch all signed numbers and forward to reinterpret
void grain(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && !is(T == enum) &&
                                                        (isSigned!T || isBoolean!T ||
                                                         is(T == char) || isFloatingPoint!T)) {
    cereal.grainReinterpret(val);
}

// If the type is an enum, get the unqualified base type and cast it to that.
void grain(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && is(T == enum)) {
    alias BaseType = Unqual!(OriginalType!(T));
    cereal.grain( cast(BaseType)val );
    if(val < T.min || val > T.max)
        // String literal to avoid std.conv.text / Appender / _d_arraysetlengthTImpl.
        throw new Exception("Illegal enum value");
}


void grain(C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C && is(T == wchar)) {
    cereal.grain(*cast(ushort*)&val);
}

void grain(C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C && is(T == dchar)) {
    cereal.grain(*cast(uint*)&val);
}

void grain(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && is(T == ushort)) {
    ubyte valh = (val >> 8);
    ubyte vall = val & 0xff;
    cereal.grainUByte(valh);
    cereal.grainUByte(vall);
    val = (valh << 8) + vall;
}

void grain(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && is(T == uint)) {
    ubyte val0 = (val >> 24);
    ubyte val1 = cast(ubyte)(val >> 16);
    ubyte val2 = cast(ubyte)(val >> 8);
    ubyte val3 = val & 0xff;
    cereal.grainUByte(val0);
    cereal.grainUByte(val1);
    cereal.grainUByte(val2);
    cereal.grainUByte(val3);
    val = (val0 << 24) + (val1 << 16) + (val2 << 8) + val3;
}

void grain(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && is(T == ulong)) {
    T newVal;
    for(int i = 0; i < T.sizeof; ++i) {
        immutable shiftBy = 64 - (i + 1) * T.sizeof;
        ubyte byteVal = (val >> shiftBy) & 0xff;
        cereal.grainUByte(byteVal);
        newVal |= (cast(T)byteVal << shiftBy);
    }
    val = newVal;
}

enum hasByteElement(T) = is(Unqual!(ElementType!T): ubyte) && T.sizeof == 1;

void grain(C, T)(auto ref C cereal, ref T val) @trusted if(isCerealiser!C &&
                                                           isInputRange!T && !isInfinite!T &&
                                                           !is(T == string) &&
                                                           !isStaticArray!T &&
                                                           !isAssociativeArray!T) {
    grain!ushort(cereal, val);
}

void grain(U, C, T)(auto ref C cereal, ref T val) @trusted if(isCerealiser!C &&
                                                              isInputRange!T && !isInfinite!T &&
                                                              !is(T == string) &&
                                                              !isStaticArray!T &&
                                                              !isAssociativeArray!T) {
    import std.array: array;
    import std.range: hasSlicing;

    enum hasLength = is(typeof(() { auto l = val.length; }));
    // String literals to avoid std.conv.text / Appender / _d_arraysetlengthTImpl.
    static assert(hasLength, "Only InputRanges with .length accepted");
    U length = cast(U)val.length;
    assert(length == val.length, "overflow");
    cereal.grain(length);

    static if(hasSlicing!(Unqual!T) && hasByteElement!T)
        cereal.grainRaw(cast(ubyte[])val.array);
    else
        foreach(ref e; val) cereal.grain(e);
}


void grain(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && isStaticArray!T) {
    static if(hasByteElement!T)
        cereal.grainRaw(cast(ubyte[])val);
    else
        foreach(ref e; val) cereal.grain(e);
}

void grain(C, T)(auto ref C cereal, ref T val) @trusted if(isDecerealiser!C &&
                                                           !isStaticArray!T &&
                                                           isOutputRange!(T, ubyte)) {
    grain!ushort(cereal, val);
}

void grain(U, C, T)(auto ref C cereal, ref T val) @trusted if(isDecerealiser!C &&
                                                              !isStaticArray!T &&
                                                              isOutputRange!(T, ubyte)) {
    version(DigitalMars)
        U length;
    else
        U length = void;

    cereal.grain(length);

    static if(isArray!T) {
        decerealiseArrayImpl(cereal, val, length);
    } else {
        for(U i = 0; i < length; ++i) {
            ubyte b = void;
            cereal.grain(b);

            enum hasOpOpAssign = is(typeof(() { val ~= b; }));
            static if(hasOpOpAssign) {
                val ~= b;
            } else {
                val.put(b);
            }
        }
    }
}

private void decerealiseArrayImpl(C, T, U)(auto ref C cereal, ref T val, U length) @safe
    if(is(T == E[], E) && isDecerealiser!C)
{

    import std.exception: enforce;
    import std.range: ElementType, isInputRange;
    import std.traits: isScalarType;

    ulong neededBytes(T)(ulong length) {
        alias E = ElementType!T;
        static if(isScalarType!E)
            return length * E.sizeof;
        else static if(isInputRange!E)
            return neededBytes!E(length);
        else
            return 0;
    }

    immutable needed = neededBytes!T(length);
    // Use a string literal instead of std.conv.text to avoid Appender
    // instantiation which requires _d_arraysetlengthTImpl in CTFE.
    enforce(needed <= cereal.bytesLeft,
            "Not enough bytes left to decerealise array");

    static if(hasByteElement!T) {
        val = cereal.grainRaw(length).dup;
    } else {
        // Use ~= instead of val.length = to avoid _d_arraysetlengthTImpl.
        alias E = ElementType!T;
        val = null;
        foreach (_; 0 .. cast(size_t) length) {
            val ~= E.init;
            cereal.grain(val[$ - 1]);
        }
    }
}

void grain(C, T)(auto ref C cereal, ref T val) @trusted if(isDecerealiser!C &&
                                                           !isOutputRange!(T, ubyte) &&
                                                           isDynamicArray!T && !is(T == string)) {
    grain!ushort(cereal, val);
}

void grain(U, C, T)(auto ref C cereal, ref T val) @trusted if(isDecerealiser!C &&
                                                              !isOutputRange!(T, ubyte) &&
                                                              isDynamicArray!T && !is(T == string)) {
    version(DigitalMars)
        U length;
    else
        U length = void;

    cereal.grain(length);
    decerealiseArrayImpl(cereal, val, length);
}

void grain(C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C && is(T == string)) {
    grain!ushort(cereal, val);
}

void grain(U, C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C && is(T == string)) {
    U length = cast(U)val.length;
    assert(length == val.length, "overflow");
    cereal.grain(length);

    static if(isCerealiser!C)
        cereal.grainRaw(cast(ubyte[])val);
    else
        val = cast(string) cereal.grainRaw(length).idup;
}

// AA grain overloads: the real implementation (using .keys, .values) triggers
// core.internal.newaa.Impl which needs _d_arraysetlengthTImpl in DMD-as-library
// CTFE.  These stubs compile cleanly and throw at runtime until AA support
// lands in the backends.
void grain(C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C && isAssociativeArray!T) {
    throw new CerealException("Associative arrays not yet supported");
}

void grain(U, C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C && isAssociativeArray!T) {
    throw new CerealException("Associative arrays not yet supported");
}

void grain(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && isPointer!T) {
    import std.traits;
    alias ValueType = PointerTarget!T;
    static if(isDecerealiser!C) {
        if(val is null) val = new ValueType;
    }
    cereal.grain(*val);
}

private template canCall(C, T, string func) {
    enum canCall = is(typeof(() { auto cer = C(); auto val = T.init; mixin("val." ~ func ~ "(cer);"); }));
    static if(!canCall && __traits(hasMember, T, func)) {
        pragma(msg, "Warning: '" ~ func ~
               "' function defined for ", T, ", but does not compile for Cereal ", C);
    }
}

void grain(C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C && isAggregateType!T &&
                                                           !isInputRange!T && !isOutputRange!(T, ubyte)) {
    enum canAccept   = canCall!(C, T, "accept");
    enum canPreBlit = canCall!(C, T, "preBlit");
    enum canPostBlit = canCall!(C, T, "postBlit");

    static if(canAccept) { //custom serialisation
        static assert(!canPostBlit && !canPreBlit, "Cannot define both accept and pre/postBlit");
        val.accept(cereal);
    } else { //normal serialisation, go through each member and possibly serialise
        static if(canPreBlit) {
            val.preBlit(cereal);
        }

        cereal.grainAllMembers(val);
        static if(canPostBlit) { //semi-custom serialisation, do post blit
            val.postBlit(cereal);
        }
    }
}

void grainAllMembers(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && is(T == struct)) {
    cereal.grainAllMembersImpl!T(val);
}


void grainAllMembers(C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C && is(T == class)) {

    static if(isCerealiser!C) {
        assert(val !is null, "null value cannot be serialised");
    }

    enum hasDefaultConstructor = is(typeof(() { val = new T; }));
    static if(hasDefaultConstructor && isDecerealiser!C) {
        if(val is null) val = new T;
    } else {
        // String literal to avoid std.conv.text / Appender / _d_arraysetlengthTImpl.
        assert(val !is null, "Cannot deserialise into null value (no default constructor)");
    }

    cereal.grainClass(val);
}


alias grainMemberWithAttr = grainAggregateMember;
void grainAggregateMember(string member, C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C) {

    import cerealed.attrs: NoCereal;
    import std.meta: staticIndexOf;

    /**(De)serialises one member taking into account its attributes*/
    enum noCerealIndex = staticIndexOf!(NoCereal, __traits(getAttributes,
                                                           __traits(getMember, val, member)));
    //only serialise if the member doesn't have @NoCereal or @PostBlit
    static if(noCerealIndex == -1) {
        grainMember!member(cereal, val);
    }
}

void grainMember(string member, C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C) {

    import cerealed.attrs:
        isABitsStruct, isArrayLengthStruct, isLengthInBytesStruct, RawArray, isLengthType;
    import std.meta: staticIndexOf, Filter;

    alias bitsAttrs = Filter!(isABitsStruct, __traits(getAttributes,
                                                      __traits(getMember, val, member)));
    static assert(bitsAttrs.length == 0 || bitsAttrs.length == 1,
                  "Too many Bits!N attributes!");

    alias arrayLengths = Filter!(isArrayLengthStruct,
                                 __traits(getAttributes,
                                          __traits(getMember, val, member)));
    static assert(arrayLengths.length == 0 || arrayLengths.length == 1,
                  "Too many ArrayLength attributes");

    alias lengthInBytes = Filter!(isLengthInBytesStruct,
                                  __traits(getAttributes,
                                           __traits(getMember, val, member)));
    static assert(lengthInBytes.length == 0 || lengthInBytes.length == 1,
                  "Too many LengthInBytes attributes");

    enum rawArrayIndex = staticIndexOf!(RawArray, __traits(getAttributes,
                                                           __traits(getMember, val, member)));

    alias lengthTypes = Filter!(isLengthType, __traits(getAttributes, __traits(getMember, val, member)));
    static assert(lengthTypes.length == 0 || lengthTypes.length == 1,
                  "Too many LengthType attributes");

    static if(bitsAttrs.length == 1) {

        grainWithBitsAttr!(member, bitsAttrs[0])(cereal, val);

    } else static if(lengthTypes.length == 1) {

        grain!(lengthTypes[0].Type)(cereal, __traits(getMember, val, member));

    } else static if(rawArrayIndex != -1) {

        cereal.grainRawArray(__traits(getMember, val, member));

    } else static if(arrayLengths.length > 0) {

        grainWithArrayLengthAttr!(member, arrayLengths[0].member)(cereal, val);

    } else static if(lengthInBytes.length > 0) {

        grainWithLengthInBytesAttr!(member, lengthInBytes[0].member)(cereal, val);

    } else {

        cereal.grain(__traits(getMember, val, member));

    }
}

private void grainWithBitsAttr(string member, alias bitsAttr, C, T)(
    auto ref C cereal, ref T val) @safe if(isCereal!C) {

    import cerealed.attrs: getNumBits;

    enum numBits = getNumBits!(bitsAttr);
    enum sizeInBits = __traits(getMember, val, member).sizeof * 8;
    // String literal to avoid std.conv.text / Appender / _d_arraysetlengthTImpl.
    static assert(numBits <= sizeInBits,
                  member ~ " is not enough bits to store @Bits!" ~ numBits.stringof);
    cereal.grainBitsT(__traits(getMember, val, member), numBits);
}

private void grainWithArrayLengthAttr(string member, string lengthMember, C, T)
    (auto ref C cereal, ref T val) @safe if(isCereal!C) {

    import std.range: ElementType;

    checkArrayAttrType!member(cereal, val);

    static if(isCerealiser!C) {
        cereal.grainRawArray(__traits(getMember, val, member));
    } else {
        immutable length = lengthOfArray!(member, lengthMember)(cereal, val);
        alias E = ElementType!(typeof(__traits(getMember, val, member)));

        if(length * E.sizeof  > cereal.bytesLeft) {
            // String literal to avoid std.conv.text / Appender / _d_arraysetlengthTImpl.
            throw new CerealException("@ArrayLength larger than remaining byte array");
        }

        // Use ~= instead of member.length = to avoid _d_arraysetlengthTImpl.
        __traits(getMember, val, member) = null;
        foreach (_; 0 .. cast(size_t) length) {
            __traits(getMember, val, member) ~= E.init;
            cereal.grain(__traits(getMember, val, member)[$ - 1]);
        }
    }
}

void grainWithLengthInBytesAttr(string member, string lengthMember, C, T)
                                (auto ref C cereal, ref T val) @safe if(isCereal!C) {

    import std.range: ElementType;

    checkArrayAttrType!member(cereal, val);

    static if(isCerealiser!C) {
        cereal.grainRawArray(__traits(getMember, val, member));
    } else {
        immutable length = lengthOfArray!(member, lengthMember)(cereal, val); //error handling

        if(length > cereal.bytesLeft) {
            // String literal to avoid std.conv.text / Appender / _d_arraysetlengthTImpl.
            throw new CerealException("@LengthInBytes larger than remaining byte array");
        }

        // Use ~= instead of member.length = to avoid _d_arraysetlengthTImpl.
        alias E = ElementType!(typeof(__traits(getMember, val, member)));
        __traits(getMember, val, member) = null;

        long bytesLeft = length;
        while(bytesLeft) {
            auto origCerealBytesLeft = cereal.bytesLeft;
            __traits(getMember, val, member) ~= E.init;
            cereal.grain(__traits(getMember, val, member)[$ - 1]);
            bytesLeft -= (origCerealBytesLeft - cereal.bytesLeft);
        }
    }
}

private void checkArrayAttrType(string member, C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C) {

    alias M = typeof(__traits(getMember, val, member));
    // String literal to avoid std.conv.text / Appender / _d_arraysetlengthTImpl.
    static assert(is(M == E[], E),
                  "@ArrayLength and @LengthInBytes not valid for " ~ member ~
                  ": they can only be used on slices");
}


private int lengthOfArray(string member, string lengthMember, C, T)(auto ref C cereal, ref T val)
    @safe if(isCereal!C) {

    int _tmpLen;
    mixin(q{with(val) _tmpLen = cast(int)(} ~ lengthMember ~ q{);});

    if(_tmpLen < 0)
        // String literal to avoid std.conv.text / Appender / _d_arraysetlengthTImpl.
        throw new CerealException("@LengthInBytes resulted in negative length");

    return _tmpLen;
}

void grainRawArray(C, T)(auto ref C cereal, ref T[] val) @trusted if(isCereal!C) {
    //can't use virtual functions due to template parameter
    static if(isDecerealiser!C) {
        // Use ~= instead of val.length++ to avoid _d_arraysetlengthTImpl
        // which is not supported in DMD-as-library CTFE.
        val = null;
        while(cereal.bytesLeft()) {
            val ~= T.init;
            cereal.grain(val[$ - 1]);
        }
    } else {
        foreach(ref t; val) cereal.grain(t);
    }
}


/**
 * To be used when the length of the array is known at run-time based on the value
 * of a part of byte stream.
 */
void grainLengthedArray(C, T)(auto ref C cereal, ref T[] val, long length) {
    // Use ~= instead of val.length = to avoid _d_arraysetlengthTImpl.
    val = null;
    foreach (_; 0 .. cast(size_t) length) {
        val ~= T.init;
        cereal.grain(val[$ - 1]);
    }
}


package void grainClassImpl(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && is(T == class)) {
    //do base classes first or else the order is wrong
    cereal.grainBaseClasses(val);
    cereal.grainAllMembersImpl!T(val);
}

private void grainBitsT(C, T)(auto ref C cereal, ref T val, int bits) @safe if(isCereal!C) {
    uint realVal = val;
    cereal.grainBits(realVal, bits);
    val = cast(T)realVal;
}

private void grainReinterpret(C, T)(auto ref C cereal, ref T val) @trusted if(isCereal!C) {
    auto ptr = cast(CerealPtrType!T)(&val);
    cereal.grain(*ptr);
}

private void grainBaseClasses(C, T)(auto ref C cereal, ref T val) @safe if(isCereal!C && is(T == class)) {
    foreach(base; BaseTypeTuple!T) {
        cereal.grainAllMembersImpl!base(val);
    }
}


private void grainAllMembersImpl(ActualType, C, ValType)
                                (auto ref C cereal, ref ValType val) @trusted if(isCereal!C) {
    foreach(member; __traits(derivedMembers, ActualType)) {
        //makes sure to only serialise members that make sense, i.e. data
        enum isMemberVariable = is(typeof(() {
                                           __traits(getMember, val, member) = __traits(getMember, val, member).init;
                                       }));
        static if(isMemberVariable) {
            cereal.grainAggregateMember!member(val);
        }
    }
}

private template CerealPtrType(T) {
    static if(is(T == bool) || is(T == char)) {
        alias CerealPtrType = ubyte*;
    } else static if(is(T == float)) {
        alias CerealPtrType = uint*;
    } else static if(is(T == double)) {
        alias CerealPtrType = ulong*;
    } else {
        alias CerealPtrType = Unsigned!T*;
    }
}
