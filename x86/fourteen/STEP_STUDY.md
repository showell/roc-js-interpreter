# The fourteen race: where `step` and its call go, against LLVM and V8 (2026-11-26)

The code here was written by AI coding agents (Claude), with human supervision.

This is a read of the compiled fourteen race's machine code at master 62cb716, set beside the machine code of the Roc port's release build (LLVM) and of node's optimized code (V8's TurboFan), to find general rules for our inliner and lowering that would close the gap. Nothing in the compiler was changed. Tonight's quiet-box verdict at 21,000 rounds (344 million points) was js-x86 52.42 s, node 21.72 s, Roc 17.82 s: **152 ns a point compiled, 63 ns node, 52 ns Roc.** One nanosecond a point is 0.34 s at full size.

Method, as in x86/bank/TRIAGE.md: the race compiled at 20 and 300 rounds (`shale x86/fourteen.shale rounds=300`), disassembled with `objdump -D -b binary -mi386:x86-64 -M intel --adjust-vma=0x400000 --start-address=0x400078`; the Roc binary is the cached `build:cache/roc-apps-builds/fourteen-roc/8f8a86a91074af1d/fourteen-roc` (`objdump -d`); node's is `node --print-opt-code` and `--trace-turbo-inlining` on the 20-round copy. Paths were counted by hand, and how often each is taken was computed exactly by running the Nibble machine over all 16,384 points in a script. Two claims were then timed by byte-patching a copy of the compiled executable (below), which changes no compiler code. The CPU is family 6 model 85 (Skylake-SP or Cascade Lake), where 64-bit division is slow, and that turned out to be the main finding.

## 1. Where our time goes

The layout: `step` at 0x4000cf, `f` at 0x400315, `main` at 0x4004ae. `run` is a double in `r11`, `op` an `Integer` in `rbx`.

**`step`, per call, by path** (callee only, prologue to `ret`):

| path | instructions | share of the 6 lines a point |
|---|---|---|
| the head every call runs: `push rbp`, frame, 4 saves of r9 to r11 and rbx, the stack check, 2 argument loads, `run > 3` as a `ucomisd` of a double (6) | 17 | |
| run already done (`run > 3`): + result, 4 restores, `ret` | 25 | 1.84 |
| nada (op 0): 4 failed `op ===` tests, 6 each | 49 | 1.04 |
| zero at AX 0 (accepts): `op === 1`, `run === 0` as `ucomisd` with `jne`/`jp`, the result | 39 | 0.34 |
| zero at AX > 0 (falls through every test) | 56 | 0.70 |
| decr at AX 0 (rejects) | 45 | 0.34 |
| decr at AX > 0: `subsd` of 1.0 | 61 | 0.70 |
| mod2: `run % 2` of a double, the whole-number test (`cvttsd2si`, `cvtsi2sd`, `ucomisd`), the magic multiply, back to a double, the sign or-ed in | 75 | 1.04 |

Weighted by how often each path runs: **about 285 instructions of `step` a point, 47.6 a call.** Of those, 18 a call are the frame, the saves, the stack check, the argument loads and the restores: 108 a point.

Every `op ===` test is 6 instructions (`mov r9, rbx`, `mov r10, imm`, `mov rax, r9`, `mov rcx, r10`, `cmp`, `jne`), where one `cmp rbx, imm` and a jump would do. Every `run` test is 6 or 7, because `run` is a double.

**`f`'s loop body, 46 instructions a line** (0x40039f to 0x40044c), 276 a point:

| part | instructions | what |
|---|---|---|
| the `for ... of` step | ~17 | `places` loaded and untagged (`shl`, `shr`) every line, the index a double in the frame (`movsd`, `cvttsd2si`, `lea`, `cvtsi2sd`, `movsd` back), the length check, the item a double made an `Integer` (`cvttsd2si`) |
| `Math.floor(program / place) % 4` | ~17 | the operands copied through two frame places, `cqo`, **`idiv rcx`** (64-bit), a dead store of the 4, `and rax, 3` |
| the call | ~12 | two pushes, **4 stores of r9 to r11 and rbx** (which `step` saves and restores itself), `call`, 1 reload, `add rsp`, the result moved |

