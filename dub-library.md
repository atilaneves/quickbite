# dub-library worktree handoff

## Goal

Replace the `dub describe` subprocess in `tests/ut/dub_paths.d` with
direct dub D library calls.

The current `master` API is not the old `cerealImportPaths` shape. The
code now exposes `dubImportPaths`, `cerealSrcDir`, and `cerealTestsDir`,
and quickbite has `runTestsFromFile`. Continue against that API shape.

## Branch State

The worktree is:

- `/home/atila/coding/d/quickbite/.claude/worktrees/dub-library`
- branch `worktree-dub-library`
- rebased onto `master` at `2e8f527`

Current files added or changed by this work:

- `dub-library.md`
- `vendor/dub_library/`
- `vendor/dub_patches/`

There is also an autostash:

```text
stash@{0}: autostash
```

Do not blindly pop it. Its `dub.sdl` and `tests/ut/dub_paths.d` changes
target the pre-rebase API and conflict with `master`. Use it only as a
reference.

## Current Master Code To Replace

`tests/ut/dub_paths.d` calls `dub describe` via subprocess in
`loadDubDescription` and parses its JSON output into:

```d
private struct DubDescription {
    string[string] packageDirs;
    string[][string] packageImportPaths;
    string[][string] packageUnusedSources;
}
```

The replacement must preserve `dubImportPaths`, `cerealSrcDir`, and
`cerealTestsDir`.

## Dub Library API (dub 1.40.0)

### Key types

All under `vendor/dub_source/source/`:

| Type | Module |
|------|--------|
| `PackageManager` | `dub.packagemanager` |
| `Package` | `dub.package_` |
| `SelectedVersions` | `dub.recipe.selection` |
| `Project` | `dub.project` |
| `GeneratorSettings` | `dub.generators.generator` |
| `BuildPlatform` | `dub.platform` |
| `ProjectDescription` | `dub.description` |
| `PackageDescription` | `dub.description` |
| `SourceFileDescription` | `dub.description` |
| `SourceFileRole` | `dub.description` |
| `NativePath` | `dub.internal.vibecompat.inet.path` |

### Step-by-step: get a `ProjectDescription`

```d
// 1. Create PackageManager
//    Constructor appends ".dub/packages/" to package_path
//    and "packages/" to user_path automatically.
auto pm = new PackageManager(
    NativePath(projectRoot),   // local: looks in projectRoot/.dub/packages/
    NativePath(homePath),      // user:  looks in homePath/packages/
    NativePath.init,           // system: empty
);

// 2. Load the root Package from disk
auto pack = pm.getOrLoadPackage(NativePath(projectRoot));

// 3. Construct Project (auto-loads dub.selections.json)
auto project = new Project(pm, pack);

// 4. Build platform — use determineBuildPlatform() from dub.platform
//    to get platform/architecture/compiler/frontendVersion for the
//    current build.  compilerBinary is left empty by that function.
import dub.platform : determineBuildPlatform;
auto bp = determineBuildPlatform();

// 5. GeneratorSettings — only platform and config are required for
//    package description.  Leave buildType empty to skip the more
//    expensive TargetDescription pass.
GeneratorSettings gs;
gs.platform = bp;
gs.config   = project.getDefaultConfiguration(bp);
// gs.buildType = "";  // leave empty → targets not populated

// 6. Describe
ProjectDescription desc = project.describe(gs);
```

`desc.packages` is a `PackageDescription[]`.  Each entry has:

```d
struct PackageDescription {
    string name;
    string path;           // absolute path with trailing slash
    string[] importPaths;  // relative to path — must be joined with path
    SourceFileDescription[] files;
}

struct SourceFileDescription {
    SourceFileRole role;
    string path;   // absolute path
}

enum SourceFileRole {
    unusedStringImport,
    unusedImport,
    unusedSource,   // ← what parseDubDescription checks for
    stringImport,
    import_,
    source,
}
```

### Reconstructing `DubDescription` from `ProjectDescription`

```d
foreach (pkg; desc.packages) {
    ret.packageDirs[pkg.name] = pkg.path;

    // importPaths are relative to pkg.path — join them
    string[] abs;
    foreach (ip; pkg.importPaths)
        abs ~= buildNormalizedPath(pkg.path, ip);
    ret.packageImportPaths[pkg.name] = abs;

    // unusedSources — paths are already absolute in SourceFileDescription
    string[] unused;
    foreach (f; pkg.files)
        if (f.role == SourceFileRole.unusedSource)
            unused ~= f.path;
    ret.packageUnusedSources[pkg.name] = unused;
}
```

### `PackageManager` constructor detail

```d
// The two-NativePath overload:
this(NativePath package_path,   // → local cache: package_path/.dub/packages/
     NativePath user_path,      // → user cache:  user_path/packages/
     NativePath system_path,    // → system cache: system_path/packages/
     bool refresh_packages = true)
```

