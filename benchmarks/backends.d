module benchmarks.backends;

import quickbite.backends.runner: Runner;
import quickbite.backends.bytecode: Bytecode;
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

private Runner makeCtfe(in BackendEnv env) {
    return new Ctfe;
}

private Runner makeBytecode(in BackendEnv env) {
    return new Bytecode;
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
        env.dubPackage,
    );
}

public Runner[string] makeRunners(in BackendEnv env) {
    Runner function(in BackendEnv)[string] registry = [
        "ctfe":          &makeCtfe,
        "bytecode":      &makeBytecode,
        "interpreter":   &makeInterpreter,
        "system-linker": &makeSystemLinker,
        "llvmjit":       &makeLLVMJit,
    ];

    Runner[string] runners;
    foreach (name, make; registry) {
        // llvmjit is unavailable under the LDC benchmark build (cli.d
        // withoutUnavailableBackends drops it from selection), so it is never
        // timed -- but constructing it still runs its ctor, which dlopens the
        // DMD-compiled dependency image into the LDC host and runs that image's
        // module ctors. For a package with non-trivial shared static ctors
        // (e.g. vibe-core), those ctors execute DMD-codegen'd code against the
        // host's LDC druntime -- the extern(D) ABI mismatch (ai/spikes/ldc-eh/
        // FINDINGS.md) then segfaults the host. Don't construct what we can't run.
        version (LDC) if (name == "llvmjit") continue;
        runners[name] = make(env);
    }
    return runners;
}
