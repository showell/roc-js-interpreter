## This module holds the routines of the language's own operations and
## built-in objects: `**`, `typeof`, the packing and iteration of values and
## the destructuring check; `throw`, `new Error` and an error's message;
## `Math`'s routines, an error's text and `Object.keys`'s listing; the
## string methods `charCodeAt` and `split`; and the spreads and rests.
##
## It stands apart from Runtime, its one caller being `RuntimeCode`,
## because its routines mark and call Runtime's names (`Runtime.throw`,
## `Runtime.new_error`, `Runtime.math_routine` ...), so it imports Runtime;
## Roc forbids an import cycle, so Runtime cannot list it in its own
## routines, and `RuntimeCode` puts the two together.
import Assembly
import Boxing
import Emit
import Heap
import Runtime
import RuntimeBuilders

LanguageRoutines :: [].{

	## Every routine of this module's, which `RuntimeCode` lays down after
	## Runtime's own: the language's operations, the exceptions, the
	## built-in objects, the string methods and the spreads.
	items : List(Assembly.Statement)
	items = [
		language_items,
		exception_items,
		builtin_items,
		string_method_items,
		spread_items,
	].join()
}

## `runtime_power`, `runtime_type_of`, `runtime_pack` and
## `runtime_items_of`. The power is made by squaring in whole numbers,
## each step held to 2^53 in size so that every product is exact: r10 the
## base squared so far, r9 the exponent left, rax the result, r11 the
## exponent given.
language_items : List(Assembly.Statement)
language_items = {
	magnitude_held = |reg| [
		Emit.imm(Rcx, 9007199254740992),
		Emit.cmp(reg, Rcx),
		Emit.jcc(G, "runtime_power_stop"),
		Emit.imm(Rcx, -9007199254740992),
		Emit.cmp(reg, Rcx),
		Emit.jcc(L, "runtime_power_stop"),
	]
	power = [Emit.mark(Runtime.power)]
		.concat(
			RuntimeBuilders.whole_number_items({
				reg: Rdi,
				to: R10,
				label: "runtime_power_stop",
			}),
		)
		.concat(
			RuntimeBuilders.whole_number_items({
				reg: Rsi,
				to: R9,
				label: "runtime_power_stop",
			}),
		)
		.concat([
			Emit.test(R9, R9),
			Emit.jcc(S, "runtime_power_stop"),
			Emit.mov(R11, R9),
			Emit.imm(Rax, 1),
			Emit.mark("runtime_power_step"),
			Emit.test(R9, R9),
			Emit.jcc(E, "runtime_power_done"),
			Emit.mov(Rcx, R9),
			Emit.bit_and_imm(Rcx, 1),
			Emit.jcc(E, "runtime_power_squared"),
			Instruction(Imul({ to: Rax, from: R10 })),
			Emit.jcc(O, "runtime_power_stop"),
		])
		.concat(magnitude_held(Rax))
		.concat([
			Emit.mark("runtime_power_squared"),
			Emit.shr(R9, 1),
			Emit.test(R9, R9),
			Emit.jcc(E, "runtime_power_done"),
			Instruction(Imul({ to: R10, from: R10 })),
			Emit.jcc(O, "runtime_power_stop"),
		])
		.concat(magnitude_held(R10))
		.concat([
			Emit.jmp("runtime_power_step"),
			# A zero power is -0 when the base is -0 and the exponent odd.
			Emit.mark("runtime_power_done"),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.test(Rax, Rax),
			Emit.jcc(Ne, "runtime_power_signed"),
			Emit.bit_and_imm(R11, 1),
			Emit.jcc(E, "runtime_power_signed"),
			Emit.imm(Rcx, (0x8000000000000000).to_i64_wrap()),
			Emit.cmp(Rdi, Rcx),
			Emit.jcc(Ne, "runtime_power_signed"),
			Emit.mov(Rax, Rcx),
			Emit.mark("runtime_power_signed"),
			Emit.ret,
			Emit.mark("runtime_power_stop"),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_power"))
	typed = |{ label, text }| [
		Emit.mark(label),
		Emit.address_of(Rax, text),
		Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)),
		Emit.plus(Rax, Rcx),
		Emit.ret,
	]
	type_of = [Emit.mark(Runtime.type_of)]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(B, "runtime_type_of_number"),
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(E, "runtime_type_of_string"),
			Emit.cmp_imm(Rcx, Boxing.function_tag),
			Emit.jcc(E, "runtime_type_of_function"),
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(Ne, "runtime_type_of_object"),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rdi, Rcx),
			Emit.jcc(E, "runtime_type_of_undefined"),
			Emit.imm(Rcx, Boxing.null_bits),
			Emit.cmp(Rdi, Rcx),
			Emit.jcc(E, "runtime_type_of_object"),
		])
		.concat(typed({ label: "runtime_type_of_boolean", text: "runtime_text_type_boolean" }))
		.concat(typed({ label: "runtime_type_of_number", text: "runtime_text_type_number" }))
		.concat(typed({ label: "runtime_type_of_string", text: "runtime_text_type_string" }))
		.concat(typed({ label: "runtime_type_of_function", text: "runtime_text_type_function" }))
		.concat(typed({ label: "runtime_type_of_object", text: "runtime_text_type_object" }))
		.concat(typed({ label: "runtime_type_of_undefined", text: "runtime_text_undefined" }))
	pack = [
		Emit.mark(Runtime.pack),
		Emit.save(Rdi),
		Emit.save(Rsi),
		Emit.mov(Rdi, Rsi),
		Emit.call(Runtime.new_array),
		Emit.restore(Rcx),
		Emit.restore(Rsi),
		Emit.mov(Rdi, Rdx),
		Emit.shl(Rcx, 3),
		Instruction(RepMovsb),
		Emit.ret,
		Emit.mark(Runtime.pack_received),
		Emit.save(Rdi),
		Emit.save(Rsi),
		Emit.save(R8),
		Emit.mov(Rdi, Rsi),
		Emit.plus_imm(Rdi, 1),
		Emit.call(Runtime.new_array),
		Emit.restore(R8),
		Emit.restore(Rcx),
		Emit.restore(Rsi),
		Emit.store(Emit.mem(Rdx, 0), R8),
		Emit.lea(Rdi, Emit.mem(Rdx, 8)),
		Emit.shl(Rcx, 3),
		Instruction(RepMovsb),
		Emit.ret,
	]
	# r10: the string; r9: its length; r11: the array; rdx: its items.
	items_of = [Emit.mark(Runtime.items_of), Emit.mov(Rax, Rdi)]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(E, "runtime_items_of_done"),
			Emit.cmp_imm(Rcx, Boxing.collection_tag),
			Emit.jcc(E, "runtime_items_of_collection"),
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(Ne, "runtime_not_iterable"),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.mov(R10, Rdi),
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.save(R9),
			Emit.save(R10),
			Emit.mov(Rdi, R9),
			Emit.call(Runtime.new_array),
			Emit.restore(R10),
			Emit.restore(R9),
			Emit.mov(R11, Rax),
			Emit.zero(R8),
			Emit.mark("runtime_items_of_next"),
			Emit.cmp(R8, R9),
			Emit.jcc(E, "runtime_items_of_made"),
			RuntimeBuilders.text_byte_item({ reg: Rax, base: R10 }),
		])
		.concat(RuntimeBuilders.one_byte_text_items)
		.concat(RuntimeBuilders.boxed_string_items)
		.concat([
			Emit.store(
				Based({
					base: Rdx,
					index: Scaled({ reg: R8, scale: Times8 }),
					displacement: 0,
				}),
				Rax,
			),
			Emit.plus_imm(R8, 1),
			Emit.jmp("runtime_items_of_next"),
			Emit.mark("runtime_items_of_made"),
			Emit.mov(Rax, R11),
			Emit.mark("runtime_items_of_done"),
			Emit.ret,
			Emit.mark("runtime_not_iterable"),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_not_iterable"))
	check_destructurable = [
		Emit.mark(Runtime.check_destructurable),
		Emit.mov(Rcx, Rax),
		Instruction(
			AluImm({
				operation: Or,
				to: Rcx,
				value: 1,
			}),
		),
		Emit.save(Rax),
		Emit.imm(Rax, Boxing.null_bits),
		Emit.cmp(Rcx, Rax),
		Emit.restore(Rax),
		Emit.jcc(E, "runtime_not_destructurable"),
		Emit.ret,
		Emit.mark("runtime_not_destructurable"),
	]
		.concat(RuntimeBuilders.stopping_items("runtime_text_not_destructurable"))
	[power, type_of, pack, items_of, check_destructurable].join()
}

## The statements that leave `rax` -0 when it is +0 and `rdi`, the number
## it was made of, is negative: `Math`'s roundings keep a zero's sign.
signed_zero_items : List(Assembly.Statement)
signed_zero_items = [
	Emit.mark("runtime_math_signed"),
	Emit.test(Rax, Rax),
	Emit.jcc(Ne, "runtime_math_done"),
	Emit.test(Rdi, Rdi),
	Emit.jcc(Ns, "runtime_math_done"),
	Emit.imm(Rax, (0x8000000000000000).to_i64_wrap()),
	Emit.mark("runtime_math_done"),
	Emit.ret,
]

## The statements that start a rounding of the number in `rdi`: one of at
## least 2^52 in size, an infinity or NaN is its own answer; any other is
## truncated, `xmm0` the number and `xmm1` its truncation.
truncated_items : Str -> List(Assembly.Statement)
truncated_items = |name| [
	Emit.mark(Runtime.math_routine(name)),
	Emit.mov(Rax, Rdi),
	Emit.mov(Rcx, Rdi),
	Emit.shl(Rcx, 1),
	Emit.shr(Rcx, 1),
	Emit.imm(Rdx, 0x4330000000000000),
	Emit.cmp(Rcx, Rdx),
	Emit.jcc(Ae, "runtime_math_done"),
	Emit.to_xmm(Xmm0, Rdi),
	Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
	Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
]

## `Math`'s routines, `runtime_error_text` (an error's text, of the error
## at `rax`: its name and its message, `: ` between, or the one of them
## that isn't empty) and `runtime_object_listing`.
builtin_items : List(Assembly.Statement)
builtin_items = {
	answer = [Instruction(MovqFromXmm({ to: Rax, from: Xmm1 })), Emit.jmp("runtime_math_signed")]
	stepped = |{ label, value }|
		RuntimeBuilders.double_items({ to: Xmm0, value })
			.concat([Emit.double_sum(Xmm1, Xmm0)])
			.append(Emit.mark(label))
			.concat(answer)
	trunc = truncated_items("trunc").concat(answer)
	floor = truncated_items("floor")
		.concat([
			Instruction(Ucomisd({ left: Xmm1, right: Xmm0 })),
			Emit.jcc(Be, "runtime_math_floor_done"),
		])
		.concat(stepped({ label: "runtime_math_floor_done", value: -1.0 }))
	ceiling = truncated_items("ceil")
		.concat([
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(Be, "runtime_math_ceil_done"),
		])
		.concat(stepped({ label: "runtime_math_ceil_done", value: 1.0 }))
	# Up from the floor when the number is at least a half past it: exact,
	# since the number is below 2^52 in size.
	round = truncated_items("round")
		.concat([
			Instruction(Ucomisd({ left: Xmm1, right: Xmm0 })),
			Emit.jcc(Be, "runtime_math_round_floored"),
		])
		.concat(RuntimeBuilders.double_items({ to: Xmm2, value: -1.0 }))
		.concat([
			Emit.double_sum(Xmm1, Xmm2),
			Emit.mark("runtime_math_round_floored"),
			Emit.double_difference(Xmm0, Xmm1),
		])
		.concat(RuntimeBuilders.double_items({ to: Xmm2, value: 0.5 }))
		.concat([
			Instruction(Ucomisd({ left: Xmm0, right: Xmm2 })),
			Emit.jcc(B, "runtime_math_round_done"),
		])
		.concat(stepped({ label: "runtime_math_round_done", value: 1.0 }))
	abs = [
		Emit.mark(Runtime.math_routine("abs")),
		Emit.mov(Rax, Rdi),
		Emit.shl(Rax, 1),
		Emit.shr(Rax, 1),
		Emit.ret,
	]
	sqrt = [
		Emit.mark(Runtime.math_routine("sqrt")),
		Emit.to_xmm(Xmm0, Rdi),
		Emit.square_root(Xmm0, Xmm0),
		Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
		Emit.ret,
	]
	# NaN and the zeros are their own signs.
	sign = [
		Emit.mark(Runtime.math_routine("sign")),
		Emit.mov(Rax, Rdi),
		Emit.to_xmm(Xmm0, Rdi),
		Emit.zero(Rcx),
		Emit.to_xmm(Xmm1, Rcx),
		Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
		Emit.jcc(P, "runtime_math_done"),
		Emit.jcc(E, "runtime_math_done"),
		Emit.imm(Rax, RuntimeBuilders.double_bits(1.0)),
		Emit.jcc(A, "runtime_math_done"),
		Emit.imm(Rax, RuntimeBuilders.double_bits(-1.0)),
		Emit.ret,
	]
	# A NaN is the answer; of two equal numbers (+0 and -0 among them) the
	# answer's sign is the two's, and-ed for `max` and or-ed for `min`.
	extreme = |{ name, greater, joined }| {
		label = Runtime.math_routine(name)
		[
			Emit.mark(label),
			Emit.mov(Rax, Rdi),
			Emit.to_xmm(Xmm0, Rdi),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
			Emit.jcc(P, "runtime_math_done"),
			Emit.mov(Rax, Rsi),
			Emit.to_xmm(Xmm1, Rsi),
			Instruction(Ucomisd({ left: Xmm1, right: Xmm1 })),
			Emit.jcc(P, "runtime_math_done"),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(greater, "${label}_first"),
			Emit.jcc(E, "${label}_equal"),
			Emit.ret,
			Emit.mark("${label}_first"),
			Emit.mov(Rax, Rdi),
			Emit.ret,
			Emit.mark("${label}_equal"),
			Emit.mov(Rax, Rdi),
			Instruction(
				Alu({
					operation: joined,
					to: Rax,
					from: Rsi,
				}),
			),
			Emit.ret,
		]
	}
	error_text = [
		Emit.mark("runtime_error_text"),
		Emit.save(Rax),
		Emit.mov(Rdi, Rax),
		Emit.address_of(Rsi, "runtime_text_name"),
		Emit.call("runtime_object_entry"),
		Emit.load(Rdi, Emit.mem(Rax, 0)),
		Emit.call("runtime_text_of"),
		Emit.save(Rax),
		Emit.load(Rdi, Emit.mem(Rsp, 8)),
		Emit.address_of(Rsi, "runtime_text_message"),
		Emit.call("runtime_object_entry"),
		Emit.load(Rdi, Emit.mem(Rax, 0)),
		Emit.call("runtime_text_of"),
		Emit.restore(Rdi),
		Emit.plus_imm(Rsp, 8),
		Emit.load(Rcx, Emit.mem(Rax, 0)),
		Emit.test(Rcx, Rcx),
		Emit.jcc(Ne, "runtime_error_text_message"),
		Emit.mov(Rax, Rdi),
		Emit.ret,
		Emit.mark("runtime_error_text_message"),
		Emit.load(Rcx, Emit.mem(Rdi, 0)),
		Emit.test(Rcx, Rcx),
		Emit.jcc(E, "runtime_math_done"),
		Emit.save(Rax),
		Emit.address_of(Rsi, "runtime_text_colon"),
		Emit.call("runtime_concat"),
		Emit.mov(Rdi, Rax),
		Emit.restore(Rsi),
		Emit.jmp("runtime_concat"),
	]
	text_of_boxed = [Emit.mark(Runtime.text_of_boxed), Emit.call("runtime_text_of")]
		.concat(RuntimeBuilders.boxed_string_items)
		.append(Emit.ret)
	# Its frame: the object (`[rbp - 8]`), the kind (16), the array made
	# (24) and the place (32).
	listing = [
		Emit.mark(Runtime.object_listing),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 32),
	]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.object_tag), Emit.jcc(Ne, "runtime_object_listing_stop")])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rsi),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_object_listing_plain"),
			Emit.load(Rdx, Emit.mem(Rdi, 16)),
			Emit.load(Rdx, Emit.mem(Rdx, 0)),
			Emit.address_of(Rax, RuntimeBuilders.error_mark),
			Emit.cmp(Rdx, Rax),
			Emit.jcc(E, "runtime_object_listing_stop"),
			Emit.address_of(Rax, RuntimeBuilders.instance_mark),
			Emit.cmp(Rdx, Rax),
			Emit.jcc(E, "runtime_instance_listed"),
			Emit.mark("runtime_object_listing_plain"),
			Emit.mov(Rdi, Rcx),
			Emit.call(Runtime.new_array),
			Emit.store(RuntimeBuilders.local(24), Rax),
			Emit.zero(Rax),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.mark("runtime_object_listing_next"),
			Emit.load(Rdi, RuntimeBuilders.local(8)),
			Emit.load(Rcx, RuntimeBuilders.local(32)),
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(E, "runtime_object_listing_done"),
			Emit.shl(Rcx, 4),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.plus(R8, Rcx),
			Emit.load(Rax, Emit.mem(R8, 0)),
		])
		.concat(RuntimeBuilders.boxed_items(Boxing.string_tag))
		.concat([
			Emit.load(Rsi, Emit.mem(R8, 8)),
			Emit.load(Rdx, RuntimeBuilders.local(16)),
			Emit.test(Rdx, Rdx),
			Emit.jcc(E, "runtime_object_listing_item"),
			Emit.mov(Rax, Rsi),
			Emit.cmp_imm(Rdx, 1),
			Emit.jcc(E, "runtime_object_listing_item"),
			Emit.load(Rax, Emit.mem(R8, 0)),
		])
		.concat(RuntimeBuilders.boxed_items(Boxing.string_tag))
		.concat([
			Emit.save(Rsi),
			Emit.save(Rax),
			Emit.imm(Rdi, 2),
			Emit.call(Runtime.new_array),
			Emit.restore(Rcx),
			Emit.store(Emit.mem(Rdx, 0), Rcx),
			Emit.restore(Rcx),
			Emit.store(Emit.mem(Rdx, 8), Rcx),
			Emit.mark("runtime_object_listing_item"),
			Emit.load(Rdi, RuntimeBuilders.local(24)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rcx, RuntimeBuilders.local(32)),
			Emit.store(RuntimeBuilders.listed_item(Rcx), Rax),
			Emit.plus_imm(Rcx, 1),
			Emit.store(RuntimeBuilders.local(32), Rcx),
			Emit.jmp("runtime_object_listing_next"),
			Emit.mark("runtime_object_listing_done"),
			Emit.load(Rax, RuntimeBuilders.local(24)),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
			Emit.mark("runtime_object_listing_stop"),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_object_keys"))
	# The kernel's real-time clock read into 16 bytes at `rsp` (syscall 228,
	# the clock 0), the seconds then the nanoseconds; the milliseconds are
	# whole, as node's, the nanoseconds' part divided down.
	date_now = [
		Emit.mark(Runtime.date_now),
		Emit.minus_imm(Rsp, 16),
		Emit.imm(Rax, 228),
		Emit.zero(Rdi),
		Emit.mov(Rsi, Rsp),
		Emit.syscall,
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_date_now_stop"),
		Emit.load(R8, Emit.mem(Rsp, 0)),
		Emit.imm(Rcx, 1000),
		Instruction(Imul({ to: R8, from: Rcx })),
		Emit.load(Rax, Emit.mem(Rsp, 8)),
		Emit.zero(Rdx),
		Emit.imm(Rcx, 1000000),
		Instruction(Div(Rcx)),
		Emit.plus(Rax, R8),
		Emit.plus_imm(Rsp, 16),
		Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
		Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
		Emit.ret,
		Emit.mark("runtime_date_now_stop"),
	]
		.concat(RuntimeBuilders.stopping_items("runtime_text_clock"))
	[
		signed_zero_items,
		trunc,
		floor,
		ceiling,
		round,
		abs,
		sqrt,
		sign,
		extreme({
			name: "max",
			greater: A,
			joined: And,
		}),
		extreme({
			name: "min",
			greater: B,
			joined: Or,
		}),
		date_now,
		error_text,
		text_of_boxed,
		listing,
	].join()
}

## `runtime_char_code_at` and `runtime_split`, which take their receiver and
## arguments as StringMethods' header says. A place not given is 0; a split
## at nothing is the string in an array of its own, and a split to a limit
## (a second argument) stops. A split's frame holds the string (`[rbp -
## 8]`), the separator (16), the array (24), the piece's start (32) and the
## place (40).
string_method_items : List(Assembly.Statement)
string_method_items = {
	char_code =
		[Emit.mark(Runtime.char_code_at)]
			.concat(RuntimeBuilders.unset_place_items("runtime_char_code_at_placed"))
			.concat(
				RuntimeBuilders.unless_string_items({
					reg: Rdi,
					label: "runtime_index_not_compiled",
				}),
			)
			.concat(
				RuntimeBuilders.unless_number_items({
					reg: Rsi,
					label: "runtime_index_not_compiled",
				}),
			)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.zero(R8),
				Emit.to_xmm(Xmm0, Rsi),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
				Emit.jcc(P, "runtime_char_code_place"),
				Instruction(Cvttsd2si({ to: R8, from: Xmm0 })),
				Emit.mark("runtime_char_code_place"),
				Emit.imm(Rax, 0x7FF8000000000000),
				Emit.load(Rcx, Emit.mem(Rdi, 0)),
				Emit.cmp(R8, Rcx),
				Emit.jcc(Ae, "runtime_char_code_done"),
				RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
				Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
				Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
				Emit.mark("runtime_char_code_done"),
				Emit.ret,
			])
	# The piece of the string from the start to the place, pushed.
	piece = [
		Emit.mark("runtime_split_piece"),
		Emit.load(Rdx, RuntimeBuilders.local(40)),
		Emit.load(Rcx, RuntimeBuilders.local(32)),
		Emit.minus(Rdx, Rcx),
		# A piece of no byte is the empty string and one of one byte its
		# string of the table's: neither takes a block.
		Emit.cmp_imm(Rdx, 1),
		Emit.jcc(A, "runtime_split_piece_made"),
		Emit.address_of(Rax, "runtime_text_empty"),
		Emit.test(Rdx, Rdx),
		Emit.jcc(E, "runtime_split_piece_boxed"),
		Emit.load(Rsi, RuntimeBuilders.local(8)),
		Emit.mov(R8, Rcx),
		RuntimeBuilders.text_byte_item({ reg: Rax, base: Rsi }),
	]
		.concat(RuntimeBuilders.one_byte_text_items)
		.concat([
			Emit.jmp("runtime_split_piece_boxed"),
			Emit.mark("runtime_split_piece_made"),
			Emit.save(Rdx),
			Emit.lea(Rdi, Emit.mem(Rdx, 8)),
			Emit.call(Heap.allocate(String)),
			Emit.restore(Rcx),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.load(Rsi, RuntimeBuilders.local(8)),
			Emit.load(Rdx, RuntimeBuilders.local(32)),
			Emit.plus(Rsi, Rdx),
			Emit.plus_imm(Rsi, 8),
			Instruction(RepMovsb),
			Emit.mark("runtime_split_piece_boxed"),
		])
		.concat(RuntimeBuilders.boxed_string_items)
		.concat([Emit.mov(Rsi, Rax), Emit.load(Rdi, RuntimeBuilders.local(24))])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([Emit.call("runtime_push_item"), Emit.ret])
	split =
		[
			Emit.mark(Runtime.split),
			Emit.cmp_imm(Rcx, 2),
			Emit.jcc(B, "runtime_split_unlimited"),
			Emit.imm(R8, Boxing.undefined_bits),
			Emit.cmp(Rdx, R8),
			Emit.jcc(Ne, "runtime_split_limit_stop"),
			Emit.mark("runtime_split_unlimited"),
			Emit.imm(R8, Boxing.undefined_bits),
			Emit.cmp(Rsi, R8),
			Emit.jcc(Ne, "runtime_split_at"),
			Emit.save(Rdi),
			Emit.imm(Rdi, 1),
			Emit.call(Runtime.new_array),
			Emit.restore(Rcx),
			Emit.store(Emit.mem(Rdx, 0), Rcx),
			Emit.ret,
			Emit.mark("runtime_split_at"),
			Emit.save(Rbp),
			Emit.mov(Rbp, Rsp),
			Emit.minus_imm(Rsp, 48),
		]
			.concat(
				RuntimeBuilders.unless_string_items({
					reg: Rdi,
					label: "runtime_index_not_compiled",
				}),
			)
			.concat(RuntimeBuilders.unless_string_items({ reg: Rsi, label: "runtime_split_stop" }))
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.store(RuntimeBuilders.local(8), Rdi),
				Emit.store(RuntimeBuilders.local(16), Rsi),
				Emit.zero(Rdi),
				Emit.call(Runtime.new_array),
				Emit.store(RuntimeBuilders.local(24), Rax),
				Emit.zero(Rax),
				Emit.store(RuntimeBuilders.local(32), Rax),
				Emit.store(RuntimeBuilders.local(40), Rax),
				Emit.load(Rsi, RuntimeBuilders.local(16)),
				Emit.load(Rcx, Emit.mem(Rsi, 0)),
				Emit.test(Rcx, Rcx),
				Emit.jcc(E, "runtime_split_characters"),
				# A place where the separator's bytes are the string's: the
				# piece before it pushed, the next starting past it.
				Emit.mark("runtime_split_scan"),
				Emit.load(Rdi, RuntimeBuilders.local(8)),
				Emit.load(Rsi, RuntimeBuilders.local(16)),
				Emit.load(R9, RuntimeBuilders.local(40)),
				Emit.load(Rdx, Emit.mem(Rsi, 0)),
				Emit.mov(Rax, R9),
				Emit.plus(Rax, Rdx),
				Emit.load(R10, Emit.mem(Rdi, 0)),
				Emit.cmp(Rax, R10),
				Emit.jcc(A, "runtime_split_last"),
				Emit.zero(Rcx),
				Emit.mark("runtime_split_byte"),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(E, "runtime_split_found"),
				Emit.mov(R8, R9),
				Emit.plus(R8, Rcx),
				RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
				Emit.mov(R8, Rcx),
				RuntimeBuilders.text_byte_item({ reg: R8, base: Rsi }),
				Emit.cmp(Rax, R8),
				Emit.jcc(Ne, "runtime_split_on"),
				Emit.plus_imm(Rcx, 1),
				Emit.jmp("runtime_split_byte"),
				Emit.mark("runtime_split_on"),
				Emit.plus_imm(R9, 1),
				Emit.store(RuntimeBuilders.local(40), R9),
				Emit.jmp("runtime_split_scan"),
				Emit.mark("runtime_split_found"),
				Emit.call("runtime_split_piece"),
				Emit.load(Rax, RuntimeBuilders.local(40)),
				Emit.load(Rsi, RuntimeBuilders.local(16)),
				Emit.load(Rcx, Emit.mem(Rsi, 0)),
				Emit.plus(Rax, Rcx),
				Emit.store(RuntimeBuilders.local(40), Rax),
				Emit.store(RuntimeBuilders.local(32), Rax),
				Emit.jmp("runtime_split_scan"),
				Emit.mark("runtime_split_last"),
				Emit.load(Rax, Emit.mem(Rdi, 0)),
				Emit.store(RuntimeBuilders.local(40), Rax),
				Emit.call("runtime_split_piece"),
				Emit.jmp("runtime_split_done"),
				# Each character a piece of its own.
				Emit.mark("runtime_split_characters"),
				Emit.load(Rdi, RuntimeBuilders.local(8)),
				Emit.load(Rax, RuntimeBuilders.local(40)),
				Emit.load(Rcx, Emit.mem(Rdi, 0)),
				Emit.cmp(Rax, Rcx),
				Emit.jcc(E, "runtime_split_done"),
				Emit.store(RuntimeBuilders.local(32), Rax),
				Emit.plus_imm(Rax, 1),
				Emit.store(RuntimeBuilders.local(40), Rax),
				Emit.call("runtime_split_piece"),
				Emit.jmp("runtime_split_characters"),
				Emit.mark("runtime_split_done"),
				Emit.load(Rax, RuntimeBuilders.local(24)),
				Emit.mov(Rsp, Rbp),
				Emit.restore(Rbp),
				Emit.ret,
				Emit.mark("runtime_split_stop"),
			])
			.concat(RuntimeBuilders.stopping_items("runtime_text_split_separator"))
			.append(Emit.mark("runtime_split_limit_stop"))
			.concat(RuntimeBuilders.stopping_items("runtime_text_split_limit"))
	[char_code, piece, split].join()
}

