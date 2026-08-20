---
title: Do as I Say, Not as I Do
subtitle: Lessons in agentic coding new backends
author: Átila Neves
date: DConf 2026
---


# The idea

* I hate waiting.
* 200ms is a long time to wait.
* 2s for unit tests is an eternity.
* Do I *have* to compile code to run it?
* Goal: minimal edit -> test result latency.

# Lisp did it first

* Lisp: REPL and interpreter.
* Code can be compiled to bytecode for faster execution.
* Emacs is a Lisp VM pre-built with editing functions.
* Bytecode for D?

# Implementing a D backend

* Requires subclassing ...

AI: include D code showing backend stuff (must fit on slide)

# When dinosaurs roamed the Earth (2025)...

* ChatGPT et al could write code.
* But not well, and not a lot of it.
* Nearly one AST node at a time.

# Agentic coding revolution

* Autonomous agents can now write a lot of code, well.
* "Write me a backend" should work.
* Dennis had the same idea with [wasm](https://github.com/dlang/dmd/pull/23584).

# CTFE

* Part of the goal was faster CTFE.
* Already an alternative D backend.
* How hard could it be?

# CTFE

* Not that hard:

AI: insert D code from Ctfe backend (must fit on slide)

# How about a REPL?

* Prior art from Martin Nowak.
* Compile code on the fly.
* Can we do better?

# Demo - REPL

# CTFE isn't general enough

* CTFE was meant for compile time.
* No runtime shenanigans.

# Backends

* CTFE
* Bytecode VM - original idea.
* Tree walking interpreter - AI suggestion.
* IR - AI suggestion.
* Regular compiled D code.

# Benchmarking

* To compare fairly, must only measure post-parse/sema.
* Create a common `Backend` interface
  - Write a `Ctfe` backend to call the existing engine.
  - Write a `SystemLinker` backend to call dmd codegen.
* Parse/sema -> feed into different backends.

# D oops #1

* Semantic analysis is side-effecty.
* dmd codegen is side-effecty.
* dmd template codegen is.... "challenging".
* Solution? Fork!
* Template solution: lightning rod.

# CTFE parity

* Surprisingly easy.
* Autonomous coding without input from me.
* Can't run real projects.

# Don't make mistakes

* Make $BACKEND run cerealed's unittests.
* They ran!
* But the code...

# AI oops #1 - the cat was away

AI: insert old executor code here special casing and intercepting cerealed code.

# FFI

* Needed to call libc.
* Needed to call installed libraries like Phobos or dub deps.
* Stop everything, we need FFI.

# Once more from the top

* Restart the backends from scratch ()

# D oops #2

* `Value`: boxed D value, makes tests look pretty.
* Also makes FFI hard.
* A lot of work before I noticed.
* Start the bytecode VM backend a 3rd time.

# AI oops #3

* Bytecode - no `Value` from the get-go.
* AI decided existing FFI marshalling code was an example.
* Bytecode ended up marshalling despite not needing to!
* AI decided to use `(length, ptr)` instead of `(pointer, length)`.

# D oops #3

* AI decided to implement AAs itself.
* Again, a while before I noticed.
* It did for two different backends!
* Solution: interpret/compile druntime.

# Conclusion

* Don't bit off more than you can chew.
* Learn enough to be able to make decisions.
* Do not trust agents to do the right thing.
* Write down everything you know about coding.
* Understand the technical options deeply.
* Your codebase is the context your agents operate in.

# Questions?
