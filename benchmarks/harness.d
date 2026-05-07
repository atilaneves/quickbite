module benchmarks.harness;

private:

public struct Result {
    public imported!"core.time".Duration min;
    public imported!"core.time".Duration median;
    // Sample standard deviation in microseconds; floating-point because
    // Duration cannot represent a sub-integer-hnsec spread.
    public double stddevUsecs;
}

public Result measure(
    scope void delegate() runParsed,
    in size_t warmup,
    in size_t iterations,
) {
    import core.time: Duration, MonoTime;
    import std.algorithm.sorting: sort;
    import std.math: sqrt;

    auto timings = new Duration[](iterations);

    foreach (i; 0 .. warmup)
        runParsed();

    foreach (i; 0 .. iterations) {
        const start = MonoTime.currTime;
        runParsed();
        timings[i] = MonoTime.currTime - start;
    }

    double sum = 0;
    foreach (t; timings)
        sum += t.total!"usecs";
    const mean = sum / iterations;

    double sqDiffSum = 0;
    foreach (t; timings) {
        const diff = t.total!"usecs" - mean;
        sqDiffSum += diff * diff;
    }
    // Sample stddev (Bessel's correction); falls back to 0 for a single sample.
    const stddev = iterations > 1 ? sqrt(sqDiffSum / (iterations - 1)) : 0.0;

    timings.sort;
    return Result(timings[0], timings[$ / 2], stddev);
}
