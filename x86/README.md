# x86: the JavaScript subset compiled to x86-64, in Roc alone

The code here was written by AI coding agents (Claude), with human supervision.

This folder is the start of an ahead-of-time compiler for the JavaScript subset that `js/` interprets. It will take a program through the interpreter's own front end (`js/roc/`'s Lexer, Parser, Resolve and Compile, to `Bytecode`) and turn the bytecode into a static Linux x86-64 executable. Roc writes every byte of that executable: there is no assembler, linker, LLVM or libc in the product, and the binary needs none to run.

## The milestones

1. **Hello, world.** The instruction encoder, the ELF writer, and the `write` and exit system calls. *Done* (below).
2. **Numbers and functions.** Doubles, calls and returns, `if` and loops; `fib` compiled and timed against node and the VM.
3. **Heap values with a bump allocator, no collector.** Objects, arrays, strings; as many corpus programs as fit in memory without collecting.
4. **The runtime in the subset.** `console.log`'s formatting, Map and Set, number to string, written in the JavaScript subset and compiled by this compiler.
5. **The collector,** with the shadow stack as its roots, and the whole corpus held to node.
6. **Type specialization,** for long numeric loops.

## What works now (2026-11-24)

- `roc/X86.roc` encodes the instructions the first two milestones need: `mov` (register, immediate, memory, and `movabs` for an immediate past 32 bits), `lea`, `add`, `sub`, `and`, `or`, `xor`, `cmp` (register or immediate), `imul`, `test`, `shl`, `sar`, `push`, `pop`, `jmp`, `jcc`, `call` (each with a rel32), `ret`, `syscall`, and the SSE2 doubles `movsd`, `addsd`, `subsd`, `mulsd`, `divsd`, `ucomisd`, `cvtsi2sd`, `cvttsd2si` and `movq`. A memory operand is a base register, an optional scaled index and a displacement, or a displacement from `rip`. Every general register is 64 bits wide. Each instruction's bytes are held to its encoding by an `expect`, 71 of them, including the corner cases of the encoding: `rsp` and `r12` as a base (a SIB byte), `rbp` and `r13` with no displacement (a zero byte of it), and displacements and immediates at the edges of 8 and 32 bits.
- `roc/Assembly.roc` assembles a list of instructions, labels and data into code: a jump, a call or a `lea` that names a label gets a placeholder rel32, patched once every label's place is known.
- `roc/Elf.roc` wraps the code as a static executable: an ELF header, one program header and one loadable segment, read and execute, mapped at 0x400000, entry at the code's first byte. The data (the string to print) is read-only, so it shares that segment.
- `roc/Hello.roc` is the driver: given a text, it writes the executable that prints it and exits 0. The hello-world binary is 176 bytes.

Roc's default platform writes only text to stdout, so the driver prints the executable as hex, and `hello.shale` turns each pair of digits back into its byte. The script decides no byte; it only carries them to the file.

**How the encodings were checked:** each `expect`'s bytes were disassembled with binutils' `objdump -D -b binary -mi386:x86-64 -M intel` during development and read back as the instruction the `expect` names, all 71 of them; the hello-world binary was read with `readelf -h -l` and its code with `objdump`. The product and its checks never run either tool.

## Running it

From the repository's root:

    shale x86/hello.shale

It runs the backend's 85 expects (`roc test x86/roc/Hello.roc`, which runs every imported module's), builds the driver on the dev backend, writes the executable under the build mount, runs it, and holds its output (`Hello, world!` and a newline) and its exit code (0) exactly. `shale check.shale` runs it as one of its checks, and runs `roc fmt --check` and `roc check` over this folder as over the rest.

The driver alone, once built, takes the text to print: `x86-hello "Hello, world!"` prints the executable's bytes as hex.

`x86/lints.shale` and `x86/accepted_terms.txt` give Shale's Roc lints the manuals' short words (`rax`, `lea`, `rex`), which they would otherwise read as abbreviations.
