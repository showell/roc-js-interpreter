# The SAT race: where the compiled solver's time goes (2026-11-27)

The code here was written by AI coding agents (Claude), with human supervision.

This is a profile of the compiled `sat.js` on the race workload, master f5afb83, to rank the general compiler fixes that would close js-x86's gap to node (95.24 s against 52.75 s, 1.81 times, README.md's preliminary race). Nothing in `sat.js` changes for it: the JavaScript stays a faithful transliteration of rocsat.

## How it was measured

`perf` can't sample on the box (`perf_event_paranoid` is 4), and neither valgrind nor gdb is installed, so the executables got a sampler of their own: given the argument `profile`, an executable maps a file `x86.prof` (eight bytes of count for each byte of code) and takes SIGPROF at every millisecond of its CPU time, counting the code byte each signal interrupted (x86/roc/Profiler.roc; without the argument, the start's test of it is the only cost). js-x86's new `labels` mode prints each label's place in the code, so a sample maps to its function (`code_<n>`, the bytecode's n-th code), to its bytecode instruction (`code_<n>_<at>`, js-dump's places) or to a runtime routine. `shale x86/satprofile.shale workload=race` does all of it: the executable, its disassembly, its labels, the profiled run and the tables.

One profiled run of the race workload, load 3.9 (other lanes compiling): 137.4 s wall, 104.3 s of CPU, 105,611 samples. The shares below are of those samples; the instruction counts are read from the disassembly by hand, to about 20%.

## Where the samples land

By function (the bytecode's codes, named by js-dump's dump of `sat.js`):

| share | function |
|---|---|
| 56.7% | `propagate` (code 16) |
| 11.1% | `lit_redundant` (code 21) |
| 5.6% | `push_watch` (code 13) |
| 4.3% | `analyze` (code 19) |
| 2.0% | `cancel_until` (code 5) |
| 7.5% | the property lookups on `st`: `runtime_get_property_hashed`, `runtime_object_entry_probe`, `_hashed`, `_hashed_probe`, `_hit`, `runtime_object_index*`, `runtime_text_equal*` |
| 2.8% | `runtime_strict_equal` and its answers |
| 2.0% | `runtime_word_of` |
| 3.2% | `runtime_collection_find_*`: the gate Map of the instances' making |
| 0.4% | the collector, every `runtime_gc_*` |

