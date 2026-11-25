## This module holds the small statement builders the runtime's routines
## share: a frame's places, a stop at a text, a value's tag tested, boxed
## and unboxed, an array's item addressed, a double's bits, a whole number
## checked, an error passed by. None marks a label of its own or names a
## routine of `Runtime`'s, so it imports no Runtime.
##
## It stands apart from Runtime because Runtime is being split into
## modules of their own (the texts, the timers, the collections, inspect,
## the array methods), each of which imports Runtime for the routines'
## names and uses these builders too: a module they all import, and that
## imports none of them, is the one place the builders can live without
## a cycle.
import Assembly
import Boxing
import Emit
import X86

RuntimeBuilders :: [].{

	## The place `offset` bytes below `rbp`, `[rbp - offset]`, where a
	## routine's frame keeps what it holds.
	local : I64 -> X86.Mem
	local = |offset| Emit.mem(Rbp, 0 - offset)

	## The statements that stop the program with the text at `label`.
	stopping_items : Str -> List(Assembly.Statement)
	stopping_items = |label| [Emit.address_of(Rsi, label), Emit.jmp("runtime_stop")]

	## The label of an error's key, the one-byte string every error object
	## holds as its first key, which `not_an_error_items` looks for.
	error_mark : Str
	error_mark = "runtime_text_error_mark"

	## The statements that stop the program when the object at `rsi`
	## (unboxed) is an error; `label` names their way past. They change `rcx`
	## and `rdx`.
	not_an_error_items : Str -> List(Assembly.Statement)
	not_an_error_items = |label| [
		Emit.load(Rcx, Emit.mem(Rsi, 0)),
		Emit.test(Rcx, Rcx),
		Emit.jcc(E, label),
		Emit.load(Rcx, Emit.mem(Rsi, 16)),
		Emit.load(Rcx, Emit.mem(Rcx, 0)),
		Emit.address_of(Rdx, RuntimeBuilders.error_mark),
		Emit.cmp(Rcx, Rdx),
		Emit.jcc(E, "runtime_spread_error"),
		Emit.mark(label),
	]

	## The statements that put the tag of the value in `from` in `rcx`.
	tag_load_items : X86.Register -> List(Assembly.Statement)
	tag_load_items = |from| [Emit.mov(Rcx, from), Emit.shr(Rcx, Boxing.tag_shift)]

	## The statements that jump to `label` unless the value in `reg` is a
	## string, with `rcx` its tag after.
	unless_string_items : { reg : X86.Register, label : Str } -> List(Assembly.Statement)
	unless_string_items = |{ reg, label }|
		RuntimeBuilders.tag_load_items(reg).concat([
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(Ne, label),
		])

	## The statements that jump to `label` unless the value in `reg` is a
	## number.
	unless_number_items : { reg : X86.Register, label : Str } -> List(Assembly.Statement)
	unless_number_items = |{ reg, label }|
		RuntimeBuilders.tag_load_items(reg).concat([
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(Ae, label),
		])

	## The pointer a boxed value holds, its tag cleared, in the same register:
	## the top 16 bits shifted out and back as zeros.
	unboxed_items : X86.Register -> List(Assembly.Statement)
	unboxed_items = |reg| [Emit.shl(reg, 16), Emit.shr(reg, 16)]

	## The statements that put the boxed value of the pointer in `rax`, with
	## `tag`, in `rax`. They change `rcx`.
	boxed_items : I64 -> List(Assembly.Statement)
	boxed_items = |tag| [Emit.imm(Rcx, Boxing.tag_bits(tag)), Emit.plus(Rax, Rcx)]

	## The string at the address in `rax` boxed, in `rax`. It changes `rcx`.
	boxed_string_items : List(Assembly.Statement)
	boxed_string_items = [Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)), Emit.plus(Rax, Rcx)]

	## The address of item `index` of the items whose address is in `r8`.
	listed_item : X86.Register -> X86.Mem
	listed_item = |index| Based({
		base: R8,
		index: Scaled({ reg: index, scale: Times8 }),
		displacement: 0,
	})

	## A double's bits, as an immediate takes them.
	double_bits : F64 -> I64
	double_bits = |value| value.to_bits().to_i64_wrap()

	## A double's bits put in an xmm register, through `rax`.
	double_items : { to : X86.Xmm, value : F64 } -> List(Assembly.Statement)
	double_items = |{ to, value }| [
		Emit.imm(Rax, RuntimeBuilders.double_bits(value)),
		Emit.to_xmm(to, Rax),
	]

	## The statements that leave the number in `reg`, as a whole number of at
	## most 2^53 in size, in `to`, or jump to `label`. They change `rcx`.
	whole_number_items : {
		reg : X86.Register,
		to : X86.Register,
		label : Str,
	} -> List(Assembly.Statement)
	whole_number_items = |{ reg, to, label }| {
		[
			Emit.to_xmm(Xmm0, reg),
			Instruction(Cvttsd2si({ to, from: Xmm0 })),
			Instruction(Cvtsi2sd({ to: Xmm1, from: to })),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(P, label),
			Emit.jcc(Ne, label),
			Emit.imm(Rcx, 9007199254740992),
			Emit.cmp(to, Rcx),
			Emit.jcc(G, label),
			Emit.imm(Rcx, -9007199254740992),
			Emit.cmp(to, Rcx),
			Emit.jcc(L, label),
		]
	}
}
