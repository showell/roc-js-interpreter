# Tiny kernels: js-x86's loops against Roc's

The code here was written by AI coding agents (Claude), with human supervision.

Each kernel here is a small loop written twice: a JS file that js-x86 compiles, and a Roc twin beside it that Roc's release build (`--opt=speed`, LLVM) compiles. The Roc uses `var` and `while`, so the two loops have the same shape. Each kernel's sizes keep its hot loop dominant, and each prints one checksum. `shale x86/kernels.shale` holds js-x86's executable, node and the Roc twin to the same line (8 of 8 agree). The point is to read the two compilers' hot loops instruction by instruction, so the next compiler work can be aimed at what LLVM does and we don't.

**When and what:** 2026-11-28. Our side is js-x86 at master 70f8542, the lane's base, before the lazy sweep merged. Roc's side is the pinned Roc, 0.1.0_RC1. Neither compiler was changed for this.

## How the numbers were taken

```
shale x86/kernels.shale                      # the checksums, all three
shale x86/kernels.shale time=1               # and one timing each, niced
shale x86/cost.shale counted=1 loop=1 --args-stdin <<'ARGS'
races=x86/kernels/sum_array.js,x86/kernels/dot.js
ARGS
shale x86/cost.shale native=<Roc's executable>                  # its jumps back
shale x86/cost.shale native=<Roc's executable> range=14c0-14e1  # one loop, read by llvm-mca
```

- **Our side:** `cost.shale counted=1 loop=1` runs the counted executable (x86/COST.md, "The counter") and finds its hottest loop: the jump back whose target ran the most times, the innermost on a tie. The **hot path** is the loop's instructions whose block ran at least half as often as the loop's head, which leaves out the slow paths laid out inside the loop. `hot` is the hot path's static count. `per trip` is the exact dynamic count of the loop's own code divided by the trips, and `all/trip` divides the whole run's count, the runtime's routines included.
- **Roc's side:** Roc's executable keeps its symbols. `native=` lists the jumps back in the app's own `roc__` function, and the loop was picked from that list and its disassembly by its shape and constants (the `% 1000` magic number, the item load). `range=` reads those addresses with llvm-mca. **The box can't count Roc's dynamic instructions**: there is no valgrind, and the VM exposes no PMU (x86/COST.md, "What the box has"). Roc's static count per trip is the only count we have for it.
- **llvm-mca** reads each hot path as one block for Cascade Lake: `rt` is its block reciprocal throughput in cycles, and `bound` is the busiest port over 100 passes, with its micro-ops per pass. Ports 0, 1, 5 and 6 do arithmetic (6 takes branches), 2 and 3 do loads, 4 is store data and 7 store addresses.
- **Timings** are one run each, niced, at a load average of about 2.5 while other lanes ran. They are a guide only, not a verdict.

## The table

| kernel | ours: hot | per trip | rt | bound | Roc: loop | rt | bound | ms: ours / node / Roc |
|---|---|---|---|---|---|---|---|---|
| sum_array | 39 | 39.0 | 8.0 | Port0 8.99 | 5 | 1.0 | Port0/Port6 1.27 | 3,126 / 1,554 / 70 |
| dot | 56 | 56.0 | 10.0 | Port0 10.01 | 8 | 1.5 | Port0/Port1 1.96 | 1,788 / 1,584 / 683 |
| fibonacci_remainder | 40 | 40.0 | 7.3 | Port0 11.02 | 44 per 8 trips | 16.0 per 8 trips | Port1 16.00 | 2,716 / 1,467 / 286 |
| call | 46 | 46.0 | 8.5 | Port0 13.02 | 7 per 8 trips | 1.3 per 8 trips | Port1 1.79 | 2,155 / 942 / 12 |
| fields | 157 | 157.0 | 27.2 | Port0 38.00 | 24 | 4.7 | Port5 6.61 | 893 / 427 / 83 |
| push | 23 | 66.1 all | 6.0 | Port4 6.00 | 10 | 1.7 | Port6 2.26 | 497 / 644 / 236 |
| map_get | 62 | 274.6 all | 14.0 | Port4 14.00 | 102 | 21.0 | Port0/Port6 20.00 | 1,025 / 605 / 697 |
| concat | 22 | 679.7 all | 4.2 | Port5 4.76 | 12 | 2.5 | Port6 2.26 | 3,917 / 675 / 461 |

