module benchmarks.harness;

private:

public struct Result {
    public imported!"core.time".Duration min;
    public imported!"core.time".Duration median;
    // Sample standard deviation in hnsecs; floating-point because Duration
    // cannot represent a sub-integer-hnsec spread.
    public double stddevHnsecs;
    // The largest increase in GC.stats.usedSize between a pre-sample
    // collection and the sample's completion. With collection enabled this is
    // retained live memory, not total allocation volume.
    public size_t maxGcUsedSizeDelta;
}

public struct Measurement(T) {
    public Result timing;
    // Values returned by every timed iteration, in iteration order. Warmup
    // values deliberately stay out of this record.
    public T[] results;
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
    size_t maxGcUsedSizeDelta;

    foreach (i; 0 .. warmup)
        runTests();

    foreach (i; 0 .. iterations) {
        // Collection stays enabled while the operation runs: its pauses and
        // reclamation are part of normal edit-to-result latency. This explicit
        // collection is outside the timed region and gives samples a common
        // starting point.
        GC.collect;
        const baselineRam = GC.stats.usedSize;
        const start = MonoTime.currTime;
        runTests();
        timings[i] = MonoTime.currTime - start;
        const usedRam = GC.stats.usedSize;
        if (usedRam > baselineRam
            && usedRam - baselineRam > maxGcUsedSizeDelta)
            maxGcUsedSizeDelta = usedRam - baselineRam;
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
    return Result(timings[0], median, stddev, maxGcUsedSizeDelta);
}

public Measurement!T measureWithResults(T)(
    scope T delegate() operation,
    in size_t warmup,
    in size_t iterations,
) {
    import core.memory: GC;
    import core.time: Duration, MonoTime, hnsecs;
    import std.algorithm.sorting: sort;
    import std.math: sqrt;

    auto timings = new Duration[](iterations);
    auto results = new T[](iterations);
    size_t maxGcUsedSizeDelta;

    foreach (i; 0 .. warmup)
        operation();

    foreach (i; 0 .. iterations) {
        GC.collect;
        const baselineRam = GC.stats.usedSize;
        const start = MonoTime.currTime;
        results[i] = operation();
        timings[i] = MonoTime.currTime - start;
        const usedRam = GC.stats.usedSize;
        if (usedRam > baselineRam
            && usedRam - baselineRam > maxGcUsedSizeDelta)
            maxGcUsedSizeDelta = usedRam - baselineRam;
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
    const median = iterations % 2 == 1
        ? timings[iterations / 2]
        : hnsecs(
            (timings[iterations / 2 - 1].total!"hnsecs"
             + timings[iterations / 2].total!"hnsecs") / 2,
        );
    return Measurement!T(
        Result(timings[0], median, stddev, maxGcUsedSizeDelta),
        results,
    );
}
