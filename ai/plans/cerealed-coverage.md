# Plan: Run Cerealed Unit Tests on Both Backends

## Goal

Run the real cerealed serialization library's `unittest` blocks through
quickbite's IR and tree-walking backends, working toward full coverage.
Both backends are extended in parallel using worktrees + subagents.

---

## What Has Been Done (cerealed-setup branch)

- **Vendored cerealed** into `vendor/cerealed/src/` and
  `vendor/cerealed/tests/` (copied from `~/.dub/packages/cerealed/`).
- **Added `tests/ut/cerealed.d`**: generates one test per
  `(backend, testFile)` pair.  `makeCerealSource` concatenates the
  unit_threaded stubs + all library `.d` files + the test file into one
  string, stripping `module cerealed.*`, `module tests.*`,
  `import cerealed*`, and `import unit_threaded` lines.
- **Registered** `"ut.cerealed"` in `tests/main.d`.
- **Set `fatalErrorHandler = () => true`** in `Compiler` to prevent DMD
  from calling `exit()` on cascading errors; without this the first
  failing cerealed test aborted the entire process.
- **Patched `vendor/cerealed/src/cerealiser.d`**:
  - Removed `AppenderCerealiser` and `ScopeBufferCerealiser` aliases.
    Both trigger `_d_arraysetlengthTImpl` in DMD-as-library CTFE.
  - Changed `Cerealiser` alias to `DynamicArrayCerealiser`.
  - Changed `cerealise(alias F, ...)` to use `DynamicArrayCerealiser`.
  - Replaced `enforce(..., text(...))` with a string literal because
    `std.conv.text` uses `Appender` internally and also fails CTFE.
  - Removed two `static assert(isCereal!)` / `static assert(isCerealiser!)`
    calls that cascade through `grainBits` → CTFE failure.
- **Patched `vendor/cerealed/src/range.d`**:
  - Removed `static assert(isCerealiserRange!ScopeBufferRange)` (its
    `put` uses C `realloc`, which fails in DMD-as-library CTFE).

---

## Current Baseline (38 tests, 0 passing)

```
38 = 19 test files × 2 backends
```

| Failure category | Count | Root cause |
|---|---|---|
| DMD reported an error without a diagnostic message | 36 | `_d_arraysetlengthTImpl` not found during `fullSemantic` of templates that instantiate AA operations |
| Unsupported declaration: struct (IR) | 1 | IR backend does not handle struct declarations |
| Unsupported expression: declaration (tree-walking) | 1 | Tree-walking backend does not handle struct declarations |

The silent-DMD-error category happens because `core.internal.newaa`
uses `arr.length = n` (array length assignment) during template
constraint evaluation, which is an unsupported CTFE intrinsic when DMD
is used as a library.  Only `structs.d` avoids triggering these
templates and therefore gets past DMD.

---

## Phase 2: Unblock the Remaining 36 Tests

Before backend feature work makes sense, most tests need to pass DMD
semantic analysis.

### 2.1 Identify the triggering templates

