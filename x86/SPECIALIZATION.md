# Type specialization for js-x86 (milestone 6): the design

The code here was written by AI coding agents (Claude), with human supervision.

This is the design for milestone 6: values that keep known number kinds through arrays and objects. Steve accepted it on 2026-11-27 with all seven decisions at the end. Lanes 1 to 3 are built ("Lane 1, as built", "Lane 2, as built" and "Lane 3, as built", the last sections). It follows x86/COLLECTOR.md's shape: why now, what the compiled program looks like, the designs compared, the one I'd build, how it is checked, the lanes, and the decisions for Steve.

**Every number here is preliminary.** The box's load average went from 0.2 to 8.3 while I measured (other lanes compiling). The profiles count CPU time, so their shares hold up under load. The kernel timings are medians of 7 alternated runs at a load of 2.6 to 3.4.

## Why now

### How it was measured

`shale x86/profile.shale race=<name>` (new, measurement only) compiles a race with the dev driver, whose executables are the release driver's byte for byte. It runs the executable with the argument `profile` (x86/roc/Profiler.roc, a sample each millisecond of CPU) and sorts each sample by what its instruction does for the kinds:

- **tag**: a tag's test or constant (`shr r, 0x30`, `cmp r, 0xfff9`..`0xfffe`, a tag's bits loaded), and the jump after it;
- **untag**: a pointer's tag cleared (`shl r, 0x10` then `shr r, 0x10`);
- **convert**: `cvttsd2si`, `cvtsi2sd`, and a whole-number test (the `ucomisd` after a `cvtsi2sd`, its `jp` and `jne`);
- **runtime kinds**: a routine whose job is a kind found as the program runs (`runtime_add`, `runtime_strict_equal`, `runtime_truthy`, `runtime_word_of`, `runtime_check_number`, and the like);
- **runtime lookups**: a property's or key's search (hashing, probes, key compares); **runtime heap**: the allocator and the collector.

The classes are a lower bound. The moves that feed a tag test, and an index computed with `mulsd` and `addsd` because it is a double, count as "other". `x86/profile.shale` takes over from x86/satprofile.shale, which profiled the SAT race alone; `race=sat size=race` does what that script's `workload=race` did.

### Where each race's time goes

