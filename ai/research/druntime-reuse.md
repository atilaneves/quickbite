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

- **Associative arrays:** Interpreter executes real druntime source over native
  handles, with metadata only where guest `Impl` fields cannot hold a host
  object. Bytecode uses a linear-scan table and name-based hooks.
- **Array append and growth:** Interpreter uses the real
  `gc_expandArrayUsed` check but still has temporary allocation, copy, and
  growth code. Bytecode has an independent path whose exact-size reallocation
  makes repeated append quadratic.
- **Hashing:** Interpreter executes real druntime source. Bytecode uses linear
  scans.
- **Exception chaining:** Interpreter uses real `Throwable` objects but writes
  `_nextInChainPtr` directly. Bytecode uses synthetic catch-shape objects.
- **TypeInfo and `typeid`:** Interpreter uses native or synthesized identity
  metadata; `_d_arrayctor` still has a name-matched substitute. Bytecode uses
  real `TypeInfo_Class` objects.
- **Display:** Interpreter executes the guest D formatter. Bytecode uses
  backend-local host rendering.
- **Interception:** the Interpreter contract permits none. Monitor and
  `_d_arrayctor` name matches remain as temporary deviations. Bytecode has
  separate interception tables.

The Interpreter is carrier-free: guest data lives in native typed places, and
native calls consume typed addresses. `ai/plans/interpreter.md` owns that
storage boundary and the druntime-first and no-interception contracts. The
remaining deviations have explicit issue owners: monitors [#561],
`_d_arrayctor` and its `TypeInfo` path [#562], allocation and length [#565],
append and reserve [#566], exception chaining [#568], concatenation [#569],
and dead policy cleanup [#570]. Bytecode convergence remains in
`ai/plans/bytecode.md`.

Host-coupled facts that guest bytes cannot express, such as identity for an
interpreted-only callable or type, stay as Interpreter metadata. They are not
a second guest value representation and must follow typed storage clear, copy,
move, and lifetime rules.

[#561]: https://github.com/atilaneves/quickbite/issues/561
[#562]: https://github.com/atilaneves/quickbite/issues/562
[#565]: https://github.com/atilaneves/quickbite/issues/565
[#566]: https://github.com/atilaneves/quickbite/issues/566
[#568]: https://github.com/atilaneves/quickbite/issues/568
[#569]: https://github.com/atilaneves/quickbite/issues/569
[#570]: https://github.com/atilaneves/quickbite/issues/570
