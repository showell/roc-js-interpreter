# The big-daddy race

The code here was written by AI coding agents (Claude), with human supervision.

`bigdaddy_race.js` is a breadth race. The fib and fourteen races are narrowly arithmetic, and the bank race is one loop of method calls; this one asks for everything at once: strings built and taken apart, objects and destructuring, closures, Map and Set, exceptions, merge sort and `sort`, a Dijkstra walk over a street map, a sieve, word counts and the timers. The point is to find where the compiled program is weak, not to flatter it.

**It is a fork of `js/tests/54-big-daddy.js`**, "a day in a little simulated city". It started as 54 in a loop, and it is its own program from here on: it may drift from 54 where the comparison with node suggests, and it never feeds back into `js/tests/`. The rule of the races still holds: ordinary JavaScript, changed to probe where we are weak, never shaped toward our compiler.

- **The day** is 54's six stages in one function, `day(seed, talk)`, run `ROUNDS` times with the seed `2026 + round`, so no two days build the same city. The stages are 54's: the census (written as text and parsed back), the clerk's lookups (a TypeError and a RangeError caught), the sort, the streets, the sieve and the newsletter's words, and the evening's light count, a plain loop in each day.
- **Printing stays out of the timed work.** The first day talks: it prints 54's transcript, `console.log` of nested objects and a Map included. The other days print nothing.
- **The checksums.** Each stage's checksum goes into a ledger of its own across the days. At the end the program prints the seven ledgers and the ledgers combined.
- **The timers run once**, after the last day, over the last city: a timeout cleared, an interval ticking 19:00 to 22:00, and the midnight report. Their delays are 0, since 54's 250 ms and 1.5 s would be sleep, not work, and the report is scheduled from the last tick, so its order never depends on the clock.
- **The crow's distance is printed in whole hundredths** (`Math.round(straight * 100)`, 1131), where 54 prints `/ 100` (11.31). js-x86's executables can't print a fraction yet (milestone 4, number printing), and Steve chose this way around it over dropping the clause. No checksum ever saw the number.

From the repository's root:

    shale x86/bigdaddy.shale                  # 10,000 rounds, about 18 to 20 s under node
    shale x86/bigdaddy.shale size=small       # 30 rounds, about 0.3 s under node, for tuning
    shale x86/bigdaddy.shale rounds=500       # any count of at least 1
    shale x86/bigdaddy.shale size=small runs=5   # five runs of each in turn, and the medians

The contestants are the program compiled by js-x86 and the same program under node. Until js-x86 compiles it, the script prints `compiled: not compiled yet:` and js-x86's refusal, and times node alone. node's last two lines are held to the ledgers stored in the script for 10,000 and 30 rounds; the compiled program's whole output will be held to node's.

## Sizes (2026-11-26)

`SIZE` is 10 (200 residents, a 9x9 street map, a sieve to 3,000, a 40-issue newsletter), and `ROUNDS` scales the work. At SIZE 10 node runs a day in about 1.8 ms once warm.

| rounds | node | js-vm (release, context) |
|---|---|---|
| 30 (`size=small`) | 0.34 to 0.38 s (load 1.5); 0.53 s once at load 2 | 3.54 s |
| 60 | 0.42 s | 6.24 s |
| 4,000 | 7.27 s (load 2.1) | |
| 10,000 (as written) | 19.95 s (load 2.0) | |

The box was shared all along (another lane compiling, load 1.5 to 2.1), so these are single runs, not medians. js-vm is the bytecode VM's release build, 9040235960356694, after 34af33f; node and js-vm print the same output at 3, 30 and 60 rounds. js-vm is not a contestant: its number is here for context, about 10 to 15 times node at the small size.

**Found on the way:** js-vm's `lastIndexOf` gave a fraction far into an array (2999.0000000000005 at the sieve's 3,000), which held this race up until master's 34af33f fixed it.

## What stops the compiled program (2026-11-26, master 9287a30)

Found by compiling a copy of the race with js-x86 and, at each refusal or stop, changing the copy by hand to reach the next. The copies were scratch and are not committed. In the order met, which is also the order I'd fix them:

