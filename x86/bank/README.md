# The bank race

The code here was written by AI coding agents (Claude), with human supervision.

`bank_race.js` makes a fixed number of transfers on a bank ledger, `TRANSFERS` (110,000,000 as written), chosen so that the compiled program takes about a minute on our box, as the fib race's N is. It is a second race beside the fib race (`x86/race/`), as plain as fib but reaching more of the language: a class with methods, a plain object used as a dictionary, string keys, `Object.keys`, `for ... of`, `%` and whole-number arithmetic. It uses no recursion.

- **The accounts:** 500 of them, each an `Account` (its name, a balance in whole cents, and counts of deposits, withdrawals and declines, with `deposit(amount)` and `withdraw(amount)`), kept in a plain object keyed by name (`"acct-217"`). The names are made once, at the start, and kept in an array too, so the transfers make no new strings or objects. The compiled program has no garbage collector, so a transfer that allocated would fill its 1 GiB heap.
- **A transfer** draws three numbers from a seeded Park-Miller generator, a `Random` (seed times 48271, mod 2^31 - 1; every product is below 2^47, so exact in a double): the payer, the payee and the amount, 1 to 50,000 cents. It looks both accounts up by name, and when the payer has the funds, `withdraw` and `deposit` move the money; otherwise `withdraw` counts a decline.
- **The audit:** every 10,000 transfers, an audit walks `Object.keys` of the dictionary and sums the balances. Money only moves, so the total must stay the opening total.

**No warm-up.** The self-paced race ran 2,000,000 untimed transfers before its clock started, so node's JIT had warmed up before it was timed: Steve's call, to give node slack for its warm-up penalty at a 1-second budget. A fixed-work race is timed from outside, start to exit, and at about a minute node's warm-up (about 4% of a 1-second race) is noise, so the slack is moot and the warm-up is gone.

**How it is checked:**

- The first 100,000 transfers are run first. The program prints the checksum of every account after them (balances and counts folded below a prime) beside a constant computed offline with node.
- It prints the audits it made and how many found a total other than the opening total.
- Last, it prints the transfers it made and the checksum of every account then.

`verify.js N` is a second implementation of the ledger (plain arrays indexed by account number, no class and no dictionary). It runs N transfers in node and prints the three lines the race must print, exactly: a wrong early checksum, an unbalanced audit or a wrong final checksum is a mismatch.

From the repository's root:

    shale x86/bank.shale                     # 110,000,000 transfers, about a minute compiled
    shale x86/bank.shale size=small          # 2,000,000 transfers, about a second compiled, for tuning
    shale x86/bank.shale transfers=2000000   # any count of at least 100,000
    shale x86/bank.shale size=small runs=5   # five runs of each in turn, and the medians

`transfers=` (or `size=small`) writes a copy of `bank_race.js` with its `const TRANSFERS` line changed, under the build mount, and the two JS contestants run that copy. The script builds js-x86 on the dev backend, writes the executable, builds `bank_race.roc`'s release executable, then runs the compiled executable, node and Roc, niced and never at the same time, each timed from outside by its wall clock, start to exit. Each contestant's output is held to verify.js's for that count. Each contestant gets one line, its wall time and whether its output matched; node's line adds the ratio of the compiled time to node's, and Roc's the ratio of the compiled time to Roc's. With `runs=k`, a last line gives the medians and their ratios. `check.shale` doesn't run it, since its numbers are timings.

**How the defaults were picked (2026-11-26).** After the hash index (ObjectTable.roc) and the hashes of literal keys, a quiet paired run of 18,000,000 transfers (load 0.83) took 9.71 s compiled, 0.54 µs a transfer, so the defaults were raised to 110,000,000 (about a minute) and 2,000,000 (about a second). The first calibration, below, was made before those two fixes.

The first paired run at that size, master 2026-11-26, load 0.68:

    compiled: 66.03 s, matched (verify.js)
    node: 13.19 s, matched (verify.js); compiled/node 5.01

**The first calibration.** Only from compiled runs, never beside node. The box didn't go below load 0.5 (other lanes were building), so the count is scaled, not measured. One run each of 100,000 to 1,600,000 transfers, at load 0.7 to 0.8, cost 3.1 to 3.6 µs a transfer, with no trend: the work grows linearly. 1,600,000 took 5.12 s, which scales to 18,000,000 in about 58 s; 300,000 took 0.97 s, the small size. Sets of runs at one count moved by half between minutes (seven runs of 300,000 a minute earlier took 1.21 to 1.52 s), so a single run of either size is noisy on a busy box.

**One reshape for js-x86.** The generator keeps its seed in itself, a `Random` object, rather than in a function `nextSeed(seed)` whose result the caller passes back to it. js-x86 refuses any program in which a function's result reaches its own parameter: `function t(s) { return s + 1; }` called as `t(t(1))` stops with "the kinds of the functions' parameters and results never settle". A guess at why, not checked: each pass computes the parameters' kinds from the last pass's results, and the results from the last pass's parameters, so the two swap between `Number` and `Value` every pass and never meet. The fix is in `x86/roc/Lowering.roc` (`items_with_numbers`), widening each pass's kinds with the last pass's.

## Against Roc (2026-11-26)

