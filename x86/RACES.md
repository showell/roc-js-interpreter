# The races' latest verdicts

The code here was written by AI coding agents (Claude), with human supervision.

Each race has its own README, which says what it runs and how (x86/race for fib, x86/bank, x86/fourteen, x86/bigdaddy, x86/satrace and x86/buildrace). This page keeps only the latest verdicts, side by side, with when and how each was taken, so a later run has something to be read against.

**The method, for every row below:** the median of three runs, on a quiet box (a shared 2-core VM), each run timed from outside the program, from its start to its exit. Times are wall times. The box's load is its load average while the runs went.

## 2026-11-27, 17:22 to 17:47, master 6949841, load about 1.0

Master 6949841 is lane 3 of milestone 6 (guarded arrays and side exits in versioned loops), the head of master in that window by its log.

**The SAT race** (x86/satrace, the race workload):

| contestant | time |
|---|---|
| js-x86's executable | 89.19 s |
| node | 38.95 s |
| rocsat (Roc) | 29.87 s |

**The build race** (x86/buildrace): js-x86's warm builds take 30 to 600 ms from source to executable, against 0.02 to 0.03 s for Roc's dev backend and 1.05 to 3.50 s for its speed builds.

**Stripped sizes**, js-x86's executable against the Roc port's:

| race | js-x86 | Roc |
|---|---|---|
| fib | 31 KB | 39 KB |
| bank | 45 KB | 169 KB |
| fourteen | 30 KB | 26 KB |

**The collector** (x86/bigdaddy): big daddy at 300 rounds runs in 1,453 ms, its heap at most 8.8 MB.

## 2026-11-26, 22:26, master 2f6f510, load 0.85

| race | compiled | node | Roc |
|---|---|---|---|
| fourteen, 21,000 rounds | 31.84 s | 22.82 s | 18.50 s |

## 2026-11-26, 21:30, master 62cb716, load 0.3 to 1.0

| race | compiled | node | Roc |
|---|---|---|---|
| fib, F(740000) | 50.37 s | 79.73 s | 51.66 s |
| bank, 110M | 22.01 s | 13.06 s | 25.54 s |
| fourteen, 21,000 rounds | 52.42 s | 21.72 s | 17.82 s |

## What is not here

- **The cost tier and the counter are not timings.** `x86/cost.shale` reads llvm-mca's prediction of the bytes, and js-x86's `counted` mode counts the instructions run; both read the same on any box, and x86/COST.md holds their tables.
- **Later commits have not been timed yet:** lane 4's FrameValues (merged as fb5a2d0) and big daddy at 15,000 rounds among them. Until a quiet-box run of them, the rows above are the latest.
