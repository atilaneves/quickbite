# Backend Test Module Order

This order ranks CTFE-backed backend behavior modules by the amount of D
language surface a new backend must implement before the whole module can pass.
Use it when choosing which existing CTFE tests to promote to a backend.

Scores are approximate and intentionally relative. A lower score means the
module should usually be promoted before a higher-scored module. Within a
module, still promote one named unittest, or one tightly-related family of
unittests, at a time.

| Order | Difficulty | Module |
| ---: | ---: | --- |
| 1 | 3.0 | `tests/ut/backends/lang/eval.d` |
| 2 | 4.0 | `tests/ut/backends/lang/integral_types.d` |
| 3 | 4.5 | `tests/ut/backends/api/runner.d` |
| 4 | 5.0 | `tests/ut/backends/lang/logic.d` |
| 5 | 6.0 | `tests/ut/backends/lang/diagnostics.d` |
| 6 | 6.5 | `tests/ut/backends/lang/math.d` |
| 7 | 7.5 | `tests/ut/backends/api/repl.d` |
| 8 | 8.0 | `tests/ut/backends/lang/arrays.d` |
| 9 | 8.5 | `tests/ut/backends/lang/structs.d` |
| 10 | 9.0 | `tests/ut/backends/lang/control_flow.d` |
| 11 | 9.5 | `tests/ut/backends/lang/expressions.d` |
| 12 | 10.0 | `tests/ut/backends/lang/exceptions.d` |
| 13 | 10.5 | `tests/ut/backends/projects/cerealed.d` |

## Classification Notes

- `eval.d`: Direct `eval`, scalar values, literals, arithmetic, casts, simple
  multi-cell declarations, string literals, and a few `std.math` calls.
- `integral_types.d`: All integral widths and signedness, runtime casts and
  truncation, typed locals, aliases, enum constants, function parameters and
  returns, and signed/unsigned assertion formatting.
- `api/runner.d`: Module-backed unittest execution, attributed unittests, thrown
  unittests, import paths, multiple modules, assertion failure handling,
  summary counts, DMD unittest symbols, and source/file locations.
- `logic.d`: Boolean and non-boolean truthiness, `!`, `&&`, `||`,
  short-circuiting, comparisons inside logical expressions, operand calls, and
  assertion diagnostics.
- `diagnostics.d`: DMD-like assertion messages, explicit and dynamic assert
  messages, simple `if`/`else`, `in` and `ref` parameters, null class
  diagnostics, `typeid`, and uninitialized scalar diagnostics.
- `math.d`: `std.math` imports and intrinsic-like calls such as `pow`, `sqrt`,
  `fabs`, `isNaN`, `isInfinity`, and `signbit`; NaN, infinity, sign-bit, and
  floating assertion diagnostics.
- `api/repl.d`: `evalRepl`, persistent cell state, expression and no-display
  cells, declarations, functions, templates, imports, Phobos-visible calls,
  scalar/string/array/associative-array/enum/range display values, loaded
  unittest execution, location rewriting, and diagnostic cleanup.
- `arrays.d`: Dynamic and static arrays, indexing, writes, `.length`, append,
  concatenation, slices, slice assignment, equality diagnostics, nested arrays,
  associative arrays, `.dup`, `new T[]`, bounds diagnostics, `ref` array
  parameters, pointers, pointer arithmetic, and string copying.
- `structs.d`: Struct layout, default initialization, field access and writes,
  copy semantics, methods, constructors, `this` mutation, template methods,
  `ref` fields, dynamic array fields, returns, `new Struct`, pointer field
  access, `with`, nested structs, static array fields, destructors, and
  postblits.
- `control_flow.d`: `if`, loops, `foreach`, `foreach_reverse`, `break`,
  `continue`, labels, `switch`, `goto case`, `goto default`, direct `goto`,
  `try/finally` interactions with jumps, function pointers, ranges, string
  iteration, and basic struct method behavior.
- `expressions.d`: Broad expression runtime including arithmetic, bitwise ops,
  shifts, comparisons, compound assignment, comma expressions, increment and
  decrement, floating/complex casts, arrays, slices, strings, pointers,
  pointer casts, `new`, classes, inheritance, virtual/interface dispatch,
  `typeid`, delegates, closures, member delegates, and vector splats.
- `exceptions.d`: `new Exception`, throw statements and expressions,
  uncaught-exception reporting, `try`/`catch`, class matching, catch binding,
  exception member access, propagation across calls and branches, unwinding,
  `finally` ordering, return-value capture before `finally`, catch-handler
  `goto`, and exception chaining.
- `projects/cerealed.d`: Integration stress coverage combining arrays,
  structs, methods, `ref` cursors, post-increment indexing, templates,
  `T.sizeof`, constraints, loops, bit operations, casts, enum round trips,
  nested arrays, associative arrays, pointers, `new`, static arrays, input
  range-style properties, overloads, bounds diagnostics, and float bit
  reinterpretation.

## Not Behavior Targets

`tests/ut/backends/package.d` is promotion plumbing, not a behavior target.
`tests/ut/backends/architecture.d` is a global architecture guard and does not
execute the backend matrix.
