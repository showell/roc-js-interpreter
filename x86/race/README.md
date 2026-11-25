# The fib race

The code here was written by AI coding agents (Claude), with human supervision.

`fib_race.js` asks how far iterative Fibonacci gets in 20 seconds. Its numbers are arrays of base-10^7 limbs, added in place, so a program with no garbage collector can run it; it reads its own clock (`Date.now()`) between batches of steps and sizes each batch from what the last one cost, stopping when the time left is too small to plan one. On the way it holds its own arithmetic to F(100), computed once offline with node's BigInt and written into the program as a string; a mismatch is a `FAIL` whatever the time. It prints how far it got, `PASS` when its last clock reading is within the 20 seconds and its F(100) was right (`FAIL` otherwise), and last, after the verdict, the whole of F(n) in decimal. `verify.js N` prints the same lines from BigInt's F(N).

The race is between the program compiled by js-x86 and the same program under node. From the repository's root:

    shale x86/race.shale
    shale x86/race.shale budget=1000   # the same race with a 1-second budget, for working on speed

`budget=` (milliseconds, 20000 unset) writes a copy of `fib_race.js` with `BUDGET_MS` changed, under the build mount, and both contestants run that copy; each run may take the budget and a minute more. It builds js-x86 on the dev backend, writes the executable, runs it and then node, niced and never at the same time, and checks each answer against verify.js exactly, the whole number included. Each contestant gets one line: F(n) reached, its digits, the elapsed time the program measured, PASS or FAIL, whether the answer is BigInt's, and the time after the verdict (the run's wall time less its elapsed: chiefly building and printing the whole number). `check.shale` doesn't run it, since it takes about a minute and its numbers are timings. The script is `x86/race.shale`, beside `x86/bench.shale`, because a Shale library can be named only from beside a script's own file or below it.

One run before the fixes below, on one 2-core box on 2026-11-25, node v22.23.2, load average 0.35 (the race before its F(100) check was added):

    compiled: F(129808), 27128 digits, elapsed 19951 ms, PASS, verified; after the verdict 44 ms (wall 19995 ms)
    node: F(348552), 72843 digits, elapsed 19962 ms, PASS, verified; after the verdict 59 ms (wall 20021 ms)

A step costs time in proportion to the number's length, so the work done grows as n squared: node did about seven times the compiled program's work in the same 20 seconds.

## Where the compiled program lost its time

`perf` can't sample on the box (`perf_event_paranoid` is 4), so this was measured by reading `addInto`'s machine code (`objdump`) and by timing copies of the race at a 4-second budget, each one run, which reached:

- the race as it is: F(60067);
- with `BASE` written as a literal inside `addInto`: F(59795);
- with no top-level variable captured by a function (`steps` and `hi` written out at the top level): F(57566).

So the captured cells were not the cost, which the guess here had said. The machine code showed what was: in each limb of `addInto`'s first loop, eleven calls into the runtime. Three were `.length` (`runtime_get_property`, which compared the key's bytes with `"length"` on every read), two item reads and one item write (`runtime_get_index` and `runtime_set_index`), two `runtime_add`, two `runtime_compare` and two `runtime_check_number`. The limbs come out of an array, so their kind is never known before the program runs, and every operator on them took the runtime's general way.

## The fixes, and what each did (4-second copies)

1. **A value's number tag tested in line**, and `+` and the orderings of two values done in line when both are numbers (the same `addsd` or `ucomisd` as for two known numbers), the routine kept for the rest: F(60067) to F(60686), about 2% more work.
2. **An array's `length`, item read and item write in line** (`x86/roc/IndexLowering.roc`): the receiver's tag and the index tested, the index made a whole number below the length, then one load or store; anything else calls the routine as before. F(60686) to F(78858), about 1.7 times the work.

The 20-second race after both, the same box and day, load average 0.84:

    compiled: F(179933), 37604 digits, elapsed 19969 ms, PASS, verified; after the verdict 71 ms (wall 20040 ms)
    node: F(358271), 74874 digits, elapsed 19964 ms, PASS, verified; after the verdict 47 ms (wall 20011 ms)

