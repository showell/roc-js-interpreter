# The bank race: where a transfer's instructions go (2026-11-26)

The code here was written by AI coding agents (Claude), with human supervision.

This is a read of the compiled bank race's machine code, master b1217aa, to rank the general compiler fixes that would close the gap to node (56.63 s against 19.97 s at 110,000,000 transfers, 2.8 times). `perf` can't sample on the box, so the method was to compile `bank_race.js` at the small size (`shale x86/bank.shale size=small`), disassemble the executable (`objdump -D -b binary -mi386:x86-64 -M intel --adjust-vma=0x400000 --start-address=0x400078`), find `transfers`, the methods and the runtime routines they call, and count instructions on the common path by hand. The counts are estimates to about 20%. Nothing in the compiler was changed.

The timing that run gave, at load 2.0 with another lane compiling, was 2.49 s compiled, 0.40 s node and 0.67 s Roc for 2,000,000 transfers. The README's quiet medians are 0.81, 0.33 and 0.48. That timing is noise. The counts below are what to rely on.

## The layout of the executable

The program's functions come first, in source order: `opening` at 0x4000cf, `audit` 0x4001d4, `checksum` 0x4002f0, `transfers` 0x40093f, `race` 0x40141d, then the class code: `Account`'s constructor 0x4025d5, `deposit` 0x402049, `withdraw` 0x402258, `Random`'s constructor 0x402a51 and `next` 0x4028a6. The runtime starts at about 0x403000. These are the runtime routines a transfer calls:

