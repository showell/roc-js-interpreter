# Roc RC2 against RC1, through the compiler and its races (2026-11-27)

The code here was written by AI coding agents (Claude), with human supervision.

This is a first exercise of Roc 0.1.0-RC2 before Roc 0.10. It runs this repository's gate, js-x86 and the races under RC2, against the pin, 0.1.0_RC1. The pin did not move. RC2 ran from an unpacked release outside `~/tools`, through an uncommitted local override of `roc-version` and the prelude's `pinned_roc`, and both were put back before any commit. The checkout was master 8dd6fad.

**All the timings here are preliminary.** Other lanes were running throughout (the collector, the book audit, a SAT race), so the load average stayed between 1.5 and 3.1 on the two cores, and each table records it. The same executable's run time varied by up to 3 times between runs (below), so only gaps much larger than that mean anything. `shale x86/buildrace.shale rocs=...` (x86/buildrace/README.md) repeats every timing in one command, for a run on a quiet box.

## In short

- **The gate passes under RC2:** 56 of 56 checks, and the allocation tier 2 of 2. No new warnings or errors, and no `roc fmt --check` differences.
- **RC2 writes the same bytes as RC1.** Every executable both compilers built is byte-identical: js-x86 itself (8,120,552 bytes), and the dev and speed builds of the three Roc races. So, of course, is every executable js-x86 writes: 174 programs, none different.
- **Roc's run-time speed is therefore unchanged.** The gaps in the timing table come from the load on the box.
- **js-x86's own release build** takes about 250 s of CPU under either compiler: 254 s warm under RC1, 244 s under RC2.
- **The build race:** js-x86 builds each race 10 to 75 times faster than `roc build --opt=speed`. But `roc build --opt=dev` beats js-x86, at 0.06 to 0.2 s against js-x86's 0.1 to 0.2 s. Roc's dev executables, though, are 2.3 MB and run 10 to 25 times slower. So the thesis holds against the build that makes a fast executable, and does not hold against Roc's dev build.

## 1. Correctness: the gate under RC2

`shale check.shale` under RC2 printed **`check: 56 of 56 passed`**. Every line passed:

- the Roc recipes, their counts unchanged;
- the 11 roots;
- `roc fmt --check` over 68 files;
- `roc check` of each root, with 0 errors and warnings;
- `roc test` of js/'s roots, at their held counts (20, 20, 11, 20);
- js/oracle, js/canvas, js/dump and tools/machine_size;
- x86/hello, x86/fib with `timing=0`, and x86/programs (the corpus still at 49 of 61).

All the builds the gate makes through tools/roc_build.shale fail on any warning, and none failed. The allocation tier, `shale check.shale js=1`, gave **2 of 2**: js-vm's release build (165.5 s under RC2) and its dev build both held the controls to `expected.txt` and `expected-dev.txt` exactly. So the monotype-lowering changes in RC2 moved no allocation count.

**Nothing in RC2's output differs from RC1's.** The gate counts every ✗ and ● line `roc check` prints, and there were none under either compiler. `roc fmt --check` passed under both. No reproduction was needed.

## 2. Byte identity

`x86/buildrace.shale parts=bytes` compiled each of these with the js-x86 that RC1 built and with the one RC2 built:

- every program in `x86/tests/` (64);
- every program in `x86/tests/refused/` (45);
- the corpus, `js/tests/` (61);
- the four races (fib, bank, fourteen and big daddy).