For push, map_get and concat, `all` is the whole run's count per trip: their loops call the runtime, and the runtime does most of the work. Roc's map_get and concat loops call routines too (two `roc_llvm_rc_decref_27` calls a lookup, `strConcatOutOfLine` an append), and those routines aren't counted in its column.

## sum_array: the sum of an integer array

`for (let i = 0; i < a.length; i++) s = s + a[i]`, a thousand items read 50,000 times.

Ours (39 instructions a trip; `i` and `s` are doubles):

```
mov    rdi,QWORD PTR [rbp-0x8]      ; the array, from the frame
shl    rdi,0x10                     ; untagged
shr    rdi,0x10
mov    rax,QWORD PTR [rdi]          ; its length
cvtsi2sd xmm0,rax                   ; made a double, to compare with i
movq   xmm1,rbx
ucomisd xmm0,xmm1
...
cvttsd2si rcx,xmm0                  ; i made an integer for the index,
cvtsi2sd xmm1,rcx                   ;   and checked whole
ucomisd xmm0,xmm1
jp / jne
mov    rdi,QWORD PTR [rbp-0x48]     ; the array again, untagged again
shl    rdi,0x10
shr    rdi,0x10
mov    rdx,QWORD PTR [rdi]
cmp    rcx,rdx                      ; the bounds check
jae    ...
mov    r8,QWORD PTR [rdi+0x10]
mov    rax,QWORD PTR [r8+rcx*8]
movq xmm0,rbx / movq xmm1,rax / addsd / movq r11,xmm0      ; s + a[i]
movq xmm0,r10 / movabs rax,0x3ff0000000000000 / movq xmm1,rax / addsd / movq r10,xmm0   ; i++
```

Roc (5 instructions):

```
1180: add    r15,QWORD PTR [rdi+rsi*8]   ; s += a[j]
      jb     overflow                    ; Roc's integer overflow check
      inc    rsi
      cmp    rcx,rsi
      jne    1180
```

**The gap:**
- **`i` is a double.** The counter is compared with `a.length` in the loop's own condition, and that leaves it a double. With `const n = a.length` before the loop, the same loop is 27 instructions with `i` an integer in `r10` (`add r10,0x1`). With a constant bound (`i < 1000`) it is 23. That was measured on variants of this kernel at 5 rounds. Lowering gives a known array's length the `Integer` kind (Lowering.roc, the `GetProperty` case), so the loss is somewhere between that and the counter's narrowing (`OperatorLowering.integer_jump_items`). As a double, `i` costs a `cvtsi2sd` of the length, a `ucomisd`, three instructions to check the index is whole, and five for `i++`.
- **The array is reloaded and untagged twice a trip**, once for the length and once for the read, from `[rbp-0x8]` and from a stack place. Roc keeps the items' address in `rdi` and the length in `rcx` for the whole loop.
- **The bounds check runs every trip.** Roc has none: LLVM proved `j < len` from the loop's condition.
- **`s` is a double**, and each add is four instructions moving between general registers and `xmm`.

## dot: two arrays of doubles

`d = d + x[i] * y[i]`, a thousand items, 50,000 times.

Ours (56 instructions): the same counter and array costs as sum_array, twice, since both arrays are reloaded and untagged and both reads are bounds-checked. The product goes through the frame:

```
mov    rax,QWORD PTR [r8+rcx*8]
mov    QWORD PTR [rbp-0x50],rax         ; x[i] stored to a stack place
...
movsd  xmm0,QWORD PTR [rbp-0x50]        ; and loaded back
movq   xmm1,rax
mulsd  xmm0,xmm1
movsd  QWORD PTR [rbp-0x50],xmm0        ; the product stored
movq   xmm0,rbx
movsd  xmm1,QWORD PTR [rbp-0x50]        ; and loaded back
addsd  xmm0,xmm1
movq   r11,xmm0
```

Roc (8 instructions):

