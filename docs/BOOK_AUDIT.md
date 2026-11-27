# The JS book's correctness audit (2026-11-27)

The code here was written by AI coding agents (Claude), with human supervision.

An audit of `js-book/book.md` ("JavaScript in Roc: A Compiler and an
Interpreter") against master 8dd6fad: its code, its docs and its commit
record. Each claim with a number, a name, a path, a function, a behaviour or a
date was checked; each wrong one is listed below (old → new, with the
evidence), with the count of claims checked that were right. Flow and chapter
order were out of scope. The compiler's races and optimizations and its
collector are changing in other lanes, so for them the book was checked only
for what master holds, and numbers that will move are cited to their READMEs.

Evidence used throughout: `git log` and `git show` of each cited hash (author
dates, in UTC), counts of files and lines made for the audit, the scripts'
held constants (`EXPECTS`, `INLINED`, `HELD`), `shale check.shale` (56 of 56),
`shale x86/fib.shale timing=0`, and probe programs run on the cached js-vm and
js-x86 builds and on node.

## Introduction

Wrong (1):
- "over four days, 2026-11-23 to 2026-11-26" → "starting on 2026-11-23
  (`30837f8e`)". Master holds commits of 2026-11-27 (a328636, e876665 and the
  book's own).

Right (15): the subset's list; classes as sugar (0b6d8de); why `this`, `new`
and prototypes stay out (js/README.md, "Why `this` stays out"); 61 corpus
programs; the compiler's 49 (x86/corpus.txt); node 22; the oracle scripts and
the refusals' first lines; 32 and 25 on the first day (278631d); 61 and 76
(js/README.md's status); 54-big-daddy as "all features" (7d6a472, cc904c2);
js/canvas/2-turtle-spiral.js; the move on 2026-11-24; the playground's URL;
the book's parts.

## Motivation

Right (2): the copy shapes and the build times it points to. Unverified (1):
that list-copy bugs went upstream (no commit or doc here names them).

## How it got here

Wrong (1):
- "At 20:44 UTC the compiler made its first executable (`c3ff721`)" →
  20:39. 20:44 is the commit's committer date; its author date is 20:39:18,
  and 0c5ea7e's 21:26:45 is 47 minutes after that, as the next clause says.

Added: a sentence on 2026-11-26's integer kind (81b5809) and inlining
(7810da3), and a section for 2026-11-27 (a328636), so "a section a day"
covers master.

Right (30): every other hash's date and subject, and the figures their
messages give: 37 of 50 and 13 refused (fe85d38), 50 of 50 (b69660c), the
peaks of 40 to 164 MB to about 4 MB (6211010), the walker's 50 of 50 and 44 of
44 by the day's end (aac0e64), under 256 bytes (3aba5cf), 45 of 61 at 01:21
(451306b), 47 at 17:00 (6ec8068), and the rest.

## The front end

Right (12): the four stages and their modules; ScopeLayout's layouts;
ClassDesugaring's three parts (its header); `NewInstance` and `InstanceOf`;
jumps relative to the next instruction (Bytecode.roc's header); the frame's
layout (Compile.roc).

## Roc's copy rule

Right (9): the eight shapes and their builds, held to roc-apps'
tools/copy_shapes/expected.txt and expected-dev.txt; `List.update`; the
record and `Box` rules.

## The compiler to x86-64

Wrong (8):
- The pipeline named only the lowering's four families → it now points to
  `Inlining` before the lowering and four passes after it, which the
  optimizer chapter names: `Registers`, `Jumps`, `Forwarding` and `Moves`
  (`Lowering.program_lowering`, Lowering.roc lines 151 to 166 and 382 to
  383). The chapter was trimmed to stay under 900 words.
- The kinds left out `Integer` → added (x86/README.md, "An integer kind").
- "(`Lowering.program_items`)" for the passes until kinds settle →
  `items_with_numbers` (Lowering.roc's header; `program_items` only wraps
  `program_lowering`).
- "about 15 KB of machine code (`x86/README.md`)" → about 21 KB: `let x =
  1;` compiles to 21,611 bytes. The README's figure predates the later
  routines; the README itself is left as it is.
- "fib(22) is 25,167 bytes (`x86/fib.shale`, 2026-11-25)" → x86/fib.js,
  fib(22) and fib(30), 22,041 bytes (x86/fib.shale, 2026-11-27); milestone
  2's 1,010 bytes cited to 0c5ea7e.
- "47 of 61 (`6ec8068`)" → 49 of 61 (x86/corpus.txt, x86/README.md).
- "the 23 programs of `x86/tests/`, and the 31 of `x86/tests/refused/`" →
  64 and 45.
- The table of the 14 left (3, 3, 8, with `substring`, `repeat`, `trim`
  and `o.k++`) → the 12 left (3, 4, 5), as x86/README.md's table has them:
  the string methods (8cb8756) and `o.k++` (a27562c) now compile, and 21 (an
  array of more than 100 items printed) is a reason of its own.

Right (16): the modules X86, Assembly, Elf, Emit, Boxing, JsToX86; the ELF
layout at 0x400000; the hex carried by executables.shale; the NaN-boxing table
(Boxing.roc, x86/README.md); `runtime_add` and `runtime_compare`; the four
registers; the 2 GiB heap, 64 KiB pages and headers (x86/COLLECTOR.md);
`Heap.allocate_items`; the refusal and stop messages.

## The compiler against node

Right (26): every figure of the table and the text against x86/BENCH.md
(68f420b; c46df62 changed only its prose); the in-line paths' commits
(17cb2b0, d6ecebd) come after it; the bench is untouched since; fib(30)'s
220 times (x86/README.md).

## Three compilers, one race

Wrong (3):
- "Roc's loop runs 46 to 51 instructions a limb and js-x86's 71. About 25
  of js-x86's come from the numbers being doubles" → 71 on 2026-11-26, 64
  since the integer counter, and the 25 are of master's 76 before fixes 18
  and 19 (x86/race/README.md: "That is about 25 of master's 76").
- "The largest lead is an integer loop counter ... which needs the compiler
  to carry whole numbers as integers" → it is done (x86/race/README.md,
  "What is left", 1: 71 to 64).
- "the bank ledger, about five times, and the fourteen race, about 2.7
  times" → their last full-size runs, 2.84 and 2.60 (x86/bank/README.md and
  x86/fourteen/README.md, "Against Roc"); 5.01 and 2.68 were earlier runs.
  The fourth race, big daddy, is named, and the chapter points to each
  README for where a race stands.

Right (14): F(740000) (`const N`); the Roc port and its build; more than
150,000 digits; the table and its load (x86/race/README.md after 8989013);
0.74 and 0.99; "seven times" on 2026-11-25; fixes 1 to 19 and the four named.

## What the compiler leaves to an optimizer

Wrong (4):
- "Four ways, three from knowing" → seven ways: the integer kind, field
  places and method tables (FieldSlots.roc, MethodTables.roc), inlining
  (Inlining.roc), and the register renaming and the three passes after the
  lowering were missing.
- "A search of `x86/roc/` on 2026-11-25 finds zero mentions of inlining a
  function, constant folding, peephole passes or register allocation" and "a
  call stays a call" → Inlining.roc and Registers.roc exist; the section now
  says calls stay calls but for inlined leaves, Registers renames at most four
  places a function, and a search on 2026-11-27 finds zero mentions of
  constant folding.
- "milestone 6, register allocation and type specialization" (twice) →
  "type specialization", x86/README.md's milestone 6 as it reads now.
- "outgrow the 1 GiB heap" → 2 GiB (a328636), with the collector's first
  lane named.

Right (8): the in-line paths and their commits; 6 to 8 times for loops; the
two guesses as BENCH.md gives them; eleven runtime calls a limb
(x86/race/README.md); classes since 6ec8068; the receiver in `rdx` (555b245);
milestone 4 and its four programs.

## The interpreter

Right (8): JsVm.roc, oracle.shale, the wasm engine, Inspect.roc,
NumberText.roc, `dispatch!` and the quoted lines (the build holds them).

## A canvas in the browser

Wrong (1):
- The drawing calls left out `noFill` and `noStroke`, while the text says
  "That is the whole of it" → added (Ast.roc's library names, Canvas.roc,
  js/README.md).

Right (17): 400 by 400; the turtle, input and time calls; `onCollect`; 30
frames a second; js_page.js, js_runner.js, js_painter.js, js_memory.js;
`Vm.tick!`; the files named by their bytes; the host's four functions;
`Canvas.line_of`; the three hosts; `Events.timer_requested` and
`with_event_taken`; node's order for the example.

## Memory strategy

Right (21): the cells and the free list (Heap.roc); `Machine.pushed`;
`Ast.Capture`; every cost row against js/controls/expected.txt,
expected-dev.txt and js/README.md's probes; the line's instructions
(js/dump.shale holds that dump); the six shapes (js/README.md).

## The garbage collector

Wrong (1):
- "The headers and pages are built (`e876665`)" → a328636, the commit that
  built them; e876665 is its README.

Right (14): Collector.roc's mark and sweep; `lent` before `swept`; the
roots; the threshold, twice the kept and at least 1,024 cells; the 0.04 a
pass and the ladder's 0.05 (tools/alloc_ladder.shale); 55-garbage.js's 1,800
pieces in 12 rounds and its third place (a57db77, js/build.shale's FEATURED);
`onCollect` (aa391df); the compiled collector's design (x86/COLLECTOR.md).

## JavaScript's rules for values

Right (15): `Instructions.binary`, `property_read`, `combined`;
`ValueRules.add`, `property`, `text_of`, `kind_of`; the eight names of
`is_prototype_name`; `ValueRules.Machine`'s three fields; `Machine.lent`,
`shell`, `with_got`; the four modules and `text_method`, `array_method`;
05-array-push's one allocation in release.

## Handing the machine on

Right (9): 123 to 82 ms (15686d9); 232, 312, 288 and 248 bytes, the table and
the 16% (3aba5cf); 248 held by tools/machine_size.shale.

## Why a compiler suits Roc

Wrong (5):
- The stages named `Lowering.program_items` → `executable_of` calls
  `lowering_of`, which calls `Lowering.program_lowering`.
- "Across the 13,521 lines of `x86/roc/`" → 23,712 (33 files, 2026-11-27).
- "four definitions carry the `!`" → five: JsToX86.roc's `write_inlined!`
  is the fifth.
- "the encoder's 106 `expect`s" → 108 (X86.roc).
- "`x86/roc/Inspect.roc`, 1,184 lines" → 1,185.

Right (7): `executable_of`'s type; `runtime_write`, `runtime_run_timers`;
Vm.roc's 25 and js/roc's 38 effectful declarations; Assembly.roc's comment on
writing in place.

## Dev and release builds disagree

Right (30): the controls' table (both expected files); 112 bytes and
`Machine.pushed`; 46c08a1, 53f986a, 22cd72d; 3 against 1 and 3 to 12.73
(d8d6b7f); 15 to 16 (920cda0) and 3 to 4 (2233adc); the timings' table
(920cda0, 3b4f9bd, js/README.md); 40% slower; the step budgets and 1.1, 5.2,
2.0 and 8.8 s (fd9fb4e); roc-apps' CLAUDE.md section 9.

## Build times

Right (16): 65 s (84263a4), 686 s (f0837ff), 1,052 s (roc-apps' tag
rc1-slow-release-build), 11 to 17 minutes (roc-apps 762c7d3a); 670 s
(29cb46e), 84 s (15686d9, d7ce2f2), 110 s (f9188b2), 91 s (js/README.md);
481 s for js-run (d7ce2f2); the three pull requests' changes and 271, 166,
63 and 83 s, and 12% and 14% (12.4% and 13.9% in #13410's description), read
on GitHub; all three still open.

Unverified (3): the author's name (GitHub shows the login GW-Jack); "about 12
times faster" together (Zulip, which this audit can't read); "expected to
merge after Roc 0.10".

## How it is tested

Wrong (3):
- "the encoder's 106" and "`x86/fib.shale` the compiler's 187 (`x86/README.md`)"
  → hello.shale's 123 expects, the encoder's 108 among them, and fib.shale's
  213, each script's `EXPECTS`. x86/README.md still says 113 and 187; it is
  left as it is.
- "The record lists five plants" → the interpreter's record lists five; the
  compiler's commits list more (c3ff721, 0c5ea7e, 22361e1, a328636), and
  tools/machine_size.shale's header one more. Added, with programs.shale's
  held inlining count and its `heapwalk`.

Right (11): oracle.shale's 61 and `collect=every`, 51 to 53; programs.shale's
holds; controls with both builds and 80b5e68; 9 canvas samples; page_check;
the five plants' commits (278631d, b623437, 80b5e68, 668c52c).

## Limitations

Right (18): the page's API (with the canvas fix above); `Date.now()` the
compiler's alone (x86/README.md; ValueRules.roc refuses `Date`); async
refused; 100,000 callbacks; the step budgets; the class differences
(js/README.md); 400 and 10,000 deep (f432045); UTF-16 against UTF-8; the
parser's refusals; 128 KiB (js/README.md, "Pitfalls"). The exhausted Map
iterator was run for this audit: js-vm prints the entry set after the walk
ended, node prints nothing, as the book says.

## Totals

325 claims checked, 27 of them wrong and fixed, and 4 left unverified.

Stale docs found beside the book and left as they are (outside this lane):
x86/README.md's "about 15 KB" runtime, its hello.shale count (113, now 123)
and fib.shale count (187, now 213), and milestone 5's "shadow stack as its
roots" (x86/COLLECTOR.md chose conservative roots); the root README's "17 of
the corpus's 61 programs"; Lowering.roc's header, which says a class can't be
lowered yet.
