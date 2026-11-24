# roc-js-interpreter

A subset of JavaScript run by a bytecode VM written in Roc, its playground,
and the book about it ([README.md](README.md); the interpreter itself is
[js/README.md](js/README.md)).

The general habits are roc-apps' (its `CLAUDE.md`, `docs/roc-style.md` and
`docs/roc-notes.md`): the Roc quality standard, the commit and gate rules,
Shale for every shell step. This file adds only what is particular here.

- **The gate** is `shale check.shale`, from the root. A change is done when
  it prints `check: N of N passed`. `shale check.shale js=1` is the
  allocation tier, and `js/build.shale` and `js-book/book.shale` are the
  page's and the book's own gates. Every count is held exact: the corpus's,
  the controls' (`js/controls/expected*.txt`), the book's expects, and the
  Roc recipes' in `tools/lints.shale`'s `HELD`, which came from roc-apps'
  quality baseline. Move one only with the change that moves it, and say why
  in the commit.
- **The Roc is the pin** in `roc-version`, at `tools:roc-<pin>/roc`. It
  moves with roc-apps' pin, in step, since the book is built by roc-apps'
  book builder, which holds its Roc to roc-apps' `roc-version`.
- **Some tools are copies of roc-apps', on purpose:** the prelude's
  `pinned_roc`, `built_roc` and `check_roc_version`, `tools/roc_build.shale`,
  `tools/alloc_ladder.shale`, `tools/alloc_trace.shale` and
  `tools/chromium.mjs`. Each header names its twin; a fix to one is a fix to
  look at in the other.
- **The book is built by roc-apps' book builder,** from the roc-apps
  checkout beside this one (`repos:roc-apps` on the box), and so is the
  book's app header (`../../../roc-apps/book_builder/...`).
- **The playground and the book build into the box's dev channel,**
  `build:roc-apps/next/js` and `next/js-book`, and roc-apps publishes them.
- The repository is public: no hosts, addresses or accounts in it.
