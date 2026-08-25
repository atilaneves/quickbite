# Issue 555 bytecode VM profile

## Result

Opcode frequencies do not identify where execution time goes. The repeated
Cerealed verdict spends most sampled CPU in three areas:

1. `machine.run` is 56.56% to 61.13% of all sampled periods in six
   repeated-only profiles.
2. Real libc copy code is 13.92% of all sampled periods in the 3,999 Hz
   repeated-only profile. Five VM copy call-site groups explain 98.01% of
   those libc periods.
3. Frontend and native-call preparation remain visible outside the VM. The
   repeated-only profile has no GC worker samples because it did not collect.

The common VM block is not one 50% root cause. It contains instruction
address formation, operand extraction, jump-table work, and the indirect
jump. These ranges are stable across six sample frequencies. Precise sampled
instruction pointers show residence, not an additive causal cost for each
instruction. Out-of-order execution can retire a cheap instruction while the
processor waits for earlier work.

The five VM copy groups perform real `memcpy` calls through the PLT. They are
not compiler-lowered moves. Most copies have small fixed widths. Some bytes
must move under the current VM frame model, but the generic libc calls are
not required for the common widths. The call-argument and return-result
copies also expose extra movement caused by the separate-frame ABI.

GC is a first-verdict cost in this workload. The first verdict performed
seven collections. The repeated verdict performed none. Therefore, aggregate
GC worker CPU in a profile of both verdicts does not explain repeated VM
execution time.

## Workload

The tight measurement loop was:

```console
taskset -c 2 bin/bench -b bytecode -w 0 -r 1 --dub cerealed
```

One representative unprofiled run reported:

```text
frontend  1043.551 ms
first     5393.626 ms, compile 1308.737 ms, 167476 KiB
repeated  4051.346 ms, compile       .023 ms,  62494.6 KiB
156/156 tests passed
```

The first verdict includes compilation and VM execution. The repeated verdict
has a negligible compile phase and is the primary VM measurement.

## Method

All primary profiles used the normal optimized and inlined VM. The benchmark
build includes debug metadata, but no profiling flag changes optimization.
The experimental handler helpers were inlined and did not create independent
ELF symbols. LLVM also merged some handler tails. Source-line or symbol-only
reports cannot separate these paths.

Each completed benchmark was copied to a unique directory in `/tmp`. The
profile was recorded by executing that immutable copy. `perf buildid-list`
and `readelf -n` were checked before analysis. This avoids a `perf` build-ID
cache hazard: the cache can hard-link a binary that a later build overwrites.

The first precise profile used this immutable build:

```text
64fe857b392a69171d63406776f9a4db121fa1bf
```

The command was:

```console
perf record -e cycles:uP -c 1000003 -j any,u \
    -o /tmp/quickbite-issue-555-precise-64fe.data -- \
    taskset -c 2 /tmp/quickbite-issue-555-build-64fe/bench \
    -b bytecode -w 0 -r 1 --dub cerealed
```

The event had `precise_ip=3`. The run captured 48,554 hardware samples and
lost none. It included both verdicts. Build `64fe...` contained a dormant,
environment-controlled GC boundary probe in the benchmark CLI. The probe was
not enabled for this record. It had no memcpy wrapper, interposition, noinline
helper, or hot-path counter.

The repeated-only profiles used this immutable build:

```text
7a0334b63b48007a546cb18cb746f15a971455b1
```

That build added only an outside-the-VM FIFO control hook to the benchmark
callback. `perf` started disabled, then recorded only the repeated verdict:

```console
perf record -D -1 \
    --control=fifo:CONTROL_FIFO,ACK_FIFO \
    -e cycles:uP -F FREQUENCY -j any,u \
    -o PROFILE.data -- \
    env QUICKBITE_PERF_CONTROL=CONTROL_FIFO \
        QUICKBITE_PERF_ACK=ACK_FIFO \
    taskset -c 2 IMMUTABLE_BENCH \
    -b bytecode -w 0 -r 1 --dub cerealed
```

The frequencies were 2,753, 3,001, 3,503, 3,999, 4,507, and 5,003 Hz. All
six runs passed 156 of 156 tests. The three benchmark builds used for the
main precise, repeated-only, and earlier whole-command profiles have the same
13,650-byte `machine.run` and the same normalized disassembly instruction
sequence. Only relocated addresses and immediates differ.

