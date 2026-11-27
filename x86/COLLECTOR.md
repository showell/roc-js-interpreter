# A collector for js-x86 (milestone 5): the design

The code here was written by AI coding agents (Claude), with human supervision.

This is the agreed design for the compiled programs' garbage collector. Steve accepted it on 2026-11-26 with four decisions:
- conservative roots and a non-moving mark-sweep, not exact stack maps and a moving collector;
- a header word on every heap block;
- a GC-torture tier in the gate, which collects at every allocation, at small sizes;
- lane 1 starts on a quiet tree, not beside other compiler lanes.

Lanes 1 and 2 are in (2026-11-27): headers and size-class pages, then the mark, the sweep and the torture tier; "Lane 1, as built" and "Lane 2, as built" at the end say what each is and what it cost. Trigger tuning (lane 3) and the book (lane 4) are not done yet.

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

- **The header:** 8 bytes before every block's contents, the kind's code (`Heap.BlockKind`: string 1, array 2, items 3, object 4, entries 5, table 6, closure 7, cell 8, collection 9, collection entries 10, iterator 11, timer 12, texts 13, a routine's list of raw string addresses) in the top 16 bits and the bytes asked, rounded up to 8, in the low 48. Each of the 33 allocation sites names its kind (`Heap.allocate(String)`), an entry that loads the kind's bits and joins the shared path. The allocator still answers the address past the header, so every layout the runtime reads is as it was, and a value's address is its header's plus 8.
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
