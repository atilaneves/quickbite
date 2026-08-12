module ut.backends.runner.lang.assoc_arrays;


import ut.backends;
import quickbite.frontend.compiler: FrontendFlags;


/++
    Associative arrays.
+/
static foreach (backend; Matrix!()) {
    @("assocArray.literalKeepsRuntimeKeysAndValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] values = [first: first + 30, second: second + 30];

                assert(values.length == 2);
                assert(values[first] == 40);
                assert(values[second] == 41);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.literalKeepsLastDuplicateRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int duplicate = key(10);
                int other = key(11);
                int[int] values = [duplicate: 10, duplicate: 20, other: 30];

                assert(values.length == 2);
                assert(values[duplicate] == 20);
                assert(values[other] == 30);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.keysAndValuesUseRuntimeLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(5);
                int second = value(first + 2);
                int third = value(second + 2);
                int[int] values = [
                    first: first + 18,
                    second: second + 20,
                    third: third + 22,
                ];
                int keySum;
                int valueSum;

                foreach (key; values.keys) {
                    keySum += key;
                }

                foreach (entry; values.values) {
                    valueSum += entry;
                }

                assert(keySum == 21);
                assert(valueSum == 81);
            }
        });
    }
}

// Returning the associative array across a function boundary keeps its null
// state as a runtime value; `.keys` preserves that state as a null key slice.
static foreach (backend; Matrix!()) {
    @("assocArray.nullKeysReturnsEmptyArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[int] emptyValues() {
                int[int] values;
                return values;
            }

            unittest {
                auto values = emptyValues;
                const keys = values.keys;

                assert(keys.length == 0);
                assert(keys.ptr is null);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.inFindsRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int missing = key(second + 1);
                int[int] values = [
                    first: first + 30,
                    second: second + 30,
                ];

                int* found = first in values;
                int* absent = missing in values;

                assert(found !is null);
                assert(*found == 40);
                assert(absent is null);
            }
        });
    }
}

// Membership in a default-initialized associative array observes an empty
// mapping, including when the null handle crosses a function boundary.
static foreach (backend; Matrix!()) {
    @("assocArray.inMissingFromNullArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[int] emptyValues() {
                int[int] values;
                return values;
            }

            unittest {
                int key = 10;
                auto values = emptyValues;

                assert((key in values) is null);
            }
        });
    }
}

// A non-capturing lambda has a plain function-pointer type.  Storing it in an
// associative-array entry must preserve that callable value when the entry is
// read back; unlike a delegate, it has no context word.
static foreach (backend; Matrix!()) {
    @("assocArray.functionPointerValuePreservesCallable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int function(int)[string] callbacks;
                callbacks["increment"] = value => value + 1;

                assert(callbacks["increment"](41) == 42);

                callbacks["increment"] = null;
                assert(callbacks["increment"] is null);
            }
        });
    }
}

// A key wider than 4 bytes (`long`) must compare its full width, not just
// its low 32 bits.
static foreach (backend; Matrix!()) {
    @("assocArray.longKeyLookupUsesFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long key(long value) {
                return value;
            }

            unittest {
                // Both keys have low 32 bits == 0 (only bits 40/41 set), so a
                // 4-byte-truncated comparison would wrongly collapse them
                // into a single entry.
                long lo = key(1L << 40);
                long hi = key(1L << 41);
                int[long] table;
                table[lo] = 7;
                table[hi] = 9;

                assert((lo in table) !is null);
                assert((hi in table) !is null);
                assert(table[lo] == 7);
                assert(table[hi] == 9);
                assert(table.length == 2);
            }
        });
    }
}

// A `double` key's bytes are its IEEE-754 bit pattern, not a 4-byte `int`
// truncation of them.
static foreach (backend; Matrix!()) {
    @("assocArray.doubleKeyLookupUsesFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double key(double value) {
                return value;
            }

            unittest {
                // 1.0 and 2.0 have IEEE-754 bit patterns 0x3ff0000000000000
                // and 0x4000000000000000: both have low 32 bits == 0, so a
                // 4-byte-truncated comparison would wrongly collapse them
                // into a single entry, even though the high 32 bits (and so
                // the full 64-bit patterns) differ.
                double lo = key(1.0);
                double hi = key(2.0);
                int[double] table;
                table[lo] = 9;
                table[hi] = 11;

                assert((lo in table) !is null);
                assert((hi in table) !is null);
                assert(table[lo] == 9);
                assert(table[hi] == 11);
                assert(table.length == 2);
            }
        });
    }
}

// A `string` key compares the content its slice descriptor points at, not
// the descriptor's own bytes: two separately-materialised but content-equal
// strings are the same key.
static foreach (backend; Matrix!()) {
    @("assocArray.stringKeyComparesByContentNotIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[string] table;
                table["a"] = 42;

                assert(("a" in table) !is null);
                assert(table["a"] == 42);
                assert(table.length == 1);
            }
        });
    }
}

// `object.classinfo.name` is an lvalue (a field of the class's `TypeInfo`),
// so an `auto ref` key parameter binds it by reference and the address must
// keep the name's characters reachable across the whole lookup.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dereference of invalid pointer `Registrant()`"),
)) {
    @("assocArray.classinfoNameKeyReachesStoredValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Registrant {
            }

            unittest {
                int[string] table;
                auto object = new Registrant;
                table[object.classinfo.name] = 42;

                assert((object.classinfo.name in table) !is null);
                assert(table[object.classinfo.name] == 42);
                assert(table.length == 1);
            }
        });
    }
}

