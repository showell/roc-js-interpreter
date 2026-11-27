# The SAT race

The code here was written by AI coding agents (Claude), with human supervision.

`sat.js` is rocsat's CDCL solver ([github.com/showell/rocsat](https://github.com/showell/rocsat), `src/`) transliterated into the JavaScript subset, so the race runs one algorithm three ways: compiled by js-x86, under node, and as rocsat itself, Roc on LLVM. The fib, bank, fourteen and big-daddy races are arithmetic, method calls and breadth; this one is a real program's hot loops: unit propagation over a flat clause arena, conflict analysis, a heap, and bit fields in every clause header.

## What was transliterated

rocsat's one-shot solve path, function for function, with rocsat's names (Core, Propagate, Analyze, Branch, Reduce, Simplify and Solver each a section of `sat.js`): literals as `2 * var + sign`; the flat arena of `[header, meta, lits...]`, the header's size, learnt and deleted bits and the meta word's LBD and use age; pooled watch lists with blockers, a block moved to the pool's end at twice its room when full; the trail and its levels; EVSIDS with its heap (ties to the lower variable) and full phase saving; Luby restarts with a unit of 1,000 conflicts; first-UIP analysis with MiniSat's recursive minimisation and the exact LBD; reduction every 2,000 conflicts by worse LBD, then size, then age; arena compaction past one sixth dead words; root simplification.

**Left out:** DRAT proofs, assumptions and incremental solving, and the brute checker.

**Deliberate differences, each in a comment where it is:**

- rocsat threads its lists through its functions and gets them back in tuples, because Roc copies a list that a record shares (its Core.roc header). Here the arrays are shared by reference in one state object, and a function writes its scalars into it.
- **No list is built afresh where it can be reused.** Analysis keeps its working lists in the state and empties them for each conflict (MiniSat's own `analyze_stack` and `analyze_toclear`); simplification and compaction move the live clauses down the arena in place; a watch rebuild empties the pool and zeroes the block tables. Each makes the lists rocsat makes, so the search is the same, every count included. The reason is the executables' heap: there is no collector yet (x86/README.md, milestone 5), and with fresh lists the executable ran out of its 2 GiB on `plus49151-28` alone. With the lists reused, the whole race workload ends with 447 MB in blocks (`heapstat`).
- `absent` (a heap position) is -1 and `undef_lit` -2, where rocsat's are `0xFFFFFFFF`; neither is ever a position or a literal.
- `truncate(a, n)` pops to cut an array, since js-x86 refuses a write of an array's `length` (`refused: the property \`length\` of an array written`). It is the one change made for the compiler, and it is a plain rewrite.

## The instances

The subset reads no files, so the program makes its instances:

- **`holeN`**, rocsat's `hole` family (SATLIB's, hole6 to hole10 in rocsat's corpus, hole3 and hole4 in its tests/edge): N + 1 pigeons in N holes, written as tests/edge/hole4.cnf is. Known UNSAT. rocsat's bench corpus itself isn't fetched on the box, so these stand for it.
- **`plusW-K`**, cook-levin's Nibble++ search: is there a K-line program that decides language W? `sat.js` holds sat.c's gates (constants folded, a gate made twice reused) and plus_sat.c's step, gate for gate, so its clauses are `plus_sat search W K`'s, byte for byte, which x86/satrace.shale checks when cook-levin's `out/tcc/plus_sat` is built. The census gives the answers: 49151 (`is_not_14`) needs 28 lines, so 27 is UNSAT and 28 SAT; 191 needs 14, 47 needs 10 and 11 needs 6.

Each instance prints its verdict and its conflict, decision and propagation counts, and a SAT model is checked against the instance's clauses.

| workload | instances | node |
|---|---|---|
| `race` (as written) | hole8, plus191-13, plus191-14, plus49151-27, plus49151-28 | about 41 s of CPU |
| `small` (x86/programs.shale) | hole5, hole7, plus11-5, plus11-6, plus47-9 | about 1 s |
| `tiny` (js-vm) | hole4, plus11-5, plus11-6 | under 1 s |

`ROUNDS` solves each instance that many times; the race needs no repeats to pass 20 s under node.

## Correctness

node and js-x86's executable print the same lines on the small and race workloads, and js-vm prints them on the tiny one. Those lines are rocsat's: on each instance of the small and race workloads (x86/satrace.shale checks it every run) the verdicts and the conflict, decision and propagation counts are rocsat's own (its `c conflicts=...` line), exactly, through restarts, reductions, compactions and simplifications (plus49151-27: 45,778 conflicts, 70,956 decisions, 69,763,851 propagations, 23 restarts, 22 reductions and 7 compactions in rocsat's count). js-vm was run on `tiny` only: its dev build took 119 s of CPU there (the release build wasn't in the cache).

## Running it

From the repository's root:

    shale x86/satrace.shale                   # the race workload: node about 40 s of CPU
    shale x86/satrace.shale workload=small    # about 1 s under node
    shale x86/satrace.shale runs=3            # three runs of each in turn, and the medians
    shale x86/satrace.shale rounds=2          # each instance solved twice by every contestant

The script builds js-x86 on the dev backend and writes the executable; builds rocsat's release executable (`roc build --opt=speed`, by the nightly rocsat's roc-version pins, from build:roc-pin-dl) under the build mount, once a rocsat commit; and has node write each instance as DIMACS for rocsat, one process an instance. The three run niced, one after another, and the load average is printed before and after. The compiled program's output must be node's, and rocsat's lines node's. x86/programs.shale holds the small workload's executable to node in the gate.

## The race (PRELIMINARY)

One run of each, 2026-11-27, master 5b85772 plus this lane, niced, on the shared 2-core box with other lanes compiling (load average 2.17 before, 2.58 after). These are wall times of a busy box; run it again on a quiet one before reading much into them.

| contestant | race workload | / rocsat |
|---|---|---|
| js-x86's executable (163,180 bytes) | 95.24 s | 2.64 |
| node v22.23.2 | 52.75 s | 1.46 |
| rocsat, Roc's release build (LLVM) | 36.12 s | 1.00 |

compiled/node is 1.81. On the small workload (load 2.39) the executable took 1.88 s, node 1.33 s and rocsat 0.55 s, where node's start and rocsat's five process starts weigh.

What the executable does with the solver's code hasn't been read yet. `st`'s fields are a plain object's, read through the runtime's hashed lookup, and every array read from one is a `Value`, so each index in propagation's inner loop tests a tag; that is the first place to look.