The compiled program did about 1.9 times its earlier work, and node now does about four times the compiled program's work, down from seven. fib's times were unchanged (x86/fib.shale: 20 ms for fib(22) and fib(30)). What was left was a guess, not measured: every value still moves through the frame in memory, one instruction at a time, where node keeps the loop in registers with small integers (milestone 6's register allocation and specialization).

## Measured again, and two more fixes (2026-11-25, 1-second copies)

Reading `addInto`'s machine code again, one limb of the first loop (the usual way: `i < a.length`, both items numbers) runs about 262 instructions, roughly half of them loads or stores at `rbp`, and no runtime calls. By part: each `.length` about 15 (the tag tested, the count made a double), each ordering 14 (a boolean made with `setcc`, tagged and stored, and then 4 more to load it and test it), each item read about 25 and the write 30 (the index tested whole and in range, then one load or store), each `+` of values 12 to 15, and every variable read a load and a store onto the bytecode's stack before its user loads it again. `s` is a `Value`, since it comes from `a[i] + b[i]`, whose items may be anything; `i` and `carry` are known numbers already. `BASE` is read from its cell and its tag tested each time. An ideal loop is about 12 to 15 instructions with 3 memory operations: two item loads, two `addsd`s, a compare and a subtract, the store, the step of `i` and the loop's test, with `i`, the lengths and the items' addresses in registers.

The fixes, each measured as the median of 5 runs of the 1-second race, alternated with master's executable (the box was busy with other work, so the absolute numbers moved between sessions; the ratios are what to read):

3. **An ordering and the `JumpIfFalse` after it, lowered as one** (`OperatorLowering.ordered_jump_items`), when no other way reaches the `JumpIfFalse`: one `ucomisd` and one jump on its flags, no boolean made. This saves about 36 of the 262 instructions a limb: F(36,932) to F(37,908), about 1.05 times the work.
4. **Loads forwarded from registers** (`x86/roc/Forwarding.roc`): over the whole program, a load from the frame of a value a register already holds becomes a register move, or nothing. It forgets what it knows at any jump, call, arithmetic, store elsewhere, or label something names. With 3: F(30,076) to F(34,193), about 1.3 times the work.

That instructions saved bought less than their share is a guess: the loop seems to wait on its chains through memory (each value stored and loaded back) more than on its count of instructions. The register moves of fix 4 shorten those chains. fib's times were unchanged (x86/fib.shale: 20 ms for fib(22) and fib(30)).

The 20-second race after both, the same box and day, load average 0.96:

    compiled: F(194187), 40583 digits, elapsed 19952 ms, PASS, verified; after the verdict 101 ms (wall 20053 ms)
    node: F(349559), 73054 digits, elapsed 19960 ms, PASS, verified; after the verdict 57 ms (wall 20017 ms)

The compiled program did about 1.16 times its earlier work, and node now does about 3.2 times the compiled program's work, down from four. What is left, measured above but not yet fixed: the bytecode's stack is still memory (a variable read is copied there before use), `s` is still a `Value`, and `.length` is read twice a limb.

## Two more fixes: a constant, then registers (2026-11-25, 1-second copies)

Each measured as before: the median of 5 runs of the 1-second race, alternated with master's executable, on the same box and day (load average under 0.7).

5. **A captured `const` set from a number literal is that number** (`KnownFunctions.constant_numbers`): when the maker sets the variable from a literal in the straight run of declarations its code starts with, before anything can run code, and nothing else writes it, a read of its cell is the number, a known `Number`. `BASE`'s cell load and its tag tests go: addInto's first loop 314 to 304 instructions a limb. The race didn't move: F(39,444) master, F(39,442) with it. `s` is still a `Value`, so `s >= BASE` still tests `s`'s tag.
6. **A looping function's three busiest places of the frame kept in registers** (`x86/roc/Registers.roc`): in a function with a loop, the three places at `rbp` that the most plain moves name, and nothing else names, become `r9`, `r10` and `r11` (which no lowered instruction used), spilled before and reloaded after every call and `syscall`, saved below the frame at entry and put back before `ret`; a program with a `try` renames nothing (the module's header has the whole rule). In addInto these are likely the bytecode stack's two lowest places and `i` (a guess from the counts, not checked). The first loop's memory operands at `rbp` went from 126 to 101; its instructions from 304 to 384, all of the rise being the spills and reloads around the runtime calls of the slow ways, which the usual way never takes. F(43,215) master to F(47,024), about 1.18 times the work. fib's times were unchanged (x86/fib.shale: 19 ms for fib(22) and fib(30), which has no loop and so no registers).

