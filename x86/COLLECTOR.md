# A collector for js-x86 (milestone 5): the design

The code here was written by AI coding agents (Claude), with human supervision.

This is the agreed design for the compiled programs' garbage collector. Steve accepted it on 2026-11-26 with four decisions:
- conservative roots and a non-moving mark-sweep, not exact stack maps and a moving collector;
- a header word on every heap block;
- a GC-torture tier in the gate, which collects at every allocation, at small sizes;
- lane 1 starts on a quiet tree, not beside other compiler lanes.

Nothing below is built yet.

## Why now

Every compiled program allocates from a 1 GiB bump heap and never frees. Fib, bank and fourteen never noticed: they allocate little, or reuse their arrays. Big daddy allocates 2-3.5 MB a simulated day, almost all of it garbage by the day's end, so it runs out around 600 rounds. Its full size, 10,000 rounds, would need 20-35 GB. node's collector is part of what big daddy measures, so racing it honestly needs one of our own.

## What the compiled program looks like to a collector

**Values are NaN-boxed everywhere.** A value's bits are the same whatever the compiler knows about it, so a string, array, object, closure or Map anywhere in a frame carries its tag (0xFFFA to 0xFFFE) and its address in the low 48 bits. Two exceptions:

- **Integers** (since today's integer kind) are raw 64-bit integers in their slots.
- **Inside the heap and the runtime, pointers are raw:** an array's items address, an object's entries and table addresses, a closure record's captured cell addresses. So are pointers a runtime routine holds in a register mid-operation.

**Every allocation goes through one routine,** `runtime_allocate` (a bump of r15 against r14), called from about 45 sites in the runtime. So "is the heap full?" is already asked in one place.

**Registers are already spilled at calls.** Registers.roc stores r9-r11 and rbx to their frame places before every call. So at any call into the allocator, the program's own values are in the machine stack, and only the caller's in-flight scratch registers (rax, rcx, rdx and so on) hold anything else.

**Read-only records never move.** Literals and static closures live in the read-only segment, outside the heap, so the collector ignores any address outside the heap.

## The design I'd propose

**1. A header word on every heap block.** Today a block is just its contents. The tag on the *reference* says what the block is, but the heap's raw internal pointers carry no tag. So each block gets 8 bytes in front: its kind (string, array, items, object, entries, table, closure, cell, map, map entries, iterator, timer) and its size. That is enough to trace any block exactly and to walk the heap block by block.

**2. Conservative roots, precise heap: non-moving mark-sweep.**

- **Roots:** at collection time, push every general register, then scan the whole machine stack word by word, from rsp to the stack's base. A word counts as a possible pointer if it's a tagged pointer into the heap, or a raw address into the heap. That covers Integers that happen to look like heap addresses (they only keep garbage alive, never break anything), raw pointers mid-routine, and the try-handler records. No stack maps needed.
- **Heap:** tracing is exact, by each block's header.
- **Non-moving:** because a root might be an integer that only *looks* like a pointer, we can't rewrite it, so nothing moves. That rules out copying, but it also means no pointer anywhere ever needs updating, which is the main source of collector bugs.

This is the Boehm-style shape, chosen because it's the one where a mistake in root finding costs memory, not correctness.

**3. Size-class pages instead of one bump region.** The heap becomes 64 KB pages, each holding one block size (16, 32, 64, ... bytes), plus large blocks with their own pages. Allocation is still a bump or a free-list pop, a few instructions. An interior pointer finds its block start with arithmetic on its page, which conservative scanning needs.

**4. Collect when the heap has doubled since the last live size.** It's stop-the-world, with no write barriers, since nothing is incremental or generational.

## How it would be checked

- **Every program still matches node,** as today, through the whole gate.
- **A torture tier:** a build flag that collects at every allocation, run over x86/tests and the corpus at small sizes. Root-finding bugs show up there immediately, not once a week.
- **Big daddy at 10,000 rounds:** the first program that can't run without the collector, and its race.
- **Allocation counts** checked against the interpreter's own collector on the same programs (js/ already has one; the JS book's chapter "The garbage collector" describes it).

## The lanes, in order

1. Headers and size-class pages, still never freeing. Behaviour identical; measure the allocation overhead on all three races.
2. Mark from conservative roots, trace by headers, sweep. Add the torture tier.
3. Trigger tuning. Big daddy at full size.
4. The JS book's statement that "compiled JS has no collector" gets rewritten.

Each lane is a normal-sized lane. 1 and 2 are the big ones.