```
14c0: cmp    r9,rcx                         ; y's bounds check (x's is the loop's own)
      je     out_of_bounds
      vmovsd xmm1,QWORD PTR [r12+rcx*8]
      vmulsd xmm1,xmm1,QWORD PTR [r10+rcx*8]
      vaddsd xmm0,xmm0,xmm1                 ; d stays in xmm0
      inc    rcx
      cmp    r14,rcx
      jne    14c0
```

**The gap:** the double counter, the reloads and the bounds checks as in sum_array. **Doubles live in general registers and in the frame**: the item, the product and `d` each go through `movq` or a stack place between operations, so one `mulsd` and one `addsd` cost 9 instructions, where Roc keeps `d` in `xmm0` and folds the load into `vmulsd`.

## fibonacci_remainder: Fibonacci modulo a prime

`t = (a + b) % M; a = b; b = t`, 50 million steps.

Ours (40 instructions; `i` is an integer, `a`, `b` and `t` are doubles):

```
mov    rax,rbx                  ; i < N: N put in a register to compare
mov    rcx,0x2faf080
cmp    rax,rcx
...
addsd  xmm0,xmm1                ; a + b, as doubles
cvttsd2si rcx,xmm0              ; made whole for %, and checked whole
cvtsi2sd xmm1,rcx
ucomisd xmm0,xmm1
jp / jne
movabs rax,0x89705f3112a28fe5   ; % M, signed magic multiply
imul   rcx
add rdx,rcx / sar rdx,0x1d / mov rax,rcx / shr rax,0x3f / add rdx,rax
mov rax,0x3b9aca07 / imul rdx,rax / sub rcx,rdx
cvtsi2sd xmm0,rcx               ; back to a double
movq   rax,xmm0
mov rdx,rbx / shr rdx,0x3f / shl rdx,0x3f / or rax,rdx   ; -0's sign put back
mov    QWORD PTR [rbp-0x28],rbx ; t through the frame
```

Roc's loop is unrolled 8 times: 44 instructions for 8 steps, 5.5 a step. One step:

```
add    rax,rcx
mov    rdx,rax
mulx   rdx,rdx,rdi              ; unsigned magic multiply
shr    rdx,0x1d
imul   rdx,rdx,0x3b9aca07
sub    rax,rdx
```

From the third step of each eight on, LLVM drops the `shr` (a different magic constant in `r8`), because it knows each sum is below 2M.

**The gap:** **`a` and `b` are doubles although every value is below M.** `t` is `(a + b) % M`, between 0 and M - 1, but the loop's head widens `a` and `b` to ±2^53 the first time their range grows (README.md, "A loop's head"), so `a + b` may pass 2^53 and the `%` is a double's. That costs about 20 instructions a step: the whole-number check, the signed fix-up (`shr`, `add`), the convert back and -0's sign. **The compare's constant is not an immediate** (`mov rcx,0x2faf080; cmp rax,rcx`, against Roc's `cmp` with a register or an immediate). Roc also unrolls, which we don't.

## call: a small function in a loop

`s = mix(s, i)`, `mix(x, k) = (x * 31 + k) % 65536`, 50 million calls.

Ours (46 instructions): `mix` is inlined (Inlining.roc), so there is no call, but `s` is a double for the same reason as fibonacci_remainder's `a`. `x * 31` is a `mulsd` by `movabs rbx,0x403f000000000000` (31.0), `k` is converted with `cvtsi2sd`, and `% 65536` of a double goes through the same whole-number check and a signed magic multiply. A power of two would be an `and` for an `Integer`.

Roc (7 instructions for 8 calls):

```
1590: imul   eax,eax,0x94446f01     ; eight steps of s = s*31 + i, mod 2^16, composed
      add    eax,esi
      movzx  eax,ax                 ; % 65536 is the low 16 bits
      add    rdx,0x8
      add    rsi,rdi
      cmp    r14,rdx
      jne    1590
```

Its loop for one call at a time is 9 instructions: `shl rdx,5; sub rdx,rax` for `* 31`, an `add`, `movzx eax,dx`.

**The gap:** the widening that makes `s` a double, as in fibonacci_remainder; with `s` an `Integer` of 0 to 65535 the body would be a multiply, an add and an `and`. Roc's composition of eight steps into one multiply is LLVM's induction and recurrence rewriting, well past what a baseline compiler does, so call's timing (12 ms) overstates the gap that matters.