The 20-second race after both, the same box and day, load average 0.72:

    compiled: F(207628), 43392 digits, elapsed 19966 ms, PASS, verified; after the verdict 89 ms (wall 20055 ms)
    node: F(353376), 73851 digits, elapsed 19975 ms, PASS, verified; after the verdict 52 ms (wall 20027 ms)

From F(194,187), the compiled program did about 1.14 times its earlier work, and node now does about 2.9 times the compiled program's work, down from 3.2. What is left, a guess: `s` is a `Value` (its tag is tested at each use), `.length` is still read twice a limb, and only three places are in registers, chosen by how often the code names them, not by how often they run; xmm registers for the known numbers would save the moves between the general and the xmm registers.

## The program shaped for the compiler, then arrays of numbers (2026-11-25, 1-second copies)

Each measured as before: the median of 5 runs of the 1-second race, alternated with master's executable, the same box and day (load average under 0.7). The instruction counts are addInto's, read with `objdump`, and its first loop's, one limb.

7. **The program shaped for js-x86**, within Steve's rules for the race (the ordinary iterative algorithm, node running the same source). The race's state moved from top-level variables, which functions capture and so live in cells on the heap as values of unknown kind, into one function's own variables (`race`), so `lo` and `hi` are known arrays there (addInto's parameters stayed values: fix 8 says why). `steps` takes the two arrays and does its steps two at a time, the caller swapping its names after an odd count, in place of the `hiIsY` flag. addInto reads each length once, into a constant, and its common part, where both numbers have a limb, is a loop of its own with no test of `i < a.length` and no `push`; b's one limb past a's end and the carry are a short loop and one `push` after it. addInto went from 683 instructions to 562, its first loop from 384 a limb (101 at `rbp`) to 282 (68 at `rbp`). F(46,268) master to F(51,034), about 1.22 times the work. node's own runs of the 1-second race, one each: F(78,660) before, F(82,188) and F(82,006) after, so node lost nothing by the shaping.
8. **A function that captures only known functions and numbers held for good is known before the program runs** (`KnownFunctions.statics_of`, a general rule: any function reading a top-level `const` set from a number literal). addInto captures `BASE`, whose every read fix 5 already made the number, so it needed its cell for nothing, but its capture kept it, and so `steps` and `race` after it, out of the functions known by their code: each call of them went through a value, and their parameters were values. Now such a function takes no closure record, its entry copies no cell for such a number, and it is called directly, its parameters taking the kinds its calls give: addInto's `a` and `b` are known arrays at last (fix 7 alone had not done it, a guess there that the measurements below corrected). addInto 562 instructions to 489, its first loop 282 a limb (68 at `rbp`) to 245 (62). F(51,352) to F(54,294), about 1.12 times the work. `x86/tests/constant-capture.js` holds such a function called directly, through a value and by `map`, and printed.
9. **Arrays that hold only numbers** (`Numbers`, Lowering's header has the rule, `numbers_escaping` and `numbers_escape` hold it). An array literal of known numbers, or an empty one, is an array of numbers for good when nothing could put anything else in it: it may be read for its length, read and written at number indexes (written only with known numbers), given `push` of known numbers, printed, moved between the frame's own slots and the stack, and passed to functions called directly whose parameter then holds only such arrays. Anything else that reaches one (an object or array or cell it is stored in, a return, a call through a value, an operator, another method, a meeting of two ways where one way has another kind) refuses, and any refusal lowers the whole program again without arrays of numbers, so the rule never refuses a program that compiled before. An item read of such an array is a known number, so `a[i] + b[i] + carry`, `s >= BASE` and `s - BASE` test no tag; a read that finds no item (node's `undefined`) stops the executable with a line saying so (`x86/tests/refused/numbers-read-past-end.js`). Seven expects in Lowering hold the rule both ways: two arrays kept, and five near misses not (a string pushed, a write of a value of unknown kind, an array stored in an object, one passed where another call passes strings, one captured by a closure); `x86/tests/number-arrays.js` and `number-arrays-missed.js` hold both to node's output. addInto 489 instructions to 363, its first loop 245 a limb (62 at `rbp`) to 167 (32). The race moved less than that: F(53,547) to F(55,248) in one set of 5 runs, and F(50,011) to F(50,792) in a second, with master at F(44,462) beside them, the box busier; about 1.03 to 1.07 times the work. That the instructions saved bought little is again a guess: what is left in the loop is mostly the frame's loads and stores and their chains.

One more was tried and dropped: `rbx` as a fourth spare register in a function that names it nowhere (addInto is one, now that it is called directly). The fourth place by count was not one the loop waits on: addInto's first loop went from 167 instructions to 171 (32 to 29 at `rbp`), and the race from F(56,591) to F(56,243), medians of 7, no gain, so it is not in the branch.

The 20-second race after 7 to 9, the same box and day, load average 0.71, with master's run just after it (load 0.81):

    compiled: F(243271), 50841 digits, elapsed 19962 ms, PASS, verified; after the verdict 132 ms (wall 20094 ms)
    node: F(373752), 78110 digits, elapsed 19973 ms, PASS, verified; after the verdict 55 ms (wall 20028 ms)

    master, compiled: F(207310), 43325 digits, elapsed 19966 ms, PASS, verified; after the verdict 88 ms (wall 20054 ms)
    master, node: F(326270), 68187 digits, elapsed 19959 ms, PASS, verified; after the verdict 62 ms (wall 20021 ms)

From F(207,310), the compiled program did about 1.38 times its earlier work. node's runs move by a tenth between runs on this box (F(326,270) to F(373,752) here, F(353,376) at the end of the last section), so how its own work changed with the shaping is within that noise; it did not fall. Against the node run beside it, node now does about 2.4 times the compiled program's work, down from 2.9. What is left, measured in the loop's code but not fixed: each item read and write tests its index whole and in range again (three times a limb for the same `i`), unboxes the array's address each time, and every variable still lives in the frame; the three registers hold the bytecode's stack places, not `i` or `carry`.

## An index checked once (2026-11-25, 1-second copies)

Measured as before: the median of 5 runs of the 1-second race, alternated with master's executable, on the same box and day (load average under 1.2). The instruction counts are addInto's first loop, one limb, read with `objdump`.

10. **An index checked once in a straight run is not checked again** (`IndexLowering`'s header has the rule, `Checked`, `checked_after` and `checks_for`). The walk follows where each place of the bytecode's stack came from (a variable's slot, by `LoadLocal`) along a straight run, and an item read of an array of numbers, whose slow way stops the program, proves its index's slot a whole number below its array's slot's length. A later read or write of the same two slots skips the tests proved: `b[i]` skips the whole-number test of `i`, and `a[i] = s - BASE` skips both. What was proved is forgotten at every place two ways meet and at every instruction outside a short list that changes no array's length but by growing it, so a call or a `push` forgets it. The write in the `else` branch starts at a meeting of two ways, so it still tests everything. addInto's first loop 167 instructions a limb (32 at `rbp`) to 156 (32). F(57,725) master to F(60,275), about 1.09 times the work.

Two more were tried and are not in the branch:

- **The array's unboxed address kept for reuse** (cause (b) of the last section) was not written: the items' address would have to live in a register no lowered code between two accesses spoils, and the slow ways' runtime calls between them spoil every register but the spare three, so keeping it needs a register of its own across those calls. Left for a lane with more time.
- **Registers choosing places by their moves inside loops** (each move inside a loop counted 16 times, a loop being the statements from a label to a jump back to it) chose the same three places as before: addInto's first loop stayed at 156 instructions (32 at `rbp`), and the race at F(59,886) before and F(60,221) after, medians of 5, no gain. The bytecode's stack places are the busiest inside the loop too; `i` and `carry` would need more spare registers, or the stack places kept out of the frame some other way. A guess, not measured: a lowering that leaves a loaded variable's value in its register instead of copying it to the stack would serve both.

The 20-second race after 10, the same box and day, load average 0.78, one run with no master run beside it:

    compiled: F(213849), 44692 digits, elapsed 19963 ms, PASS, verified; after the verdict 104 ms (wall 20067 ms)
    node: F(373393), 78035 digits, elapsed 19968 ms, PASS, verified; after the verdict 63 ms (wall 20031 ms)

That is below the F(243,271) of the last section's run, though the 1-second medians, alternated with master's executable, put 10 ahead by about 9%. With no master run beside it, this run can't tell the change from the box's noise; a guess is the noise, since the 1-second runs alternate and this one doesn't. Against the node run beside it, node did about 3 times the compiled program's work.
