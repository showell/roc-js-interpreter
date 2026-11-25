# The fib race

The code here was written by AI coding agents (Claude), with human supervision.

`fib_race.js` asks how far iterative Fibonacci gets in 20 seconds. Its numbers are arrays of base-10^7 limbs, added in place, so a program with no garbage collector can run it; it reads its own clock (`Date.now()`) between batches of steps and sizes each batch from what the last one cost, stopping when the time left is too small to plan one. On the way it holds its own arithmetic to F(100), computed once offline with node's BigInt and written into the program as a string; a mismatch is a `FAIL` whatever the time. It prints how far it got, `PASS` when its last clock reading is within the 20 seconds and its F(100) was right (`FAIL` otherwise), and last, after the verdict, the whole of F(n) in decimal. `verify.js N` prints the same lines from BigInt's F(N).

The race is between the program compiled by js-x86 and the same program under node. From the repository's root:

    shale x86/race.shale

It builds js-x86 on the dev backend, writes the executable, runs it and then node, niced and never at the same time, and checks each answer against verify.js exactly, the whole number included. Each contestant gets one line: F(n) reached, its digits, the elapsed time the program measured, PASS or FAIL, whether the answer is BigInt's, and the time after the verdict (the run's wall time less its elapsed: chiefly building and printing the whole number). `check.shale` doesn't run it, since it takes about a minute and its numbers are timings. The script is `x86/race.shale`, beside `x86/bench.shale`, because a Shale library can be named only from beside a script's own file or below it.

One run, on one 2-core box on 2026-11-25, node v22.23.2, load average 0.35:

    compiled: F(129808), 27128 digits, elapsed 19951 ms, PASS, verified; after the verdict 44 ms (wall 19995 ms)
    node: F(348552), 72843 digits, elapsed 19962 ms, PASS, verified; after the verdict 59 ms (wall 20021 ms)

A step costs time in proportion to the number's length, so the work done grows as n squared: node did about seven times the compiled program's work in the same 20 seconds. Not yet measured, but the likely cause: the race's top-level variables are captured by its functions, so the compiled code keeps them in cells whose kind is `Value`, and `addInto`'s arrays and limbs arrive as `Value`s, which go through the runtime's checked routines where node's optimizing tier specializes them (milestone 6's work).
