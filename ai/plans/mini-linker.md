Thought for a few seconds

Yes, if you emit normal relocatable code and want to load it yourself,
you are writing a small dynamic linker/JIT linker.

Not a full system linker, but still linker work.

The scope depends on what you choose to support.

Minimal in-RAM linker

For one platform, one object format, one architecture, no exceptions,
no TLS, no COMDAT, no debug info, no shared libraries, you need
roughly:

parse object file read sections allocate memory for
.text/.rodata/.data/.bss copy section contents build symbol table
resolve local symbols resolve external symbols from host/dependency
image apply relocations set memory permissions RX/RO/RW flush
instruction cache if needed return address of entrypoint

That is not enormous.

For example, on ELF/x86-64, the toy version mostly means handling
relocations like:

R_X86_64_64 R_X86_64_PC32 R_X86_64_PLT32 R_X86_64_GOTPCREL
R_X86_64_RELATIVE

But that toy version stops being enough quickly.

The real D version

For D unit tests/REPL, the painful parts are:

exception/unwind metadata: .eh_frame, personality routines TLS module
constructors/destructors TypeInfo/ClassInfo references
vtables/interfaces COMDAT/linkonce sections weak symbols section
groups relocation overflow checks jump tables GOT/PLT-like
indirections symbol interposition policy visibility incremental
unloading/invalidation calling into precompiled Phobos/druntime/dub
deps

That is where “small linker” becomes “oh, this is a linker.”

Do you have to write it from scratch?

No. I would avoid that unless the experiment explicitly wants to
measure a custom linker.

Use one of these:

LLVM JITLink / ORC best existing answer if LLVM dependency is
  acceptable

mold/lld code reuse conceptually possible, but not designed as an
  embedded in-memory JIT linker API

libelf + custom relocator viable for a constrained Linux/x86-64
  prototype

dmd backend emits already-final code possible only if you
  restrict/avoid relocations heavily

shared object + dlopen simplest operationally, but pays filesystem +
  dynamic loader costs

For benchmarking, the fastest route to “native code in RAM” is
probably LLVM JITLink, even if you are not using LLVM for codegen. If
dmd can emit a relocatable object into memory, JITLink is exactly the
kind of component that can map/link it.

Important distinction

There are two different problems:

A. Code generation directly into executable memory B. Linking
relocatable generated code into executable memory

If dmd’s backend can emit final machine code with all addresses known,
then A is simpler.

But in realistic D code, addresses are not all known when emitting
instructions:

foo(); // external or later symbol throw new Exception("x");
typeid(MyClass); someGlobal += 1;

Those references need relocation or some equivalent patching
mechanism.

So even “emit straight to RAM” usually becomes:

emit code with fixups allocate symbols resolve addresses patch fixups
publish code

That is still linker-like.

One way to reduce scope

Use an indirection table.

Instead of generating arbitrary relocations into code/data, emit
calls/loads through a VM-owned symbol table:

call [symbol_table + index] load [global_table + index]

Then native codegen mostly refers to known table addresses. Updating
symbols means updating table entries, not patching code.

Pros:

simpler relocation story easier invalidation/redefinition
REPL-friendly works with incremental compilation

Cons:

slower generated code less ABI-natural still need some relocations
harder for direct calls/inlining

This could be a good prototype trick.

Another way: compile each transaction as a shared object

For a first native backend:

dmd emits .so dlopen dlsym test entrypoint run

Pros:

almost no custom linker work uses platform loader correct EH/TLS/init
behavior more likely good baseline

Cons:

filesystem overhead dynamic loader overhead hard to unload safely
symbol/versioning mess probably slower than true in-RAM JIT

But it gives you a correctness/performance baseline before writing a
JIT linker.

My recommendation

Do not start by writing a serious linker.

Benchmark in this order:

1. dmd emits shared object + dlopen establishes native dynamic-loading
   baseline

2. dmd emits relocatable object + LLVM JITLink establishes in-RAM
   linker baseline

3. only then consider custom minimal linker if JITLink overhead is
   proven too high

A custom linker is only worth it if measurements show:

JITLink/linking overhead dominates and your required
relocation/features subset is small/stable Bottom line

Yes, relocating machine code in RAM means doing linker work.

But you have levels:

toy ELF/x86-64 relocator: weeks-ish

usable D/Linux/x86-64 JIT linker: months-ish

portable production linker for D tests/REPL: large project

using LLVM JITLink: much more realistic

I’d treat custom in-memory linking as a benchmark subject, not a
prerequisite.

You can look up if the dmd backend can emit code with addresses known,
you don't have to speculate

I’ll verify this against dmd backend sources/docs rather than infer
from general compiler behavior.

Thought for 23s

Fair point. I checked. The answer is: the current dmd backend is not
purely “emit final addressed code”. It already has a
fixup/relocation-oriented object emission model.

Evidence:

The backend has an object-format abstraction with methods like:

reftoident(...)  addrel(...)  writerel(...)

dispatching to ELF/MSCOFF/Mach-O object emitters. That is not a “final
address known everywhere” interface; it is explicitly an
object/relocation interface.

The ELF path’s ElfObj_reftoident decides between directly writing an
address value and emitting a relocation. In the same function, if the
symbol is not yet in the symbol table, it adds it to a fixlist;
otherwise it may call ElfObj_writerel(...) with relocation types like
R_X86_64_PC32, R_X86_64_PLT32, R_X86_64_GOTPCREL, R_X86_64_64, TLS
relocations, etc.

