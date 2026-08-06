module quickbite.backends.native.llvm_jit;


private:


// A native backend that reuses SystemLinker's object production verbatim and
// replaces only the load step: instead of `dmd -shared` + dlopen, it links the
// same `.o` files in-process with LLVM's ORC JIT, killing the ~30 ms linker
// spawn. Object production is shared via native/codegen.d; this backend
// differs from SystemLinker only after the objects exist on disk.
public class LLVMJit:
    imported!"quickbite.backends".Backend,
    imported!"quickbite.backends.runner".GroupedRunner
{
    import quickbite.backends.evaluator: Evaluator, EvalResult;
    import quickbite.backends.runner: TestResult;
    import quickbite.ffi: loadDependencyImages, verifyDependencyImages;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    private const LLVMJitInputs _inputs;

    public alias eval = Evaluator.eval;

    public this(
        in LLVMJitInputs inputs = LLVMJitInputs.init,
    ) @safe @nogc nothrow pure {
        _inputs = inputs;
    }

    public this(
        const string[] dependencyImages,
        const string[] importPaths,
    ) {
        this(
            LLVMJitInputs(
                importPaths,
                dependencyImages,
            ),
        );
        verifyDependencyImages(_inputs.dependencyImages);
        version (LDC) {}
        else loadDependencyImages(_inputs.dependencyImages);
    }

    public this(
        const string[] dependencyImages,
        const string[] importPaths,
        in string packageRoot,
        in imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags =
            imported!"quickbite.frontend.compiler".FrontendFlags.init,
        in imported!"quickbite.backends.native.system_linker".DubPackage dubPackage =
            imported!"quickbite.backends.native.system_linker".DubPackage.no,
    ) {
        import quickbite.frontend.compiler: FrontendFlags;
        import quickbite.backends.native.link_files: dependencyImportPathsOutside;

        this(
            LLVMJitInputs(
                dependencyImportPathsOutside(importPaths, packageRoot),
                dependencyImages,
                FrontendFlags(frontendFlags.compilerArguments.dup),
                dubPackage,
            ),
        );
        verifyDependencyImages(_inputs.dependencyImages);
        version (LDC) {}
        else loadDependencyImages(_inputs.dependencyImages);
    }

    public override TestResult[] runTests(Module module_) {
        return runTests([module_]);
    }

    public override TestResult[] runTests(Module[] modules) {
        version (LDC)
            return runTestsViaExecutor(modules, _inputs);
        else
            return runTestsInChild(modules, _inputs);
    }

    public override EvalResult eval(FuncDeclaration function_) {
        version (LDC)
            throw new Exception("LLVMJit.eval is unavailable under the LDC build");
        return evalInChild(function_, _inputs);
    }
}