**Around it, a point:** `main`'s loop and its call of `f` about 27; `f`'s own entry about 29, the walk's last test 8, and its return, which makes a boolean of `run === ACCEPTED`, 22.

**A point in all: about 650 instructions and 6 `idiv r64`.** The call of `step` alone (the call site's 12 and the callee's 18) is about 174 of them, 27%.

**The divisions are about 40% of the time.** A microbenchmark of six divisions of a number below 4096 by the six places, in a loop with nothing else (build:stepstudy/divbench.c), on this box:

| form | ns a point (6 divisions) |
|---|---|
| `cqo; idiv r64` (ours) | 64 to 76 |
| `xor edx, edx; div r64` (LLVM's) | 61 to 67 |
| `xor edx, edx; div r32` | 25 |
| `divsd; roundsd; cvttsd2si` (V8's) | 25 |
| the loop alone | 1 to 8 |

**Timed in the real program:** a copy of the compiled 300-round executable with the one `cqo; mov rcx, [rbp-0x80]; idiv rcx` at 0x400406 patched to `xor edx, edx; mov ecx, [rbp-0x80]; div ecx` (same output), 7 runs of each alternated, CPU time: **median 775 ms before, 572 ms after (26% less, 158 to 116 ns a point).** At full size that is about 52.4 s down to about 38.7 s.

A second patch on top, the four redundant stores before the call of `step` and the reload after it made `nop`s: median 562 ms against 541 ms, about 4% and within the noise, so the spills are a small part of the call's cost; the frame, the pushes and the `ret` are the rest.

## 2. What Roc's LLVM build does

The hot loop is in `roc__p49e682ec...` (`main!`), 0x1440 to 0x1680, about 150 static instructions.

- **`step` is inlined, `is_accepted` is inlined into `main!`'s loop, and the fold over the six places is unrolled six times.** The list `[1024, 256, 64, 16, 4, 1]` is a literal inside `is_accepted`, so LLVM knows its length is 6; it doesn't fold its items, which it loads from the constant list (`[r8+0x8]` to `[r8+0x30]`) every point, each with a test for 0 (Roc's "divided by 0" crash).
- **The division is not strength-reduced.** Each line is a `div r64` by the loaded place. `bits // 4096` and `bits % 4096` are `shr` and `and`, since those divisors are literal.
- **Everything is in registers:** AX in `rsi`, the run's tag in `r14b` (0 Accepted, 1 Going, 2 Rejected), the program in `edi`, the count in `r13`. The loop touches no stack.
- **No jump table and no `cmov` for the dispatch.** It is a chain of compares and branches on the op (`cmp eax, 3`, `cmp eax, 2`, and `xor rdx, 1; or rdx, rsi` testing op 1 and AX 0 at once). decr is branchless: `test rsi, rsi; setne r15b; cmp rsi, 1; adc rsi, -1` (AX - 1, and whether it stays going). mod2 is `and esi, 1`.
- **Jump threading on the run's state.** After a line that accepts or rejects, the code jumps into the later lines' "done" paths, which test the tag and skip the op's compares. Lines 2 to 5 still do their `div` before the tag test; line 6 tests first and skips it.
- **Per point: about 80 to 90 instructions and 5 or 6 `div r64`.** At about 10 ns a `div r64` on this CPU, the divisions are the whole 52 ns: **Roc is bound by the divider, not by instructions.**

## 3. What node's V8 does

From `node --trace-turbo-inlining` (node v22.23.2): TurboFan inlines `step` (75 bytes of bytecode) into `f`, then `f` (190 bytes) into `main`, and `step` again into that, so `main`'s optimized code holds the whole point. The loop over `places` is not unrolled (`places` is a parameter): each line is about 40 to 45 instructions on its path, with the elements kind check (`PACKED_SMI_ELEMENTS`), a Smi or heap-number test of the item, **`vdivsd`, `vroundsd` (floor) and `vcvttsd2si`** with a check that the result is whole, `% 4` as `and` with the sign handled, `run` kept as a double in `xmm0` and made an int32 at each line with a check, the op tests as `cmpl`, and the interrupt check. About 250 instructions a point, but its division is the fast one: so V8 does three times LLVM's instructions and is only 20% slower.

V8's inlining limits, from `node --v8-options` (the flags live in V8's `src/flags/flag-definitions.h`; the heuristic that applies them is `src/compiler/js-inlining-heuristic.cc`):

| flag | default | meaning |
|---|---|---|
| `--max-inlined-bytecode-size` | 460 | the largest callee, in bytecode bytes, TurboFan inlines |
| `--max-inlined-bytecode-size-cumulative` | 920 | the most bytecode inlined into one optimized function in all |
| `--max-inlined-bytecode-size-absolute` | 4600 | the largest the function and its inlinees may be |
| `--max-inlined-bytecode-size-small` | 27 | a callee this small is inlined whatever the budget left |
| `--reserve-inline-budget-scale-factor` | 1.2 | scales the callee's size when the budget is reserved |
| `--min-inlining-frequency` | 0.15 | a call site must run at least this often per run of the caller |
| `--max-maglev-inlined-bytecode-size` | 100 | Maglev's (the middle tier's) per-callee limit; its cumulative is 920 and its small 27 |

The limits are absolute sizes per optimized function, not a percentage of the caller. In our units: `step` is 75 V8 bytes and 44 of our instructions, so V8's 460 is roughly 250 of ours and its 27 roughly 16. (`f` is 190 V8 bytes but 40 of our instructions, since V8's `for ... of` is iterator bytecode, so the ratio is rough.)