That is 174 programs: 158 became executables, and 16 were refused by name. Each output (the executable's hex, or the refusal) and its exit code were held to RC1's by sha256. **None differed.** Big daddy compiles now: its executable is written, though the run here does not hold its output to node's.

Byte identity holds a level further down, too: **the two compilers' executables are themselves the same bytes.** These are js-x86's release build, and the dev and speed builds of `fibonacci_race.roc`, `bank_race.roc` and `fourteen.roc`:

| executable | bytes | RC2's against RC1's |
|---|---|---|
| js-x86 (`--opt=speed`) | 8,120,552 | identical |
| fib-race-roc, dev / speed | 2,275,992 / 45,504 | identical / identical |
| bank-race-roc, dev / speed | 2,417,128 / 179,840 | identical / identical |
| fourteen-roc, dev / speed | 2,347,640 / 32,296 | identical / identical |

So whatever the 5 files that changed from RC1 to RC2 do (in the type checker and the monotype lowering), they change no code in anything built here.

## 3. The speed of Roc itself

**The Roc races' release executables** (`--opt=speed`), at the race scripts' small sizes, with the compilers taking turns, 5 runs each, medians of wall time. The load was 2.68, 2.76, 2.71 before and 2.84, 2.79, 2.72 after:

| race (argument) | RC1 | RC2 | RC2/RC1 |
|---|---|---|---|
| fib (100,000) | 2,217 ms | 2,001 ms | 0.90 |
| bank (2,000,000 transfers) | 1,000 ms | 1,001 ms | 1.00 |
| fourteen (300 rounds) | 542 ms | 553 ms | 1.02 |

The executables are byte-identical, so these gaps are the box's noise. The same fib executable ran in 1,180 ms, 2,217 ms (median of 5) and 2,978 ms (median of 3) at different moments of the afternoon.

**js-x86's own release build**, `roc build --opt=speed x86/roc/JsToX86.roc`: cold means an empty Roc cache, and warm is the median of 2 runs with that cache. The load was 2.67, 2.89, 2.87 before and 2.97, 3.00, 2.74 after:

| compiler | cold | warm | cold CPU | warm CPU |
|---|---|---|---|---|
| RC1 | 471.6 s | 295.2 s | 267.8 s | 254.2 s |
| RC2 | 268.1 s | 289.0 s | 246.3 s | 243.6 s |

RC1's cold wall time was taken during a burst of other work: its CPU time, 268 s, is close to the others. On CPU time, RC2 is about 4% to 8% lower, which is within this box's noise. A warm cache saves little, since the time goes to LLVM, and the cache keeps the front end's work, not the optimized code.

## 4. The build race: source in, executable out

`x86/buildrace.shale parts=build runs=3`: medians of 3 warm runs, not 5, to fit the session's time. The default, 5, is for the quiet run.

- **js-x86** is the release build each compiler made, and the time covers the whole step: the driver, Shale turning its hex into bytes, the write and the `chmod`. The driver's own time is in brackets. js-x86 has no cache: its cold run is just its first.
- **`roc build`** is the compiler's whole run from the race's folder. That includes linking the default platform's host.
- **Cold** means a fresh, empty `XDG_CACHE_HOME` and `TMPDIR` under `build:scratch/buildrace`, which Roc's cache was seen to fill. **Warm** means that same cache again.

### fib (load 2.28, 2.69, 2.65)

| contestant | cold | warm |
|---|---|---|
| js-x86, built by RC1 | 143 ms | 138 ms (driver 113 ms) |
| js-x86, built by RC2 | 175 ms | 142 ms (driver 106 ms) |
| `roc build --opt=dev`, RC1 | 0.14 s | 0.08 s |
| `roc build --opt=dev`, RC2 | 0.14 s | 0.09 s |
| `roc build --opt=speed`, RC1 | 2.31 s | 2.78 s |
| `roc build --opt=speed`, RC2 | 2.71 s | 2.53 s |

### bank (load 2.53, 2.71, 2.66)

| contestant | cold | warm |
|---|---|---|
| js-x86, built by RC1 | 139 ms | 140 ms (driver 121 ms) |
| js-x86, built by RC2 | 204 ms | 149 ms (driver 120 ms) |
| `roc build --opt=dev`, RC1 | 0.20 s | 0.07 s |
| `roc build --opt=dev`, RC2 | 0.19 s | 0.06 s |
| `roc build --opt=speed`, RC1 | 10.76 s | 8.52 s |
| `roc build --opt=speed`, RC2 | 11.04 s | 8.96 s |

### fourteen (load 2.90, 2.79, 2.69)

| contestant | cold | warm |
|---|---|---|
| js-x86, built by RC1 | 93 ms | 107 ms (driver 83 ms) |
| js-x86, built by RC2 | 53 ms | 110 ms (driver 87 ms) |
| `roc build --opt=dev`, RC1 | 0.13 s | 0.09 s |
| `roc build --opt=dev`, RC2 | 0.16 s | 0.07 s |
| `roc build --opt=speed`, RC1 | 1.79 s | 1.66 s |
| `roc build --opt=speed`, RC2 | 1.71 s | 2.09 s |

### big daddy (load 3.01, 2.82, 2.70; no Roc port)

| contestant | cold | warm |
|---|---|---|
| js-x86, built by RC1 | 1,222 ms | 1,200 ms (driver 1,155 ms) |
| js-x86, built by RC2 | 1,151 ms | 1,137 ms (driver 1,091 ms) |

### What the race says about the thesis

**Against `--opt=speed`, js-x86 wins easily:** about 18 times faster on fib (0.14 s against 2.5 s), 60 times on bank (0.14 s against 8.5 s) and 16 times on fourteen (0.11 s against 1.7 s). That is Roc's build that makes a fast executable, and the one the races run.

**Against `--opt=dev`, the thesis does not hold.** Roc's dev build makes a runnable executable in 0.06 to 0.2 s, about as fast as js-x86 or faster, even cold. But what it makes is not comparable. Each dev executable is about 2.3 MB, against 32 to 180 KB at `--opt=speed`, and it runs 10 to 25 times slower: fib(100,000) took 19.5 s from RC1's dev build and 1.2 s from its speed build, both in the same run. Their outputs are the same. The size and speed suggest that the dev backend carries the program with an interpreter rather than compiling it, though nothing here checks that.

So js-x86, at 0.1 s to a whole static executable, builds at the speed of Roc's dev build and makes code at the speed of the races' compiled times. Its time goes to the driver itself; carrying the hex to the file costs about 20 to 50 ms. Big daddy, the largest program at over a second, shows how js-x86's build time grows with the program. That cost is in js-x86's front end and lowering, which no profile here took apart.

## Reproducing it

    shale x86/buildrace.shale rocs=tools:roc-0.1.0_RC1/roc,build:scratch/wasm-host/dl/rc2/roc-linux_x86_64-0.1.0-RC2/roc

That runs every part, with 5 warm runs, and ends with the byte-for-byte check of the Roc-built executables. It takes about an hour: js-x86's release build is about 4 to 5 minutes, and the self part makes six of them. `parts=bytes,build,speed` leaves that part out, but still makes js-x86 once for each compiler. The gate under RC2 needs the local override this run used: `roc-version` set to `0.1.0-RC2`, and `pinned_roc` pointed at the unpacked binary. Neither is ever committed.
