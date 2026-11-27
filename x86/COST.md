# The cost tier

The races are timed on a shared 2-core VM, and the timings move with its load.
This tier measures what doesn't move: what the bytes are, and what a model of
the box's CPU says those bytes cost. It is a measurement, not a gate, so
check.shale doesn't run it.

## What the box has

The tier can only use what is installed on the box. On 2026-11-27 that was:

| tool | on the box | works | what it would give |
|---|---|---|---|
| valgrind (cachegrind, callgrind) | no (only `/usr/lib/valgrind/*.supp`, left by another package) | no | an exact dynamic count, simulated cache misses |
| `perf` 6.8.12 | yes | no counters | `perf stat` refuses: `perf_event_paranoid` is 4. The VM's CPU flags have no `arch_perfmon`, so KVM exposes no PMU, and root would get no cycles or instructions either |
| llvm-mca (LLVM 18, `llvm-mca-18`) | yes | yes | a static model of a block: micro-ops, port pressure, throughput, one pass's latency |
| uiCA | no | no | the same kind of model, more exact for Intel |
| qemu-user (insn plugin), DynamoRIO, Intel SDE, Pin | no | no | an exact dynamic count |
| gdb, rr | no | no | single-stepping (too slow for these races anyway) |
| bpftrace | yes | needs root | nothing for user-space instruction counts |
| objdump | yes | yes | the disassembly (profile.shale already uses it) |

The CPU is a DigitalOcean "DO-Premium-Intel": family 6, model 85, stepping 7,
which is Cascade Lake. llvm-mca calls it `cascadelake`.

**There is no exact dynamic count on this box.** The tier uses llvm-mca for
static block costs. A dynamic count needs the executable to count itself,
designed below as "The counter" but not built. LLVM stays out of the compiler:
llvm-mca only reads our disassembly.

## What x86/cost.shale measures