1. **`UpdateProperty`, `o.k++`.** *Done 2026-11-26*: `runtime_update_property_hashed` reads the property, holds it to a number, steps it and writes it back, by the runtime's hashed read and write (the in-line field places of FieldSlots are not used for it yet). The race and 54 then meet blocker 2. One site: line 151, `entry.people++`. The first refusal, as it is 54's. **Small:** the compiler's `GetProperty`/`SetField` pair with the `++` between, as compound assignment to a property (`stats.perks += ...`, `entry.totalAge += age`) is already compiled; it touches Lowering's property instructions and FieldSlots.
2. **A function with more loops than the widenings allow.** *Done 2026-11-26*: each loop's head has its own `most_widenings` (16), counted by its instruction, so the cap of a function grows with its count of loop heads (x86/README.md, where a loop's head widens; x86/tests/loops-many-heads.js and refused/loop-widenings.js hold it). Before that, `the function \`day\`: a loop's kinds never settle, at instruction N`: Lowering's `code_items` widened one loop's head a walk and gave up after 16 walks for the whole function, and `day` has about 20 loops (54's top level the same). The instruction it named was only the last head widened, and none of the loops was at fault. To reach past it a scratch copy split `day` into a function a stage.
3. **A string's `padEnd`.** *Done 2026-11-26*, with 4: `padEnd` is one of the methods StringMethods' table holds. One site: line 349, `"headline:".padEnd(12)`. A refusal: `the method \`padEnd\` of a string is not compiled yet`. **Small:** a runtime routine beside the string methods already written; it touches MethodTables and the string runtime. (The copy used the literal `"headline:   "`.)
4. **A string's methods on a value whose kind isn't known.** *Done 2026-11-26*: `runtime_string_method` (x86/README.md, "A string's methods") calls a string method's routine when the value is a string, and the value's own property otherwise; `trim`, `trimStart`, `trimEnd`, `toUpperCase`, `toLowerCase`, `substring`, `repeat`, `padStart`, `padEnd`, `startsWith`, `endsWith`, `replace`, `replaceAll` and a known string's `concat` are written, and 18 and 59 of the corpus match node with them. Before that, the program compiled, and its executable stops at once with `x86: this property read is not compiled yet`, at `line.trim()` (line 104), whose `line` is an item of `split`'s array, so a `Value`. `runtime_get_property` (Runtime.roc's `property_items`) reads only a string's or an array's `length`, an object's property and a Map's or Set's `size`; it has no way to a string method when the receiver's kind is found as the program runs. **Medium:** a dynamic dispatch of the string methods, which also needs each method itself: x86/README.md's corpus list names `trim` and `toUpperCase` as not written. The sites that will meet it: `trim` (104, 105), `split` (103, 105, 335), `charCodeAt` (31, 52), `toUpperCase` (331), `toLowerCase` (336), `replaceAll` (337), `slice` and `indexOf` of a string (349). It touches MethodTables and Runtime's property and method routines.

I stopped there, so whatever lay past 4 was not known then. The guesses made then (array destructuring with a default, the object rest pattern, the catch pattern, labelled `break`, `do ... while`, `**`) all compile, as the next section found.

## What it meets now (2026-11-26, after blockers 1 to 4)

**The race compiles as written**, `day` one function, and its executable prints what node prints, byte for byte. `shale x86/bigdaddy.shale size=small runs=5` on the box at a load of 0.5 to 0.7, the medians of five: compiled 0.19 s, node 0.35 s, compiled/node 0.55 (the executable 80,396 bytes). Earlier, with `day` split into a function a stage (a scratch copy, not committed), at a load of 2.2 to 2.7, five runs at 30 rounds and three at 300, the compiled program then node:

| rounds | compiled | node |
|---|---|---|
| 30 (`size=small`) | 150 to 164 ms (148 to 160 ms CPU) | 183 to 196 ms |
| 300 | 1,543 to 1,872 ms (1,482 to 1,644 ms CPU) | 697 to 833 ms |

So the compiled day costs about 5 ms to node's warm 2.4 ms: about twice node, once node's start (about 0.13 s) is paid. At 30 rounds the start hides it. Which stage dominates is not measured yet.

**What's next at the race's size is memory.** No collector runs, and a day allocates about 2 to 3.5 MB: 300 rounds fit the heap of 1 GiB, and past about 600 (600, 800, 1,000, 1,500 and 2,000 were tried on the split copy) the executable stops with `x86: out of memory: the heap of 1 GiB is full, and no collector runs yet`. 10,000 rounds would need some 20 to 35 GB. That is the collector's milestone, not a method or an instruction.

**54 compiles too** and stops where node prints its first fraction, the crow's 7.07 (milestone 4, number printing), so it stays out of the corpus (x86/README.md's table).

**Milestone 4 (fractions):** the crow's distance was the race's one fraction printed, and it prints whole hundredths (above). Nothing else in the race prints or checksums a fraction: every ledger is an integer below 1,000,003.

## Candidates for Steve (not made)

- **A per-stage timing under node** wasn't done, for want of time on a busy box; it would show which stage dominates. A guess from reading the code: the census (200 lines of text built, split and parsed, every checksum's `String(value)` walked a character at a time) and the two sorts dominate, and the sieve (3,000 booleans) and the clerk (four lookups) are too small to measure. If so, the clerk could do its lookups over every resident, and the sieve could grow on its own.
- **`day` stays one function of about 20 loops.** That is ordinary code, and it compiles now as written; splitting it would shape the program toward the compiler.
