# Value Representation

## Summary

Expand `quickbite.lang.Value` so it can represent useful D runtime values beyond
the current scalar and array cases. Keep the model recursive and VM-friendly:
`Value` should name the D value categories Quickbite needs, then each category
can be implemented one approved TDD slice at a time.

The first concrete slice is struct values. Other categories are named now so the
shape has room to grow without forcing a redesign.

## Value Categories

Add explicit `Value.Data` arms over time for these D value shapes:

- `Struct`: aggregate value with type identity and ordered named fields.
- `Union`: aggregate value with type identity and a represented active field or
  raw storage model, to be decided when implemented.
- `ClassRef`: reference to a class object, preserving identity and dynamic type.
- `InterfaceRef`: reference to an interface view of an object.
- `Pointer`: pointer-like value, initially identity/address-like unless a
  backend supplies dereferenceable storage.
- `Delegate`: callable reference with context identity.
- `FunctionRef`: function symbol/reference value.
- `AssocArray`: key/value collection represented recursively with `Value` keys
  and values.
- Existing `Array` remains the representation for D arrays.

Do not add imaginary or complex-number support in this plan.

## Struct Slice

Use structs as the first example and implementation slice.

A likely recursive representation is:

```d
private struct Struct {
    string typeName;
    Field[] fields;
}

private struct Field {
    string name;
    Value value;
}
```

For:

```d
struct Point {
    int x;
    int y;
}

Value(Point(1, 2))
```

`Value` stores a `Struct` with type identity for `Point` and fields
`x = Value(1)`, `y = Value(2)`.

Struct equality initially compares type identity, then fields in declaration
order using `Value` equality. Exact custom `opEquals` behavior can be added
later if a test requires matching D equality more closely.

## Implementation Options

Prefer explicit recursive categories because they are inspectable by the VM,
serializable for diagnostics, and map naturally from backend/CTFE values.

A boxed or type-erased fallback remains an implementation option for value
shapes that cannot be represented cleanly as recursive `Value` data. It should
not be the first design for structs, arrays, associative arrays, or other values
where Quickbite benefits from inspecting the representation.

## TDD Plan

Autonomous run in `value-structs`: the user explicitly approved proceeding
without pausing for each test.

1. [done] Add one red struct test in `ut.lang`: two equal `Point` values
   compare equal,
   and a different `Point` compares unequal.
2. [done] Implement the minimal `Struct` arm and `Value(T)` construction for
   structs.
3. Add a second approved struct test proving two distinct struct types with the
   same fields compare unequal.
4. Add approved tests one category at a time for `AssocArray`, `Union`,
   `ClassRef`, `InterfaceRef`, `Pointer`, `Delegate`, and `FunctionRef`.
5. After each green step, run the focused `ut.lang` test. After the edit
   session, run `dub test -- --random`.

## Assumptions

- This plan targets direct `Value(...)` construction first.
- Backend and CTFE result conversion should later map into the same categories.
- `quickbite.executor.Value` is out of scope.
- The plan names the value categories now; detailed representation choices
  beyond structs are decided by later tests.
