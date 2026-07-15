module ut.backends.matrix;


import ut.backends;


// `Matrix!()` (no specs) is exactly `LangBackends`: same length, same
// types, same order.
static assert(Matrix!().length == LangBackends.length);
static assert(is(Matrix!()[0] == Ctfe));
static assert(is(Matrix!()[1] == Interpreter));
static assert(is(Matrix!()[2] == Bytecode));
static assert(is(Matrix!()[3] == SystemLinker));
static assert(is(Matrix!()[4] == LLVMJit));


// `Omit!(Ctfe, ...)` drops `Ctfe` and keeps the other four, in order.
private alias WithoutCtfe =
    Matrix!(Omit!(Ctfe, Because.inexpressible, "no byte view of float locals"));
static assert(WithoutCtfe.length == 4);
static assert(is(WithoutCtfe[0] == Interpreter));
static assert(is(WithoutCtfe[1] == Bytecode));
static assert(is(WithoutCtfe[2] == SystemLinker));
static assert(is(WithoutCtfe[3] == LLVMJit));


// `Plus!(IR)` adds the in-development `IR` backend to the five
// `LangBackends`.
private alias WithIR = Matrix!(Plus!(IR));
static assert(WithIR.length == 6);
static assert(is(WithIR[0] == Ctfe));
static assert(is(WithIR[1] == Interpreter));
static assert(is(WithIR[2] == Bytecode));
static assert(is(WithIR[3] == SystemLinker));
static assert(is(WithIR[4] == LLVMJit));
static assert(is(WithIR[5] == IR));


// Negative invariants (each verified by temporarily writing it here,
// confirming the compile error below, then removing it - do not
// leave uncompilable code in the tree):
//
// - `Omit!(SystemLinker, Because.diverges)` fails: "the oracle can
//   never be omitted from a Matrix; use a hand-written `AliasSeq!`
//   characterization pin instead".
// - `Omit!(Ctfe, Because.inexpressible)` (no note) fails: "a non-empty
//   `note` is required for this reason".
// - `Omit!(IR, Because.unconfirmed)` fails: "`IR` is not in
//   `LangBackends` - typo?" (IR is opt-in via `Plus`, never a member of
//   `LangBackends`, so it can never be omitted from one).
// - `Matrix!(Ctfe)` (a bare backend, not wrapped in `Omit!`/`Plus!`)
//   fails: "`Ctfe` is neither `Omit!(...)` nor `Plus!(...)`" - a bare
//   backend would be silently ignored rather than adjust the matrix.
// - `Matrix!(Plus!(Ctfe))` fails: "`Ctfe` is already in `LangBackends`
//   - `Plus!` would duplicate it in the matrix".
