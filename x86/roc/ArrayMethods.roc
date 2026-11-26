## This module holds the array methods' routines: the callbacks
## (`runtime_call_back`, the walk behind `map`, `filter` and `forEach`, and
## `reduce`), `join`, `slice` and `charAt`, the searches (`find`, `some`,
## `every`, `indexOf`, `concat`, `reverse`), `sort`, and the edits
## (`splice`, `lastIndexOf`, `String.fromCharCode`, `Array.from`).
##
## It stands apart from Runtime, its one caller being `RuntimeCode`,
## because its routines call Runtime's names, so it imports Runtime; Roc
## forbids an import cycle, so Runtime cannot list it in its own routines,
## and `RuntimeCode` puts the two together.
import Assembly
import Boxing
import Emit
import Runtime
import RuntimeBuilders

ArrayMethods :: [].{

	## Every array method's routine, in the order `RuntimeCode` lays them
	## down: the callbacks, join and slice, the searches, sort, the edits.
	items : List(Assembly.Statement)
	items = [callback_items, slice_items, search_items, sort_items, edit_items].join()
}

## `runtime_call_back`, which calls the function `rdi` through its value
## with the item `rsi`, its place `rdx` (a whole number) and the array `rcx`,
## its result in `rax`, as `map`, `filter` and `forEach` call theirs; then
## those three, one walk (`runtime_walk`, its kind in `rdx`: 0 `map`, 1
## `filter`, 2 `forEach`), and `reduce`. A walk's frame holds the array
## (`[rbp - 8]`), the function (16), the kind (24), the place (32), the new
## array (40) and the item (48); a function called may change every
## register but `rbp`, `rsp` and `r12` to `r15`.
callback_items : List(Assembly.Statement)
callback_items = {
	call_back = [
		Emit.mark("runtime_call_back"),
		Emit.save(Rcx),
		Instruction(Cvtsi2sd({ to: Xmm0, from: Rdx })),
		Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
		Emit.save(Rax),
		Emit.save(Rsi),
		Emit.mov(Rbx, Rdi),
	]
		.concat(RuntimeBuilders.unboxed_items(Rbx))
		.concat([
			Emit.load(Rax, Emit.mem(Rbx, 0)),
			Emit.plus(Rax, Rbx),
			Emit.imm(Rcx, 3),
			Instruction(CallReg(Rax)),
			Emit.plus_imm(Rsp, 24),
			Emit.ret,
		])
	kinds = [
		Emit.mark(Runtime.map),
		Emit.zero(Rdx),
		Emit.jmp("runtime_walk"),
		Emit.mark(Runtime.filter),
		Emit.imm(Rdx, 1),
		Emit.jmp("runtime_walk"),
		Emit.mark(Runtime.for_each),
		Emit.mov(Rcx, Rdi),
		Emit.shr(Rcx, Boxing.tag_shift),
		Emit.cmp_imm(Rcx, Boxing.collection_tag),
		Emit.jcc(E, "runtime_collection_for_each"),
		Emit.imm(Rdx, 2),
	]
	start = [
		Emit.mark("runtime_walk"),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 48),
	]
		.concat(RuntimeBuilders.array_check_items)
		.concat([Emit.mov(Rax, Rsi), Emit.call(Runtime.check_function)])
		.concat([
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rsi),
			Emit.store(RuntimeBuilders.local(24), Rdx),
			Emit.zero(Rax),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.zero(Rcx),
			Emit.test(Rdx, Rdx),
			Emit.jcc(Ne, "runtime_walk_sized"),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.mark("runtime_walk_sized"),
			Emit.mov(Rdi, Rcx),
			Emit.call(Runtime.new_array),
			Emit.store(RuntimeBuilders.local(40), Rax),
		])
	walk = [Emit.mark("runtime_walk_next"), Emit.load(Rdi, RuntimeBuilders.local(8))]
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(Rdx, RuntimeBuilders.local(32)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_walk_done"),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rsi, RuntimeBuilders.listed_item(Rdx)),
			Emit.store(RuntimeBuilders.local(48), Rsi),
			Emit.load(Rdi, RuntimeBuilders.local(16)),
			Emit.load(Rcx, RuntimeBuilders.local(8)),
			Emit.call("runtime_call_back"),
			Emit.load(Rdx, RuntimeBuilders.local(24)),
			Emit.test(Rdx, Rdx),
			Emit.jcc(Ne, "runtime_walk_kept"),
			Emit.load(Rdi, RuntimeBuilders.local(40)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rdx, RuntimeBuilders.local(32)),
			Emit.store(RuntimeBuilders.listed_item(Rdx), Rax),
			Emit.jmp("runtime_walk_stepped"),
			Emit.mark("runtime_walk_kept"),
			Emit.cmp_imm(Rdx, 1),
			Emit.jcc(Ne, "runtime_walk_stepped"),
			Emit.mov(Rdi, Rax),
			Emit.call(Runtime.truthy),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_walk_stepped"),
			Emit.load(Rdi, RuntimeBuilders.local(40)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rsi, RuntimeBuilders.local(48)),
			Emit.call("runtime_push_item"),
			Emit.mark("runtime_walk_stepped"),
			Emit.load(Rax, RuntimeBuilders.local(32)),
			Emit.plus_imm(Rax, 1),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.jmp("runtime_walk_next"),
			Emit.mark("runtime_walk_done"),
			Emit.load(Rax, RuntimeBuilders.local(40)),
			Emit.load(Rdx, RuntimeBuilders.local(24)),
			Emit.cmp_imm(Rdx, 2),
			Emit.jcc(Ne, "runtime_walk_return"),
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.mark("runtime_walk_return"),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
		])
	# reduce's frame: the array (8), the function (16), the value so far
	# (24) and the place (32).
	reduce = [
		Emit.mark(Runtime.reduce),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 32),
		Emit.mov(R11, Rcx),
	]
		.concat(RuntimeBuilders.array_check_items)
		.concat([
			Emit.mov(Rax, Rsi),
			Emit.call(Runtime.check_function),
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rsi),
			Emit.store(RuntimeBuilders.local(24), Rdx),
			Emit.zero(Rax),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.cmp_imm(R11, 2),
			Emit.jcc(E, "runtime_reduce_next"),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_reduce_empty"),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rax, Emit.mem(R8, 0)),
			Emit.store(RuntimeBuilders.local(24), Rax),
			Emit.imm(Rax, 1),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.mark("runtime_reduce_next"),
			Emit.load(Rdi, RuntimeBuilders.local(8)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(Rdx, RuntimeBuilders.local(32)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_reduce_done"),
			Emit.load(Rax, RuntimeBuilders.local(8)),
			Emit.save(Rax),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rdx })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.save(Rax),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rax, RuntimeBuilders.listed_item(Rdx)),
			Emit.save(Rax),
			Emit.load(Rax, RuntimeBuilders.local(24)),
			Emit.save(Rax),
			Emit.load(Rbx, RuntimeBuilders.local(16)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rbx))
		.concat([
			Emit.load(Rax, Emit.mem(Rbx, 0)),
			Emit.plus(Rax, Rbx),
			Emit.imm(Rcx, 4),
			Instruction(CallReg(Rax)),
			Emit.plus_imm(Rsp, 32),
			Emit.store(RuntimeBuilders.local(24), Rax),
			Emit.load(Rax, RuntimeBuilders.local(32)),
			Emit.plus_imm(Rax, 1),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.jmp("runtime_reduce_next"),
			Emit.mark("runtime_reduce_done"),
			Emit.load(Rax, RuntimeBuilders.local(24)),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
			Emit.mark("runtime_reduce_empty"),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_empty_reduce"))
	[call_back, kinds, start, walk, reduce].join()
}

## `runtime_join`, `runtime_slice` and `runtime_char_at`. join takes two
## passes, so its time and its memory are linear in the text it makes: the
## first keeps each item's text (the empty text for `undefined` and `null`)
## in a list of its own and sums their lengths with the separators'; the
## second copies them into the one string it allocates. Its frame holds the
## array, unboxed (`[rbp - 8]`), the separator (16), the texts (24), the
## place (32), the length so far (40) and the string made (48).
slice_items : List(Assembly.Statement)
slice_items = {
	# The text at `[rsi]`'s bytes copied to `rdi`, which ends past them. It
	# changes `rcx` and `rsi`.
	copied = |text| [
		Emit.load(Rcx, Emit.mem(text, 0)),
		Emit.lea(Rsi, Emit.mem(text, 8)),
		Instruction(RepMovsb),
	]
	join = [
		Emit.mark(Runtime.join),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 48),
	]
		.concat(RuntimeBuilders.array_check_items)
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rsi),
			Emit.load(Rdi, Emit.mem(Rdi, 0)),
			Emit.test(Rdi, Rdi),
			Emit.jcc(E, "runtime_join_empty"),
			Emit.shl(Rdi, 3),
			Emit.call(Runtime.allocate),
			Emit.store(RuntimeBuilders.local(24), Rax),
			Emit.zero(Rax),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.store(RuntimeBuilders.local(40), Rax),
			# The first pass: each item's text kept, its length counted.
			Emit.mark("runtime_join_next"),
			Emit.load(Rdi, RuntimeBuilders.local(8)),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(Rdx, RuntimeBuilders.local(32)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_join_counted"),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rdi, RuntimeBuilders.listed_item(Rdx)),
			Emit.address_of(Rax, "runtime_text_empty"),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rdi, Rcx),
			Emit.jcc(E, "runtime_join_item"),
			Emit.imm(Rcx, Boxing.null_bits),
			Emit.cmp(Rdi, Rcx),
			Emit.jcc(E, "runtime_join_item"),
			Emit.call("runtime_text_of"),
			Emit.mark("runtime_join_item"),
			Emit.load(R8, RuntimeBuilders.local(24)),
			Emit.load(Rdx, RuntimeBuilders.local(32)),
			Emit.store(RuntimeBuilders.listed_item(Rdx), Rax),
			Emit.load(R9, RuntimeBuilders.local(40)),
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.plus(R9, Rcx),
			Emit.test(Rdx, Rdx),
			Emit.jcc(E, "runtime_join_stepped"),
			Emit.load(Rsi, RuntimeBuilders.local(16)),
			Emit.load(Rcx, Emit.mem(Rsi, 0)),
			Emit.plus(R9, Rcx),
			Emit.mark("runtime_join_stepped"),
			Emit.store(RuntimeBuilders.local(40), R9),
			Emit.plus_imm(Rdx, 1),
			Emit.store(RuntimeBuilders.local(32), Rdx),
			Emit.jmp("runtime_join_next"),
			# The second pass: the string allocated once and the texts
			# copied in, the separator between them. The array's length in
			# `r9`, the place in `r10`, the separator in `r11`.
			Emit.mark("runtime_join_counted"),
			Emit.load(Rdi, RuntimeBuilders.local(40)),
			Emit.plus_imm(Rdi, 8),
			Emit.call(Runtime.allocate),
			Emit.store(RuntimeBuilders.local(48), Rax),
			Emit.load(Rcx, RuntimeBuilders.local(40)),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.load(R8, RuntimeBuilders.local(24)),
			Emit.load(R9, RuntimeBuilders.local(8)),
			Emit.load(R9, Emit.mem(R9, 0)),
			Emit.zero(R10),
			Emit.load(R11, RuntimeBuilders.local(16)),
			Emit.mark("runtime_join_copy"),
			Emit.cmp(R10, R9),
			Emit.jcc(Ae, "runtime_join_copied"),
			Emit.test(R10, R10),
			Emit.jcc(E, "runtime_join_piece"),
		])
		.concat(copied(R11))
		.concat([Emit.mark("runtime_join_piece"), Emit.load(Rdx, RuntimeBuilders.listed_item(R10))])
		.concat(copied(Rdx))
		.concat([
			Emit.plus_imm(R10, 1),
			Emit.jmp("runtime_join_copy"),
			Emit.mark("runtime_join_copied"),
			Emit.load(Rax, RuntimeBuilders.local(48)),
			Emit.jmp("runtime_join_done"),
			Emit.mark("runtime_join_empty"),
			Emit.address_of(Rax, "runtime_text_empty"),
			Emit.mark("runtime_join_done"),
		])
		.concat(RuntimeBuilders.boxed_string_items)
		.concat([
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
		])
	# A place given as a number, made a whole one counted from the start:
	# from the end when negative, then held between 0 and the length (r9).
	place = |{ reg, label }|
		RuntimeBuilders.unless_number_items({ reg, label: "runtime_slice_not_a_number" })
			.concat([
				Emit.to_xmm(Xmm0, reg),
				Instruction(Cvttsd2si({ to: reg, from: Xmm0 })),
				Emit.cmp_imm(reg, 0),
				Emit.jcc(Ge, "${label}_counted"),
				Emit.plus(reg, R9),
				Emit.cmp_imm(reg, 0),
				Emit.jcc(Ge, "${label}_counted"),
				Emit.zero(reg),
				Emit.mark("${label}_counted"),
				Emit.cmp(reg, R9),
				Emit.jcc(Le, "${label}_held"),
				Emit.mov(reg, R9),
				Emit.mark("${label}_held"),
			])
	# r11: how many places were given; r10: the array; r9: its length;
	# rsi: the start; rdx: the end.
	# r8: 1 for a string, whose bytes are sliced, 0 for an array.
	slice = [
		Emit.mark(Runtime.slice),
		Emit.mov(R11, Rcx),
		Emit.zero(R8),
	]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(Ne, "runtime_slice_array"),
			Emit.imm(R8, 1),
			Emit.jmp("runtime_slice_listed"),
			Emit.mark("runtime_slice_array"),
		])
		.concat(RuntimeBuilders.array_check_items)
		.concat([Emit.mark("runtime_slice_listed")])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.mov(R10, Rdi),
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.test(R11, R11),
			Emit.jcc(Ne, "runtime_slice_start"),
			Emit.zero(Rsi),
			Emit.jmp("runtime_slice_started"),
			Emit.mark("runtime_slice_start"),
		])
		.concat(place({ reg: Rsi, label: "runtime_slice_start" }))
		.concat([
			Emit.mark("runtime_slice_started"),
			Emit.cmp_imm(R11, 2),
			Emit.jcc(E, "runtime_slice_end"),
			Emit.mov(Rdx, R9),
			Emit.jmp("runtime_slice_ended"),
			Emit.mark("runtime_slice_end"),
		])
		.concat(place({ reg: Rdx, label: "runtime_slice_end" }))
		.concat([
			Emit.mark("runtime_slice_ended"),
			Emit.minus(Rdx, Rsi),
			Emit.cmp_imm(Rdx, 0),
			Emit.jcc(Ge, "runtime_slice_counted"),
			Emit.zero(Rdx),
			Emit.mark("runtime_slice_counted"),
			Emit.test(R8, R8),
			Emit.jcc(Ne, "runtime_slice_string"),
			Emit.save(R10),
			Emit.save(Rsi),
			Emit.save(Rdx),
			Emit.mov(Rdi, Rdx),
			Emit.call(Runtime.new_array),
			Emit.mov(Rdi, Rdx),
			Emit.restore(Rcx),
			Emit.restore(Rsi),
			Emit.restore(R10),
			Emit.load(R8, Emit.mem(R10, 16)),
			Emit.lea(Rsi, RuntimeBuilders.listed_item(Rsi)),
			Emit.shl(Rcx, 3),
			Instruction(RepMovsb),
			Emit.ret,
			Emit.mark("runtime_slice_string"),
			Emit.save(R10),
			Emit.save(Rsi),
			Emit.save(Rdx),
			Emit.lea(Rdi, Emit.mem(Rdx, 8)),
			Emit.call(Runtime.allocate),
			Emit.restore(Rcx),
			Emit.restore(Rsi),
			Emit.restore(R10),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.lea(
				Rsi,
				Emit.mem_index({
					base: R10,
					index: Rsi,
					displacement: 8,
				}),
			),
			Instruction(RepMovsb),
		])
		.concat(RuntimeBuilders.boxed_string_items)
		.concat([Emit.ret, Emit.mark("runtime_slice_not_a_number")])
		.concat(RuntimeBuilders.stopping_items("runtime_text_slice_place"))
	char_at = [Emit.mark(Runtime.char_at)]
		.concat(
			RuntimeBuilders.unless_string_items({ reg: Rdi, label: "runtime_index_not_compiled" }),
		)
		.concat([
			Emit.call(Runtime.get_index),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ne, "runtime_char_at_found"),
			Emit.address_of(Rax, "runtime_text_empty"),
		])
		.concat(RuntimeBuilders.boxed_string_items)
		.concat([Emit.mark("runtime_char_at_found"), Emit.ret])
	[join, slice, char_at].join()
}