The third contestant is `bank_race.roc`, the race ported to Roc and built by Roc's release build (LLVM, `--opt=speed`), the plain translation with no optimizing. Its count is its argument (`bank-race-roc N`), so nothing of the race is known when Roc compiles it, and its three lines are held to verify.js's as the others are. What the port had to choose:

- **The dictionary is a `Dict(Str, Account)`, keyed by the same names.** The JS looks each account up by its name, and that lookup is most of the race's cost (below), so the fair port does a string-keyed lookup too, not a `List` read by account number. An `Account` is a nominal record with `deposit` and `withdraw` (`withdraw` answers `Withdrew(account)` or `Declined(account)`); a value can't be changed where it sits, so a changed account goes back under its name with `Dict.insert`, a second hashed lookup for each account a transfer changes, where the JS writes through the object it found.
- **The generator is a record holding its seed,** `next` giving the next one, the same arithmetic in `U64`.
- **The first 100,000 transfers run to `U64.min(count, check_at)`.** They depend on nothing the run gives, so Roc made them while compiling (`roc check` warned that the checksum's `if` was known); the minimum, which is always 100,000, ties them to the run.

`shale x86/bank.shale`, 110,000,000 transfers, one run of each, load 2.25 at the start (the box was busy):

    compiled: 56.63 s, matched (verify.js)
    node: 19.97 s, matched (verify.js); compiled/node 2.84
    roc: 40.17 s, matched (verify.js); compiled/roc 1.41

`shale x86/bank.shale size=small runs=5`, load 0.4 to 0.6:

    medians of 5: compiled 0.81 s, node 0.33 s, roc 0.48 s; compiled/node 2.43, compiled/roc 1.68

## History: measured under the old self-paced form

Everything below was measured when the race was self-paced: the program read its own clock between batches, made as many transfers as fit in `BUDGET_MS` (20 seconds, or 1 with `budget=1000`), and, unless `warmup=0`, made 2,000,000 untimed transfers before its clock started. Its numbers are transfers made in a time, not times for a count. The leads it found are about the cost of a transfer, so they still stand.

### The first numbers (2026-11-26, 1-second budget)

Medians of 5 runs of each, compiled and node in turn, on the 2-core box, node v22.23.2, master ce5318a, load average about 1.0 to 1.3 (another lane's work was running):

| | compiled | node | node's lead |
|---|---|---|---|
| no warm-up | 241,852 transfers | 7,836,412 | 32 times |
| after 2,000,000 untimed | 283,933 | 8,130,711 | 29 times |

So node's warm-up costs it about 4% at 1 second. The compiled program's own runs move a lot between runs: 200k to 286k in one set of 3. A guess, not measured: some of the move is the ledger's own state, since a decline is cheaper than a transfer and the share of declines changes as the balances spread. The compiled program's warm-up takes about 7 seconds of wall time outside its clock.

### Where the compiled program loses its time

`perf` can't sample on the box, so this was measured with copies of the race, each with one part taken out, each run once at a 1-second budget with no warm-up. Each is the same ledger, held to the same checksums:

| the copy | compiled transfers | about ns a transfer | node |
|---|---|---|---|
| the race as it is | 242k (median above) | 4,000 | 7.8M |
| the accounts reached through an array by number, not the dictionary | 1.47M | 655 | 12.2M |
| that, and `withdraw` and `deposit` written in line | 1.64M | 585 | 12.9M |
| that, and the generator's three `next()` calls in line | 2.58M | 372 | 12.0M |
| that, with no audits | 3.06M | 313 | |

The leads, ranked by what they cost the race now:

1. **The dictionary's lookup, about 83% of the time** (3,350 of 4,000 ns, two lookups a transfer). An object's entries are searched in order (`runtime_object_entry` in `x86/roc/Runtime.roc`), calling `runtime_text_equal` on each key. That routine compares the addresses, then the lengths, then the bytes one at a time. 400 of the 500 names are 8 bytes long and all start `acct-`, so most entries before the one found are compared to their sixth byte or past it, about 250 entries a lookup. Node keeps a dictionary-mode object as a hash table. A hash index on an object with many keys would take this lead away. Interning the keys alone would not, since the names are made with `+` as the program runs.
2. **Method calls, about 70 ns each, five a transfer** (`next()` three times, `withdraw` and `deposit`): together about 280 ns, 7% now and about 45% once the dictionary is fast. Each call looks the method up among the instance's keys (an instance holds its methods, as closures over `this`, beside its fields), then calls it through its value: the arguments pushed and counted, the closure's captured `this` copied in. Its result is a value of unknown kind, so `random.next() % COUNT` tests a tag.
3. **The instances' property reads and writes, most of the last 313 ns.** Each `this.balance` or `payer.declined` is the same in-order search over the instance's ten or so keys. A field's place is never known ahead of time, as node's hidden classes make it.
4. **The audits, about 60 ns a transfer (1.5%):** 500 dictionary lookups and one `Object.keys` array every 10,000 transfers. That is lead 1 again. `Object.keys` allocates about 4 KB an audit, so a 20-second race at node's pace would take about 65 MB of the heap, which is well within it.

Node does about 80 ns a transfer in every copy but the first (125 ns with the dictionary).