By instruction, two loads hold 15.8%: `mov rbx, [r8 + rcx*8]` of `arena[c + 2]` (propagate's bytecode 128, 8.9%, the sample landing on the `jmp` after it) and of `pool[base + 2 * i]` (bytecode 75, 6.9%). They are cache misses on the clause arena and the watch pool, which node's packed arrays of small integers pay as well (eight bytes an item either way, since node's x64 builds have no pointer compression). They are the program's, not the compiler's.

## What the watch loop's code does

Every array the solver uses is a property of `st`, a plain object of 40 keys, so every local that holds one is a `Value`, and so is every item read from one: `blocker`, `c`, `base`, `nw`, `trail_len`, all of them. The loop counters `i` and `j` are doubles, since they are compared with `nw`, a `Value`. So each line of the loop is lowered on `Value`s:

- **An item read** `pool[base + 2 * i]` is about 40 instructions: `2 * i` a `mulsd` through memory, `base + ...` the tag test of `base` and an `addsd` (with `runtime_add` beside it), then the array's tag test, the index's tag test, its whole-number test (`cvttsd2si`, `cvtsi2sd`, `ucomisd`, `jp`, `jne`), the unbox, the bounds test, the items' address and the load. An ideal lowering, with `pool` known an array of integers and `base` and `i` integers, is about 4: an `lea`, a bounds `cmp`, and the load.
- **`value[blocker] === true_val`** is the item read (about 22) and then a call of `runtime_strict_equal` with `r9`, `r10`, `r11` and `rbx` stored around it, and the boolean it answers compared with `true`: about 35 instructions more, where `ucomisd` and a jump, or one `cmp` of the bits, would do. Every `===` and `!==` of a `Value` is such a call: four to six of them each time a watch's blocker isn't true (`l0 === false_lit`, `first !== blocker`, `value[first] === true_val`, each `value[arena[k]] === false_val`, `value[first] === false_val`), and three in `lit_redundant`'s inner loop.
- **`p ^ 1`, `first >> 1`, `abstract_level(lv) & abstract_levels`**: a bitwise operator on a `Value` calls `runtime_word_of` for the operand, with the registers stored around it, though the value is a whole number every time.
- **`st.wofs[p]`, `st.wlen[p]`, `st.pool`, `st.wlen[p] = j`**: each `st.k` is a call of `runtime_get_property_hashed` (or the set), which hashes nothing (the compiler hands it the key's hash) but probes the object's table and compares the entry's key, about 60 instructions with the spills. propagate does three a literal propagated and one more after each `push_watch`, and `push_watch` itself five; `assign`, `pick`, `backtrack`, `analyze` and the rest read their arrays from `st` on every call.

## The ranked fixes

Every fix is in the compiler and general: it helps any program that compares, masks or indexes values whose kinds aren't known before it runs, or reads a plain object's fields.

### 1. `===` and `!==` of a `Value` in line, fused with their jump (about 5 to 8%)

The equality of a `Value` with a known number, or of two `Value`s, that a `JumpIfFalse` follows: the value's tag tested in line, two numbers compared by `ucomisd` and the jump taken on its flags, as `equal_jump_items` does for two known numbers; a non-number against a known number is unequal with no call; two values that aren't both numbers keep the call. Saved: `runtime_strict_equal`'s 2.8% and, at each call site, the spills, the call and the boolean's test (about 25 instructions a comparison).

- **Modules:** Lowering.roc (`fused_jump`), OperatorLowering.roc (`equal_jump_items`).
- **Risk:** low: NaN, -0 and strings are the cases to hold to node (x86/tests/equal-jumps.js has the numbers' already).

### 2. Fixed slots for a plain object literal's keys, guarded (about 6 to 9%)

FieldSlots guesses a class instance's field places from its constructor. An object literal's keys are laid out in the order it writes them, so `core_new`'s `{ num_vars: n, arena: [0], ... }` puts `arena` at place 1 in every state object. The same guard (the receiver an object, more entries than the place, the entry's key the literal's address) makes `st.arena` a load where it hits, and the runtime's call where it doesn't. Saved: the 7.5% of the lookup routines, and the calls' spills.

- **Modules:** FieldSlots.roc (`field_slots`, from each `NewObject`'s run of `SetField`s).
- **Risk:** low: a wrong guess is only slow. A literal with a spread or a computed value that holds another literal must not be counted wrong; the guard makes even that safe.

### 3. A bitwise operator's `Value` operand made its word in line (about 3%)

`runtime_word_of` is called for every `Value` operand. In line: the tag test, `cvttsd2si`, and the overflow test it already does for a known number (`cmp rax, 1; jno`), with the call kept for the rest. Saved: `runtime_word_of`'s 2.0% and the call sites' spills.

- **Modules:** OperatorLowering.roc (`word_items`).
- **Risk:** low: the routine stays for every value but a number in range.

### 4. Kinds through the heap (the largest, about 30% or more; out of this lane's reach)

Most of the watch loop's instructions are the tag and whole-number tests of `Value`s that are always whole numbers, and the doubles' arithmetic of indexes. Knowing that `st.pool` always holds an array of integers would make each item read the 4 instructions above. The compiler keeps a kind per slot and per function's parameters and result, never per object field or per array that has escaped into an object (Lowering's `NUMBER-ONLY ARRAYS` refuses a `Numbers` array stored in an object). That is milestone 6, type specialization, and a reshaping of the kinds passes; it is not attempted here.

### Not ranked

- **The cache misses** on the arena and the pool (15.8%) are the solver's own.
- **The gate Map** (3.2%) is the instances' making, not the solve: `runtime_collection_find_next` walks the Map's entries in order for each lookup. A hashed Map would help any program with large Maps (x86/README.md: a Map's entries are searched by SameValueZero).
- **The collector** is 0.4%: not a cause here, so nothing in Heap.roc or the allocator is touched.
- **Spills of `r9` to `r11` and `rbx`** around every call are part of fixes 1 to 3's savings; what is left after them is around calls of program functions (`push_watch`, `lit_redundant`).

## The fixes as made

(Each fix's measured effect is added below as it lands.)