// dmd emits each module's ModuleInfo, ClassInfo/vtables and template TypeInfos
// into the JIT object; weak-symbol interposition (defineHostSymbols) redirects
// only the symbols the host process also exports, so metadata unique to the
// object (user classes, the module's own TypeInfo, Throwable subtypes) stays
// JIT-resident. If the long-lived parent ran the tests, those metadata objects
// would survive in its GC heap as pointers into JIT memory, and the moment that
// memory is reclaimed they become dangling — a later collection would walk a
// survivor and dereference an unmapped ClassInfo/vtable, crashing the suite
// (ai/plans/llvm-jit.md, Step 4). So run the whole create -> load -> execute
// cycle in a forked child that _exits when done: the child takes all
// JIT-tainted heap and eh_frame state with it, and reports each test's result
// to the parent over a pipe. This mirrors the codegen fork the child itself
// then performs (native/codegen.d).
private imported!"quickbite.backends.runner".TestResult[] runTestsInChild(
    imported!"dmd.dmodule".Module[] modules,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.runner: TestResult;
    import core.stdc.errno: EINTR, errno;
    import core.stdc.stdio: fflush;
    import core.sys.posix.unistd: _exit, close, fork, pipe, read;
    import core.sys.posix.sys.wait:
        WEXITSTATUS, WIFEXITED, WIFSIGNALED, WTERMSIG, waitpid;
    import std.conv: text;

    // The child inherits stdio buffers; flush so it cannot re-emit them.
    fflush(null);

    int[2] fds;
    if (pipe(fds) != 0)
        throw new Exception("pipe() failed");

    // runChildAndReport eventually takes withCompilerLock in this child.
    // AGENTS.md requires serial suite execution, so the child cannot inherit
    // that mutex locked by another test and deadlock here.
    const pid = fork();
    if (pid < 0)
        throw new Exception("fork() failed");

    if (pid == 0) { // child: run the JIT cycle, report over the pipe, never return
        close(fds[0]);
        runChildAndReport(fds[1], modules, inputs);
        close(fds[1]);
        _exit(0);
    }

    // parent: read the report before reaping the child so a report larger than
    // the pipe buffer cannot deadlock against waitpid.
    close(fds[1]);
    bool childReaped;
    scope(failure) {
        if (!childReaped)
            closeAndReapChild(fds[0], pid);
    }
    ubyte[] data;
    ubyte[4096] buffer;
    for (;;) {
        const got = read(fds[0], buffer.ptr, buffer.length);
        if (got < 0) {
            if (errno == EINTR)
                continue;
            throw new Exception("read from result pipe failed");
        }
        if (got == 0)
            break;
        data ~= buffer[0 .. got];
    }
    close(fds[0]);
    fds[0] = -1;

    int status;
    for (;;) {
        const reaped = waitpid(pid, &status, 0);
        if (reaped == pid) {
            childReaped = true;
            break;
        }
        if (reaped < 0 && errno == EINTR)
            continue;
        throw new Exception("waitpid failed for the JIT child");
    }

    // The child _exits 0 after writing a complete frame (error frames included),
    // so a signal or non-zero exit means it died mid-report — surface it rather
    // than pass for success. A fixture that genuinely crashes lands here; none
    // of the SystemLinker-oracle fixtures do.
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        const detail = WIFSIGNALED(status)
            ? text("signal ", WTERMSIG(status))
            : WIFEXITED(status)
                ? text("exit code ", WEXITSTATUS(status))
                : text("status ", status);
        throw new Exception(text("JIT child died (", detail, ")"));
    }

    return decodeFrame(data);
}

// Child side: build the JIT, run every unittest, and write a result frame to
// the pipe. Never lets a Throwable unwind out — the child must not run the
// parent's inherited scope(exit)s — so infrastructure failures are reported as
// an error frame instead. A failing assert is not seen here: runUnitTest
// catches it into a TestResult.
private void runChildAndReport(
    int fd,
    imported!"dmd.dmodule".Module[] modules,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.runner: TestResult;
    import quickbite.frontend.util: foreachUnitTestDeclaration;

    try {
        // No LLVMOrcDisposeLLJIT: the child _exits immediately after reporting,
        // so the OS reclaims the JIT mapping. Disposing here would be the very
        // munmap-then-collect that crashes the parent; _exit avoids both the
        // explicit unmap and any gc_term sweep over a JIT-resident survivor.
        auto jit = jitForObjects(modules, inputs);

        TestResult[] cases;
        foreach (module_; modules)
            foreachUnitTestDeclaration(module_, (unitTest) {
                cases ~= runUnitTest(jit, unitTest);
            });

        writeResults(fd, cases);
    } catch (Throwable throwable) {
        string message;
        try
            message = throwable.toString;
        catch (Throwable)
            message = throwable.msg;
        writeError(fd, message);
    }
}

// Eval has the same JIT-resident metadata lifetime as runTests, but the
// evaluator's public contract is one EvalResult rather than a TestResult
// array. Keep the LLJIT and all values reached from it inside this child.
private imported!"quickbite.backends.evaluator".EvalResult evalInChild(
    imported!"dmd.func".FuncDeclaration function_,
    in LLVMJitInputs inputs,
) {
    import core.stdc.errno: EINTR, errno;
    import core.stdc.stdio: fflush;
    import core.sys.posix.unistd: _exit, close, fork, pipe, read;
    import core.sys.posix.sys.wait:
        WEXITSTATUS, WIFEXITED, WIFSIGNALED, WTERMSIG, waitpid;
    import std.conv: text;

    fflush(null);

    int[2] fds;
    if (pipe(fds) != 0)
        throw new Exception("pipe() failed");

    const pid = fork();
    if (pid < 0)
        throw new Exception("fork() failed");

    if (pid == 0) {
        close(fds[0]);
        runEvalChildAndReport(fds[1], function_, inputs);
        close(fds[1]);
        _exit(0);
    }

    close(fds[1]);
    bool childReaped;
    scope(failure) {
        if (!childReaped)
            closeAndReapChild(fds[0], pid);
    }
    ubyte[] data;
    ubyte[4096] buffer;
    for (;;) {
        const got = read(fds[0], buffer.ptr, buffer.length);
        if (got < 0) {
            if (errno == EINTR)
                continue;
            throw new Exception("read from result pipe failed");
        }
        if (got == 0)
            break;
        data ~= buffer[0 .. got];
    }
    close(fds[0]);
    fds[0] = -1;

    int status;
    for (;;) {
        const reaped = waitpid(pid, &status, 0);
        if (reaped == pid) {
            childReaped = true;
            break;
        }
        if (reaped < 0 && errno == EINTR)
            continue;
        throw new Exception("waitpid failed for the JIT child");
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        const detail = WIFSIGNALED(status)
            ? text("signal ", WTERMSIG(status))
            : WIFEXITED(status)
                ? text("exit code ", WEXITSTATUS(status))
                : text("status ", status);
        throw new Exception(text("JIT child died (", detail, ")"));
    }

    return decodeEvalFrame(data);
}

