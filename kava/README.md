# kava: KavaScript's front end

The code here was written by AI coding agents (Claude), with human supervision.

KavaScript (a code name: K comes after J) is the JavaScript subset that `js/` interprets, with additions that are all optional: every program the subset accepts is a KavaScript program, unchanged, and every KavaScript program transpiles to JavaScript, so node is its oracle and gives its benchmarks. Its files are `.kava`; a `.js` file is taken as it is. This folder is its front end: it reads the additions and writes JavaScript in two modes, and touches neither the VM nor js-x86's lowering.

    shale kava/kava.shale file=kava/tests/dedupe.kava mode=strip
    shale kava/kava.shale file=kava/tests/dedupe.kava mode=checked out=build:kava/dedupe.js
    shale kava/programs.shale          # the tier check.shale runs

## The additions

Each stands where today's JavaScript has a syntax error, or where TypeScript writes a type, so no JavaScript program changes meaning. `roc/KavaReader.roc`'s header has the grammar, and `roc/KavaTypes.roc`'s the types'.

| Addition | Where it goes |
|---|---|
| `requires e`, `ensures e` (with `result` and `old(x)`) | between a function's parameters (and its result's type) and its body, for a declaration, an expression, a method or an arrow |
| `cost O(...) [where n = e, ...]` | there too, and after a loop's head; read and carried, not checked yet |
| `invariant e` | after a `while`'s or a `for`'s head, before its block; `invariant e;` among a class's members, holding after its constructor and each method that isn't static |
| `ghost let x = e;`, `ghost <statement>`, `ghost { ... }`, a class's `ghost f = e;` | where a statement or a member goes |
| `: T` (`number`, `i32`, `i64`, `string`, `boolean`, `bigint`, a class, `T[]`, `{ a: T, ... }`) | after a parameter, after the parameters (the result), after a `let`'s or a `const`'s name |
| `own`, `lent` | before a parameter, and before a call's argument: `push(own a, 4)`, `total(lent xs)` |
| `law name(...) { ... }` | where a statement goes; carried whole |

## The two modes

**`strip`** takes every addition out. The reader edits the program's own bytes (`roc/Edits.roc`), so a program with no additions comes out byte for byte the same, and every line keeps its number. The stripped text is then read by the subset's own parser, so whatever isn't an addition is held to the subset.

**`checked`** writes the checks in, each on the line it guards, and the functions they call after the program (`roc/KavaChecks.roc`). Each failure throws an Error whose message names the clause, the file and the line: `kava: requires amount > 0 failed (violations.kava, line 13)`.

- `requires`, a typed parameter, a `lent` parameter and each `old(x)` (saved in a local) are checked at the function's entry.
- Each `return e` becomes `{ const result = e; <the result's type, each ensures, the class's invariants> return result; }`, and the end of a body the same with `undefined`.
- A loop's invariant is checked at the head of every pass.
- Ghosts are ordinary code (strip mode deletes them).
- `own a` hands `a`'s value over and leaves a poison in `a`, which throws at any use, and every later read of `a` is checked; `lent` passes a view whose every write throws.

**The static rules** (`roc/KavaRules.roc`) refuse a program before it is written: ordinary code that names a ghost or declares a ghost's name, a ghost that writes ordinary state, and a use of a variable after its hand-over that the block shows, or a hand-over on every pass of a loop.

## The tests

`kava/programs.shale` holds strip and checked to the identity on every program of `js/tests/` and `x86/tests/`, each `.kava` program of `kava/tests/` in both modes to its `.strip.out` and `.checked.out` under node, and each of `kava/tests/refused/` to the refusal its first line names.
