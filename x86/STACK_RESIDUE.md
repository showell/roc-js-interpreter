# What the stack machine leaves in the hot loops (2026-11-26)

The code here was written by AI coding agents (Claude), with human supervision.

This study reads the compiled hot loop of each race at master 2f6f510. It asks how much of the bytecode stack machine's memory traffic is still there after the post-passes (Registers, Forwarding, Jumps, Moves). It answers one question: is the residue large enough to design a compiler front form now, built from the resolved AST, with temporaries as virtual registers and explicit loops? Nothing in the compiler was changed.

## Method

Each race was compiled at its small size with js-x86's dev build: fib at N = 100,000, bank at 2,000,000 transfers, fourteen at 20 rounds, big daddy at 30 rounds. Big daddy's executable printed node's ledgers for 30 rounds. Each executable was disassembled as TRIAGE.md and STEP_STUDY.md do it (`objdump -D -b binary -mi386:x86-64 -M intel --adjust-vma=0x400000 --start-address=0x400078`). `js-dump` gave each function's `frame_size`. A small Shale counter, kept outside the repository, classified each instruction of a loop body.

**The frame layout** (LoweringBasics' `slot_place` and `stack_place`; Lowering's `frame_bytes`): slot `s` is at `rbp - 8(s+1)`, and stack place `d` is at `rbp - 8(frame_size + d + 1)`. Below them is the save area of the registers Registers uses, `r9`, `r10`, `r11` and `rbx`. Inlining adds the inlined body's slots to the caller's `frame_size`, so fourteen's `f` has 10 + 4 slots. Registers renames up to four places to registers, and it may pick stack places as well as slots. Fib's `addInto` keeps `i` and `carry` in `r9` and `r10`, and its two busiest stack places in `r11` and `rbx`.

**What was counted** in each loop body:
- every instruction;
- each load and store at `[rbp-…]`, split into slots and stack places;
- **store-then-load**: a load of a place whose last access in the same straight run was a store, with no call between;
- **dead**: a store overwritten before any load, or never read in the body;
- **call spills**: the stores of `r9` to `rbx` to their homes right before a call, and the loads right after;
- **register-to-register moves**, with the ones to or from an xmm register counted apart.

Loops with branches were counted on their fall-through path: every conditional jump falls through, and every forward `jmp` is followed. That is the usual path of a slow way placed in line. Fourteen's dispatch was weighted by how often each path runs, from STEP_STUDY.md. Bank's `withdraw` falls through to its decline, which is about the size of its money-moved path. The counts are good to about 10%.

## The fib race: `addInto`'s first loop, a limb (0x40013d to 0x400250)

| | count |
|---|---|
| instructions | 64, no call |
| slot loads / stores | 5 / 1 (`a` twice, `b`, `aLength`, `s`; the one store is `s`, read back in the same run) |
| stack-place loads / stores | 4 / 6 |
| of those, store then load of the same place | 4 pairs |
| dead stack stores | 2 (one overwritten unread, one `BASE` literal never read) |
| call spills | 0 |
| register-to-register moves | 16 (6 to or from xmm) |

Every stack-place load is a value that a register held just before. The `s - carry * BASE` part goes through memory three times: carry to `[rbp-0x68]`, then `mulsd`, back to `[rbp-0x68]`, `subsd` from `[rbp-0x60]`, and back to `[rbp-0x60]` for the array store. The `const s` slot is stored and loaded once too, so it is a temporary in all but name. **Forwarding misses these pairs for two reasons.** It forgets everything at any instruction other than its four moves, so a `movabs`, a `ucomisd` or a `cmovae` between the store and the load clears it. And it turns only general-register loads into moves, never `movsd` loads into xmm. The moves include `mov rax,r9; mov rbx,rax; mov rcx,rbx` for one index.

None of the memory round trips is on the loop-carried chain. That chain is `carry` (`r10`): `addsd`, `ucomisd`, `cmovae`, about 10 to 11 cycles. So the round trips cost issue slots, not latency. At 4 a cycle, 64 instructions take about 16 cycles.

## The fourteen race: `f`'s loop, a line, with `step` inlined (0x4003e5 to 0x400602)