## `runtime_search`, `runtime_index_of`, `runtime_concat_item` and
## `runtime_reverse`. A search's frame holds the array (`[rbp - 8]`), the
## function (16), the kind (24), the place (32), the length it started with
## (40) and the item (48): `find` and `findIndex` go on to that length,
## reading `undefined` past the end, while `some` and `every` stop at the end.
search_items : List(Assembly.Statement)
search_items = {
	answers = |{ label, values }|
		values
			.map_with_index(
				|value, kind| [
					Emit.cmp_imm(Rdx, kind.to_i64_wrap()),
					Emit.jcc(Ne, "${label}_not_${kind.to_str()}"),
					Emit.imm(Rax, value),
					Emit.jmp("runtime_search_leave"),
					Emit.mark("${label}_not_${kind.to_str()}"),
				],
			)
			.join()
	search = [
		Emit.mark(Runtime.search),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 48),
	]
		.concat(RuntimeBuilders.array_check_items)
		.concat([
			Emit.mov(Rax, Rsi),
			Emit.call(Runtime.check_function),
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rsi),
			Emit.store(RuntimeBuilders.local(24), Rdx),
			Emit.zero(Rax),
			Emit.store(RuntimeBuilders.local(32), Rax),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.store(RuntimeBuilders.local(40), Rcx),
			Emit.mark("runtime_search_next"),
			Emit.load(Rdx, RuntimeBuilders.local(32)),
			Emit.load(Rcx, RuntimeBuilders.local(40)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_search_ended"),
			Emit.load(Rdi, RuntimeBuilders.local(8)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.imm(Rsi, Boxing.undefined_bits),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_search_past"),
			Emit.load(Rsi, RuntimeBuilders.listed_item(Rdx)),
			Emit.jmp("runtime_search_call"),
			Emit.mark("runtime_search_past"),
			Emit.load(Rax, RuntimeBuilders.local(24)),
			Emit.cmp_imm(Rax, 2),
			Emit.jcc(B, "runtime_search_ended"),
			Emit.mark("runtime_search_call"),
			Emit.store(RuntimeBuilders.local(48), Rsi),
			Emit.load(Rdi, RuntimeBuilders.local(16)),
			Emit.load(Rcx, RuntimeBuilders.local(8)),
			Emit.call("runtime_call_back"),
			Emit.mov(Rdi, Rax),
			Emit.call(Runtime.truthy),
			Emit.load(Rdx, RuntimeBuilders.local(24)),
			Emit.cmp_imm(Rdx, 1),
			Emit.jcc(E, "runtime_search_every"),
			Emit.test(Rax, Rax),
			Emit.jcc(Ne, "runtime_search_found"),
			Emit.jmp("runtime_search_step"),
			Emit.mark("runtime_search_every"),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_search_found"),
			Emit.mark("runtime_search_step"),
			Emit.load(Rax, RuntimeBuilders.local(32)),
			Emit.plus_imm(Rax, 1),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.jmp("runtime_search_next"),
			Emit.mark("runtime_search_found"),
			Emit.load(Rax, RuntimeBuilders.local(48)),
			Emit.cmp_imm(Rdx, 2),
			Emit.jcc(E, "runtime_search_leave"),
			Emit.load(Rax, RuntimeBuilders.local(32)),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.cmp_imm(Rdx, 3),
			Emit.jcc(E, "runtime_search_leave"),
		])
		.concat(
			answers({
				label: "runtime_search_found",
				values: [Boxing.true_bits, Boxing.false_bits],
			}),
		)
		.concat([Emit.mark("runtime_search_ended"), Emit.load(Rdx, RuntimeBuilders.local(24))])
		.concat(
			answers({
				label: "runtime_search_ended",
				values: [
					Boxing.false_bits,
					Boxing.true_bits,
					Boxing.undefined_bits,
					RuntimeBuilders.double_bits(-1.0),
				],
			}),
		)
		.concat([
			Emit.mark("runtime_search_leave"),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
		])
	# r9: the place to start from, made whole, NaN 0, held to 2^53 in size;
	# r11: the kind; r10: the length.
	start = [
		Emit.mark(Runtime.index_of),
		Emit.mov(R11, R8),
		Emit.zero(R9),
		Emit.cmp_imm(Rcx, 2),
		Emit.jcc(B, "runtime_index_of_started"),
	]
		.concat(
			RuntimeBuilders.unless_number_items({ reg: Rdx, label: "runtime_index_of_place_stop" }),
		)
		.concat([
			Emit.to_xmm(Xmm0, Rdx),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
			Emit.jcc(P, "runtime_index_of_started"),
		])
		.concat(RuntimeBuilders.double_items({ to: Xmm1, value: 9007199254740992.0 }))
		.concat([
			Emit.imm(R9, 9007199254740992),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(Ae, "runtime_index_of_started"),
		])
		.concat(RuntimeBuilders.double_items({ to: Xmm1, value: -9007199254740992.0 }))
		.concat([
			Emit.imm(R9, -9007199254740992),
			Instruction(Ucomisd({ left: Xmm1, right: Xmm0 })),
			Emit.jcc(Ae, "runtime_index_of_started"),
			Instruction(Cvttsd2si({ to: R9, from: Xmm0 })),
			Emit.mark("runtime_index_of_started"),
		])
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(E, "runtime_index_of_string"),
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(Ne, "runtime_not_an_array"),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(R10, Emit.mem(Rdi, 0)),
			Emit.test(R9, R9),
			Emit.jcc(Ns, "runtime_index_of_item"),
			Emit.plus(R9, R10),
			Emit.test(R9, R9),
			Emit.jcc(Ns, "runtime_index_of_item"),
			Emit.zero(R9),
		])
	# Each item from r9 on compared by `===`, or as `includes` compares,
	# NaN the same as NaN.
	items = [
		Emit.mark("runtime_index_of_item"),
		Emit.cmp(R9, R10),
		Emit.jcc(Ge, "runtime_index_of_none"),
		Emit.load(R8, Emit.mem(Rdi, 16)),
		Emit.save(Rdi),
		Emit.save(Rsi),
		Emit.save(R9),
		Emit.save(R10),
		Emit.save(R11),
		Emit.load(Rdi, RuntimeBuilders.listed_item(R9)),
		Emit.call(Runtime.strict_equal),
		Emit.restore(R11),
		Emit.restore(R10),
		Emit.restore(R9),
		Emit.restore(Rsi),
		Emit.restore(Rdi),
		Emit.imm(Rcx, Boxing.true_bits),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(E, "runtime_index_of_found"),
		Emit.test(R11, R11),
		Emit.jcc(E, "runtime_index_of_next"),
	]
		.concat(RuntimeBuilders.unless_number_items({ reg: Rsi, label: "runtime_index_of_next" }))
		.concat([
			Emit.to_xmm(Xmm0, Rsi),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
			Emit.jcc(Np, "runtime_index_of_next"),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rax, RuntimeBuilders.listed_item(R9)),
		])
		.concat(RuntimeBuilders.unless_number_items({ reg: Rax, label: "runtime_index_of_next" }))
		.concat([
			Emit.to_xmm(Xmm0, Rax),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
			Emit.jcc(P, "runtime_index_of_found"),
			Emit.mark("runtime_index_of_next"),
			Emit.plus_imm(R9, 1),
			Emit.jmp("runtime_index_of_item"),
		])
	# A string: the place held between 0 and the length, then each place
	# from it where the string sought fits, compared byte by byte.
	string_search =
		[Emit.mark("runtime_index_of_string")]
			.concat(
				RuntimeBuilders.unless_string_items({
					reg: Rsi,
					label: "runtime_index_of_sought_stop",
				}),
			)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.load(R10, Emit.mem(Rdi, 0)),
				Emit.test(R9, R9),
				Emit.jcc(Ns, "runtime_index_of_low"),
				Emit.zero(R9),
				Emit.mark("runtime_index_of_low"),
				Emit.cmp(R9, R10),
				Emit.jcc(Le, "runtime_index_of_place"),
				Emit.mov(R9, R10),
				Emit.mark("runtime_index_of_place"),
				Emit.load(Rdx, Emit.mem(Rsi, 0)),
				Emit.mov(Rax, R9),
				Emit.plus(Rax, Rdx),
				Emit.cmp(Rax, R10),
				Emit.jcc(G, "runtime_index_of_none"),
				Emit.zero(Rcx),
				Emit.mark("runtime_index_of_byte"),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(E, "runtime_index_of_found"),
				Emit.mov(R8, R9),
				Emit.plus(R8, Rcx),
				RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
				Emit.mov(R8, Rcx),
				RuntimeBuilders.text_byte_item({ reg: R8, base: Rsi }),
				Emit.cmp(Rax, R8),
				Emit.jcc(Ne, "runtime_index_of_string_next"),
				Emit.plus_imm(Rcx, 1),
				Emit.jmp("runtime_index_of_byte"),
				Emit.mark("runtime_index_of_string_next"),
				Emit.plus_imm(R9, 1),
				Emit.jmp("runtime_index_of_place"),
			])
	answered = [
		Emit.mark("runtime_index_of_found"),
		Emit.imm(Rax, Boxing.true_bits),
		Emit.test(R11, R11),
		Emit.jcc(Ne, "runtime_index_of_done"),
		Instruction(Cvtsi2sd({ to: Xmm0, from: R9 })),
		Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
		Emit.ret,
		Emit.mark("runtime_index_of_none"),
		Emit.imm(Rax, Boxing.false_bits),
		Emit.test(R11, R11),
		Emit.jcc(Ne, "runtime_index_of_done"),
		Emit.imm(Rax, RuntimeBuilders.double_bits(-1.0)),
		Emit.mark("runtime_index_of_done"),
		Emit.ret,
		Emit.mark("runtime_index_of_place_stop"),
	]
		.concat(RuntimeBuilders.stopping_items("runtime_text_index_of_place"))
		.append(Emit.mark("runtime_index_of_sought_stop"))
		.concat(RuntimeBuilders.stopping_items("runtime_text_index_of_sought"))
	# r9: the items appended, r10 their count, r11 the place.
	concat_item =
		[Emit.mark(Runtime.concat_item)]
			.concat(RuntimeBuilders.tag_load_items(Rsi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(E, "runtime_concat_items"),
				Emit.jmp("runtime_push_item"),
				Emit.mark("runtime_concat_items"),
			])
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.mov(R9, Rsi),
				Emit.zero(R11),
				Emit.mark("runtime_concat_next"),
				Emit.load(R10, Emit.mem(R9, 0)),
				Emit.cmp(R11, R10),
				Emit.jcc(E, "runtime_concat_done"),
				Emit.load(R8, Emit.mem(R9, 16)),
				Emit.load(Rsi, RuntimeBuilders.listed_item(R11)),
				Emit.save(R9),
				Emit.save(R11),
				Emit.call("runtime_push_item"),
				Emit.restore(R11),
				Emit.restore(R9),
				Emit.plus_imm(R11, 1),
				Emit.jmp("runtime_concat_next"),
				Emit.mark("runtime_concat_done"),
				Emit.ret,
			])
	# rdx and r9 walk in from both ends, swapping.
	reverse =
		[Emit.mark(Runtime.reverse), Emit.mov(Rax, Rdi)]
			.concat(RuntimeBuilders.array_check_items)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.load(R8, Emit.mem(Rdi, 16)),
				Emit.zero(Rdx),
				Emit.load(R9, Emit.mem(Rdi, 0)),
				Emit.mark("runtime_reverse_next"),
				Emit.minus_imm(R9, 1),
				Emit.cmp(Rdx, R9),
				Emit.jcc(Ge, "runtime_reverse_done"),
				Emit.load(Rcx, RuntimeBuilders.listed_item(Rdx)),
				Emit.load(R10, RuntimeBuilders.listed_item(R9)),
				Emit.store(RuntimeBuilders.listed_item(Rdx), R10),
				Emit.store(RuntimeBuilders.listed_item(R9), Rcx),
				Emit.plus_imm(Rdx, 1),
				Emit.jmp("runtime_reverse_next"),
				Emit.mark("runtime_reverse_done"),
				Emit.ret,
			])
	[
		search,
		start,
		items,
		string_search,
		answered,
		concat_item,
		reverse,
	].join()
}