| address | routine | what it does on the common path |
|---|---|---|
| 0x4045ab | `runtime_get_property_hashed` | tag check, then the entry search (0x4043fc), then the value |
| 0x404673 | `runtime_set_property_hashed` | the same search, then a store |
| 0x4046a5 | `runtime_get_method_hashed` | the shadowed flag (`[r13+56]`), the instance's class table from its first entry, then a search there |
| 0x4043fc / 0x4043dd | the entry search | under 8 keys, the linear search at 0x403c87; from 8, the hash table (0x404466 checks that the table is current, 0x40455d is FNV-1a over the key's bytes) |
| 0x403c87 | linear search | for each entry, a call of `runtime_text_equal` (0x4036a9) |
| 0x404017 | `o[k]` of a `Value` | tag dispatch, then 0x4043dd with the hash computed as it runs |
| 0x403a73 | the check that a value is a function | 4 instructions |
| 0x40383d | `runtime_strict_equal` | about 10 instructions for two objects |
| 0x4039ec | `runtime_truthy` | about 12 |

**An `Account` has 7 keys, one under the hash index's threshold of 8.** The keys are the instance mark, `þAccount`, `name`, `balance`, `deposits`, `withdrawals` and `declined`, so every field read or write is the linear search. Each entry passed costs a call of `runtime_text_equal`, about 16 instructions when the lengths differ and more when they match: `þAccount` and `deposits` are 8 bytes like `declined`, and `deposits` shares its first two bytes with it. One access costs about 34 + 16i instructions for the key at place i. That is about 82 for `balance`, 104 for `deposits`, 114 for `withdrawals` and 154 for `declined`. A `Random` has 3 keys; `seed` costs about 66.

**Every call site spills and reloads r9, r10 and r11**, three stores and three loads, including calls of runtime routines.

## The hot path, per transfer, by line of bank_race.js

"Calls" counts the calls made from `transfers` and from the method bodies, not the nested ones inside the runtime (the entry search, and `runtime_text_equal` once per entry passed).

| line | source | what runs | calls | instructions |
|---|---|---|---|---|
| 116 | `while (step < to)` | `ucomisd` of two doubles (`step` is a double, since `from` is a parameter) | 0 | ~8 |
| 117 | `random.next()` | method lookup (~46), function check (4), call through the value (~20), the body of `next` (below, ~260) | 6 | ~330 |
| 117 | `% COUNT` | the tag test of the unknown result, the whole-number test, the magic multiply | 0 | ~25 |
| 117 | `names[...]` | inline index read | 0 | ~15 |
| 117 | `accounts[...]` | 0x404017 → hash table: check the table is current (~13), **FNV-1a of the 8-byte name as the program runs (~80)**, probe and pointer-equal key (~22), dispatch (~25) | 1 | ~160 |
| 118 | the payee, as line 117 | | 7 | ~545 |
| 119 | `random.next() % MAX_AMOUNT + 1` | as above, plus `addsd` | 6 | ~365 |
| 120 | `payer !== payee` | `runtime_strict_equal` on two `Value`s | 1 | ~20 |
| 120 | `payer.withdraw(amount)` | method lookup (~62), check, call through the value with one argument, the body (below, ~530), `runtime_truthy` of the result | 3 + 5 + 1 | ~650 |
| 120 | `payee.deposit(amount)` | method lookup (~46), check, call, the body (below, ~400) | 3 + 4 | ~490 |
| 121-122 | `step = step + 1`, `step % AUDIT_EVERY === 0` | double add, the whole-number test, the magic multiply, compare with 0 | 0 | ~30 |
| 123-124 | the audit, amortized | 500 dictionary lookups and `balance` reads, and one `Object.keys`, every 10,000 transfers | | ~15 |
| | **a transfer** | | **~37** | **~2,700** |

The method bodies:

- **`next()`**, about 260 instructions and 3 calls: get `seed` (~66), a tag test, `mulsd`, `%` by the modulus (the whole-number test and the magic multiply, ~25), set `seed` (~70), and **get `seed` again for the return (~66)**, a value that was just written. The prologue and epilogue add about 20.
- **`withdraw(amount)`**, about 530 instructions with the money moved: get `balance` (82), two tag tests and the compare, get `balance` again (82), `subsd`, set `balance` (86), get and set `withdrawals` (about 230). A decline is about 410, because `declined` is the last key and costs about 310 to get and set.
- **`deposit(amount)`**, about 400: get and set `balance` (about 170), get and set `deposits` (about 210), and the tag tests on `amount`, a `Value` parameter.

By kind of work, per transfer:

| work | instructions | share |
|---|---|---|
| field reads and writes on instances (14 to 15 of them, linear search) | ~1,450 | ~54% |
| method lookups, function checks, calls through a value, argument counts (5 calls) | ~400 | ~15% |
| the two dictionary lookups (FNV hashing as the program runs is half of it) | ~320 | ~12% |
| spills and reloads of r9 to r11 around the ~37 calls | ~220 | ~8% (overlaps the rows above) |
| tag tests, the whole-number tests of `%`, the loop, `!==`, `truthy`, the audit | ~300 | ~11% |

Against the measured 0.51 µs a transfer at full size (about 1,500 cycles at 3 GHz), 2,700 instructions is an IPC near 1.8, which is plausible for code that is mostly calls and short dependent loads.

## For contrast: the Roc port

This report does not disassemble `bank_race.roc`; its release executable was cached, but reading LLVM's inlined code was skipped to stay inside the time box. From its source (x86/bank/README.md, "Against Roc"), a Roc transfer does two `Dict.get`s keyed by `Str` and, for each account that changes, a `Dict.insert`: three or four hashed lookups, each hashing the name's bytes. It does no field search at all, since an `Account` is a record with fixed offsets, and its methods are direct, inlined calls. It runs at about 0.37 µs a transfer, against our 0.51, although it does about twice our hashing. That fits this triage: our dictionary lookups are not the main cost; our field access and method calls are.

## The ranked fixes

Every fix here is general: none reshapes `bank_race.js`, and each one helps any program with classes, methods or string-keyed dictionaries. The savings are per transfer, from the counts above. They overlap where noted.

### 1. Fixed slots for class instances, with a guard (about 1,250 instructions, ~45%): done

**Done (2026-11-26, x86/roc/FieldSlots.roc).** The guess is per key, not per receiver: FieldSlots reads each class's constructor code for the keys it sets, in order, following `super(...)` into the parent's, and gives each key the places (at most three) where an instance holds it. A `GetProperty` (any key but `length`) or `SetProperty` on an `Object` or a `Value` whose key has places tests in line: the receiver's tag (for a `Value`), its entry count above the place, and the entry's key against the literal's address. The fallback is exactly the old call. The receiver's class is never inferred, since the exact test makes any guess safe.

Counted the same way, by static objdump of the small race (master a6985e1 against the lane):

| | before | after |
|---|---|---|
| one field read or write on the common path | 66 to 154 instructions, 1 call plus 1 to 6 nested `runtime_text_equal` calls | 17 instructions (the tag test, the unbox, the count, the key compare, the load or store and the jump past the slow way), no call |
| field accesses a transfer makes (money moved: 9 in the three `next()`s, 5 in `withdraw`, 4 in `deposit`) | ~1,470 instructions | ~310 |
| calls a transfer makes from `transfers` and the method bodies | ~37 | ~19 |
| a transfer | ~2,700 instructions | ~1,550 |
| `deposit`, `withdraw`, `next` (static instructions, every way included) | 120, 201, 99 | 190, 323, 153 (each slow way stays beside its fast one) |

`shale x86/bank.shale size=small runs=3` (2,000,000 transfers, load about 1.5): compiled 0.43 s, node 0.30 s, Roc 0.47 s, medians; compiled/node 1.44, compiled/roc 0.90. Before, one run each beside it: 0.89 s compiled. So the compiled race now beats the Roc port at the small size, and is about 1.4 times node's.

The plan as first written:

A class's constructor that writes `this.k = ...` in straight-line code with no branches before the writes gives every instance the same entry order: the mark, the class keys, then the fields in order. So `balance` is always entry 3 of an `Account`. For a `this.k` in that class's methods, and for `o.k` in general, the compiler can guess the slot and emit an inline guard instead of the runtime call:

    untag o; entries = [o + 16]; if [entries + 16*slot] == &"k" (the literal's address) then load or store [entries + 16*slot + 8] else call the runtime as today

Keys a program writes with `o.k` are stored as the literal's address, so the guard is one pointer compare. Anything that breaks the layout (a computed key, an index key moving the entries, another class) fails the guard and takes today's path, so semantics are unchanged. With no class to guess from, the slot could be learned per site, a one-entry inline cache in a writable word, but the class guess needs no writable data.

- **Saving:** the 14 to 15 field accesses drop from about 100 instructions and two to six calls each to about 8 instructions and no call, about 1,250 instructions and most of the spills around them. This one fix should take the compiled race below node's 2x.
- **Modules:** Lowering.roc (the `GetProperty` and `SetProperty` arms, and the compound `this.k += v`), a new analysis next to KnownFunctions.roc (the constructor's field order, from the bytecode ClassDesugaring makes), RuntimeBuilders.roc (where the instance's keys are laid out, the source of truth for the slot numbers).
- **Risk:** low to medium. The guard makes a wrong guess slow, never wrong. The analysis must count the class keys a subclass adds (`þ` and each name in the chain) and the fields a parent's constructor writes first.
- **Conflict with the Integer lane:** a textual one in Lowering.roc only (the property arms are far from the arithmetic and loop code, near lines 2124 and 2279). There is no semantic overlap, since a field is always a boxed value.

### 2. Direct calls of class methods, guarded (about 350 instructions, ~13%, and better kinds)

`random.next()` and `payer.withdraw(amount)` look the method up in the class table, check that it is a function, and call through the closure with an argument count and the missing-argument fill. When the method name belongs to exactly one class's table, the call site can test the receiver's class key (entry 1's key is `&"þC"`) and the shadowed flag (`[r13+56]`, which already exists for `runtime_get_method_hashed`), then call C's method directly with `this` in a register. Otherwise it keeps today's path.

- **Saving:** about 70 instructions and two calls for each of the five method calls: about 350. More follows from it: a method only called directly could keep its parameter kinds, as fib does (`amount` a `Number`, so `deposit` and `withdraw` lose their tag tests, about 40), and a known result kind (`withdraw` gives a boolean, so `runtime_truthy` goes, about 20).
- **Modules:** CallLowering.roc (`value_call_items` and a direct variant), Lowering.roc (the `CallMethod` arm near line 2888), KnownFunctions.roc (which names belong to one class, and whether a method escapes as a value, which keeps it on `Value` parameters).
- **Risk:** medium. The `escaping` analysis must still see a method read as a value (`const f = a.withdraw`), and a subclass that overrides a method must not take the parent's direct call. Testing the exact class key handles that.
- **Conflict with the Integer lane:** real. Integer parameters change how call arguments are converted and how parameter kinds settle across the program, and this fix adds a new kind of direct call whose parameters settle the same way. Land it after Integer parameters, or agree first on how the direct method entry takes its argument kinds.

### 3. Runtime routines that keep r9 to r11 (about 220 instructions, ~8%; about 100 after fix 1)

Every call site stores r9, r10 and r11 and loads them back, including the ~30 calls of runtime routines per transfer. The property routines use r9 to r11 inside the entry search (0x403c87 and the table probe), so the caller has to save them. If the runtime's leaf routines (the property get and set, the method lookup, `strict_equal`, `truthy`, the function check) saved what they use, or used other scratch registers, the lowering could skip the spills around calls of those routines.

- **Saving:** 6 instructions times about 37 calls, about 220 today. After fix 1 removes most field calls, about 100 is left.
- **Modules:** Runtime.roc and ObjectTable.roc (the routines' register use), Registers.roc and Moves.roc (which calls need the spill), Lowering.roc (`Emit.call` sites that save the registers).
- **Risk:** medium. A routine that clobbers a register its callers now trust gives wrong values that no tag catches. Each routine needs an expect or a list of the registers it keeps.
- **Conflict with the Integer lane:** moderate. Registers.roc renames frame places, `Integer` ones included, to r9 to r11 and rbx, so both lanes touch which registers are live across a call. Land it after the Integer work settles.

### 4. A string's hash kept with the string (about 140 instructions, ~5%)

`accounts[names[i]]` hashes the 8-byte name with FNV-1a every time (the loop at 0x40455d, about 8 instructions a byte), twice a transfer and 500 times an audit. The compile-time hashes help only literal keys. A string is immutable, so its hash can be stored once: a word before the length (offset -8), so that every routine that reads the length at 0 and the bytes at 8 stays as it is. A literal's hash is written by the compiler, and a heap string's when it is made (`+`, templates, `String(v)`, `slice`, `split`), or lazily, with 0 for "not yet". The lookup then reads one word.

- **Saving:** about 70 instructions a lookup, about 140 a transfer, plus the audits'.
- **Modules:** Runtime.roc and RuntimeTexts.roc (string allocation and the literals' layout), ObjectTable.roc (read the hash instead of hashing), Collections.roc (Map and Set could use it too), Assembly.roc and Elf.roc (only if the read-only layout of literals changes).
- **Risk:** medium. Every place that makes a string must write the word or leave it 0; a lazy hash is the safer form, since a forgotten site is only slow. The literals must be laid out in a way that keeps the label at the length.
- **Conflict with the Integer lane:** none (runtime only).

### 5. Forward a property just written to the read after it (about 200 instructions today, about 30 after fix 1)

`next()` writes `this.seed` and then reads it back for `return this.seed`. `withdraw` reads `this.balance` twice with nothing between that could change it (the compare, then `-=`). Where no call or other write lies between, a read of `o.k` after a write or read of the same `o.k` can take the value already in hand. Forwarding.roc already does this kind of thing for the stack.

- **Saving:** one `seed` read per `next()` (3 × ~66) and one `balance` read per `withdraw` (~82), about 280 today. After fix 1 makes each access about 8 instructions, it is worth about 30, so it ranks last.
- **Modules:** Forwarding.roc and Lowering.roc.
- **Risk:** low, if "nothing between" is strict: no call, no write of any property, no index write.
- **Conflict with the Integer lane:** a textual one in Lowering.roc only.

### Not ranked

- `step` is a double because `from` and `to` are parameters, so its `+ 1` and `% AUDIT_EVERY` take the whole-number test (about 25 instructions). The Integer-parameters lane's work fixes this; it needs nothing here.
- `payer !== payee` of two `Value`s (about 20 instructions) could be inlined: if the bits are equal and the value isn't a number, the answer is true; if either side is neither a number nor a string, compare the bits. This is small.
- Raising the hash index's threshold or lowering it to 7 would only swap one search for another. Fix 1 removes the search on the hot path instead.

## What surprised

- The `Account` instance is exactly one key short of the hash index (7 against 8), so the hash index never helps the field accesses, which are half the work. The dictionary, which the hash index was built for, is now only about 12%.
- The Roc port does twice our hashing and still wins, because its field access is free.
- `next()` reads `this.seed` back right after writing it: three wasted lookups per transfer.
