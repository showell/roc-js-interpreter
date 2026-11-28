# A collector for js-x86 (milestone 5): the design

The code here was written by AI coding agents (Claude), with human supervision.

This is the agreed design for the compiled programs' garbage collector. Steve accepted it on 2026-11-26 with four decisions:
- conservative roots and a non-moving mark-sweep, not exact stack maps and a moving collector;
- a header word on every heap block;
- a GC-torture tier in the gate, which collects at every allocation, at small sizes;
- lane 1 starts on a quiet tree, not beside other compiler lanes.

All four lanes are in (2026-11-27): headers and size-class pages, then the mark, the sweep and the torture tier, then the trigger's measurement and the book; "Lane 1, as built", "Lane 2, as built" and "Lane 3" at the end say what each is and what it cost.

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

## Lane 1, as built (2026-11-27)

`roc/Heap.roc` holds all of it; its header is the layout's home.

- **The header:** 8 bytes before every block's contents, the kind's code (`Heap.BlockKind`: string 1, array 2, items 3, object 4, entries 5, table 6, closure 7, cell 8, collection 9, collection entries 10, iterator 11, timer 12, texts 13, a routine's list of raw string addresses; and since milestone 6, numbers array 14 and int32 array 15, an array's record whose items are all numbers, or all whole numbers of 32 bits, x86/SPECIALIZATION.md's "Lane 1, as built") in the top 16 bits and the bytes asked, rounded up to 8, in the low 48. Each of the 33 allocation sites names its kind (`Heap.allocate(String)`), an entry that loads the kind's bits and joins the shared path. The allocator still answers the address past the header, so every layout the runtime reads is as it was, and a value's address is its header's plus 8.
- **The pages:** `r15` now holds the heap's state, not its next free byte: the next free page, the first page, the walk's mode and counts, each size class's next block and block size, and a page table of one byte a page (0 not taken, 3 to 14 a page of blocks of `2 << n` bytes, 0x80 a large block's first page, 0x81 each page after it). Pages are 64 KiB from the first multiple of 64 KiB past the state. Blocks are 16 to 32768 bytes, powers of two, header included; a bigger block takes whole pages. A small block is a bump through its class's page; the class takes the next free page when its next block lies at a page's start.
- **The interior pointer:** `runtime_block_start` (`Heap.block_start`): page = (address - first page) >> 16; a small page's block size `s` comes from its class, and the header is at `address & -s`; a large block's later page walks the table back to its first. It answers 0 for an address below the first page or past the next free one, or in a block not taken yet (header 0). It changes `rax`, `rcx` and `rdx`.
- **The walk:** `runtime_heap_walk`, run at the exit and at a stop when the executable's first argument is `heapwalk` (`heapstat` writes its counts too). Each header must hold a kind's code and a size its block's class was chosen for, and `block_start` of the block's first and last bytes must give the block back; past a page's first free block (which must be its class's next) every header must be 0; a large block's later pages must be marked 0x81. x86/programs.shale and x86/fib.shale run every executable with `heapwalk`; x86/tests/heap-large-blocks.js puts large blocks between small pages. Planted once each and seen red: an iterator allocated with 0 bytes and written with 32 (x86/programs.shale failed, 57-map-set-churn stopping with the walk's line), a block size doubled in `block_start` (fib.js, 48-map-set and 55-garbage each stopped), and a large block's later pages marked as first pages (heap-large-blocks.js stopped).
- **The heap is 2 GiB, not 1:** headers and the classes' rounding take about 1.35 times the bytes asked on big daddy (4 to 8 bytes of header on an average block of about 61), and its 300 rounds ask 900 MB, past what 1 GiB holds. The mapping reserves nothing, so only touched pages are memory.