## `runtime_call_spread`, `runtime_log_spread`, `runtime_extreme_of`,
## `runtime_spread_fields` and `runtime_properties_left`. Each walk's frame
## holds its list (`[rbp - 8]`), what it makes or its kind (16), the place
## (24) and, for a rest, the keys left out (32).
spread_items : List(Assembly.Statement)
spread_items = {
	framed = |{ label, size }| [
		Emit.mark(label),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, size),
	]
	leave = [
		Emit.mov(Rsp, Rbp),
		Emit.restore(Rbp),
		Emit.ret,
	]
	# The walk's next item in `rax`, `label` taken past the last.
	next_item = |label| [
		Emit.load(Rdi, RuntimeBuilders.local(8)),
		Emit.load(Rcx, RuntimeBuilders.local(24)),
		Emit.load(Rdx, Emit.mem(Rdi, 0)),
		Emit.cmp(Rcx, Rdx),
		Emit.jcc(Ae, label),
		Emit.load(R8, Emit.mem(Rdi, 16)),
		Emit.load(Rax, RuntimeBuilders.listed_item(Rcx)),
		Emit.plus_imm(Rcx, 1),
		Emit.store(RuntimeBuilders.local(24), Rcx),
	]
	# The items pushed, the last first, as a call through a value takes them,
	# and `rdx`, the receiver or `undefined`, kept below them for the call.
	call_spread =
		[
			Emit.mark(Runtime.call_spread),
			Emit.mov(Rax, Rdi),
			Emit.call(Runtime.check_function),
		]
			.concat(RuntimeBuilders.tag_load_items(Rsi))
			.concat([Emit.cmp_imm(Rcx, Boxing.array_tag), Emit.jcc(Ne, "runtime_not_an_array")])
			.concat([
				Emit.save(Rbp),
				Emit.mov(Rbp, Rsp),
				Emit.save(Rdx),
			])
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.load(Rcx, Emit.mem(Rsi, 0)),
				Emit.load(R8, Emit.mem(Rsi, 16)),
				Emit.mov(Rdx, Rcx),
				Emit.mark("runtime_call_spread_push"),
				Emit.test(Rdx, Rdx),
				Emit.jcc(E, "runtime_call_spread_pushed"),
				Emit.minus_imm(Rdx, 1),
				Emit.load(Rax, RuntimeBuilders.listed_item(Rdx)),
				Emit.save(Rax),
				Emit.jmp("runtime_call_spread_push"),
				Emit.mark("runtime_call_spread_pushed"),
				Emit.mov(Rbx, Rdi),
			])
			.concat(RuntimeBuilders.unboxed_items(Rbx))
			.concat([
				Emit.load(Rax, Emit.mem(Rbx, 0)),
				Emit.plus(Rax, Rbx),
				Emit.load(Rdx, Emit.mem(Rbp, -8)),
				Instruction(CallReg(Rax)),
			])
			.concat(leave)
	log_spread =
		framed({ label: Runtime.log_spread, size: 32 })
			.concat(RuntimeBuilders.array_check_items)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.store(RuntimeBuilders.local(8), Rdi),
				Emit.zero(Rax),
				Emit.store(RuntimeBuilders.local(24), Rax),
				Emit.mark("runtime_log_spread_next"),
			])
			.concat(next_item("runtime_log_spread_done"))
			.concat([
				Emit.store(RuntimeBuilders.local(16), Rax),
				Emit.cmp_imm(Rcx, 1),
				Emit.jcc(E, "runtime_log_spread_first"),
			])
			.concat(Runtime.text_items(Space))
			.concat([
				Emit.mark("runtime_log_spread_first"),
				Emit.load(Rdi, RuntimeBuilders.local(16)),
				Emit.call(Runtime.write_value),
				Emit.jmp("runtime_log_spread_next"),
				Emit.mark("runtime_log_spread_done"),
			])
			.concat(Runtime.text_items(Newline))
			.concat(leave)
	extreme_of =
		framed({ label: Runtime.extreme_of, size: 32 })
			.concat(RuntimeBuilders.array_check_items)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.store(RuntimeBuilders.local(8), Rdi),
				Emit.store(RuntimeBuilders.local(32), Rsi),
				Emit.zero(Rax),
				Emit.store(RuntimeBuilders.local(24), Rax),
				Emit.imm(Rax, 0x7FF0000000000000),
				Emit.test(Rsi, Rsi),
				Emit.jcc(Ne, "runtime_extreme_of_started"),
				Emit.imm(Rax, (0xFFF0000000000000).to_i64_wrap()),
				Emit.mark("runtime_extreme_of_started"),
				Emit.store(RuntimeBuilders.local(16), Rax),
				Emit.mark("runtime_extreme_of_next"),
			])
			.concat(next_item("runtime_extreme_of_done"))
			.concat([
				Emit.call(Runtime.check_number),
				Emit.mov(Rsi, Rax),
				Emit.load(Rdi, RuntimeBuilders.local(16)),
				Emit.load(Rax, RuntimeBuilders.local(32)),
				Emit.test(Rax, Rax),
				Emit.jcc(Ne, "runtime_extreme_of_min"),
				Emit.call(Runtime.math_routine("max")),
				Emit.jmp("runtime_extreme_of_kept"),
				Emit.mark("runtime_extreme_of_min"),
				Emit.call(Runtime.math_routine("min")),
				Emit.mark("runtime_extreme_of_kept"),
				Emit.store(RuntimeBuilders.local(16), Rax),
				Emit.jmp("runtime_extreme_of_next"),
				Emit.mark("runtime_extreme_of_done"),
				Emit.load(Rax, RuntimeBuilders.local(16)),
			])
			.concat(leave)
	# An object's entries are copied below; an array or a string goes to
	# `${label}_listed`, boxed; anything else has no properties.
	keyed = |label|
		RuntimeBuilders.tag_load_items(Rsi)
			.concat([
				Emit.cmp_imm(Rcx, Boxing.object_tag),
				Emit.jcc(E, "${label}_object"),
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(E, "${label}_listed"),
				Emit.cmp_imm(Rcx, Boxing.string_tag),
				Emit.jcc(E, "${label}_listed"),
				Emit.jmp("${label}_done"),
				Emit.mark("${label}_object"),
			])
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat(RuntimeBuilders.not_an_error_items("${label}_plain"))
	# An array's items, or a string's characters, set on the object at
	# [rbp - 16] under their places' texts: `{ ...[10, 20] }` is
	# `{ '0': 10, '1': 20 }`.
	listed_fields =
		[Emit.mark("runtime_spread_fields_listed")]
			.concat(RuntimeBuilders.tag_load_items(Rsi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(E, "runtime_spread_fields_array"),
				Emit.mov(Rdi, Rsi),
				Emit.call(Runtime.items_of),
				Emit.mov(Rsi, Rax),
				Emit.mark("runtime_spread_fields_array"),
			])
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.store(RuntimeBuilders.local(8), Rsi),
				Emit.zero(Rax),
				Emit.store(RuntimeBuilders.local(24), Rax),
				Emit.mark("runtime_spread_fields_item"),
				Emit.load(Rdi, RuntimeBuilders.local(8)),
				Emit.load(Rcx, RuntimeBuilders.local(24)),
				Emit.load(Rdx, Emit.mem(Rdi, 0)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, "runtime_spread_fields_done"),
				Emit.load(R8, Emit.mem(Rdi, 16)),
				Emit.load(Rax, RuntimeBuilders.listed_item(Rcx)),
				Emit.store(RuntimeBuilders.local(32), Rax),
				Instruction(Cvtsi2sd({ to: Xmm0, from: Rcx })),
				Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
				Emit.call(Runtime.number_text),
				Emit.mov(Rsi, Rax),
				Emit.load(Rdi, RuntimeBuilders.local(16)),
				Emit.load(Rdx, RuntimeBuilders.local(32)),
				Emit.call(Runtime.set_property),
				Emit.load(Rcx, RuntimeBuilders.local(24)),
				Emit.plus_imm(Rcx, 1),
				Emit.store(RuntimeBuilders.local(24), Rcx),
				Emit.jmp("runtime_spread_fields_item"),
			])
	# Each entry of the object at [rbp - 8] whose key isn't left out, set
	# on the object at [rbp - 16].
	copied = |label|
		[
			Emit.zero(Rax),
			Emit.store(RuntimeBuilders.local(24), Rax),
			Emit.mark("${label}_next"),
			Emit.load(Rdi, RuntimeBuilders.local(8)),
			Emit.load(Rcx, RuntimeBuilders.local(24)),
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(Ae, "${label}_done"),
			Emit.plus_imm(Rcx, 1),
			Emit.store(RuntimeBuilders.local(24), Rcx),
			Emit.minus_imm(Rcx, 1),
			Emit.shl(Rcx, 4),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.plus(R8, Rcx),
			Emit.load(Rsi, Emit.mem(R8, 0)),
			Emit.load(Rdx, Emit.mem(R8, 8)),
			Emit.load(R9, RuntimeBuilders.local(32)),
			Emit.zero(R11),
			Emit.mark("${label}_key"),
			Emit.load(R10, Emit.mem(R9, 0)),
			Emit.cmp(R11, R10),
			Emit.jcc(E, "${label}_kept"),
			Emit.load(R8, Emit.mem(R9, 16)),
			Emit.load(Rdi, RuntimeBuilders.listed_item(R11)),
		]
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.save(Rdx),
				Emit.save(R9),
				Emit.save(R11),
				Emit.save(Rsi),
				Emit.call("runtime_text_equal"),
				Emit.restore(Rsi),
				Emit.restore(R11),
				Emit.restore(R9),
				Emit.restore(Rdx),
				Emit.test(Rax, Rax),
				Emit.jcc(Ne, "${label}_next"),
				Emit.plus_imm(R11, 1),
				Emit.jmp("${label}_key"),
				Emit.mark("${label}_kept"),
				Emit.load(Rdi, RuntimeBuilders.local(16)),
				Emit.call(Runtime.set_property),
				Emit.jmp("${label}_next"),
			])
	spread_fields =
		framed({ label: Runtime.spread_fields, size: 32 })
			.concat([Emit.store(RuntimeBuilders.local(16), Rdi)])
			.concat(keyed("runtime_spread_fields"))
			.concat([
				Emit.store(RuntimeBuilders.local(8), Rsi),
				# No key is left out: an empty list of them.
				Emit.zero(Rdi),
				Emit.call(Runtime.new_array),
			])
			.concat(RuntimeBuilders.unboxed_items(Rax))
			.append(Emit.store(RuntimeBuilders.local(32), Rax))
			.concat(copied("runtime_spread_fields_copy"))
			.concat([
				Emit.mark("runtime_spread_fields_done"),
				Emit.mark("runtime_spread_fields_copy_done"),
			])
			.concat(leave)
			.concat(listed_fields)
	left =
		framed({ label: Runtime.properties_left, size: 32 })
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.store(RuntimeBuilders.local(32), Rsi),
				Emit.mov(Rsi, Rdi),
				Emit.call(Runtime.new_object),
				Emit.store(RuntimeBuilders.local(16), Rax),
				Emit.mov(Rdi, Rax),
			])
			.concat(keyed("runtime_properties_left"))
			.concat([Emit.store(RuntimeBuilders.local(8), Rsi)])
			.concat(copied("runtime_properties_left_copy"))
			.concat([
				Emit.mark("runtime_properties_left_done"),
				Emit.mark("runtime_properties_left_copy_done"),
				Emit.load(Rax, RuntimeBuilders.local(16)),
			])
			.concat(leave)
			.append(Emit.mark("runtime_properties_left_listed"))
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.load(Rcx, Emit.mem(Rsi, 0)),
				Emit.test(Rcx, Rcx),
				Emit.jcc(E, "runtime_properties_left_done"),
			])
			.concat(RuntimeBuilders.stopping_items("runtime_text_rest_listed"))
			.append(Emit.mark("runtime_spread_error"))
			.concat(RuntimeBuilders.stopping_items("runtime_text_spread_error"))
	[call_spread, log_spread, extreme_of, spread_fields, left].join()
}

