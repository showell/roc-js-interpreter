# The bank race

The code here was written by AI coding agents (Claude), with human supervision.

`bank_race.js` asks how many transfers a bank ledger makes in 20 seconds. It is a second race beside the fib race (`x86/race/`), as plain as fib but reaching more of the language: a class with methods, a plain object used as a dictionary, string keys, `Object.keys`, `for ... of`, `%` and whole-number arithmetic. It uses no recursion.

- **The accounts:** 500 of them, each an `Account` (its name, a balance in whole cents, and counts of deposits, withdrawals and declines, with `deposit(amount)` and `withdraw(amount)`), kept in a plain object keyed by name (`"acct-217"`). The names are made once, at the start, and kept in an array too, so the transfers make no new strings or objects. The compiled program has no garbage collector, so a transfer that allocated would fill its 1 GiB heap.
- **A transfer** draws three numbers from a seeded Park-Miller generator, a `Random` (seed times 48271, mod 2^31 - 1; every product is below 2^47, so exact in a double): the payer, the payee and the amount, 1 to 50,000 cents. It looks both accounts up by name, and when the payer has the funds, `withdraw` and `deposit` move the money; otherwise `withdraw` counts a decline.
- **The audit:** every 10,000 transfers, an audit walks `Object.keys` of the dictionary and sums the balances. Money only moves, so the total must stay the opening total.

It is timed as the fib race is: the program reads its own clock (`Date.now()`) between batches, sizes each batch from what a transfer has cost so far, and stops when the time left is too small to plan one. **Before the clock starts, `WARMUP` transfers run untimed** (2,000,000, about 250 ms of node's time), so node's JIT has warmed up before it is timed: Steve's call, to race node at 1 s first and give it slack for its warm-up penalty. `WARMUP = 0` runs the race with no warm-up.

**How it is checked:**

- The first 100,000 transfers are always run first, warm-up or not. The checksum of every account after them (balances and counts folded below a prime) is held to a constant computed offline with node. A mismatch is a `FAIL` whatever the time.
- So is any audit whose total is not the opening total.
- So is a last clock reading past the budget.
- After the `PASS` or `FAIL` line, the program prints the transfers it reached and the checksum of every account then.

`verify.js N` is a second implementation of the ledger (plain arrays indexed by account number, no class and no dictionary). It runs N transfers in node and prints the checksum line, the audits line and the last line that the race must print, exactly.

From the repository's root:

    shale x86/bank.shale budget=1000                   # a 1-second budget, after the warm-up
    shale x86/bank.shale budget=1000 warmup=0          # the same with no warm-up
    shale x86/bank.shale budget=1000 warmup=0 runs=5   # five runs of each in turn, and the medians

`budget=` (milliseconds, 20000 unset) and `warmup=` (transfers; the file's own value unset, else 0 or at least 100,000) write a copy of `bank_race.js` with those lines changed, under the build mount, and both contestants run that copy. The script builds js-x86 on the dev backend, writes the executable, runs it and then node, niced and never at the same time, and checks each answer against verify.js. Each contestant's line gives:

- the transfers made while its clock ran, and in all;
- the elapsed time the program measured;
- PASS or FAIL;
- whether the answer is verify.js's;
- the time outside its clock: the start, the warm-up, the final checksum and the exit.

`check.shale` doesn't run it, since its numbers are timings.

**One reshape for js-x86.** The generator keeps its seed in itself, a `Random` object, rather than in a function `nextSeed(seed)` whose result the caller passes back to it. js-x86 refuses any program in which a function's result reaches its own parameter: `function t(s) { return s + 1; }` called as `t(t(1))` stops with "the kinds of the functions' parameters and results never settle". A guess at why, not checked: each pass computes the parameters' kinds from the last pass's results, and the results from the last pass's parameters, so the two swap between `Number` and `Value` every pass and never meet. The fix is in `x86/roc/Lowering.roc` (`items_with_numbers`), widening each pass's kinds with the last pass's.

## The first numbers (2026-11-26, 1-second budget)

Medians of 5 runs of each, compiled and node in turn, on the 2-core box, node v22.23.2, master ce5318a, load average about 1.0 to 1.3 (another lane's work was running):

| | compiled | node | node's lead |
|---|---|---|---|
| no warm-up | 241,852 transfers | 7,836,412 | 32 times |
| after 2,000,000 untimed | 283,933 | 8,130,711 | 29 times |

So node's warm-up costs it about 4% at 1 second. The compiled program's own runs move a lot between runs: 200k to 286k in one set of 3. A guess, not measured: some of the move is the ledger's own state, since a decline is cheaper than a transfer and the share of declines changes as the balances spread. The compiled program's warm-up takes about 7 seconds of wall time outside its clock.

## Where the compiled program loses its time

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
