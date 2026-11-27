# The big-daddy race

The code here was written by AI coding agents (Claude), with human supervision.

`bigdaddy_race.js` is a breadth race. The fib and fourteen races are narrowly arithmetic, and the bank race is one loop of method calls; this one asks for everything at once: strings built and taken apart, objects and destructuring, closures, Map and Set, exceptions, merge sort and `sort`, a Dijkstra walk over a street map, a sieve, word counts and the timers. The point is to find where the compiled program is weak, not to flatter it.

**It is a fork of `js/tests/54-big-daddy.js`**, "a day in a little simulated city". It started as 54 in a loop, and it is its own program from here on: it may drift from 54 where the comparison with node suggests, and it never feeds back into `js/tests/`. The rule of the races still holds: ordinary JavaScript, changed to probe where we are weak, never shaped toward our compiler.

- **The day** is 54's six stages in one function, `day(seed, talk)`, run `ROUNDS` times with the seed `2026 + round`, so no two days build the same city. The stages are 54's: the census (written as text and parsed back), the clerk's lookups (a TypeError and a RangeError caught), the sort, the streets, the sieve and the newsletter's words, and the evening's light count, a plain loop in each day.
- **Printing stays out of the timed work.** The first day talks: it prints 54's transcript, `console.log` of nested objects and a Map included. The other days print nothing.
- **The checksums.** Each stage's checksum goes into a ledger of its own across the days. At the end the program prints the seven ledgers and the ledgers combined.
- **The timers run once**, after the last day, over the last city: a timeout cleared, an interval ticking 19:00 to 22:00, and the midnight report. Their delays are 0, since 54's 250 ms and 1.5 s would be sleep, not work, and the report is scheduled from the last tick, so its order never depends on the clock.
- **The crow's distance is printed in whole hundredths** (`Math.round(straight * 100)`, 1131), where 54 prints `/ 100` (11.31). js-x86's executables can't print a fraction yet (milestone 4, number printing), and Steve chose this way around it over dropping the clause. No checksum ever saw the number.

From the repository's root:

    shale x86/bigdaddy.shale                  # 15,000 rounds, the full size, about 25 s under node
    shale x86/bigdaddy.shale size=small       # 30 rounds, about 0.3 s under node, for tuning
    shale x86/bigdaddy.shale rounds=300       # any count of at least 1
    shale x86/bigdaddy.shale size=small runs=5   # five runs of each in turn, and the medians

The contestants are the program compiled by js-x86 and the same program under node. Should js-x86 refuse it, the script prints `compiled: not compiled yet:` and the refusal, and times node alone. node's last two lines are held to the ledgers stored in the script for 15,000, 10,000, 300 and 30 rounds, and the compiled program's whole output is held to node's.

**The full size is 15,000 rounds** (2026-11-27), the file's own `ROUNDS`. It was 300 until the collector landed (Steve, 2026-11-26: race at 300 now, design the collector next), with 10,000 the goal. Every race should run at least 20 s (Steve), and 10,000 doesn't reach it on this box: node ran it in 17.7 s of wall time and 16.6 s of CPU at a load of 3 to 8 (one run, niced), and earlier in 19.95 s wall at a load of 2.0 and 21.6 s of CPU at 1.9 to 3.0. node's CPU at 15,000 rounds was 28.3 s at a load of 3 to 4, so about 25 s on a quiet box, with room under it. The work a round does is the same at every count (each day is its own city), so the size only lengthens the race.

## Sizes (2026-11-26)

`SIZE` is 10 (200 residents, a 9x9 street map, a sieve to 3,000, a 40-issue newsletter), and `ROUNDS` scales the work. At SIZE 10 node runs a day in about 1.8 ms once warm.

| rounds | node | js-vm (release, context) |
|---|---|---|
| 30 (`size=small`) | 0.34 to 0.38 s (load 1.5); 0.53 s once at load 2 | 3.54 s |
| 60 | 0.42 s | 6.24 s |
| 4,000 | 7.27 s (load 2.1) | |
| 10,000 (as written) | 19.95 s (load 2.0) | |

The box was shared all along (another lane compiling, load 1.5 to 2.1), so these are single runs, not medians. js-vm is the bytecode VM's release build, 9040235960356694, after 34af33f; node and js-vm print the same output at 3, 30 and 60 rounds. js-vm is not a contestant: its number is here for context, about 10 to 15 times node at the small size.

**Found on the way:** js-vm's `lastIndexOf` gave a fraction far into an array (2999.0000000000005 at the sieve's 3,000), which held this race up until master's 34af33f fixed it.

## What stops the compiled program (2026-11-26, master 9287a30)

Found by compiling a copy of the race with js-x86 and, at each refusal or stop, changing the copy by hand to reach the next. The copies were scratch and are not committed. In the order met, which is also the order I'd fix them:

1. **`UpdateProperty`, `o.k++`.** *Done 2026-11-26*: `runtime_update_property_hashed` reads the property, holds it to a number, steps it and writes it back, by the runtime's hashed read and write (the in-line field places of FieldSlots are not used for it yet). The race and 54 then meet blocker 2. One site: line 151, `entry.people++`. The first refusal, as it is 54's. **Small:** the compiler's `GetProperty`/`SetField` pair with the `++` between, as compound assignment to a property (`stats.perks += ...`, `entry.totalAge += age`) is already compiled; it touches Lowering's property instructions and FieldSlots.
2. **A function with more loops than the widenings allow.** *Done 2026-11-26*: each loop's head has its own `most_widenings` (16), counted by its instruction, so the cap of a function grows with its count of loop heads (x86/README.md, where a loop's head widens; x86/tests/loops-many-heads.js and refused/loop-widenings.js hold it). Before that, `the function \`day\`: a loop's kinds never settle, at instruction N`: Lowering's `code_items` widened one loop's head a walk and gave up after 16 walks for the whole function, and `day` has about 20 loops (54's top level the same). The instruction it named was only the last head widened, and none of the loops was at fault. To reach past it a scratch copy split `day` into a function a stage.
3. **A string's `padEnd`.** *Done 2026-11-26*, with 4: `padEnd` is one of the methods StringMethods' table holds. One site: line 349, `"headline:".padEnd(12)`. A refusal: `the method \`padEnd\` of a string is not compiled yet`. **Small:** a runtime routine beside the string methods already written; it touches MethodTables and the string runtime. (The copy used the literal `"headline:   "`.)
4. **A string's methods on a value whose kind isn't known.** *Done 2026-11-26*: `runtime_string_method` (x86/README.md, "A string's methods") calls a string method's routine when the value is a string, and the value's own property otherwise; `trim`, `trimStart`, `trimEnd`, `toUpperCase`, `toLowerCase`, `substring`, `repeat`, `padStart`, `padEnd`, `startsWith`, `endsWith`, `replace`, `replaceAll` and a known string's `concat` are written, and 18 and 59 of the corpus match node with them. Before that, the program compiled, and its executable stops at once with `x86: this property read is not compiled yet`, at `line.trim()` (line 104), whose `line` is an item of `split`'s array, so a `Value`. `runtime_get_property` (Runtime.roc's `property_items`) reads only a string's or an array's `length`, an object's property and a Map's or Set's `size`; it has no way to a string method when the receiver's kind is found as the program runs. **Medium:** a dynamic dispatch of the string methods, which also needs each method itself: x86/README.md's corpus list names `trim` and `toUpperCase` as not written. The sites that will meet it: `trim` (104, 105), `split` (103, 105, 335), `charCodeAt` (31, 52), `toUpperCase` (331), `toLowerCase` (336), `replaceAll` (337), `slice` and `indexOf` of a string (349). It touches MethodTables and Runtime's property and method routines.

I stopped there, so whatever lay past 4 was not known then. The guesses made then (array destructuring with a default, the object rest pattern, the catch pattern, labelled `break`, `do ... while`, `**`) all compile, as the next section found.

## What it meets now (2026-11-26, after blockers 1 to 4)

**The race compiles as written**, `day` one function, and its executable prints what node prints, byte for byte. `shale x86/bigdaddy.shale size=small runs=5` on the box at a load of 0.5 to 0.7, the medians of five: compiled 0.19 s, node 0.35 s, compiled/node 0.55 (the executable 80,396 bytes). Earlier, with `day` split into a function a stage (a scratch copy, not committed), at a load of 2.2 to 2.7, five runs at 30 rounds and three at 300, the compiled program then node:

| rounds | compiled | node |
|---|---|---|
| 30 (`size=small`) | 150 to 164 ms (148 to 160 ms CPU) | 183 to 196 ms |
| 300 | 1,543 to 1,872 ms (1,482 to 1,644 ms CPU) | 697 to 833 ms |

So the compiled day costs about 5 ms to node's warm 2.4 ms: about twice node, once node's start (about 0.13 s) is paid. At 30 rounds the start hides it. Which stage dominates is not measured yet.

**Memory was the race's wall until the collector** (x86/COLLECTOR.md, lane 2). A day allocates about 2 to 3.5 MB, and with no collector 300 rounds filled most of the heap and past about 600 the executable stopped, out of memory. With it, the race runs at its full size (below, "At full size").

**54 compiles too** and stops where node prints its first fraction, the crow's 7.07 (milestone 4, number printing), so it stays out of the corpus (x86/README.md's table).

**Milestone 4 (fractions):** the crow's distance was the race's one fraction printed, and it prints whole hundredths (above). Nothing else in the race prints or checksums a fraction: every ledger is an integer below 1,000,003.

## At full size (2026-11-27, master f724c41)

The compiled program's whole output is node's, byte for byte, at 15,000 rounds (`shale x86/bigdaddy.shale`) and at 10,000 (`shale x86/collector.shale races=bigdaddy rounds=10000 runs=1 node=1`); nothing stopped it, so this lane fixed nothing and added no program to x86/tests. The collector's counts, from the executable's `heapstat` (counts, not timings):

| rounds | allocations | collections | pages at most | peak RSS | live at the exit |
|---|---|---|---|---|---|
| 10,000 | 490,201,329 | 4,999 | 135 (8.8 MB) | 8.8 MB (node: 105.9 MB) | 1,031 blocks, 103,232 bytes in blocks |
| 15,000 | 735,302,387 | 7,499 | 135 (8.8 MB) | | 1,033 blocks, 103,296 bytes in blocks |

About 49,000 allocations a day and one collection every two days, at every size: the heap's peak doesn't grow with the run, and it is about a twelfth of node's. The time spent collecting isn't a timing here; its share of the work is in the ranking below (the sweep about 11% of the instructions run and 16% of the samples, the mark under 1%).

## Where we're weak against node: the next work (2026-11-27)

Two readings, at master f724c41. **The counts** are exact: `shale x86/cost.shale counted=1 races=bigdaddy`, at 300 rounds, 6,917,983,458 instructions run, 90% of them in the runtime and 10% in the program's own code (x86/COST.md, "The counter"). **The samples** are a guide: `shale x86/profile.shale race=bigdaddy size=1000`, one run, 4,143 samples. The program's own code is not where we're weak: its hottest function, `code_24`, is 3.9% of the instructions, and the kinds (tags, untags, converts, the runtime's kind routines) are 4.5% of the samples. Three costs dominate, in order:

