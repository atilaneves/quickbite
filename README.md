# quickbite

[![codecov](https://codecov.io/gh/atilaneves/quickbite/branch/master/graph/badge.svg)](https://codecov.io/gh/atilaneves/quickbite)

A bytecode VM for the D programming language.

## Goal

Optimise for the latency of getting unittest results from any given
edit. Compilation is driven by `unittest` blocks, generating only the
bytecode required for the test and its transitive dependencies — no
object files, no linker tax.

## Building and testing

```
dub test -- -s
```

Tests are run serially because parallel execution can cause spurious
failures due to `__gshared` state in the dmd frontend.

## Benchmarks

```
dub run :benchmark
```

## License

Boost Software License 1.0 (BSL-1.0).
