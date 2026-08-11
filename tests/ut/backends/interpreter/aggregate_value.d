module ut.backends.interpreter.aggregate_value;


import ut;
import dmd.mtype: Type, TypeDArray;
import quickbite.backends.interpreter.aggregate_value: AggregateValue;
import quickbite.backends.interpreter.expression_result: ExpressionResult;

private:


@("AggregateValue.reconstructAndVisitNativeArray")
unittest {
    int[2] external = [3, 4];
    const nativeArray = AggregateValue.reconstructNativeArray(
        new TypeDArray(Type.tint32),
        [ExpressionResult(3), ExpressionResult(4)],
        external.ptr,
    );
    AggregateValue.nativeArrayAddress(nativeArray).should == external.ptr;
    AggregateValue.elementAt(nativeArray, 0).should == ExpressionResult(3);
    AggregateValue.elementAt(nativeArray, 1).should == ExpressionResult(4);
}
