module quickbite.backends.native.system_linker;


private:


public class SystemLinker: imported!"quickbite.backends.runner".Runner {
    import quickbite.backends.runner: TestResult;
    import dmd.dmodule: Module;

    public override TestResult[] runTests(Module module_) {
        import quickbite.frontend.util: foreachUnitTestDeclaration;
        import core.runtime: Runtime;

        auto library = compileToSharedLibrary(module_);
        // The results copy everything they need out of the library, so it can
        // be unloaded as soon as the tests have run.
        scope(exit) Runtime.unloadLibrary(library);

        TestResult[] cases;
        foreachUnitTestDeclaration(module_, (unitTest) {
            cases ~= runUnitTest(library, unitTest);
        });

        return cases;
    }
}

private void* compileToSharedLibrary(imported!"dmd.dmodule".Module module_) {
    import quickbite.frontend.compiler: withCompilerLock;
    import core.atomic: atomicFetchAdd;
    import std.conv: text;
    import std.file: mkdirRecurse, rmdirRecurse, tempDir;
    import std.path: buildPath;

    // Unique paths per call: dlopen caches by path, so reusing one would
    // return a previously loaded library instead of the new code.
    const index = atomicFetchAdd(_libraryCounter, 1u);
    const dir = buildPath(tempDir, text("quickbite_native_", index));
    mkdirRecurse(dir);
    // The loader keeps the library mapped after Runtime.loadLibrary, so the
    // files can go as soon as it is loaded.
    scope(exit) rmdirRecurse(dir);
    const objPath = buildPath(dir, "module.o");
    const libPath = buildPath(dir, "module.so");

    withCompilerLock(() {
        emitObjectFile(module_, objPath);
    });
    linkSharedLibrary(objPath, libPath);

    return loadSharedLibrary(libPath);
}

private void emitObjectFile(
    imported!"dmd.dmodule".Module module_,
    in string objPath,
) {
    import dmd.root.filename: FileName;

    initialiseBackend;

    module_.objfile = FileName(objPath);
    removeForeignTemplateInstances(module_);

    // Codegen marks every emitted symbol as written once per process, so a
    // module that was already codegen'd would otherwise produce an empty
    // object file.
    resetCodegenState(module_);
    generate(module_, objPath);

    // DMD instantiates each template once per process, owned by whichever
    // root module instantiated it first, and codegen only emits an instance
    // into its owner's object. Any instance this module uses but does not
    // own is therefore an undefined symbol in the object just written, so
    // adopt those instances as members and re-emit until nothing new gets
    // adopted. Each shared library links independently and template symbols
    // are COMDATs, so the duplicate emission across objects is safe.
    while (adoptInstancesFor(undefinedSymbols(objPath), module_)) {
        resetCodegenState(module_);
        generate(module_, objPath);
    }
}

// Clear the process-global "already written" codegen state
// (FuncDeclaration.semanticRun at PASS.obj, backend Symbols cached in
// Dsymbol.csym) so the next generateCodeAndWrite emits the symbols again,
// into the current object file.
private void resetCodegenState(imported!"dmd.dsymbol".Dsymbol symbol) {
    import dmd.dsymbol: PASS;
    import dmd.dsymbolsem: include;

    // An uninstantiated template body is parse-time AST that never gets
    // codegen'd; walking its raw statements would trip asserts downstream.
    if (symbol.isTemplateDeclaration !is null)
        return;

    symbol.csym = null;

    if (auto function_ = symbol.isFuncDeclaration) {
        if (function_.semanticRun == PASS.obj) {
            function_.semanticRun = PASS.semantic3done;
            resetLocalVariables(function_);
        }
    }

    if (auto unitTest = symbol.isUnitTestDeclaration) {
        // Nested functions are codegen'd with their unittest, not as module
        // members, so the member walk below cannot reach them.
        foreach (i; 0 .. unitTest.deferredNested.length)
            resetCodegenState(unitTest.deferredNested[i]);
    }

    // Process-global appends can grow `members` while it is walked (see
    // removeForeignTemplateInstances), so iterate by index.
    if (auto scope_ = symbol.isScopeDsymbol) {
        if (scope_.members !is null)
            foreach (i; 0 .. scope_.members.length)
                resetCodegenState((*scope_.members)[i]);
    }

    if (auto attribute = symbol.isAttribDeclaration) {
        if (auto declarations = include(attribute, null))
            foreach (i; 0 .. declarations.length)
                resetCodegenState((*declarations)[i]);
    }
}

