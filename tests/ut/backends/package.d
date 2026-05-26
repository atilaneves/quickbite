module ut.backends;


public import ut;
public import quickbite.lang: Value;
public import quickbite.backends.ctfe;


alias backends = imported!"std.meta".AliasSeq!(
    Ctfe,
);


auto newBackend(T)() {
    return new T;
}
