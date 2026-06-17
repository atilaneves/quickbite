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
    );
}

// In-process ORC JIT: reuses SystemLinker's object production but resolves
// druntime/phobos from the running process, so it ignores env (no archive
// linking) like Ctfe does. Archive-backed dub packages are out of its scope.
private Runner makeLLVMJit(in BackendEnv env) {
    return new LLVMJit;
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
