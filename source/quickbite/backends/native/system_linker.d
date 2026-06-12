module quickbite.backends.native.system_linker;


private:


public class SystemLinker: imported!"quickbite.backends.runner".Runner {
    import quickbite.backends.runner: ExecutionMode, TestResult;
    import dmd.dmodule: Module;

    private const string[] _linkFiles;
    private const string[] _archiveImportPaths;

    // Native code is inherently runtime; the mode parameter exists for
    // constructor uniformity across backends. The link files are prebuilt
    // libraries (e.g. dub-built dependency archives) appended to every link;
    // modules whose source lives under the archive import paths are defined
    // by those libraries and must not be codegen'd again.
    public this(
        in ExecutionMode mode = ExecutionMode.runtime,
        const string[] linkFiles = [],
        const string[] archiveImportPaths = [],
    ) @safe @nogc nothrow pure {
        assert(mode == ExecutionMode.runtime);
        _linkFiles = linkFiles;
        _archiveImportPaths = archiveImportPaths;
    }

    public override TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;
        import core.runtime: Runtime;

        auto library = compileToSharedLibrary(
            module_,
            _linkFiles,
            _archiveImportPaths,
        );
        // The results copy everything they need out of the library, so it can
        // be unloaded as soon as the tests have run. Dead objects of classes
        // the fixture defines still sit in the GC heap with vptrs into this
        // library, though; collect them while it is still mapped, or any
        // later finalizer sweep dereferences unmapped memory.
        scope(exit) {
            import core.memory: GC;
            GC.collect;
            Runtime.unloadLibrary(library);
        }

        TestResult[] cases;
        foreachUnitTestDeclaration(module_, (unitTest) {
            cases ~= runUnitTest(library, unitTest);
        });

        return cases;
    }
}

private void* compileToSharedLibrary(
    imported!"dmd.dmodule".Module module_,
    in string[] linkFiles,
    in string[] archiveImportPaths,
) {
    import quickbite.frontend.compiler: withCompilerLock;
    import core.atomic: atomicFetchAdd;
    import std.conv: text;
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
    import std.path: buildPath;

    // Unique paths per call: dlopen caches by path, so reusing one would
    // return a previously loaded library instead of the new code. The pid
    // keeps paths unique across processes too: a crashed run leaks its
    // directories, and a later run reusing the path could load the stale
    // library if its own link step failed.
    import core.sys.posix.unistd: getpid;
    const index = atomicFetchAdd(_libraryCounter, 1u);
    const dir = buildPath(tempDir, text("quickbite_native_", getpid, "_", index));
    mkdirRecurse(dir);
    // The loader keeps the library mapped after Runtime.loadLibrary, so the
    // files can go as soon as it is loaded.
    scope(exit) rmdirRecurse(dir);
    const libPath = buildPath(dir, "module.so");

    withCompilerLock(() {
        buildSharedLibrary(module_, dir, libPath, linkFiles, archiveImportPaths);
    });

    return loadSharedLibrary(libPath);
}