## fields: two fields of one object

`p.x = p.x + (i % 7); p.y = p.y + (p.x % 5)` on a class instance, 20 million times.

Ours (157 instructions a trip). Each of the four field reads and two field writes is FieldSlots' guarded access, 14 instructions:

```
mov    rdi,QWORD PTR [rbp-0x28]     ; p, from the frame every time
mov    rcx,rdi
shr    rcx,0x30
cmp    rcx,0xfffc                   ; is it an object?
jne    slow
shl    rdi,0x10
shr    rdi,0x10
mov    rcx,QWORD PTR [rdi]          ; its count
mov    rdi,QWORD PTR [rdi+0x10]     ; its entries
lea    rdx,[rip+0x7a3d]             ; "x"
cmp    rcx,0x2
jbe    slow
mov    rax,QWORD PTR [rdi+0x20]     ; the key at x's place
cmp    rax,rdx
jne    slow
mov    QWORD PTR [rdi+0x28],r11     ; the store
```

The field's value is a `Value`, so each use tests that it is a number (`shr rcx,0x30; cmp rcx,0xfff9; jae`) before `addsd`, and `p.x % 5` is a double's remainder with the whole-number check and -0's sign.

Roc (24 instructions; the record is two registers, `rax` and `r8`):

```
1540: mov    r9,rax
      mov    rdx,rcx
      mulx   rdx,rdx,rsi            ; i % 7
      ...
      add    rax,r9                 ; x += i % 7
      jb     overflow
      mov    rdx,rax
      mulx   rdx,rdx,rdi            ; x % 5
      shr    rdx,0x2
      lea    rdx,[rdx+rdx*4]
      mov    r9,rax
      sub    r9,rdx
      add    r8,r9                  ; y += x % 5
      jb     overflow
      inc    rcx
      dec    r14
      jne    1540
```

**The gap:** **the shape guard is paid at every access**, though `p` is a `const` that nothing in the loop can reshape (no call, no other write). One guard before the loop would leave each access a load or a store at `[entries+0x28]` or `[entries+0x38]`. **The fields' values have no kind**, so each use is tag-tested and their arithmetic is a double's. Roc goes further, with no memory at all: the record's fields are scalars in registers.

## push: pushes onto a new array

`const a = []; for (...) a.push(i + r)`, a thousand pushes, 20,000 times.

Ours: 23 instructions in the loop and 66 a trip in all. The loop's call:

```
add    rax,rcx                      ; i + r, an integer
cvtsi2sd xmm0,rax                   ; stored as a double
movq   rbx,xmm0
mov    rdi,r10
mov    rsi,rbx
mov    QWORD PTR [rbp-0x28],r9      ; the four spare registers saved
mov    QWORD PTR [rbp-0x38],r10
mov    QWORD PTR [rbp-0x40],r11
mov    QWORD PTR [rbp-0x48],rbx
call   runtime_push
mov    r9,QWORD PTR [rbp-0x28]
```

In the runtime, each push runs `runtime_push`, `runtime_push_item`, `runtime_push_item_room` and `runtime_push_item_kind_kept`, 30 instructions, and the collector's `runtime_gc_sweep_zero` adds 12 a push.

Roc (10 instructions; the store is in line):

```
1100: mov    r9,r8
      add    r9,r12                 ; i + r
      jb     overflow
      cmp    rsi,rcx                ; room left?
      je     grow                   ; else a call, out of line
      mov    QWORD PTR [rdi+rcx*8],r9
      inc    rcx
      inc    r8
      cmp    rbx,r8
      jne    1100
```

**The gap:** **no fast path for an append in line:** a compare with the capacity, a store and a length increment, with the call only to grow. **The spare registers are saved around every runtime call**, live or not. In its one timing ours beat node here (497 ms to 644), and the array's growth and the collector's work, not the loop, are most of the difference from Roc.

## map_get: lookups in a Map

`s = s + m.get(i % KEYS)` in a Map of a thousand whole-number keys, 10 million times.

