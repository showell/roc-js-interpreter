# Where js-x86's build time goes (2026-11-27)

The code here was written by AI coding agents (Claude), with human supervision.

The build race (x86/buildrace/README.md) found js-x86 at 107 to 149 ms from source to executable on fib, bank and fourteen, and about 1.1 s on big daddy, against 0.06 to 0.2 s for `roc build --opt=dev`. This file says where that time goes, what was fixed, and what is left. **Every number here is preliminary:** the box had a load average of 1.3 to 2.7 on its two cores throughout (another lane was optimizing the compiler's generated code), and each table says its load. CPU time is the number to read; wall time moves with the load.

## How it was measured

- **By phase:** `js-x86 "<program>" stop=<phase>` (JsToX86.roc's `stopped_at`) runs the compile only as far as one phase and prints one number of what it made, so nothing is left out as unused. `shale x86/buildtime.shale parts=phases` times each phase's run, and a phase's own time is the difference from the phase before. It also times the post-passes alone (`stop=posts-again` lowers, then runs the four post-passes over the result once more) and the runtime's statements alone (`stop=runtime-posts`, `stop=runtime-assemble`).
- **By line:** perf is closed to an unprivileged user here (`perf_event_paranoid` is 4), so a scratch sampler stopped js-x86 every 300 µs by ptrace and read its program counter and the words on its stack, and a release build with `--debug` gave addr2line its lines. The sampler is not part of the repository; the line numbers below are this tree's.
- **Scaling:** `parts=scaling` compiles a made-up program of 25, 50, 100 and 200 small functions, each calling the one before.
- **Identity:** `parts=identity` compiles the 183 programs (x86/tests, x86/tests/refused, js/tests and the five races: fib, bank, fourteen, big daddy, sat) and holds each output's sha256 and exit code to a saved manifest.

All runs niced to 19, medians of 3 unless said.

## The phase profile, before (load 1.7 to 2.4, CPU ms)

| program | start | parse | compile | lower (with the post-passes) | assemble | ELF | hex | whole (wall) |
|---|---|---|---|---|---|---|---|---|
| fib | 0 | 2 | 0 | 40 | 0 | 2 | -1 | 43 (44) |
| bank | 1 | 2 | 1 | 70 | -12 | -1 | 1 | 62 (63) |
| fourteen | 2 | 4 | -2 | 51 | 2 | -8 | 6 | 55 (57) |
| big daddy | 1 | 12 | 3 | 644 | -135 | 78 | -52 | 597 (608) |
| sat | 1 | 18 | 3 | 1117 | 93 | -105 | 61 | 1194 (1317) |

The negative differences are noise: assembling, the ELF header and the hex together cost a few ms. **Almost all the time is in lowering and its post-passes.** Process start-up, the front end (lexing, parsing, resolving and bytecode, 2 to 21 ms) and the encoding are small.

**The runtime is not re-encoded at a cost.** Roc evaluates a top-level value when it compiles js-x86, so `RuntimeCode.items` (7,447 statements) is built once, into the executable; assembling it alone takes about 1 ms (`stop=runtime-assemble`, 2 ms with start-up).

**The post-passes over the runtime are the biggest single piece for a small program.** Jumps, Forwarding, Moves and Jumps again over the runtime's statements alone take 19 to 29 ms (`stop=runtime-posts`), and over a small race's whole program about 25 ms of its 40 to 70 ms lowering (`stop=posts-again` less `stop=lower`). The runtime is 7,447 of the fib race's statements; the program's own are fewer than 2,000.

## Scaling (load 1.7, CPU ms, median of 3)

| functions | source bytes | lower | whole | lower per function |
|---|---|---|---|---|
| 25 | 5,400 | 169 | 172 | 6.8 ms |
| 50 | 10,775 | 320 | 339 | 6.4 ms |
| 100 | 21,528 | 725 | 733 | 7.2 ms |
| 200 | 43,328 | 2,060 | 1,886 | 10.3 ms |

Lowering grows a little faster than the program (8 times the functions, 12 times the time), and it is heavy for each function from the start: about 7 ms for a function of eight lines. Counting with `dbg` in a dev build shows why: the lowering walks each function many times. The fib race's lowering made 2 rules' tries and 7 passes over its functions, 78 walks of a function in all; big daddy 7 passes and 421 walks; sat 3 rules, 12 passes and 2,103 walks (`Lowering.rules_items` tries `IntegerItems`, then `NumberItems`, then `AnyItems`, each until the kinds settle, and a loop whose head widens walks its function again).

## The ranked causes

1. **The lowering's repeated walks** (big daddy and sat: most of their time). Each try of a rule lowers every function in every pass until the kinds settle, and a refused rule's work is thrown away. The sampler finds no single hot line: the time is spread over the walk (`code_walk`, Lowering.roc 978 to 1315: `integers_made` 5%, `$body`'s concatenations 2%, the five-place `ahead` test 2.5%, `fused_jump` 2%), reference counting (incref and decref, about 25% of all samples) and allocation (`roc_realloc`, about 10%, which copies a byte at a time). Part of it was work done again in every pass and every walk that no pass changes (each function's cells, captured numbers, held captures and declarations, each found by walking a maker's code, so it grew with the program's size): **fixed** (below), 20 to 25% on big daddy and sat. **Estimated win of the rest:** large but not cheap: walking only the functions whose inputs changed since the last pass would save most of the passes after the first, and is a change to what the lowering decides when, which belongs with the lowering's owners.
2. **The post-passes over the runtime** (fib: about 20 of 43 ms). **Estimated win: up to 45% of a small race's compile.** Not as one piece: `Jumps.unreached_dropped` takes out every runtime routine the program never names (a routine's label is named only by the program's calls: 80 of the 131 programs that lower name `runtime_get_property_hashed`, 75 `runtime_add`, one `runtime_string_replace`), so the runtime's statements after the passes differ from program to program. An attempt that did the runtime's passes once and checked, program by program, that the result would be the same found it never was (`runtime_no_heap` and `runtime_stack_overflow`, which only the start code names, in all 131). **Fixed per unit** (below, "The runtime's post-passes done once").
3. **A copy in Moves on every joined move** (`Moves.drop_last_instruction`). It kept its argument alive while it took the last statement off, a use after a consume (roc-apps' docs/roc-notes.md, "Speed and copying"), and in the fib race 208 of the sampler's 300 `roc_realloc` samples came from Moves. **Fixed** (below); the measured win was 3 to 7%, less than those samples suggested.
4. **Shale's hex to bytes** in the race's own step (`bytes_of_hex`): 20 ms of the fib race's step and 61 ms of big daddy's, outside the driver. **Fixed** (below).

## What was fixed, each measured

Each on the release build, CPU medians of 7 or 9 runs alternated with the build before it (x86/buildtime.shale and a scratch script that alternates two builds), load 0.7 to 1.0. Changes of 5% or less on the small races are within the noise.

| commit | change | fib | bank | fourteen | big daddy | sat |
|---|---|---|---|---|---|---|
| 7bc1526 | the race's hex to the file by xxd (`hex_written`), outside the driver | 20 ms less | | | 61 ms less | |
| e5de4c7 | Moves: `drop_last_instruction` no longer copies the walk on every join | 43 -> 40 | 62 -> 60 | 37 -> 37 | 506 -> 503 | 1165 -> 1139 |
| 1dde69f | Lowering: each function's cells and captured numbers found once, not once a pass; no Integer work with none on the stack | 41 -> 39 | noise | noise | 514 -> 463 | 1117 -> 999 |
| 13757a8 | Lowering: no list made for a call's kinds, a clash or the look ahead when there is nothing to find | noise | noise | noise | 489 -> 398 | noise |
| b1570ca | Lowering: each code's held captures, declared functions and their places found once | noise | noise | noise | noise | 1197 -> 1108 |

Tried and dropped: reading `$now`'s length in `Jumps.thread_jumps` before the walk took the statements (no change), and doing the runtime's post-passes once (cause 2: never applicable).

**All together** (master's release js-x86 against this lane's, CPU medians of 9, alternated, load 0.7 to 0.9): fib 56 -> 48 ms (85%), bank 81 -> 74 (91%), fourteen 46 -> 48 (noise), big daddy 665 -> 515 (77%), sat 1404 -> 1088 (77%).

The made-up program's lowering at 200 functions went from 2,060 to 1,373 ms (load 0.9), 10.3 ms a function to 6.9, nearly linear now: celled_slots and constant_numbers walked a maker's code for every function in every pass.

The phase profile after (load 0.8 to 1.0, CPU ms, median of 5):

| program | start | parse | compile | lower (with the post-passes) | assemble, ELF, hex | whole (wall) |
|---|---|---|---|---|---|---|
| fib | 1 | 2 | 1 | 50 | about 10 | 57 (60) |
| bank | 1 | 2 | 1 | 71 | about 0 | 78 (80) |
| fourteen | 1 | 1 | 0 | 35 | about 10 | 40 (42) |
| big daddy | 1 | 8 | 2 | 443 | about 20 | 466 (476) |
| sat | 1 | 18 | 7 | 985 | about 0 | 957 (962) |

(The box was busier than for the comparisons above, so these small races read high: fib's whole compile was 38 to 48 ms in the quieter runs.)

## Byte identity

After every change, `shale x86/buildtime.shale parts=identity against=...` compiled the 183 programs (64 of x86/tests, 45 of x86/tests/refused, 61 of js/tests, the five races including big daddy and sat; 165 executables and 18 refusals) and held each output's sha256 and exit code to the manifest master's js-x86 wrote. **None differed, at any step.** The gate's x86/programs.shale held the compiled programs to node, and the refused to their refusals.

## The build race, before and after

`x86/buildrace.shale parts=build runs=5`, RC1, master's scripts and js-x86 then the lane's, one after the other (load 1.0 to 1.3). Wall times, so only large gaps mean anything; the CPU table above is the better measure of the driver.

| race | js-x86 warm, before (driver alone) | js-x86 warm, after (driver alone) | roc --opt=dev cold / warm | roc --opt=speed warm |
|---|---|---|---|---|
| fib | 59 ms (46) | 63 ms (55) | 0.05 s / 0.03 s | 1.07 to 1.79 s |
| bank | 82 ms (62) | 94 ms (81) | 0.09 to 0.11 s / 0.03 s | 3.4 to 3.8 s |
| fourteen | 60 ms (42) | 44 ms (37) | 0.05 to 0.06 s / 0.02 to 0.03 s | 0.72 to 0.75 s |
| big daddy | 617 ms (575) | 454 ms (444) | no Roc port | |

The step past the driver (xxd and the chmod, against bytes_of_hex) fell from 13 to 42 ms to 7 to 13 ms. **On a quiet box, `roc build --opt=dev` warm (0.02 to 0.03 s) still beats js-x86 (about 40 to 60 ms of driver for the three small races); js-x86 is level with Roc's cold dev build, and 15 to 50 times faster than `--opt=speed`.** The earlier race's 107 to 149 ms (x86/RC2.md) was at a load of 2.3 to 3.0.

## The runtime's post-passes done once (lane x86-runtimepre, 2026-11-27)

`x86/roc/RuntimePosts.roc` (its header has the rules) runs the four post-passes over the runtime once, as top-level values Roc evaluates when it builds js-x86, and a compile runs them over the program's own statements beside the runtime's finished ones. **Every program compiles to the same bytes as on master b38100d**: 184 of 184 (x86/tests, x86/tests/refused, js/tests and the five races; `parts=identity` against master's manifest, dev and release builds).

**How the runtime's routines were made independent of the program.** The runtime is cut after every `jmp` and `ret` into 480 units, each entered only at its labels. Forwarding and Moves forget what they know at a `jmp` and a `ret`, so a unit's passes depend on the program only through which of its labels are named, whose address is taken among the labels it jumps to, and what is read there; Jumps keeps a unit from its first named label on, round after round. So the units are passed once as if all were kept (each unit's first labels taken as named, and a seam between units, a distance to a label nothing marks, which stops Jumps from dropping a jump as one to just after it). A compile emulates Jumps' rounds over the program beside the units exactly as Jumps runs them over the whole: each unit kept from its first segment whose label is named, the unnamed labels of the texts dropped, the rounds stopping when the whole's count of statements stays the same or after 8 (`phase`), and a mark before the tail standing for whether the texts leave it reached. It then holds that what each kept unit saw alone is what it sees beside this program: its labels named as they were, its jump targets' addresses taken as they were, no jump of it to just after it into the next kept unit, and what it reads at a unit passed with the program as it was. **A unit that doesn't fit is passed with the program**, in its place in the whole's order, and the compile is tried again: the allocator's kind entries are such units (each ends `jmp runtime_allocate_kind`, and Jumps drops the last kept entry's jump, so which entries run together depends on the kinds a program uses), and so are `runtime_stack_overflow`'s unit (named by every function's stack check, inside a unit the runtime alone doesn't name it in) and a few lookups of properties. The 19 units most programs pass are found when js-x86 is built (`seed`), so fib, bank, fourteen and sat take one try and big daddy two. Every program of x86/tests and the races goes this way (`js-x86 "<program>" posts`, held by x86/programs.shale); the whole is passed as before only when the program's code doesn't end with a `ret` or a `jmp`, the tail holds code, or the units passed keep growing.

**Three mistakes on the way, each found by the identity check or a fallback count:** the program's Forwarding and Moves must take every label the whole names (a unit done once names labels of the units passed with the program); the runtime's reads must never seed the walk's own labels (Moves' fixpoint starts from nothing, `Labels.marked`); and a unit dropped while a label inside it is named leaves its tail behind for a round (`runtime_next_item`, whose inner label its collection unit jumps to), so a unit is kept from a segment, not whole.

The whole compile, master's release js-x86 against the lane's, alternated, CPU medians of 9 (wall in brackets), niced, load 1.3 to 1.6:

| race | master b38100d | lane | |
|---|---|---|---|
| fib | 38 ms (41) | 25 ms (26) | 34% less |
| bank | 55 ms (57) | 44 ms (46) | 20% less |
| fourteen | 35 ms (37) | 21 ms (22) | 40% less |
| big daddy | 449 ms (457) | 456 ms (461) | noise |
| sat (medians of 7) | 1259 ms | 1247 ms | noise |

Big daddy and sat are their lowering's walks (cause 1); the runtime's 20 ms is small beside them.

The build race (`x86/buildrace.shale parts=build runs=5`, RC1, master's release js-x86 then the lane's, one after the other, load 1.6 to 1.9; wall times, js-x86's driver alone in brackets):

| race | js-x86 warm, before | js-x86 warm, after | js-x86 cold, after | roc --opt=dev cold / warm | roc --opt=speed warm |
|---|---|---|---|---|---|
| fib | 52 ms (45) | 34 ms (28) | 34 ms | 0.05 to 0.06 s / 0.02 to 0.03 s | 1.11 s |
| bank | 66 ms (59) | 57 ms (49) | 60 ms | 0.09 to 0.11 s / 0.03 s | 4.0 to 4.3 s |
| fourteen | 53 ms (46) | 35 ms (29) | 37 ms | 0.07 s / 0.03 s | 0.79 to 0.82 s |
| big daddy | 492 ms (482) | 492 ms (481) | 489 ms | no Roc port | |

**js-x86 now beats Roc's cold dev build on every small race by about half, and is level with its warm one** (fib and fourteen 34 to 35 ms against 0.03 s; the race prints Roc's times to a hundredth of a second, so "level" is all it says). About 6 ms of each js-x86 time is the step past the driver (xxd and the chmod). The races' executables are the same bytes as master's, so their run times are unchanged by construction.

## What is left

- **What a small race's compile still spends on the post-passes**: the program's own statements through all four (cause 3's copies aside, they are most of what is left of a small race's lowering after its walks), the 19 or so units passed with it, and the emulation's rounds over the 480 units (a list of booleans by label number a round). Big daddy's second try runs the program's first Jumps twice; a wider `seed` would save it.
- **The lowering's repeated walks** (cause 1): a function whose inputs (its parameters' kinds, the results of the functions it calls, the escaped codes) didn't change since the last pass could keep its last lowering, and a rule's refused try could stop at its first lasting refusal. Both change when the lowering decides things, so they belong with the lowering's owners.
- **Allocation and reference counting**: about a third of all samples. The default platform's `roc_realloc` copies a byte at a time; a statement's labels are strings, so every copy of a list of statements touches each string's count.
- The process's start-up, the front end and the encoding are each a few ms and need nothing.