// Codegen runs in a fork child: DMD's backend is strictly once-per-process
// (backend_init, PASS.obj/csym written-marks, deferToObj and enum/TypeInfo
// gates), and the child gets a disposable copy-on-write image, so every
// codegen uses the backend exactly the way a fresh dmd process would. The
// parent's AST and globals are never mutated, which is what lets cached
// (stale) parses be codegen'd repeatedly.
private void buildSharedLibrary(
    imported!"dmd.dmodule".Module module_,
    in string dir,
    in string libPath,
    in string[] linkFiles,
    in string[] archiveImportPaths,
) {
    import quickbite.frontend.compiler: lightningRod;
    import dmd.dmodule: Module;
    import std.algorithm.iteration: filter;
    import std.array: array;
    import std.conv: text;
    import std.path: buildPath;

    auto rod = lightningRod;
    // A root module parsed before the rod would have become the accumulation
    // point for druntime/phobos instances instead of the rod, and the link
    // would fail with undefined template symbols two tests later. Fail here.
    assert(
        rod !is null && Module.rootModule is rod,
        "the lightning rod was not the first root module parsed",
    );

    initialiseBackend;

    // Modules from user import paths are compiled into the link too: their
    // functions live in no other object, and dmd emits an imported module's
    // function bodies only if it reached semantic3. Archive-backed modules
    // are the exception: a prebuilt library on the link line already defines
    // their symbols, so they get neither the root promotion (saving their
    // semantic3) nor an object of their own.
    auto allUserImports = userImportedModules(module_);
    auto userImports = allUserImports
        .filter!(import_ => !isUnderImportPaths(import_, archiveImportPaths))
        .array;
    prepareForCodegen(userImports);

    // The snippet first and the rod last, like dmd compiling several root
    // modules at once: codegen of the snippet can still append late template
    // instances to the rod's members, and the rod must pick them up.
    auto modules = [module_] ~ userImports ~ [rod];

    // Everything the link may legitimately reference; the rod is pruned down
    // to members that only touch these modules (or druntime/phobos).
    // Archive-backed modules belong here despite not being codegen'd: the
    // prebuilt libraries define their symbols.
    bool[Module] linkSet;
    foreach (linkModule; modules)
        linkSet[linkModule] = true;
    foreach (userImport; allUserImports)
        linkSet[userImport] = true;

    string[] objPaths;
    foreach (i; 0 .. modules.length)
        objPaths ~= buildPath(dir, text("obj_", i, ".o"));

    runInFork(() {
        const context = LinkContext(linkSet, collectMemberInstances(linkSet));
        // User-import modules are root modules (see prepareForCodegen), so
        // like the rod they accumulate template instances parameterized on
        // other compilations' types; prune them all against this link.
        pruneForeignMembers(rod, context);
        foreach (userImport; userImports)
            pruneForeignMembers(userImport, context);
        adoptTypeInfos(rod, linkSet);
        emitObjectFiles(modules, objPaths);
        linkSharedLibrary(objPaths, libPath, linkFiles);
    });
}

// What the link being built may legitimately reference: the modules whose
// objects are in it, and the template instances those modules hold as
// members (an instance is emitted from whichever members array holds it, so
// only member instances are guaranteed a definition).
private struct LinkContext {
    bool[imported!"dmd.dmodule".Module] modules;
    bool[imported!"dmd.dtemplate".TemplateInstance] memberInstances;
}