**What it cost** (each the median of 7 runs, before and after alternated, niced, the executables of master 5ef49e2 and of this lane, load 0.5 to 1.0; the executable's bytes are the same from the driver's dev and release builds; big daddy's second line is 9 more runs of it alone). Bytes asked are what the bump allocator took before, exactly (it took each ask rounded to 8); after, the blocks hold them with their headers, and the pages are what is touched at most:

| race | before: wall, CPU | after: wall, CPU | bytes asked (before's heap) | after: blocks, bytes in blocks, pages |
|---|---|---|---|---|
| fib, N = 100,000 | 1,053 ms, 1,045 ms | 973 ms, 959 ms | 345,296 | 6,451 blocks, 665,616 bytes, 20 pages (1.3 MB) |
| bank, 2,000,000 transfers | 439 ms, 420 ms | 448 ms, 442 ms | 982,880 | 2,265 blocks, 1,130,496 bytes, 24 pages (1.6 MB) |
| fourteen, 300 rounds | 494 ms, 489 ms | 467 ms, 462 ms | 416 | 17 blocks, 720 bytes, 4 pages |
| big daddy, 300 rounds | 1,819 ms, 1,807 ms | 2,048 ms, 1,909 ms | 900,584,144 | 14,707,232 blocks, 1,215,044,400 bytes, 18,546 pages (1.2 GB) |
| big daddy again | 1,795 ms, 1,782 ms | 2,036 ms, 2,027 ms | | |

fib, bank and fourteen are within the box's noise (their runs spread by 20% and more). Big daddy, which allocates 14.7 million blocks, is about 6 to 14% slower: the allocator's fast path is 25 instructions with its kind's entry where the bump was 7 (it keeps `rcx` and `rdx`, takes the class by `bsr`, writes the header), and it touches 1.35 times the memory.

## Lane 2, as built (2026-11-27)

`roc/Heap.roc` holds all of it; its header is the collector's home. The heap's layout is lane 1's, with these changes: each class has 32 bytes in the state (its next block, its block size and its free list), the state keeps the collector's counts, its threshold, the free pages' runs and the stack's base, and the mapping is 3 GiB, the heap's 2 then the mark stack.

- **When:** the allocator counts every block's bytes (a small block's block size, a large block's pages) into the bytes in use, which a collection sets to the bytes it found live. Past the threshold, twice those live bytes and at least 8 MiB, the allocator collects before it takes the block. That is the design's "doubled since the last live size", with the floor.
- **The roots** (`runtime_gc_collect`): every general register but `r12` to `r15` (the runtime's, which hold no block) and all 16 xmm registers (Forwarding may leave a value in one across a routine's call) are pushed, then every word from `rsp` to the stack's base, the program's entry `rsp`, kept at the start. Then the runtime's places past `r13` before its buffer (`Heap.runtime_roots_size`, 64 bytes): of them only the timers' list (an array's record, raw) holds a block. The inspect depth, the handler record's address (on the stack, which is scanned anyway), the clock and the counts are scalars. Nothing else outside the stack holds a block: the program's globals are slots of the main function's frame, literals and static closures are in the read-only segment, and the heap's own state holds no block's address. A word counts with its tag cleared when its top 16 bits are 0xFFFA or more, else as it is; `Heap.block_start` takes it from there, so an address outside the heap, in a free block or in a free page is no pointer.
- **The mark is the header's bit 47**, not a side bitmap: the header is read anyway to trace the block (its kind and its size), the sweep reads every header anyway, and no other structure needs keeping in step with the pages. Bytes asked fit 47 bits (an expect holds the heap below 2^47). The walk rejects any header with the bit set, so no mark survives a collection.
- **The mark stack** lies past `r14`, 1 GiB: one 8-byte entry for each 16 bytes of heap, so it holds every block the heap could and never overflows. A block is pushed only when first marked, and not at all when its kind holds no pointer (a string, a table).
- **The trace is by kind** (`trace_from`): every word of the block's bytes asked from a kind's first field that may hold a value or a raw address is read as a root is. An array's record from 16 (its items' address, then the room for its first items), an object's from 16 (its entries' and its table's addresses, the count covered, its first entries), a closure's from 24 (its cells' addresses), and every word of the items, entries, cells, collections and their entries, iterators, timers and texts. Words past a list's length (items popped, room not used yet) are read too: they can only keep garbage, never free what is used.
- **The sweep** (`runtime_gc_sweep`) drops every class's free list and its bump page and builds the lists again, page by page in address order. On a page of blocks, a marked block's mark is cleared; an unmarked one is zeroed and linked, with the blocks already free (header 0), onto the page's chain, which joins its class's list. A page with no block kept becomes a free page instead (its links cleared). A dead large block's header and bytes are zeroed and its pages marked free. Free pages next to each other make one run, its first page holding the next run's address and its count of pages; a run at the heap's end lowers the next free page instead. **A free block is 0 but for its link**, and a free page 0 but for a run's two words, so the allocator's answer is all 0, as lane 1's code relies on.
- **The allocator** pops its class's free list first (clearing the link), then bumps through its page, then takes a page; pages come from the runs first fit (a run of just that many taken whole, a longer one giving its last pages), then from the heap's end.
- **The walk** now accepts a block not taken anywhere in a page: it must be 0 past its link, and it is counted free unless it lies at or past its class's next block in that class's bump page, where its link must be 0 too. Free pages are counted. Then every class's free list is followed (each block below the next free page, header 0, in a page of its class, at a multiple of its size, never more blocks than counted, so a loop stops) and must hold exactly the free blocks counted, and the runs (at a page's start, at least a page, every page marked 0) exactly the free pages. `heapstat` adds the most pages reached and the collections run.
- **The torture tier:** the first argument `gcalways` sets the threshold to 0, so every allocation collects, and walks the heap after each collection. x86/programs.shale runs every program of x86/tests, x86/tests/refused (the `// stops:` ones) and the corpus with it after `heapwalk`, held to node the same; all matched on the first run. x86/tests/join.js is left out of it, named in TORTURE_SKIPPED: its 420,000 allocations over 335 pages take minutes. The tier adds about 40 s to programs.shale (57-map-set-churn is the slowest, about 10 s).

**Planted, and what the tier saw.** Each was put in, x86/programs.shale run, and taken out:
- **A kind's trace left out** (`Cell => Untraced`): 10 programs of x86/tests failed under `gcalways` (array-methods, class-fields, class-methods, classes, collections, method_near_misses, object-table, property-update, string-methods-dynamic, timers: wrong output, a stop, or a crash), every one of them still passing under `heapwalk` alone.
- **A runtime root left out** (the places past `r13` not scanned): timers.js crashed under `gcalways`, its timers' list freed.
- **A register left out** (`rsi`'s pushed word zeroed for the scan and put back after), and then **every register and xmm register left out** (the scan starting past them): nothing failed. At every allocation in these programs, each value a register holds is also somewhere on the stack, because Registers spills at calls and the routines save what they hold across the allocator. So the registers' roots are pushed for safety, and no test yet shows one is needed: a routine that keeps a block only in a register across an allocation would be the first.

**What it cost** (each the median of 7 runs, before and after alternated, niced; before is master e876665's executables, after this lane's, from its release driver; the box was loaded by other lanes, load 1.5 to 3.4, so the wall times spread widely and CPU is the better guide; fib again as 9 runs alone):

| race | before: wall, CPU | after: wall, CPU | after: heapstat |
|---|---|---|---|
| fib, N = 100,000 | 5,641 ms, 1,149 ms | 6,817 ms, 1,324 ms | 6,451 blocks, 20 pages, 0 collections |
| fib again (9 runs) | 1,088 ms, 980 ms | 1,132 ms, 1,108 ms | |
| bank, 2,000,000 transfers | 2,825 ms, 488 ms | 4,802 ms, 531 ms | 2,265 blocks, 24 pages, 0 collections |
| fourteen, 300 rounds | 1,241 ms, 511 ms | 1,063 ms, 505 ms | 17 blocks, 4 pages, 0 collections |
| big daddy, 300 rounds | 2,227 ms, 2,119 ms | 1,873 ms, 1,669 ms | 86,459 blocks taken at the exit, 135 pages at most (8.8 MB, was 18,546 pages, 1.2 GB), 149 collections |

Fib, bank and fourteen never reach the threshold, so they pay only the allocator's longer path (the bytes counted, the free list tested), a few instructions on their few thousand allocations; fib's 10% of CPU is more than that can explain and is likely the box's noise. Big daddy is about 20% faster in CPU: its heap stays within 135 pages instead of touching 1.2 GB.

**Big daddy past 300 rounds** (this lane's executables, niced, the box loaded): 1,000 rounds 7.2 s wall, 5.5 s CPU, 499 collections; 3,000 rounds 25.5 s wall, 15.9 s CPU, 1,499 collections; 10,000 rounds, the race's full size, 58.9 s wall, 47.5 s CPU, 4,999 collections, its ledgers node's (LEDGERS["10000"]). Each held at most 135 pages (8.8 MB): about 5.5 ms of CPU a round at every size, so the collector's cost doesn't grow with the run.

**For lane 3:** the floor (8 MiB) sets big daddy's pace, one collection about every two rounds while its live heap is about 5 MB; the doubling rule alone would collect more often. A collection's sweep visits every block of every page, so its cost follows the heap's pages, not the live bytes; a page's free blocks could be swept lazily, at its allocation. Pages wholly free are kept, not given back to the kernel (`madvise`); the peak is small enough now that it hasn't mattered. Runs of free pages coalesce only at a sweep.

## Lane 3: the trigger, the register roots, the sampled torture and the counts (2026-11-27)

`shale x86/collector.shale` is the measurement, re-runnable: each race compiled by one or more drivers (`drivers=label:path,...` on stdin, js-x86 executables; this tree's own unset), run niced and alternated under `/usr/bin/time`, the medians of wall time, CPU time and peak resident memory, node beside them with `node=1`, and each executable's `heapstat` line. The figures below are preliminary: two other lanes were running, and the load was 1.9 to 3.0.

**The trigger.** The threshold is `max(growth × live, floor)` (`Heap.roc`'s `growth` and `least_threshold`). Six settings, each its own driver, big daddy run by each in turn. At 300 rounds, 5 runs each (load 2.6 to 3.0):

| floor, growth | wall | CPU | peak RSS | collections | pages at most |
|---|---|---|---|---|---|
| 8 MiB, 2x | 2,899 ms | 1,435 ms | 8.8 MB | 149 | 135 |
| 16 MiB, 2x | 2,874 ms | 1,383 ms | 17.3 MB | 73 | 265 |
| 32 MiB, 2x | 2,958 ms | 1,432 ms | 33.9 MB | 36 | 519 |
| 64 MiB, 2x | 2,996 ms | 1,491 ms | 67.5 MB | 18 | 1,031 |
| 8 MiB, 3x | 2,932 ms | 1,425 ms | 8.8 MB | 149 | 135 |
| 16 MiB, 4x | 2,957 ms | 1,440 ms | 17.3 MB | 73 | 265 |
| node | 2,190 ms | 1,209 ms | 92.0 MB | | |

At 10,000 rounds, the full size, 3 runs each (load 3.0 to 1.9; the wall times spread with the load, so CPU is the guide):

| floor, growth | wall | CPU | peak RSS | collections | pages at most |
|---|---|---|---|---|---|
| 2 MiB, 2x | 56.3 s | 50.8 s | 3.3 MB | 22,534 | 50 |
| 4 MiB, 2x | 92.3 s | 50.5 s | 4.6 MB | 10,261 | 71 |
| 8 MiB, 2x | 73.9 s | 52.3 s | 8.8 MB | 4,999 | 135 |
| 16 MiB, 2x | 50.8 s | 48.6 s | 17.3 MB | 2,462 | 265 |
| 32 MiB, 2x | 57.4 s | 50.0 s | 34.1 MB | 1,218 | 521 |
| 64 MiB, 2x | 50.2 s | 48.5 s | 67.6 MB | 606 | 1,032 |
| node | 24.3 s | 21.6 s | 109.7 MB | | |

- **CPU doesn't follow the floor.** From 2 to 64 MiB the CPU stays within 48.5 to 52.3 s, a spread of 8% with no order to it, while the collections fall 37-fold and the peak grows 20-fold. A collection's cost is its sweep, which visits every page, and its mark, which visits what is live; big daddy's live heap is under 2.7 MiB at every collection (8 MiB at 3x collects exactly as 8 MiB at 2x, so 3 × live never passed 8 MiB), so the mark is small, and the pages swept come to about the same in all: fewer collections each sweep proportionally more pages (149 × 135 is 20,115 and 18 × 1,031 is 18,558 at 300 rounds).
- **The growth never binds on big daddy:** 3x and 4x collect as 2x with the same floor.
- **The choice: keep 8 MiB and 2x.** A bigger floor buys nothing measurable and doubles the peak each step; a smaller one saves 4 to 5 MB at two to four times the collections, and each collection's fixed costs (the stack's scan, every page swept) grow with a program's stack and heap, which big daddy's are too small to show. At 8 MiB big daddy peaks at 8.8 MB, about a twelfth of node's 109.7 MB at the same size. The doubling stays the design's rule; `growth` is now a named constant beside the floor.
- **Later, unmeasured:** a lazy sweep (a page's free blocks found when its class next needs one) and giving wholly free runs of pages back to the kernel (`madvise`). The peak RSS is already small, and the CPU shows no cost of the sweep that the floor moves, so neither is worth its code yet. Where the compiled day's 5 ms goes against node's 2.2 ms is the race's question (`x86/bigdaddy/README.md`): the collector's share is not separated from the program's here.

**A register-only root: no program reaches one, and the plants say why.** Lane 2 left every register out of the scan and nothing failed. The reason is three rules, each of which keeps a copy of every live block on the stack at every allocation:

1. **The compiled code keeps every value in its frame.** The lowering moves every value through its slot, Forwarding keeps every store and forgets every holding at a call, and Registers stores `r9` to `r11` and `rbx` to their places before every call (`Registers.roc`'s header, "What the frame still holds"). So at any call into the runtime, the program's values are on the stack.
2. **The allocator pushes `rcx` and `rdx` before it may collect** (and `rsi` on its large path), so whatever those hold is a stack word at the collection.
3. **A runtime routine pushes, or keeps in its frame, every block it holds across an allocation in another register,** with one exception: `runtime_items_of` (`LanguageRoutines.roc`), a string's characters made an array, holds the new array in `r11` while it allocates each character's string. It also holds the array's items' address, inside the same block, in `rdx`, which the allocator pushes.

The plants, each run over x86/tests/ under `gcalways` and taken out (a scratch script, 66 programs, join.js aside):
- **every register left out** (the scan starting past the 27 words pushed): 0 of 66 failed, as in lane 2;
- **every register left out, and the allocator's pushed `rcx` and `rdx` too** (the scan starting 3 words further): 4 failed, collections.js, parameters.js and spreads.js stopping at the walk and coercion.js printing otherwise, each through `runtime_items_of`'s array;
- **the allocator's `rcx` and `rdx` left out, the registers scanned:** 0 failed;
- **the allocator's `rcx` and `rdx` left out, every register scanned but `r11`:** the same 4 failed.

So the collector's pushed `r11` is a root that holds a live block, and the torture tier sees it go, but only once the allocator's copy of `rdx` is hidden too. No test can fail by dropping registers alone while rule 3 holds. A routine that kept a block in `rbx`, `rsi`, `r8` to `r11` or an xmm register alone across an allocation would be the first; `runtime_items_of` would be one if it indexed the array through `r11` and kept no `rdx`, and the tier would then hold the register scan. That change would shape the runtime toward a test, so it is left as a choice for Steve. (Since 2026-11-28 the exception is gone: a string's characters are the one-byte strings made once in the read-only segment, "Cheaper allocation" below, so `runtime_items_of` allocates nothing in its loop and holds no block across an allocation.)

**join.js and the SAT race under torture.** `gcsample`, a fourth mode, collects each time 64 KiB more are taken since the last collection (`Heap.sample_bytes`), with the walk after each, as `gcalways` does. x86/programs.shale runs TORTURE_SAMPLED's programs with it in `gcalways`'s place: join.js (620,174 allocations, 335 pages at most) in about 1.8 s of CPU, and the SAT race at its small size (267,792 allocations, 329 pages) in about 2.2 s. TORTURE_SKIPPED is gone: every program the gate runs is collected under one of the two.

**The counts against the interpreter's.** `heapstat` now writes the allocations of the whole run and, after a last collection that it leaves out of the count, what is live at the exit: `heap: <n> allocations, <n> collections, <n> pages at most; live at the exit: <n> blocks, <n> bytes asked, <n> bytes in blocks, <n> pages`. `shale x86/collector.shale counts=1` sets it beside js-vm's `--counts` (its dev build: the steps, the heap's cells, the cells live at the end, the collections):

| program | compiled: allocations, collections, live blocks at the exit | js-vm: cells, live at the end, collections |
|---|---|---|
| big daddy, 30 rounds | 1,470,541, 14, 1,029 | 2,118, 330, 252 |
| 33-string-append | 96, 0, 13 | 61, 52, 0 |
| 55-garbage | 9,077, 0, 74 | 1,099, 115, 25 |
| 57-map-set-churn | 50,646, 0, 51 | 158, 74, 0 |
| 60-many-instances | 14,160, 0, 191 | 1,024, 149, 7 |

The two count different things, so neither number checks the other directly; each is plausible for its representation:
- **A VM cell is an object, an instance, an array, a function, its environment, a captured variable's box, a Map, a Set, an iterator, an error, or one of the builtins** (`js/roc/Heap.roc`'s `Cell`); a string is a Roc value inside one, never a cell. A compiled block is any of the 13 kinds, strings first: every string made (each `String(n)`, each concatenation, each character) is a block, an array that grows is a record and then a list of items, an object a record, its entries and, from 8 keys, its table. So the compiled program allocates many more: big daddy's census writes and parses 200 lines of text a day.
- **The VM's heap holds its library and every function made:** each builtin function and namespace (`Math`, `String.fromCharCode`) is a cell, and a function made is a `Fun` cell and an `Environment` cell. The compiled program's builtins are code, and a function known before the run sits in the read-only segment, no block. So 33-string-append, a few strings, keeps 52 cells live and 13 blocks.
- **The VM's live count is exact; the compiled one is conservative,** every word of the stack that looks like a block's address counted. Both include what the program's globals still reach.
- **The collections differ by the triggers:** the VM collects at twice what it kept and at least 1,024 cells (`Machine.roc`'s `is_collection_due`), so a program of a few thousand cells collects a few times; the compiled program first collects past 8 MiB, which these four corpus programs never take.

Both are stable: each compiled line came out the same in 5 runs, the heap's address moving with each. x86/programs.shale holds the four corpus programs' lines exactly (HEAP_HELD).

## Cheaper allocation (2026-11-28)

Item 3 of x86/bigdaddy/README.md's ranked next work: two general rules, neither shaped to a race.

- **The one-byte strings are made once.** The 256 strings of one byte lie in the read-only segment, each its length (1) in 8 bytes then its byte, 9 bytes apart (`RuntimeBuilders.one_byte_texts`, laid down by RuntimeTexts; 2,304 bytes). An index or `charAt` of a string, a walk of its characters (`runtime_items_of`: `for ... of`, a spread, `Array.from`), a split piece of one byte (and one of none, which is the empty literal), a slice or `substring` of one byte, a number of one digit and `String.fromCharCode` of one code answer one of them, and allocate nothing. `runtime_concat` answers a string and the empty string with the string itself, since a string never changes once made. The collector needs no change: a static string is outside the heap, as every literal is, so `Heap.block_start` finds no block for it, and nothing marks or frees it. Equality and Map, Set and object keys compare a string's bytes, so the table's string, a literal and a built string of the same byte are the same key (x86/tests/one-byte-strings.js).
- **An allocation whose size is known is in line** (`Heap.allocate_known_items`). The size class and the header are chosen when the runtime is built; the code in line adds the class's block size to the bytes in use and compares it with the threshold, pops the class's free list or bumps its page (a next block at a page's start, low 16 bits 0, means full or none), then writes the header and the count of allocations, as the shared path does, changing `rax` and `rdi` alone. Past the threshold, on a full page, or for a block past a page of blocks, it calls the shared path, which counts the block from the start, so the counts, the trigger, the free lists and the pages are kept exactly. The torture tier needs nothing: its threshold is 0, so every allocation takes the shared path and collects. Used by `runtime_new_array` (and its Int32 and Numbers twins) for at most 4 items, `runtime_new_object` and `runtime_new_cell`.

**The counts** (`shale x86/cost.shale counted=1`, master fa2fda0 against this lane). "In the allocator" is every place of `runtime_allocate_*`, `runtime_take_pages*` and `runtime_block_start*`, and the in-line paths' own places (`*_alloc`, `_alloc_bump`, `_alloc_header`, `_alloc_shared`):

| race | instructions run, before | after | in the allocator, before | after | predicted cycles, before | after |
|---|---|---|---|---|---|---|
| fib 100,000 | 9,415,873,498 | 9,415,728,206 | 245,889 | 130,983 | 3,348,651,132 | 3,348,617,166 |
| bank 2,000,000 | 2,760,324,551 | 2,760,319,429 | 86,982 | 78,241 | 770,806,566 | 770,805,550 |
| fourteen 300 | 1,984,730,118 | 1,984,730,119 | 798 | 747 | 895,982,651 | 895,982,652 |
| big daddy 300 | 4,085,933,251 | 3,873,443,548 | 569,726,016 | 418,723,214 | 1,186,109,055 | 1,142,105,776 |
| SAT small | 2,723,707,216 | 2,719,317,407 | 40,443,665 | 37,398,155 | 823,841,432 | 822,929,487 |

Big daddy runs 5.2% fewer instructions, 26% fewer in the allocator, and the model predicts 3.7% fewer cycles. The shared path ran about 14.7 million times before and 5.8 million after (its `runtime_allocate_kind` block, 21 instructions); string blocks fell from about 5.5 million to 4.5 million. The sweep (`runtime_gc_sweep_*`) is now the runtime's biggest cost there.

**The bytes:** every executable carries the table and the longer routines, 3,037 bytes more: fib 31,328 to 34,365, bank 44,956 to 47,993, fourteen 30,094 to 33,131, big daddy 91,226 to 94,263, SAT small 247,938 to 250,975.