// `foreach (k, v; aa)` must read each key back at its own real width, not a
// hardcoded 4-byte `int` truncation of it.
static foreach (backend; Matrix!()) {
    @("assocArray.foreachLongKeyReadsFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long key(long value) {
                return value;
            }

            unittest {
                int[long] table;
                table[key(1L << 40)] = 7;
                table[key(1L << 41)] = 9;

                int count;
                foreach (k, v; table) {
                    assert(table[k] == v);
                    count += v;
                }
                assert(count == 16);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.foreachDoubleKeyReadsFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double key(double value) {
                return value;
            }

            unittest {
                int[double] table;
                table[key(3.14159)] = 9;
                table[key(2.71828)] = 11;

                int count;
                foreach (k, v; table) {
                    assert(table[k] == v);
                    count += v;
                }
                assert(count == 20);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.foreachStringKeyReadsFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[string] table;
                table["a"] = 42;
                table["bb"] = 5;

                int count;
                int lengthSum;
                foreach (k, v; table) {
                    assert(table[k] == v);
                    count += v;
                    lengthSum += cast(int) k.length;
                }
                assert(count == 47);
                assert(lengthSum == 3);
            }
        });
    }
}

// A struct key with no string/dynamic-array member (`Point`, two `int`
// fields) is compared and stored as its own raw bytes, the same treatment
// `assocArrayValueWidth` already gives a struct-typed AA *value*. Covers
// construction from a literal (`counts[Point(1, 2)] = v`, the synthesized
// `__aakeyN` temporary DMD's index lowering hoists a non-trivial key
// expression into) and from a plain struct local (`counts[p] = v`), lookup
// through both `[]` and `in`, and `foreach (k, v; counts)` reading the key
// back at its own struct width.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyRawBytesConstructLookupAndIterate." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }

            unittest {
                int[Point] counts;
                counts[Point(1, 2)] = 10;

                Point p = Point(3, 4);
                counts[p] = 20;

                assert((Point(1, 2) in counts) !is null);
                assert(counts[Point(1, 2)] == 10);
                assert(counts[p] == 20);
                assert(counts.length == 2);

                int sum;
                foreach (k, v; counts)
                    sum += k.x + k.y + v;
                assert(sum == 1 + 2 + 10 + 3 + 4 + 20);
            }
        });
    }
}

// Finding 3 (Fable pre-PR review): `structKeyFieldLayoutOrNull` only routes
// a struct AA key through field-wise structural comparison when it finds a
// TOP-LEVEL plain-`string` field; a struct with an array-typed field but NO
// top-level `string` field (a lone `int[]` field here -- neither
// `assocArrayKeyIsArray`'s single-field carve-out, which only recognises a
// lone plain-`string` field, nor `structKeyFieldLayoutOrNull`, which returns
// `null` outright for fewer than two fields) used to fall all the way
// through to `assocArrayKeyNonArrayWidth`'s whole-block RAW-byte comparison
// with no field validation at all -- silently comparing two content-equal
// `xs` arrays built from different backing allocations as UNEQUAL (a missed
// lookup, not a thrown diagnostic), contradicting this very file's own
// `structKeyRawBytesConstructLookupAndIterate` comment two fixtures up
// ("Struct-typed key storage itself ... is supported") and this backend's
// own documented refusal for an array-bearing AA key
// (`assocArrayKeyIsArray`'s "Unsupported associative array key type"
// diagnostic, already exercised for a `wstring`/`dstring` key). Now
// declined the same way instead: `assocArrayKeyNonArrayWidth`'s Tstruct
// branch recursively checks every field (through nested structs too) for an
// array type before accepting the raw-byte path.
static foreach (backend; AliasSeq!(Bytecode)) {
    @("assocArray.structKeyWithArrayFieldAndNoStringFieldDeclines." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct K { int[] xs; }

            unittest {
                int[K] counts;
                counts[K([1, 2])] = 1;
                assert(K([1, 2]) in counts);
            }
        }).shouldThrowWithMessage(
            "Unsupported associative array key type in bytecode core: K",
        );
    }
}

// Struct AA keys compare dynamic-array members by their elements, not by the
// identity of their slice backing storage. Struct-typed key storage itself
// (`assocArrayKeyMeta`/`assocArrayKeyOffset`, raw-byte comparison, no string
// member) is supported (`structKeyRawBytesConstructLookupAndIterate` above).
// A struct key that is itself nothing but a single plain-`string` field has
// the exact same {length, ptr} byte layout as a bare `string` -- no
// interleaved scalar fields to keep raw -- so `assocArrayKeyIsArray`
// (compiler.d) now recognises that shape and routes it through the same
// content, not descriptor-byte, comparison a bare `string` key already gets
// (`keysEqual`, machine.d, unchanged). This fixture's own `ab()` call
// happens to return the same backing literal both times, so it would not by
// itself catch a raw-byte regression; the sibling
// `structKeyWithStringMemberComparesByContentNotPointer` fixture below
// constructs the two keys from genuinely different backing storage and is
// the real regression guard.
//
// Getting here also fixed an unrelated compiler bug along the way:
// `compilePointerDeclaration` used to register a pointer local's frame slot
// only *after* compiling its initializer, but DMD's `in` lowering for a
// non-constant-foldable key (`Name(ab())`, needing a hidden key temp to
// preserve evaluation order) nests a self-referential assignment to that
// same local inside its own initializer's `CommaExp` -- `(__aakeyN =
// Name(ab()), variable = _d_aaInX(...))` -- so the generic assignment
// compiler used to reach a plain `variable = ...` while the local's own
// declaration was still being compiled, with no slot yet registered for it,
// refusing with "Unsupported assignment in bytecode core". Registering the
// slot before compiling the initializer (mirroring the plain-scalar
// declaration path, which already did this) fixes that ordering bug
// generally, independent of the string-member comparison fix above.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyWithStringMemberComparesStructurally." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Name {
                string text;
            }

            string ab() {
                return "ab";
            }

            unittest {
                int[Name] ages;
                ages[Name(ab())] = 1;
                assert((Name(ab()) in ages) !is null);
            }
        });
    }
}

