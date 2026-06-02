module benchmarks.harness;

private:

public struct Result {
    public imported!"core.time".Duration min;
    public imported!"core.time".Duration median;
    // Sample standard deviation in hnsecs; floating-point because Duration
    // cannot represent a sub-integer-hnsec spread.
    public double stddevHnsecs;
}

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

    foreach (i; 0 .. warmup)
        runTests();

    // Disable the GC during measurement so a stop-the-world collection
    // inside one iteration cannot dominate the stddev. Force a collection
    // before each iteration so each one starts from a comparable baseline.
    GC.disable;
    scope(exit) GC.enable;

    foreach (i; 0 .. iterations) {
        GC.collect;
        const start = MonoTime.currTime;
        runTests();
        timings[i] = MonoTime.currTime - start;
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
    const median = iterations % 2 == 1
        ? timings[iterations / 2]
        : hnsecs(
            (timings[iterations / 2 - 1].total!"hnsecs"
             + timings[iterations / 2].total!"hnsecs") / 2,
        );
    return Result(timings[0], median, stddev);
}