| | head (all lines) | dispatch (weighted mean) | a line |
|---|---|---|---|
| instructions | 39 | ~17.6 | ~57 |
| slot loads / stores | 4 / 3 | ~2.4 / 0 (the `op` slot reloaded at each `op ===` test) | ~6.4 / 3 |
| stack-place loads / stores | 2 / 3 | 0 / 0 | 2 / 3 |
| store then load | 2 stack pairs, 1 slot pair (`place`) | the ~2.4 `op` loads, each of a slot just stored | ~5.4 |
| dead stack stores | 1 (`% 4`'s divisor) | | 1 |
| call spills | 0 | 0 (the `%` slow way's 4 never run) | 0 |
| register-to-register moves | 7 (3 xmm) | ~4 | ~11 |

The worst residue here is a slot, not a stack place. **The `for ... of` walk's index is a double in `[rbp-0x38]`, loop-carried through memory**: a load, then `cvttsd2si`, `lea`, `cvtsi2sd`, and a store that the next line loads. That chain is about 5 cycles of store forwarding plus about 10 of conversions, about 16 cycles a line, and nothing else in the loop waits on memory that way. The inlined `op` and `place` are slots that hold temporaries. The true stack-place traffic is 5 accesses a line, 2 of them store-then-load.

## The bank race: a transfer (`transfers` 0x400b2c to 0x4017ee, and the methods it calls)

| | `transfers`' loop | `next` (×3) | `withdraw` | `deposit` | a transfer |
|---|---|---|---|---|---|
| instructions | 509, 9 calls | 109 | 103 | 121 | ~1,060 |
| slot loads / stores | 23 / 12 | 0 | 1 / 1 | 1 / 1 | ~37 |
| stack-place loads / stores | 22 / 30 | 0 | 0 | 0 | 52 |
| store then load | 10 stack pairs | 0 | 1 slot pair | 1 slot pair | ~12 pairs |
| call spills (stores / loads) | 27 / 17 | | | | 44 |
| saves and restores at entry and exit | | 8 | 8 | 8 | 40 |
| register-to-register moves | 73 (14 xmm) | 24 | 24 | 28 | ~197 |

All of each method's places are registers, so a method's frame traffic is its saves and its argument reads. In `transfers`, about half the stack-place traffic is the spills of `r10` and `r11` around its 9 calls. The other half is mostly the receiver and the method value, held across the in-line table read. The store-then-load pairs are about 24 of the transfer's ~1,060 instructions. The moves are larger: `this` goes `mov rax,rbx; mov r10,rax; mov r9,rax; mov rdi,r9; mov rcx,rdi` on its way to a tag test.

## Big daddy: the checksum's character loop (`add`, 0x4003b6 to 0x400570)

I read the stages' code and took the inner loop of `makeChecksum`'s `add`, `sum = (sum * 31 + ch.charCodeAt(0)) % 1000003`, as the hottest. It runs for every value every stage adds, a character at a time. I didn't locate mergeSort's merge loop or the sieve in the time box.

| | count |
|---|---|
| instructions | 89, 2 calls (an allocation, and `charCodeAt` through the runtime) |
| slot loads / stores | 5 / 2 |
| stack-place loads / stores | 11 / 10 |
| store then load | 5 stack pairs, 1 slot pair |
| dead stack stores | 2 |
| register-to-register moves | 6 |

**Registers renamed nothing in this function.** It saves no register, so its loop is the raw stack machine: 28 of its 89 instructions are frame accesses. I didn't check which part of Registers' rule refused it. The candidates are its packed rest parameter, its captured `sum` cell, and the `[rdx]` and `[rax]` stores that `charCodeAt`'s argument and the cell write make. `sum`'s chain goes through `[rbp-0x50]` five times on its way from the cell's load to the cell's store: `mulsd`, the tag test, `addsd`, the whole-number test, and `%`. That is about 5 store-to-load forwards, about 22 cycles. They are on the loop-carried chain, beside about 30 cycles of arithmetic and the cell's own round trip.

## What register-carried temporaries would save

An ideal scheme keeps every bytecode temporary, and every slot that is only a temporary (`s`, `op`, `place`), in a register. It removes the moves that only shuffle a value between registers. It keeps the boxing, the tag tests, the index checks and the calls as they are today. At about 4 instructions a cycle, and 4 to 5 cycles of latency for each store forward on a carried chain:

| race | today | ideal | saved | share of the loop's time |
|---|---|---|---|---|
| fib, a limb | 64 | ~42 | ~22 (10 stack accesses, 2 of `s`, ~10 moves) | ~25%: issue-bound at ~16 cycles, down to near the carry chain's ~11 |
| fourteen, a line | ~57 | ~45 | ~12 (5 stack accesses, ~4 of the temporary slots, ~3 moves) | ~5 to 10%: the line is ~48 cycles (96 ns a point), mostly the divide and the dispatch's branches |
| bank, a transfer | ~1,060 | ~990 | ~70 (~24 store-then-load accesses, ~50 shuffling moves) | ~5%; the call spills and saves (~84) are a calling-convention matter, not a temporaries one |
| big daddy, a character | 89 | ~65 | ~24 (21 stack accesses, the `[rbp-0x50]` chain) | ~15 to 25%: ~22 cycles of forwards on the carried chain, but each character also makes two calls |

Two cheaper changes would get much of this without a new front form:

- **Forwarding that forgets only what an instruction writes, and forwards into xmm loads too.** That takes most of fib's 4 pairs, fourteen's `op` and `place` reloads, and bank's 10.
- **Registers on big daddy's `add`,** once whatever its rule refused there is understood.

The two larger costs in these loops come from neither the temporaries nor the front form. One is fourteen's walk index, a double carried through a slot (STEP_STUDY.md, recommendation 4). The other is the call spills and saves in bank.

## Verdict

**The residue is small where the post-passes run.** Store-then-load traffic of stack places is 4 pairs in fib's 64 instructions, about 2 in fourteen's ~57, and about 12 in bank's ~1,060. What survives is mostly register shuffles. On this CPU, the core removes many plain `mov`s between general registers at rename, so they cost issue slots, not latency. The one large residue is a function Registers declined, big daddy's `add`. There the whole stack machine is still in memory, on the loop's carried chain.

On these numbers, an AST-based front form would buy about 25% of fib's inner loop, 5 to 10% of fourteen's and 5% of bank's directly. Most of that is also within reach of a smarter Forwarding and a wider Registers, at much less cost. **So the front form can wait.** Its payoff is mostly what it enables later: real register allocation across calls, hoisting loop invariants (fib reloads `a`, and fourteen untags `places` every line), and integer induction variables without inference. Those are reasons to design it once those optimizations are next in line, not now on the residue alone.