// The real regression guard for the fix above: `a()` and `b()` both return
// content-equal `"Alice"` strings built from genuinely different backing
// storage (concatenation vs. an appended-then-`idup`'d buffer), so a
// raw-byte compare of the whole `Name` block (which would compare the
// differing backing pointers) would wrongly miss the lookup.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyWithStringMemberComparesByContentNotPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Name {
                string text;
            }

            string a() {
                return "Al" ~ "ice";
            }

            string b() {
                char[] buf;
                buf ~= "Alice";
                return buf.idup;
            }

            unittest {
                int[Name] ages;
                ages[Name(a())] = 1;
                assert((Name(b()) in ages) !is null);
            }
        });
    }
}

// The same single-string-field struct key, covering construction from a
// local (not just a literal), `[]` lookup, a negative `in` miss, `foreach`
// reading the key back at its real (content-comparable) width, and
// `.remove`.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyWithStringMemberSupportsForeachAndRemove." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Name {
                string text;
            }

            string a() {
                return "Al" ~ "ice";
            }

            string b() {
                char[] buf;
                buf ~= "Alice";
                return buf.idup;
            }

            unittest {
                int[Name] ages;
                ages[Name(a())] = 30;

                Name key = Name(b());
                ages[key] = 31;
                assert(ages.length == 1);
                assert(ages[Name("Alice")] == 31);
                assert((Name("Bob") in ages) is null);

                int sum;
                foreach (k, v; ages) {
                    sum += v;
                    assert(k.text == "Alice");
                }
                assert(sum == 31);

                assert(ages.remove(Name("Alice")));
                assert(ages.length == 0);
            }
        });
    }
}

// A struct key mixing a content-compared `string` field with a raw-compared
// scalar field in the same key (`struct Name { string first; int age; }`):
// neither `assocArrayKeyIsArray`'s single-string-field carve-out (the
// sibling fixtures above) nor the default whole-block raw comparison (the
// `Point`-only fixture further above) is sound for this shape, since the
// key is neither all-content nor all-raw. `assocArrayKeyMeta` (compiler.d)
// now recognises this mix and routes it through a `Program`-level
// `assocArrayKeyLayouts` entry instead (`assocArrayKeyIsStructLayoutFlag`),
// giving `keysEqual` (machine.d) a field-by-field comparison mirroring
// `compileStructIdentity`'s pattern for `==`: `first` compares by content
// (`a()`/`b()` are content-equal `"Alice"`s built from genuinely different
// backing storage, so a raw-byte compare of the whole block would wrongly
// miss the lookup), `age` compares by its own raw bytes (so a same-name,
// different-age key is correctly a distinct entry).
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyWithMixedFieldsComparesStructurally." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Name {
                string first;
                int age;
            }

            string a() {
                return "Al" ~ "ice";
            }

            string b() {
                char[] buf;
                buf ~= "Alice";
                return buf.idup;
            }

            unittest {
                int[Name] ages;
                ages[Name(a(), 30)] = 1;
                assert((Name(b(), 30) in ages) !is null);
                assert(ages[Name(b(), 30)] == 1);
                assert((Name(b(), 31) in ages) is null);
            }
        });
    }
}

// The same mixed-field key shape, covering construction from a local (not
// just a literal), multiple entries, `foreach` reading both fields back at
// their own real widths, and `.remove`.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyWithMixedFieldsSupportsForeachAndRemove." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Name {
                string first;
                int age;
            }

            unittest {
                int[Name] ages;
                ages[Name("Alice", 30)] = 1;

                Name key = Name("Bob", 25);
                ages[key] = 2;
                assert(ages.length == 2);

                int sum;
                foreach (k, v; ages) {
                    assert(k.first == "Alice" || k.first == "Bob");
                    sum += k.age + v;
                }
                assert(sum == 30 + 1 + 25 + 2);

                assert(ages.remove(Name("Alice", 30)));
                assert(ages.length == 1);
                assert((Name("Alice", 30) in ages) is null);
                assert((Name("Bob", 25) in ages) !is null);
            }
        });
    }
}

// A struct key with *only* `string` fields and no raw field at all (`struct
// FullName { string first; string last; }`) -- the gap the mixed-field fix
// above deliberately left open (its gate required at least one non-array
// field alongside the string field). The underlying per-field machinery
// (`AssocArrayKeyField`/`AssocArrayKeyLayout`, `keysEqual`, machine.d)
// already compared each field by its own rule generically; the gate in
// `structKeyFieldLayoutOrNull` (compiler.d, formerly
// `structKeyMixedFieldsOrNull`) just needed relaxing from "at least one
// string field and at least one non-array field" to "at least one string
// field", since an all-string-field struct still needs the same field-wise
// walk a mixed-field one does (a raw compare would wrongly compare each
// field's backing pointer instead of its content). `first` and `last` are
// each built from genuinely different backing storage (concatenation vs. an
// appended-then-`idup`'d buffer) so a raw-byte compare of either field would
// wrongly miss the lookup.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyWithAllStringFieldsComparesStructurally." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct FullName {
                string first;
                string last;
            }

            string firstA() {
                return "A" ~ "da";
            }

            string firstB() {
                char[] buf;
                buf ~= "Ada";
                return buf.idup;
            }

            string lastA() {
                return "Love" ~ "lace";
            }

            string lastB() {
                char[] buf;
                buf ~= "Lovelace";
                return buf.idup;
            }

            unittest {
                int[FullName] counts;
                counts[FullName(firstA(), lastA())] = 1;
                assert((FullName(firstB(), lastB()) in counts) !is null);
                assert(counts[FullName(firstB(), lastB())] == 1);
                assert((FullName(firstB(), "Someone Else") in counts) is null);
            }
        });
    }
}

