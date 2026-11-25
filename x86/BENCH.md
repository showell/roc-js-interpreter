# The compiled programs against node, warmed

The code here was written by AI coding agents (Claude), with human supervision.

The x86 README's fib table shows the executable beating node on small programs, and that comparison is partly node's start-up: `node file.js` spends about 45 ms before it runs a line. This page asks the other question. Once node's JIT has had time to warm up, how do the executables do? On these four programs, node wins. Its optimized code is faster than the executables on every program we timed, by 1.2 to 8 times.

## The method

`shale x86/bench.shale`, from the repository's root, runs the whole measurement. It is not part of `check.shale`, because timing on this box is too noisy to gate on.

Each program in `x86/bench/` defines `work(n)`, which returns a number:

- **fib**: a recursive `fib(n)`, so the cost is mostly calls.
- **loops**: nested loops over local variables and an array of 100 numbers, with a `%` in the inner body.
- **sieve**: the sieve of Eratosthenes over an array of `n + 1` flags built by `push`. This one is mostly array reads and writes.
- **collatz**: the sum of the Collatz steps for every start from 1 to `n`, using `%`, `/` and `*` on doubles in a `while` loop.

Each program runs at two sizes. The small one runs in a few milliseconds. The large one runs for several hundred milliseconds or more, long enough for node's optimizing tier to take over. For each program and size, the script writes the program with `console.log(work(n))` at its end, compiles it with js-x86, and checks that the executable prints exactly what node prints. Only then does it time anything. Every run is niced, and every time is the median of 3 runs:

- **executable**: the compiled ELF's wall time, in whole milliseconds, process start included.
- **node**: `node file.js` wall time, so node's start-up is included.
- **warmed**: a harness that runs `work(n)` in a loop inside one node process. It throws away the first runs as warm-up (200 at the small size, 3 at the large), then times 50 or 5 more with `process.hrtime.bigint` and takes their median. The harness also reports the very first run's time (**first run**), which shows how much of the warm-up happens inside a single call. Its result is checked against the program's printed one.
- **vm**: js-vm's release build (the bytecode VM), at the small size alone. The large sizes would take minutes in it.

The **ratio** is the executable's time divided by node warmed's. Above 1 means node warmed is faster. At the small sizes the ratio means little, because the executable's time is mostly process start and is rounded to whole milliseconds. Compare the executable with one-shot node there instead.

## The numbers

These are from one box on one day (2026-11-25): the 2-core development box, no swap, node v22.23.2, load average 0.07 at the start. Treat them as one sample, not a benchmark suite. All times are in ms.

| program | executable | node | first run | warmed | ratio | vm |
|---|---|---|---|---|---|---|
| fib(22) | 1 | 48 | 2.0 | 0.3 | (3.2) | 112 |
| fib(35) | 222 | 213 | 212.1 | 190.1 | 1.17 | - |
| loops(2000) | 7 | 51 | 3.3 | 0.8 | (8.3) | 503 |
| loops(300000) | 831 | 172 | 142.6 | 132.9 | 6.25 | - |
| sieve(10000) | 2 | 68 | 2.7 | 0.1 | (11) | 82 |
| sieve(5000000) | 514 | 437 | 366.5 | 296.7 | 1.73 | - |
| collatz(10000) | 84 | 108 | 5.7 | 3.3 | (25) | 2,258 |
| collatz(300000) | 1,043 | 446 | 375.9 | 479.4 | 2.18 | - |

A second run a minute later had the same shape, with a fair spread. loops(300000) took 1,261 ms in the executable and 155.6 ms warmed (8.10). fib(35) took 219 against 165.5 (1.32), and collatz(10000) took 27 ms in the executable, against 84 in the first run. Expect differences of 30% or more between runs on this box. The ratios at the large sizes stayed on the same side of 1.

## What they say

- **Small programs:** the executable wins against `node file.js` on all four, at 1 to 84 ms against 48 to 108. The win is node's start-up, as the book says. Inside a warm node process, the same small workloads take 0.1 to 3.3 ms per run.
- **Large programs:** node wins even one-shot, start-up included, on three of the four. Warmed, it wins on all four:
  - fib, by about 1.2 to 1.3 times. All of fib's kinds are known, so the executable tests no tags, but its baseline code keeps every value in memory.
  - sieve, by 1.7 times.
  - collatz, by 2.2 times.
  - loops, by 6 to 8 times. That is the widest gap. Our guess, not measured: a tight loop over a local array is where V8's registers and small integers help most, and where the executable's values moving through memory cost most.
- **Most of node's warm-up happens within the first call.** At the large sizes, the first run is already close to the steady time, because V8 optimizes a hot loop while it is still running (on-stack replacement). collatz's steady time came out slower than its first run in both runs (about 475 ms against about 370). We have not looked into why.
- **The VM** is about 25 to 110 times slower than the executable at the small sizes, where the executable's own times are mostly its process start.

These results match the x86 README's own reading of fib(30), and they point at the same remedy: milestone 6's register allocation and type specialization, for long numeric loops.