Ours: 62 instructions in the loop and 275 a trip in all. `m.get` is two runtime calls, `runtime_new_array_*`, which makes an array for the call's argument, then `runtime_collection_method` with the method's name:

```
cvtsi2sd xmm0,rax                   ; the key, made a double
movsd  QWORD PTR [rbp-0x50],xmm0
mov    rdi,0x1
...4 spills...
call   0x402199                     ; an array of the one argument
...4 restores...
mov    QWORD PTR [rdx],rcx          ; the key put in it
mov    rdi,QWORD PTR [rbp-0x40]     ; m
lea    rsi,[rip+0x7543]             ; "get"
...4 spills...
call   0x4057ee                     ; runtime_collection_method
...4 restores...
mov rcx,rax / shr rcx,0x30 / cmp rcx,0xfff9 / jae   ; the result tested a number
```

In the runtime, per lookup: `runtime_collection_method`, `_method_own`, `_method_given` and `_method_get` (about 50 instructions to choose `get`), then `runtime_collection_find`, `_find_hashed`, `_hash_bits`, `_index` and `_find_probe`, and the collector's sweep of the argument arrays (`runtime_gc_sweep_zero`, 24 a lookup).

Roc (102 instructions, plus two `roc_llvm_rc_decref_27` calls): its wyhash of the key is about 35 instructions, and LLVM made `i % keys` a counter that wraps (`inc rax; cmp rax,[rbp-0x158]; cmovne rbx,rax`), with no divide. The Dict is reference-counted: each lookup increments two counts and calls decref twice. That is Roc's own cost, and we don't pay it.

**The gap:** **a Map's method on a value known to be a Map still takes the generic dispatch**, by the method's name, with an array made for its arguments, so each lookup allocates. With a guard on the tag and the record's first word (0, a Map), a `get` could call the find with the key in a register: no array, no name, no garbage. The `% KEYS` by a `const` is already a magic multiply on our side, which is fine.

**Closed (branch x86-mapfast, 2026-11-28):** the guard is in (x86/README.md, "Maps, Sets and iterators"). By the counter, the whole run went from 241.98 instructions a trip (master 3ad1066, after the lazy sweep) to 146.24, the loop's own from 62 to 58, and the allocations from 10,001,019 to 19. What is left is the find itself (`runtime_collection_find`, its probe, the hash and the index's check, about 75 a lookup) and the four spare registers saved around the call.

## concat: building a string

`s = s + "ab"`, a thousand appends, 2,000 times.

Ours: 22 instructions in the loop and 680 a trip in all, 75% of them in `runtime_gc_sweep_zero`. Each `+` makes a new string and copies all of `s` into it (`runtime_concat`, `runtime_add_texts`), so a round copies about a million bytes and leaves them as garbage, and the sweep zeroes every block it frees.

Roc (12 instructions and a call): `Str.concat` of a string only this loop holds appends in place, the bytes going into the room the buffer already has (`strConcatOutOfLine` grows it by doubling). For the first 23 bytes the string is held inside its own record, and that path is in line.

**The gap:** **`s = s + x` in a loop is quadratic** in bytes copied and in garbage. A string a local variable alone holds, appended to in a loop, could be a buffer with room to spare: an append in place, like Roc's or like V8's ropes. The other half is the sweep's zeroing of freed blocks. The lazy sweep merged into master after these numbers, so this kernel should be measured again on master before that half is worked on.

## The codegen gaps, ranked

Ranked by how many kernels pay each gap and how much it costs them.

