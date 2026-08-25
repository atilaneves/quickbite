module benchmarks.cgroup_peak;

private:

public struct CgroupPeakMeter {
    private int _fd = -1;

    public static CgroupPeakMeter fromEnvironment() {
        import std.conv: to;
        import std.process: environment;

        const value = environment.get("QUICKBITE_CGROUP_PEAK_FD");
        return value is null
            ? CgroupPeakMeter.init
            : CgroupPeakMeter(value.to!int);
    }

    public bool available() const @safe pure nothrow @nogc {
        return _fd >= 0;
    }

    public void reset() {
        if (!available)
            return;

        seekToStart(_fd);
        resetPeak(_fd);
    }

    public ulong read() {
        if (!available)
            return 0;

        seekToStart(_fd);
        return readPeak(_fd);
    }
}

private void seekToStart(in int fd) {
    import core.stdc.stdio: SEEK_SET;
    import core.sys.posix.unistd: lseek;
    import std.exception: errnoEnforce;

    errnoEnforce(lseek(fd, 0, SEEK_SET) >= 0, "cannot seek memory.peak");
}

// @trusted: write reads only the complete immutable reset token for this call.
private void resetPeak(in int fd) @trusted {
    import core.sys.posix.unistd: write;
    import std.exception: errnoEnforce;

    immutable token = "reset";
    errnoEnforce(
        write(fd, token.ptr, token.length) == token.length,
        "cannot reset memory.peak",
    );
}

// @trusted: read writes only inside the fixed local buffer and the returned
// slice never escapes this call.
private ulong readPeak(in int fd) @trusted {
    import core.sys.posix.unistd: read;
    import std.conv: to;
    import std.exception: errnoEnforce;
    import std.string: strip;

    char[32] buffer;
    const length = read(fd, buffer.ptr, buffer.length);
    errnoEnforce(
        length >= 0,
        "cannot read memory.peak",
    );
    return buffer[0 .. length].strip.to!ulong;
}
