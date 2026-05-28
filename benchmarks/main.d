int main(string[] args) {
    import benchmarks.cli: run;
    import std.stdio: stderr;

    try {
        run(args);
        return 0;
    } catch (Exception e) {
        stderr.writeln(e.msg);
        return 1;
    }
}
