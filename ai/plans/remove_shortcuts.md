# Plan: Remove Cerealed Shortcuts / General Tree-Walker

## Context

The tree-walking backend accumulated cerealed-specific shortcut
functions that intercept known patterns (`grain`, `cerealise`,
`_childCerealisers`, `_output`, etc.) and return pre-computed answers
instead of executing real D code. This is wrong for two reasons:

1. **Overfitting.** The shortcuts encode knowledge of one library's
   internals. Every new D project would require new shortcuts.
2. **Fragility.** Shortcuts can silently give wrong answers (as the
   recent ShouldFail work demonstrated). Real execution is the only
   correct specification.

The goal is a tree-walking backend that runs the unit tests of *any* D
project, the same way DMD's CTFE engine does: by walking the AST and
evaluating it, with a simulated heap for dynamic allocation.

---

## Why This Is Tractable

DMD's own CTFE engine is a tree walker. It handles `new`, `malloc`,
heap-allocated structs, and pointer arithmetic by maintaining an
internal heap table — no OS allocation involved. Our tree walker is
structurally identical and is unconstrained by the compile-time
restrictions that CTFE must obey. We have strictly more latitude.

---

## Phase 1 — Simulated Heap

### What is missing

The current `Value` type is:

```d
alias Value = SumType!(long, long[], LocalPtr);
```

There is no representation for a heap-allocated object. When
interpreted code calls `malloc`, `free`, or `new`, the interpreter
hits "No function body to execute" or falls into a shortcut.

### Approach

Extend `Value` with a `HeapPtr` case — an opaque index into a heap
table owned by `Interpreter`:

```
Value = SumType!(long, long[], LocalPtr, HeapPtr)
```

`Interpreter` gains a heap table (`HeapObject[]` or equivalent). A
`HeapObject` holds whatever the allocation contains: raw bytes, a
scalar, an array, or a struct field map — the same representation
already used for stack values.

Intercepted operations:

| D operation | Interpreter action |
|---|---|
| `malloc(n)` | allocate `n`-byte `HeapObject`, return `HeapPtr` |
| `free(ptr)` | mark slot free (or no-op; GC model is simpler) |
| `new T(args)` | allocate struct `HeapObject`, run constructor |
| `*ptr = v` | write `v` into `heap[ptr.id]` |
| `*ptr` (read) | read from `heap[ptr.id]` |
| `ptr + n` | return `HeapPtr` with adjusted offset |


### Acceptance criteria

- All existing tests continue to pass.
- `source/quickbite/backends/tree_walking.d` contains no strings that
  match `cereal`, `Cereal`, `_childCerealisers`, `_output`, `grain`,
  or `decerealise`.
- Running the cerealed test suite against the tree-walking backend
  produces the same results as the IR backend, without any library-
  specific shortcuts.

---

## Phase 2 — Native Call Bridging (dependency calls)

Standard library and dub dependency functions have compiled native
bodies, not D source bodies the tree-walker can walk. The correct
long-term answer (from `ai/plans/overview.md` step 10) is to
pre-compile dependencies to native code once per session and call into
them via libffi or JIT stubs.

**For now:** when the tree-walker encounters a call with no walkable
body, it must throw an explicit, actionable diagnostic — not silently
return zero or fall into a shortcut. The message should identify the
callee by fully-qualified name so it is clear what bridging would need
to be added.

When bridging is implemented:
- Compile each dub dependency to a `.so` once at session start (fast;
  deps only change on `dub upgrade`).
- At call sites with no D body, marshal the interpreter's `Value`
  arguments into the native calling convention via libffi, invoke the
  symbol, and unmarshal the result back to `Value`.
- The simulated heap from Phase 1 must be compatible: pointers passed
  to native code must be real pointers into an actual memory region,
  not opaque indices.

---

## Files to modify

| File | Change |
|---|---|
| `source/quickbite/backends/tree_walking.d` | Add `HeapPtr` to `Value`; add heap table to `Interpreter`; handle `malloc`/`free`/`new`/pointer ops; remove all cerealed shortcuts |

