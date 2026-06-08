module ut.backends.ctfe;


import ut.backends;


@("convertsLegacyValuePreservingUbyteType.Ctfe")
unittest {
    newBackend!Ctfe.eval("cast(ubyte) 3").should == Value(cast(ubyte) 3);
}
