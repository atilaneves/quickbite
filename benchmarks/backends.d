module benchmarks.backends;

import quickbite.backends.runner: Runner;
import quickbite.backends.ctfe: Ctfe;
import quickbite.backends.interpreter: Interpreter;
import quickbite.backends.native: LLVMJit, SystemLinker;

private:

// Everything any backend factory might need; each factory ignores the fields
// it does not use.
public struct BackendEnv {
    string[] importPaths;
    string[] linkFiles;
    string packageRoot;
    imported!"quickbite.frontend.compiler".FrontendFlags frontendFlags;
    // A dub package is codegen'd as its own root set; a standalone fixture is
    // not. Only set for `--dub` runs (see cli.d).
    imported!"quickbite.backends.native".DubPackage dubPackage;
}

// One registry entry per backend; adding bytecode/ir later is a single line in
// the AA below.
private Runner makeCtfe(in BackendEnv env) {
    return new Ctfe;
}

private Runner makeInterpreter(in BackendEnv env) {
    return new Interpreter;
}

// Like `dub test`: dependency objects come from the dub-built archives; only
// the project under test is codegen'd per run.
private Runner makeSystemLinker(in BackendEnv env) {
    return new SystemLinker(
        env.linkFiles,
        env.importPaths,
        env.packageRoot,
        env.frontendFlags,
        env.dubPackage,
    );
}

// In-process ORC JIT: reuses SystemLinker's object production but resolves
// druntime/phobos and dub shared-image symbols from the running process, and
// static archives through ORC.
private Runner makeLLVMJit(in BackendEnv env) {
    return new LLVMJit(
        env.linkFiles,
        env.importPaths,
        env.packageRoot,
        env.frontendFlags,
    );
}

public Runner[string] makeRunners(in BackendEnv env) {
    Runner function(in BackendEnv)[string] registry = [
        "ctfe":          &makeCtfe,
        "interpreter":   &makeInterpreter,
        "system-linker": &makeSystemLinker,
        "llvmjit":       &makeLLVMJit,
    ];

    Runner[string] runners;
    foreach (name, make; registry)
        runners[name] = make(env);
    return runners;
}
