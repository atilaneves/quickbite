# Example Corpus: `tests/example.d` Language-Feature Density

## Goal

`tests/example.d` is `bin/bench.sh`'s default fixture
(`benchmarks/cli.d`). Widen the D language surface it exercises so the
benchmark measures more than integer encode/decode and a handful of
control-flow shapes, while staying inside what `bin/bench.sh -b
interpreter -b bytecode` can actually time: `bench.md`'s Check Rule only
times a unit when the selected backends return an identical
`TestResult[]` (same count, names, pass/fail).

## Not quickbite's own test suite

This file is an example corpus, not a `quickbite` behaviour test. Adding
or changing unittests here needs no approval, and no `ci.sh` run — there
is no production change. The only check is `./bin/bench.sh -b interpreter
-b bytecode` succeeding on the result.

## Current coverage

`tests/example.d` exercises `ubyte`/`byte`/`ushort`/`short`/`uint`/`int`/
`ulong`/`long` encode-decode round trips, dynamic arrays (`~=`, slicing,
`$`, assignment), `foreach`/`for`/`switch` control flow, short-circuit
`&&`/`||`, and bitwise ops. It has no floating point, exceptions,
classes/interfaces, delegates/closures, or associative arrays.

## Constraint and method

Every addition must be a construct both `Interpreter` and `Bytecode`
already implement and agree on. The safe source is
`tests/ut/backends/runner/lang/*.d` rows under `Matrix!()` with zero
`Omit!(Interpreter, ...)`/`Omit!(Bytecode, ...)`. `expressions.d` is the
outlier (330 rows, 23 Interpreter-only + 25 Bytecode-only omits, mostly
`ref`/pointer edge cases) — consult it only to confirm a specific shape,
never mine it for new features.

## Queue

1. Floating point `encode`/`decode` (`double`/`float`) — the biggest gap
   given `math.d`'s full-matrix support and no float coverage today.
2. Exceptions — `throw`/`catch`/`finally`, catch-by-base, multi-catch,
   rethrow. Natural fit: make `decode`/`Minicereal.get` throw on
   out-of-bounds input.
3. Classes + interfaces + virtual dispatch — fields, inheritance, default
   field initializers, an interface with runtime-dispatched
   implementations.
4. Delegates / closures / nested functions — capture-by-reference, a
   nested function or IIFE reading an enclosing local or `this` field.
5. Associative arrays — scalar/string/struct keys, nested `AA[AA]`,
   iteration. Avoid AA passed as a `ref` parameter (Interpreter-only
   omit, `tests/ut/backends/runner/lang/arrays.d`).
6. Remaining control flow: `do`/`while`, labeled `break`/`continue`
   across nested loops, `switch` `goto case`/`goto default`, case
   ranges/multi-value cases, `final switch` on an enum, string-typed
   switch cases, ternary `?:`.

## Deferred — no matrix evidence or active backend risk

- `scope(exit/failure/success)`, `invariant(){}`, `in{}`/`out{}`
  contracts: no test evidence either way.
- Any `expressions.d`-omitted shape: `ref`-to-AA, scalar `ref`
  address-of, template `ref shared` params.
- Class-hierarchy/pointer-aliasing shapes beyond single inheritance with
  plain fields — `value.md`'s class-identity redesign is in flight.
- `synchronized`/concurrency.

## Process per rung

Write the unittest(s) → run `./bin/bench.sh -b interpreter -b bytecode -b
system-linker` (`SystemLinker` is the oracle, `single-oracle.md`; adding
it to the backend list checks correctness in the same run, not just
interpreter/bytecode agreement) → once it succeeds, drop back to `-b
interpreter -b bytecode` for the timed benchmark run → commit. A
construct that disagrees once combined with the rest of the file,
despite passing in isolation in `lang/*.d`, is a real backend finding:
distill it into a minimal fixture and route it to
`bytecode.md`/`interpreter.md`, don't drop it silently from this queue.