| race (size) | CPU, samples | tag | untag | convert | runtime kinds | **kinds in all** | what holds the rest |
|---|---|---|---|---|---|---|---|
| fib (N = 200,000) | 5,067 ms, 5,074 | 0 | 4.7% | 0 | 0 | **4.7%** | `addInto`'s arithmetic (95%) |
| bank (10,000,000 transfers) | 2,119 ms, 2,145 | 3.0% | 3.2% | 11.2% | 0.9% | **18.3%** | lookups 32% (the dictionary's string hashing 10.5%, probes 9%) |
| fourteen (1,000 rounds) | 1,732 ms, 1,727 | 0.2% | 0.2% | 4.9% | 0 | **5.3%** | the division and the dispatch |
| big daddy (300 rounds) | 1,552 ms, 1,555 | 0.3% | 0.1% | 1.2% | 1.5% | **3.1%** | the Map's linear search 19%, string compares 15%, the collector's sweep 15%, allocation 10% |
| sat (small, 4 rounds) | 2,686 ms, 2,712 | 6.1% | 2.6% | 16.4% | 2.3% | **27.4%** | the two loads that miss the cache 8%, the gate Map 7% |

In sat, `propagate` holds 53% of the samples. Within it the kind classes are 33% (convert 22%, tag 7%, untag 3%), and the two cache-missing loads TRIAGE.md found are another 15%.

### Known after a guard, or unknowable

- **sat: all of it is known after a guard.** Every array the solver keeps in `st` holds only whole numbers below 2^31 for the whole run (`unassigned`, `true_val` and `false_val` are 0, 1 and 2; literals, clause references, offsets and bit fields are all integers). `activity` is the exception: it holds doubles, but only doubles. No array in the program ever changes kind. The tests are paid because the arrays live in an object, so each local that holds one is a `Value` (satrace/TRIAGE.md, fix 4).
- **bank: known, but through fields and method results, not arrays.** The converts are `random.next() % COUNT` and its use as `names[...]`'s index (code 3 at 12, 13, 22, 23), `seed * MULTIPLIER % MODULUS` in `next` (code 9 at 6), and `step % AUDIT_EVERY`. `seed` only ever holds a whole number below 2^31, but it is a field, and `next` is a method, whose result is always a `Value`. Nothing here is an array's item.
- **fourteen: already known.** Its arrays are `Integers` today (x86/README.md, "An integer kind", step 4). What is left is representation: an item is kept as a double and made an integer by a `cvttsd2si` on each read.
- **fib: already known.** Its arrays are `Numbers`. The 4.7% is each item access untagging the array's address again, which is loop-invariant code motion, not specialization.
- **big daddy: mostly unknowable.** Its values really are mixed (strings, objects, Map entries). Its kinds share is 3%.

### A bound from a hand-made pair: the watch loop in miniature

`x86/specialization/heap_kinds.js` is propagate's watch loop in miniature: a blocker tested, a clause's literal read, flipped with `^ 1`, tested and written back. Its three arrays are held in an object, as `st` holds them. `local_kinds.js` is the same program with the arrays in the frame, passed to direct calls, where js-x86 already keeps them `Integers`. Both print node's lines at 40,000 repeats.

| | the sweep's static instructions | CPU, median of 7 alternated (load 2.6 to 3.4) | kind classes in its profile |
|---|---|---|---|
| arrays in an object (`Value`s) | 511, 14 calls | 2,030 ms | 41% |
| arrays in the frame (`Integers`) | 266, 3 calls | 1,216 ms (40% less) | 25% (the `cvttsd2si` of each item, the untags) |
| node | | about 0.49 s | |

So knowing the kinds takes 40% off this loop. The share of samples in the kind classes predicted it closely (41%). One item read of a `Value` array at a double index is 25 instructions: 14 of them test the array's tag, the index's tag and the index's wholeness, 3 untag, 3 test the bounds and 2 load. Known kinds leave the untag, the bounds and the load.

**What that means for the races:** sat is the one race type specialization would move. My estimate is 15 to 25% of its CPU: its kind classes are 27%, and the design below keeps a `cvttsd2si` on each read and adds guards. fib and fourteen are already specialized. Bank's kind cost is in fields and method results, and its larger gap is the dictionary's hashing (bank/TRIAGE.md, fix 4). Big daddy's gap is the Map's linear search and the sweep. Milestone 6 as first written said "for long numeric loops". The integer kind already did that for fib and fourteen. What remains is kinds through the heap, and that is sat's problem.

## What the compiled program looks like to this design

- **Every kind is fixed when a function is lowered.** The walk keeps a kind for each slot and each stack place. Where two ways meet, the kinds meet (`met_kind`). A guard that may fail can therefore only lead to code lowered with other kinds. Today no such second copy exists. The integer kind's design ruled out "deoptimization, lowering a function twice and moving between the two as it runs".
- **Arrays of known numbers exist, in the frame only.** `Numbers` and `Integers` (Lowering's `NUMBER-ONLY ARRAYS` and `INTEGER ARRAYS`) are a static rule for the whole program. An array literal keeps the kind while it stays in frames and direct calls. Any escape (stored in an object, returned, passed through a value) refuses the rule, and the whole program is lowered again with fewer: `IntegerItems`, then `NumberItems`, then `AnyItems`. sat stores every array in `st`, so it tries all three rules and lowers under `AnyItems` (buildrace/PROFILE.md: 3 rules, 12 passes, 2,103 walks).
- **Every value has its boxed bits wherever it is held.** A double is its own bits, so an array of numbers needs no other layout. Its items are doubles whatever is known of them. An `Integer` is the one kind with other bits: a raw integer, converted wherever it meets a value.
- **An array is a record** (its length, its capacity and its items' address) **in a block whose header says its kind** (Heap.roc: the kind's code in the top 16 bits, the mark in bit 47, the bytes asked in the low 47). The collector traces by that kind and the heap walk checks every header.
- **An out-of-range read of a `Numbers` array stops the program**, since its reads give numbers and `undefined` is none. Any design that spreads number kinds must not spread that stop to programs that run today.

## The candidate designs

### a) Element kinds in the array's header, guarded in versioned loops

Each array's header says what its items are: **Int32** (every item a double holding a whole number in -2^31 to 2^31 - 1, never -0), **Numbers** (every item a double), or **Values**. It works like V8's elements kinds (PACKED_SMI, PACKED_DOUBLE, PACKED_ELEMENTS), and a kind only falls, from Int32 to Numbers to Values. An empty literal, or a literal of whole numbers, starts at Int32. Every store keeps the header true: a store the compiler proves conforming is a plain store, and any other store (a runtime routine's, or a `Value`'s in line) tests the value and lowers the kind. The items stay NaN-boxed doubles, so every runtime routine reads them as it does now.

A loop that reads items of arrays held in `Value` slots is **lowered twice**: a fast copy, with those slots given guarded item kinds, and the generic copy, as today. At the loop's entry a guard tests each slot (the array's tag and the header's element kind) and enters the fast copy when they hold. Inside the fast copy, an item read is an `Integer` (one `cvttsd2si`), and a store of an `Integer` in range keeps the facts. A call, or a store the compiler can't prove conforming, drops the facts for the rest of that iteration. A read past the end, or a guard that fails after a call, is a **side exit**: a jump to the generic copy's label for that same instruction, each slot and stack place converted from its fast kind to its generic kind, as two ways meeting convert today.

- **Buys:** sat 15 to 25% (above). bank, fib, fourteen and big daddy about 0. Their loops hold no `Value` slot used as an array or a number, so nothing is versioned and they compile as today.
- **Correctness risk: low to medium, and checked as it runs.** A guard tests the facts at run time, so no proof about aliasing is needed. The risk is in two places. One is a store that doesn't lower the kind (a runtime routine missed). The heap walk can check every flagged array's items, so `heapwalk` and `gcalways` catch it. The other is a side exit's conversions; a torture mode that takes every exit catches those. JS semantics: a hole is no new risk (a write past the end already stops), a read past the end exits to the generic copy and gives `undefined`, `-0` is not Int32 (the test compares the round trip's bits, since `ucomisd` calls -0 equal to 0), NaN and integers past 2^31 are Numbers, and an array that changes kind mid-loop takes the exit.
- **Collector cost: small.** Two new block kinds, traced exactly as an array record is. The walk checks a flagged array's items, but only in its own modes.
- **Compile-time cost:** a versioned loop is walked twice and adds its exit stubs. A budget bounds it, as Inlining's does. sat's lowering might grow 5 to 10% (propagate's and lit_redundant's inner loops are a small part of 1,183 lines). Programs with nothing to guard pay only the search for a guard set.
- **Size:** four lanes (below). The side exits are the large and new part.

### b) Kind inference through the heap, for the whole program

Each array literal and object literal is an allocation site. The passes settle, per site, what its items or each field hold, the way they already settle parameters and results. A local read from `st.pool` is then "an array from site 7", whose items are `Integer`s. No guards are needed.

- **Buys:** a little more than (a) where it proves, with no guards, and it covers straight-line code (`push_watch`, `assign`) as well as loops. For sat, perhaps 20 to 30%. Bank's fields only if no dynamic-key write could reach them, and `accounts[name] = ...` defeats that.
- **Correctness risk: high.** Soundness depends on modelling every way a value can flow: callbacks of `map`, `sort` and `forEach`, spreads, rests, Map and Set values, `Object.values`, closures' cells, `for ... of`. A path missed gives wrong answers with no stop. It needs a checking build to be trusted. It also inherits the out-of-range stop, or must prove indexes in bounds. Ranges need widening thresholds (int32, uint32, ±2^53), or `base + 2 * i` falls back to doubles.
- **Collector cost:** none.
- **Compile-time cost: high.** Lowering is already the build's time (sat 1,108 ms, almost all of it walks). Site facts would add passes to a fixed point that already takes sat 12 passes over 3 rules. My estimate is 30 to 100% more lowering on sat and big daddy.
- **Size:** five or more lanes, mostly a reshaping of the kinds passes.

### c) Field kinds, extending FieldSlots

For a class's fields, and for object literal keys, learn what kind every write of that key stores, and read the field as that kind.

- **Buys:** bank's `seed` read as an `Integer`, so `next()` and its `%`s lose their whole-number tests and tags (most of bank's 18%, perhaps 10 to 15% of its CPU), and `st`'s scalar fields in sat (read outside the hot loops, a few percent).
- **Risk:** static by key name, it is poisoned by any dynamic-key write (`o[k] = v` with an unknown `k`), and bank has one. Guarded at the read, it is what the tag test already does.
- **Collector, compile time:** none; small.
- **Size:** two lanes. It needs (d) as well for bank, since `next`'s result is a method's.