private void runEvalChildAndReport(
    int fd,
    imported!"dmd.func".FuncDeclaration function_,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.evaluator: EvalResult;

    try {
        auto jit = jitForObjects([function_.getModule], inputs);
        writeEvalResult(fd, evalCompiledFunction(jit, function_));
    } catch (Throwable throwable) {
        string message;
        try
            message = throwable.toString;
        catch (Throwable)
            message = throwable.msg;
        writeError(fd, message);
    }
}

// If the parent cannot finish reading a child report, leaving the read end
// open can strand the child in write(2), and throwing before waitpid leaves a
// zombie. This cleanup runs only before the normal reap succeeds.
private void closeAndReapChild(ref int readFd, int pid) @nogc nothrow {
    import core.stdc.errno: EINTR, errno;
    import core.sys.posix.signal: SIGKILL, kill;
    import core.sys.posix.sys.wait: waitpid;
    import core.sys.posix.unistd: close;

    if (readFd >= 0) {
        close(readFd);
        readFd = -1;
    }
    kill(pid, SIGKILL);

    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
}

public struct LLVMJitInputs {
    // Modules under dependency import paths are defined by prebuilt images and
    // must not be codegen'd again. Whether default imports are traversed for
    // template-instance codegen is derived from the modules themselves by the
    // shared codegen path, not from a caller flag.
    public const string[] dependencyImportPaths;
    // Cold dub dependency images are dlopen'd with RTLD_GLOBAL before ORC asks
    // the process-symbol generator to resolve dependency symbols.
    public const string[] dependencyImages;
    public imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags =
        imported!"quickbite.frontend.compiler".FrontendFlags.init;
    public imported!"quickbite.backends.native.system_linker".DubPackage dubPackage;
}

// The LDC host emits DMD objects but cannot execute them in-process. Hand the
// objects, cold dependency images, and discovered symbols to
// the DMD-built executor, which performs the ORC link and test calls.
version (LDC)
private imported!"quickbite.backends.runner".TestResult[] runTestsViaExecutor(
    imported!"dmd.dmodule".Module[] modules,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.runner: TestResult;
    import quickbite.backends.native.run_executor: runExecutor;
    import quickbite.frontend.util: foreachUnitTestDeclaration;
    import run_wire:
        RunKind, RunRequest, UnitTestSymbol, decodeResults, encodeRequest;
    import dmd.mangle: mangleExact;
    import core.sys.posix.unistd: getpid;
    import std.conv: text;
    import std.file: mkdirRecurse, read, rmdirRecurse, tempDir, write;
    import std.path: buildPath;
    import std.string: fromStringz;

    const index = _jitCounter++;
    const dir = buildPath(tempDir, text("quickbite_jit_", getpid, "_", index));
    mkdirRecurse(dir);
    // Unlike the in-process path, the executor reads these files after this
    // function has emitted them, so retain the directory through its reply.
    scope(exit) rmdirRecurse(dir);
    // RunRequest owns mutable arrays while its encoder walks them.
    auto objectFiles = emitObjects(modules, dir, inputs);

    UnitTestSymbol[] symbols;
    foreach (module_; modules)
        foreachUnitTestDeclaration(module_, (unitTest) {
            symbols ~= UnitTestSymbol(
                mangleExact(unitTest).fromStringz.idup,
                unitTest.ident.toChars.fromStringz.idup,
                unitTest.loc.toChars.fromStringz.idup,
            );
        });

    const requestFile = buildPath(dir, "request.bin");
    const resultsFile = buildPath(dir, "results.bin");
    write(requestFile, encodeRequest(RunRequest(
        RunKind.orcObjects,
        "",
        inputs.dependencyImages.dup,
        objectFiles,
        symbols,
    )));
    runExecutor(requestFile, resultsFile);

    TestResult[] cases;
    foreach (result; decodeResults(cast(ubyte[]) read(resultsFile)))
        cases ~= TestResult(result.passed, result.name, result.location, result.message);
    return cases;
}

