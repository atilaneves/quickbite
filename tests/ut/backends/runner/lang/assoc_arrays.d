module ut.backends.runner.lang.assoc_arrays;


import ut.backends;
import quickbite.frontend.compiler: FrontendFlags,
    parseSnippetWithCheckActionContext;


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

// An array-valued struct key uses element-wise equality, not slice identity.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyWithArrayFieldComparesStructurally." ~
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
        });
    }
}

// Struct keys with string members compare the string contents, not the
// identity of their backing storage. The next fixture uses distinct backing
// storage to verify that rule.
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

// A struct key with a string and a scalar field compares the string by
// content and the scalar by value. Equal strings with different backing
// storage must still match.
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

// A custom key equality and hash function control key identity. The two
// values below differ only in a field that both functions ignore.
static foreach (backend; Matrix!(
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

// Reading a nested AA as the second equality operand does not affect a later,
// unrelated insert.
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

// A nested write through an existing outer key preserves its inner AA.
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

// A static-array AA value supports construction, whole-value reads, indexed
// writes, and iteration.
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
static foreach (backend; Matrix!()) {
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

// Iteration over a delegate-valued AA calls each stored delegate.
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
// file's other fixtures exercise. dmd's own generic expression walkers know
// to follow `.lowering` instead of the original operands once semantic sets
// it for some expression kinds (`CatExp`/`CatAssignExp`/`EqualExp`), but not
// for `AssocArrayLiteralExp`, which always walks `.keys`/`.values` and never
// `.lowering`. A walk that inventories a function's locals purely from that
// pre-lowering shape therefore reserved no storage for the temp the AA
// literal's lowering synthesized -- however deep it lives in the body --
// and evaluating it threw "has no native place". Fixed generally, not as an
// AA-literal special case: the locals inventory now additionally finds
// every reachable `AssocArrayLiteralExp` in an expression tree and follows
// any `.lowering` it carries, recursing through a `DeclarationExp`'s own
// initializer the same way dmd's own generic walkers already do elsewhere
// -- fixing both this fixture and the sibling module-scope fixture below.
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

// The front end keeps declarations from the first fixture. The second fixture
// must compile its AA literal from its own semantic AST and stack storage.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyLiteralAfterTypeInfoFixture." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // This setup only exposes a Bytecode fault.
        static if (backend.stringof == Bytecode.stringof)
            parseSnippetWithCheckActionContext(q{
                class Thing {}

                struct Observation {
                    TypeInfo type;
                }

            });
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
// A pointer-typed slice-assignment target (`p[i .. j] = ...;`-shaped, where
// the left-hand side is a pointer rather than a plain array/slice variable
// or field) has two legitimate right-hand shapes: a whole array/slice value
// copied in element-by-element (`matrix[] = row;`) and a scalar fill value
// broadcast across every element (`p[i .. j] = 0;`). Every other
// slice-assignment target (a plain variable, a field, a cast expression)
// already guarded against treating a scalar fill value as if it were
// indexable, falling back to broadcasting the scalar itself whenever the
// right-hand side was not actually an array. The pointer-typed target's
// evaluator alone lacked that guard, so a scalar fill value -- like the `0`
// zero-fill above -- was always indexed as if it were an array, which fails
// outright for anything that isn't a native aggregate.
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
// expression is never part of any function's body, so the per-function fix
// above doesn't reserve it a frame either -- evaluating it used to reuse
// whichever frame the triggering read's OWN function happened to have,
// sized for THAT function's locals, never this initializer's. Fixed by
// giving a dataseg variable's own initializer expression a dedicated frame
// around just its own evaluation, sized by the same locals-inventory walk
// used above. `Ctfe`, `Bytecode` and `LLVMJit` are omitted:
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
