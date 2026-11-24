# x86: the JavaScript subset compiled to x86-64, in Roc alone

The code here was written by AI coding agents (Claude), with human supervision.

This folder is the start of an ahead-of-time compiler for the JavaScript subset that `js/` interprets. It will take a program through the interpreter's own front end (`js/roc/`'s Lexer, Parser, Resolve and Compile, to `Bytecode`) and turn the bytecode into a static Linux x86-64 executable. Roc writes every byte of that executable: there is no assembler, linker, LLVM or libc in the product, and the binary needs none to run.

## The milestones

1. **Hello, world.** The instruction encoder, the ELF writer, and the `write` and exit system calls. *Done* (below).
2. **Numbers and functions.** Doubles, calls and returns, `if` and loops; `fib` compiled and timed against node and the VM. *Done* (below).
3. **Heap values with a bump allocator, no collector.** Objects, arrays, strings; as many corpus programs as fit in memory without collecting.
4. **The runtime in the subset.** `console.log`'s formatting, Map and Set, number to string, written in the JavaScript subset and compiled by this compiler.
5. **The collector,** with the shadow stack as its roots, and the whole corpus held to node.
6. **Type specialization,** for long numeric loops.

## What works now (2026-11-24)

- `roc/X86.roc` encodes the instructions the first two milestones need: `mov` (register, immediate, memory, and `movabs` for an immediate past 32 bits), `lea`, `add`, `sub`, `and`, `or`, `xor`, `cmp` (register or immediate), `imul`, `div`, `neg`, `test`, `shl`, `sar`, `setcc`, `movzx` of a byte, a byte store, `push`, `pop`, `jmp`, `jcc`, `call` (each with a rel32), `ret`, `syscall`, and the SSE2 doubles `movsd`, `addsd`, `subsd`, `mulsd`, `divsd`, `ucomisd`, `cvtsi2sd`, `cvttsd2si` and `movq`. A memory operand is a base register, an optional scaled index and a displacement, or a displacement from `rip`. Every general register is 64 bits wide; a byte operand is one of `al`, `cl`, `dl` and `bl`, which need no REX prefix. Each instruction's bytes are held to its encoding by an `expect`, 87 of them, including the corner cases of the encoding: `rsp` and `r12` as a base (a SIB byte), `rbp` and `r13` with no displacement (a zero byte of it), and displacements and immediates at the edges of 8 and 32 bits.
- `roc/Assembly.roc` assembles a list of instructions, labels and data into code: a jump, a call or a `lea` that names a label gets a placeholder rel32, patched once every label's place is known.
- `roc/Elf.roc` wraps the code as a static executable: an ELF header, one program header and one loadable segment, read and execute, mapped at 0x400000, entry at the code's first byte. The data (the string to print) is read-only, so it shares that segment.
- `roc/Hello.roc` is the driver: given a text, it writes the executable that prints it and exits 0. The hello-world binary is 176 bytes.

- `roc/JsToX86.roc` is the compiler: `js-x86 "<program>"` parses and compiles the program with js/roc's own front end, by import (`js/roc/main.roc` makes `Ast`, `Bytecode`, `Compile` and `Parser` a package), lowers the bytecode (`roc/Lowering.roc`), and writes the executable. `roc/Runtime.roc` is the machine code every executable carries beside its own: `console.log`'s writing of a number, and its texts.

Roc's default platform writes only text to stdout, so each driver prints the executable as hex, and `executables.shale` turns each pair of digits back into its byte. The scripts decide no byte; they only carry them to the file.

**How the encodings were checked:** each `expect`'s bytes were disassembled with binutils' `objdump -D -b binary -mi386:x86-64 -M intel` during development and read back as the instruction the `expect` names, all 87 of them; the hello-world binary was read with `readelf -h -l` and its code with `objdump`. The product and its checks never run either tool.

## What the compiler compiles

**Values carry no tags.** Lowering knows every value's kind before the program runs: it walks each function's instructions keeping the kind of each slot of the frame and each place on the bytecode's stack (a number, a boolean, `undefined`, a function by the code it runs, `console`, `console.log`), and where two ways meet (a jump's target, a loop's head) the kinds must agree. So a number is its 8 bytes of IEEE double, a boolean is 0 or 1, and a function costs nothing to hold. This is the essay's type specialization, done for the one case where it is free; NaN-boxing comes with the first value whose kind can't be known, in milestone 3.

