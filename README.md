# roc-js-interpreter

The code here was written by AI coding agents (Claude), with human supervision. Point an agent at this repo to extend it: `CLAUDE.md` gives it the rules.

A subset of JavaScript run by a bytecode VM written in Roc, a web playground where a program draws on a canvas as it runs, and a corpus that holds the language to node. Every program in the subset is real JavaScript, so node is a free oracle: what node prints for a program is what the interpreter must print.

It has four parts, each with its own README or manuscript:

- [js/](js/README.md): the interpreter, its playground and its tests. Its README says what the subset holds, how the VM and its collector work, and how each part is tested.
- [js-book/](js-book/book.md): the book *Compiling JavaScript in Roc*, built with roc-apps' book builder. It tells how the compiler and the interpreter work and what they taught us about Roc.
- [x86/](x86/README.md): a compiler from the subset to static Linux x86-64 executables, every byte written by Roc. It compiles numbers, booleans, strings, arrays, plain objects, Maps and Sets (NaN-boxed, on a heap with a mark-sweep collector, x86/COLLECTOR.md), loops, recursive functions, closures, classes, `switch`, exceptions and timers; how many of the corpus's programs it compiles is x86/README.md's "The corpus", held in `x86/corpus.txt`, and its fib beats node's wall-clock time (x86/README.md, "fib, compiled and timed").

- [kava/](kava/README.md): KavaScript, the subset with optional contracts, ghosts, types and ownership, and its front end, which writes it as plain JavaScript or with the checks written in.

The first two moved here from [roc-apps](https://github.com/showell/roc-apps) with their history, so a commit message older than the move may name a file of roc-apps that this repository doesn't have.

## Before you build

- **The checkouts beside this one.** The book and the tools reach four repositories by relative path, so clone each next to this checkout, in the same folder:
  - [roc-apps](https://github.com/showell/roc-apps), whose `book_builder/` builds the book (the book's app names its platform and builder package as `../../../roc-apps/book_builder/...`);
  - [roc-syntax-color](https://github.com/showell/roc-syntax-color), which colors the book's code;
  - [roc-markdown](https://github.com/showell/roc-markdown), which the book builder imports;
  - [roc-alloc-trace](https://github.com/showell/roc-alloc-trace), which counts the allocations the controls hold (`js/controls.shale`).
- **The Roc pin.** `roc-version` names the Roc nightly, installed at `~/tools/roc-<pin>/roc`. It moves in step with roc-apps' pin, since the book builder holds its Roc to roc-apps' `roc-version` exactly. A sandbox that can't reach Roc's releases takes the compiler from roc-apps' toolchain release, as roc-apps' `CLAUDE.md`, §2, says.
- **clang**, the system's, compiles the playground's wasm host, `js/wasm/platform/host.c`, for `--target=wasm32-unknown-unknown`; Roc links the wasm itself (`js/build.shale`).
- **node 22** runs the oracle and the page's check, and Chromium, found through `PLAYWRIGHT_BROWSERS_PATH`, runs the book's check and the page's shots.
- **[Shale](https://github.com/showell/shale)** runs every script here. On our box Shale is the only shell, and the scripts reach the dev channel and the sibling checkouts through its mounts (`build:`, `repos:`).

## Checking it

    shale check.shale          # the Roc recipes, the roots, roc fmt, roc check, js/'s expects, the oracle, the canvas samples, the bytecode dump, x86's expects, hello world, fib and compiled programs, and kava's front end
    shale check.shale js=1     # the controls' allocations, in the release and the dev build
    shale js/build.shale       # the playground, built and checked, into the dev channel's /js/
    shale js-book/book.shale   # the book, built and checked, into the dev channel's /js-book/

`js/README.md`, "Running it and the tests", lists the rest.

## Where it runs

The playground is [roc.lynrummy.com/js/](https://roc.lynrummy.com/js/) and the book is [roc.lynrummy.com/js-book/](https://roc.lynrummy.com/js-book/). Both are published by roc-apps, whose `site/` folder holds the live site. The page's link home, `../shared/home.js`, is the site's own file, which the site supplies in its dev channel and on the live site alike.

## License

UPL 1.0; see [LICENSE](LICENSE).
