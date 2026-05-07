module benchmarks.harness;

private:

public struct Result {
    public imported!"core.time".Duration min;
    public imported!"core.time".Duration median;
}

public Result measure(
    scope void delegate() runParsed,
    in size_t warmup,
    in size_t iterations,
) {
    import core.time: Duration, MonoTime;
    import std.algorithm.sorting: sort;

    auto timings = new Duration[](iterations);

    foreach (i; 0 .. warmup)
        runParsed();

    foreach (i; 0 .. iterations) {
        const start = MonoTime.currTime;
        runParsed();
        timings[i] = MonoTime.currTime - start;
    }

    timings.sort;
    return Result(timings[0], timings[$ / 2]);
}