### d) Functions cloned by their arguments' kinds

A function a value may hold (a method, a callback) gets a second body lowered with its direct calls' argument kinds, and a guard at its entry chooses between the two.

- **Buys:** bank's `deposit` and `withdraw` keep `amount` a number (bank/TRIAGE.md, fix 2, "what it doesn't do yet"), about 40 instructions of a transfer's 1,390. Nothing for sat: the kinds it lacks are inside `st`, not in arguments.
- **Risk:** medium. Method tables must hand the right entry, and code grows with each clone.
- **Collector:** none. **Compile time:** a walk per clone.
- **Size:** two lanes.

### e) Combinations

(a) and (c) share their guard machinery: a field read is a `Value` that a versioned loop could guard like any other. (a) then (b) would let a later proof remove guards that (a) placed, with (a)'s guards as the oracle while it is tried. I'd build (a) first, and measure before taking the others.

| | sat | bank | fourteen, fib, big daddy | correctness risk | collector | compile time | lanes |
|---|---|---|---|---|---|---|---|
| a) element kinds, versioned loops | 15 to 25% | 0 | 0 | low to medium, checked as it runs | 2 block kinds | +5 to 10% on sat, 0 elsewhere | 4 |
| b) whole-program inference | 20 to 30% | little | 0 | high, silent | none | +30 to 100% | 5+ |
| c) field kinds | a few % | 10 to 15% (with d) | 0 | medium | none | small | 2 |
| d) clones by argument kinds | 0 | about 3% | 0 | medium | none | a walk per clone | 2 |

## The design I'd propose: (a)