1. **A Map's or a Set's key is found by a linear search, its strings compared a byte at a time.** `runtime_collection_find_*` is 31.5% of the instructions run (`_next` alone 26.3%) and 17% of the samples; `runtime_text_equal*` another 15.3% and 14%, most of it called from that search. The streets' Dijkstra keeps about 80 corners in Maps and Sets keyed by strings (`${x},${y}`, made fresh each time, so no two keys share an address) and asks `distance.get` and `done.has` inside its scan of `distance`: each lookup walks the entries in order, and each entry of the same length is compared byte by byte. node hashes. **The change:** a hashed index beside a Map's or a Set's entries, as an object has past 8 keys (`ObjectTable.roc`, FNV-1a by `runtime_text_hash`), the entries kept in their order for the walks; a number key hashed by its bits (with -0 made 0, as now). And `runtime_text_equal` comparing 8 bytes a step once the lengths match. Every program with a Map past a few entries gains, the SAT race's gate Map among them (x86/satrace/TRIAGE.md).
2. **The collector's sweep.** `runtime_gc_*` is 11.3% of the instructions (`runtime_gc_sweep_zero` 6.6%, the per-block walk 1.6%, the links 2.5%) and about 16% of the samples; the mark (the stack's scan and the trace) is under 1%, since the live heap is small. Each collection visits every block of every page, and zeroes every dead block word by word, since the allocator's answer must be 0: at one collection every two days, it writes the whole dead heap, about 8 MB, once per collection. **The change:** a lazy sweep, a page swept when its class next needs a block, and a block zeroed when it is allocated (its cache lines are about to be written anyway), not when it dies; a wholly free page zeroed in one `rep stosq`, or given back to the kernel. x86/COLLECTOR.md's lane 3 named the lazy sweep as later work; this is the measurement that makes it next.
3. **Allocation: its fast path and its count.** 49,000 allocations a day. The allocator (`runtime_allocate_*`, `runtime_block_start`) is 7.9% of the instructions and about 9.5% of the samples, about 37 instructions an allocation, where a bump is a handful: the kind's entry, the class taken by `bsr`, the bytes counted against the threshold, the free list tried, then the bump, the header written. Around it, the strings made a character or a digit at a time (`runtime_concat` 4.5% of the samples, `runtime_number_digit` 3.4%, the splits 4%) are allocations too: every character of `for (const ch of String(value))` is a new string block. **The change:** for a site whose size is known when it compiles (a character, a record, an array's first room), the class and the header chosen then, and the bump done in line, the shared path only on a page's end; and the one-byte strings made once, in the read-only segment, so a string's walk, `charAt`, an index into a string and a one-byte split piece allocate nothing.

None of the three is built in this lane. Each is a runtime change, general to every program; the race isn't changed toward any of them.

## Candidates for Steve (not made)

- **A per-stage timing under node** wasn't done, for want of time on a busy box; it would show which stage dominates. A guess from reading the code: the census (200 lines of text built, split and parsed, every checksum's `String(value)` walked a character at a time) and the two sorts dominate, and the sieve (3,000 booleans) and the clerk (four lookups) are too small to measure. If so, the clerk could do its lookups over every resident, and the sieve could grow on its own.
- **`day` stays one function of about 20 loops.** That is ordinary code, and it compiles now as written; splitting it would shape the program toward the compiler.
