module ut.backends.interpreter.aggregate_value;


import ut;
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
    AggregateValue.isClass(classValue).should == true;
    AggregateValue.classFieldAt(classValue, 0).should == arrayValue;
}
