module quickbite.backends.native.codegen;


private:


// Codegen-relevant subset of a backend's inputs. The loader's link files are
// not part of object production, so they are deliberately absent: both
// SystemLinker (dmd -shared) and LLVMJit (in-process ORC link)
// share this object-production path and differ only in how they consume the
// emitted objects.
public struct CodegenInputs {
    // Modules under dependency import paths are defined by prebuilt images on
    // the link line and must not be codegen'd again. Whether default imports
    // are traversed for template-instance codegen is derived from the modules
    // themselves (see dependencyImageImports), not from a caller flag.
    public const string[] dependencyImportPaths;
    // The compiler arguments dub used for the package under test (e.g.
    // -version, -preview, -I). Applied around codegen so the import modules'
    // semantic3 sees the same frontend configuration as the original parse.
    public imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags =
        imported!"quickbite.frontend.compiler".FrontendFlags.init;
    // A dub package is codegen'd as its own root set, without the
    // single-snippet lightning rod and prune/adopt apparatus.
    public bool dubPackage;
}

// The one object-production entry point used by both native loaders. Keeping
// the dub-package choice with the codegen inputs makes their object production
// identical by construction; only their loading strategy can then differ.
public string[] emitObjectFilesForBackend(
    imported!"dmd.dmodule".Module[] rootModules,
    in string dir,
    in CodegenInputs inputs,
) {
    return inputs.dubPackage
        ? emitObjectFilesForDubPackage(rootModules, dir, inputs)
        : emitObjectFilesForLink(rootModules, dir, inputs);
}

// Fork, run DMD's backend, and write one object file per emitted module into
// `dir`, returning the object-file paths to the parent. This is the shared
// codegen path: it performs the rod-root assertion, user-import promotion,
// child-side adopt-and-prune (adoptOrphans/pruneForeignMembers), then emits
// objects. The fork child
// emits to disk and exits; the parent reads the paths back. Callers consume
// the objects however they like (dmd -shared, ORC, ...).
public string[] emitObjectFilesForLink(
    imported!"dmd.dmodule".Module[] rootModules,
    in string dir,
    in CodegenInputs inputs,
) {
    import quickbite.frontend.compiler: withFrontendFlags;

    string[] objPaths;
    withFrontendFlags(inputs.frontendFlags, () {
        objPaths = emitObjectFilesForLinkLocked(rootModules, dir, inputs);
    });
    return objPaths;
}

// Codegen a dub package compiled as its own root set, the way
// `dmd -unittest <files> -I<deps>` (what `dub test` runs) does. The package's
// modules are genuine roots from parseRootModules, where allInst was off, so
// each reachable template instance already homed on the package root that
// instantiated it -- including druntime instances like hashOf!(const(T)*).
// Emitting the roots therefore emits those instances next to the code that
// uses them.
//
// This deliberately omits the single-snippet apparatus that
// emitObjectFilesForLink carries -- the lightning rod, the dependency-image-gated
// druntime codegen, and the foreign-member prune -- because none of it
// applies once the package is its own root set: dependencies stay non-root
// imports (DMD's inNonRoot skips emitting their bodies), so their symbols come
// from the prebuilt dependency image on the link line and druntime/phobos from
// libphobos2.so.
public string[] emitObjectFilesForDubPackage(
    imported!"dmd.dmodule".Module[] rootModules,
    in string dir,
    in CodegenInputs inputs,
) {
    import quickbite.frontend.compiler: withFrontendFlags;

    string[] objPaths;
    withFrontendFlags(inputs.frontendFlags, () {
        objPaths = emitObjectFilesForDubPackageLocked(rootModules, dir);
    });
    return objPaths;
}

private string[] emitObjectFilesForDubPackageLocked(
    imported!"dmd.dmodule".Module[] rootModules,
    in string dir,
) {
    import quickbite.frontend.compiler: diagnosticMessage;
    import dmd.dsymbolsem: runDeferredSemantic3;
    import dmd.globals: global;
    import dmd.semantic2: semantic2;
    import dmd.semantic3: semantic3;
    import std.conv: text;
    import std.path: buildPath;

    initialiseBackend;

    // The roots completed semantic3 during parseRootModules; the guards make
    // these idempotent, but a re-run keeps codegen robust against any deferred
    // body that has yet to run before objects are emitted.
    foreach (module_; rootModules) {
        module_.semantic2(null);
        module_.semantic3(null);
    }
    runDeferredSemantic3;
    if (global.errors != 0)
        throw new Exception(diagnosticMessage);

    throwOnInlineAsm(rootModules);

    string[] objPaths;
    foreach (i; 0 .. rootModules.length)
        objPaths ~= buildPath(dir, text("obj_", i, ".o"));

    // Codegen in a fork child for the same reason as the snippet path: DMD's
    // backend is strictly once-per-process, and the disposable child image
    // leaves the parent's cached AST untouched for the next run.
    runInFork(() {
        emitObjectFiles(rootModules, objPaths);
    });

    return objPaths;
}

