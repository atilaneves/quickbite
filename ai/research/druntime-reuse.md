# Druntime reuse census (2026-08-13)

Evidence base for AGENTS.md's druntime-first rule: which runtime
behaviours each backend executes through druntime's real source or
hooks, and which it reimplements locally. Two incidents motivated the
rule, both agent-introduced representation drift with no mechanical
check against ground truth:

- The Bytecode slice descriptor was laid out `{ptr, length}` while
  compiled D uses `{length, ptr}`, forcing compensating word swaps at
  every native-call crossing until commit `7d76f1ad` flipped it.
- Both backends carried from-scratch associative arrays. PR #480
  deleted the Interpreter's (`native_assoc_array.d`) in favour of
  interpreting druntime's real `core.internal.newaa` source over a
  native `Impl*` handle; the Bytecode VM's remains (see below).

## Census

| Area | Interpreter | Bytecode VM |
|---|---|---|
| Associative arrays | real druntime source, interpreted | from-scratch linear-scan table, no hashing; by-name hook interception bypasses druntime bodies |
| Array append/grow | real `gc_expandArrayUsed` check; hand-rolled copy/grow path | same check, independently written; exact-size reallocation makes repeated `~=` quadratic |
| Hashing | real (interpreted druntime source) | none (linear scan) |
| Exception chaining | real `Throwable` objects; writes `_nextInChainPtr` directly | synthetic catch-shape objects, not real `Throwable`s |
| TypeInfo / typeid | `TypeName` string tags (display only) | real `TypeInfo_Class` objects |
| Display formatting | guest formatter (real interpreted D) | host-side `Value.toString` reimplementation |
| Interception governance | `enforceInterceptionPolicy`: enumerated exemptions, retirement conditions, assertion-enforced | none; separate ad-hoc interception tables |

The Interpreter's `enforceInterceptionPolicy` is the working model of
the rule: everything with a D body and no inline asm executes for real,
exemptions are enumerated with retirement conditions, violations
assert. The convergence work items live in `ai/plans/bytecode.md`
(milestone 2) and `ai/plans/value.md` (druntime-first backlog).

One principled exception class stands: behaviour that is host-coupled
in a way the guest cannot share (e.g. TypeInfo for interpreted-only
guest types, which has no resident native object) is handled as
interpreter-owned metadata per `value.md` decision 15, not by calling a
host facility that cannot exist.
