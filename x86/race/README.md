# The fib race

The code here was written by AI coding agents (Claude), with human supervision.

`fib_race.js` asks how far iterative Fibonacci gets in 20 seconds. Its numbers are arrays of base-10^7 limbs, added in place, so a program with no garbage collector can run it; it reads its own clock (`Date.now()`) between batches of steps and sizes each batch from what the last one cost, stopping when the time left is too small to plan one. On the way it holds its own arithmetic to F(100), computed once offline with node's BigInt and written into the program as a string; a mismatch is a `FAIL` whatever the time. It prints how far it got, `PASS` when its last clock reading is within the 20 seconds and its F(100) was right (`FAIL` otherwise), and last, after the verdict, the whole of F(n) in decimal. `verify.js N` prints the same lines from BigInt's F(N).

The race is between the program compiled by js-x86 and the same program under node. From the repository's root:

    shale x86/race.shale

It builds js-x86 on the dev backend, writes the executable, runs it and then node, niced and never at the same time, and checks each answer against verify.js exactly, the whole number included. Each contestant gets one line: F(n) reached, its digits, the elapsed time the program measured, PASS or FAIL, whether the answer is BigInt's, and the time after the verdict (the run's wall time less its elapsed: chiefly building and printing the whole number). `check.shale` doesn't run it, since it takes about a minute and its numbers are timings. The script is `x86/race.shale`, beside `x86/bench.shale`, because a Shale library can be named only from beside a script's own file or below it.

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

The compiled program did about 1.9 times its earlier work, and node now does about four times the compiled program's work, down from seven. fib's times were unchanged (x86/fib.shale: 20 ms for fib(22) and fib(30)). What is left is a guess, not measured: every value still moves through the frame in memory, one instruction at a time, where node keeps the loop in registers with small integers (milestone 6's register allocation and specialization).