The frequency profiles use summed sample `period` weights. Raw sample counts
are not used as elapsed-time attribution. The fixed-period profile has almost
equal period weights, so its exact instruction table also gives sample counts.

## Hypotheses

The initial ranked hypotheses were:

1. VM call and return frame movement dominates execution.
2. The common fetch, decode, and dispatch path dominates execution.
3. `loadConstant` staging and copying dominates execution.
4. Pointer address, pointer load, and general copy work dominate execution.
5. GC and allocation outside the repeated VM run dominate execution.

The measurements refine them as follows:

- The common path is large, but it is several distinct ranges. No one range
  is 50% of `machine.run`.
- Small copy code is material. `loadConstant` is the largest caller, followed
  by `copy`, `pointerLoad`, call arguments, and return results.
- Call and return copies are material, but they do not explain all VM time.
- GC is large only when both verdicts are combined. The repeated verdict did
  not collect.

## Broad CPU phases

A whole-command `cpu-clock:u` profile with DWARF call graphs gave these broad
self-attribution values:

```text
machine.run                         42.21%
druntime GC mark workers             8.76%
druntime GCBits work                 3.92%
libc small-copy implementation      about 11% to 12%
memcpy PLT                           4.48%
Type.toBasetype                      2.53%
Parameter list traversal             2.15%
```

The GC values aggregate sampled CPU over the main thread and 15 GC mark
workers. They are not wall-time shares.

The 3,999 Hz repeated-only profile reported these broad self values:

```text
machine.run                         60.44%
memcpy PLT                           3.33%
Parameter traversal                  4.07%
parameter-list work                  2.00%
preparePhysicalCall                  1.77%
physical-call policy                 1.72%
Type.toBasetype                      1.31%
ffi.call                             1.05%
native-call preparation              0.88%
libffi ffi_call                      0.46%
```

There were no GC symbols in the repeated-only profile.

## Common VM path

### Exact fixed-period split

There were 22,181 samples in `machine.run` in the fixed-period precise
profile. The native instruction ranges split as follows:

| Range | Samples | Share of `machine.run` |
| --- | ---: | ---: |
| IP advance | 19 | 0.086% |
| Handler state restore | 1,132 | 5.104% |
| Function and code lookup | 2,076 | 9.359% |
| IP times 12 address | 1,782 | 8.034% |
| Two instruction loads | 213 | 0.960% |
| Opcode range guard | 35 | 0.158% |
| Operand extraction | 1,889 | 8.516% |
| Jump-table index | 1,828 | 8.241% |
| Target lookup and relocation | 279 | 1.258% |
| Indirect jump instruction | 1,962 | 8.845% |

These ranges total 50.56% of `machine.run`. This is a descriptive residence
split. It is not ten additive causal instruction costs.

The state-restore range belongs to the preceding handler, not to fetch or
dispatch. All 1,151 samples in the combined handler-tail and state-restore
range had the earlier central dispatch branch and handler target in their
last-branch records. Of these, 1,133, or 98.44%, also had the immediate branch
from that handler to the common tail. Therefore, handler attribution can
charge this range to the preceding handler without changing VM code. Shared
LLVM handler targets must remain handler families rather than false per-op
labels.

### Six repeated-only profiles

The following values are period-weighted percentages of `machine.run`. They
are the minimum, median, and maximum over the six sample frequencies:

| Native range | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| IP advance | 0.050% | 0.082% | 0.097% |
| Handler state restore | 4.745% | 4.907% | 5.173% |
| Function and code lookup | 8.680% | 9.167% | 9.630% |
| IP times 12 address | 7.960% | 8.151% | 8.233% |
| Two instruction loads | 1.144% | 1.211% | 1.352% |
| Opcode range guard | 0.125% | 0.164% | 0.194% |
| Operand extraction | 8.369% | 8.514% | 8.751% |
| Jump-table index | 7.508% | 7.790% | 8.576% |
| Target lookup and relocation | 1.648% | 1.851% | 2.056% |
| Indirect jump instruction | 8.384% | 8.845% | 9.372% |