1. **Values proved whole are kept as doubles.** This hits five of the eight kernels: sum_array, dot, fibonacci_remainder, call and fields. It costs 3 instructions a use for the whole-number check (`cvttsd2si`, `cvtsi2sd`, `ucomisd`, plus `jp` and `jne`), 5 for `i++`, and about 20 for a `%` (the signed fix-up, the convert back, -0's sign). Two causes:
   - a counter compared with `a.length` in its loop's condition stays a double (sum_array, dot), though `const n = a.length` keeps it an `Integer`. **Fix:** find where the `Integer` that `GetProperty "length"` gives is lost before `OperatorLowering.integer_jump_items` narrows the counter. This is the most common loop in JavaScript.
   - the loop head's widening sends a value straight to ±2^53 when its range first grows, so `(a + b) % M` and `(x * 31 + k) % 65536` stay doubles (fibonacci_remainder, call). **Fix:** widening with thresholds in Lowering's loop-head widening: widen to the next bound the program's own `%`, `&` and comparisons supply (M - 1, 65535) before ±2^53, or allow a few passes before widening. The fixpoint here is reached in two passes.
2. **Doubles live in general registers and the frame, not in `xmm` registers.** This hits six kernels (sum_array, dot, fibonacci_remainder, call, fields, map_get). One `addsd` is `movq xmm0,rbx; movq xmm1,rax; addsd; movq r11,xmm0`, and dot's product makes two round trips through `[rbp-0x50]`. Roc keeps `d` in `xmm0` and folds the load into `vmulsd`. **Fix:** let Registers (or a pass after FrameValues) rename a place whose kind is `Number` to an `xmm` register, and let operations take a memory operand.
3. **Loop-invariant work runs every trip.** This hits sum_array, dot, fields and push. An array is reloaded from the frame and untagged (`shl 0x10; shr 0x10`) at each use, its length and items' address are loaded again at each read, an object's shape guard runs at each field access, and a bounds check that the loop's own `i < a.length` proves runs every trip. **Fix:** a loop-invariant pass after the kinds settle, which keeps the untagged record, the length and the items' address in registers across the loop and drops checks the loop's condition implies. For a `const` object with no call or foreign write in the loop, it checks the shape once before the loop. COST.md's lane 4 notes already name the first part ("Keeping the untagged record across the iteration would need a register held across the loop").
   **Done in part (2026-11-28, x86/README.md, "Loop invariants"):** the record, the length, the items' address and the field guards are kept. Per trip, by the counter against master 3ad1066: sum_array 39 to 32 (rthroughput 8.0 either way), dot 56 to 46 (10.0 to 8.3), fields 157 to 97 (27.2 to 17.3, Port0 38.0 to 23.0); the other five kernels write master's bytes. The bounds check stays: the kernels' counter is a double (gap 1), whose sign the walk doesn't know, so `i < a.length` proves no `0 <= i`.
4. **A runtime call costs saves and layers.** This hits push, map_get and concat. The four spare registers (`r9`, `r10`, `r11`, `rbx`) are stored before every call and reloaded after, live or not, and the routines nest three or four deep (`runtime_push` to `runtime_push_item_kind_kept`). **Fix:** an append fast path in line (a capacity compare, a store, a length increment, with a call only to grow), saving only the places live after a call, and flattening the push and collection routines in Runtime.roc.
5. **A known Map's `get` and `set` go through the generic method dispatch.** This hits map_get: an argument array is allocated per call, the method is found by its name, and the lookup reaches the find after about 50 instructions. **Fix:** a guarded fast path in the lowering of a method call on a collection: test the tag (0xFFFE) and the record's first word, then call `runtime_collection_find_hashed` with the key in a register, no array and no name.
6. **`s = s + x` in a loop copies the whole string each time.** This hits concat, where the copies are quadratic in bytes and in garbage. **Fix:** a string a local alone holds, appended to in a loop, is a buffer with room (in place, as Roc's `Str.concat` is), found by an escape check in the lowering. Re-measure after the lazy sweep first, since the sweep's zeroing was 75% of this kernel's instructions.
7. **Peephole losses:**
   - a constant compared through a register (`mov rcx,0x2faf080; cmp rax,rcx`, not `cmp rax,imm32`);
   - chains of moves (`mov rbx,r9; mov rax,rbx; mov rcx,rbx`);
   - stack places stored and loaded back by the next place (`mov [rbp-0x48],rax`, then `mov rdi,[rbp-0x48]`);
   - `1.0` made with `movabs` and `movq` for every `i++` of a double.

   Each kernel pays a few instructions a trip for these. **Fix:** Moves' joins extended to immediates, and FrameValues' forwarding over the bytecode stack's places within a straight run.

LLVM also unrolls loops (fibonacci_remainder by 8), reduces strength (`i % keys` as a counter that wraps), and composes recurrences (call's eight steps in one `imul`). Those come after the gaps above: each gap above costs more per trip than unrolling would save.