Pass `NativePath.init` for `system_path` when there is no system cache.

The user cache path is typically `expandTilde("~")` or the home
directory, not `~/.dub` directly — the constructor appends `packages/`,
not `.dub/packages/`.  The *local* cache gets `.dub/packages/` appended,
so passing `projectRoot` is correct.

### `getDefaultConfiguration`

```d
string getDefaultConfiguration(
    in BuildPlatform platform,
    bool allow_non_library_configs = true,
) const
```

Returns the configuration name string for the root package on the given
platform. Pass `"unittest"` explicitly instead if the project needs the
unittest config.

### `describe` and `GeneratorSettings`

`Project.describe(GeneratorSettings)` — defined in `dub/project.d:996`.

For package-only description (no target linking info):

- **Required**: `gs.platform`, `gs.config`
- **Leave empty**: `gs.buildType` — if non-empty, dub runs the
  `TargetDescriptionGenerator` which may invoke the compiler.

## Vendor Layout

```
vendor/
  dub_source/          ← vendored dub 1.40.0 source tree
  dub_library/         ← sub-package "quickbite-dub-library"
    dub.sdl
    source/
      quickbite_dub_library/
        package_resolver.d    ← describeProject and resolvePackagePath
        package_resolver.di   ← declaration-only interface
  dub_patches/         ← patched dub 1.40.0 source files
    dub/dependency.d
    dub/internal/configy/Exceptions.d
    dub/internal/configy/Utils.d
```

The `vendor/dub_library/dub.sdl` points at the vendored dub 1.40.0
source and applies the patches:

```sdl
importPaths "../dub_source/source"
sourcePaths "../dub_source/source"
sourcePaths "../dub_patches"
excludedSourceFiles "../dub_source/source/app.d"
excludedSourceFiles "../dub_source/source/dub/dependency.d"
excludedSourceFiles "../dub_source/source/dub/internal/configy/Exceptions.d"
excludedSourceFiles "../dub_source/source/dub/internal/configy/Utils.d"
versions "DubUseCurl"
```

Remove `vendor/dub_library/libquickbite-dub-library.a` before committing
— it is a generated artifact.

## Dub Patch Files

The `vendor/dub_patches/` directory patches three dub 1.40.0 files for
`-preview=dip1000`:

- `dub/dependency.d` — fix `Version`/`VersionRange` scope issues
- `dub/internal/configy/Exceptions.d` — keep existing `@trusted`,
  wrap only specific unsafe calls in narrow `@trusted` lambdas
- `dub/internal/configy/Utils.d` — make `Colored.toString` a template
  so `std.format` can instantiate it

## Completed

1. Expanded `quickbite_dub_library.package_resolver` to expose
   `PackageInfo` and `describeProject`:

   ```d
   struct PackageInfo {
       string dir;
       string[] importPaths;
       string[] unusedSources;
   }

   PackageInfo[string] describeProject(
       in string projectRoot,
       in string homeDir,
       in string config,
   ) @trusted;
   ```

   The `.di` interface file is in sync.

2. Updated `vendor/dub_library/dub.sdl` to also expose
   `importPaths "source"` so the sub-package's own modules are visible.

3. Added `dependency "quickbite-dub-library" path="vendor/dub_library"`
   to both `unittest` and `unittest-cov` configs in root `dub.sdl`.
   Keep the existing `cerealed` repository dependency unchanged.

4. Reworked `loadDubDescription` in `tests/ut/dub_paths.d` to call the
   library helper instead of the `execute(["dub", "describe", ...])`.

5. Kept all `dub.*` imports inside `vendor/dub_library`. Root package
   imports only `quickbite_dub_library.*`.

6. Ran `dub test -- -s`; it passes.

## Implementation Notes

- The local helper package is removed from the root package recipe before
  constructing `Project`. Otherwise dub tries to describe the helper package
  too, and its absolute vendored dub source paths trigger a `NativePath`
  assertion.
- The dub compiler registry is empty when these modules are embedded directly,
  so `DMDCompiler`, `GDCCompiler`, and `LDCCompiler` are registered once before
  `Project.describe`.
- `determineBuildPlatform` leaves `compilerBinary` empty, but
  `Package.describe` calls `getCompiler(platform.compilerBinary)`. The wrapper
  sets `compilerBinary` to the canonical compiler name.
- For dub 1.40.0, pass `$HOME/.dub` as `packageCacheRoot`; `PackageManager`
  appends `packages/` itself.
- `SourceFileDescription.path` can be relative for unused source files, so the
  wrapper normalizes it against the package path.

## Notes

- Run tests with `dub test -- -s` (serial) to avoid spurious failures
  from `__gshared` DMD state.
- The shell startup emits SSH-agent permission errors. They are noise
  unless the command itself fails.
- Do not run multiple `dub test` commands in this checkout at once.
- `dub describe` subprocess must not remain after the library
  replacement preserves the current behaviour.