// Emit the objects (shared codegen path, child emits, no link) and hand them
// to the frontend-free ORC loader (orc.loader), which stands up an LLJIT with
// them all added to the main JITDylib, plus a process-symbol generator so
// druntime/phobos symbols resolve from the running bin/ut.
private imported!"orc.bindings".LLVMOrcLLJITRef jitForObjects(
    imported!"dmd.dmodule".Module[] modules,
    in LLVMJitInputs inputs,
) {
    import orc.loader: createJit;
    import core.sys.posix.unistd: getpid;
    import std.conv: text;
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
    import std.path: buildPath;

    // Unique per call; a crashed run leaks its directory, and a later run with
    // the same path would otherwise be ambiguous.
    const index = _jitCounter++;
    const dir = buildPath(tempDir, text("quickbite_jit_", getpid, "_", index));
    mkdirRecurse(dir);
    // The loader reads the objects into memory buffers before it returns, so
    // the files can go as soon as it has.
    scope(exit) rmdirRecurse(dir);

    const objPaths = emitObjects(modules, dir, inputs);

    return createJit(objPaths);
}

private string[] emitObjects(
    imported!"dmd.dmodule".Module[] modules,
    in string dir,
    in LLVMJitInputs inputs,
) {
    import quickbite.backends.native.codegen: CodegenInputs, emitObjectFilesForBackend;
    import quickbite.backends.native.system_linker: DubPackage;
    import quickbite.frontend.compiler: FrontendFlags, withCompilerLock;

    string[] objectFiles;
    withCompilerLock(() {
        objectFiles = emitObjectFilesForBackend(
            modules,
            dir,
            CodegenInputs(
                inputs.dependencyImportPaths,
                FrontendFlags(inputs.frontendFlags.compilerArguments.dup),
                inputs.dubPackage == DubPackage.yes,
            ),
        );
    });
    return objectFiles;
}

private imported!"quickbite.backends.runner".TestResult runUnitTest(
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    import quickbite.backends.runner: TestResult;
    import orc.loader: runSymbol;
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    const run = runSymbol(jit, mangleExact(unitTest).fromStringz);

    return TestResult(
        run.passed,
        unitTest.ident.toChars.fromStringz.idup,
        unitTest.loc.toChars.fromStringz.idup,
        run.message,
    );
}

private imported!"quickbite.backends.evaluator".EvalResult evalCompiledFunction(
    imported!"orc.bindings".LLVMOrcLLJITRef jit,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import quickbite.backends.native.evaluator: callNativeFunction, evalNativeFunction;
    import orc.loader: symbolAddress;
    import dmd.mangle: mangleExact;
    import std.string: fromStringz;

    auto address = symbolAddress(jit, mangleExact(function_).fromStringz);

    return evalNativeFunction(
        () => callNativeFunction(address, function_),
        function_,
    );
}

// The child -> parent result frame. The first byte is the kind: 1 means a
// results frame (a size_t count followed by that many [passed, name, location,
// message] records), 2 means an EvalResult, and 0 means an error frame (the
// rest of the stream is the message). Strings are length-prefixed with a
// size_t; both sides are the same process image, so native endianness needs no
// normalisation.
private void writeResults(int fd, in imported!"quickbite.backends.runner".TestResult[] cases) {
    writeByte(fd, 1);
    writeSizeT(fd, cases.length);
    foreach (testCase; cases) {
        writeByte(fd, testCase.passed ? 1 : 0);
        writeString(fd, testCase.name);
        writeString(fd, testCase.location);
        writeString(fd, testCase.message);
    }
}

private void writeEvalResult(
    int fd,
    in imported!"quickbite.backends.evaluator".EvalResult result,
) {
    writeByte(fd, 2);
    writeByte(fd, result.failed ? 1 : 0);
    writeString(fd, result.display);
    writeString(fd, result.diagnostic);
}

