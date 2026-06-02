module quickbite.backends.ir.language;

private:

package struct Literal {
    imported!"quickbite.lang".Value value;
}

package struct Add {
    Literal lhs;
    Literal rhs;
}

package alias Expression = imported!"std.sumtype".SumType!(Literal, Add);
