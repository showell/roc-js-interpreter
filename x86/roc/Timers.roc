## This module holds the timers: the routines of `setTimeout`,
## `setInterval` and their clears, `runtime_run_timers`, which runs the
## callbacks once the program's own code is done, and the state they keep
## past `r13` (the timers' list, the virtual clock, the counts of timers
## set and of callbacks run), which nothing else reads.
##
## It stands apart from Runtime, its one caller being `RuntimeCode`,
## because its routines mark and call Runtime's names (`Runtime.set_timer`,
## `Runtime.run_timers`, `Runtime.allocate` ...), so it imports Runtime;
## Roc forbids an import cycle, so Runtime cannot list it in its own
## routines, and `RuntimeCode` puts the two together.
import Assembly
import Boxing
import Emit
import Runtime
import RuntimeBuilders
import X86

Timers :: [].{

	## The timers, on a virtual clock that reads 0 while the program runs and
	## moves to each callback's time as it runs. A timer is a record with the
	## collection tag (`Boxing.collection_tag`), its kind 3: its time due (8),
	## its place in the order set (16), its function (24), its interval (32, 0
	## for a timeout) and whether it is cleared or done (40). `runtime_run_timers`
	## runs the earliest due that is neither, two due at once in the order set;
	## an interval is set again after its callback, from its time, unless the
	## callback cleared it. A throw nothing catches in a callback stops the
	## program, as node's ends it.
	items : List(Assembly.Statement)
	items = {
		set_timer =
			[
				Emit.mark(Runtime.set_timer),
				Emit.save(Rbp),
				Emit.mov(Rbp, Rsp),
				Emit.minus_imm(Rsp, 32),
				Emit.store(RuntimeBuilders.local(8), Rdi),
				Emit.store(RuntimeBuilders.local(16), Rdx),
				Emit.mov(Rax, Rdi),
				Emit.call(Runtime.check_function),
				Emit.mov(Rdi, Rsi),
			]
				.concat(
					RuntimeBuilders.unless_number_items({
						reg: Rdi,
						label: "runtime_set_timer_coerced",
					}),
				)
				.concat([
					Emit.jmp("runtime_set_timer_numbered"),
					Emit.mark("runtime_set_timer_coerced"),
					Emit.call(Runtime.to_number),
					Emit.mov(Rdi, Rax),
					Emit.mark("runtime_set_timer_numbered"),
					# A delay not between 1 and 2^31 - 1 (NaN among them) is 1, as
					# node makes it; any other is its whole part.
					Emit.imm(Rax, 1),
					Emit.to_xmm(Xmm0, Rdi),
				])
				.concat(RuntimeBuilders.double_items({ to: Xmm1, value: 1.0 }))
				.concat([
					Emit.imm(Rax, 1),
					Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
					Emit.jcc(P, "runtime_set_timer_delayed"),
					Emit.jcc(B, "runtime_set_timer_delayed"),
				])
				.concat(RuntimeBuilders.double_items({ to: Xmm1, value: 2147483647.0 }))
				.concat([
					Emit.imm(Rax, 1),
					Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
					Emit.jcc(A, "runtime_set_timer_delayed"),
					Instruction(Cvttsd2si({ to: Rax, from: Xmm0 })),
					Emit.mark("runtime_set_timer_delayed"),
					Emit.store(RuntimeBuilders.local(24), Rax),
					Emit.load(Rax, timers_place),
					Emit.test(Rax, Rax),
					Emit.jcc(Ne, "runtime_set_timer_listed"),
					Emit.zero(Rdi),
					Emit.call(Runtime.new_array),
				])
				.concat(RuntimeBuilders.unboxed_items(Rax))
				.concat([
					Emit.store(timers_place, Rax),
					Emit.mark("runtime_set_timer_listed"),
					Emit.imm(Rdi, 48),
					Emit.call(Runtime.allocate),
					Emit.imm(Rcx, 3),
					Emit.store(Emit.mem(Rax, 0), Rcx),
					Emit.load(Rcx, clock_place),
					Emit.load(Rdx, RuntimeBuilders.local(24)),
					Emit.plus(Rcx, Rdx),
					Emit.store(Emit.mem(Rax, 8), Rcx),
					Emit.load(Rcx, timers_set_place),
					Emit.store(Emit.mem(Rax, 16), Rcx),
					Emit.plus_imm(Rcx, 1),
					Emit.store(timers_set_place, Rcx),
					Emit.load(Rcx, RuntimeBuilders.local(8)),
					Emit.store(Emit.mem(Rax, 24), Rcx),
					Emit.zero(Rcx),
					Emit.load(R8, RuntimeBuilders.local(16)),
					Emit.test(R8, R8),
					Emit.jcc(E, "runtime_set_timer_once"),
					Emit.mov(Rcx, Rdx),
					Emit.mark("runtime_set_timer_once"),
					Emit.store(Emit.mem(Rax, 32), Rcx),
					Emit.zero(Rcx),
					Emit.store(Emit.mem(Rax, 40), Rcx),
				])
				.concat(RuntimeBuilders.boxed_items(Boxing.collection_tag))
				.concat([
					Emit.store(RuntimeBuilders.local(32), Rax),
					Emit.load(Rdi, timers_place),
					Emit.mov(Rsi, Rax),
					Emit.call("runtime_push_item"),
					Emit.load(Rax, RuntimeBuilders.local(32)),
					Emit.mov(Rsp, Rbp),
					Emit.restore(Rbp),
					Emit.ret,
				])
		clear_timer =
			[Emit.mark(Runtime.clear_timer)]
				.concat(RuntimeBuilders.tag_load_items(Rdi))
				.concat([
					Emit.cmp_imm(Rcx, Boxing.collection_tag),
					Emit.jcc(Ne, "runtime_clear_timer_done"),
				])
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat([
					Emit.load(Rcx, Emit.mem(Rdi, 0)),
					Emit.cmp_imm(Rcx, 3),
					Emit.jcc(Ne, "runtime_clear_timer_done"),
					Emit.imm(Rcx, 1),
					Emit.store(Emit.mem(Rdi, 40), Rcx),
					Emit.mark("runtime_clear_timer_done"),
					Emit.imm(Rax, Boxing.undefined_bits),
					Emit.ret,
				])
		# r8: the timers' items; r9: their count; r10: the place; r11: the
		# earliest so far, 0 before one; the timer run is at [rsp].
		run_timers =
			[
				Emit.mark(Runtime.run_timers),
				Emit.load(R10, timers_place),
				Emit.test(R10, R10),
				Emit.jcc(E, "runtime_run_timers_done"),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(R9, Emit.mem(R10, 0)),
				Emit.zero(R10),
				Emit.zero(R11),
				Emit.mark("runtime_run_timers_scan"),
				Emit.cmp(R10, R9),
				Emit.jcc(E, "runtime_run_timers_scanned"),
				Emit.load(Rax, RuntimeBuilders.listed_item(R10)),
				Emit.plus_imm(R10, 1),
			]
				.concat(RuntimeBuilders.unboxed_items(Rax))
				.concat([
					Emit.load(Rcx, Emit.mem(Rax, 40)),
					Emit.test(Rcx, Rcx),
					Emit.jcc(Ne, "runtime_run_timers_scan"),
					Emit.test(R11, R11),
					Emit.jcc(E, "runtime_run_timers_earlier"),
					Emit.load(Rcx, Emit.mem(Rax, 8)),
					Emit.load(Rdx, Emit.mem(R11, 8)),
					Emit.cmp(Rcx, Rdx),
					Emit.jcc(L, "runtime_run_timers_earlier"),
					Emit.jcc(G, "runtime_run_timers_scan"),
					Emit.load(Rcx, Emit.mem(Rax, 16)),
					Emit.load(Rdx, Emit.mem(R11, 16)),
					Emit.cmp(Rcx, Rdx),
					Emit.jcc(Ge, "runtime_run_timers_scan"),
					Emit.mark("runtime_run_timers_earlier"),
					Emit.mov(R11, Rax),
					Emit.jmp("runtime_run_timers_scan"),
					Emit.mark("runtime_run_timers_scanned"),
					Emit.test(R11, R11),
					Emit.jcc(E, "runtime_run_timers_done"),
					Emit.load(Rcx, callbacks_run_place),
					Emit.cmp_imm(Rcx, callbacks_most),
					Emit.jcc(Ae, "runtime_run_timers_most"),
					Emit.plus_imm(Rcx, 1),
					Emit.store(callbacks_run_place, Rcx),
					Emit.load(Rcx, Emit.mem(R11, 8)),
					Emit.store(clock_place, Rcx),
					Emit.load(Rcx, Emit.mem(R11, 32)),
					Emit.test(Rcx, Rcx),
					Emit.jcc(Ne, "runtime_run_timers_call"),
					Emit.imm(Rcx, 1),
					Emit.store(Emit.mem(R11, 40), Rcx),
					Emit.mark("runtime_run_timers_call"),
					Emit.save(R11),
					Emit.load(Rbx, Emit.mem(R11, 24)),
				])
				.concat(RuntimeBuilders.unboxed_items(Rbx))
				.concat([
					Emit.load(Rax, Emit.mem(Rbx, 0)),
					Emit.plus(Rax, Rbx),
					Emit.zero(Rcx),
					Instruction(CallReg(Rax)),
					Emit.restore(R11),
					# An interval its callback didn't clear is due again.
					Emit.load(Rcx, Emit.mem(R11, 40)),
					Emit.test(Rcx, Rcx),
					Emit.jcc(Ne, Runtime.run_timers),
					Emit.load(Rcx, clock_place),
					Emit.load(Rdx, Emit.mem(R11, 32)),
					Emit.plus(Rcx, Rdx),
					Emit.store(Emit.mem(R11, 8), Rcx),
					Emit.load(Rcx, timers_set_place),
					Emit.store(Emit.mem(R11, 16), Rcx),
					Emit.plus_imm(Rcx, 1),
					Emit.store(timers_set_place, Rcx),
					Emit.jmp(Runtime.run_timers),
					Emit.mark("runtime_run_timers_done"),
					Emit.zero(Rdi),
					Emit.jmp(Runtime.exit),
					Emit.mark("runtime_run_timers_most"),
				])
				.concat(RuntimeBuilders.stopping_items("runtime_text_callbacks_most"))
		[set_timer, clear_timer, run_timers].join()
	}
}

## The timers' places past `r13`: their list (24, 0 before the first is
## set), the virtual clock (32), the count of timers set (40) and of
## callbacks run (48). Runtime's `buffer_place` says what comes before.
timers_place : X86.Mem
timers_place = Emit.mem(R13, 24)

clock_place : X86.Mem
clock_place = Emit.mem(R13, 32)

timers_set_place : X86.Mem
timers_set_place = Emit.mem(R13, 40)

callbacks_run_place : X86.Mem
callbacks_run_place = Emit.mem(R13, 48)

## How many timer callbacks run before the program stops: an interval
## never cleared runs for good in node.
callbacks_most : I64
callbacks_most = 100000