`machine.run` itself was 56.564% to 61.132%, with a 59.785% median, of all
repeated-process sampled periods. The narrow range spreads show that the
fixed 1,000,003-cycle period did not create the main range pattern. They do
not remove the out-of-order execution limit.

The last-branch records mark about 0.87% of sampled central dispatch branch
entries as mispredicted. This is a sampled flag rate, not an exact execution
rate and not a miss penalty. A global indirect-branch counter cannot isolate
this dispatch. The host exposes a PEBS retire-latency event, but the required
nested `perf` record failed under `perf_event_paranoid=2`. No miss-latency
claim is made.

## Small-copy paths

### Period-weighted callers

The 3,999 Hz repeated-only profile has these exact denominators:

```text
whole process:              17,674 samples, 18,725,954,894 periods
machine.run self:           10,684 samples, 11,320,588,428 periods
libc offsets 0x176400-4ff:   2,459 samples,  2,606,661,096 periods
classified VM copy callers: 2,410 samples,  2,554,673,441 periods
```

The classifier used the newest actual VM `memcpy` call in each sample's LBR
stack. The classified callers explain 98.006% of the libc small-copy periods.

| Caller group | Count | Period | Copy | Process |
| --- | ---: | ---: | ---: | ---: |
| `loadConstant` family | 1,219 | 1,292,306,708 | 49.577% | 6.901% |
| `copy` | 627 | 664,287,719 | 25.484% | 3.547% |
| `pointerLoad` | 246 | 260,958,170 | 10.011% | 1.394% |
| Call arguments | 182 | 192,826,766 | 7.397% | 1.030% |
| Return result | 136 | 144,294,078 | 5.536% | 0.771% |

`Copy` is each group's share of all 2,606,661,096 libc small-copy periods.
`Process` is its share of all repeated-process periods. Relative to
`machine.run` self periods, the groups are 11.416%, 5.868%, 2.305%, 1.703%,
and 1.275%. That comparison does not make `machine.run` an inclusive
denominator. The precise LBR profile has no full call graph, so an exact
`machine.run` inclusive-cycle share is not derivable.

The sampled instructions at libc offsets `0x176400` through `0x1764ff` are
the resolved libc IFUNC implementation. It checks 32- and 64-byte thresholds.
It uses scalar or vector moves for widths below 32 bytes, XMM moves for 16 to
31 bytes, and YMM moves for 32 to 64 bytes. This is execution in libc, not PLT
overhead. The PLT is measured separately.

Before entering memcpy, the `loadConstant` handler body itself was 11.47% of
`machine.run` in the fixed-period precise profile. That value and the libc
caller value describe different ranges and must not be added as if they were
independent causal costs.

### Exact requested sizes

A temporary memcpy interposer counted sizes and physical VM return addresses.
It delegated the copy to `memmove` and covered the first and repeated verdicts
together. It passed 156 of 156 tests. Interposition changed timing, so these
are call counts and sizes only. They are not time attribution.

The dominant exact counts were:

- Constant: 1 B = 11,408,596; 2 B = 596,918; 4 B = 36,600,398;
  8 B = 738,657,692; and 16 B = 96.
- Copy: 1 B = 38,082,897; 2 B = 2,789,718; 4 B = 39,792,155;
  8 B = 298,606,934; 16 B = 32,117,687; 24 B = 735,295; and
  32 B = 1,440,736.
- Pointer load: 1 B = 24,368,106; 2 B = 1,791,066;
  4 B = 11,315,273; 8 B = 62,745,149; 16 B = 49,632,543;
  24 B = 184; and 32 B = 1,440,746.
- Call arguments: 1 B = 792,428; 2 B = 396,978; 4 B = 866,204;
  8 B = 50,765,233; 16 B = 44,712,816; 24 B = 4,264,562; and
  32 B = 721,325.
- Return result: 1 B = 22,265,580; 2 B = 298,990; 4 B = 1,402,866;
  8 B = 22,597,826; 16 B = 2,944,283; 24 B = 394; and
  32 B = 1,441,122.

Other call-argument widths were 9, 10, 11, 12, 13, 14, 17, 18, 20, 28, 40,
48, 56, 64, 65, 72, 80, 84, 96, 152, and 160 bytes. There were 1,442,826
zero-byte call-argument calls. Other return widths were 3, 6, 12, and 48
bytes. There were 62,059,231 zero-byte return calls. The general-copy and
pointer-load groups also had small numbers of 3, 6, 12, 40, 48, and 64-byte
calls. Tail merging means a physical call site can represent a small handler
family. The size table is exact for physical call sites, not proof of an
exclusive source-level opcode cost.

