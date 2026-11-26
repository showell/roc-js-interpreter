## This module holds the Maps and the Sets: `runtime_new_collection`,
## `runtime_collection_method`, and the walks of a Map, a Set or an
## iterator (`runtime_collection_next`, `runtime_items_of_collection`,
## `runtime_collection_for_each` ...), which Runtime's `for ... of`, spread
## and `forEach` reach by their labels.
##
## It stands apart from Runtime, its one caller being `RuntimeCode`,
## because its routines mark and call Runtime's names
## (`Runtime.new_collection`, `Runtime.collection_method`, ...), so it
## imports Runtime; Roc forbids an import cycle, so Runtime cannot list it
## in its own routines, and `RuntimeCode` puts the two together. The walks
## stay here with the Maps and Sets they read: Runtime calls them by label
## alone, which needs no import.
import Assembly
import Boxing
import Emit
import Runtime
import RuntimeBuilders

Collections :: [].{

	## The Maps and the Sets (`Boxing.collection_tag`): `runtime_new_collection`,
	## `runtime_collection_method` and the walks of a Map, a Set or an
	## iterator, which `for ... of`, a spread and `forEach` share. An entry
	## deleted keeps its place, its key `Boxing.gone_bits`, so a walk under
	## way meets the entries after it and those set later, as JavaScript's do;
	## `clear` deletes each entry the same way.
	items : List(Assembly.Statement)
	items = {
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
		# -0 in `rsi` made 0, as a Map's key is.
		unsigned_zero = |label| [
			Emit.imm(Rcx, (0x8000000000000000).to_i64_wrap()),
			Emit.cmp(Rsi, Rcx),
			Emit.jcc(Ne, label),
			Emit.zero(Rsi),
			Emit.mark(label),
		]
		# The address of the entry of the key `rsi` in the Map or Set at `rdi`,
		# or 0, keys compared as SameValueZero: the same bits, two strings of
		# the same bytes, or two NaNs. Its frame: the record (8), the key (16)
		# and the place (24).
		find =
			framed({ label: "runtime_collection_find", size: 32 })
				.concat(unsigned_zero("runtime_collection_find_key"))
				.concat([
					Emit.store(RuntimeBuilders.local(8), Rdi),
					Emit.store(RuntimeBuilders.local(16), Rsi),
					Emit.zero(Rax),
					Emit.store(RuntimeBuilders.local(24), Rax),
					Emit.mark("runtime_collection_find_next"),
					Emit.load(R10, RuntimeBuilders.local(8)),
					Emit.load(Rcx, RuntimeBuilders.local(24)),
					Emit.load(Rdx, Emit.mem(R10, 16)),
					Emit.cmp(Rcx, Rdx),
					Emit.jcc(Ae, "runtime_collection_find_none"),
					Emit.shl(Rcx, 4),
					Emit.load(R8, Emit.mem(R10, 32)),
					Emit.plus(R8, Rcx),
					Emit.load(Rdi, Emit.mem(R8, 0)),
					Emit.load(Rsi, RuntimeBuilders.local(16)),
					Emit.cmp(Rdi, Rsi),
					Emit.jcc(E, "runtime_collection_find_found"),
				])
				.concat(RuntimeBuilders.tag_load_items(Rdi))
				.concat([
					Emit.cmp_imm(Rcx, Boxing.string_tag),
					Emit.jcc(Ne, "runtime_collection_find_number"),
				])
				.concat(
					RuntimeBuilders.unless_string_items({
						reg: Rsi,
						label: "runtime_collection_find_step",
					}),
				)
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat(RuntimeBuilders.unboxed_items(Rsi))
				.concat([
					Emit.call("runtime_text_equal"),
					Emit.test(Rax, Rax),
					Emit.jcc(Ne, "runtime_collection_find_found"),
					Emit.jmp("runtime_collection_find_step"),
					Emit.mark("runtime_collection_find_number"),
					Emit.cmp_imm(Rcx, Boxing.first_tag),
					Emit.jcc(Ae, "runtime_collection_find_step"),
				])
				.concat(
					RuntimeBuilders.unless_number_items({
						reg: Rsi,
						label: "runtime_collection_find_step",
					}),
				)
				.concat([
					Emit.to_xmm(Xmm0, Rdi),
					Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
					Emit.jcc(Np, "runtime_collection_find_step"),
					Emit.to_xmm(Xmm0, Rsi),
					Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
					Emit.jcc(P, "runtime_collection_find_found"),
					Emit.mark("runtime_collection_find_step"),
					Emit.load(Rcx, RuntimeBuilders.local(24)),
					Emit.plus_imm(Rcx, 1),
					Emit.store(RuntimeBuilders.local(24), Rcx),
					Emit.jmp("runtime_collection_find_next"),
					Emit.mark("runtime_collection_find_found"),
					Emit.load(R10, RuntimeBuilders.local(8)),
					Emit.load(Rax, RuntimeBuilders.local(24)),
					Emit.shl(Rax, 4),
					Emit.load(R8, Emit.mem(R10, 32)),
					Emit.plus(Rax, R8),
					Emit.jmp("runtime_collection_find_leave"),
					Emit.mark("runtime_collection_find_none"),
					Emit.zero(Rax),
					Emit.mark("runtime_collection_find_leave"),
				])
				.concat(leave)
		# The key `rsi` given the value `rdx` in the Map or Set at `rdi`: its
		# entry's value when it has one, else a new entry after the last, the
		# entries copied to twice the room when they fill it.
		put =
			[Emit.mark("runtime_collection_put")]
				.concat(unsigned_zero("runtime_collection_put_key"))
				.concat([
					# A Set's value is its key.
					Emit.load(Rcx, Emit.mem(Rdi, 0)),
					Emit.test(Rcx, Rcx),
					Emit.jcc(E, "runtime_collection_put_valued"),
					Emit.mov(Rdx, Rsi),
					Emit.mark("runtime_collection_put_valued"),
					Emit.save(Rdi),
					Emit.save(Rsi),
					Emit.save(Rdx),
					Emit.call("runtime_collection_find"),
					Emit.restore(Rdx),
					Emit.restore(Rsi),
					Emit.restore(Rdi),
					Emit.test(Rax, Rax),
					Emit.jcc(E, "runtime_collection_put_new"),
					Emit.store(Emit.mem(Rax, 8), Rdx),
					Emit.ret,
					Emit.mark("runtime_collection_put_new"),
					Emit.load(Rcx, Emit.mem(Rdi, 16)),
					Emit.load(R8, Emit.mem(Rdi, 24)),
					Emit.cmp(Rcx, R8),
					Emit.jcc(B, "runtime_collection_put_room"),
					Emit.save(Rdi),
					Emit.save(Rsi),
					Emit.save(Rdx),
					Emit.mov(Rdi, R8),
					Emit.shl(Rdi, 5),
					Emit.call(Runtime.allocate),
					Emit.restore(Rdx),
					Emit.restore(Rsi),
					Emit.restore(Rdi),
					Emit.load(R8, Emit.mem(Rdi, 24)),
					Emit.plus(R8, R8),
					Emit.store(Emit.mem(Rdi, 24), R8),
					Emit.save(Rsi),
					Emit.load(Rcx, Emit.mem(Rdi, 16)),
					Emit.shl(Rcx, 4),
					Emit.load(Rsi, Emit.mem(Rdi, 32)),
					Emit.mov(R9, Rdi),
					Emit.mov(Rdi, Rax),
					Instruction(RepMovsb),
					Emit.store(Emit.mem(R9, 32), Rax),
					Emit.mov(Rdi, R9),
					Emit.restore(Rsi),
					Emit.mark("runtime_collection_put_room"),
					Emit.load(Rcx, Emit.mem(Rdi, 16)),
					Emit.mov(R8, Rcx),
					Emit.shl(R8, 4),
					Emit.load(R9, Emit.mem(Rdi, 32)),
					Emit.plus(R9, R8),
					Emit.store(Emit.mem(R9, 0), Rsi),
					Emit.store(Emit.mem(R9, 8), Rdx),
					Emit.plus_imm(Rcx, 1),
					Emit.store(Emit.mem(Rdi, 16), Rcx),
					Emit.load(Rcx, Emit.mem(Rdi, 8)),
					Emit.plus_imm(Rcx, 1),
					Emit.store(Emit.mem(Rdi, 8), Rcx),
					Emit.ret,
				])
		# A new Map (`rdi` 0) or Set (1) of the items of `rsi` (none for
		# `undefined` or `null`), a Map's each an array of its key and value.
		# Its frame: the record (8), the items (16) and the place (24).
		new_collection =
			framed({ label: Runtime.new_collection, size: 32 })
				.concat([
					Emit.save(Rdi),
					Emit.save(Rsi),
					Emit.imm(Rdi, 40 + 4 * 16),
					Emit.call(Runtime.allocate),
					Emit.restore(Rsi),
					Emit.restore(Rdi),
					Emit.store(Emit.mem(Rax, 0), Rdi),
					Emit.zero(Rcx),
					Emit.store(Emit.mem(Rax, 8), Rcx),
					Emit.store(Emit.mem(Rax, 16), Rcx),
					Emit.imm(Rcx, 4),
					Emit.store(Emit.mem(Rax, 24), Rcx),
					Emit.lea(Rcx, Emit.mem(Rax, 40)),
					Emit.store(Emit.mem(Rax, 32), Rcx),
					Emit.store(RuntimeBuilders.local(8), Rax),
					Emit.mov(Rdi, Rsi),
				])
				.concat(RuntimeBuilders.nullish_jump_items("runtime_new_collection_done"))
				.concat([Emit.call(Runtime.items_of)])
				.concat(RuntimeBuilders.unboxed_items(Rax))
				.concat([
					Emit.store(RuntimeBuilders.local(16), Rax),
					Emit.zero(Rax),
					Emit.store(RuntimeBuilders.local(24), Rax),
					Emit.mark("runtime_new_collection_next"),
					Emit.load(R10, RuntimeBuilders.local(16)),
					Emit.load(Rcx, RuntimeBuilders.local(24)),
					Emit.load(Rdx, Emit.mem(R10, 0)),
					Emit.cmp(Rcx, Rdx),
					Emit.jcc(Ae, "runtime_new_collection_done"),
					Emit.load(R8, Emit.mem(R10, 16)),
					Emit.load(Rsi, RuntimeBuilders.listed_item(Rcx)),
					Emit.plus_imm(Rcx, 1),
					Emit.store(RuntimeBuilders.local(24), Rcx),
					Emit.load(Rdi, RuntimeBuilders.local(8)),
					Emit.load(Rcx, Emit.mem(Rdi, 0)),
					Emit.test(Rcx, Rcx),
					Emit.jcc(Ne, "runtime_new_collection_value"),
				])
				.concat(RuntimeBuilders.tag_load_items(Rsi))
				.concat([
					Emit.cmp_imm(Rcx, Boxing.array_tag),
					Emit.jcc(Ne, "runtime_new_collection_not_entry"),
					Emit.mov(R9, Rsi),
				])
				.concat(RuntimeBuilders.unboxed_items(R9))
				.concat([
					Emit.load(Rcx, Emit.mem(R9, 0)),
					Emit.imm(Rsi, Boxing.undefined_bits),
					Emit.imm(Rdx, Boxing.undefined_bits),
					Emit.test(Rcx, Rcx),
					Emit.jcc(E, "runtime_new_collection_entry"),
					Emit.load(R8, Emit.mem(R9, 16)),
					Emit.load(Rsi, Emit.mem(R8, 0)),
					Emit.cmp_imm(Rcx, 1),
					Emit.jcc(E, "runtime_new_collection_entry"),
					Emit.load(Rdx, Emit.mem(R8, 8)),
					Emit.mark("runtime_new_collection_entry"),
					Emit.call("runtime_collection_put"),
					Emit.jmp("runtime_new_collection_next"),
					Emit.mark("runtime_new_collection_value"),
					Emit.mov(Rdx, Rsi),
					Emit.call("runtime_collection_put"),
					Emit.jmp("runtime_new_collection_next"),
					# node's TypeError for a Map's item that is no entry.
					Emit.mark("runtime_new_collection_not_entry"),
					Emit.mov(Rdi, Rsi),
					Emit.call("runtime_text_of"),
					Emit.mov(Rsi, Rax),
					Emit.address_of(Rdi, "runtime_text_entry_before"),
					Emit.call("runtime_concat"),
					Emit.mov(Rdi, Rax),
					Emit.address_of(Rsi, "runtime_text_entry_after"),
					Emit.call("runtime_concat"),
					Emit.mov(Rsi, Rax),
					Emit.address_of(Rdi, Runtime.error_name_label("TypeError")),
					Emit.call(Runtime.new_error),
					Emit.jmp(Runtime.throw),
					Emit.mark("runtime_new_collection_done"),
					Emit.load(Rax, RuntimeBuilders.local(8)),
				])
				.concat(RuntimeBuilders.boxed_items(Boxing.collection_tag))
				.concat(leave)
		# The next item from the place `rsi` (a whole number) of the array, Map
		# or Set `rdi`, past the deleted entries: `rdx` 0 a key (an array's
		# place), 1 a value, 2 an entry (a new array of the key and the value).
		# It gives the item in `rax`, `rdx` 1 (0 past the end) and the next
		# place in `rcx`; r9 is the place, r11 what it gives.
		next =
			[
				Emit.mark("runtime_collection_next"),
				Emit.mov(R11, Rdx),
				Emit.mov(R9, Rsi),
			]
				.concat(RuntimeBuilders.tag_load_items(Rdi))
				.concat([
					Emit.cmp_imm(Rcx, Boxing.array_tag),
					Emit.jcc(E, "runtime_collection_next_array"),
				])
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat([
					Emit.mov(R10, Rdi),
					Emit.mark("runtime_collection_next_entry"),
					Emit.load(Rcx, Emit.mem(R10, 16)),
					Emit.cmp(R9, Rcx),
					Emit.jcc(Ae, "runtime_collection_next_none"),
					Emit.mov(Rax, R9),
					Emit.shl(Rax, 4),
					Emit.load(R8, Emit.mem(R10, 32)),
					Emit.plus(R8, Rax),
					Emit.plus_imm(R9, 1),
					Emit.load(Rsi, Emit.mem(R8, 0)),
					Emit.imm(Rax, Boxing.gone_bits),
					Emit.cmp(Rsi, Rax),
					Emit.jcc(E, "runtime_collection_next_entry"),
					Emit.load(R8, Emit.mem(R8, 8)),
					Emit.jmp("runtime_collection_next_given"),
					Emit.mark("runtime_collection_next_array"),
				])
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat([
					Emit.load(Rcx, Emit.mem(Rdi, 0)),
					Emit.cmp(R9, Rcx),
					Emit.jcc(Ae, "runtime_collection_next_none"),
					Emit.load(R8, Emit.mem(Rdi, 16)),
					Emit.load(R8, RuntimeBuilders.listed_item(R9)),
					Instruction(Cvtsi2sd({ to: Xmm0, from: R9 })),
					Instruction(MovqFromXmm({ to: Rsi, from: Xmm0 })),
					Emit.plus_imm(R9, 1),
					# rsi the key, r8 the value.
					Emit.mark("runtime_collection_next_given"),
					Emit.mov(Rax, Rsi),
					Emit.test(R11, R11),
					Emit.jcc(E, "runtime_collection_next_found"),
					Emit.mov(Rax, R8),
					Emit.cmp_imm(R11, 1),
					Emit.jcc(E, "runtime_collection_next_found"),
					Emit.imm(Rdi, 2),
					Emit.call(Runtime.new_array),
					Emit.store(Emit.mem(Rdx, 0), Rsi),
					Emit.store(Emit.mem(Rdx, 8), R8),
					Emit.mark("runtime_collection_next_found"),
					Emit.imm(Rdx, 1),
					Emit.mov(Rcx, R9),
					Emit.ret,
					Emit.mark("runtime_collection_next_none"),
					Emit.imm(Rax, Boxing.undefined_bits),
					Emit.zero(Rdx),
					Emit.mov(Rcx, R9),
					Emit.ret,
				])
		# A walk's start: an array, a Map, a Set or an iterator is walked as it
		# is, live; a string by its characters.
		iter_start =
			[Emit.mark(Runtime.iter_start), Emit.mov(Rax, Rdi)]
				.concat(RuntimeBuilders.tag_load_items(Rdi))
				.concat([
					Emit.cmp_imm(Rcx, Boxing.array_tag),
					Emit.jcc(E, "runtime_iter_start_done"),
					Emit.cmp_imm(Rcx, Boxing.collection_tag),
					Emit.jcc(E, "runtime_iter_start_done"),
					Emit.cmp_imm(Rcx, Boxing.string_tag),
					Emit.jcc(E, Runtime.items_of),
					Emit.jmp("runtime_not_iterable"),
					Emit.mark("runtime_iter_start_done"),
					Emit.ret,
				])
		# Each item of a Map's, a Set's or an iterator's walk, in a new array; an
		# iterator's place moves to its end. Its frame: what is walked (8), the
		# place (16), what it gives (24), the array (32) and the iterator (40, 0
		# for none).
		listed =
			framed({ label: "runtime_items_of_collection", size: 48 })
				.concat([Emit.store(RuntimeBuilders.local(8), Rdi), Emit.mov(Rax, Rdi)])
				.concat(RuntimeBuilders.unboxed_items(Rax))
				.concat([
					Emit.zero(Rcx),
					Emit.store(RuntimeBuilders.local(16), Rcx),
					Emit.store(RuntimeBuilders.local(40), Rcx),
					Emit.load(Rcx, Emit.mem(Rax, 0)),
					Emit.cmp_imm(Rcx, 2),
					Emit.jcc(E, "runtime_items_of_iterator"),
					Emit.jcc(A, "runtime_not_iterable"),
					Emit.imm(Rdx, 2),
					Emit.minus(Rdx, Rcx),
					Emit.store(RuntimeBuilders.local(24), Rdx),
					Emit.jmp("runtime_items_of_walk"),
					Emit.mark("runtime_items_of_iterator"),
					Emit.store(RuntimeBuilders.local(40), Rax),
					Emit.load(Rcx, Emit.mem(Rax, 8)),
					Emit.store(RuntimeBuilders.local(8), Rcx),
					Emit.load(Rcx, Emit.mem(Rax, 16)),
					Emit.store(RuntimeBuilders.local(16), Rcx),
					Emit.load(Rcx, Emit.mem(Rax, 24)),
					Emit.store(RuntimeBuilders.local(24), Rcx),
					Emit.mark("runtime_items_of_walk"),
					Emit.zero(Rdi),
					Emit.call(Runtime.new_array),
					Emit.store(RuntimeBuilders.local(32), Rax),
					Emit.mark("runtime_items_of_step"),
					Emit.load(Rdi, RuntimeBuilders.local(8)),
					Emit.load(Rsi, RuntimeBuilders.local(16)),
					Emit.load(Rdx, RuntimeBuilders.local(24)),
					Emit.call("runtime_collection_next"),
					Emit.store(RuntimeBuilders.local(16), Rcx),
					Emit.test(Rdx, Rdx),
					Emit.jcc(E, "runtime_items_of_walked"),
					Emit.load(Rdi, RuntimeBuilders.local(32)),
				])
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat([
					Emit.mov(Rsi, Rax),
					Emit.call("runtime_push_item"),
					Emit.jmp("runtime_items_of_step"),
					Emit.mark("runtime_items_of_walked"),
					Emit.load(Rax, RuntimeBuilders.local(40)),
					Emit.test(Rax, Rax),
					Emit.jcc(E, "runtime_items_of_given"),
					Emit.load(Rcx, RuntimeBuilders.local(16)),
					Emit.store(Emit.mem(Rax, 16), Rcx),
					Emit.mark("runtime_items_of_given"),
					Emit.load(Rax, RuntimeBuilders.local(32)),
				])
				.concat(leave)
		# A new iterator over the array, Map or Set `rdi`, giving what `rsi`
		# says (0 keys, 1 values, 2 entries), from its start.
		iterator_of = [
			Emit.mark("runtime_iterator_of"),
			Emit.save(Rdi),
			Emit.save(Rsi),
			Emit.imm(Rdi, 32),
			Emit.call(Runtime.allocate),
			Emit.restore(Rsi),
			Emit.restore(Rdi),
			Emit.imm(Rcx, 2),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			Emit.store(Emit.mem(Rax, 8), Rdi),
			Emit.zero(Rcx),
			Emit.store(Emit.mem(Rax, 16), Rcx),
			Emit.store(Emit.mem(Rax, 24), Rsi),
		]
			.concat(RuntimeBuilders.boxed_items(Boxing.collection_tag))
			.append(Emit.ret)
		# A Map's or a Set's `forEach`: the function `rsi` called with each
		# live entry's value, its key and the Map or Set `rdi`, entries set
		# during the walk met too. Its frame: the Map or Set (8), the function
		# (16) and the place (24).
		for_each =
			framed({ label: "runtime_collection_for_each", size: 32 })
				.concat([
					Emit.store(RuntimeBuilders.local(8), Rdi),
					Emit.store(RuntimeBuilders.local(16), Rsi),
					Emit.mov(Rax, Rsi),
					Emit.call(Runtime.check_function),
					Emit.zero(Rax),
					Emit.store(RuntimeBuilders.local(24), Rax),
					Emit.mark("runtime_collection_for_each_next"),
					Emit.load(R10, RuntimeBuilders.local(8)),
				])
				.concat(RuntimeBuilders.unboxed_items(R10))
				.concat([
					Emit.load(Rcx, RuntimeBuilders.local(24)),
					Emit.load(Rdx, Emit.mem(R10, 16)),
					Emit.cmp(Rcx, Rdx),
					Emit.jcc(Ae, "runtime_collection_for_each_done"),
					Emit.mov(Rax, Rcx),
					Emit.shl(Rax, 4),
					Emit.load(R8, Emit.mem(R10, 32)),
					Emit.plus(R8, Rax),
					Emit.plus_imm(Rcx, 1),
					Emit.store(RuntimeBuilders.local(24), Rcx),
					Emit.load(Rsi, Emit.mem(R8, 0)),
					Emit.imm(Rax, Boxing.gone_bits),
					Emit.cmp(Rsi, Rax),
					Emit.jcc(E, "runtime_collection_for_each_next"),
					Emit.load(Rax, RuntimeBuilders.local(8)),
					Emit.save(Rax),
					Emit.save(Rsi),
					Emit.load(Rax, Emit.mem(R8, 8)),
					Emit.save(Rax),
					Emit.load(Rbx, RuntimeBuilders.local(16)),
				])
				.concat(RuntimeBuilders.unboxed_items(Rbx))
				.concat([
					Emit.load(Rax, Emit.mem(Rbx, 0)),
					Emit.plus(Rax, Rbx),
					Emit.imm(Rcx, 3),
					Emit.imm(Rdx, Boxing.undefined_bits),
					Instruction(CallReg(Rax)),
					Emit.plus_imm(Rsp, 24),
					Emit.jmp("runtime_collection_for_each_next"),
					Emit.mark("runtime_collection_for_each_done"),
					Emit.imm(Rax, Boxing.undefined_bits),
				])
				.concat(leave)
		method_case = |{ number, label }| [Emit.cmp_imm(Rcx, number), Emit.jcc(E, label)]
		answer = |{ label, value }| [Emit.mark(label), Emit.imm(Rax, value)].concat(leave)
		# `rcx`: 0 get, 1 set, 2 has, 3 delete, 4 clear, 5 add, 6 keys, 7
		# values, 8 entries, of the receiver `rdi` with the arguments in the
		# array `rdx`. A receiver that is no Map or Set (nor an array, for the
		# last three) has the method named `rsi` called as its property is. Its
		# frame: the receiver (8), the method (16), the arguments (24), the
		# first argument (32), the second (40) and the name (48).
		method =
			framed({ label: Runtime.collection_method, size: 48 })
				.concat([
					Emit.store(RuntimeBuilders.local(8), Rdi),
					Emit.store(RuntimeBuilders.local(16), Rcx),
					Emit.store(RuntimeBuilders.local(24), Rdx),
					Emit.store(RuntimeBuilders.local(48), Rsi),
				])
				.concat(RuntimeBuilders.tag_load_items(Rdi))
				.concat([
					Emit.cmp_imm(Rcx, Boxing.collection_tag),
					Emit.jcc(E, "runtime_collection_method_own"),
					Emit.cmp_imm(Rcx, Boxing.array_tag),
					Emit.jcc(Ne, "runtime_collection_method_property"),
					Emit.load(Rcx, RuntimeBuilders.local(16)),
					Emit.cmp_imm(Rcx, 6),
					Emit.jcc(B, "runtime_collection_method_property"),
					Emit.mark("runtime_collection_method_iterator"),
					Emit.load(Rsi, RuntimeBuilders.local(16)),
					Emit.minus_imm(Rsi, 6),
					Emit.load(Rdi, RuntimeBuilders.local(8)),
					Emit.call("runtime_iterator_of"),
				])
				.concat(leave)
				.concat([
					Emit.mark("runtime_collection_method_property"),
					Emit.load(Rdi, RuntimeBuilders.local(8)),
					Emit.load(Rsi, RuntimeBuilders.local(48)),
					Emit.call(Runtime.get_property),
					Emit.mov(Rdi, Rax),
					Emit.load(Rsi, RuntimeBuilders.local(24)),
					# A method of the receiver's own takes it first.
					Emit.load(Rdx, RuntimeBuilders.local(8)),
					Emit.call(Runtime.call_spread),
				])
				.concat(leave)
				.concat([Emit.mark("runtime_collection_method_own"), Emit.mov(Rax, Rdi)])
				.concat(RuntimeBuilders.unboxed_items(Rax))
				.concat([
					Emit.load(Rcx, Emit.mem(Rax, 0)),
					Emit.cmp_imm(Rcx, 2),
					Emit.jcc(Ae, "runtime_collection_method_stop"),
					Emit.load(R10, RuntimeBuilders.local(24)),
				])
				.concat(RuntimeBuilders.unboxed_items(R10))
				.concat([
					Emit.load(Rcx, Emit.mem(R10, 0)),
					Emit.imm(Rax, Boxing.undefined_bits),
					Emit.store(RuntimeBuilders.local(32), Rax),
					Emit.store(RuntimeBuilders.local(40), Rax),
					Emit.test(Rcx, Rcx),
					Emit.jcc(E, "runtime_collection_method_given"),
					Emit.load(R8, Emit.mem(R10, 16)),
					Emit.load(Rax, Emit.mem(R8, 0)),
					Emit.store(RuntimeBuilders.local(32), Rax),
					Emit.cmp_imm(Rcx, 1),
					Emit.jcc(E, "runtime_collection_method_given"),
					Emit.load(Rax, Emit.mem(R8, 8)),
					Emit.store(RuntimeBuilders.local(40), Rax),
					Emit.mark("runtime_collection_method_given"),
					Emit.load(Rdi, RuntimeBuilders.local(8)),
				])
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat([
					Emit.load(Rsi, RuntimeBuilders.local(32)),
					# r8: 0 for a Map, 1 for a Set.
					Emit.load(R8, Emit.mem(Rdi, 0)),
					Emit.load(Rcx, RuntimeBuilders.local(16)),
					Emit.cmp_imm(Rcx, 6),
					Emit.jcc(Ae, "runtime_collection_method_iterator"),
				])
				.concat(method_case({ number: 0, label: "runtime_collection_method_get" }))
				.concat(method_case({ number: 1, label: "runtime_collection_method_set" }))
				.concat(method_case({ number: 2, label: "runtime_collection_method_has" }))
				.concat(method_case({ number: 3, label: "runtime_collection_method_delete" }))
				.concat(method_case({ number: 4, label: "runtime_collection_method_clear" }))
				# add, of a Set alone.
				.concat([
					Emit.test(R8, R8),
					Emit.jcc(E, "runtime_collection_method_stop"),
					Emit.mov(Rdx, Rsi),
					Emit.call("runtime_collection_put"),
					Emit.load(Rax, RuntimeBuilders.local(8)),
				])
				.concat(leave)
				.concat([
					Emit.mark("runtime_collection_method_get"),
					Emit.test(R8, R8),
					Emit.jcc(Ne, "runtime_collection_method_stop"),
					Emit.call("runtime_collection_find"),
					Emit.test(Rax, Rax),
					Emit.jcc(E, "runtime_collection_method_undefined"),
					Emit.load(Rax, Emit.mem(Rax, 8)),
				])
				.concat(leave)
				.concat([
					Emit.mark("runtime_collection_method_set"),
					Emit.test(R8, R8),
					Emit.jcc(Ne, "runtime_collection_method_stop"),
					Emit.load(Rdx, RuntimeBuilders.local(40)),
					Emit.call("runtime_collection_put"),
					Emit.load(Rax, RuntimeBuilders.local(8)),
				])
				.concat(leave)
				.concat([
					Emit.mark("runtime_collection_method_has"),
					Emit.call("runtime_collection_find"),
					Emit.test(Rax, Rax),
					Emit.jcc(E, "runtime_collection_method_false"),
					Emit.jmp("runtime_collection_method_true"),
					Emit.mark("runtime_collection_method_delete"),
					Emit.call("runtime_collection_find"),
					Emit.test(Rax, Rax),
					Emit.jcc(E, "runtime_collection_method_false"),
					Emit.imm(Rcx, Boxing.gone_bits),
					Emit.store(Emit.mem(Rax, 0), Rcx),
					Emit.imm(Rcx, Boxing.undefined_bits),
					Emit.store(Emit.mem(Rax, 8), Rcx),
					Emit.load(Rdi, RuntimeBuilders.local(8)),
				])
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat([
					Emit.load(Rcx, Emit.mem(Rdi, 8)),
					Emit.minus_imm(Rcx, 1),
					Emit.store(Emit.mem(Rdi, 8), Rcx),
					Emit.jmp("runtime_collection_method_true"),
					Emit.mark("runtime_collection_method_clear"),
					Emit.load(Rcx, Emit.mem(Rdi, 16)),
					Emit.load(R8, Emit.mem(Rdi, 32)),
					Emit.imm(Rax, Boxing.gone_bits),
					Emit.mark("runtime_collection_method_clear_next"),
					Emit.test(Rcx, Rcx),
					Emit.jcc(E, "runtime_collection_method_cleared"),
					Emit.store(Emit.mem(R8, 0), Rax),
					Emit.plus_imm(R8, 16),
					Emit.minus_imm(Rcx, 1),
					Emit.jmp("runtime_collection_method_clear_next"),
					Emit.mark("runtime_collection_method_cleared"),
					Emit.zero(Rcx),
					Emit.store(Emit.mem(Rdi, 8), Rcx),
				])
				.concat(
					answer({
						label: "runtime_collection_method_undefined",
						value: Boxing.undefined_bits,
					}),
				)
				.concat(
					answer({ label: "runtime_collection_method_true", value: Boxing.true_bits }),
				)
				.concat(
					answer({ label: "runtime_collection_method_false", value: Boxing.false_bits }),
				)
				.append(Emit.mark("runtime_collection_method_stop"))
				.concat(RuntimeBuilders.stopping_items("runtime_text_collection_method"))
		[
			find,
			put,
			new_collection,
			next,
			iter_start,
			listed,
			iterator_of,
			for_each,
			method,
		].join()
	}
}