**1. Element kinds in the header.** The array record's block takes one of three kind codes: the array's (Values), an Int32 array's or a Numbers array's. All three are traced exactly as an array record is. The items block is unchanged.
- **Made:** an array literal of whole number literals, or an empty one, is Int32. A literal of numbers is Numbers. Any array a routine makes (`map`, `filter`, `slice`, `concat`, `split`, `Array.from`, a spread, a rest) is Values, unless the routine is taught otherwise later. Values is always safe.
- **Kept:** a store in line that the compiler proves conforming (an `Integer` within int32 into Int32, any number into Numbers) changes nothing. Every other store lowers the kind when the value doesn't conform: `runtime_set_index`, `push`, `splice`, `unshift`, and IndexLowering's in-line store of a `Value`. A routine that only moves items (`sort`, `reverse`, `pop`, `shift`) keeps it. The test is the round trip's bits (`cvttsd2si`, `cvtsi2sd`, `movq` and a compare of the bits), so -0 is not Int32.
- **Checked:** the heap walk, at an exit or after every collection under `gcalways`, holds every Int32 and Numbers array's items to their kind and stops naming the block when one doesn't. So the torture tier is the oracle for the stores.

**2. Versioned loops.** For each innermost loop, the **guard set** is the slots live at its head that hold a `Value` (or an `Array`) and that the body uses as an array whose items it reads, or as a number. If the set is empty, or the loop is over the budget, the loop is lowered once, as today, to the same bytes.
- **The fast copy** is the loop lowered with the guard set's slots given guarded kinds: an `Integer` of int32 or a `Number` for a scalar, guarded Int32 or Numbers items for an array. A guarded array's item read is an `Integer` (one `cvttsd2si` of the double) or a `Number`. Its index is an integer, its bounds one unsigned `cmp`, and its untagged address may be kept across the iteration.
- **The guard** sits at the loop's entry and, after an iteration that dropped facts, at the head again. Per array it is a tag test and a header load and compare, about 6 instructions; per scalar it is a tag test and a round trip, about 8.
- **Facts are dropped** at any call and any store not proven conforming. Every guarded array kind in the frame becomes `Array`, which needs no code, since the bits are the same. Items already read keep their kinds: a slot holds them.
- **Side exits:** a read past a guarded array's end, and a guard that fails at the head, jump to the generic copy at the same instruction. Each slot and stack place is converted from its fast kind to the generic copy's kind there; the fast copy's kinds always lie below them, so the conversion is the one `values_made` does today. Exits go only one way, from fast to generic, so a loop run that leaves the fast copy finishes in the generic one. The lowering checks each exit's conversions. Where one can't be made (a kind with no conversion, such as a function known by its code), the loop is not versioned, so versioning never refuses a program.
- **The budget**, in Lowering beside Inlining's constants: the most instructions a function may version, and the most for the program. `js-x86 "<program>" versioned` prints the loops versioned and their instructions, as `inlined` does.

**What it costs in the product:** a guard per loop entry (sat: once per propagated literal, about 45 instructions for its three arrays and its scalars, against more than 100 saved per watch visited); nothing in a loop that isn't versioned; the stores' kind upkeep on the generic way (a test of a few instructions on paths that already call the runtime).

**Left out, for later and measured on their own:** typed int32 items, which save the `cvttsd2si` of each read (at most about 5% on fourteen, and part of sat's remaining convert); versioning straight-line regions (`push_watch`, `assign`); field kinds (c) and method clones (d) for bank.

## How it would be checked

- **Every program still matches node,** through the whole gate, as today.
- **The heap walk holds the element kinds:** `heapwalk` and `gcalways` check every flagged array's items, so a store that forgot its upkeep fails at the next collection. It is planted once (one routine's upkeep left out) and must be seen red.
- **A guard torture mode:** `js-x86 "<program>" guardsflip` compiles every guard to fail after its loop's first iteration, so every side exit runs. `programs.shale` runs every program of x86/tests and the corpus compiled that way, held to node. It is a compile mode, so no product executable carries its test.
- **Held counts:** `programs.shale` holds the loops versioned across x86/tests, and each test's own count, as it holds `INLINED`.
- **Byte identity:** a program with nothing to guard compiles to the same bytes as before (`shale x86/buildtime.shale parts=identity`, its manifest of 183 programs). I'd expect fib, bank and fourteen among them, and so racing exactly as now.
- **New tests in x86/tests:** arrays that change kind every way (a string pushed into an Int32 array, a fraction, -0, 2^31, `splice` with values, `sort` with a function), a call in a loop that changes a guarded array's kind mid-loop, two names for one array, a read past the end in a versioned loop, guard sets at the budget's edges, and the near misses that must not be versioned.
- **The races:** the profile again on all five (the kinds classes should fall on sat and stay where they are elsewhere), the five races' CPU alternated with master's, and the build race.

## The lanes, in order

