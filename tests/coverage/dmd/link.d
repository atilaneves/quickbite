module dmd.link;

private:

import dmd.astenums: DArray;
import dmd.common.outbuffer: OutBuffer;
import dmd.errorsink: ErrorSink;
import dmd.location: Loc;
import dmd.root.array: Array;

public int runPreprocessor(
    Loc loc,
    const(char)[] cpp,
    const(char)[] filename,
    const(char)* importc_h,
    ref Array!(const(char)*) cppswitches,
    bool verbose,
    ErrorSink eSink,
    ref OutBuffer defines,
    out DArray!ubyte text,
)
{
    return 1;
}