**A frame is fixed per function**: below `rbp`, its slots, then the bytecode's stack as deep as the function ever makes it, so every push and pop is a load or a store at a known place. A call pushes its arguments, the last first, and the callee copies them to its parameters' slots; the result comes back in `rax`.

**Compiled:** numbers (SSE2) and booleans in variables, parameters and on the stack, and `undefined`; `+ - * /`, the four comparisons, `===` and `!==` (NaN unequal to itself, by `ucomisd`'s parity flag), unary `- + !`, `++`, `--` and a number's `+=`; `if`, `while`, `for`, `break`, `continue`, `&&` and `||`; function declarations (and a function expression in a scope's first statement), called by name, with returns and recursion, a function that returns nothing giving `undefined`; `NaN` and `Infinity`; and `console.log` of any number of numbers, booleans and `undefined`.

**Refused, by name, before a byte is written:** strings, objects, arrays and classes; `%` and `**`; every builtin but `console.log`, `NaN` and `Infinity`; a variable a closure captures that holds a value (only a function's name may be captured); a function expression anywhere but a scope's first statement; a call with more or fewer arguments than the function has parameters, or with an argument that isn't a number; a variable or a function's result whose kind differs by the way it was reached; and every bytecode instruction not named above. `x86/tests/refused/` holds one program for most of them.

**Numbers are written as node writes them** when they are integers of at most 2^53 in size (fib's answers), `NaN`, `Infinity`, `-Infinity` or `-0`. Any other number (a fraction, or an integer too large for every integer near it to be a double) is not written yet: the executable writes `x86: console.log of a number that is not an integer of at most 2^53 is not compiled yet` to stderr and exits 1, so its output can't pass for node's. Shortest round-trip printing of a fraction is milestone 4's.

**Not checked yet:** a recursion deep enough to overflow the stack (node throws a `RangeError`; the executable is stopped by a segfault); a write that the kernel cuts short.

## fib, compiled and timed (2026-11-24)

`x86/fib.js` is the recursive `fib(n)` printing `fib(22)` and `fib(30)` (17711 and 832040). Each time is the best of three runs, wall clock and CPU, on the 2-core box with its load average at 0.01, 0.32, 1.36, node v22; js-vm is the bytecode VM's release build, from the shared build cache:

| program | the executable | node | js-vm (release) |
|---|---|---|---|
| fib(22) | 1 ms (0 ms CPU), 1,010 bytes | 42 ms | 94 ms |
| fib(22) and fib(30) | 21 ms (19 ms CPU), 1,089 bytes | 58 ms | 4,560 ms |

On fib(22) the executable's time is all work, about a millisecond, where node's 42 ms is mostly its start; js-vm's 94 ms matches the book's 99. On fib(30), 1.6 million calls, node's optimizing tier makes its own work about 16 ms, the executable's about 20: the baseline code keeps every value in memory and moves it through `rax` or `xmm0` an instruction at a time, which milestone 6's register allocation and specialization are for. The VM is about 230 times slower than the executable there.

## Running it

From the repository's root:

    shale x86/hello.shale            # the encoder's expects, then the hello-world executable
    shale x86/programs.shale         # each program in x86/tests/ held to node, each in tests/refused/ to its refusal
    shale x86/fib.shale              # the compiler's expects, fib held to node, then the times
    shale x86/fib.shale timing=0     # the same without the times

`hello.shale` runs the backend's 101 expects (`roc test x86/roc/Hello.roc`, which runs every imported module's), builds the driver on the dev backend, writes the executable under the build mount, runs it, and holds its output (`Hello, world!` and a newline) and its exit code (0) exactly. `programs.shale` compiles each program in `tests/` and holds what its executable prints and its exit code to node's, exactly; each program in `tests/refused/` names in its first line the refusal js-x86 must print (`// refused: <text>`) or the line its executable must stop with (`// stops: <text>`). `fib.shale` holds the compiler's 112 expects (the encoder's, and js/roc's 11 that the front end brings), then fib to node, then times the executable, node and js-vm's release build; it never starts a release build, and says so when the cache holds none of today's inputs (`tools/roc_build.shale cached=1`). `shale check.shale` runs all three (fib with `timing=0`), and runs `roc fmt --check` and `roc check` over this folder as over the rest.

The drivers alone, once built: `x86-hello "Hello, world!"` and `js-x86 "<program>"` print an executable's bytes as hex; a program js-x86 refuses ends with a line `js-x86: <why>` and exit 1.

`x86/lints.shale` and `x86/accepted_terms.txt` give Shale's Roc lints the manuals' short words (`rax`, `lea`, `rex`), which they would otherwise read as abbreviations.