1. **Element kinds in the header** (small to medium; output identical, and only the runtime's bytes change). Three kind codes, set where arrays are made, kept by every store, checked by the heap walk. Nothing reads them yet. Measure the upkeep on the five races (it should be within noise). Tests for every transition; the planted missing upkeep.
2. **Versioned loops on scalars** (medium). The two copies and the entry guard, for slots that are loop-invariant `Value`s used as numbers (sat's `nw`, `base` and `dl`, so `i` and `j` become `Integer`s). An invariant slot can't change inside the loop, so this lane needs no side exits. The budget, the `versioned` count and byte identity for every program with nothing to guard.
3. **Guarded arrays and side exits** (large; the core). Guarded item kinds, facts dropped at calls and unproven stores, the re-guard at the head, side exits at an instruction, and `guardsflip` in the gate. This lane carries the risk, so it ends with the full gate and the torture tier green.
4. **Measure and write it up** (small). The profile and the races again, x86/README.md's milestone 6, and the JS book's chapter on kinds. Then rank what is next by the new profile: typed int32 items, straight-line versioning, field kinds and method clones for bank.

Lane 1 is the one to start on a quiet tree: it touches Heap.roc and every runtime routine that writes an array.

## Decisions for Steve

1. **Guards at run time (a), not a whole-program proof (b)?** Lean yes: a mistake shows up as a failed check, not a silent wrong answer, and it costs a fraction of (b)'s compile time.
2. **The element kind in the array's header (two new block kinds), with items still NaN-boxed doubles, and no typed int32 stores in this milestone?** Lean yes: no runtime routine has to learn a new item layout, and the typed stores are worth at most about 5% where measured.
3. **Side exits from a fast copy into the generic copy, which the integer kind's design ruled out, allowed here inside versioned loops only?** Lean yes: without them, a read past the end would have to stop the program, as a `Numbers` array's does.
4. **A `guardsflip` torture mode in the gate, compiling every program with every exit taken?** Lean yes, as `gcalways` was for the collector.
5. **A budget on versioned instructions, and byte identity held for programs with nothing to guard?** Lean yes.
6. **Milestone 6 is the SAT race's: fib, fourteen, bank and big daddy are expected not to move, and bank's hashing and big daddy's Map search and sweep go to lanes of their own outside this milestone?** Lean yes.
7. **Lane 1 on a quiet tree, not beside other compiler lanes?** Lean yes, as for the collector's lane 1.

## Lane 1, as built (2026-11-27)

`roc/Heap.roc`'s header is the element kinds' home; nothing reads them for code generation yet, and every program's output is as it was.

**The header.** An array's record block is one of three block kinds: `Int32Array` (code 15), `NumbersArray` (14) or `Array` (2, Values). The codes fall as the kind does, and each fits the header's byte 6 (`Heap.element_kind_place`, the record's address minus 2), so a lowering is one byte stored. The collector traces all three as an array's record.

**Where a kind is set:**
- **An array literal** (`MakeArray`) starts at Numbers when the lowering knows it holds numbers (`Numbers` or `Integers`, `runtime_new_numbers_array`); at Int32 when each item was an `Integer` within 32 bits, or there are none (`runtime_new_int32_array`); at Values when an item is known to be no number; and otherwise `runtime_find_element_kind` finds it from the items as the program runs. A literal with spreads (`NewArray`) starts at Int32, and its appends keep it.
- **Every other array a routine makes** (`map`, `filter`, `slice`, `concat`, `split`, `Array.from`, a spread into a call, a rest, a pattern's array) is Values, from `runtime_new_array`.

**Where a kind is kept:** `Heap.kind_kept_items`, by what the item is known to be (`Heap.ItemStored`), and the routine `runtime_keep_item_kind` built from it:
- IndexLowering's store in line: nothing for an array of numbers the lowering knows (only numbers are written into one, and it starts at Numbers), one byte stored for an item known to be no number, the Number sequence for a double, the Value sequence for anything else;
- `runtime_push_item` (and so `push`, the appends of a literal with spreads, `concat`, `filter`, the timers' list), in line, before the item is stored;
- `runtime_set_index`'s store in place and each item `splice` puts in, by the routine;
- `sort` makes the kind Values when it writes an `undefined` past the items it sorted; `reverse`, `pop` and `sort`'s moves change no item's kind.

**The test.** A whole number of 32 bits, never -0, is a double that makes the round trip through a 32-bit integer back to its own bits: `cvttsd2si r32` then `cvtsi2sd` from it (X86's `Cvttsd2si32` and `Cvtsi2sd32`), whose 0x80000000 for a NaN, a boxed value or a double past 32 bits misses the round trip. The instructions each store adds, on its fast way:

| store | its item known to be | instructions |
|---|---|---|
| in line, into an array of numbers the lowering knows | a number | 0 |
| in line | no number | 2 |
| in line | a double: into Numbers or Values / into Int32, a whole number of 32 bits / lowering Int32 | 3 / 9 / 11 |
| in line, and `push` | any value: a whole number of 32 bits, into any array / any item into Values / a number into Numbers | 6 / 9 / 15 |
| `runtime_set_index` in place, each item `splice` puts in | any value | the Value sequence and a call, about 15 more |

**The check.** The heap walk (`heapwalk`, and after every collection under `gcalways` and `gcsample`) holds every Int32 and Numbers array's items, to its length, to the kind, and stops with "x86: the heap walk found an array's item that its element kind doesn't hold". `x86/tests/element-kinds.js` changes kinds every way (fractions and strings stored in line, -0, the edges of 32 bits, NaN and the infinities pushed, stores through arrays held in an object, `splice`, `sort`, spreads, `concat`, arrays routines make). Planted and seen red, each taken out: the in-line store of a value without its upkeep (x86/programs.shale failed 2 of 118, element-kinds.js and the SAT race, whose `activity` takes doubles); `runtime_push_item` without its upkeep; the Number sequence's lowering left unstored.

**What it cost** (master 779279e's executables against this lane's, alternated, niced, medians of 7 runs, CPU; the box was loaded by other lanes, load 2.6 to 3.9, so these are preliminary):

| race | master | lane |
|---|---|---|
| fib, N = 100,000 | 1,413 ms | 1,243 ms |
| bank, 2,000,000 transfers | 472 ms | 475 ms |
| fourteen, 300 rounds | 520 ms | 519 ms |
| big daddy, 300 rounds | 1,537 ms | 1,376 ms |
| sat, small | 865 ms | 805 ms |

Every difference is within the box's noise; the same pair measured 11 runs each at load 7.6 gave sat 1,035 against 994 ms and big daddy 1,661 against 1,600. The profile is the steadier guide: of sat's 3,130 samples, 157 (5%) fall on the upkeep's instructions, the 80 Int32 tests in its code and the runtime's and the labels past them, a few of them the store's before it; big daddy's are about 1%. An earlier cut of the lane, measured at a load near 1, had fib 24% slower (its limb arrays started Int32, so every store took the test) and sat 7 to 16% slower (18 instructions a store); starting the lowering's arrays of numbers at Numbers and the 32-bit round trip took both out.

**For lane 2 and 3:** a guard on an array is its tag, then `movzx` of `[record - 2]` and a compare with 15 or 14. Arrays that arrive held as values (sat's `st`) are Int32 or Numbers when built from literals and appends; every routine's array is Values until the routine is taught its kind. A versioned loop's fast copy that knows an array is Int32 and stores an `Integer` within 32 bits needs no upkeep; one that stores anything else keeps the generic store's.

## Lane 2, as built (2026-11-27)

`roc/Versioning.roc` places loops twice in the bytecode; Lowering's `versions_tried`, `guard_items` and `exit_items` lower the guards and the exits. No side exits: a fast copy, once entered, runs to one of the loop's own exits.

**Which loops.** A loop is versioned when it reads, as a number, a variable it never writes that the lowering keeps as a `Value` at its head: the first lowering's kinds at each loop's head say which (`CodeItems`' `heads`). "As a number" is read from the bytecode: the value a `LoadLocal` pushes is next taken, through the pushes and operators above it, as an operand of an arithmetic, ordering, equality or bitwise operator, or as an index (`Versioning.is_numeric_use`). Loops are tried outermost first, and a loop inside a versioned one is copied with it. In sat, propagate's watch loop (`while (i < nw)`) is versioned on `nw` and `base`, its counters guarded with them, and the scan for a new watch (`while (k < end ...)`) is copied inside it; the whole program versions 15 loops, 1,111 instructions. fib, bank, fourteen and big daddy version none.

**What the guard tests.** Each such invariant, and each variable the loop writes that it reads as a number from before it starts (its counters, `Versioning.read_first`) and that is a `Value` or a `Number` at the head, is tested for a whole number of 32 bits, not -0: the round trip through `cvttsd2si r32` and `cvtsi2sd` back to its own bits, 9 instructions (`int32_tested_items`). When all hold, the fast copy runs with them as `Integer`s of 32 bits; the walk then takes the counters' ranges as it does any slot's (a counter tested against `nw` narrows, so `i + 1` stays an `Integer`). When one fails, the generic copy, the loop as it was, runs.

**The two copies' slots are apart.** The fast copy names, in place of each slot the loop writes or the guard tests, a fresh slot past the frame's. The guard copies each in; each exit (one a place the loop leaves to) copies back the slots the loop writes, an `Integer` made a double unless the generic copy's way there holds an `Integer` in that slot too. So the two copies' kinds never meet in one slot, and no slot of the generic copy is demoted or widened by the fast copy's kinds.

**When in doubt, not versioned.** No program with a `try`; no loop that makes a closure or a cell, sets a box, or steps a `for ... of`; none entered but at its head or left backwards but by its own `Loop`; none whose renamed slots hold a cell. A versioned program that the lowering refuses is dropped for the program as it was. x86/tests/versioned-near-misses.js holds five near misses at 0 loops.

**The budget:** 400 copied instructions a function, 1,600 a program (`Versioning.most_function_instructions`, `most_program_instructions`). `js-x86 "<program>" versioned` prints `versioned: <loops> loops, <instructions> instructions`, and x86/programs.shale holds the sum across x86/tests (`VERSIONED`) and each test's own first line.

**Byte identity.** `x86/buildtime.shale parts=identity`, the lane's driver against master ad850cf's manifest: 183 of the 187 programs write the same bytes, and the 4 that differ are the 4 that version a loop (x86/tests/equal-values.js, versioned-loops.js, js/tests/12-insertion-sort.js and the SAT race).

**Tests and plants.** x86/tests/versioned-loops.js (5 loops) runs each copy: guards that hold, guards that fail at the entry (a fraction, -0, 2^31, -2^31 and 2^31 - 1 at the edges, NaN, an infinity), a read past the end, an array that changed kind before the loop, a counter that starts as a fraction, a `break`, a `return` inside, a loop nested in a versioned one, and a call in one. Planted and seen red, each taken out: the guard's test made one that never fails (`jcc O` for `jcc Ne`: the fast copy ran on 1.5 and 2.5 as 1 and 2, five lines differed from node); the exits' copy back of the first slot the loop writes left out (nine lines differed); an exit that keeps an `Integer` where the generic copy holds a double (the walk itself stops: "a demoted slot holds no Integer").

**What it bought (preliminary: other lanes ran; CPU, niced, executables alternated).** The SAT race's small workload, 7 runs of each at load about 1.1 to 1.4: 847 ms on master's executable, 812 ms on the lane's (4% less, inside the noise); its profiled run (`x86/profile.shale race=sat`, one run each, load 1.0): 3,734 samples on master, 3,248 on the lane (13% fewer), propagate's 2,078 against 1,806, the tag tests 168 against 103 and the untags 66 against 49; the converts are as they were (591 against 513 samples, the same share). The race workload, 2 runs of each at load 2.2 to 2.9: 104.1 and 99.7 s on master's, 111.4 and 99.6 s on the lane's: no gain the box can show. fib, bank, fourteen and big daddy compile to the same bytes, so they race as before (7 runs each: 1,315/1,383, 538/473, 526/483, 1,301/1,297 ms, all noise). In propagate's watch loop the fast copy is 2,457 instructions against the generic copy's 2,863; the first item read, `pool[base + 2 * i]`, is 52 instructions in the fast copy against 72 (about 39 run against 45, its slow way left out): `i` and `base` are `Integer`s, but `2 * i` is still a double's `mulsd` (a literal on the left of an operator is never an `Integer`, `integer_literal`), and `pool` is a `Value`, so the tag, whole-number and bounds tests stay. The design's 4 needs the arrays guarded (lane 3) and the literal rule; that rule moves two programs that version nothing (join.js, 21-printing-arrays.js), so it is a change of its own. **The cost:** the versioned program is lowered a second time, so the SAT race's compile took 19.9 s of the dev driver's CPU against 11.5 s (73% more), and its executable is 245 KB against 194 KB; programs with nothing to version pay only the search.

**Arrays are not guarded in this lane.** A guarded array's item read past its end, or an item a call stores, has no kind the fast copy could give it without a side exit: `undefined` is no `Integer`. The element kinds lane 1 keeps wait for lane 3's exits.

## Lane 3, as built (2026-11-27)

Lowering's `guard_items`, `fast_before`, `fast_after` and `side_exit_items`, IndexLowering's `int32_read_items` and `int32_write_items`, and Versioning's array guard sets. The kind `Int32Items` (LoweringBasics) is an array, in a fast copy alone, whose header said Int32 when last tested.

**The fast copy first.** A versioned loop is laid out as the guard, the fast copy, the generic copy and the exits. The guard's tests fall to the fast copy when they hold and jump to the generic copy when one fails, so every side exit is a jump forward, whose kinds the walk meets before it lowers the generic copy (`LoweringBasics.Versions`' `fast`: each fast place's generic twin, the slots to copy back, the slots kept as arrays).

**Side exits.** A side exit makes each `Integer` on the stack a double, copies back each fast slot the loop writes (`exit_copies_items`, the loop exits' code too, an `Integer` made a double and an `Int32Items` an array) and jumps to the generic copy's same instruction, which finishes the loop. Its code lies out of line, after a jump past it. The fast copy exits:
- **at an item read** of an `Int32Items` array whose index is no whole number below the length (a read past the end gives `undefined` in the generic copy);
- **at an item write** of one, past the end or of a value that isn't a whole number of 32 bits, not -0 (the round trip through `cvttsd2si r32`), before the store, which the generic copy makes with its kind upkeep;
- **at a store into a slot it keeps as an array** (`pool = st.pool` after `push_watch`) of a value whose tag or header doesn't say Int32 (`fast_before`);
- **after an instruction that may lower any array's kind** (`keeps_element_kinds`: a call, a method other than `Math`'s and console.log, a write of any other array's item, which may be another name for a guarded one): each slot holding `Int32Items` is tested again, `movzx` of `[record - 2]` against 15, and the exit goes to the generic copy's next instruction (`fast_after`).

An `Integer` that would pass 32 bits needs no exit: an `Integer`'s range is the walk's, to ±2^53, so a sum of two items is an `Integer` of 33 bits, and a guarded item stored back must pass the write's round trip. An instruction that would need a side exit beside a branch of its own is refused, which drops the versioned program for the program as it was.

**Array guards.** A loop with a number to guard is chosen first, as in lane 2; a loop with none whose items of a slot holding a `Value` or an `Array` it reads or writes (`Versioning.is_receiver_use`) is chosen after, if it neither holds nor lies in a chosen loop. The guard tests each such slot: its tag (a `Value`'s), then `movzx` of `[record - 2]` against 15, and gives its fast slot `Int32Items`. In the fast copy an item read is the bounds `cmp`, the items' address, a `movsd` and a `cvttsd2si`, giving an `Integer` of 32 bits with no tag or whole-number test; a store of an `Integer` known to be within 32 bits (a literal, `true_val`) is a plain store with no test. A Numbers array is not guarded in this lane: its guard fails, and the generic copy runs.

**The literal rule** (its own commit, 0696339): a number literal on the left of `+ - * %` or a bitwise operator whose right is an `Integer` slot is an `Integer`, so `2 * i` is an `imul`. Byte identity against master c480c4b's manifest: 181 of 187 programs write the same bytes; the 4 that version a loop differ, and so do 2 that version none, x86/tests/join.js (`1000000 + i`) and js/tests/21-printing-arrays.js (`97 + i`).

**Compile time.** The versioned program's passes start from the first lowering's settled kinds (`Lowering.items_with_numbers`' `seed`, commit 8d0c371): the SAT race's compile, dev driver, 20.2 s of CPU on lane 2's driver, 15.4 s seeded, the same bytes.
Lane 3's arrays add loops (the SAT race versions 26 loops, 1,597 instructions, near the program's budget of 1,600) and side exits: its compile is 18.7 s on this lane's driver against 14.0 s on master's and 21.6 s on lane 2's (the measurement below, one compile each, load about 1.3), and its executable 269 KB against master's 194 KB and lane 2's 245 KB.

**`guardsflip`.** `js-x86 "<program>" guardsflip` takes each side exit's test also at every eighth test the program makes, counted in the mapping's last 8 bytes, which the mark stack never reaches (`Heap.spare_place`), so the exits run all through a program. x86/programs.shale compiles every program of x86/tests, the corpus and the SAT race's small workload that way, and runs each whose flipped executable differs from its own with `heapwalk`, held to node. Planted and seen red, each taken out: a side exit that drops its first slot's copy-back (x86/tests/guarded-arrays.js differs from node in both modes; an earlier cut of the plant that also left the kinds wrong made the lowering refuse the versioned program, which the program then drops silently, and the test's held `// versioned:` line is what shows that); a guard with no kind test (guarded-arrays.js and versioned-loops.js differ from node).

**Byte identity.** `x86/buildtime.shale parts=identity` against master c480c4b's manifest: 177 of 188 programs write the same bytes. The 11 that differ are the 9 that version a loop (carried-registers, equal-values, guarded-arrays, integer-arrays-missed, select, versioned-loops, whole-counters, 12-insertion-sort, the SAT race) and the literal rule's 2. fib, bank, fourteen and big daddy version nothing and compile to master's bytes.

**The item read.** `pool[base + 2 * i]` in propagate's fast copy: the index is `imul` and `add` of `Integer`s, and the read 11 instructions (the index moved to `rcx`, the record loaded and untagged, the length's `cmp` and `jae` to the side exit, the items' address, `movsd`, `cvttsd2si`, the store) and a `jmp` past the exit's code; about 25 with the index's arithmetic and the frame's loads and stores, against about 40 on master and 39 on lane 2. The ~4 of the design's ideal needs the stack places in registers and the record's address kept across the iteration.

**What it bought (preliminary: CPU medians of 7 alternated runs, niced, load 1.1 to 1.8; dev drivers' executables, which are the release driver's).**

| race | master c480c4b | lane 2 | lane 3 |
|---|---|---|---|
| fib, N = 100,000 | 1,236 ms | 1,261 ms | 1,268 ms |
| bank, 2,000,000 transfers | 496 ms | 557 ms | 500 ms |
| fourteen, 300 rounds | 547 ms | 536 ms | 550 ms |
| big daddy, 300 rounds | 1,428 ms | 1,439 ms | 1,514 ms |
| sat, small | 862 ms | 943 ms | 811 ms |

fib, bank, fourteen and big daddy are the same bytes on all three, so their columns are the box's noise. The SAT race's small workload is 6% below master's and 14% below lane 2's; its profile (`x86/profile.shale race=sat`, one run at load 1.6) has 3,131 samples, against lane 2's 3,248 and master's 3,734 (loads differ); the converts, tags and untags are 604 of them (19%), against lane 2's 665 (20%) and the design's 25% on master. The race workload, 2 alternated runs each at load about 1.0: 90.1 and 84.9 s of CPU on master's executable, 78.3 and 88.1 s on this lane's (5% less on the means, inside the box's spread). The kinds share fell less than the design's estimate: what converts are left are outside the item reads (the doubles of values read from `st`, the generic copies, `p ^ 1`'s `runtime_word_of`), and the hottest samples are still the two cache-missing loads, now on the `cvttsd2si` after them.
**For lane 4.** The gain is real on the small workload and about a third of the design's 15 to 25%. What holds the rest, by the profile: the fast copy's values live in frame slots, so each read is a dozen loads and stores around its 4 working instructions (the registers pass doesn't reach the stack places), and the record is untagged again at every read; the values read from `st` outside the watch loop (`st.wofs[p]`, `st.wlen[p]`) are still `Value`s; and a Numbers array (`activity`) is never guarded. The budget is nearly spent by the SAT race (1,597 of 1,600), so loops past it are left as they were.