The COFF side also has explicit relocation structures and x86-64
relocation kinds such as IMAGE_REL_AMD64_ADDR64,
IMAGE_REL_AMD64_REL32, IMAGE_REL_AMD64_SECREL, etc.

So the current shape is closer to:

backend emits bytes into sections
+ records symbolic references / fixups / relocations
+ object writer serializes ELF/COFF/Mach-O
+ external linker/loader resolves the rest

not:

backend always knows final executable addresses while emitting
instructions But there is a useful nuance

Some addresses are known early enough.

For example, references to already-laid-out local code/data in the
same segment can sometimes be converted directly into a
displacement/address. The ELF code has a path where, if no relocation
is needed, it writes the address value directly via writeaddrval(...);
otherwise it emits a relocation.

So a memory backend could exploit that.

A plausible in-RAM backend would be:

1. allocate memory sections up front .text .data .rodata .bss
   EH/TLS/etc if supported

2. assign each section a final base address

3. let dmd emit code/data into those sections

4. when dmd calls reftoident/addrel/writerel: if symbol address is
   known: patch immediately else: append to fixup list

5. after all functions/data in the transaction are emitted: resolve
   remaining fixups set memory permissions run entrypoint

That is still linker-like, but it is not necessarily a full
ELF/COFF/Mach-O linker. It could be a replacement Obj implementation
that consumes dmd’s existing relocation/fixup events directly.

The important distinction

Writing a loader for .o files means parsing ELF/COFF/Mach-O and
applying their relocations.

Writing a new dmd “memory object” backend could avoid the object-file
parsing step:

dmd backend → Obj interface calls → memory sections + fixup list →
  patch code/data directly

That is probably the better route if you want to reuse dmd’s backend.

Remaining hard parts

Even with final section bases known up front, you still need to
handle:

forward references external symbols calls to precompiled native deps
TLS relocations EH/unwind metadata module constructors/destructors
TypeInfo/ClassInfo/vtables COMDAT/linkonce-ish duplication symbol
invalidation after edits

But the scope is smaller than “write lld”.

Revised conclusion

You likely do not need to write a complete linker from scratch.

You probably need either:

A. use dmd object emission + LLVM JITLink/lld-style loader

or better:

B. implement a new dmd Obj backend that writes to RAM and
records/patches fixups directly

Option B is more work inside dmd, but avoids object file
round-tripping and should be the thing to benchmark for the “dmd
backend to RAM” idea.

How would this mini linker be faster than lld or mold?  Thought for a
second

It might not be faster than lld/mold at “link a real executable/shared
library”.

It can be faster only because it solves a much smaller problem.

lld/mold are optimized for general linking:

many object files archives COMDAT/section groups symbol resolution
rules visibility/interposition relaxations GOT/PLT TLS models debug
sections ICF/GC sections version scripts shared library generation
relocatable output platform object quirks

Your mini-linker would ideally avoid most of that.

Why it can win
1. No object file parsing

If you implement a dmd Obj-to-RAM backend, you do not emit
ELF/COFF/Mach-O and then parse it again.

Instead of:

dmd backend → object file bytes → lld/mold parses object file → links
→ writes executable/shared object → loader maps it

you get:

dmd backend → memory sections + fixup list → patch fixups → run

That is a real latency win.

2. Much fewer inputs

A normal linker links lots of objects and libraries. Your hot path
might only link:

changed functions/module
+ small generated test harness
+ references to already-loaded dependency image

The stable dependency closure is precompiled and already loaded.

So symbol resolution is mostly:

local transaction symbols session symbol table precompiled dependency
symbols host/druntime symbols

not a full archive/library search.

3. No output file

lld/mold usually produce an ELF/Mach-O/COFF output file or shared
object. Then the OS loader maps it.

Your mini-linker can allocate executable memory directly:

allocate .text/.rodata/.data copy bytes apply relocations mprotect
RX/RO call entrypoint

No filesystem output. No full dynamic loader pass.

4. No general-purpose link features

For a test/REPL transaction, you can probably skip:

debug info linking section garbage collection identical code folding
LTO/plugin machinery version scripts symbol export policy archive
member extraction linker script support full dynamic relocation
machinery

Skipping features is the main speedup.

5. Incremental state

lld/mold are fast, but mostly batch-oriented. Your linker can keep:

symbol table loaded sections dependency image resolved external
addresses compiled artifact cache

warm across runs.

So the second/third/nth edit-test cycle avoids repeated setup.

Where it probably will not win

If you compare against mold linking a small .so from one object file,
the gap may be small.

If your mini-linker has to implement:

EH frames TLS COMDAT weak symbols lots of relocations many changed
modules native dependency search

then it becomes less mini and the advantage shrinks.

Also, mold is extremely optimized. A naive custom linker can easily be
slower.

The real expected win

Not:

my relocation loop is better than mold's relocation loop

But:

I avoid invoking a general linker and dynamic loader pipeline at all.

The fast path is narrower:

already-sema'd changed code → dmd backend emits into RAM → patch a
small fixup list → execute selected tests Benchmark expectation

Likely outcomes:

full clean build: mold/lld wins or is hard to beat

one changed module → shared object: mold/lld competitive

one changed function/test in persistent session: mini-linker can win

many tiny REPL snippets: mini-linker can win if setup is amortized

large native-heavy test: backend execution speed matters more than
  link speed

So the claim should not be “mini-linker faster than lld/mold”.

The defensible claim is:

For small incremental transactions in a persistent process, a
specialized in-memory linker may have lower end-to-end latency because
it avoids object-file round-tripping, general link semantics,
filesystem output, and dynamic-loader setup.