// The same all-string-fields key shape, covering construction from a local
// (not just a literal), multiple entries, `foreach` reading both fields back
// at their own real (content-comparable) width, and `.remove`.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyWithAllStringFieldsSupportsForeachAndRemove." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct FullName {
                string first;
                string last;
            }

            unittest {
                int[FullName] counts;
                counts[FullName("Ada", "Lovelace")] = 1;

                FullName key = FullName("Grace", "Hopper");
                counts[key] = 2;
                assert(counts.length == 2);
                assert(counts[FullName("Grace", "Hopper")] == 2);
                assert((FullName("Ada", "Hopper") in counts) is null);

                int sum;
                foreach (k, v; counts) {
                    assert(
                        (k.first == "Ada" && k.last == "Lovelace") ||
                        (k.first == "Grace" && k.last == "Hopper")
                    );
                    sum += v;
                }
                assert(sum == 3);

                assert(counts.remove(FullName("Ada", "Lovelace")));
                assert(counts.length == 1);
                assert((FullName("Ada", "Lovelace") in counts) is null);
                assert((FullName("Grace", "Hopper") in counts) !is null);
            }
        });
    }
}

// A struct key with custom `opEquals`/`toHash` that only compare/hash the
// first field: druntime's AA hooks call the key type's own
// `opEquals`/`toHash` (via `TypeInfo_Struct.xopEquals`/`xtoHash`) rather
// than comparing raw bytes, so two keys differing only in the field the
// custom hash and equality ignore must still collide into the same entry.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "0 is `null` -- the bytecode VM's own map still does structural " ~
        "key comparison and never dispatches a key's custom " ~
        "opEquals/toHash; migrating it onto druntime's AA hooks like " ~
        "Interpreter is tracked in issue #478"),
    Omit!(Ctfe, Because.refusal,
        "0x0 is `null` -- dmd's own CTFE AA evaluator compares struct " ~
        "keys structurally too and never dispatches a custom " ~
        "opEquals/toHash, so the two keys land in different slots; " ~
        "upstream dmd CTFE behaviour, not a quickbite bug"),
)) {
    @("assocArray.customOpEqualsToHashKeyIgnoresUnhashedField." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Key {
                int id;
                int other;

                bool opEquals(const Key rhs) const {
                    return id == rhs.id;
                }

                size_t toHash() const nothrow @safe {
                    return id;
                }
            }

            unittest {
                int[Key] counts;
                counts[Key(1, 100)] = 42;

                assert((Key(1, 999) in counts) !is null);
                assert(counts[Key(1, 999)] == 42);
                assert(counts.length == 1);
            }
        });
    }
}

// `int[int][int]` auto-vivification one level deep: `a[1][2] = 3` on a
// completely empty outer map must materialise both the fresh outer entry
// and the inner map it points at in the same statement.
static foreach (backend; Matrix!()) {
    @("assocArray.nestedAutoVivificationCreatesInnerMapOnFirstWrite." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int][int] a;
                a[1][2] = 3;
                assert(a[1][2] == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.nestedLookupDereferencesAssociativeArrayPointee." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int][int] a = [1: [2: 3]];

                assert(a[1][2] == 3);
            }
        });
    }
}

// `a[1] == b` (nested AA read as the FIRST operand of a plain, non-assert
// `==`): control case for the corruption below. A later, unrelated AA
// write must not see any effect from this comparison's operand codegen.
static foreach (backend; Matrix!()) {
    @("assocArray.nestedReadAsFirstEqualityOperandLeavesLaterWritesUnaffected."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int][int] a;
                a[1][10] = 100;
                a[1][20] = 103;

                int[int] b;
                b[99] = 1;

                const bool same = a[1] == b;

                int[int] m;
                m[5] = 6;

                assert(!same);
                assert(a[1].length == 2);
                assert(a[1][10] == 100);
                assert(a[1][20] == 103);
                assert(m.length == 1);
                assert(m[5] == 6);
            }
        });
    }
}

// `b == a[1]` (nested AA read as the SECOND operand of a plain, non-assert
// `==`): used to leave a stale write-back pointer set after the
// comparison's operand codegen (only argument 0 of an AA hook call ever
// consumed it). The NEXT plain, unrelated AA insert (`m[5] = 6` below)
// then wrote its own freshly-autovivified handle through that stale
// pointer, silently aliasing `a[1]`'s storage onto `m` -- corrupting a
// variable the comparison never touched.
static foreach (backend; Matrix!()) {
    @("assocArray.nestedReadAsSecondEqualityOperandLeavesLaterWritesUnaffected."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int][int] a;
                a[1][10] = 100;
                a[1][20] = 103;

                int[int] b;
                b[99] = 1;

                const bool same = b == a[1];

                int[int] m;
                m[5] = 6;

                assert(!same);
                assert(a[1].length == 2);
                assert(a[1][10] == 100);
                assert(a[1][20] == 103);
                assert(m.length == 1);
                assert(m[5] == 6);
            }
        });
    }
}

// `a[1][5] = 9` on an already-present outer key: reaching the inner map for
// the nested write reads `a[1]`'s existing value through the same
// find-or-default-insert hook (`_d_aaGetY`) real D uses for the outer level
// too. Bytecode's own hook (`Op.aaInsert`) used to unconditionally overwrite
// the target slot's bytes with a fresh placeholder before the caller ever
// wrote the real value through it -- correct for a direct `m[k] = v`, but
// wrong here, where the outer slot's bytes are only ever *read* (to reach
// the inner map) rather than assigned to, so the placeholder silently
// replaced the real, already-populated inner map with an empty one.
static foreach (backend; Matrix!()) {
    @("assocArray.nestedWriteIntoExistingOuterKeyPreservesOtherInnerEntries."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int][int] a = [1: [2: 3]];
                a[1][5] = 9;

                assert(a.length == 1);
                assert(a[1].length == 2);
                assert(a[1][2] == 3);
                assert(a[1][5] == 9);

                a[1][2] = 30;
                assert(a[1].length == 2);
                assert(a[1][2] == 30);
                assert(a[1][5] == 9);
            }
        });
    }
}