// Run `work` in a fork child; the child never returns. Errors are transported
// through a pipe and re-thrown in the parent, since a child cannot throw
// across the fork boundary. Forking while holding the compiler lock is safe:
// the process is single-threaded (versions "unitUnthreaded"; neither the
// benchmark nor the repl spawn threads), so no other thread can be wedged
// mid-lock in the child image.
private void runInFork(scope void delegate() work) {
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

    const pid = fork();
    if (pid < 0)
        throw new Exception("fork() failed");

    if (pid == 0) { // child: do the work, report through the pipe, never return
        close(fds[0]);
        int status = 0;
        try
            work();
        catch (Throwable throwable) { // also report asserts in the child
            status = 1;
            // toString can itself throw; the child must never unwind into
            // the parent's frames (every inherited scope(exit) would run,
            // including the temp-dir cleanup).
            try
                writeAll(fds[1], throwable.toString);
            catch (Throwable) {}
        }
        close(fds[1]);
        _exit(status);
    }

    // parent: read the error report (if any) before reaping the child so a
    // report larger than the pipe buffer cannot deadlock against waitpid.
    close(fds[1]);
    string message;
    char[4096] buffer;
    for (;;) {
        const got = read(fds[0], buffer.ptr, buffer.length);
        if (got < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (got == 0)
            break;
        message ~= buffer[0 .. got].idup;
    }
    close(fds[0]);

    int status;
    for (;;) {
        const reaped = waitpid(pid, &status, 0);
        if (reaped == pid)
            break;
        if (reaped < 0 && errno == EINTR)
            continue;
        // An unreaped child must not pass for success: the .so was likely
        // never linked.
        throw new Exception("waitpid failed for the codegen child");
    }
    if (status != 0) {
        const detail = WIFEXITED(status)
            ? text("exit code ", WEXITSTATUS(status))
            : WIFSIGNALED(status)
                ? text("signal ", WTERMSIG(status))
                : text("status ", status);
        throw new Exception(
            message.length > 0
                ? message
                : text("codegen child died without a report (", detail, ")"),
        );
    }
}

// write(2) may write partially or fail with EINTR; the report must survive
// both or the parent sees a truncated error.
private void writeAll(int fd, in char[] data) {
    import core.stdc.errno: EINTR, errno;
    import core.sys.posix.unistd: write;

    size_t written = 0;
    while (written < data.length) {
        const wrote = write(fd, data.ptr + written, data.length - written);
        if (wrote < 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        written += wrote;
    }
}

// With allInst on, every druntime/phobos template instance and TypeInfo from
// every compilation in the process accumulates on the rod (the first root
// module parsed; appendToModuleMember and getTypeInfoType chase importedFrom
// to it). Codegen of the rod emits all of them — needsCodegen is
// provenance-based, never link-set-based — so instances parameterized on
// other snippets' types would make rod.o reference symbols this link cannot
// resolve. Drop every member that references a module outside this link
// (druntime/phobos modules stay: their instances are exactly what the rod is
// for). Runs in the fork child only, so nothing needs restoring.
private void pruneForeignMembers(
    imported!"dmd.dmodule".Module module_,
    in LinkContext context,
) {
    if (module_.members is null)
        return;

    size_t numKept = 0;
    foreach (i; 0 .. module_.members.length) {
        auto member = (*module_.members)[i];
        if (!memberIsForeign(member, context))
            (*module_.members)[numKept++] = member;
    }
    module_.members.setDim(numKept);
}

// The template instances some in-link module holds as a member — the only
// instances whose emission in this link is guaranteed (an instance is
// emitted from whichever members array holds it).
private bool[imported!"dmd.dtemplate".TemplateInstance] collectMemberInstances(
    bool[imported!"dmd.dmodule".Module] linkSet,
) {
    import dmd.dtemplate: TemplateInstance;

    bool[TemplateInstance] result;
    foreach (module_, _; linkSet) {
        if (module_.members is null)
            continue;
        foreach (i; 0 .. module_.members.length)
            if (auto instance = (*module_.members)[i].isTemplateInstance) {
                result[instance] = true;
                if (instance.inst !is null)
                    result[instance.inst] = true;
            }
    }
    return result;
}

// TypeInfos are created once per process (genTypeInfo only reports
// needs-codegen on vtinfo creation) and appended to the creating module's
// importedFrom — for a root snippet, the snippet itself. A later snippet
// using the same type gets the cached vtinfo and no member append, so
// nothing in its own link would emit the TypeInfo (the symbol referenced by
// e.g. a synthesized __xtoHash stays undefined). The cache is on the type
// (Type.stringtable); re-home every aggregate-free TypeInfo onto the rod,
// where it emits as a COMDAT — duplicate emission across links is safe.
private void adoptTypeInfos(
    imported!"dmd.dmodule".Module rod,
    bool[imported!"dmd.dmodule".Module] linkSet,
) {
    import dmd.declaration: TypeInfoDeclaration;
    import dmd.mtype: Type;

    // A TypeInfo already emitted by any module in this link must not be
    // pushed onto the rod as well: emitting the same Dsymbol from two
    // modules in one process trips symbol_add's Ssymnum assert.
    bool[TypeInfoDeclaration] present;
    foreach (module_, _; linkSet) {
        if (module_.members is null)
            continue;
        foreach (i; 0 .. module_.members.length)
            if (auto typeInfo = (*module_.members)[i].isTypeInfoDeclaration)
                present[typeInfo] = true;
    }

    // Two passes because the string table's opApply requires a nothrow
    // delegate and the foreignness walk is not nothrow.
    TypeInfoDeclaration[] cached;
    foreach (entry; Type.stringtable) {
        // The string table hands out const entries; pushing the declaration
        // as a member requires mutability and the AST is logically owned by
        // this codegen pass.
        auto type = cast(Type) entry.value;
        if (type !is null && type.vtinfo !is null)
            cached ~= type.vtinfo;
    }

    foreach (typeInfo; cached) {
        import dmd.typinf: builtinTypeInfo;

        // Only aggregate-free types (builtin compositions like
        // const(int[])): their TypeInfos reference nothing but other
        // builtin-composition TypeInfos and druntime vtables, so the COMDAT
        // is self-contained. A TypeInfo involving a struct/class/enum
        // references the aggregate's synthesized members (__xtoHash,
        // __xopEquals, __init); those resolve only if the aggregate's
        // declaration or instance is emitted in this link — in which case
        // the TypeInfo is already a member of an in-link module — and
        // adopting one created for another compilation (e.g.
        // std.array.Appender!(int[]).Data, instantiated by unrelated
        // in-process code) injects undefined references the snippet never
        // asked for. Builtin TypeInfos themselves are exported by druntime.
        if (builtinTypeInfo(typeInfo.tinfo) || typeHasAggregate(typeInfo.tinfo))
            continue;
        if (typeInfo in present)
            continue;
        present[typeInfo] = true;
        rod.members.push(typeInfo);
    }
}

// Whether any struct/class/enum anywhere in the type satisfies `predicate`.
private bool anyAggregate(
    imported!"dmd.mtype".Type type,
    scope bool delegate(imported!"dmd.dsymbol".Dsymbol) predicate,
) {
    if (type is null)
        return false;
    if (auto structType = type.isTypeStruct)
        return predicate(structType.sym);
    if (auto classType = type.isTypeClass)
        return predicate(classType.sym);
    if (auto enumType = type.isTypeEnum)
        return predicate(enumType.sym);
    if (auto functionType = type.isTypeFunction) {
        if (anyAggregate(functionType.next, predicate))
            return true;
        foreach (i; 0 .. functionType.parameterList.length)
            if (anyAggregate(functionType.parameterList[i].type, predicate))
                return true;
        return false;
    }
    if (auto aaType = type.isTypeAArray)
        return anyAggregate(aaType.index, predicate)
            || anyAggregate(aaType.next, predicate);
    // TypeTuple extends Type directly (nextOf is null); D-style variadics
    // create tuple TypeInfos whose emission references each component
    // type's TypeInfo, so a struct component must be visible here.
    if (auto tupleType = type.isTypeTuple) {
        if (tupleType.arguments !is null)
            foreach (i; 0 .. tupleType.arguments.length)
                if (anyAggregate((*tupleType.arguments)[i].type, predicate))
                    return true;
        return false;
    }
    if (auto vectorType = type.isTypeVector)
        return anyAggregate(vectorType.basetype, predicate);
    if (auto next = type.nextOf)
        return anyAggregate(next, predicate);
    return false;
}

private bool typeHasAggregate(imported!"dmd.mtype".Type type) {
    return anyAggregate(type, aggregate => true);
}

private bool memberIsForeign(
    imported!"dmd.dsymbol".Dsymbol member,
    in LinkContext context,
) {
    if (auto instance = member.isTemplateInstance)
        return instanceIsForeign(instance, context);
    if (auto typeInfo = member.isTypeInfoDeclaration)
        return typeIsForeign(typeInfo.tinfo, context);
    return false;
}

private bool instanceIsForeign(
    imported!"dmd.dtemplate".TemplateInstance instance,
    in LinkContext context,
) {
    import dmd.dsymbol: Dsymbol;

    if (instance.tiargs !is null)
        foreach (i; 0 .. instance.tiargs.length)
            if (argIsForeign((*instance.tiargs)[i], context))
                return true;

    // A nested instance (e.g. Impl!(int, snippet.Nested).findSlotLookup!int,
    // whose own args are innocent) is foreign whenever the instance it is a
    // member of is: its emitted code references its enclosing instance's
    // symbols.
    for (Dsymbol parent = instance.parent; parent !is null; parent = parent.parent)
        if (auto enclosing = parent.isTemplateInstance)
            return instanceIsForeign(enclosing, context);

    return false;
}

private bool argIsForeign(
    imported!"dmd.rootobject".RootObject arg,
    in LinkContext context,
) {
    import dmd.dtemplate: isDsymbol, isExpression, isTuple, isType;

    if (auto type = isType(arg))
        return typeIsForeign(type, context);
    if (auto symbol = isDsymbol(arg))
        return symbolIsForeign(symbol, context);
    if (auto expression = isExpression(arg))
        return expression.type !is null
            && typeIsForeign(expression.type, context);
    if (auto tuple = isTuple(arg)) {
        foreach (i; 0 .. tuple.objects.length)
            if (argIsForeign(tuple.objects[i], context))
                return true;
    }
    return false;
}

private bool typeIsForeign(
    imported!"dmd.mtype".Type type,
    in LinkContext context,
) {
    return anyAggregate(type, aggregate => symbolIsForeign(aggregate, context));
}

// A symbol nested in a template instance lives wherever the instance does;
// what makes it foreign is the instance, not the template's declaring
// module, in two ways: the instance's arguments may come from another
// compilation (core.internal.newaa.Impl!(int, snippet_5.Nested) is declared
// in druntime but foreign to every link except snippet_5's), and the
// instance may never be emitted at all — a speculative instantiation by
// unrelated in-process code (std.array.Appender!(int[]) via a repl test)
// lands in no members array, so its synthesized members
// (__xtoHash/__xopEquals/__init) and TypeInfos have no definition in any
// link. needsCodegen finalizes instance state (tnext/minst); safe here
// because this only runs in the fork child.
private bool symbolIsForeign(
    imported!"dmd.dsymbol".Dsymbol symbol,
    in LinkContext context,
) {
    import dmd.dsymbol: Dsymbol;
    import dmd.templatesem: needsCodegen;

    for (Dsymbol parent = symbol; parent !is null; parent = parent.parent)
        if (auto instance = parent.isTemplateInstance) {
            if (instanceIsForeign(instance, context))
                return true;
            if (instance.inst is null)
                return true; // dummy/errored: never emitted
            return instance.inst !in context.memberInstances
                || !needsCodegen(instance.inst);
        }

    return moduleIsForeign(symbol.getModule, context);
}

// A module is foreign to this link if its symbols are in neither the link
// (the snippet, its user imports, the rod) nor libphobos2.so / the rod's
// emitted instances (druntime and phobos modules, identified by living under
// the process-default import paths).
private bool moduleIsForeign(
    imported!"dmd.dmodule".Module module_,
    in LinkContext context,
) {
    return module_ !is null
        && module_ !in context.modules
        && !isUnderDefaultImportPaths(module_);
}

// The modules the snippet (transitively) imports from user import paths:
// everything reachable through aimports that is not under the default
// (process-init, i.e. druntime/phobos) import paths. Recursion stops at
// default-path modules; their imports are druntime's business.
private imported!"dmd.dmodule".Module[] userImportedModules(
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.dmodule: Module;

    Module[] result;
    bool[Module] visited;
    visited[module_] = true;

    void walk(Module current) {
        foreach (i; 0 .. current.aimports.length) {
            auto imported_ = current.aimports[i];
            if (imported_ in visited)
                continue;
            visited[imported_] = true;
            if (isUnderDefaultImportPaths(imported_))
                continue;
            result ~= imported_;
            walk(imported_);
        }
    }

    walk(module_);
    return result;
}

private bool isUnderDefaultImportPaths(imported!"dmd.dmodule".Module module_) {
    return isUnderImportPaths(module_, defaultImportPaths);
}

private bool isUnderImportPaths(
    imported!"dmd.dmodule".Module module_,
    in string[] roots,
) {
    import std.algorithm.searching: any, startsWith;
    import std.path: absolutePath, buildNormalizedPath, dirSeparator;

    const path = module_.srcfile.toString.idup.absolutePath.buildNormalizedPath;
    // Match whole path components: a bare prefix check would classify a
    // sibling directory like <root>-extra/ as under <root>.
    return roots.any!((root) {
        const normalised = root.absolutePath.buildNormalizedPath;
        return path == normalised || path.startsWith(normalised ~ dirSeparator);
    });
}

// The import paths registered when DMD was initialized (druntime/phobos);
// per-parse user import paths are removed from global.path again after each
// parse, so snapshotting at first use only ever sees the defaults.
private string[] defaultImportPaths() {
    import dmd.globals: global;
    import std.path: absolutePath, buildNormalizedPath;
    import std.string: fromStringz;

    if (_defaultImportPaths.length == 0)
        foreach (i; 0 .. global.path.length)
            _defaultImportPaths ~= global.path[i].path.fromStringz.idup
                .absolutePath.buildNormalizedPath;

    return _defaultImportPaths;
}

// Imported modules only get semantic3 (function bodies analyzed) on demand,
// and codegen silently emits nothing for bodies that never got it. Parent
// side, under the compiler lock: instances created here must land on the rod
// before the fork snapshots the process. checkaction=context to match how
// the snippets themselves are compiled.
private void prepareForCodegen(imported!"dmd.dmodule".Module[] modules) {
    import dmd.astenums: CHECKACTION;
    import dmd.dsymbolsem: runDeferredSemantic3;
    import dmd.globals: global;
    import dmd.semantic2: semantic2;
    import dmd.semantic3: semantic3;
    import quickbite.frontend.compiler: diagnosticMessage;

    if (modules.length == 0)
        return;

    const originalCheckAction = global.params.checkAction;
    global.params.checkAction = CHECKACTION.context;
    scope(exit) global.params.checkAction = originalCheckAction;

    foreach (module_; modules) {
        // Codegen only emits functions of root modules
        // (FuncDeclaration_toObjFile returns early on inNonRoot, glue
        // package.d:485). Promote like dmd -i does (checkCompiledImport,
        // dmodule.d:747). The promotion makes the module accumulate template
        // instances like the rod; the child-side prune handles both.
        module_.importedFrom = module_;
        module_.semantic2(null);
        module_.semantic3(null);
    }
    runDeferredSemantic3;

    if (global.errors != 0)
        throw new Exception(diagnosticMessage);
}

private void emitObjectFiles(
    imported!"dmd.dmodule".Module[] modules,
    in string[] objPaths,
) {
    import dmd.glue: generateCodeAndWrite;
    import dmd.globals: global;
    import dmd.root.filename: FileName;

    foreach (i, module_; modules)
        module_.objfile = FileName(objPaths[i]);

    enum noLibModules = (const(char)*[]).init;
    enum noLibName = "";
    enum currentDirectory = "";
    enum doNotWriteLibrary = false;
    enum writeObjectFile = true;
    enum objectFilePerModule = false;
    enum doNotSplitObject = false;
    enum doNotPrintProgress = false;

    generateCodeAndWrite(
        modules,
        noLibModules,
        noLibName,
        currentDirectory,
        doNotWriteLibrary,
        writeObjectFile,
        objectFilePerModule,
        doNotSplitObject,
        doNotPrintProgress,
    );
    if (global.errors != 0)
        throw new Exception("codegen failed");
}

private void initialiseBackend() {
    import dmd.dmdparams: DMDparams, PIC;
    import dmd.dmsc: backend_init;
    import dmd.glue: ObjcGlue_initialize;
    import dmd.globals: global;
    import dmd.target: target;

    if (_backendInitialised)
        return;
    _backendInitialised = true;

    DMDparams driverParams;
    // Shared libraries need position independent code.
    driverParams.pic = PIC.pic;
    backend_init(global.params, driverParams, target);
    ObjcGlue_initialize;
}

private void linkSharedLibrary(
    in string[] objPaths,
    in string libPath,
    in string[] linkFiles,
) {
    import std.conv: text;
    import std.process: execute;

    // Link against shared phobos so the library shares the host's druntime
    // (one GC, one DSO registry) instead of smuggling in its own copy.
    // `-z defs` turns any symbol the generated code fails to provide into a
    // link error instead of a load-time failure.
    auto command = [ // const fails: appended to below
        "dmd",
        "-shared",
        "-defaultlib=libphobos2.so",
        "-L=-z",
        "-L=defs",
        "-of=" ~ libPath,
    ] ~ objPaths;
    // Group-wrap the prebuilt libraries: references between archives can go
    // in either direction, and the group makes the linker rescan to fixpoint.
    if (linkFiles.length != 0)
        command ~= "-L=--start-group" ~ linkFiles ~ "-L=--end-group";
    const result = execute(command);
    if (result.status != 0)
        throw new Exception(text("link failed: ", result.output));
}

private void* loadSharedLibrary(in string libPath) {
    import core.runtime: Runtime;

    // Runtime.loadLibrary registers the library with druntime (module
    // constructors, GC ranges, unloadable later). It requires the host to
    // link druntime as a shared library.
    auto handle = Runtime.loadLibrary(libPath);
    if (handle is null)
        throw new Exception("failed to load shared library: " ~ libPath);

    return handle;
}

private imported!"quickbite.backends.runner".TestResult runUnitTest(
    void* library,
    imported!"dmd.declaration".UnitTestDeclaration unitTest,
) {
    import quickbite.backends.runner: TestResult;
    import core.sys.posix.dlfcn: dlsym;
    import dmd.mangle: mangleExact;
    import std.conv: text;
    import std.string: fromStringz;

    auto test = cast(void function()) dlsym(library, mangleExact(unitTest));
    if (test is null)
        throw new Exception(text(
            "unittest symbol not found in shared library: ",
            mangleExact(unitTest).fromStringz,
        ));

    auto result = TestResult(
        true,
        unitTest.ident.toChars.fromStringz.idup,
        unitTest.loc.toChars.fromStringz.idup,
        "",
    );

    try
        test();
    catch (Throwable throwable) { // assert failures are Errors, not Exceptions
        result.passed = false;
        result.message = throwable.msg.idup;
    }

    return result;
}

private __gshared uint _libraryCounter;
// Only accessed under the compiler lock (buildSharedLibrary is always called
// inside withCompilerLock).
private __gshared bool _backendInitialised;
private __gshared string[] _defaultImportPaths;