## `runtime_throw`, `runtime_new_error` and `runtime_error_message`. A
## handler's record is three values on the machine's stack, from its
## address up: the handler before it, the frame's `rbp`, and the code the
## throw enters.
exception_items : List(Assembly.Statement)
exception_items = {
	throw = [
		Emit.mark(Runtime.throw),
		Emit.load(Rcx, Runtime.handler_place),
		Emit.test(Rcx, Rcx),
		Emit.jcc(E, "runtime_uncaught"),
		Emit.mov(Rsp, Rcx),
		Emit.restore(Rdx),
		Emit.store(Runtime.handler_place, Rdx),
		Emit.restore(Rbp),
		Emit.ret,
		Emit.mark("runtime_uncaught"),
	]
		.concat(RuntimeBuilders.stopping_items("runtime_text_uncaught"))
		.append(Emit.mark("runtime_inspect_error"))
		.concat(RuntimeBuilders.stopping_items("runtime_text_error_written"))
		.append(Emit.mark("runtime_inspect_instance"))
		.concat(RuntimeBuilders.stopping_items("runtime_text_instance_written"))
		.append(Emit.mark("runtime_instance_listed"))
		.concat(RuntimeBuilders.stopping_items("runtime_text_instance_listed"))
	# `value instanceof C`: true when the value (`rdi`) is an instance whose
	# keys hold C's (`rsi`, the text `NewInstance` sets for each class).
	marked = "runtime_instance_of_marked"
	instance_of = [Emit.mark(Runtime.instance_of)]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.object_tag), Emit.jcc(Ne, "runtime_instance_of_false")])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat(RuntimeBuilders.instance_jump_items(marked))
		.concat([
			Emit.jmp("runtime_instance_of_false"),
			Emit.mark(marked),
			Emit.call("runtime_object_entry"),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_instance_of_false"),
			Emit.imm(Rax, Boxing.true_bits),
			Emit.ret,
			Emit.mark("runtime_instance_of_false"),
			Emit.imm(Rax, Boxing.false_bits),
			Emit.ret,
		])
	property = |{ key, value }| [
		Emit.load(Rdi, Emit.mem(Rsp, 0)),
		Emit.address_of(Rsi, key),
		Emit.load(Rdx, value),
		Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)),
		Emit.plus(Rdx, Rcx),
		Emit.call(Runtime.set_property),
	]
	new_error =
		[
			Emit.mark(Runtime.new_error),
			Emit.save(Rsi),
			Emit.save(Rdi),
			Emit.call(Runtime.new_object),
			Emit.save(Rax),
			Emit.mov(Rdi, Rax),
			Emit.address_of(Rsi, RuntimeBuilders.error_mark),
			Emit.imm(Rdx, Boxing.true_bits),
			Emit.call(Runtime.set_property),
		]
			.concat(property({ key: "runtime_text_name", value: Emit.mem(Rsp, 8) }))
			.concat(property({ key: "runtime_text_message", value: Emit.mem(Rsp, 16) }))
			.concat([
				Emit.restore(Rax),
				Emit.plus_imm(Rsp, 16),
				Emit.ret,
			])
	# node's TypeError for a property of `undefined` or `null` (`rdi`) read
	# (`rdx` 0) or written (1), the key's text at `rsi`: `Cannot read
	# properties of null (reading 'x')`. The frame holds the value (8), the
	# key (16) and which (24).
	property_error = [
		Emit.mark("runtime_property_error"),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 32),
		Emit.store(Emit.mem(Rbp, -8), Rdi),
		Emit.store(Emit.mem(Rbp, -16), Rsi),
		Emit.store(Emit.mem(Rbp, -24), Rdx),
		Emit.address_of(Rdi, "runtime_text_cannot_read"),
		Emit.test(Rdx, Rdx),
		Emit.jcc(E, "runtime_property_error_verb"),
		Emit.address_of(Rdi, "runtime_text_cannot_set"),
		Emit.mark("runtime_property_error_verb"),
		Emit.address_of(Rsi, "runtime_text_undefined"),
		Emit.load(Rax, Emit.mem(Rbp, -8)),
		Emit.imm(Rcx, Boxing.null_bits),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Ne, "runtime_property_error_value"),
		Emit.address_of(Rsi, "runtime_text_null"),
		Emit.mark("runtime_property_error_value"),
		Emit.call("runtime_concat"),
		Emit.mov(Rdi, Rax),
		Emit.address_of(Rsi, "runtime_text_reading"),
		Emit.load(Rdx, Emit.mem(Rbp, -24)),
		Emit.test(Rdx, Rdx),
		Emit.jcc(E, "runtime_property_error_participle"),
		Emit.address_of(Rsi, "runtime_text_setting"),
		Emit.mark("runtime_property_error_participle"),
		Emit.call("runtime_concat"),
		Emit.mov(Rdi, Rax),
		Emit.load(Rsi, Emit.mem(Rbp, -16)),
		Emit.call("runtime_concat"),
		Emit.mov(Rdi, Rax),
		Emit.address_of(Rsi, "runtime_text_quote_closed"),
		Emit.call("runtime_concat"),
		Emit.mov(Rsi, Rax),
		Emit.address_of(Rdi, Runtime.error_name_label("TypeError")),
		Emit.call(Runtime.new_error),
		Emit.jmp(Runtime.throw),
	]
	message = [
		Emit.mark(Runtime.error_message),
		Emit.imm(Rcx, Boxing.undefined_bits),
		Emit.cmp(Rdi, Rcx),
		Emit.jcc(Ne, "runtime_text_of"),
		Emit.address_of(Rax, "runtime_text_empty"),
		Emit.ret,
	]
	[throw, new_error, property_error, message, instance_of].join()
}