// Parameters and body-local variables get backend Symbols of their own; a
// stale one still carries the local-symbol-table index from the previous
// codegen and trips `assert(s.Ssymnum == SYMIDX.max)` in symbol_add when the
// function is emitted again.
private void resetLocalVariables(imported!"dmd.func".FuncDeclaration function_) {
    import dmd.declaration: VarDeclaration;
    import dmd.expression: Expression;
    import dmd.visitor.foreachvar: foreachExpAndVar, foreachVar;

    void resetVariable(VarDeclaration variable) {
        variable.csym = null;
    }

    if (function_.parameters !is null)
        foreach (i; 0 .. function_.parameters.length)
            resetVariable((*function_.parameters)[i]);
    if (function_.vthis !is null)
        resetVariable(function_.vthis);
    if (function_.vresult !is null)
        resetVariable(function_.vresult);

    foreachExpAndVar(
        function_.fbody,
        (Expression expression) { foreachVar(expression, &resetVariable); },
        &resetVariable,
    );
}

private void generate(
    imported!"dmd.dmodule".Module module_,
    in string objPath,
) {
    import dmd.glue: generateCodeAndWrite;
    import dmd.globals: global;

    enum noLibModules = (const(char)*[]).init;
    enum noLibName = "";
    enum currentDirectory = "";
    enum doNotWriteLibrary = false;
    enum writeObjectFile = true;
    enum oneObjectFile = true;
    enum doNotSplitObject = false;
    enum doNotPrintProgress = false;

    generateCodeAndWrite(
        [module_],
        noLibModules,
        noLibName,
        currentDirectory,
        doNotWriteLibrary,
        writeObjectFile,
        oneObjectFile,
        doNotSplitObject,
        doNotPrintProgress,
    );
    if (global.errors != 0)
        throw new Exception("codegen failed: " ~ objPath);
}

// Append to this module's members every template instance that some other
// module owns but whose symbols this module's object references without
// containing (= they are undefined in the object just written). The next
// codegen pass then emits them here: needsCodegen() is true for any
// non-speculative instance owned by a root module, and emission location is
// purely a question of whose members array holds the instance.
private bool adoptInstancesFor(
    in string[] undefinedSymbols,
    imported!"dmd.dmodule".Module module_,
) {
    import dmd.dmodule: Module;
    import std.algorithm.searching: any, canFind, startsWith;

    if (undefinedSymbols.length == 0)
        return false;

    bool adopted = false;
    foreach (moduleIndex; 0 .. Module.amodules.length) {
        auto candidateModule = Module.amodules[moduleIndex];
        if (candidateModule is module_ || candidateModule.members is null)
            continue;
        foreach (i; 0 .. candidateModule.members.length) {
            auto instance = (*candidateModule.members)[i].isTemplateInstance;
            if (instance is null
                || instance.inst !is instance // only primaries carry code
                || instance.errors
                || instance.minst is null) // speculative, never emitted
                continue;
            const prefix = mangledPrefix(instance);
            if (!undefinedSymbols.any!(symbol => symbol.startsWith(prefix)))
                continue;
            if ((*module_.members)[].canFind!(member => member is instance))
                continue;
            module_.members.push(instance);
            adopted = true;
        }
    }
    return adopted;
}