// `a[1][2] = 3` on a brand-new OUTER key (`a[1]` does not yet exist): the
// outer level auto-vivifies a fresh, still-empty inner map, and the write
// into that inner map must be visible back through the outer map's own
// storage, not just a local copy of the freshly-created handle.
static foreach (backend; Matrix!()) {
    @("assocArray.nestedWriteAutoVivifiesBrandNewOuterKey." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int][int] a;
                a[1][2] = 3;

                assert(a.length == 1);
                assert((1 in a) !is null);
                assert(a[1].length == 1);
                assert(a[1][2] == 3);

                a[1][5] = 9;
                a[7][8] = 20;

                assert(a.length == 2);
                assert(a[1].length == 2);
                assert(a[1][2] == 3);
                assert(a[1][5] == 9);
                assert(a[7].length == 1);
                assert(a[7][8] == 20);
            }
        });
    }
}

// `a[k] += rhs`: DMD hoists `_d_aaGetY`'s slot pointer into a hidden
// compiler-generated pointer temp once and represents the compound
// assignment as an index off that same temp, so the read and write sides
// share one lookup and a missing key auto-vivifies with its default value
// first (`_d_aaGetY` always inserts).
static foreach (backend; Matrix!()) {
    @("assocArray.compoundAddAssignAutoVivifiesMissingKeyAndAddsIntoExisting."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[string] a;
                a["x"] = 1;
                a["x"] += 10;
                assert(a["x"] == 11);

                a["y"] += 5;
                assert(a["y"] == 5);
            }
        });
    }
}

// `a[k1][k2] += rhs` on an existing nested entry: the same hidden-pointer
// compound-assignment lowering as the flat case above, one level down.
static foreach (backend; Matrix!()) {
    @("assocArray.nestedCompoundAddAssignAddsIntoExistingInnerEntry." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[string][string] a;
                a["a"]["b"] = 1;
                a["a"]["c"] = 2;
                a["a"]["b"] += 10;

                assert(a["a"]["b"] == 11);
                assert(a["a"]["c"] == 2);
            }
        });
    }
}

// An associative array whose value type is itself a dynamic array
// (`int[][int]`): each entry holds an array reference, not an inline scalar,
// so inserting a value, reading its length and its elements back, mutating an
// element in place, and copying the whole value out all have to agree about
// the same elements. `Interpreter` does not round-trip such an entry; the
// mechanism is unconfirmed, so it stays off the matrix.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "AA entry whose value type is a dynamic array does not round-trip"),
)) {
    @("assocArray.dynamicArrayValueInsertsReadsAndMutates." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][int] a;
                a[1] = [10, 20, 30];

                assert(a.length == 1);
                assert(a[1].length == 3);
                assert(a[1][1] == 20);

                a[1][2] = 99;
                assert(a[1][2] == 99);

                int[] fetched = a[1];
                assert(fetched == [10, 20, 99]);
            }
        });
    }
}

// `int[][int].values` packs each entry at its own 16-byte slice-descriptor
// stride (`assocArrayValueWidth`), not a hardcoded 4-byte `int`. Reading
// values back at the wrong (scalar) stride would misalign every entry after
// the first -- summing every element of every entry is order-independent
// (AA iteration order is unspecified) but still catches a misaligned read.
static foreach (backend; Matrix!()) {
    @("assocArray.valuesOnArrayValuedAAReadsFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[] pair(int a, int b) {
                return [a, b];
            }

            unittest {
                int[][int] a;
                a[1] = pair(10, 20);
                a[2] = pair(30, 40);

                int[][] vs = a.values;
                assert(vs.length == 2);
                assert(vs[0].length == 2);
                assert(vs[1].length == 2);

                int total;
                foreach (entry; vs)
                    foreach (x; entry)
                        total += x;
                assert(total == 100);
            }
        });
    }
}

// A struct-typed value (`Point[int]`): field write through `p[0].x = ...`
// composes through DMD's own `_d_aaGetRvalueX`-lowered pointer-dereference
// receiver (`expressionsem.d`'s `revertModifiableAAIndexReads`), a plain
// pointer-index assignment target `writeIndexLocation` handles like any
// other native pointer.
static foreach (backend; Matrix!()) {
    @("assocArray.structValueFieldReadWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }
            unittest {
                Point[int] a;
                a[1] = Point(10, 20);
                assert(a[1].x == 10);
                a[1].x = 5;
                assert(a[1].x == 5);
                assert(a[1].y == 20);
            }
        });
    }
}

// A struct-typed AA value whose byte width (12, three ints) is not a power
// of two, unlike the two-int `Point` above: the address computation this
// composes through must align by the struct's own alignment, not by its raw
// byte width used as an alignment mask.
static foreach (backend; Matrix!()) {
    @("assocArray.nonPowerOfTwoWidthStructValueFieldReadWrite." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Triple { int a; int b; int c; }
            unittest {
                Triple[int] entries;
                entries[1] = Triple(10, 20, 30);
                entries[2] = Triple(40, 50, 60);

                entries[1].b = 99;

                assert(entries[1].a == 10);
                assert(entries[1].b == 99);
                assert(entries[1].c == 30);
                assert(entries[2].a == 40);
                assert(entries[2].b == 50);
                assert(entries[2].c == 60);
            }
        });
    }
}

// Calling a mutating method through an AA-value struct receiver
// (`a[1].bump()`) is the same `_d_aaGetRvalueX`-lowered pointer-dereference
// receiver shape as the plain field write above, but reached through
// `runMemberFunction`'s `addressOfExpression`/`arrayPointer` path instead of
// an assignment target.
static foreach (backend; Matrix!()) {
    @("assocArray.structValueMethodCallMutatesEntry." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
                int bump() { return x += 1; }
            }
            unittest {
                Point[int] a;
                a[1] = Point(10, 20);
                a[1].bump();
                assert(a[1].x == 11);
                assert(a[1].y == 20);
            }
        });
    }
}

