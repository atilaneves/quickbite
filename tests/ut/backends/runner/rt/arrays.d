module ut.backends.runner.rt.arrays;


import ut.backends;


// Compiled overlapping slice assignment raises druntime's plain
// "Range violation"; the slice-range text is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("dynamicArray.overlappingSliceAssignmentDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1, first + 2];
                size_t targetStart = cast(size_t) seed(1);
                size_t targetStop = cast(size_t) seed(3);
                size_t sourceStart = cast(size_t) seed(0);
                size_t sourceStop = cast(size_t) seed(2);

                values[targetStart .. targetStop] =
                    values[sourceStart .. sourceStop];

                assert(values[1] == first);
            }
        }).shouldThrowWithMessage("Range violation");
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text; the
// "exceeds array length" wording is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("dynamicArray.sliceIndexPastLengthDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                size_t start = cast(size_t) value(1);
                size_t stop = cast(size_t) value(3);
                auto slice = values[start .. stop];
                size_t index = cast(size_t) value(3);

                assert(slice[index] == first);
            }
        }).shouldThrowWithMessage(
            "index [3] is out of bounds for array of length 2",
        );
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text; the
// backtick-range wording is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("dynamicArray.indexPastLengthDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1];
                size_t index = cast(size_t) value(3);

                assert(values[index] == first);
            }
        }).shouldThrowWithMessage(
            "index [3] is out of bounds for array of length 2",
        );
    }
}

// Compiled missing-key reads raise druntime's plain "Range violation"; the
// key/array-name text is CTFE-only.
static foreach (backend; AliasSeq!(SystemLinker)) {
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

// Compiled pointer slicing is unchecked: the allocated-block diagnostic is
// CTFE-only and the fixture just passes (the slice is never dereferenced).
static foreach (backend; AliasSeq!(SystemLinker)) {
    @("pointer.slicePastAllocatedBlockDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];
                int* p = &values[0];
                size_t start = cast(size_t) seed(1);
                size_t stop = cast(size_t) seed(3);

                auto tail = p[start .. stop];

                assert(tail.length == 2);
            }
        });
    }
}
