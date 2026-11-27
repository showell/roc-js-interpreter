# The build race

The code here was written by AI coding agents (Claude), with human supervision.

`x86/buildrace.shale` times what it takes to go from a race's source to an executable that runs it, with js-x86 and with Roc's own compiler, and how big and how fast that executable is. js-x86 has no LLVM and no type inference, so it ought to build much faster than `roc build` does. The script also gives a new Roc release some exercise: it builds js-x86 with each Roc named, holds the executables they write to the same bytes, and times the Roc races' release executables. x86/RC2.md has the first results, for RC1 against RC2.

(The script sits beside x86/race.shale, not in this folder: a library is named only from beside a script's own file or below it, and it uses x86/executables.shale.)

## Running it

From the repository's root, with the box quiet:

    shale x86/buildrace.shale rocs=tools:roc-0.1.0_RC1/roc,build:scratch/wasm-host/dl/rc2/roc-linux_x86_64-0.1.0-RC2/roc

`rocs=` names each compiler by a Shale path, a mount's or an absolute one; left out, it is the one `roc-version` pins. The first compiler is the baseline for the byte comparison and the ratios. `parts=` picks some of `self`, `bytes`, `build`, `speed` and `size` (the first four unless named), `runs=` sets the warm runs and the speed runs (5), and `self_runs=` sets the warm runs of js-x86's own build, which takes minutes (2). A compiler outside a `tools` mount is run with a `want`, so it is logged.

For sizes alone, which don't depend on the load, `shale x86/buildrace.shale parts=size` builds each executable once, untimed, in about 20 seconds: no js-x86 release build is waited for, since js-x86's dev build (tools/roc_build.shale's cached one) writes the same bytes.

Everything runs niced, one program at a time. Each table prints the load average before it, and the script prints it again at the end. Other lanes' work moves every number, so a run whose numbers will be quoted is made on a quiet box.

## What each part measures

- **self:** `roc build --opt=speed x86/roc/JsToX86.roc`, cold and warm. The executable it makes is the js-x86 the other parts use.
- **bytes:** every program in `x86/tests/`, `x86/tests/refused/` and `js/tests/`, and the four races, compiled by each compiler's js-x86. Each output (the executable's hex, or the refusal) is held to the first compiler's by its sha256, along with the exit code. A program whose output differs is named.
- **build:** one table for each race. Each contestant takes the source in and leaves an executable on the disk:
  - **js-x86**, by each compiler's release build. The time counts the driver's run, xxd turning its hex into the file's bytes (`hex_written` in x86/executables.shale; it was Shale's `bytes_of_hex`, about 20 ms of the fib race's step, before 2026-11-27), and the `chmod`, all measured by the wall clock (`date +%s%N` before and after, about a millisecond each). The driver's own time is in brackets. Cold is the first run after the build; js-x86 keeps no cache, so cold and warm differ only by what the kernel has cached.
  - **`roc build --opt=dev`** and **`--opt=speed`** of the race's Roc port, by each compiler, from the port's folder. Each counts the compiler's whole run, including linking the platform's host. Cold means a fresh, empty folder as `XDG_CACHE_HOME` and `TMPDIR`, so Roc finds nothing from an earlier build. Warm means the same folder again, `runs` times; the table gives the median.
  - Big daddy has no Roc port, so only js-x86 builds it, and while js-x86 refuses it the row is the refusal.
- **speed:** each Roc race's `--opt=speed` executable, run with the race scripts' small sizes (fib 100,000, bank 2,000,000 transfers, fourteen 300 rounds), and js-x86's executable of each race at the same size (big daddy at 30 rounds), compiled from a copy of the JavaScript with its `const N`, `TRANSFERS` or `ROUNDS` line set to it. The executables and the compilers take turns, `runs` times each, and the table gives each one's median wall time, and the last compiler's median over the first's. Each kind's outputs from the different compilers must be the same, and a difference is printed. Roc's dev executables aren't run: they are 10 to 25 times slower (below), and would take minutes.
- **size:** each executable built once, untimed, for the summary alone.

- **The summary.** A run whose parts include `build`, `speed` or `size` ends with one table of every executable the build race makes: js-x86's of each race, and the dev and speed builds of each Roc port. An executable this run hasn't made is built first, untimed, so nothing an earlier run left behind (of older code) is measured. Its columns:
  - **build (warm):** the build part's warm median, the same number as its table; `-` when the build part didn't run.
  - **run:** the speed part's median; `-` when it didn't run, and always for Roc's dev builds.
  - **bytes:** the file's size.
  - **stripped:** the size of a copy after `strip` (`strip -o`, so the executable itself is never changed). This is the fair comparison. Roc's executables carry their symbols and DWARF debug information (`with debug_info, not stripped`, says `file`), which a run never reads: stripping takes about half of a dev build's bytes, most of them `.debug_info` and `.debug_line`. js-x86 writes no section headers, symbols or debug information, so there is nothing to strip and its two numbers are the same.
  - **text, data, bss:** what `size` (binutils) counts: code and read-only data, initialized writable data, and zeroed memory. js-x86's executables have no section headers, so `size` sees nothing in them; their numbers are their load segments' instead (`readelf -l`: an executable or read-only segment's file bytes are text, a writable one's are data, and its memory past them is bss). js-x86 writes one segment, readable and executable, holding its code and its constants, and maps its heap at run time, so all of its bytes are text.
  - **linked:** whether `file` says it is statically or dynamically linked. Under the table, one line for each kind gives `file`'s whole description, less its build id.

- **Every run ends with** each Roc-built executable (js-x86, and each race's dev and speed builds the run made or found) held byte for byte to the first compiler's. When two compilers write the same bytes, any gap in their run times is the box's noise.

The Roc dev builds (`--opt=dev`) are about 2.3 MB each and run 10 to 25 times slower than the speed builds. Their size and speed suggest that the dev backend at RC1 and RC2 carries the program with an interpreter rather than compiling it to machine code, but nothing here checks that. So js-x86's real rival on build time is `--opt=speed`, which also makes an executable at full speed.

## Sizes (2026-11-27)

`shale x86/buildrace.shale parts=size`, master ad850cf (milestone 6's lane 1, element kinds in each array's header), Roc 0.1.0_RC1. Sizes don't move with the box's load. These executables are the races as written, not the speed part's sized copies, which differ from them only by a constant.

| race | executable | bytes | stripped | text | data | bss | linked |
|---|---|---|---|---|---|---|---|
| fib | js-x86 | 31,115 | 31,115 | 31,115 | 0 | 0 | static, no sections |
| fib | roc --opt=dev | 2,275,992 | 1,092,064 | 966,669 | 111,656 | 8,672 | static-pie |
| fib | roc --opt=speed | 45,504 | 38,696 | 31,675 | 576 | 4,128 | static-pie |
| bank | js-x86 | 45,069 | 45,069 | 45,069 | 0 | 0 | static, no sections |
| bank | roc --opt=dev | 2,417,128 | 1,226,392 | 1,036,413 | 176,352 | 8,656 | static-pie |
| bank | roc --opt=speed | 179,840 | 169,480 | 109,907 | 53,536 | 4,408 | static-pie |
| fourteen | js-x86 | 29,687 | 29,687 | 29,687 | 0 | 0 | static, no sections |
| fourteen | roc --opt=dev | 2,347,640 | 1,165,872 | 1,034,437 | 115,832 | 8,696 | static-pie |
| fourteen | roc --opt=speed | 32,296 | 26,248 | 20,111 | 416 | 4,272 | static-pie |
| bigdaddy | js-x86 | 90,622 | 90,622 | 90,622 | 0 | 0 | static, no sections |

Every executable here is static: js-x86's are `statically linked, no section header`, and Roc's, the program linked with the default platform's host, are `static-pie linked, with debug_info, not stripped`. None needs a dynamic loader or a shared library.

Stripped, js-x86's executables are 0.80 of Roc's speed builds on fib, 0.27 on bank and 1.13 on fourteen, and 27 to 39 times smaller than the dev builds. Each carries js-x86's runtime, as each of Roc's carries the platform's host.

The SAT race (x86/satrace) isn't in the build race: its Roc is rocsat, another repository on another pin. Its js-x86 executable was 163,180 bytes when x86/satrace/README.md was written.

Where js-x86's own time goes, phase by phase, and what was done about it, is x86/buildrace/PROFILE.md (x86/buildtime.shale measures it).

Everything is written under `scratch=` (`build:scratch/buildrace`), in one folder for each compiler, named after what its `roc version` prints.
