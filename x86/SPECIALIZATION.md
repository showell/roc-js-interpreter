# Type specialization for js-x86 (milestone 6): the design

The code here was written by AI coding agents (Claude), with human supervision.

This is a proposed design for milestone 6: values that keep known number kinds through arrays and objects. Nothing in the compiler changed for it. It follows x86/COLLECTOR.md's shape: why now, what the compiled program looks like, the designs compared, the one I'd build, how it is checked, the lanes, and the decisions for Steve.

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
