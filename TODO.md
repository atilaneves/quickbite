* Increase test coverage.
* Get at least one backend to the CTFE-parity finish line.
* Plan and implement runtime execution for CTFE-parity backends.
* Deal with and cache dub dependencies instead of
  interpreting/compiling everything at once. Even dub doesn't do this,
  it builds the dependencies then links them in at the end.
* LLVMJit