module lib;
export extern(C) long c_combine(long a, long b, long c, long d) nothrow @nogc
{ return a*1000 + b*100 + c*10 + d; }
export extern(D) long d_combine(long a, long b, long c, long d) nothrow @nogc
{ return a*1000 + b*100 + c*10 + d; }
