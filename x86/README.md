# x86: the JavaScript subset compiled to x86-64, in Roc alone

The code here was written by AI coding agents (Claude), with human supervision.

This folder is the start of an ahead-of-time compiler for the JavaScript subset that `js/` interprets. It will take a program through the interpreter's own front end (`js/roc/`'s Lexer, Parser, Resolve and Compile, to `Bytecode`) and turn the bytecode into a static Linux x86-64 executable. Roc writes every byte of that executable: there is no assembler, linker, LLVM or libc in the product, and the binary needs none to run.

## The milestones

1. **Hello, world.** The instruction encoder, the ELF writer, and the `write` and exit system calls. *Done* (below).
2. **Numbers and functions.** Doubles, calls and returns, `if` and loops; `fib` compiled and timed against node and the VM. *Done* (below).
3. **Heap values with a bump allocator, no collector.** Objects, arrays, strings; as many corpus programs as fit in memory without collecting. *Done* (below): 9 of the corpus's 61 programs.
4. **The runtime in the subset.** `console.log`'s formatting, Map and Set, number to string, written in the JavaScript subset and compiled by this compiler.
5. **The collector,** with the shadow stack as its roots, and the whole corpus held to node.
6. **Type specialization,** for long numeric loops.

## What works now (2026-11-24)

- `roc/X86.roc` encodes the instructions the milestones so far need: `mov` (register, immediate, memory, and `movabs` for an immediate past 32 bits), `lea`, `add`, `sub`, `and`, `or`, `xor`, `cmp` (register or immediate), `imul`, `div`, `idiv`, `cqo`, `neg`, `test`, `shl`, `shr`, `sar`, `setcc`, `movzx` of a byte register or of a byte of memory, a byte store, `rep movsb`, `push`, `pop`, `jmp`, `jcc`, `call` (each with a rel32), `ret`, `syscall`, and the SSE2 doubles `movsd`, `addsd`, `subsd`, `mulsd`, `divsd`, `ucomisd`, `cvtsi2sd`, `cvttsd2si` and `movq`. A memory operand is a base register, an optional scaled index and a displacement, or a displacement from `rip`. Every general register is 64 bits wide; a byte operand is one of `al`, `cl`, `dl` and `bl`, which need no REX prefix. Each instruction's bytes are held to its encoding by an `expect`, 95 of them, including the corner cases of the encoding: `rsp` and `r12` as a base (a SIB byte), `rbp` and `r13` with no displacement (a zero byte of it), and displacements and immediates at the edges of 8 and 32 bits.
- `roc/Assembly.roc` assembles a list of instructions, labels and data into code: a jump, a call or a `lea` that names a label gets a placeholder rel32, patched once every label's place is known.
- `roc/Elf.roc` wraps the code as a static executable: an ELF header, one program header and one loadable segment, read and execute, mapped at 0x400000, entry at the code's first byte. The data (the string to print) is read-only, so it shares that segment.
- `roc/Hello.roc` is the driver: given a text, it writes the executable that prints it and exits 0. The hello-world binary is 176 bytes.

- `roc/JsToX86.roc` is the compiler: `js-x86 "<program>"` parses and compiles the program with js/roc's own front end, by import (`js/roc/main.roc` makes `Ast`, `Bytecode`, `Compile` and `Parser` a package), lowers the bytecode (`roc/Lowering.roc`), and writes the executable. `roc/Runtime.roc` is the machine code every executable carries beside its own (about 7 KB of it): the start, the allocator, buffered output, the stops, and the routines below. `roc/Boxing.roc` holds a value's layout, and `roc/Emit.roc` short builders for the statements the runtime is written in, one instruction a line.

Roc's default platform writes only text to stdout, so each driver prints the executable as hex, and `executables.shale` turns each pair of digits back into its byte. The scripts decide no byte; they only carry them to the file.

**How the encodings were checked:** each `expect`'s bytes were disassembled with binutils' `objdump -D -b binary -mi386:x86-64 -M intel` during development and read back as the instruction the `expect` names, all 95 of them; the hello-world binary was read with `readelf -h -l` and its code with `objdump`. The product and its checks never run either tool.

