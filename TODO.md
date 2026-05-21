* Change all tests to use checkaction=context modulo linker errors.
* Make the dmd backend emit machine code in RAM, using a shared
  library uses the FS, and we don't want that.
* New tree walker from scratch, but the unit tests we get from that
  are more important.
* Delete minicereal, delete cerealed specific tests, extract unit
  tests from the mess.
* Make the benchmarks run with automem.
* Make the benchmarks run faster, so slow.
* Stop doing benchmarks for individual modules when using `--dub`.
  Although we want to be able to run tests for just one module, I
  think measuring a whole dub project makes more sense (and will have
  less noise). The API will need a `runTests(Module[] modules)` or
  something like that.
* Look at the code/test structure and fix it.
* Review the actual IR, not necessarilythe code that lowers to it.
