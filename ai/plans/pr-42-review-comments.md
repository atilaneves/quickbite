# PR 42 Review Comments

Use strict TDD. The reviewer supplied probe tests for each item, so workers may
add the named tests without stopping for separate approval. Address each review
comment in a separate worker worktree and integrate the accepted changes here.

- [x] Runtime floating-to-integer casts in the IR backend must convert
  numerically, not through floating bit patterns. Probe:
  `ut.backends.ir.eval.castsFloatingValueNumerically`.
- [x] Floating `-`, `*`, and `/` in the IR backend must use numeric floating
  values instead of integer operations over floating bit patterns. Probe:
  `ut.backends.ir.eval.floatingSubtractionUsesNumericValues`.
- [ ] IR scalar equality must not treat integer values as equal to matching
  floating bit patterns for ordinary D numeric comparison. Probe:
  `ut.backends.ir.eval.integerFloatEqualityIsNumeric`.
- [x] Unary minus on runtime floating IR values must negate the numeric value,
  not the floating bit pattern. Probe:
  `ut.backends.ir.eval.floatingUnaryMinusUsesNumericValue`.
- [x] `std.math.fabs(float)` in the IR math-intrinsic path must preserve the
  float return type. Probe:
  `ut.backends.ir.eval.fabsFloatPreservesReturnType`.
- [ ] Mixed unsigned/floating comparisons must compare the numeric unsigned
  value, including large `ulong` values. Probe:
  `ut.backends.ir.eval.ulongDoubleComparisonUsesNumericUnsignedValue`.
- [ ] `real` comparisons must preserve real precision instead of converting
  both operands through `double`. Probe:
  `ut.backends.ir.eval.realComparisonPreservesRealPrecision`.
- [x] `std.math.pow(float, float)` must not store a `double` `Value` when DMD's
  expression type is `float`. Probe:
  `ut.backends.ir.eval.powFloatDoesNotReturnDoubleValue`.
- [x] `Value.toString` must show enough scalar identity that distinct scalar
  values such as `Value(8.0f)` and `Value(8.0)` do not print identically.
  Probe: `ut.value.value.toStringShowsDistinctScalarIdentity`.