## What the compiler compiles

**A value is NaN-boxed, and its kind is known ahead of time where it can be.** Every value's 8 bytes are its boxed bits (`roc/Boxing.roc`):

| top 16 bits | value | low 48 bits |
|---|---|---|
| below 0xFFF9 | a number | (the IEEE double's own) |
| 0xFFF9 | `undefined`, `null`, `false`, `true` | 0, 1, 2, 3 |
| 0xFFFA | a string | its address |
| 0xFFFB | an array | its address |
| 0xFFFC | a plain object | its address |

A number is its double, unchanged; the NaNs x86-64 makes (0x7FF8... for `NaN`, 0xFFF8... for `0 / 0`) lie below every tag, so a value is a number exactly when it is below 0xFFF9 shifted into place, one unsigned compare, and no arithmetic can make a tag. Lowering walks each function's instructions keeping the kind of each slot of the frame and each place on the bytecode's stack: a number, a boolean, `undefined`, `null`, a string, an array, an object, or `Value`, a value whose kind isn't known before it runs; or what takes no bytes (a function by the code it runs, `console`, `console.log`, an array's method looked up). Where two ways meet with two value kinds (a jump's target, a loop's head) the place becomes a `Value`; a loop whose body changes a kind widens its head and lowers the function again. Since a value's bits are the same whatever is known of it, widening costs no code. A known kind lets the code skip the tag's test: two numbers add with `addsd` and nothing else, as in milestone 2, so fib's code is unchanged but for the stack's check. A `Value` goes through the runtime, which tests the tag (`runtime_add`, `runtime_strict_equal`, `runtime_compare`, `runtime_truthy`, `runtime_check_number` before arithmetic). A function's parameters and its result take their kinds from the whole program: each pass meets every call's argument kinds and every return's kind per function, until both settle.

**The heap and the runtime's registers.** The start maps 1 GiB (`mmap`, `MAP_NORESERVE`, so only what is touched is memory) and sets four registers that no other code writes: `r12` the lowest the stack may reach, `r13` the runtime's state (the output buffer's fill, node's inspect depth, then 64 KiB of buffer), `r14` the heap's end, `r15` its next free byte. `runtime_allocate` is a bump allocator, 8-byte aligned; nothing is freed, and past the end the program stops with `x86: out of memory: the heap of 1 GiB is full, and no collector runs yet` on stderr and exit 1. A string is its length in 8 bytes, then its bytes; a literal sits in the read-only segment in the same layout, each text once. An array is its length, its capacity and its items' address, 8 bytes each; an object is its count, its capacity and its entries' address, 16 bytes each (a key's address and the value), searched in order. A full list is copied to one twice its size.

**Output is buffered.** console.log writes into the buffer, which is written when the next bytes wouldn't fit, before a stop's message, and at the exit; a write the kernel cuts short is written on until every byte is. `many-lines.js` prints 20,000 lines through it.

