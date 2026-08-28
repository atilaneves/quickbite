---
title: Do as I Say, Not as I Do
subtitle: Lessons in agentic coding new backends
author: Átila Neves
date: DConf 2026
header-includes:
  - \setbeamertemplate{caption}{\tiny\insertcaption}
---


# The idea

::: columns
:::: {.column width=55%}
* I hate waiting.
* 200ms is a long time to wait.
* 2s for unit tests is an eternity.
* Do I *have* to compile code to run it?
* Goal: minimal edit -> test result latency.
::::
:::: {.column width=45%}
![xkcd 303, CC BY-NC 2.5](img/compiling.png){height=70%}
::::
:::

# Lisp did it first

::: columns
:::: {.column width=50%}
* Lisp: REPL and interpreter.
* Code can be compiled to bytecode for faster execution.
* Emacs is a Lisp VM pre-built with editing functions.
* Bytecode for D?
::::
:::: {.column width=50%}
![Symbolics keyboard, RCS/RI, CC BY-SA 3.0](img/lisp-machine.jpg){width=100%}
::::
:::

# Implementing a D backend

* A visitor over dmd's post-semantic AST: 26 statement kinds, 71 expression kinds.

```d
void compileStatement(Statement statement) {
    if (auto expression = statement.isExpStatement) {
        compileExpression(expression.exp);
        return;
    }
    // ... 25 more statement kinds
}
Operand compileExpression(Expression expression) {
    if (auto call = expression.isCallExp)
        return compileCall(call);
    // ... 70 more expression kinds
}
```

# When dinosaurs roamed the Earth (2025)...

::: columns
:::: {.column width=45%}
* ChatGPT et al could write code.
* But not well, and not a lot of it.
* Nearly one AST node at a time.
::::
:::: {.column width=55%}
![Charles R. Knight, 1897, public domain](img/dinosaurs.jpg){width=100%}
::::
:::

# Agentic coding revolution

