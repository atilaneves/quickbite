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
`ulong`/`long`/`float`/`double` encode-decode round trips, dynamic arrays
(`~=`, slicing, `$`, assignment), `foreach`/`for`/`switch` control flow,
short-circuit `&&`/`||`, bitwise ops, and exceptions (`throw`/`catch`/
`finally`, catch-by-base, multi-catch, rethrow — via a
`decode`/`Minicereal.get` bounds check), classes/interfaces (field
defaults, inheritance, a class field as a `ref` argument, interface
virtual dispatch across two implementations), delegates/closures
(capture-by-reference through a returned delegate, a nested lambda/IIFE
reading an enclosing struct method's `this` field), associative arrays
(`string`/struct/`int` keys, `.keys`/`.values` iteration, a struct-valued
AA's field write and mutating method call), and the remaining control
flow (`do`/`while`, labeled `break`/`continue` across nested loops,
`switch` `goto case`/`goto default`, string-typed switch cases (plus a
ternary in the case-selector helper), `final switch` on an enum, case
ranges and multi-value cases). The original queue is fully landed; see
Deferred below for what's still routed elsewhere.

## Constraint and method

Every addition must be a construct both `Interpreter` and `Bytecode`
already implement and agree on. The safe source is
`tests/ut/backends/runner/lang/*.d` rows under `Matrix!()` with zero
`Omit!(Interpreter, ...)`/`Omit!(Bytecode, ...)`. `expressions.d` is the
outlier (330 rows, 23 Interpreter-only + 25 Bytecode-only omits, mostly
`ref`/pointer edge cases) — consult it only to confirm a specific shape,
never mine it for new features.

## Deferred — no matrix evidence or active backend risk

Nothing left in the original queue (`## Current coverage` above). What
remains is routed backend work, not corpus work: each item below needs a
minimal fixture in `bytecode.md` or `interpreter.md` before its
construct can be re-added here.

- `scope(exit/failure/success)`, `invariant(){}`, `in{}`/`out{}`
  contracts: no test evidence either way.
- Any `expressions.d`-omitted shape: `ref`-to-AA, scalar `ref`
  address-of, template `ref shared` params.
- Class-hierarchy/pointer-aliasing shapes beyond single inheritance with
  plain fields — `value.md`'s class-identity redesign is in flight.
- `synchronized`/concurrency.
- A nested `try { try {...} catch (Exception) {...} } catch (Error e)`
  around an out-of-bounds array index (`RangeError`): confirmed Bytecode
  diverges from `SystemLinker` (Bytecode fails the assertion that the
  `Error` reaches the outer handler; `Interpreter` matches the oracle).
  Route a minimal fixture to `bytecode.md` before re-adding this shape.
- An interface method taking a parameter (`interface Codec { int
  transform(int); }`), called through an interface-typed variable:
  confirmed Interpreter-only failure, "Unsupported interpreter call
  arguments." Only zero-arg interface methods are proven
  (`tests/ut/backends/runner/lang/expressions.d`'s `Speaker.score()`).
  Route a minimal fixture to `interpreter.md` before re-adding a
  parameterized interface method.
- A zero-arg interface method called through an interface-typed variable
  constructed directly inside a `unittest { }` block (rather than inside
  an ordinary function, as every proven matrix fixture does): confirmed
  Interpreter-only wrong result, no diagnostic. Wrapping the
  construction and call in a free function avoids it. Route a minimal
  fixture to `interpreter.md`; until fixed, always call a
  freshly-constructed polymorphic object through a wrapper function in
  this corpus, never directly in a `unittest` body.
- Nested-AA auto-vivification through plain index assignment
  (`int[int][int] a; a[1][2] = 3;`): confirmed Interpreter-only failure,
  "Associative-array lvalue needs a variable" — reproduced with the
  verbatim `arrays.d` `nestedWriteAutoVivifiesBrandNewOuterKey` fixture
  appended to this corpus unchanged, so the divergence is triggered by
  combination with the rest of the file, not the construct itself
  (`arrays.d`'s Interpreter omit is currently recorded only for the
  compound-`+=` sibling shape). Route a minimal fixture to
  `interpreter.md` before re-adding nested-AA writes here.

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
