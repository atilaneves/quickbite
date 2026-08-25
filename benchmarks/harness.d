module benchmarks.harness;

private:

public struct Result {
    public imported!"core.time".Duration min;
    public imported!"core.time".Duration median;
    // Sample standard deviation in hnsecs; floating-point because Duration
    // cannot represent a sub-integer-hnsec spread.
    public double stddevHnsecs;
    // Median dGC allocation across the timed iterations.
    public ulong dGcAllocation;
    public imported!"std.typecons".Nullable!ulong cgroupPeakMemory;
}

public struct Measurement(T) {
    public Result timing;
    // Warmup values are not timed, but callers retain them so a failed warmup
    // cannot be hidden by later successful measured iterations.
    public T[] warmupResults;
    // Values returned by every timed iteration, in iteration order.
    public T[] results;
}

public alias AdditionalAllocation = ulong delegate();
public alias SampleBoundary = void delegate();

public Result measure(
    scope void delegate() runTests,
    in size_t warmup,
    in size_t iterations,
) {
    import core.memory: GC;
    import core.time: Duration, MonoTime, hnsecs;
    import std.algorithm.sorting: sort;
    import std.math: sqrt;

    auto timings = new Duration[](iterations);
    auto allocations = new ulong[](iterations);

    foreach (i; 0 .. warmup)
        runTests();

    foreach (i; 0 .. iterations) {
        const allocationBaseline = GC.allocatedInCurrentThread;
        const start = MonoTime.currTime;
        runTests();
        timings[i] = MonoTime.currTime - start;
        allocations[i] = GC.allocatedInCurrentThread - allocationBaseline;
    }

    double sum = 0;
    foreach (t; timings)
        sum += t.total!"hnsecs";
    const mean = sum / iterations;

    double sqDiffSum = 0;
    foreach (t; timings) {
        const diff = t.total!"hnsecs" - mean;
        sqDiffSum += diff * diff;
    }
    // Sample stddev (Bessel's correction); falls back to 0 for a single sample.
    const stddev = iterations > 1 ? sqrt(sqDiffSum / (iterations - 1)) : 0.0;

    timings.sort;
    allocations.sort;
    const median = iterations % 2 == 1
        ? timings[iterations / 2]
        : hnsecs(
            (timings[iterations / 2 - 1].total!"hnsecs"
             + timings[iterations / 2].total!"hnsecs") / 2,
        );
    const medianAllocation = iterations % 2 == 1
        ? allocations[iterations / 2]
        : allocations[iterations / 2 - 1]
            + (allocations[iterations / 2]
                - allocations[iterations / 2 - 1]) / 2;
    return Result(timings[0], median, stddev, medianAllocation);
}

public Measurement!T measureWithResults(T)(
    scope T delegate() operation,
    in size_t warmup,
    in size_t iterations,
    scope AdditionalAllocation additionalAllocation = null,
    scope SampleBoundary beforeSample = null,
    scope SampleBoundary afterSample = null,
) {
    import core.memory: GC;
    import core.time: Duration, MonoTime, hnsecs;
    import std.algorithm.sorting: sort;
    import std.math: sqrt;

    auto timings = new Duration[](iterations);
    auto warmupResults = new T[](warmup);
    auto results = new T[](iterations);
    auto allocations = new ulong[](iterations);

    foreach (i; 0 .. warmup)
        warmupResults[i] = operation();

    foreach (i; 0 .. iterations) {
        if (beforeSample !is null)
            beforeSample();
        {
            scope(exit)
                if (afterSample !is null)
                    afterSample();

            const allocationBaseline = GC.allocatedInCurrentThread;
            const start = MonoTime.currTime;
            results[i] = operation();
            timings[i] = MonoTime.currTime - start;
            allocations[i] = GC.allocatedInCurrentThread - allocationBaseline;
            if (additionalAllocation !is null)
                allocations[i] += additionalAllocation();
        }
    }

    double sum = 0;
    foreach (t; timings)
        sum += t.total!"hnsecs";
    const mean = sum / iterations;

    double sqDiffSum = 0;
    foreach (t; timings) {
        const diff = t.total!"hnsecs" - mean;
        sqDiffSum += diff * diff;
    }
    const stddev = iterations > 1 ? sqrt(sqDiffSum / (iterations - 1)) : 0.0;

    timings.sort;
    allocations.sort;
    const median = iterations % 2 == 1
        ? timings[iterations / 2]
        : hnsecs(
            (timings[iterations / 2 - 1].total!"hnsecs"
             + timings[iterations / 2].total!"hnsecs") / 2,
        );
    const medianAllocation = iterations % 2 == 1
        ? allocations[iterations / 2]
        : allocations[iterations / 2 - 1]
            + (allocations[iterations / 2]
                - allocations[iterations / 2 - 1]) / 2;
    return Measurement!T(
        Result(timings[0], median, stddev, medianAllocation),
        warmupResults,
        results,
    );
}
