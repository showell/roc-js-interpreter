# The build race

The code here was written by AI coding agents (Claude), with human supervision.

`x86/buildrace.shale` times what it takes to go from a race's source to an executable that runs it, with js-x86 and with Roc's own compiler. js-x86 has no LLVM and no type inference, so it ought to build much faster than `roc build` does. The script also gives a new Roc release some exercise: it builds js-x86 with each Roc named, holds the executables they write to the same bytes, and times the Roc races' release executables. x86/RC2.md has the first results, for RC1 against RC2.

(The script sits beside x86/race.shale, not in this folder: a library is named only from beside a script's own file or below it, and it uses x86/executables.shale.)

## Running it

From the repository's root, with the box quiet:

    shale x86/buildrace.shale rocs=tools:roc-0.1.0_RC1/roc,build:scratch/wasm-host/dl/rc2/roc-linux_x86_64-0.1.0-RC2/roc

`rocs=` names each compiler by a Shale path, a mount's or an absolute one; left out, it is the one `roc-version` pins. The first compiler is the baseline for the byte comparison and the ratios. `parts=` picks some of `self`, `bytes`, `build` and `speed` (all four unless named), `runs=` sets the warm runs and the speed runs (5), and `self_runs=` sets the warm runs of js-x86's own build, which takes minutes (2). A compiler outside a `tools` mount is run with a `want`, so it is logged.

Everything runs niced, one program at a time. Each table prints the load average before it, and the script prints it again at the end. Other lanes' work moves every number, so a run whose numbers will be quoted is made on a quiet box.

## What each part measures

- **self:** `roc build --opt=speed x86/roc/JsToX86.roc`, cold and warm. The executable it makes is the js-x86 the other parts use.
- **bytes:** every program in `x86/tests/`, `x86/tests/refused/` and `js/tests/`, and the four races, compiled by each compiler's js-x86. Each output (the executable's hex, or the refusal) is held to the first compiler's by its sha256, along with the exit code. A program whose output differs is named.
- **build:** one table for each race. Each contestant takes the source in and leaves an executable on the disk:
  - **js-x86**, by each compiler's release build. The time counts the driver's run, xxd turning its hex into the file's bytes (`hex_written` in x86/executables.shale; it was Shale's `bytes_of_hex`, about 20 ms of the fib race's step, before 2026-11-27), and the `chmod`, all measured by the wall clock (`date +%s%N` before and after, about a millisecond each). The driver's own time is in brackets. Cold is the first run after the build; js-x86 keeps no cache, so cold and warm differ only by what the kernel has cached.
  - **`roc build --opt=dev`** and **`--opt=speed`** of the race's Roc port, by each compiler, from the port's folder. Each counts the compiler's whole run, including linking the platform's host. Cold means a fresh, empty folder as `XDG_CACHE_HOME` and `TMPDIR`, so Roc finds nothing from an earlier build. Warm means the same folder again, `runs` times; the table gives the median.
  - Big daddy has no Roc port, so only js-x86 builds it, and while js-x86 refuses it the row is the refusal.
- **speed:** each Roc race's `--opt=speed` executable, run with the race scripts' small sizes (fib 100,000, bank 2,000,000 transfers, fourteen 300 rounds). The compilers take turns, `runs` times each, and the table gives each one's median wall time, and the last compiler's median over the first's. The outputs of the different compilers' executables must be the same, and a difference is printed.

- **Every run ends with** each Roc-built executable (js-x86, and each race's dev and speed builds the run made or found) held byte for byte to the first compiler's. When two compilers write the same bytes, any gap in their run times is the box's noise.

The Roc dev builds (`--opt=dev`) are about 2.3 MB each and run 10 to 25 times slower than the speed builds. Their size and speed suggest that the dev backend at RC1 and RC2 carries the program with an interpreter rather than compiling it to machine code, but nothing here checks that. So js-x86's real rival on build time is `--opt=speed`, which also makes an executable at full speed.

Everything is written under `scratch=` (`build:scratch/buildrace`), in one folder for each compiler, named after what its `roc version` prints.