private void writeError(int fd, in char[] message) {
    writeByte(fd, 0);
    writeAll(fd, message);
}

private void writeString(int fd, in char[] str) {
    writeSizeT(fd, str.length);
    writeAll(fd, str);
}

private void writeByte(int fd, ubyte value) {
    writeAll(fd, (&value)[0 .. 1]);
}

private void writeSizeT(int fd, size_t value) {
    writeAll(fd, (cast(const(ubyte)*) &value)[0 .. size_t.sizeof]);
}

// write(2) may write partially or fail with EINTR; the frame must survive both
// or the parent sees a truncated report.
private void writeAll(int fd, scope const(void)[] data) {
    import core.stdc.errno: EINTR, errno;
    import core.sys.posix.unistd: write;

    const(ubyte)[] bytes = cast(const(ubyte)[]) data;
    size_t written = 0;
    while (written < bytes.length) {
        const wrote = write(fd, bytes.ptr + written, bytes.length - written);
        if (wrote < 0) {
            if (errno == EINTR)
                continue;
            throw new Exception("write to result pipe failed");
        }
        written += wrote;
    }
}

// Parent side: turn the bytes read from the pipe back into results, or throw
// the child's reported infrastructure error.
private imported!"quickbite.backends.runner".TestResult[] decodeFrame(
    const(ubyte)[] data,
) {
    import quickbite.backends.runner: TestResult;

    if (data.length == 0)
        throw new Exception("JIT child reported no results");

    const kind = data[0];
    auto rest = data[1 .. $];
    if (kind == 0) // error frame: the remainder is the message
        throw new Exception((cast(const(char)[]) rest).idup);

    size_t pos = 0;
    const count = readSizeT(rest, pos);
    TestResult[] cases;
    cases.reserve(count);
    foreach (_; 0 .. count) {
        const passed = readByte(rest, pos) != 0;
        const name = readString(rest, pos);
        const location = readString(rest, pos);
        const message = readString(rest, pos);
        cases ~= TestResult(passed, name, location, message);
    }
    return cases;
}

private imported!"quickbite.backends.evaluator".EvalResult decodeEvalFrame(
    const(ubyte)[] data,
) {
    import quickbite.backends.evaluator: EvalResult;

    if (data.length == 0)
        throw new Exception("JIT child reported no results");

    const kind = data[0];
    auto rest = data[1 .. $];
    if (kind == 0)
        throw new Exception((cast(const(char)[]) rest).idup);
    if (kind != 2)
        throw new Exception("JIT child reported an unexpected frame");

    size_t pos = 0;
    const failed = readByte(rest, pos) != 0;
    const display = readString(rest, pos);
    const diagnostic = readString(rest, pos);
    return failed
        ? EvalResult(EvalResult.Diagnostic(diagnostic))
        : EvalResult(display);
}

private string readString(const(ubyte)[] data, ref size_t pos) {
    const length = readSizeT(data, pos);
    if (pos + length > data.length)
        throw new Exception("truncated result stream");
    auto str = (cast(const(char)[]) data[pos .. pos + length]).idup;
    pos += length;
    return str;
}

private size_t readSizeT(const(ubyte)[] data, ref size_t pos) {
    if (pos + size_t.sizeof > data.length)
        throw new Exception("truncated result stream");
    size_t value;
    (cast(ubyte*) &value)[0 .. size_t.sizeof] = data[pos .. pos + size_t.sizeof];
    pos += size_t.sizeof;
    return value;
}

private ubyte readByte(const(ubyte)[] data, ref size_t pos) {
    if (pos + 1 > data.length)
        throw new Exception("truncated result stream");
    return data[pos++];
}

@("jitPipe.writeFailureIsReportedNotSwallowed")
unittest {
    import quickbite.backends.runner: TestResult;
    import core.sys.posix.signal: SIG_IGN, SIGPIPE, signal;
    import core.sys.posix.unistd: close, pipe;
    import ut;

    int[2] fds;
    pipe(fds).should == 0;
    scope(exit) close(fds[1]);
    close(fds[0]);
    const oldSigpipe = signal(SIGPIPE, SIG_IGN);
    scope(exit) signal(SIGPIPE, oldSigpipe);

    writeResults(fds[1], [TestResult(true, "t", "loc", "")])
        .shouldThrowWithMessage("write to result pipe failed");
}

private __gshared uint _jitCounter;
