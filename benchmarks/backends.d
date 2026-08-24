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
    string[] dependencyImages;
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
    return new Bytecode(env.dependencyImages);
}

private Runner makeInterpreter(in BackendEnv env) {
    return new Interpreter(env.dependencyImages);
}

// Like `dub test`: only the project under test is codegen'd per run.
private Runner makeSystemLinker(in BackendEnv env) {
    return new SystemLinker(
        env.dependencyImages,
        env.importPaths,
        env.packageRoot,
        env.frontendFlags,
        env.dubPackage,
    );
}

// In-process ORC JIT: reuses SystemLinker's object production and resolves
// druntime/phobos and dependency-image symbols from the running process.
private Runner makeLLVMJit(in BackendEnv env) {
    return new LLVMJit(
        env.dependencyImages,
        env.importPaths,
        env.packageRoot,
        env.frontendFlags,
        env.dubPackage,
    );
}

public Runner[string] makeRunners(
    in BackendEnv env,
    in string[] backendNames = null,
) {
    Runner function(in BackendEnv)[string] registry = [
        "ctfe":          &makeCtfe,
        "bytecode":      &makeBytecode,
        "interpreter":   &makeInterpreter,
        "system-linker": &makeSystemLinker,
        "llvmjit":       &makeLLVMJit,
    ];

    Runner[string] runners;
    const names = backendNames.length == 0 ? registry.keys : backendNames;
    foreach (name; names) {
        if (name !in registry)
            continue;
        runners[name] = registry[name](env);
    }
    return runners;
}