// A struct value with a user-defined `opAssign` (`Setting`, as opposed to
// the plain `Point` above): DMD represents `a[1] = Setting(2)` as a
// ConstructExp (blitting the fresh rvalue directly into the newly obtained
// AA slot -- `opAssign` is never invoked for this initial-insert shape) with
// an `IndexExp` `e1`, a lvalue shape `compileExpression`'s ConstructExp
// dispatch previously only recognised over a `DotVarExp`/`VarExp`/
// `SliceExp`/`ThisExp` lvalue, not an AA-element `IndexExp`.
static foreach (backend; Matrix!()) {
    @("assocArray.structValueWithOpAssignInsertsFromLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Setting {
                int value;

                void opAssign(Setting rhs) {
                    value = rhs.value;
                }
            }
            unittest {
                Setting[int] a;
                a[1] = Setting(2);
                assert(a[1].value == 2);
            }
        });
    }
}

// Overwriting an existing AA entry from another struct value (as opposed to
// the fresh-insert case above) lowers through the `_d_aaGetY` slot-pointer
// write shape (`p[i] = rhs`, `tryPointerElementAssign`/`storeThroughPointer`)
// regardless of whether the value type defines `opAssign` -- an AA element
// overwrite blits the value's raw bytes rather than dispatching through
// `opAssign`. `storeThroughPointer` previously only materialised the rhs
// through `compileExpression`, which handles a struct rvalue (a literal or
// constructor call) but not a struct lvalue (an existing local, reached the
// same way `structOperandOffset` resolves every other struct-value read).
static foreach (backend; Matrix!()) {
    @("assocArray.structValueOverwriteFromVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }
            unittest {
                Point pt;
                pt.x = 3;
                pt.y = 4;

                Point[int] a;
                a[1] = Point(10, 20);
                a[1] = pt;
                assert(a[1].x == 3);
                assert(a[1].y == 4);
            }
        });
    }
}

// A static-array-typed value (`int[3][string]`): construction from a
// literal, whole-value indexed read, an indexed single-element write
// through the AA-value-read pointer (`rows["a"][1] = 99`), and `foreach`
// all in one fixture. Two bugs fixed to get here, both in the same
// AA-value-pointer machinery `structValueFieldReadWrite` above already
// established for a struct-typed value: `staticArrayBaseOffset` (and its
// `indexesStaticArray` gate) had no branch recognising a raw pointer to a
// static array -- DMD's associative-array rvalue-read lowering
// (`_d_aaGetRvalueX`) yields exactly that shape -- so both the read and
// the indexed write threw "Unsupported static array access"/"Unsupported
// assignment in bytecode core" (Bytecode alone; `SystemLinker` always ran
// this fine). Separately, `assocArrayValueWidth` (used by every AA opcode,
// including `Op.aaValues`' per-entry stride) sized a static-array value as
// a boxed 16-byte slice descriptor via `arrayElementIsArray`'s dynamic-
// array-*row* treatment, not its own 12-byte raw block (confirmed against
// DMD's own lowering, whose `Impl.valsz` for an `int[3]` value is 12) --
// harmless for a single entry (the real bytes still start at the block's
// front) but desyncing `foreach`'s per-entry read stride from the real one
// as soon as `compileAssocArrayApply2` needed its own value width (it
// previously had no `Tsarray` case at all, throwing "Unsupported type in
// bytecode core: int[3]" via `scalarType`). The indexed write
// (`runNestedIndexAssignExpression`) composes through the same
// `_d_aaGetRvalueX`-lowered pointer-dereference receiver
// `structValueFieldReadWrite` above documents, one level further from the
// assignment's own target.
static foreach (backend; Matrix!()) {
    @("assocArray.staticArrayValueConstructsReadsWritesAndIterates." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[3][string] rows;
                rows["a"] = [1, 2, 3];
                assert(rows["a"][1] == 2);
                rows["a"][1] = 99;
                assert(rows["a"][1] == 99);
                foreach (k, v; rows)
                    assert(v[1] == 99);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.equalityComparesRuntimeEntries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] left = [
                    first: first + 30,
                    second: second + 30,
                ];
                int[int] same = [
                    second: second + 30,
                    first: first + 30,
                ];
                int[int] different = [
                    first: first + 30,
                    second: second + 31,
                ];

                assert(left == same);
                assert(left != different);
            }
        });
    }
}

// Generated equality recurses through nested aggregate fields. An
// associative array reached through a dynamic-array element therefore still
// compares its runtime entries, including struct-typed values.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal, "Assertion failure (==)"),
)) {
    @("assocArray.structFieldEqualityComparesRuntimeEntries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Leaf {
                int value;
            }

            struct Nested {
                Leaf[int] children;
            }

            struct Wrapper {
                Nested[] values;
            }

            int runtimeValue(int value) {
                return value;
            }

            unittest {
                int key = runtimeValue(7);
                Wrapper left = Wrapper([
                    Nested([key: Leaf(runtimeValue(11))]),
                ]);
                Wrapper same = Wrapper([
                    Nested([key: Leaf(runtimeValue(11))]),
                ]);
                Wrapper different = Wrapper([
                    Nested([key: Leaf(runtimeValue(12))]),
                ]);

                assert(left == same);
                assert(left != different);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.defaultNullEqualsPopulatedThenEmptied." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int runtimeValue(int value) {
                return value;
            }

            unittest {
                int[int] defaultNull;
                int[int] emptied;
                const key = runtimeValue(7);
                emptied[key] = runtimeValue(11);
                assert(emptied.remove(key));

                assert(defaultNull == emptied);
                assert(emptied == defaultNull);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.removeRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int removeKey = key(10);
                int remainingKey = key(removeKey + 1);
                int[int] values = [
                    removeKey: removeKey + 30,
                    remainingKey: remainingKey + 30,
                ];

                assert(values.remove(removeKey) == true);
                assert(values.remove(removeKey) == false);
                assert(values.length == 1);
                assert(values[remainingKey] == 41);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.dupCopiesEntries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int seed) {
                return seed;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] original = [
                    first: first + 30,
                    second: second + 30,
                ];
                int[int] copy = original.dup;

                original[first] = key(99);

                assert(copy.length == original.length);
                assert(copy[first] == 40);
                assert(copy[second] == 41);
                assert(original[first] != copy[first]);
            }
        });
    }
}

