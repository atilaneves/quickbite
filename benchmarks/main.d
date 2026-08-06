int main(string[] args) {
    import benchmarks.cli: run;
    import std.stdio: stderr;

    try {
        return run(args);
    } catch (Exception e) {
        stderr.writeln(e.msg);
        return 1;
    }
}