private string[] emitObjectFilesForLinkLocked(
    imported!"dmd.dmodule".Module[] rootModules,
    in string dir,
    in CodegenInputs inputs,
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
    // function bodies only if it reached semantic3. Dependency-image modules
    // are the exception: a prebuilt image on the link line already defines
    // their symbols, so they get neither the root promotion (saving their
    // semantic3) nor an object of their own.
    // The non-default (user-path) imports are the same whether or not default
    // imports are requested, so walk once without them to split them and to
    // derive whether default-path codegen is needed.
    auto nonDefaultImports = userImportedModules(rootModules, false);
    auto userImports = nonDefaultImports
        .filter!(import_ =>
            !isUnderImportPaths(import_, inputs.dependencyImportPaths))
        .array;
    auto dependencyImports = nonDefaultImports
        .filter!(import_ =>
            isUnderImportPaths(import_, inputs.dependencyImportPaths))
        .array;
    auto dependencyImageImports = dependencyImports
        .filter!(import_ => import_.hasTemplateInstanceMember)
        .array;
    // Derive the need for druntime/phobos template-instance codegen from the
    // modules themselves rather than from how the caller was invoked. The
    // signal is a dependency-image module that holds template-instance members:
    // a prebuilt image defines its ordinary symbols, but the snippet's use
    // of its templates instantiates them here (often parameterized on the
    // snippet's or phobos' types), and emitting those instances pulls in the
    // druntime/phobos members they reference, so the default-path modules must
    // join this link. A trivial image dependency with no templates instantiates
    // none, so root-promoting the default-path modules would only pollute
    // later links in this process; leave them out.
    auto defaultImports = dependencyImageImports.length != 0
        ? userImportedModules(rootModules, true)
            .filter!(import_ => isUnderDefaultImportPaths(import_))
            .array
        : null;
    // The snippet first and the rod last, like dmd compiling several root
    // modules at once: codegen of the snippet can still append late template
    // instances to the rod's members, and the rod must pick them up.
    auto modules = rootModules ~ userImports ~ dependencyImageImports
        ~ defaultImports ~ [rod];

    throwOnInlineAsm(modules);

    // Everything the link may legitimately reference; the rod is pruned down
    // to members that only touch these modules (or druntime/phobos).
    // Dependency-image modules belong here despite not being codegen'd: the
    // prebuilt images define their symbols.
    bool[Module] linkSet;
    foreach (linkModule; modules ~ dependencyImports)
        linkSet[linkModule] = true;
    foreach (userImport; userImports ~ dependencyImports ~ defaultImports)
        linkSet[userImport] = true;

    string[] objPaths;
    foreach (i; 0 .. modules.length)
        objPaths ~= buildPath(dir, text("obj_", i, ".o"));

    // Codegen runs in a fork child: DMD's backend is strictly once-per-process
    // (backend_init, PASS.obj/csym written-marks, deferToObj and enum/TypeInfo
    // gates), and the child gets a disposable copy-on-write image, so every
    // codegen uses the backend exactly the way a fresh dmd process would. The
    // child also completes import semantics, so template instances that it
    // creates cannot pollute the parent and later fixture links.
    runInFork(() {
        prepareForCodegen(userImports);
        prepareDependencyImageImportsForTemplateCodegen(
            dependencyImageImports,
        );
        prepareDependencyImageImportsForTemplateCodegen(defaultImports);

        // Instance and TypeInfo emission is this link's decision (see
        // adoptOrphans): adopt everything homed outside the link that this
        // link may define onto the rod, then prune by provenance.
        auto memberInstances = collectMemberInstances(modules);
        adoptOrphans(rod, linkSet, memberInstances);
        const context = LinkContext(linkSet, memberInstances);
        // User-import modules are root modules (see prepareForCodegen), so
        // like the rod they accumulate template instances parameterized on
        // other compilations' types; prune them all against this link.
        pruneForeignMembers(rod, context);
        foreach (userImport; userImports)
            pruneForeignMembers(userImport, context);
        foreach (dependencyImageImport; dependencyImageImports) {
            keepOnlyTemplateCodegenMembers(dependencyImageImport);
            pruneForeignMembers(dependencyImageImport, context);
        }
        foreach (defaultImport; defaultImports) {
            keepOnlyTemplateCodegenMembers(defaultImport);
            pruneForeignMembers(defaultImport, context);
        }
        emitObjectFiles(modules, objPaths);
    });

    return objPaths;
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

// After adoptOrphans the rod holds instances and TypeInfos from every
// compilation in the process (druntime instances home there natively —
// object.d is loaded by the rod's own semantic — and everything else is
// adopted at link time). Codegen of the rod would emit all of them —
// needsCodegen is provenance-based, never link-set-based — so instances
// parameterized on other snippets' types would make rod.o reference symbols
// this link cannot resolve. Drop every member that references a module
// outside this link (druntime/phobos modules stay: their instances are
// exactly what the rod is for). Runs in the fork child only, so nothing
// needs restoring.
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

// Dependency-image/default modules are in the codegen list only so DMD can emit the
// template instances and TypeInfos it appended to their members arrays. Their
// ordinary declarations are already supplied by a prebuilt image or
// libphobos, so emitting them here would duplicate definitions.
private void keepOnlyTemplateCodegenMembers(
    imported!"dmd.dmodule".Module module_,
) {
    if (module_.members is null)
        return;

    size_t numKept = 0;
    foreach (i; 0 .. module_.members.length) {
        auto member = (*module_.members)[i];
        if (member.isTemplateInstance || member.isTypeInfoDeclaration)
            (*module_.members)[numKept++] = member;
    }
    module_.members.setDim(numKept);
}

// The template instances some in-link module holds as a member — the only
// instances whose emission in this link is guaranteed (an instance is
// emitted from whichever members array holds it).
private bool[imported!"dmd.dtemplate".TemplateInstance] collectMemberInstances(
    imported!"dmd.dmodule".Module[] modules,
) {
    import dmd.dtemplate: TemplateInstance;

    bool[TemplateInstance] result;
    foreach (module_; modules) {
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

// DMD homes every deduplicated template instance and cached TypeInfo on
// exactly one module, chosen by whichever compilation first triggered it —
// for a lazily imported Phobos module that is an earlier test's snippet, a
// module no later link emits. Emission is therefore this link's decision:
// adopt everything homed outside the link that this link can define onto
// the rod (the module every link emits). Adopted instances join
// memberInstances so references among them survive pruneForeignMembers;
// instances parameterized on other compilations' types are never adopted,
// so references to them stay foreign and get pruned. Runs in the fork child
// only, so nothing needs restoring.
private void adoptOrphans(
    imported!"dmd.dmodule".Module rod,
    bool[imported!"dmd.dmodule".Module] linkSet,
    ref bool[imported!"dmd.dtemplate".TemplateInstance] memberInstances,
) {
    import dmd.declaration: TypeInfoDeclaration;
    import dmd.dmodule: Module;
    import dmd.dtemplate: TemplateInstance;
    import dmd.mtype: Type;
    import dmd.typinf: builtinTypeInfo;

    // Template instances live in the members array of the root module that
    // first instantiated them (appendToModuleMember chases the declaring
    // module's importedFrom to that root). memberInstances doubles as the
    // guard against adopting something an in-link module already emits:
    // emitting the same Dsymbol from two members arrays in one process trips
    // symbol_add's Ssymnum assert.
    TemplateInstance[] candidates;
    foreach (module_; Module.amodules) {
        if (module_ in linkSet || !module_.isRoot || module_.members is null)
            continue;

        foreach (i; 0 .. module_.members.length)
            if (auto instance = (*module_.members)[i].isTemplateInstance)
                if ((instance in memberInstances) is null)
                    candidates ~= instance;
    }

    // To a fixed point: an instance becomes adoptable once everything its
    // arguments reference is in-link or itself adopted (e.g. a Phobos
    // instance parameterized on another adopted Phobos instance's type).
    for (bool progressed = true; progressed;) {
        progressed = false;
        foreach (candidate; candidates) {
            if ((candidate in memberInstances) !is null)
                continue;
            if (instanceIsForeign(candidate, LinkContext(linkSet, memberInstances)))
                continue;

            memberInstances[candidate] = true;
            if (candidate.inst !is null)
                memberInstances[candidate.inst] = true;
            rod.members.push(candidate);
            progressed = true;
        }
    }

    bool[TypeInfoDeclaration] presentTypeInfos;
    foreach (module_, _; linkSet) {
        if (module_.members is null)
            continue;
        foreach (i; 0 .. module_.members.length)
            if (auto typeInfo = (*module_.members)[i].isTypeInfoDeclaration)
                presentTypeInfos[typeInfo] = true;
    }

    // TypeInfos are created once per process (genTypeInfo only reports
    // needs-codegen on vtinfo creation) and cached on the type
    // (Type.stringtable); a later compilation using the same type gets the
    // cached vtinfo and no member append at all, so the cache is the only
    // place to find them. Two passes because the string table's opApply
    // requires a nothrow delegate and the foreignness walk is not nothrow.
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
        if (typeInfo in presentTypeInfos)
            continue;
        presentTypeInfos[typeInfo] = true;
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

    // An instance nested in a function (a repl snippet's lambda, or filter!
    // instantiated inside the snippet's eval wrapper) is emitted with — and
    // references — its enclosing scope, so its enclosing module decides.
    return moduleIsForeign(instance.getModule, context);
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
    if (auto expression = isExpression(arg)) {
        // A lambda alias argument (e.g. a filter predicate) is foreign by
        // where the function symbol lives, not by its type: the function
        // type carries no aggregate, but the emitted instance calls the
        // lambda's symbol in its defining module.
        if (auto funcExp = expression.isFuncExp)
            return symbolIsForeign(funcExp.fd, context);
        return expression.type !is null
            && typeIsForeign(expression.type, context);
    }
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
// link — that case is caught by the memberInstances check below. This only
// runs in the fork child, so nothing needs restoring.
private bool symbolIsForeign(
    imported!"dmd.dsymbol".Dsymbol symbol,
    in LinkContext context,
) {
    import dmd.dsymbol: Dsymbol;

    for (Dsymbol parent = symbol; parent !is null; parent = parent.parent)
        if (auto instance = parent.isTemplateInstance) {
            if (instanceIsForeign(instance, context))
                return true;
            if (instance.inst is null)
                return true; // dummy/errored: never emitted
            // A member instance of a codegen'd module is emitted from that
            // members array even when needsCodegen is false: a sibling
            // instance that references it (e.g. std.random.uniform!(...)
            // referencing the MersenneTwisterEngine!(...) it is parameterized
            // on) pulls its symbols into the same object. So membership in a
            // codegen'd module, not needsCodegen, settles foreignness — using
            // needsCodegen here drops e.g. _d_newitemT!(MersenneTwisterEngine!
            // (...)) whose argument is emitted but reports needsCodegen=false.
            return (instance.inst in context.memberInstances) is null;
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
    imported!"dmd.dmodule".Module[] rootModules,
    in bool includeDefaultImports,
) {
    import dmd.dmodule: Module;

    Module[] result;
    bool[Module] visited;
    foreach (module_; rootModules)
        visited[module_] = true;

    void walk(Module current) {
        foreach (i; 0 .. current.aimports.length) {
            auto imported_ = current.aimports[i];
            if (imported_ in visited)
                continue;
            visited[imported_] = true;
            if (isUnderDefaultImportPaths(imported_)) {
                if (includeDefaultImports)
                    result ~= imported_;
                continue;
            }
            result ~= imported_;
            walk(imported_);
        }
    }

    foreach (module_; rootModules)
        walk(module_);
    return result;
}

// Whether any of these modules holds a template instance as a member. The
// snippet's semantic pass appends a dependency-image module's instantiated
// templates to that module's members, so a non-empty hit means this link will
// emit instances that can reference druntime/phobos members.
private bool hasTemplateInstanceMember(imported!"dmd.dmodule".Module module_) {
    if (module_.members is null)
        return false;
    foreach (i; 0 .. module_.members.length)
        if ((*module_.members)[i].isTemplateInstance)
            return true;
    return false;
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
// and codegen silently emits nothing for bodies that never got it. Run this
// in the disposable codegen child: its template instances must not persist
// into a later fixture. checkaction=context matches snippet compilation.
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

private void prepareDependencyImageImportsForTemplateCodegen(
    imported!"dmd.dmodule".Module[] modules,
) {
    foreach (module_; modules)
        module_.importedFrom = module_;
}

// The vendored frontend ships no inline assembler (source/dmd/iasm.d is a
// no-op shim), so DMD's glue emits an empty body for any function holding an
// `asm{}` block, which then returns garbage at run time. Refuse such a module
// up front -- in the parent, before the codegen fork -- so the failure is a
// clear, attributable error (e.g. a bench skip) rather than a silent
// miscompile. The shim records the offending module during its semantic3.
private void throwOnInlineAsm(imported!"dmd.dmodule".Module[] modules) {
    import dmd.iasm: moduleHasInlineAsm;
    import std.string: fromStringz;

    foreach (module_; modules)
        if (moduleHasInlineAsm(module_))
            throw new Exception(
                "the native codegen backend does not support inline asm"
                ~ " (used by module " ~ module_.toPrettyChars.fromStringz.idup ~ ")",
            );
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

// Only accessed under the compiler lock (emitObjectFilesForLink is always
// called inside withCompilerLock).
private __gshared bool _backendInitialised;
private __gshared string[] _defaultImportPaths;
