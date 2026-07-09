module ut.backends.interpreter.layout;


import ut;
import quickbite.backends.interpreter.layout:
    typeAlignment, typeByteSize, typeHasPointers;
import dmd.mtype: Type;

private:


@("typeByteSize.int32IsFourBytes")
unittest {
    typeByteSize(Type.tint32).should == 4;
}


@("typeByteSize.int64IsEightBytes")
unittest {
    typeByteSize(Type.tint64).should == 8;
}


@("typeByteSize.unsizedTypeThrows")
unittest {
    typeByteSize(Type.terror).shouldThrow;
}


@("typeAlignment.int32IsReported")
unittest {
    typeAlignment(Type.tint32).should == 4;
}


@("typeHasPointers.pointerTypeReportsPointers")
unittest {
    typeHasPointers(Type.tvoidptr).should == true;
}


@("typeHasPointers.plainIntegralReportsNoPointers")
unittest {
    typeHasPointers(Type.tint32).should == false;
}