## 4. Recommendations

Savings are per point and at full size, estimated from the counts above unless marked measured. They overlap a little; in order, they would take the race from about 152 ns a point to about 70 (about 24 s, near node's 21.7 s).

### 1. 32-bit division when the ranges allow it (measured: about 41 ns a point, 14 s) (DONE)

**Done (2026-11-26):** the unsigned half, `xor rdx, rdx; div ecx` for a dividend in [0, 2^32) and a divisor in [1, 2^32) (`OperatorLowering.fits_div32`, `X86.Div32`; x86/README.md, "An integer kind"). The fourteen race compiled at 300 rounds, 7 runs of each alternated, CPU time, niced, load 0.35 to 0.45: **median 823 ms on master ea504a7, 551 ms with it (33% less; 167 to 112 ns a point).** At full size that is about 52.4 s down to about 35 s. The signed `cdq; idiv r32` for ranges within ±2^31 is not done: fourteen doesn't need it, and the brief kept a possibly negative dividend on today's path. The operands stay 64-bit loads, which are already right for values below 2^32, so no 32-bit `mov` was added; the zero is the 64-bit `xor rdx, rdx`, one byte longer than `xor edx, edx`.

When an `Integer` division or remainder has a dividend in [0, 2^32) and a divisor in [1, 2^32), emit `xor edx, edx; div r32` instead of `cqo; idiv r64`; when both lie within ±2^31 and the divisor's range holds no 0 or -1, `cdq; idiv r32`. The bounds the integer kind already proves (`program` is 0 to 4095, `place` an item of an array of 1 to 1024) are all it needs. Unsigned `div r32` gives the floor and the remainder of non-negative operands, so `Math.floor(a / b)` and `a % b` need no sign fix-up. This beats LLVM's `div r64`, which Roc's `U64` forces.

- **Modules:** X86.roc (a `Div32` and an `Idiv32` encoding, `f7 /6` and `f7 /7` without REX.W, and `Cdq`; expects for each), OperatorLowering.roc (`integer_floor_items` and `integer_remainder_items`, near the two `Cqo`/`Idiv(Rcx)` pairs), Registers.roc (its list of the registers `Div` uses). Runtime.roc's `runtime_remainder` keeps its `idiv r64`.
- **Risk:** low. The rule reads bounds already proved; expects at 2^32 - 1, 2^31 and a negative dividend hold its edges, and a test with divisions at those ranges against node.
- **Not bloat:** the same instruction count, one byte shorter.

### 2. Inline `step`: thresholds that admit a small leaf into a small caller (estimated: about 25 ns a point, 8 to 10 s) (DONE)

**Done (2026-11-26):** the proposal below as written, as named constants in Inlining.roc (`most_leaf_instructions` 64, `most_growth_percent` 25, `least_growth_instructions` 64, `most_growth_instructions` 256, `always_leaf_instructions` 16; a small leaf still counts toward the 256). `step` is inlined into `f` (1 site, 45 instructions; 392 bytes more of executable). The fourteen race compiled at 300 rounds, 7 runs of each alternated, CPU time, niced, load 0.80 to 0.82: **median 541 ms on master 16759b7, 472 ms with it (13% less; 110 to 96 ns a point).** Less than estimated: `run` stays a double in the inlined body, which is recommendation 3. The bank and fib races compile to the same bytes. Across x86/tests/ the inlined total went from 13 sites and 73 instructions to 47 and 683, most of it inline-small.js's 21 sites at the cap.

Today `step` (44 instructions) is over the leaf limit of 40, and `f` (40) may grow by only 10. Inlined, the 174 instructions a point of the call go: the pushes, the frame, the saves, the stack check, the argument loads and the `ret`.

**The proposal:** a leaf of at most **64** instructions; each caller grows by at most **the larger of 25% of its own instructions and 64 instructions** in all, and never past **256** inlined instructions; a leaf of at most **16** instructions (V8's small-function rule) is inlined at a loop's call site whatever the caller's budget. All of today's other rules stay: leaves only, so there is no cascade, calls inside loops only, no `try`. The absolute floor is what V8's limits are (per function, not a ratio), scaled down by about four, and it is what lets a small caller take one leaf: a percentage alone shuts out exactly the case of a small function calling a slightly smaller one in a loop. For fourteen, `f` grows from 40 to about 84 instructions in the bytecode and its loop from 46 to about 118 static machine instructions, about 400 bytes of a 24 KB executable, with `step`'s own 581 bytes kept as they are.

- **Modules:** Inlining.roc (`most_leaf_instructions`, `most_growth_percent`, a floor and a cap beside them), x86/programs.shale (its `INLINED` total, which will rise), x86/tests/inline-too-big.js (its near misses move to the new limits).
- **Risk:** low to medium. The rules are unchanged in kind. README's "Inlining small leaves" records an earlier trial at 48 instructions and 150% as "758 ms against 645 ms" at a load of 3.5 without saying which side was inlined; it must be measured again on a quiet box, alternated, after fix 1, since the 64-bit divisions hid much of the rest.

### 3. An inlined body's result meets in a slot, so an `Integer` result stays one (estimated: about 10 ns a point, 3 s)

Inlined, `run` stays a double, because each `return` becomes a jump with the result on the stack, and the stack never carries an `Integer` across a meeting. If Inlining wrote each `return v` as a set of a result slot of its own and a jump, the meeting would be of a slot, where two `Integer`s meet as the hull of their ranges. With one more narrowing rule, `run` would be an `Integer` throughout: **on the way where `x === k` fails, a range that has `k` as an end drops it** (`run` in 0 to 3 and not 0 is 1 to 3), so `run - 1` stays at least 0 and `run % 2` keeps a dividend that can't be negative. Then every `run` test is a `cmp` (from 6 or 7 instructions to 2), mod2 is `and` (from 26 to about 3), decr a `sub`, and `f`'s `run === ACCEPTED` a `cmp`: about 60 to 70 instructions a point.

- **Modules:** Inlining.roc (the return's rewrite and the result slot), OperatorLowering.roc (`integer_jump_items`, the narrowing on the failing way), Lowering.roc (the slot's kind at the meeting, if anything there special-cases a call's result).
- **Risk:** medium. The narrowing is a new rule in the kinds' walk; it needs expects at both ends of a range and a test where `k` is inside the range, which must not narrow.

### 4. The frame traffic in a `for ... of` loop (estimated: about 10 ns a point, 3 s)

About 15 of `f`'s 46 instructions a line are moves the loop doesn't need: the walk's index kept as a double in the frame and converted twice a line; `places` loaded and untagged every line, though it doesn't change in the loop; the dead store of `% 4`'s divisor; the division's operands copied through two frame places. A walk over a known array whose index is an `Integer` in a register, with the array's untagged address taken once before the loop when the loop writes no slot holding it, would take out most of it. LLVM does all of this, and it is what makes its loop 80 to 90 instructions.

- **Modules:** IndexLowering.roc (the walk's index as an `Integer`), Registers.roc and Moves.roc (keeping the untagged address and the index in registers), Forwarding.roc (the dead store).
- **Risk:** medium; each is its own small rule. A loop that writes the array's slot, or pushes to the array, must still see a fresh length (node's walk does).

### 5. Calls that trust the callee to keep the spare registers (measured: about 4%, within the noise)

`step` saves and restores r9 to r11 and rbx itself, so its caller's four stores and one reload around the call are redundant. Patched out, after fix 1: 562 ms against 541 ms. Fix 2 makes it moot for `step`, but it would help every direct call that isn't inlined (the bank race's methods). It is the bank triage's fix 3 from the other side.

- **Modules:** CallLowering.roc and Registers.roc. **Risk:** medium (a callee that doesn't keep a register its caller now trusts gives wrong values that nothing catches).

### Not recommended

- **Folding the places into shifts.** Every place is a power of two, but that is this program's data, not a rule; LLVM didn't do it either.
- **Sinking the division into the "going" path,** so a done run skips it. It is legal (the division is pure), but LLVM did it for one line in six; with fix 1 a division costs about 4 ns, and a done line is 1.84 of 6.
- **Unrolling `for ... of` over an array of known length.** LLVM unrolls because the list is a literal inside the function; in the JS it is a parameter, so its length isn't known.
- **Inlining `f` into `main`, as V8 does.** It saves about 80 instructions a point (`f`'s entry and return and `main`'s call), but after fix 2 `f` has a loop and is no leaf, and inlining non-leaves needs a cascade rule. A later step, if the others land.

## What surprised

- **Roc's LLVM build is bound by the divider:** about 85 instructions a point, but 5 or 6 `div r64` at about 10 ns each are its whole time. Its lead is the CPU's 64-bit divider, not its inlining.
- **V8 is fast for the opposite reason:** three times LLVM's instructions, but its division is `vdivsd` (Math.floor of a double division, JavaScript's own meaning), as fast as a 32-bit `div`.
- **Our integer division (the integer kind's step 3) is an `idiv r64`, which on this CPU costs about two and a half times a `divsd`.** It took out the conversions and `Math.floor`'s call, but its width gave much of that back. The 32-bit form is one change in two places of OperatorLowering and takes a quarter of the race's time off.

## Recommendation 3, tried (2026-11-26): no gain, parked

Branch `x86-intrun` (81c9d88, ee4e7f7, ee9c56a; not merged) implements both parts: an inlined body's returns meet in one result slot, and a failing `===` drops the tested end of a range. Both are general and held by tests, but fourteen's `run` stays a double and the race doesn't move (300 rounds, 445 ms against 453 ms, within the noise). The ranges can't carry how one test constrains another: `op === 2 && run === 0` drops 0 from `run` only where `op === 2` held, that way joins the way where it failed before `if (op === 2) return run - 1`, so `run - 1` may be -1, and the loop's head widens `run` down to -2^53. Getting the gain needs either facts that relate two slots (`op === 2` implies `run !== 0`) or threading the two `op === 2` tests into one. The branch is kept for that design; it wasn't merged because the result slot adds code (inlined 683 to 854 instructions) with no measured gain.