## `runtime_sort`: a merge sort, stable, of the items that aren't
## `undefined`, from one list to another in runs of 1, 2, 4 and on, a
## run's item taken from the right only when the comparison says the left
## one is greater; then the `undefined` items after them. Its frame holds
## the array (`[rbp - 8]`), the function or `undefined` (16), the count
## sorted (24), the list read (32), the list written (40), the run's width
## (48), its start (56), its middle (64) and its end (72), the left place
## (80), the right one (88) and the place written (96). A comparison's
## function may change every register but `rbp`, `rsp` and `r12` to `r15`,
## so every place is in the frame.
sort_items : List(Assembly.Statement)
sort_items = {
	listed = |{ list, place }| [
		Emit.load(R8, RuntimeBuilders.local(list)),
		Emit.load(Rcx, RuntimeBuilders.local(place)),
	]
	start = [
		Emit.mark(Runtime.sort),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 96),
	]
		.concat(RuntimeBuilders.array_check_items)
		.concat([
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rsi),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rsi, Rcx),
			Emit.jcc(E, "runtime_sort_by_text"),
			Emit.mov(Rax, Rsi),
			Emit.call(Runtime.check_function),
			Emit.mark("runtime_sort_by_text"),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		# The items that aren't `undefined` copied to a list of their own,
		# and a second list as long.
		.concat([
			Emit.load(Rdi, Emit.mem(Rdi, 0)),
			Emit.shl(Rdi, 3),
			Emit.save(Rdi),
			Emit.call(Runtime.allocate),
			Emit.store(RuntimeBuilders.local(32), Rax),
			Emit.restore(Rdi),
			Emit.call(Runtime.allocate),
			Emit.store(RuntimeBuilders.local(40), Rax),
			Emit.load(Rdi, RuntimeBuilders.local(8)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.load(R10, RuntimeBuilders.local(32)),
			Emit.zero(Rcx),
			Emit.zero(Rdx),
			Emit.imm(R11, Boxing.undefined_bits),
			Emit.mark("runtime_sort_kept"),
			Emit.cmp(Rcx, R9),
			Emit.jcc(E, "runtime_sort_counted"),
			Emit.load(Rax, RuntimeBuilders.listed_item(Rcx)),
			Emit.plus_imm(Rcx, 1),
			Emit.cmp(Rax, R11),
			Emit.jcc(E, "runtime_sort_kept"),
			Emit.store(
				Based({
					base: R10,
					index: Scaled({ reg: Rdx, scale: Times8 }),
					displacement: 0,
				}),
				Rax,
			),
			Emit.plus_imm(Rdx, 1),
			Emit.jmp("runtime_sort_kept"),
			Emit.mark("runtime_sort_counted"),
			Emit.store(RuntimeBuilders.local(24), Rdx),
			Emit.imm(Rax, 1),
			Emit.store(RuntimeBuilders.local(48), Rax),
		])
	# One pass of runs of the width: each pair of runs merged into the list
	# written, then the two lists change places.
	passes = [
		Emit.mark("runtime_sort_pass"),
		Emit.load(Rax, RuntimeBuilders.local(48)),
		Emit.load(Rcx, RuntimeBuilders.local(24)),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Ae, "runtime_sort_sorted"),
		Emit.zero(Rax),
		Emit.store(RuntimeBuilders.local(56), Rax),
		Emit.mark("runtime_sort_run"),
		Emit.load(Rax, RuntimeBuilders.local(56)),
		Emit.load(Rcx, RuntimeBuilders.local(24)),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Ae, "runtime_sort_passed"),
		Emit.store(RuntimeBuilders.local(80), Rax),
		Emit.store(RuntimeBuilders.local(96), Rax),
		Emit.load(Rdx, RuntimeBuilders.local(48)),
		Emit.plus(Rax, Rdx),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Be, "runtime_sort_middle"),
		Emit.mov(Rax, Rcx),
		Emit.mark("runtime_sort_middle"),
		Emit.store(RuntimeBuilders.local(64), Rax),
		Emit.store(RuntimeBuilders.local(88), Rax),
		Emit.plus(Rax, Rdx),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Be, "runtime_sort_end"),
		Emit.mov(Rax, Rcx),
		Emit.mark("runtime_sort_end"),
		Emit.store(RuntimeBuilders.local(72), Rax),
	]
	merge =
		[
			Emit.mark("runtime_sort_merge"),
			Emit.load(Rax, RuntimeBuilders.local(96)),
			Emit.load(Rcx, RuntimeBuilders.local(72)),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ae, "runtime_sort_merged"),
			Emit.load(Rax, RuntimeBuilders.local(80)),
			Emit.load(Rcx, RuntimeBuilders.local(64)),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ae, "runtime_sort_right"),
			Emit.load(Rax, RuntimeBuilders.local(88)),
			Emit.load(Rcx, RuntimeBuilders.local(72)),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ae, "runtime_sort_left"),
		]
			.concat(listed({ list: 32, place: 80 }))
			.append(Emit.load(Rdi, RuntimeBuilders.listed_item(Rcx)))
			.concat(listed({ list: 32, place: 88 }))
			.concat([
				Emit.load(Rsi, RuntimeBuilders.listed_item(Rcx)),
				Emit.call("runtime_sort_greater"),
				Emit.test(Rax, Rax),
				Emit.jcc(Ne, "runtime_sort_right"),
				Emit.mark("runtime_sort_left"),
			])
			.concat(listed({ list: 32, place: 80 }))
			.concat([
				Emit.load(Rax, RuntimeBuilders.listed_item(Rcx)),
				Emit.plus_imm(Rcx, 1),
				Emit.store(RuntimeBuilders.local(80), Rcx),
				Emit.jmp("runtime_sort_written"),
				Emit.mark("runtime_sort_right"),
			])
			.concat(listed({ list: 32, place: 88 }))
			.concat([
				Emit.load(Rax, RuntimeBuilders.listed_item(Rcx)),
				Emit.plus_imm(Rcx, 1),
				Emit.store(RuntimeBuilders.local(88), Rcx),
				Emit.mark("runtime_sort_written"),
			])
			.concat(listed({ list: 40, place: 96 }))
			.concat([
				Emit.store(RuntimeBuilders.listed_item(Rcx), Rax),
				Emit.plus_imm(Rcx, 1),
				Emit.store(RuntimeBuilders.local(96), Rcx),
				Emit.jmp("runtime_sort_merge"),
				Emit.mark("runtime_sort_merged"),
				Emit.load(Rax, RuntimeBuilders.local(72)),
				Emit.store(RuntimeBuilders.local(56), Rax),
				Emit.jmp("runtime_sort_run"),
				Emit.mark("runtime_sort_passed"),
				Emit.load(Rax, RuntimeBuilders.local(32)),
				Emit.load(Rcx, RuntimeBuilders.local(40)),
				Emit.store(RuntimeBuilders.local(32), Rcx),
				Emit.store(RuntimeBuilders.local(40), Rax),
				Emit.load(Rax, RuntimeBuilders.local(48)),
				Emit.plus(Rax, Rax),
				Emit.store(RuntimeBuilders.local(48), Rax),
				Emit.jmp("runtime_sort_pass"),
			])
	# The sorted items back in the array, then its `undefined` ones.
	finish = [Emit.mark("runtime_sort_sorted"), Emit.load(Rdi, RuntimeBuilders.local(8))]
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.load(R10, RuntimeBuilders.local(32)),
			Emit.load(R11, RuntimeBuilders.local(24)),
			Emit.zero(Rcx),
			Emit.mark("runtime_sort_copied"),
			Emit.cmp(Rcx, R9),
			Emit.jcc(E, "runtime_sort_done"),
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.cmp(Rcx, R11),
			Emit.jcc(Ae, "runtime_sort_copy"),
			Emit.load(
				Rax,
				Based({
					base: R10,
					index: Scaled({ reg: Rcx, scale: Times8 }),
					displacement: 0,
				}),
			),
			Emit.mark("runtime_sort_copy"),
			Emit.store(RuntimeBuilders.listed_item(Rcx), Rax),
			Emit.plus_imm(Rcx, 1),
			Emit.jmp("runtime_sort_copied"),
			Emit.mark("runtime_sort_done"),
			Emit.load(Rax, RuntimeBuilders.local(8)),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
		])
	# 1 in `rax` when `rdi` goes after `rsi`: the function's answer above
	# 0 (a number, or `true`), or the first's text after the second's.
	greater = [
		Emit.mark("runtime_sort_greater"),
		Emit.load(Rax, RuntimeBuilders.local(16)),
		Emit.imm(Rcx, Boxing.undefined_bits),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(E, "runtime_sort_texts"),
		Emit.save(Rsi),
		Emit.save(Rdi),
		Emit.mov(Rbx, Rax),
	]
		.concat(RuntimeBuilders.unboxed_items(Rbx))
		.concat([
			Emit.load(Rax, Emit.mem(Rbx, 0)),
			Emit.plus(Rax, Rbx),
			Emit.imm(Rcx, 2),
			Instruction(CallReg(Rax)),
			Emit.plus_imm(Rsp, 16),
			Emit.imm(Rcx, Boxing.true_bits),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(E, "runtime_sort_yes"),
		])
		.concat(
			RuntimeBuilders.unless_number_items({ reg: Rax, label: "runtime_sort_not_a_number" }),
		)
		.concat([
			Emit.to_xmm(Xmm0, Rax),
			Emit.zero(Rcx),
			Emit.to_xmm(Xmm1, Rcx),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(P, "runtime_sort_no"),
			Emit.jcc(A, "runtime_sort_yes"),
			Emit.mark("runtime_sort_no"),
			Emit.zero(Rax),
			Emit.ret,
			Emit.mark("runtime_sort_yes"),
			Emit.imm(Rax, 1),
			Emit.ret,
			Emit.mark("runtime_sort_not_a_number"),
			Emit.imm(Rcx, Boxing.false_bits),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(E, "runtime_sort_no"),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(E, "runtime_sort_no"),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_sort_answer"))
		.concat([
			Emit.mark("runtime_sort_texts"),
			Emit.save(Rsi),
			Emit.call(Runtime.text_of_boxed),
			Emit.restore(Rdi),
			Emit.save(Rax),
			Emit.call(Runtime.text_of_boxed),
			Emit.mov(Rsi, Rax),
			Emit.restore(Rdi),
			Emit.call(Runtime.compare),
			Emit.cmp_imm(Rax, 2),
			Emit.jcc(E, "runtime_sort_yes"),
			Emit.jmp("runtime_sort_no"),
		])
	[start, passes, merge, finish, greater].join()
}

## `runtime_splice`, `runtime_last_index_of` and `runtime_from_char_codes`.
## splice's frame holds the array (`[rbp - 8]`), the arguments (16), the
## start (24), the count removed (32), what is removed (40), the array
## that takes the old one's place (48) and the count put in (56). The new
## array's items become the old array's, so every reference sees the change.
edit_items : List(Assembly.Statement)
edit_items = {
	argument = |{ at, reg }| [
		Emit.load(R10, RuntimeBuilders.local(16)),
		Emit.load(R8, Emit.mem(R10, 16)),
		Emit.load(reg, Emit.mem(R8, 8 * at)),
	]
	splice =
		[
			Emit.mark(Runtime.splice),
			Emit.save(Rbp),
			Emit.mov(Rbp, Rsp),
			Emit.minus_imm(Rsp, 64),
		]
			.concat(RuntimeBuilders.array_check_items)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.store(RuntimeBuilders.local(8), Rdi),
				Emit.store(RuntimeBuilders.local(16), Rsi),
				Emit.load(R9, Emit.mem(Rdi, 0)),
				Emit.load(R11, Emit.mem(Rsi, 0)),
				Emit.zero(Rsi),
				Emit.zero(Rdx),
				Emit.test(R11, R11),
				Emit.jcc(E, "runtime_splice_counted"),
			])
			.concat(argument({ at: 0, reg: Rsi }))
			# The start, as `slice` takes one: from the end when negative,
			# held between 0 and the length.
			.concat(
				RuntimeBuilders.unless_number_items({
					reg: Rsi,
					label: "runtime_slice_not_a_number",
				}),
			)
			.concat([
				Emit.to_xmm(Xmm0, Rsi),
				Instruction(Cvttsd2si({ to: Rsi, from: Xmm0 })),
				Emit.cmp_imm(Rsi, 0),
				Emit.jcc(Ge, "runtime_splice_start_counted"),
				Emit.plus(Rsi, R9),
				Emit.cmp_imm(Rsi, 0),
				Emit.jcc(Ge, "runtime_splice_start_counted"),
				Emit.zero(Rsi),
				Emit.mark("runtime_splice_start_counted"),
				Emit.cmp(Rsi, R9),
				Emit.jcc(Le, "runtime_splice_start_held"),
				Emit.mov(Rsi, R9),
				Emit.mark("runtime_splice_start_held"),
				# With no count, the rest goes; a count is held between 0 and
				# what follows the start.
				Emit.mov(Rax, R9),
				Emit.minus(Rax, Rsi),
				Emit.mov(Rdx, Rax),
				Emit.cmp_imm(R11, 1),
				Emit.jcc(E, "runtime_splice_counted"),
			])
			.concat(argument({ at: 1, reg: Rdx }))
			.concat(
				RuntimeBuilders.unless_number_items({
					reg: Rdx,
					label: "runtime_slice_not_a_number",
				}),
			)
			.concat([
				Emit.to_xmm(Xmm0, Rdx),
				Instruction(Cvttsd2si({ to: Rdx, from: Xmm0 })),
				Emit.cmp_imm(Rdx, 0),
				Emit.jcc(Ge, "runtime_splice_count_low"),
				Emit.zero(Rdx),
				Emit.mark("runtime_splice_count_low"),
				Emit.cmp(Rdx, Rax),
				Emit.jcc(Le, "runtime_splice_counted"),
				Emit.mov(Rdx, Rax),
				Emit.mark("runtime_splice_counted"),
				Emit.store(RuntimeBuilders.local(24), Rsi),
				Emit.store(RuntimeBuilders.local(32), Rdx),
				# What is removed, copied out.
				Emit.mov(Rdi, Rdx),
				Emit.call(Runtime.new_array),
				Emit.store(RuntimeBuilders.local(40), Rax),
				Emit.mov(Rdi, Rdx),
				Emit.load(R10, RuntimeBuilders.local(8)),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rsi, RuntimeBuilders.local(24)),
				Emit.lea(Rsi, RuntimeBuilders.listed_item(Rsi)),
				Emit.load(Rcx, RuntimeBuilders.local(32)),
				Emit.shl(Rcx, 3),
				Instruction(RepMovsb),
				# The count put in: the arguments past the first two.
				Emit.load(R10, RuntimeBuilders.local(16)),
				Emit.load(Rcx, Emit.mem(R10, 0)),
				Emit.minus_imm(Rcx, 2),
				Emit.cmp_imm(Rcx, 0),
				Emit.jcc(Ge, "runtime_splice_put"),
				Emit.zero(Rcx),
				Emit.mark("runtime_splice_put"),
				Emit.store(RuntimeBuilders.local(56), Rcx),
				# The new length, and the items: those before the start, those
				# put in, then those after what is removed.
				Emit.load(R10, RuntimeBuilders.local(8)),
				Emit.load(Rdi, Emit.mem(R10, 0)),
				Emit.load(Rax, RuntimeBuilders.local(32)),
				Emit.minus(Rdi, Rax),
				Emit.plus(Rdi, Rcx),
				Emit.call(Runtime.new_array),
				Emit.store(RuntimeBuilders.local(48), Rax),
				Emit.mov(Rdi, Rdx),
				Emit.load(R10, RuntimeBuilders.local(8)),
				Emit.load(Rsi, Emit.mem(R10, 16)),
				Emit.load(Rcx, RuntimeBuilders.local(24)),
				Emit.shl(Rcx, 3),
				Instruction(RepMovsb),
				Emit.load(R10, RuntimeBuilders.local(16)),
				Emit.load(Rsi, Emit.mem(R10, 16)),
				Emit.plus_imm(Rsi, 16),
				Emit.load(Rcx, RuntimeBuilders.local(56)),
				Emit.shl(Rcx, 3),
				Instruction(RepMovsb),
				Emit.load(R10, RuntimeBuilders.local(8)),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rax, RuntimeBuilders.local(24)),
				Emit.load(Rcx, RuntimeBuilders.local(32)),
				Emit.plus(Rax, Rcx),
				Emit.lea(Rsi, RuntimeBuilders.listed_item(Rax)),
				Emit.load(Rcx, Emit.mem(R10, 0)),
				Emit.minus(Rcx, Rax),
				Emit.shl(Rcx, 3),
				Instruction(RepMovsb),
				Emit.load(Rax, RuntimeBuilders.local(48)),
			])
			.concat(RuntimeBuilders.unboxed_items(Rax))
			.concat([
				Emit.load(R10, RuntimeBuilders.local(8)),
				Emit.load(Rcx, Emit.mem(Rax, 0)),
				Emit.store(Emit.mem(R10, 0), Rcx),
				Emit.load(Rcx, Emit.mem(Rax, 8)),
				Emit.store(Emit.mem(R10, 8), Rcx),
				Emit.load(Rcx, Emit.mem(Rax, 16)),
				Emit.store(Emit.mem(R10, 16), Rcx),
				Emit.load(Rax, RuntimeBuilders.local(40)),
				Emit.mov(Rsp, Rbp),
				Emit.restore(Rbp),
				Emit.ret,
			])
	# An array's items from the last, compared by `===`; a string's places
	# from the last where the string sought fits, byte by byte. r9 the
	# place, r10 the receiver, r11 the value sought.
	last_index_of =
		[Emit.mark(Runtime.last_index_of), Emit.mov(R11, Rsi)]
			.concat(RuntimeBuilders.tag_load_items(Rdi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.string_tag),
				Emit.jcc(E, "runtime_last_index_of_string"),
			])
			.concat(RuntimeBuilders.array_check_items)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.mov(R10, Rdi),
				Emit.load(R9, Emit.mem(R10, 0)),
				Emit.mark("runtime_last_index_of_item"),
				Emit.minus_imm(R9, 1),
				Emit.cmp_imm(R9, 0),
				Emit.jcc(L, "runtime_last_index_of_none"),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rdi, RuntimeBuilders.listed_item(R9)),
				Emit.mov(Rsi, R11),
				Emit.save(R9),
				Emit.save(R10),
				Emit.save(R11),
				Emit.call(Runtime.strict_equal),
				Emit.restore(R11),
				Emit.restore(R10),
				Emit.restore(R9),
				Emit.imm(Rcx, Boxing.true_bits),
				Emit.cmp(Rax, Rcx),
				Emit.jcc(E, "runtime_last_index_of_found"),
				Emit.jmp("runtime_last_index_of_item"),
				Emit.mark("runtime_last_index_of_string"),
			])
			.concat(
				RuntimeBuilders.unless_string_items({
					reg: Rsi,
					label: "runtime_index_of_sought_stop",
				}),
			)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat(RuntimeBuilders.unboxed_items(Rsi))
			.concat([
				Emit.load(R9, Emit.mem(Rdi, 0)),
				Emit.load(Rdx, Emit.mem(Rsi, 0)),
				Emit.minus(R9, Rdx),
				Emit.mark("runtime_last_index_of_place"),
				Emit.cmp_imm(R9, 0),
				Emit.jcc(L, "runtime_last_index_of_none"),
				Emit.zero(Rcx),
				Emit.mark("runtime_last_index_of_byte"),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(E, "runtime_last_index_of_found"),
				Emit.mov(R8, R9),
				Emit.plus(R8, Rcx),
				RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
				Emit.mov(R8, Rcx),
				RuntimeBuilders.text_byte_item({ reg: R8, base: Rsi }),
				Emit.cmp(Rax, R8),
				Emit.jcc(Ne, "runtime_last_index_of_next"),
				Emit.plus_imm(Rcx, 1),
				Emit.jmp("runtime_last_index_of_byte"),
				Emit.mark("runtime_last_index_of_next"),
				Emit.minus_imm(R9, 1),
				Emit.jmp("runtime_last_index_of_place"),
				Emit.mark("runtime_last_index_of_found"),
				Instruction(Cvtsi2sd({ to: Xmm0, from: R9 })),
				Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
				Emit.ret,
				Emit.mark("runtime_last_index_of_none"),
				Emit.imm(Rax, RuntimeBuilders.double_bits(-1.0)),
				Emit.ret,
			])
	# Each number made a whole one and its low 16 bits taken, as
	# JavaScript's ToUint16 does; one past ASCII stops the program.
	from_char_codes =
		[Emit.mark(Runtime.from_char_codes)]
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.save(Rdi),
				Emit.load(Rdi, Emit.mem(Rdi, 0)),
				Emit.plus_imm(Rdi, 8),
				Emit.call(Runtime.allocate),
				Emit.restore(R10),
				Emit.load(R9, Emit.mem(R10, 0)),
				Emit.store(Emit.mem(Rax, 0), R9),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.zero(R11),
				Emit.mark("runtime_from_char_codes_next"),
				Emit.cmp(R11, R9),
				Emit.jcc(E, "runtime_from_char_codes_done"),
				Emit.load(Rdx, RuntimeBuilders.listed_item(R11)),
			])
			.concat(
				RuntimeBuilders.unless_number_items({
					reg: Rdx,
					label: "runtime_not_a_number_stop",
				}),
			)
			.concat([
				Emit.to_xmm(Xmm0, Rdx),
				Instruction(Cvttsd2si({ to: Rdx, from: Xmm0 })),
				Emit.bit_and_imm(Rdx, 0xFFFF),
				Emit.cmp_imm(Rdx, 0x80),
				Emit.jcc(Ae, "runtime_from_char_codes_wide"),
				Emit.byte_store(
					Emit.mem_index({
						base: Rax,
						index: R11,
						displacement: 8,
					}),
					Dl,
				),
				Emit.plus_imm(R11, 1),
				Emit.jmp("runtime_from_char_codes_next"),
				Emit.mark("runtime_from_char_codes_done"),
			])
			.concat(RuntimeBuilders.boxed_string_items)
			.append(Emit.ret)
			.append(Emit.mark("runtime_from_char_codes_wide"))
			.concat(RuntimeBuilders.stopping_items("runtime_text_wide_char"))
	# The items of an iterable, or of a plain object by its `length` and its
	# index keys, then each given to the function `rsi` (with its place)
	# unless it is `undefined`. Its frame: the source (8), the function
	# (16), the array (24) and the place (32).
	array_from =
		[
			Emit.mark(Runtime.array_from),
			Emit.save(Rbp),
			Emit.mov(Rbp, Rsp),
			Emit.minus_imm(Rsp, 32),
			Emit.store(Emit.mem(Rbp, -8), Rdi),
			Emit.store(Emit.mem(Rbp, -16), Rsi),
		]
			.concat(RuntimeBuilders.tag_load_items(Rdi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.object_tag),
				Emit.jcc(E, "runtime_array_from_object"),
				Emit.call(Runtime.items_of),
				Emit.jmp("runtime_array_from_mapped"),
				Emit.mark("runtime_array_from_object"),
				Emit.address_of(Rsi, "runtime_text_length"),
				Emit.call(Runtime.get_property),
				Emit.zero(Rdi),
			])
			.concat(
				RuntimeBuilders.unless_number_items({
					reg: Rax,
					label: "runtime_array_from_sized",
				}),
			)
			.concat([
				Emit.to_xmm(Xmm0, Rax),
				Instruction(Cvttsd2si({ to: Rdi, from: Xmm0 })),
				Emit.cmp_imm(Rdi, 0),
				Emit.jcc(Ge, "runtime_array_from_sized"),
				Emit.zero(Rdi),
				Emit.mark("runtime_array_from_sized"),
				Emit.call(Runtime.new_array),
				Emit.store(Emit.mem(Rbp, -24), Rax),
				Emit.zero(Rax),
				Emit.store(Emit.mem(Rbp, -32), Rax),
				Emit.mark("runtime_array_from_item"),
				Emit.load(R10, Emit.mem(Rbp, -24)),
			])
			.concat(RuntimeBuilders.unboxed_items(R10))
			.concat([
				Emit.load(Rcx, Emit.mem(Rbp, -32)),
				Emit.load(Rdx, Emit.mem(R10, 0)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, "runtime_array_from_listed"),
				Instruction(Cvtsi2sd({ to: Xmm0, from: Rcx })),
				Instruction(MovqFromXmm({ to: Rsi, from: Xmm0 })),
				Emit.load(Rdi, Emit.mem(Rbp, -8)),
				Emit.call(Runtime.get_index),
				Emit.load(R10, Emit.mem(Rbp, -24)),
			])
			.concat(RuntimeBuilders.unboxed_items(R10))
			.concat([
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rcx, Emit.mem(Rbp, -32)),
				Emit.store(RuntimeBuilders.listed_item(Rcx), Rax),
				Emit.plus_imm(Rcx, 1),
				Emit.store(Emit.mem(Rbp, -32), Rcx),
				Emit.jmp("runtime_array_from_item"),
				Emit.mark("runtime_array_from_listed"),
				Emit.load(Rax, Emit.mem(Rbp, -24)),
				Emit.mark("runtime_array_from_mapped"),
				Emit.load(Rsi, Emit.mem(Rbp, -16)),
				Emit.imm(Rcx, Boxing.undefined_bits),
				Emit.cmp(Rsi, Rcx),
				Emit.jcc(E, "runtime_array_from_done"),
				Emit.mov(Rdi, Rax),
				Emit.call(Runtime.map),
				Emit.mark("runtime_array_from_done"),
				Emit.mov(Rsp, Rbp),
				Emit.restore(Rbp),
				Emit.ret,
			])
	[splice, last_index_of, from_char_codes, array_from].join()
}