// Duplicating an associative array preserves each function pointer's callable
// identity while detaching the copy from later mutations to the original.
static foreach (backend; Matrix!()) {
    @("assocArray.dupCopiesFunctionPointerValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            alias Handler = void function(ref int);

            void increment(ref int value) {
                value = value + 1;
            }

            unittest {
                Handler[string] original;
                original["increment"] = &increment;
                Handler[string] copy = original.dup;
                original.remove("increment");

                int value = 41;
                copy["increment"](value);
                assert(value == 42);
            }
        });
    }
}

// Bytecode ("Unsupported bytecode assignment target.") and IR ("Unsupported
// IR expression `null`") cannot run AA insertion.
static foreach (backend; Matrix!()) {
    @("assocArray.insertionGrowsAndOverwrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] values;

                values[first] = first + 30;
                assert(values.length == 1);

                values[second] = second + 30;
                assert(values.length == 2);

                values[first] = first + 32;
                assert(values.length == 2);

                assert(values[first] == 42);
                assert(values[second] == 41);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.nullAACalleeInsertInvisible." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void insert(int[int] aa) {
                aa[1] = 2;
            }

            unittest {
                int[int] aa;
                insert(aa);
                assert(aa.length == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.nullAAAssignmentInsertDetaches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int] aa;
                int[int] bb = aa;
                bb[1] = 2;
                assert(aa.length == 0);
                assert(bb.length == 1);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("assocArray.readMissingKeyThrowsDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int present = key(10);
                int absent = key(present + 1);
                int[int] values = [present: present + 30];

                auto missing = values[absent];

                assert(missing == 0);
            }
        }).shouldThrowWithMessage(
            "key `absent` not found in associative array `values`",
        );
    }
}

// Compiled missing-key reads raise druntime's plain "Range violation"; the
// key/array-name text is CTFE-only. Interpreter now interprets druntime's
// own `_d_aaGetRvalueX`/`onRangeError` hook bodies rather than a bespoke
// lookup that formatted the key and array name itself, so it raises the
// same plain message SystemLinker's compiled code does.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe)"),
)) {
    @("assocArray.readMissingKeyThrowsDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int present = key(10);
                int absent = key(present + 1);
                int[int] values = [present: present + 30];

                auto missing = values[absent];

                assert(missing == 0);
            }
        }).shouldThrowWithMessage("Range violation");
    }
}

// A delegate-typed AA VALUE for a LOCAL (non-module, non-static) variable,
// assigned from a lambda literal rather than `&freeFunction` -- the shape
// `ai/plans/bytecode.md`'s AssocArray section's item 2 asks for beyond the
// `&fn`-assigned module-scoped regression fixture already pinned as
// `ut.backends.runner.lang.cerealed`'s
// `delegateAssocArrayValueIndexedCallInvokesStoredDelegate`. This already
// worked before this fixture was added -- `delegateOperandOffset`'s
// `delegateInitializer` assign-side handling and its own `p[0]` call-side
// branch (both from the hang fix, commit 587d2a9c) are agnostic to lambda
// vs. `&freeFunction` and to local vs. module storage -- but had no fixture
// of its own. `Omit`s mirror the sibling regression fixture: this only pins
// `Bytecode` plus the `SystemLinker` oracle, not full delegate-AA-value
// support on every backend.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("assocArray.delegateValueLocalLambdaAssignInvokesStoredDelegate." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int delegate()[string] callbacks;
                callbacks["a"] = () => 42;
                auto result = callbacks["a"]();
                assert(result == 42);
            }
        });
    }
}

// Reassigning a LOCAL delegate-typed AA value's entry (still a lambda
// literal each time) must call through to the latest stored delegate, not a
// stale one -- exercising `storeThroughPointer`'s `Tdelegate` write path a
// second time over the same slot rather than only ever writing it once.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("assocArray.delegateValueLocalReassignInvokesLatestDelegate." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int delegate()[string] callbacks;
                callbacks["a"] = () => 1;
                assert(callbacks["a"]() == 1);
                callbacks["a"] = () => 2;
                auto result = callbacks["a"]();
                assert(result == 2);
            }
        });
    }
}

// `foreach (k, v; callbacks)` over a LOCAL delegate-typed AA calls through
// each stored delegate via the loop variable `v`, not just a direct
// `callbacks[key]()` index-call -- a materially different read path
// (`compileAssocArrayApply2`'s per-entry value read) from the one the hang
// fix and the two lambda-assign fixtures above exercise.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("assocArray.delegateValueLocalForeachInvokesEachStoredDelegate." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int delegate()[string] callbacks;
                callbacks["a"] = () => 1;
                callbacks["b"] = () => 2;
                callbacks["c"] = () => 3;

                int total;
                foreach (k, v; callbacks)
                    total += v();

                assert(total == 6);
            }
        });
    }
}

