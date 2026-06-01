# Value Representation

## Summary

Expand `quickbite.lang.Value` until it can losslessly store D runtime values
returned by backends and displayed by the REPL.

This plan is scoped to `quickbite.lang.Value` and backend/REPL result
conversion. Do not change `quickbite.executor.Value` as part of this plan.

Use a hybrid representation:

- explicit recursive categories for values the VM benefits from inspecting;
- a typed raw or identity fallback for values that cannot yet be decomposed
  cleanly.

Keep D type identity internally for lossless storage, but do not change public
equality or display behaviour unless an approved test explicitly requires that
change.

## Value Categories

`Value.Data` should grow one approved TDD slice at a time. The target value
categories are:

- `Void`: no value.
- `Null`: null reference or pointer value when no more precise category is
  needed.
- Scalar values: `bool`, integral types, character types, and floating types.
- `Array`: dynamic array represented recursively as `Value[]`.
- `StaticArray`: fixed-length array represented recursively as `Value[]` plus
  length and element type identity.
- `AssocArray`: key/value collection represented recursively with `Value` keys
  and values.
- `Struct`: aggregate value with rendered type name, internal type identity,
  and ordered fields.
- `Union`: aggregate value with rendered type name, internal type identity,
  and raw storage or active-field information.
- `ClassRef`: reference to a class object, preserving identity and dynamic
  type.
- `InterfaceRef`: reference to an interface view of an object.
- `Pointer`: pointer-like value, preserving pointee type identity and pointer
  identity.
- `Delegate`: callable reference with function and context identity.
- `FunctionRef`: function symbol or function pointer value.
- `Opaque`: typed raw or identity storage for value shapes that must be kept
  losslessly before they have a dedicated recursive representation.
- `TypeName`: display-only type result for REPL `typeof` cells.

The typed fallback should store Quickbite-owned metadata, not DMD frontend
objects. At minimum it needs a rendered type name, a stable internal type
identity, and either raw bytes for value-like data or identity data for
reference-like data.

## Approved Decisions

1. Scope is `quickbite.lang.Value` plus backend/REPL result conversion.
   `quickbite.executor.Value` is out of scope.
2. Storage strategy is hybrid: recursive inspectable arms plus a typed
   raw/identity fallback.
3. Type identity is internal storage metadata. Equality and display remain
   driven by approved behaviour tests.
4. The first new implementation slice is recursive arrays.
5. The first recursive-array test belongs in the backend REPL tests.
6. The first fixture is a string array:
   `string[] xs = ["a", "b"]; xs`.
7. The first assertion checks rendered REPL output exactly:
   `["a", "b"]`.
8. The first implementation boundary is the CTFE adapter only:
   `ArrayLiteralExp` element conversion should recurse through `ctfeValue`.
9. Verification for the slice is the focused REPL test first, then
   `dub test -- --random` after the edit session.

## First TDD Slice: Recursive CTFE Arrays

Current CTFE array conversion in `quickbite.backends.ctfe.dmd_ctfe` only reads
integer elements from `ArrayLiteralExp`. That prevents backend/REPL results from
displaying arrays whose elements are strings, structs, arrays, or other values
already representable by `quickbite.lang.Value`.

Proposed first test, pending explicit approval before editing tests:

```d
@("repl.backend.displaysStringArrayResults." ~ backend.stringof)
unittest {
    import quickbite.repl: runReplLoop;

    const output = runReplLoop(
        newBackend!backend,
        [
            `string[] xs = ["a", "b"];`,
            "xs",
            ":q",
        ],
    );

    output.should == [`["a", "b"]`];
}
```

Minimal implementation after that test is approved and fails:

- change CTFE `arrayValue(ArrayLiteralExp)` to build `Value[]` by calling
  `ctfeValue` for each non-null element;
- return a `quickbite.lang.Value` array from those recursive elements;
- do not change `Value(T[])` unless the approved test proves it is needed.

## Later Slices

After recursive arrays are green, choose the next slice by discussion before
writing any test. Good candidates are:

- static arrays, because they are close to recursive dynamic arrays;
- complex and imaginary scalar values, if the plan should close the scalar
  coverage gap next;
- pointer values, to exercise the typed raw/identity fallback;
- union values, to settle active-field versus raw-storage representation;
- class and interface references, to model identity and dynamic type;
- delegates and function references, to model callable values.

Each slice should add or modify one approved behaviour test first, implement
the dumbest passing code, run the focused test, and then run the randomized
suite after the editing session.

## Guardrails

- Ask before adding or modifying each test.
- Do not reintroduce DMD frontend objects into `quickbite.lang.Value`.
- Do not let type identity changes silently change equality or display.
- Do not use string heuristics in REPL/frontend code to classify D source.
- Do not use failed evaluation as REPL control flow.
- Keep backend-specific DMD conversion inside backend adapters.
- Preserve existing `Value.void_`, `Value.null_`, `Value.typeName`, and
  `Value.structValue` callers unless an approved test requires an API change.
