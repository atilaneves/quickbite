module benchmarks.backends;

import quickbite.backends.runner: Runner;
import quickbite.backends.ctfe: Ctfe;
import quickbite.backends.native: SystemLinker;

private:

// Everything any backend factory might need; each factory ignores the fields
// it does not use.
public struct BackendEnv {
    string[] importPaths;
    string[] linkFiles;
    string packageRoot;
}

// One registry entry per backend; adding bytecode/ir/interpreter later is a
// single line in the AA below.
private Runner makeCtfe(in BackendEnv env) {
    return new Ctfe;
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

public Runner[string] makeRunners(in BackendEnv env) {
    Runner function(in BackendEnv)[string] registry = [
        "ctfe":          &makeCtfe,
        "system-linker": &makeSystemLinker,
    ];

    Runner[string] runners;
    foreach (name, make; registry)
        runners[name] = make(env);
    return runners;
}