* Autonomous agents can now write a lot of code, well.
* "Write me a backend" should work.
* Dennis had the same idea with [wasm](https://github.com/dlang/dmd/pull/23584).

# CTFE

* Part of the goal was faster CTFE.
* Run tests at compile time?
* Already an alternative D backend.
* How hard could it be?

# CTFE

* Not that hard:

```d
import dmd.dinterpret: ctfeInterpret;

Expression interpretCtfe(Expression expr, out string diagnostic) {
    Expression result;
    withCompilerLock(() {
        resetErrors;
        result = ctfeInterpret(expr);
        if (result.isErrorExp || global.errors != 0)
            diagnostic = diagnosticMessage;
    });
    return result;
}
```

# CTFE parity

* Surprisingly easy.
* Autonomous coding without input from me.
* Can run example code easily.
* Can't run real projects.

# Backends

* CTFE
* Bytecode VM - original idea.
* Tree walking interpreter - AI suggestion.
* IR - AI suggestion.
* Regular compiled D code.

# How about a REPL?

* Prior art from Martin Nowak.
* Compile code on the fly.
* Can we do better?

# Demo - REPL


# Benchmarking

* To compare fairly, must only measure post-parse/sema.
* Create a common `Backend` interface
  - Write a `Ctfe` backend to call the existing engine.
  - Write a `SystemLinker` backend to call dmd codegen.
* Parse/sema -> feed into different backends.

# Benchmarking

```
== post-parse (excludes dmd parse + semantic) ==
fixture      backend        verdict    tests             min     median     stddev

example      ctfe           repeated   105/105      7.243 ms   7.375 ms   0.110 ms
example      bytecode       repeated   105/105      5.096 ms   5.174 ms   0.090 ms
example      interpreter    repeated   105/105     25.994 ms  26.276 ms   9.696 ms
example      system-linker  repeated   105/105     64.810 ms  70.119 ms   5.818 ms
example      llvmjit        repeated   105/105     63.125 ms  64.873 ms   3.819 ms
```

# D oops #1

::: columns
:::: {.column width=55%}
* Semantic analysis is side-effecty.
* dmd codegen is side-effecty.
* dmd template codegen is.... "challenging".
* Solution? Fork!
* Template solution: lightning rod.
::::
:::: {.column width=45%}
![Raul Heinrich, CC BY-SA 3.0](img/lightning-rod.jpg){height=75%}
::::
:::

# Don't make mistakes

* Make $BACKEND run cerealed's unittests.
* They ran!
* But the code...

# AI oops #1 - the cat was away

![CC0](img/cat.jpg){height=80%}

# AI oops #1 - the mice did play

* 443 hardcoded stubs, one per test's exact mangled name:

```d
pragma(mangle, "_D13unit_threaded10assertions" ~
    "__T14shouldNotThrowHTC4core9exception10Range" ~
    "ErrorTS8cerealed10cerealiser__T14Cereal...")
void shouldNotThrowRangeErrorCerealiserImpl(
    void delegate() expression, string file, ulong line,
) @safe nothrow {
}
```

* The test "passed". Nothing was actually interpreted.

# FFI

::: columns
:::: {.column width=60%}
* Needed to call libc.
* Needed to call installed libraries like Phobos or dub deps.
* Stop everything, we need FFI.
::::
:::: {.column width=40%}
![](img/stop.png){height=55%}
::::
:::

# Once more from the top

::: columns
:::: {.column width=58%}
* Restart the backends from scratch:

```
$ git show --stat 'Deleted old backends' \
    'Delete legacy executors'
 tree_walking_old.d | 11919 ----------
 tree_walking.d     |  1070 -
 dmd_codegen.d      |  6012 -----
 ir.d               |  2237 --
 bytecode/*.d       |   684 -
 14 files changed, 22713 deletions(-)
```

* Rewritten since: interpreter 23k lines, bytecode 22k lines.
::::
:::: {.column width=42%}
![Mattbr, CC BY 2.0](img/clapperboard.jpg){width=100%}
::::
:::

# D oops #2

* `Value`: boxed D value, makes tests look pretty.

```d
static foreach (backend; AliasSeq!(Ctfe, Bytecode, IR, Interpreter)) {
    unittest {
        newBackend!backend.eval("3 + 3").should == Value(6);
        newBackend!backend.eval("3u").should == Value(3u);
        newBackend!backend.eval("1.5f + 2.25f").should == Value(3.75f);
        newBackend!backend.eval(q{ "abc" }).should == Value("abc");
    }
}
```

* Also makes FFI hard.
* A lot of work before I noticed.
* Start the bytecode VM backend a 3rd time.

# D oops #2 - the price

* Every backend has to box into, and unbox out of, this:

```d
struct Value {
    alias Data = SumType!(
        Void, bool,
        ubyte, byte, short, ushort, int, uint, long, ulong,
        char, wchar, dchar,
        Null, float, double, real,
        Array, AssocArray, ClassObject, ...
    );
}
```

# D oops #2 - the marshalling ladder

* ~3000 lines to get a boxed `Value` across the FFI boundary:

```d
void marshalArgument(ubyte[] buffer, Type type, in Value value,
    in bool stableString, ref const(char)*[] keepAlive,
    ref ubyte[][] keepAliveBuffers) {
    switch (type.ty) {
        case Tbool, Tchar, Tint8, Tuns8, ..., Tint64, Tuns64: ...
        case Tfloat32, Tfloat64, Tfloat80: ...
        case Tpointer: ...  case Tclass: ...  case Tarray: ...
        case Tstruct:  foreach (field) marshalArgument(field, ...);
        case Tsarray:  foreach (elem)  marshalArgument(elem, ...);
        default: assert(false, "unmarshalled libffi argument type");
    }
}
```

# AI oops #3

* Bytecode - no `Value` from the get-go.
* AI decided existing FFI marshalling code was an example.
* Bytecode ended up marshalling despite not needing to!
* AI decided to use `(length, ptr)` instead of `(pointer, length)`.

```d
// compiled D lays a slice out as {length, ptr} - VM used
// {ptr, length}, so every FFI call needed a compensating
// swap. Fix: flip the VM's own layout to match instead.
size_t sliceDescriptorPtrOffset(in size_t base) {
    return base + size_t.sizeof;
}
size_t sliceDescriptorLengthOffset(in size_t base) {
    return base;
}
```

# D oops #3

* AI decided to implement AAs itself.
* Again, a while before I noticed - twice (interp + VM).
* Solution: interpret/compile druntime instead.
* ~1k "hand"-written lines, deleted.

```d
// deliberately not druntime's private AA layout ...
// couples the no-emit backend to a compiler runtime ABI
// without buying any language behaviour.
struct NativeAssocArray {
    Type _keyType;
    Type _valueType;
    NativeBlock[] _keys;
    NativeBlock[] _values;
}
```

# Demo - REPL with runtime capabilities

# Mistakes

* Wrong abstraction

```d
interface Runner {
    void runTests(Module module_);
}
```


# Mistakes

::: columns
:::: {.column width=58%}
* I bit off more than I could chew
* I wasn't curious enough
* I didn't run the tests myself
::::
:::: {.column width=42%}
![William I. Harter, public domain](img/sandwich.jpg){width=100%}
::::
:::



# Conclusion

* Mistrust and verify
* Your codebase is the context they operate in
* Software engineering is still (more!) important
* D needs better tools
* Learn enough to be able to make decisions
* Understand the technical options deeply

# Learning all over again

::: columns
:::: {.column width=55%}
* I wrote a game called Gravastar.
* I wrote it 3 times.
* This is eerily familiar.
::::
:::: {.column width=45%}
![Gravastar, 4-player split-screen](img/gravastar.jpg){width=100%}
::::
:::

# Questions?
