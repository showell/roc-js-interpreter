# kava: KavaScript's front end

The code here was written by AI coding agents (Claude), with human supervision.

KavaScript (a code name: K comes after J) is the JavaScript subset that `js/` interprets, with additions that are all optional: every program the subset accepts is a KavaScript program, unchanged, and every KavaScript program transpiles to JavaScript, so node is its oracle and gives its benchmarks. Its files are `.kava`; a `.js` file is taken as it is. This folder is its front end: it reads the additions and writes JavaScript in three modes, checks `cost` claims by counting under node, and touches neither the VM nor js-x86's lowering.

    shale kava/kava.shale file=kava/tests/dedupe.kava mode=strip
    shale kava/kava.shale file=kava/tests/dedupe.kava mode=checked out=build:kava/dedupe.js
    shale kava/kava.shale file=kava/tests/cost/cliff.kava mode=counted
    shale kava/cost.shale file=kava/tests/cost/cliff.kava   # its cost claims, checked
    shale kava/programs.shale          # the tier check.shale runs

## The additions

Each stands where today's JavaScript has a syntax error, or where TypeScript writes a type, so no JavaScript program changes meaning. `roc/KavaReader.roc`'s header has the grammar, and `roc/KavaTypes.roc`'s the types'.

| Addition | Where it goes |
|---|---|
| `requires e`, `ensures e` (with `result` and `old(x)`) | between a function's parameters (and its result's type) and its body, for a declaration, an expression, a method or an arrow |
| `cost O(...) [where n = e, ...]` | there too, and after a loop's head; a function's is checked by `kava/cost.shale`, a loop's not yet |
| `size name(n) { ... }` | where a statement goes, at the top level: the generator of `name`'s arguments at size `n`, returned as an array (`return [xs]`) |
| `invariant e` | after a `while`'s or a `for`'s head, before its block; `invariant e;` among a class's members, holding after its constructor and each method that isn't static |
| `ghost let x = e;`, `ghost <statement>`, `ghost { ... }`, a class's `ghost f = e;` | where a statement or a member goes |
| `: T` (`number`, `i32`, `i64`, `string`, `boolean`, `bigint`, a class, `T[]`, `{ a: T, ... }`) | after a parameter, after the parameters (the result), after a `let`'s or a `const`'s name |
| `own`, `lent` | before a parameter, and before a call's argument: `push(own a, 4)`, `total(lent xs)` |
| `law name(...) { ... }` | where a statement goes; carried whole |

## The three modes

**`strip`** takes every addition out. The reader edits the program's own bytes (`roc/Edits.roc`), so a program with no additions comes out byte for byte the same, and every line keeps its number. The stripped text is then read by the subset's own parser, so whatever isn't an addition is held to the subset.

**`checked`** writes the checks in, each on the line it guards, and the functions they call after the program (`roc/KavaChecks.roc`). Each failure throws an Error whose message names the clause, the file and the line: `kava: requires amount > 0 failed (violations.kava, line 13)`.

- `requires`, a typed parameter, a `lent` parameter and each `old(x)` (saved in a local) are checked at the function's entry.
- Each `return e` becomes `{ const result = e; <the result's type, each ensures, the class's invariants> return result; }`, and the end of a body the same with `undefined`.
- A loop's invariant is checked at the head of every pass.
- Ghosts are ordinary code (strip mode deletes them).
- `own a` hands `a`'s value over and leaves a poison in `a`, which throws at any use, and every later read of `a` is checked; `lent` passes a view whose every write throws.

**`counted`** is the checked build with a counter of the program's work written in (`roc/KavaCost.roc`, whose header and cost table say what counts): every trip of an ordinary loop counts one, every call of a builtin the table names counts its cost at run time (`includes`, `indexOf`, `lastIndexOf`, `shift`, `join`, `map`, `filter`, `forEach` and `reduce` the receiver's length; `unshift` and `splice` that and their arguments; `concat` the receiver's and every argument's length; `slice` its result's; a Map's or a Set's `get`, `set`, `has`, `add` and `delete` one), a spread `...v` counts `v`'s length, and a string grown by name (`s += e` as a statement, `s = s + e`) counts `s`'s length. A function with a `cost` clause is framed, its entry to its every way out, so its count holds every call it makes, a helper's with no claim included; a helper with its own claim is measured on its own as well. Ghosts and clauses count nothing. A counted build prints what its checked build prints; only an error that quotes a counted expression reads differently.

## Checking a cost claim

`kava/cost.shale` writes the program in counted mode and runs it under node, which, after the program's top level, calls each costed function on its `size` generator's arguments at n, 2n, 4n and 8n (`base=`, a power of two, 1024 unset) and prints its counts. The generator stands beside its function, takes the size, and returns the arguments; the claim's `where n = ...` is evaluated at the function's entry, and must give back the size asked for:

    function dedupe(xs: string[]): string[] cost O(n) where n = xs.length { ... }

    size dedupe(n) {
      const xs = [];
      for (let i = 0; i < n; i++) xs.push("w" + Math.floor(i / 2));
      return [xs];
    }

A claim is an upper bound: each doubling's ratio of counts must stay at or under its class's ratio (O(1) 1, O(log n) (k+1)/k, O(n) 2, O(n log n) 2(k+1)/k, O(n^2) 4, from m = 2^k) times 1 + 1/(2K), K the log of the last doubling's size; the runner's header says why that tolerance lets no class pass for the next one up. A claim that fails names the site whose count grows fastest:

    FAIL dedupe (cliff.kava, line 4): the counts grow faster than O(n) where n = xs.length
      n = 1024, 2048, 4096, 8192
      counts 263168, 1050624, 4198400, 16785408: ratio 3.99, 4.00, 4.00 a doubling; O(n) allows at most 2.08
      the cliff: line 7, `includes` inside the loop at line 6, counts 262144, 1048576, 4194304, 16777216: ratio 4.00, 4.00, 4.00 a doubling

A claim the runner can't measure fails, saying why (no generator, no name, another class, a loop's claim). The check is empirical, the first of the sketch's two; the static one, the table multiplied through loops and calls, is a later lane's, and can read the same table.

**The static rules** (`roc/KavaRules.roc`) refuse a program before it is written: ordinary code that names a ghost or declares a ghost's name, a ghost that writes ordinary state, and a use of a variable after its hand-over that the block shows, or a hand-over on every pass of a loop.

## The tests

`kava/programs.shale` holds strip and checked to the identity on every program of `js/tests/` and `x86/tests/`, and counted mode to printing under node what each of them prints; each `.kava` program of `kava/tests/` in strip and checked modes to its `.strip.out` and `.checked.out` under node, and in counted mode to its `.checked.out`; each of `kava/tests/refused/` to the refusal its first line names; and each program of `kava/tests/cost/` to the cost runner's report in its `.cost.out`: the sketch's good `dedupe` holds, its cliff fails with the message above, and `composed.kava` shows costs composing through calls.