### Required and avoidable work

- `loadConstant` writes a scalar constant into its final VM slot. The final
  write is required. The stack-local eight-byte staging array and generic
  libc call are avoidable. Direct little-endian 1-, 2-, 4-, and 8-byte stores
  can preserve current D value semantics.
- `copy` moves one VM slot or region to another. The logical movement is
  required under the current bytecode. A generic libc call is avoidable for
  common fixed widths by using scalar or vector moves. Any replacement must
  preserve the current self-copy and non-overlap rules.
- `pointerLoad` moves guest memory into a VM slot. The final write is required.
  Fixed-width unaligned loads and stores can remove the libc call. The
  variable-width form still needs a copy.
- Call arguments move the caller argument region into a new dense callee
  frame. The movement is required under the current separate-frame ABI.
  Typed moves can remove libc call overhead but not the bytes. A sliding or
  shared frame, or direct parameter placement, is needed to remove movement.
- Return results move the callee result into the caller destination. The same
  ABI limit applies. A return-slot alias can remove movement. Zero-byte calls
  are avoidable without an ABI change.

These are optimization candidates, not measured speedups. They need controlled
one-change benchmarks before selection.

## GC boundary measurement

An environment-controlled benchmark callback recorded `GC.stats` and
`GC.profileStats` before and after each verdict. One run gave:

| Metric | First verdict | Repeated verdict |
| --- | ---: | ---: |
| Collections | 7 | 0 |
| Collection time | 782.978 ms | 0 ms |
| Pause time | 769.664 ms | 0 ms |
| Thread allocation | 173,574,192 B | 65,311,280 B |
| Heap used before | 381,774,976 B | 271,379,040 B |
| Heap used after | 271,378,976 B | 339,225,344 B |
| Heap free before | 63,869,824 B | 174,265,760 B |
| Heap free after | 174,265,824 B | 160,945,408 B |

The first verdict was 5,329.530 ms and its compile phase was 899.250 ms in
that run. The collection-time delta is 14.69% of the full first-verdict wall
interval. The compile phase is inside that interval; it is not a valid
collection-time denominator by itself.

Local LDC druntime source sets `begin` and phase boundaries from
`MonoTime.currTime`, then sums preparation, mark, and sweep durations across
collections. Parallel marking waits for its worker group before the phase
ends. `totalCollectionTime` is therefore summed wall duration across the
seven collections, not summed worker CPU.

Observed collection triggers entered `fullcollect` through `smallAlloc` or
`bigAlloc`, usually from `_d_newarrayT` or `_d_newarrayU`, and sometimes from
`gc_qalloc` below `ffi_call`. Source inspection identifies several possible
mechanisms:

- `Op.allocStruct` allocates a new scannable GC `ubyte[]`.
- Executed druntime source performs real druntime array allocations.
- The compiler and program remain live across test cases.
- The VM registers a raw stack prefix of at least 64 KiB with `GC.addRange`.
- VM-owned byte blocks clear `NO_SCAN`, so conservative scanning and false
  retention are possible.

The profile does not quantify each mechanism. They must not be presented as
measured shares. The confirmed conclusion is narrower: allocation and seven
collections make GC expensive in the first verdict, while the repeated
verdict allocates 65,311,280 bytes but performs no collection.

## Limits and next measurements

- Sampled IP ranges show residence, not isolated causal latency.
- LBR histories can assign shared handler tails to prior handlers, but LLVM
  target sharing limits attribution to handler families.
- The indirect-branch miss penalty is unknown because the retire-latency
  event could not be recorded with current host permissions.
- The memcpy size probe gives frequencies only and changes runtime cost.
- The current results identify candidates. Controlled one-change A/B builds
  are still required to measure speedups from cached function/code state,
  alternate instruction addressing, typed copies, frame changes, or another
  dispatch form.

The synthetic decode and dispatch spikes in adjacent directories answer code
generation questions only. They do not attribute Cerealed time and are not
used as evidence for the results above.
