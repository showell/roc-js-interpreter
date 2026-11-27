## This module is the executables' sampling profiler, for reading where a
## compiled program spends its time on a box where `perf` may not sample
## (x86/satrace/TRIAGE.md). Given the first argument `profile`, the start
## opens `x86.prof` in the working folder, maps it at `counts_address`,
## eight bytes for each byte of code, and asks the kernel for SIGPROF at
## every millisecond of the process's CPU time. The handler adds one to the
## count of the code byte the signal interrupted (the context's `rip`), so
## the file holds, at its exit, a sample count for each instruction's first
## byte. `x86/profile.shale` reads it back against js-x86's `labels`.
##
## Without the argument it does nothing: the start's test of the argument
## is the only cost. A sample outside the code is not counted. The handler
## changes registers freely, since the kernel restores them all when the
## signal returns, and touches neither the heap nor the runtime's state.
import Assembly
import Emit
import X86

Profiler :: [].{

	## Where the counts are mapped: above the executable's 0x400000 and far
	## below the heap's mapping, which the kernel places near the top of the
	## address space.
	counts_address : I64
	counts_address = 0x10000000

	## The most code bytes counted: 2 MiB, eight bytes of count each.
	most_code : I64
	most_code = 0x200000

	## The code's first byte, the executable's entry (Elf's `load_address`
	## and its headers).
	code_start : I64
	code_start = 0x400078

	## The start's part: with `profile` as the first argument, the counts'
	## file opened and mapped, the handler set and the timer started. It
	## runs before the program's code, and changes `rax`, `rcx`, `rdx`,
	## `rsi`, `rdi` and `r8` to `r11`.
	start_items : List(Assembly.Statement)
	start_items = [
		Emit.load(Rcx, Emit.mem(Rsp, 0)),
		Emit.cmp_imm(Rcx, 2),
		Emit.jcc(B, "runtime_profile_off"),
		Emit.load(Rcx, Emit.mem(Rsp, 16)),
		Emit.load(Rcx, Emit.mem(Rcx, 0)),
		Emit.imm(Rax, word_bits("profile")),
		Emit.cmp(Rcx, Rax),
		Emit.jcc(Ne, "runtime_profile_off"),
		# open("x86.prof", O_RDWR | O_CREAT | O_TRUNC, 0644)
		Emit.imm(Rax, 2),
		Emit.address_of(Rdi, "runtime_profile_path"),
		Emit.imm(Rsi, 0x242),
		Emit.imm(Rdx, 420),
		Emit.syscall,
		Emit.test(Rax, Rax),
		Emit.jcc(S, "runtime_profile_off"),
		Emit.mov(R8, Rax),
		# ftruncate(fd, size): a sparse file of zero counts.
		Emit.imm(Rax, 77),
		Emit.mov(Rdi, R8),
		Emit.imm(Rsi, most_code * 8),
		Emit.syscall,
		# mmap(counts_address, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0)
		Emit.imm(Rax, 9),
		Emit.imm(Rdi, counts_address),
		Emit.imm(Rsi, most_code * 8),
		Emit.imm(Rdx, 3),
		Emit.imm(R10, 0x11),
		Emit.zero(R9),
		Emit.syscall,
		Emit.test(Rax, Rax),
		Emit.jcc(S, "runtime_profile_off"),
		# rt_sigaction(SIGPROF, the action, 0, 8): the handler, SA_SIGINFO,
		# SA_RESTORER and SA_RESTART, the return, and no mask.
		Emit.minus_imm(Rsp, 32),
		Emit.address_of(Rax, "runtime_profile_sample"),
		Emit.store(Emit.mem(Rsp, 0), Rax),
		Emit.imm(Rax, 0x14000004),
		Emit.store(Emit.mem(Rsp, 8), Rax),
		Emit.address_of(Rax, "runtime_profile_return"),
		Emit.store(Emit.mem(Rsp, 16), Rax),
		Emit.zero(Rax),
		Emit.store(Emit.mem(Rsp, 24), Rax),
		Emit.imm(Rax, 13),
		Emit.imm(Rdi, 27),
		Emit.mov(Rsi, Rsp),
		Emit.zero(Rdx),
		Emit.imm(R10, 8),
		Emit.syscall,
		# setitimer(ITIMER_PROF, {every 1 ms, first in 1 ms}, 0)
		Emit.zero(Rax),
		Emit.store(Emit.mem(Rsp, 0), Rax),
		Emit.store(Emit.mem(Rsp, 16), Rax),
		Emit.imm(Rax, 1000),
		Emit.store(Emit.mem(Rsp, 8), Rax),
		Emit.store(Emit.mem(Rsp, 24), Rax),
		Emit.imm(Rax, 38),
		Emit.imm(Rdi, 2),
		Emit.mov(Rsi, Rsp),
		Emit.zero(Rdx),
		Emit.syscall,
		Emit.plus_imm(Rsp, 32),
		Emit.mark("runtime_profile_off"),
	]

	## The handler (`rdx` the context, its `rip` at 168) and the return the
	## kernel enters after it, and the file's name.
	items : List(Assembly.Statement)
	items = [
		Emit.mark("runtime_profile_sample"),
		Emit.load(Rax, Emit.mem(Rdx, 168)),
		Emit.imm(Rcx, code_start),
		Emit.minus(Rax, Rcx),
		Emit.imm(Rcx, most_code),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Ae, "runtime_profile_sampled"),
		Emit.imm(Rcx, counts_address),
		Instruction(MovRegMem({ to: Rdx, from: count_place })),
		Emit.plus_imm(Rdx, 1),
		Instruction(MovMemReg({ to: count_place, from: Rdx })),
		Emit.mark("runtime_profile_sampled"),
		Emit.ret,
		Emit.mark("runtime_profile_return"),
		Emit.imm(Rax, 15),
		Emit.syscall,
		Emit.mark("runtime_profile_path"),
		Data("x86.prof".to_utf8().append(0)),
	]
}

## The count of the code byte in `rax`, the counts at `rcx`.
count_place : X86.Mem
count_place = Based({
	base: Rcx,
	index: Scaled({ reg: Rax, scale: Times8 }),
	displacement: 0,
})

## A word of at most 8 bytes as the little-endian bits a load of it gives,
## the bytes past it zero (a string's terminating NUL).
word_bits : Str -> I64
word_bits = |word| {
	var $bits = 0
	var $scale = 1
	for byte in word.to_utf8() {
		$bits = $bits + byte.to_i64() * $scale
		$scale = $scale * 256
	}
	$bits
}

expect word_bits("ab") == 0x6261
expect word_bits("profile") == 0x656C69666F7270