| part | for | what | deterministic because |
|---|---|---|---|
| the bytes | each race at its small size (collector.shale's sizes: fib N = 100,000, bank 2,000,000, fourteen and big daddy 300 rounds, SAT small), each driver | the executable's size, its static instruction count, and whether its bytes match the first driver's | the compiler is deterministic |
| the places | a bytecode range of one SAT function, given per driver (`places=`) | the fast path of each bytecode instruction in the range, read by llvm-mca: instructions, micro-ops, block throughput, one pass's latency (two ways) | the same bytes give the same model |

A place's **fast path** runs from its label to its first `jmp` or to the next
label (its own `_slow` or `_read_exit`, or the next place's). The fast paths
are joined in bytecode order, which assumes every conditional branch falls
through. That is the shape of a guarded fast copy, but a loop's own `if`s are
not modelled.

| column | meaning |
|---|---|
| `rthroughput` | llvm-mca's block reciprocal throughput: the cycles one pass needs when passes overlap freely, set by the busiest port |
| `latency` | one pass's cycles from the first dispatch to the last retire, with every load waiting on every store before it (`-noalias=false`). This is a ceiling: a frame slot stored and loaded back pays its trip, and so does every other frame load |
| `free` | the same with no load waiting on a store (`-noalias=true`). This is a floor |

The real CPU forwards a store to a load of the same address and lets other
loads pass, so its cost lies between `latency` and `free`. llvm-mca
simulates no caches.

### How to run it

From the repository's root:

```
shale x86/cost.shale                                # every race, this tree's js-x86: the bytes
shale x86/cost.shale races=sat show=1 --args-stdin <<'ARGS'
drivers=master:/home/steve/build/scratch/kinds6-l3/master-js-x86,lane3:/home/steve/build/scratch/kinds6-l3/lane3final-js-x86
places=master:code_16_72-78,lane3:code_16_73-79
ARGS
shale x86/cost.shale twice=1 ...                    # runs the tier twice and fails unless the tables match
```

`show=1` writes each fast path, with llvm-mca's timeline, to a `.mca.txt` file
beside the executable and prints its path. A versioned loop renumbers a
function's bytecode, so each driver gets its own range. In the SAT race,
lane 3's `code_16_<n+1>` is master's `code_16_<n>` from about 65 on. To find
the hot places, use profile.shale's samples or the counter below. The SAT
compile takes about 20 s per driver, and the tier compiles it twice (the
executable, then its labels). A two-driver run with `twice=1` takes about
2.5 minutes.

**Deterministic:** the `twice=1` run below printed `twice: the second pass's
tables are the first's, byte for byte`.

## The first table: master c480c4b against lane 3

The drivers are the ones saved in `build:scratch/kinds6-l3`: `master-js-x86`
and `lane3final-js-x86`.

| race | master bytes | lane 3 bytes | static instructions | same bytes |
|---|---|---|---|---|
| fib 100,000 | 31,115 | 31,115 | 8,332 | yes |
| bank 2,000,000 | 45,069 | 45,069 | 11,581 | yes |
| fourteen 300 | 29,687 | 29,687 | 7,940 | yes |
| big daddy 300 | 90,622 | 90,622 | 21,402 | yes |
| SAT small | 193,725 | 269,264 | 42,026 / 54,128 | no |

Four of the five races are the same program under both drivers. Any time
difference between master and lane 3 on those four is the box's noise. In
lane 3's SPECIALIZATION.md table (branch x86-kinds6-l3), big daddy reads 1,428 ms against 1,514 ms.
That 6% gap is noise, about as large as the SAT gap being judged.

**The SAT watch loop in propagate** (function 16). The item read,
`pool[base + 2 * i]`, is master's `code_16_75` and lane 3's `code_16_76`.

| window | driver | instructions | micro-ops | rthroughput | latency (ceiling) | free (floor) |
|---|---|---|---|---|---|---|
| the read and its neighbours (master 72-78, lane 3 73-79) | master | 43 | 47 | 7.8 | 51 | 27 |
| | lane 3 | 26 | 27 | 7.0 | 62 | 32 |
| the loop's fast path (master 70-135, lane 3 71-136) | master | 353 | 383 | 63.8 | 329 | 88 |
| | lane 3 | 229 | 252 | 67.0 | 457 | 90 |

**Where the instructions go,** over the loop's fast path:

| kind | master | lane 3 | change |
|---|---|---|---|
| all | 353 | 229 | -124 |
| branches (`j..`) | 48 | 12 | -36 |
| tag and untag shifts (`, 0x30`, `, 0x10`) | 37 | 14 | -23 |
| converts (`cvt..`) | 18 | 13 | -5 |
| loads | 68 | 75 | +7 |
| frame loads (`[rbp ...]`) | 49 | 56 | +7 |
| stores | 42 | 67 | +25 |
| frame stores | 40 | 65 | +25 |

## What it says about lane 3

**The model predicts lane 3's result:** about the same speed, a little slower
on the item read.

- **Lane 3 removed the cheap instructions.** About 60 of the 124 it cut were
  tag tests and their branches. On a fast path they are predictable, and
  they run in parallel, off the dependency chain. Removing them saves issue
  slots, and issue isn't what limits this loop: one pass's instructions per
  cycle are 0.5 to 2.5 on lane 3 and 1.1 to 4.0 on master (latency against
  free), under the 6 the core can dispatch, and the block's bound is a port.
- **Lane 3 added stores.** It has 25 more frame stores. Cascade Lake retires
  one store a cycle, so 67 stores take 67 cycles a pass: lane 3's whole
  `rthroughput` of 67.0 is the store port. Master's 63.8 is lower, so the
  bound moved up.
- **The item read's chain got longer.** On master the array record stays in
  `rbx` and the index stays in `rcx`. On lane 3 the index is an `imul` and an
  `add` through frame slots, each stored and loaded back. The record is loaded
  from the frame and untagged at every read. The item goes through `movsd`
  (5 cycles), then `cvttsd2si` (6 cycles), then to a frame store that the
  next place loads. One pass of the read is 62 cycles against 51 with loads
  held behind stores, and 32 against 27 with them free. Lane 3's
  SPECIALIZATION.md (branch x86-kinds6-l3) says the hot samples sit on the `cvttsd2si` after the cache-missing load,
  and that is the convert sitting on the chain.
- **The cache misses are unchanged.** Both builds load the same array items
  in the same order, and llvm-mca simulates no cache, so neither the model
  nor an instruction count would see a difference there. That is what the
  timings show: no difference.

**For lane 4,** the same tier gives the target in advance. A change speeds up
the watch loop only if it lowers the loop's `rthroughput` (fewer frame stores:
keep the fast copy's slots in registers) or shortens the read's `free` latency
(keep the record's untagged address across the iteration, and drop the
convert on the chain). Removing more tag tests won't.

**A single profile run, for scale only** (a time measurement, not this tier):
`profile` on each SAT small executable at ROUNDS 4 gave master 3,188 ms of CPU
and 3,184 samples, and lane 3 2,618 ms and 2,618 samples. A quiet-box run
gave 782 ms against 811 ms the other way. The gap between those two
measurements is the noise this tier is meant to avoid.

## Lane 4, as built (2026-11-27)

**A correction to the tables above.** An empty place's label shares the next
place's address, and `fast_path` read that code once for each label at it.
It reads it once now, so the rows move: master's loop is 63.0, not 63.8, and
lane 3's is 63.0, not 67.0. Lane 3's store bound was partly the tier's double
count. The tier also prints the fast path's instructions by kind now.

Lane 4 is two general rules of the compiler's frame and register use:

- **FrameValues** (x86/roc/FrameValues.roc), a pass over each function once
  its kinds settle. A load of a frame place that a register already holds
  becomes a move from that register. The pass numbers values, so a copy
  outlives its register being written, and a stored immediate is loaded as
  the immediate. A label whose jumps all come before it starts with what
  every way into it knows. A store that no path ever loads back is dropped.
  This is backward liveness over the places, following every jump. The pass
  leaves a function alone if it takes the address of a place or names `rbp`
  any other way, and it does nothing in a program with a `try`.
- **Registers counts hot code only.** A versioned loop's generic copy runs
  only after a guard fails or a side exit is taken. Its moves no longer count
  toward which places get the four spare registers, and its loops' carried
  places are no longer carried. So the fast copy takes the registers it used
  to share with its twin.

The drivers are master and lane 3 as in the first table, and lane 4 at this
branch's head (master 06a4131 merged).

| window | driver | instructions | micro-ops | rthroughput | latency (ceiling) | free (floor) |
|---|---|---|---|---|---|---|
| the read and its neighbours (master 72-78, lanes 3 and 4 73-79) | master | 43 | 47 | 7.8 | 51 | 27 |
| | lane 3 | 26 | 27 | 7.0 | 62 | 32 |
| | lane 4 | 22 | 23 | 3.8 | 34 | 26 |
| the loop's fast path (master 70-135, lanes 3 and 4 71-136) | master | 348 | 378 | 63.0 | 327 | 87 |
| | lane 3 | 222 | 245 | 63.0 | 438 | 86 |
| | lane 4 | 172 | 191 | 31.8 | 244 | 63 |

Over the loop's fast path:

| kind | master | lane 3 | lane 4 |
|---|---|---|---|
| all | 348 | 222 | 172 |
| branches | 48 | 12 | 12 |
| tag and untag shifts | 37 | 14 | 14 |
| converts | 18 | 13 | 13 |
| loads | 64 | 72 | 51 |
| frame loads | 45 | 53 | 32 |
| stores | 42 | 63 | 23 |
| frame stores | 40 | 61 | 21 |

The loop's bound is no longer the store port. Its `rthroughput` is half of
master's.

In the read, the array record now stays in `rbx`, the bytecode stack's top
place that Registers renames, and `i` stays in `r10`.

Three things are still left in the read:
- the record is untagged at every read;
- `base + 2 * i` still makes one trip through two stack places, because the
  lowering works in `rax` and `rcx` and its operands are gone from them by
  the time the `add` reads them;
- the item is still a `cvttsd2si`. An Int32 array's items are doubles in
  memory, so an item read as an integer is a convert wherever it is read.

Removing the convert would need items stored as integers. Keeping the
untagged record across the iteration would need a register held across the
loop, which is past Registers' rule of renaming whole places.

The rules touch fib, bank and fourteen. FrameValues applies in each of their
functions. fib 100,000 goes from 31,115 to 30,713 bytes, bank 2,000,000 from
45,069 to 44,341, and fourteen 300 from 29,687 to 29,479. Big daddy 300 has a
`try`, so it is the same 90,622 bytes. The Registers rule applies only to
versioned loops, so it leaves all four races' bytes as they were. The SAT
race's small workload is 247,334 bytes, against lane 3's 269,264.

## The counter: an exact dynamic count (designed, not built)

The box can't count a run's instructions from outside it. js-x86 can make the
executable count them itself, the same way `profile` and `guardsflip` are
modes of the executable.

| piece | design |
|---|---|
| the mode | `js-x86 "<program>" counted` writes an executable with a counter at each label: every bytecode instruction's start (`code_<f>_<n>`), each of its own labels (`_slow`, `_read_exit`, `_done`, the item-kind labels), each runtime routine's entry, and the routines' loop heads, labelled for this |
| a counter | `inc qword ptr [COUNTS + 8*k]`, one instruction, `k` the label's index in `labels` order. The table is a fixed mapping beside the heap's, as `Heap.spare_place` is for `guardsflip` |
| flags | `inc` writes the flags. At a label that starts a bytecode instruction they are dead. At a jump target the lowering has to say so, and the mode refuses a label where the flags are live, rather than counting wrong |
| exactness | the count is exact when every jump target is a label. cost.shale checks this from the disassembly (each `j..` and `call` target is one of the labels) and refuses the count otherwise |
| the output | at exit (and at a stop), the table is written to `x86.counts`, 8 bytes per label, as `profile` writes `x86.prof` |
| what cost.shale adds | for each block between two labels, its static instructions (from objdump, without the counter) times its count gives the exact dynamic instruction count per place, per function and for the whole run. Each block's count times its llvm-mca throughput gives a predicted cycle count |
| deterministic | the program is: the same input runs the same blocks the same number of times. Two things could break that, and `twice=1` would catch either: a hash over heap addresses (the heap's mapping is placed by the kernel), or a collection that a timer schedules |
| what it can't give | cache misses. A cache simulator would need each load's address: the counted mode could log the hot loads' addresses for an offline simulation, a later step if the misses turn out to be the question |
| cost | one memory increment per block. It perturbs time but not the counts, and it is never the race's build: its bytes are a separate executable, as `profile`'s mode is |

With the counter, the first table becomes this, with the dynamic counts
filled in:

| race | driver | instructions run | in the program's code | in the runtime | predicted cycles |
|---|---|---|---|---|---|
| SAT small | master | ... | ... | ... | ... |
| SAT small | lane 3 | ... | ... | ... | ... |
