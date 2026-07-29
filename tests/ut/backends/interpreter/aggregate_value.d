module ut.backends.interpreter.aggregate_value;


import ut;
import dmd.mtype: Type, TypeDArray;
import quickbite.backends.interpreter.aggregate_value: AggregateValue;
import quickbite.backends.interpreter.runtime_value: Value;

private:


@("AggregateValue.reconstructAndVisitBoxedAggregates")
unittest {
    const structValue = AggregateValue.reconstructStruct("Pair", [Value(1), Value(2)]);
    const arrayValue = AggregateValue.reconstructArray([structValue]);
    const classValue = AggregateValue.reconstructClass(
        "Box",
        ["Box"],
        ["items"],
        [arrayValue],
        7,
    );

    AggregateValue.isStruct(structValue).should == true;
    AggregateValue.fieldCount(structValue).should == 2;
    AggregateValue.fieldAt(structValue, 1).should == Value(2);
    AggregateValue.isArray(arrayValue).should == true;
    AggregateValue.elementCount(arrayValue).should == 1;
    AggregateValue.elementAt(arrayValue, 0).should == structValue;
    int[2] external = [3, 4];
    const nativeArray = AggregateValue.reconstructNativeArray(
        new TypeDArray(Type.tint32),
        [Value(3), Value(4)],
        external.ptr,
    );
    AggregateValue.nativeArrayAddress(nativeArray).should == external.ptr;
    AggregateValue.elementAt(nativeArray, 0).should == Value(3);
    AggregateValue.elementAt(nativeArray, 1).should == Value(4);
    AggregateValue.isClass(classValue).should == true;
    AggregateValue.classIdentity(classValue).should == 7;
    AggregateValue.classTypeName(classValue).should == "Box";
    AggregateValue.classFieldAt(classValue, 0).should == arrayValue;
}