// The mangled prefix shared by every symbol an instance emits, e.g.
// _D4core8internal7dassert__T14_d_assert_failTiZ for _d_assert_fail!int.
private string mangledPrefix(
    imported!"dmd.dtemplate".TemplateInstance instance,
) {
    import dmd.common.outbuffer: OutBuffer;
    import dmd.dsymbol: Dsymbol;
    import dmd.mangle: mangleToBuffer;

    OutBuffer buffer;
    buffer.writestring("_D");
    // The cast selects the Dsymbol overload, which mangles the fully
    // qualified name; the TemplateInstance overload would drop the parents.
    mangleToBuffer(cast(Dsymbol) instance, buffer);
    return buffer.extractSlice.idup;
}

// The undefined symbols of the object file just written: exactly the set the
// linker has to find elsewhere (`-z defs` turns any leftover into a link
// error), read straight from the ELF symbol table.
private string[] undefinedSymbols(in string objPath) {
    import core.sys.linux.elf: Elf64_Ehdr, Elf64_Shdr, Elf64_Sym, SHN_UNDEF,
        SHT_SYMTAB;
    import std.file: read;
    import std.string: fromStringz;

    const bytes = cast(const ubyte[]) read(objPath);
    const header = cast(const Elf64_Ehdr*) bytes.ptr;
    const sections = cast(const Elf64_Shdr*) (bytes.ptr + header.e_shoff);

    string[] result;
    foreach (sectionIndex; 0 .. header.e_shnum) {
        const section = sections + sectionIndex;
        if (section.sh_type != SHT_SYMTAB)
            continue;
        const strings = sections + section.sh_link;
        const symbols = cast(const Elf64_Sym*) (bytes.ptr + section.sh_offset);
        foreach (i; 0 .. section.sh_size / Elf64_Sym.sizeof) {
            const symbol = symbols + i;
            if (symbol.st_shndx != SHN_UNDEF || symbol.st_name == 0)
                continue;
            const name =
                cast(const char*) (bytes.ptr + strings.sh_offset + symbol.st_name);
            result ~= name.fromStringz.idup;
        }
    }
    return result;
}

// Template instances and TypeInfo declarations from *every* compilation in
// the process get appended to the first root module's members
// (TemplateInstance.appendToModuleMember and typinf.getTypeInfoType both
// redirect non-root modules through importedFrom). Emitting those would make
// the object reference symbols from other modules, so only keep what this
// module produced itself.
private void removeForeignTemplateInstances(imported!"dmd.dmodule".Module module_) {
    if (module_.members is null)
        return;

    size_t numKept = 0;
    foreach (member; *module_.members) {
        if (auto instance = member.isTemplateInstance) {
            if (instance.minst !is module_)
                continue;
        }
        if (auto typeInfo = member.isTypeInfoDeclaration) {
            if (typeModule(typeInfo.tinfo) !is module_)
                continue;
        }
        (*module_.members)[numKept++] = member;
    }
    module_.members.setDim(numKept);
}

// The module a type's TypeInfo belongs in: the one declaring the aggregate at
// the bottom of the type. Null for basic types, whose TypeInfos druntime
// already exports.
private imported!"dmd.dmodule".Module typeModule(imported!"dmd.mtype".Type type) {
    for (;;) {
        if (auto structType = type.isTypeStruct)
            return structType.sym.getModule;
        if (auto classType = type.isTypeClass)
            return classType.sym.getModule;
        if (auto next = type.nextOf) {
            type = next;
            continue;
        }
        return null;
    }
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

private void linkSharedLibrary(in string objPath, in string libPath) {
    import std.conv: text;
    import std.process: execute;

    // Link against shared phobos so the library shares the host's druntime
    // (one GC, one DSO registry) instead of smuggling in its own copy.
    // `-z defs` turns any symbol the generated code fails to provide into a
    // link error instead of a load-time failure.
    const result = execute([
        "dmd",
        "-shared",
        "-defaultlib=libphobos2.so",
        "-L=-z",
        "-L=defs",
        "-of=" ~ libPath,
        objPath,
    ]);
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
// Only accessed from initialiseBackend, which only runs under the compiler
// lock (emitObjectFile is always called inside withCompilerLock).
private __gshared bool _backendInitialised;
