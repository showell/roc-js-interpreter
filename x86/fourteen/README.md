# The fourteen race

The code here was written by AI coding agents (Claude), with human supervision.

`fourteen.js` is the Nibble machine as one function, f : {0,1}^14 -> {0,1}, written line for line as cook-levin-riff's `roc/Fourteen.roc` is. The 14 bits are a number below 2^14: the top 2 bits are the input, where AX starts, and the low 12 the program, six lines of two bits (nada 00, zero 01, decr 10, mod2 11). `step(run, op)` runs one line, and `f` reads each line's op from the program with `Math.floor(program / place) % 4`, the places 4^5 down to 4^0 walked with `for ... of`. The program runs f over all 16,384 points `ROUNDS` times, 21,000 as written, chosen so that the compiled program takes about a minute on our box, as the other races' sizes are. Each round counts the points where f is 1, which is 5,596 (the C's cross-check, and Fourteen.roc's last expect); it prints that count once, the total over all the rounds, and PASS when every round counted 5,596.

The race is between the program compiled by js-x86, the same program under node, and `fourteen.roc`, its Roc port (below). From the repository's root:

    shale x86/fourteen.shale                  # 21,000 rounds, about a minute compiled
    shale x86/fourteen.shale rounds=300       # about a second compiled, for tuning
    shale x86/fourteen.shale rounds=300 runs=5   # five runs of each in turn, and the medians

`rounds=` writes a copy of `fourteen.js` with its `const ROUNDS` line changed, under the build mount, and the two JS contestants run the copy. The script builds js-x86 on the dev backend, writes the executable, builds `fourteen.roc`'s release executable, then runs the compiled executable, node and Roc, niced and never at the same time, each timed from outside by its wall clock, start to exit. Each contestant's output must be the three lines the count fixes. `check.shale` doesn't run it, since its numbers are timings.

**The source is as it was.** No reshape was made for the fixes below: every one is a change to the compiler, and the program reads as the Roc does. Its one shaping, from before, is that the line places are an array made in `main` and passed down, since js-x86 keeps a top-level variable that a function reads in a cell of unknown kind.

## Where the time went (2026-11-26, 300 rounds)

`perf` can't sample on the box, so this was measured by reading the machine code (`objdump`) and timing copies of the program with one part changed, each copy run once at 300 rounds (4.9 million points, 29.5 million lines run). On master (0914dda), the program as it is took about 1.15 to 1.2 s, and node about 0.39 s:

| the copy | compiled | about ns a line |
|---|---|---|
| f with no loop (main, the call of f, `input` and `program`) | 110 ms | (22 ns a point) |
| that, and the `for ... of` walk, each line `run = run + place` | 384 ms | 9 for the walk |
| that, with `run = run + Math.floor(program / place) % 4` | 904 ms | 18 for the op's arithmetic |
| the walk with `run = step(run, 1)` | 674 ms | 10 for the call of step |
| the program as it is | 1,150 to 1,200 ms | |

What the machine code showed:

- **`step`'s parameters were values, not numbers.** `run = step(run, op)` passes step's result back to it. The kinds' passes guessed each parameter a value at first, so the first pass made the result a value while the call passed a number, the next made it a number while the call passed a value, and the two swapped for good; the passes that only rise then made both values. So `run > 3` tested a tag and `run === 0` called `runtime_strict_equal`, twice a line.
- **`Math.floor` was a call of its routine,** seven a point, each with the four spare registers stored and loaded around it.
- **Each step of the walk was a call of `runtime_next_item`,** which tells an array from a Map, a Set and an iterator as the program runs.
- **Every `===` of two numbers made a boolean** (`sete`, `setnp`, `and`, the tag added) and the jump after it tested the boolean, and a `&&` kept its left side's boolean as its value and tested it again at the `if`.
- `bits % 4096` and `% 4` were already in line (OperatorLowering's magic reciprocal). `run > 3` was already one compare and jump when `run` is a number, and the boolean f returns was tested in line by the `if` in main.

## The fixes, and what each did (300 rounds)

Each is a general rule, with its own test in x86/tests/ held to node and planted once (a fault in the lowering turned the test red). The medians are of 5 to 9 runs, alternated with another executable (`build:.../pair.shale`). The box was shared with other jobs for part of the session (load up to 3), so read the ratios between the two executables of a set, not the absolute times.

1. **The first pass guesses each parameter a number** (Lowering's `KINDS ONLY RISE`), and a function that no call reaches in a pass (its caller refused, say) keeps the kinds its parameters had unless it refused with them. `run = step(run, op)` now settles with both known numbers. x86/tests/result-to-parameter.js. Medians of 5: 1,208 ms master, 1,176 ms with it.
2. **`===` and `!==` of two known numbers and the `JumpIfFalse` after them are one** (Lowering's `fused_jump`): a `ucomisd` and its jumps, no boolean. x86/tests/equal-jumps.js.
3. **A `for ... of` over a known array steps in line** (IndexLowering's header), the length read anew at each step, as node's walk sees items pushed during it; an array of numbers may be walked and stays one, its items known numbers. x86/tests/array-walks.js.

   Fixes 1 to 3 together, with the rounding below, medians of 7: 1,169 ms master, 1,029 ms.

4. **A `&&` that an `if` tests jumps once** (Lowering's header, `threaded_skips`): each `SkipIfFalsy` whose skip comes to a `JumpIfFalse` is that `JumpIfFalse`'s jump, so the test before the last jump is reached one way and fuses with it (fix 2). x86/tests/equal-jumps.js holds `&&`s of one, two and three tests. Medians of 7: 1,041 ms before it, 931 ms with it (master 1,219 ms in the set beside it).
5. **A leaf function's busiest places kept in registers too** (Registers' header): a function that calls no function of the program is renamed as one with a loop is. `step` now does no load or store at `rbp` on its fast ways but its saves. Medians of 9 against fix 4: 995 ms against 985 ms, and 1,523 against 1,454 ms on a busy box: within the noise, never slower.

Tried and dropped: **`Math.floor`, `Math.ceil` and `Math.trunc` in line** (`cvttsd2si`; a NaN, an infinity or a number of 2^63 or more found by `cmp`'s overflow and sent to the routine; the step of 1 by `setb`, or by a predicted jump; the number's sign bit or-ed in for -0). The copy with the op's arithmetic alone went from 904 ms to about 600 ms, but the whole program was slower with it: medians of 9 alternated, 908 ms with the routine against 1,026 ms in line with `setb`, and 828 against 900 with the jump. Why is not known; a guess is that the routine's predicted branch keeps the compare off the answer's chain, and its one copy of the code serves all seven calls. x86/tests/math-rounding.js, written for it, stays and holds the routines to node.

After fixes 1 to 5, medians of 9 alternated with master's executable: 1,195 ms master, 797 ms; node takes about 0.39 s.

## The race at full size

One paired run at 21,000 rounds, the branch's executable then node, load 0.70:

    compiled: 62.19 s, matched
    node: 23.20 s, matched; compiled/node 2.68

Master's (0914dda) at the same size a few minutes before, load 0.94:

    compiled: 87.97 s, matched
    node: 25.41 s, matched; compiled/node 3.46

So the compiled program does the work in about 0.71 of master's time, and node's lead is down from about 3.5 to about 2.7 at a minute.

At full size node's JIT runs a round in about 1.09 ms, against about 1.3 ms in the 300-round copy, so its lead is larger at a minute than at a second.

**The other races are no slower** (measured with the in-line rounding in, which neither uses in its loop): the fib race's executables run directly, alternated, medians of 9, 1,155 ms master and 1,136 ms; `shale x86/bank.shale size=small runs=5`, twice each, alternated, 0.86 and 0.83 s master against 0.79 and 0.79 s (its methods are leaves, fix 5).

## Against Roc (2026-11-26)

The third contestant is `fourteen.roc`, the race ported to Roc from cook-levin-riff's `roc/Fourteen.roc` and built by Roc's release build (LLVM, `--opt=speed`), the plain translation with no optimizing. A run is Fourteen.roc's tag union, `[Going(U64), Accepted, Rejected]`, and `step` and f (`is_accepted`, a question, for the lints) are Fourteen.roc's, the six places a list folded over inside f as Fourteen.roc has it; the JS passes them down from `main` only for js-x86's sake. Its round count is its argument (`fourteen-roc N`), so nothing of the race is known when Roc compiles it. Its time grows with the count (300 rounds 0.33 s, 1,200 rounds 1.35 s), so LLVM doesn't lift a round, the same every time, out of the loop.

`shale x86/fourteen.shale`, 21,000 rounds, one run of each, load 3.15 at the start (the box was busy):

    compiled: 54.77 s, matched
    node: 21.10 s, matched; compiled/node 2.60
    roc: 19.38 s, matched; compiled/roc 2.83

`shale x86/fourteen.shale rounds=300 runs=5`, load 2.7 at the start:

    medians of 5: compiled 0.99 s, node 0.57 s, roc 0.29 s; compiled/node 1.74, compiled/roc 3.47

## What is left

Measured in the same copies after fixes 1 to 4 and the in-line rounding (300 rounds): f with no loop 115 ms, the walk 196 ms (about 2.7 ns a line), the op's arithmetic 546 ms (about 12 ns a line more), `step(run, 1)` 362 ms, the program 894 ms. Read in the machine code, not yet fixed:

- **The op's arithmetic is the largest part,** about 12 ns a line (measured with the in-line rounding): a `divsd`, `Math.floor`'s call, then `% 4`'s truncation, its whole-number test and its multiply, and back to a double. The integer floor makes is turned into a double and straight back into an integer by `%`; a lowering that kept a known whole number as an integer in a register would take out both conversions. That is the integer-kind work fix 17 of the fib race left for a round of its own.
- **The call of `step`,** six a point: two arguments pushed, the four spare registers stored before the call and two loaded after, `step`'s frame made and its saves, though `step` keeps them itself now. Inlining a small function known by its code, or a caller that knows its callee keeps the spare registers, would take most of it out.
- **The frame between the instructions:** each value of the bytecode's stack is still stored to the frame and loaded back (the walk's place is stored as a double each step and loaded and made an integer the next, a chain round the loop).