**Stack overflow.** Every function's entry checks its frame against `r12`, 6 MiB below the start's stack (Linux gives 8 MiB; the rest is the runtime's). Past it the program writes `RangeError: Maximum call stack size exceeded` to stderr and exits 1, as node does for an uncaught RangeError, whose stderr has that same line after the source line and a caret, and a stack trace after. How deep differs: node throws between 9,000 and 10,000 calls of `function d(n) { return n === 0 ? 0 : 1 + d(n - 1); }`, the executable between 80,000 and 90,000 (its frames are about 72 bytes), so a recursion between the two runs here and throws in node. A `try` that catches the RangeError isn't compiled.

**A frame is fixed per function**: below `rbp`, its slots, then the bytecode's stack as deep as the function ever makes it, so every push and pop is a load or a store at a known place. A call pushes its arguments, the last first, and the callee copies them to its parameters' slots; the result comes back in `rax`.

**Compiled:** numbers (SSE2), booleans, `undefined`, `null`, strings, arrays and plain objects in variables, parameters, results and on the stack; `+ - * /`, and `%` of whole numbers (by `idiv`: the dividend's sign, -0, `% 0` NaN); the four comparisons, of numbers or of strings (by their bytes); `===` and `!==` (NaN unequal to itself; strings by their bytes; anything else by its bits, so an array or object by identity); unary `- + !`, `++`, `--`, `+=` (a string's too); `if`, `while`, `for`, `for ... of` over an array, `break`, `continue`, `&&` and `||`; function declarations (and a function expression in a scope's first statement), called by name, with returns and recursion; `NaN` and `Infinity`; string literals, `+` with a string (`String(v)` of a number, a boolean, `undefined` or `null`), template strings, `.length`, `s[i]`; array literals, `a[i]`, `a[i] = v` (one past the end appends), `.length`, `push` of one or more items and `pop`; object literals, `o.k`, `o.k = v`, `o[k]` and `o[k] = v` with a string or whole-number key; and `console.log` of any number of any of these.

**console.log matches node's `util.inspect` for what is compiled:** a string is written raw at the top level and quoted inside an array or object, `'...'`, or `"..."` when it holds a `'`, with `\n`, `\t`, `\\`, `\r`, `\b` and `\f` escaped; a key is bare when it is an identifier (`[a-zA-Z_][a-zA-Z_0-9]*`) and quoted otherwise; an array or object is `[ 1, 2 ]` or `{ a: 1, b: 'x' }` on one line when node's rule puts it there (fewer than 3 levels nested below it, no item holding a line break, and its items' lengths plus 2n, the indentation and 11 at most 80), and one item a line, indented two spaces a level, otherwise; `[]`, `{}`, and `[Array]` and `[Object]` past depth 2.

**Refused, by name, before a byte is written:** classes, closures over a variable that holds a value (only a function's name may be captured), a function as a value (a callback, a method on an object), a function expression anywhere but a scope's first statement; `**`, `typeof`, `switch`, `try`, `throw`, destructuring, spread, and parameters with a pattern, a default or a rest; every builtin but `console.log`, `NaN` and `Infinity` (so `Math`, `String`, `Object`, Map, Set, the timers); every method but an array's `push` and `pop` (so `join`, `map`, `slice`, a string's methods); a string that isn't ASCII (a length here counts bytes, JavaScript's UTF-16 units); a call with more or fewer arguments than the function has parameters; an operator on kinds known to need a coercion (`true + 1`, `"a" * 2`); and every bytecode instruction not named above. `x86/tests/refused/` holds one program for most of them.

**Stopped as it runs, where only the value decides,** with a line `x86: ... is not compiled yet` on stderr and exit 1, so the output can't pass for node's: arithmetic or an ordering on a `Value` that turns out not to be numbers (or two strings); `+` of two values neither a string nor both numbers; `%` of numbers that aren't whole; an array written past its end, leaving holes; an object given an integer key (node lists those first, which a list in insertion order doesn't); an index or property on a value that has none here; console.log of an array of more than 6 items that node lays out in columns, or of more than 100; of a string holding both quotes or another control byte inside an array or object; and of a number that isn't an integer of at most 2^53 (fractions are milestone 4's shortest round-trip printing). Numbers are written as node writes them when they are such integers, `NaN`, `Infinity`, `-Infinity` or `-0` (and `String(-0)` is `"0"`).

## The corpus (2026-11-24)

`programs.shale` compiles each of the interpreter's 61 programs (`js/tests/`) and holds the ones whose executables print what node prints, exactly, to `x86/corpus.txt`: **9 of 61**, 01-hello, 03-let-const, 04-if-while, 05-for, 19-printing-nested, 22-hoisting, 25-shared-references, 29-linked-list and 31-matrix. A program that starts or stops matching fails the gate until the list moves, in a commit that says why. `shale x86/programs.shale corpus=report` prints the rest's reasons, grouped; today's, by the first refusal each program meets:

| programs | the first reason |
|---|---|
| 22 | a closure over a variable that holds a value (the classes' methods among them) |
| 6 | a method other than `push` and `pop` (`map` 2, `join` 2, `slice`, `charAt`) |
| 5 | a function called only as a value (a `sort` or `map` callback): no call shows its parameters' kinds, so they are taken as numbers and its body is refused (26, 32, 49, 50, 53) |
| 4 | a builtin (`Math`, `String`, `Object`, `setTimeout`) |
| 3 | console.log of an array node lays out in columns (08-array-push, 11-fib, 28-gcd-primes) |
| 3 | `try` and `throw` |
| 1 each | `**`, `typeof`, `switch`, parameters with defaults, a string that isn't ASCII, a function expression after a scope's start, a string with both quotes printed in an array, a property of `null` (which throws in node), and 43-uncaught-error (node exits 1) |

The closures are the long pole: a captured variable needs a box on the heap, which this milestone's heap makes possible and milestone 4 or 5 should take up.

## fib, compiled and timed (2026-11-24)

`x86/fib.js` is the recursive `fib(n)` printing `fib(22)` and `fib(30)` (17711 and 832040). Each time is the best of three runs, wall clock and CPU, on the 2-core box with its load average at 0.78, 0.45, 0.40, node v22; js-vm is the bytecode VM's release build, from the shared build cache:

| program | the executable | node | js-vm (release) |
|---|---|---|---|
| fib(22) | 1 ms (1 ms CPU), 7,976 bytes | 60 ms | 97 ms |
| fib(22) and fib(30) | 20 ms (19 ms CPU), 8,044 bytes | 60 ms | 4,696 ms |

Milestone 2's numbers were 1 ms and 21 ms with 1,010- and 1,089-byte executables: every function's entry now checks the stack (two instructions), and every executable carries the whole runtime, about 7 KB, whatever it uses. On fib(22) the executable's time is all work, about a millisecond, where node's is mostly its start. On fib(30), 1.6 million calls, node's optimizing tier makes its own work about 16 ms, the executable's about 20: fib's kinds are all known, so no tag is tested, but the baseline code keeps every value in memory and moves it through `rax` or `xmm0` an instruction at a time, which milestone 6's register allocation and specialization are for. The VM is about 230 times slower than the executable there.

## Running it

From the repository's root:

    shale x86/hello.shale            # the encoder's expects, then the hello-world executable
    shale x86/programs.shale         # each program in x86/tests/ held to node, each in tests/refused/ to its refusal, the corpus to x86/corpus.txt
    shale x86/programs.shale corpus=report   # the same, with each corpus program's reason, grouped
    shale x86/fib.shale              # the compiler's expects, fib held to node, then the times
    shale x86/fib.shale timing=0     # the same without the times

`hello.shale` runs the backend's 109 expects (`roc test x86/roc/Hello.roc`, which runs every imported module's), builds the driver on the dev backend, writes the executable under the build mount, runs it, and holds its output (`Hello, world!` and a newline) and its exit code (0) exactly. `programs.shale` compiles each program in `tests/` and holds what its executable prints and its exit code to node's, exactly; each program in `tests/refused/` names in its first line the refusal js-x86 must print (`// refused: <text>`) or the line its executable must stop with (`// stops: <text>`); then the corpus, as above. `fib.shale` holds the compiler's 123 expects (the encoder's, Boxing's 3, and js/roc's 11 that the front end brings), then fib to node, then times the executable, node and js-vm's release build; it never starts a release build, and says so when the cache holds none of today's inputs (`tools/roc_build.shale cached=1`). `shale check.shale` runs all three (fib with `timing=0`), and runs `roc fmt --check` and `roc check` over this folder as over the rest.

The drivers alone, once built: `x86-hello "Hello, world!"` and `js-x86 "<program>"` print an executable's bytes as hex; a program js-x86 refuses ends with a line `js-x86: <why>` and exit 1.

`x86/lints.shale` and `x86/accepted_terms.txt` give Shale's Roc lints the manuals' short words (`rax`, `lea`, `rex`), which they would otherwise read as abbreviations.