// Distilled from `cerealed`'s `tests/bugs.d` "assoc.array.with.pair"
// unittest (`auto p = Pair("foo", 5); auto map = [p: 105];`), which used to
// crash the Interpreter under `-preview=dip1000` (the flag `dub describe`
// reports for `cerealed`'s own unittest build, inherited transitively from
// a dependency -- `bin/bench.sh -b interpreter --dub cerealed` forwards it
// via `dubCompilerArguments`, `benchmarks/cli.d`). DMD's own
// `tryLowerAALiteral`/`functionArguments` (dmd's `expressionsem.d`) hoists
// a non-empty keys or values array literal passed to the `scope`-inferred
// `_d_assocarrayliteralTX(keys, values)` hook into an
// `__arrayliteral_on_stack*` temporary -- a `DeclarationExp` nested INSIDE
// the AA literal's `.lowering`, not among the pre-lowering keys/values this
// file's other fixtures exercise. `frame_layout.computeFrameLayout` sizes a
// function's activation frame by walking its body for every local DMD's
// own tree walkers observe (`bodyLocals`, `dmd.visitor.foreachvar`), but
// `dmd.visitor.postorder`'s `PostorderExpressionVisitor` -- the driver
// behind that walk -- has a `.lowering`-aware override for
// `CatExp`/`CatAssignExp`/`EqualExp` (each walks `.lowering` INSTEAD of its
// original operands once semantic sets it) but not for
// `AssocArrayLiteralExp`: its own override always walks `.keys`/`.values`,
// never `.lowering`, so the walk over `map`'s own unittest body reserved no
// frame slot for the temp its AA literal's lowering synthesized -- however
// deep it lives in the body -- and evaluating it threw "has no native
// place" (in `<root>`: the top-level `execute` entry point for a directly-
// run unittest never assigns `currentFunction`, only a nested call's own
// child interpreter does). Fixed generally, not as an AA-literal special
// case narrowly scoped to `bodyLocals`: `appendVarsInExpression`
// (`frame_layout.d`) additionally finds every reachable
// `AssocArrayLiteralExp` in an expression tree itself and walks any
// `.lowering` it carries, recursing through a `DeclarationExp`'s own
// initializer the same way `dmd.visitor.foreachvar`'s `VarWalker` already
// does (something `PostorderExpressionVisitor`'s generic structural
// descent never does for `DeclarationExp` at all) -- used by both
// `bodyLocals` (this fixture's own path) and the sibling module-scope
// fixture below. `runBackendSourceFixtureTests`'s new `FrontendFlags`
// overload enables `-preview=dip1000` the same way `dependency_image.d`'s
// sandboxed fixture already does.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyLiteralInsideUnittestBindsStackTemp." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Pair {
                string s;
                int i;
            }

            unittest {
                auto p = Pair("foo", 5);
                auto map = [p: 105];
                assert(map[p] == 105);
            }
        }, [], FrontendFlags(["-preview=dip1000"]));
    }
}

// The actual `cerealed` "assoc.array.with.pair" crash (`AggregateValue.elementAt
// needs a native array.`) traces to a DIFFERENT AA in the same package's test
// suite, not the struct-keyed literal above: `tests/structs.d`'s
// `DummyStruct` has a `double[int] aa` field, and decoding it
// (`Decerealiser.value!DummyStruct`) inserts into that empty field AA one
// key/value pair at a time (`val[k] = v;`, `cerealed/src/cerealed/cereal.d`).
// That insert lowers to druntime's `_d_aaGetY`/`_aaGetX`
// (`core.internal.newaa`), whose `_newEntry` zero-fills a freshly allocated
// entry's value through a raw pointer slice --
// `(cast(ubyte*)&entry.value)[0 .. V.sizeof] = 0;` -- for any value type
// whose `.init` is not the all-zero bit pattern (`double.init` is NaN, so
// `__traits(isZeroInit, double)` is false and this line runs). No `Pair`,
// `dip1000` or even `cerealed` needed to reach it: any AA insert of such a
// value type does, distilled below to a bare `double[int]`.
//
// `runPointerSliceAssignExpression` (`impl.d`) evaluates that pointer-slice
// assignment through a local `elementAt` closure choosing between a "block"
// fill (`copyArrayValue`, for `matrix[] = row;`-shaped array-of-array fills)
// and indexing the right-hand value as an array (`AggregateValue.elementAt`).
// Every sibling slice-assignment path
// (`runVariableSliceAssignExpression`/`runFieldSliceAssignExpression`/
// `runCastedSliceAssignExpression`) additionally guards that second arm with
// `AggregateValue.isArray(value)`, falling back to the scalar `value` itself
// for a fill assignment (`p[i .. j] = 0;`) whose right-hand side was never an
// array to index into -- `runPointerSliceAssignExpression`'s closure alone
// lacked that guard, so it always called `AggregateValue.elementAt` on the
// scalar `0`, which is not a native aggregate at all.
static foreach (backend; Matrix!()) {
    @("assocArray.nonZeroInitValueEntryZeroFillsThroughPointerSlice." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                double[int] aa;
                aa[5] = 3.0;

                assert(aa.length == 1);
                assert((5 in aa) !is null);
                assert(aa[5] == 3.0);
            }
        });
    }
}

// The sibling MODULE-scope shape: a dataseg variable's own initializer
// expression is a bare `Expression`, never part of any `FuncDeclaration`'s
// body, so `bodyLocals`'s fix above (which walks a function's OWN body)
// never reserves it a frame either -- lazily materializing it
// (`materializeDatasegInitializer`) reused whichever frame the triggering
// read's OWN function happened to have, sized for THAT function's locals,
// never this initializer's. Fixed by giving a dataseg variable's own
// initializer expression a dedicated frame around just its own evaluation,
// sized from the same `appendVarsInExpression`-based walk
// (`evaluateDatasegInitializerExpression`/`computeExpressionFrameLayout`,
// impl.d/frame_layout.d). `Ctfe`, `Bytecode` and `LLVMJit` are omitted:
// none of the three is regressed by this fix -- `Ctfe` gives its own
// permanent, unrelated "cannot be read at compile time" refusal for a
// mutable module variable read from a function call (this file's other
// fixtures hit the same wall, e.g. `classinfoNameKeyReachesStoredValue`
// above); `Bytecode` core declines any runtime-evaluated module-scope
// scalar initializer outright, AA or not; `LLVMJit` crashes on this exact
// `-preview=dip1000` AST shape -- a gap nothing here narrows down further,
// left for its own backlog item.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable `table` cannot be read at compile time"),
    Omit!(Bytecode, Because.refusal,
        "Unsupported module scalar initializer in bytecode core: table"),
    Omit!(LLVMJit, Because.unconfirmed, "JIT child died (signal 11)"),
)) {
    @("assocArray.moduleScopeLiteralWithFunctionCallKeyBindsStackTemp." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key() { return 5; }

            int[int] table = [key(): 105, key() + 1: 200];

            unittest {
                assert(table[5] == 105);
                assert(table[6] == 200);
            }
        }, [], FrontendFlags(["-preview=dip1000"]));
    }
}
