# A collector for js-x86 (milestone 5): the design

The code here was written by AI coding agents (Claude), with human supervision.

This is the agreed design for the compiled programs' garbage collector. Steve accepted it on 2026-11-26 with four decisions:
- conservative roots and a non-moving mark-sweep, not exact stack maps and a moving collector;
- a header word on every heap block;
- a GC-torture tier in the gate, which collects at every allocation, at small sizes;
- lane 1 starts on a quiet tree, not beside other compiler lanes.

Lane 1 is in (2026-11-27): headers and size-class pages, still never freeing; "Lane 1, as built" at the end says what it is and what it cost. Nothing else below is built yet.

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