The errors come from:
```
core.internal.newaa.Impl!(K, V) → arr.length = n → _d_arraysetlengthTImpl
```
instantiated when cerealed's template constraints evaluate `is(T ==
struct)` on types that have an AA field somewhere in their template
chain.  The triggering happens inside `grainMember` / `grainAllMembers`
in `cereal.d` when a struct with an AA field is encountered.

### 2.2 Patch cereal.d to avoid the AA CTFE path

Option A (preferred): add an `@disable` guard or restructure the
template constraints in `cereal.d` so that the AA grain functions are
never evaluated during CTFE.  Concretely: wrap the AA-handling `grain`
overload in a version block or move the `newaa` usage behind a runtime
branch.

Option B: strip the AA-handling grain overloads from the vendored
cereal.d and re-enable them once associative arrays are supported by
both backends.

Implement in `vendor/cerealed/src/cereal.d`; add a comment explaining
why.

---

## Phase 3: Feature Roadmap

Each feature must be added to **both backends in parallel** using
worktrees + subagents.  TDD per AGENTS.md: write a failing test in
`tests/ut/language.d` first, then implement.

### 3.1 Struct declarations and field access (unblocks both failing tests)

Already at the gate:
- IR: `Unsupported declaration: struct` in lowering.d:654
- TW: `Unsupported expression: declaration` in tree_walking.d:786

**IR work:**
- Emit a `StructType` record in the IR for struct declarations.
- Add `FieldLoad` / `FieldStore` instructions for dot-var expressions.
- Add struct instances to the value store (treat as a flat bag of
  temporaries indexed by field).

**Tree-walking work:**
- Handle `StructDeclaration` and `VarDeclaration` of struct type.
- Handle `DotVarExp` for field access.

### 3.2 Operator overloading (`opOpAssign`, `opEquals`)

Cerealed's public API is entirely driven by `enc ~= val` which DMD
lowers to a `CallExp` on `opOpAssign!"~"` for the struct type.  Both
backends need to handle this as a regular method call.  Verify first
that `CatAssignExp` on a struct is already a `CallExp` after
`fullSemantic` (it should be).

### 3.3 Exception support

Required to make `shouldThrow` stubs meaningful and for cerealed's own
`CerealException` error paths.

- `ThrowStatement` / throw expression
- `TryCatchStatement` with typed catches
- `Exception` class hierarchy (base case only)

### 3.4 Strings

- `string` as `immutable(char)[]`
- String literals
- String concatenation (`~`) and comparison
- `char` type

### 3.5 Floats

- `float` / `double` literals and arithmetic
- Bit-cast via union (cerealed's `FloatUnion` in utils.d)
- Int ↔ float casts

### 3.6 Associative arrays

- `V[K]` type
- Index read / write, `.length`, `.keys`, `.values`
- `foreach (k; aa)` (key iteration)
- `in` operator

### 3.7 Classes

- `new` expression (heap allocation)
- Field access on class instances (`DotVarExp`)
- Virtual method dispatch (direct first, then vtable)
- `null` and `is null` / `!is null`

### 3.8 Interfaces and virtual dispatch

Needed for cerealed's output-range protocol.

- Interface declarations
- Virtual dispatch on interface references

### 3.9 Pointers

- `T*`, `new T` (pointer allocation), dereference (`*ptr`)
- Null pointer checks

### 3.10 `scope(exit)` and `with` statement

- `ScopeGuardStatement`
- `WithStatement`

---

## Parallel Execution Model

Each feature phase (3.1–3.10) is implemented by two worktrees running
as parallel subagents:

| Worktree | Backend | Branch |
|---|---|---|
| `ir-<feature>` | IR + lowering | `ir-<feature>` |
| `tw-<feature>` | Tree-walking | `tw-<feature>` |

Protocol per worktree:
1. Write a failing test in `tests/ut/language.d`.
2. Confirm it fails with `dub test -- -s <testname>`.
3. Implement the feature.
4. Confirm all tests pass with `dub test -- -s`.
5. Open a PR for review.

Do not merge both worktrees until both PRs are approved.

---

## Critical Files

| File | Role |
|---|---|
| `vendor/cerealed/` | Vendored cerealed source (patched) |
| `tests/ut/cerealed.d` | Test driver (concat + runner) |
| `tests/ut/language.d` | Language feature tests (TDD) |
| `source/quickbite/backends/tree_walking.d` | Tree-walking backend |
| `source/quickbite/backends/ir.d` | IR executor |
| `source/quickbite/frontend/lowering.d` | IR lowering pass |
| `source/quickbite/ir/instruction.d` | IR instruction set |
| `source/quickbite/frontend/compiler.d` | DMD-as-library wrapper |

---

## Key Constraints

- **No dub dependency on cerealed**: the vendored source is compiled
  only via `parseModule` inside the test harness.
- **No multi-module support needed**: single concatenated string per
  test, with module declarations stripped.
- **Only `unittest {}` blocks run**: named test functions
  (`testEncDecBool`, etc.) are ignored by quickbite's discovery.
- **Serial test execution**: `dub test -- -s` always, because DMD's
  `__gshared` state is not thread-safe.
- **CTFE limitations**: `std.array.Appender`, `std.conv.text`,
  `core.internal.newaa` all fail in DMD-as-library CTFE.  Avoid them
  in vendored patches.
