## This module holds `console.log`'s and `util.inspect`'s writing of a
## value: `runtime_inspect` (a value as node writes it at a depth), its
## `runtime_inspect_list` (an array or an object, on one line or one
## entry a line) and `runtime_columns` (node's grouping of a long array
## into columns), with the byte, space, name and brace builders and the
## escapes they share.
##
## It stands apart from Runtime, its one caller being `RuntimeCode`,
## because its routines call Runtime's names, so it imports Runtime; Roc
## forbids an import cycle, so Runtime cannot list it in its own routines,
## and `RuntimeCode` puts the two together. The list and the columns stay
## here with inspect: they share one frame (`list_frame_size`) and jump to
## each other's labels.
import Assembly
import Boxing
import Emit
import Runtime
import RuntimeBuilders

Inspect :: [].{

	## `runtime_inspect`: the value `rdi` as node's util.inspect writes it at
	## the depth `rsi` (0 for console.log's own argument), a string's address
	## in `rax`. A number and `undefined`, `null` and the booleans are as
	## console.log writes them; a string is quoted ('', or "" when it holds a
	## ', with \n, \t, \\, \r, \b and \f escaped); an array or an object below
	## depth 2 is its items or its `key: value`s, on one line when node's
	## rule puts them there (fewer than 3 levels nested below it, no item
	## holding a line break, and `sum + 2n + 2 * depth + 11` at most 80, for n
	## items of sum characters) and one a line, indented, otherwise; past
	## depth 2 it is `[Array]` or `[Object]`. An array of more than 6 items
	## that node would lay out in columns, and a string holding both quotes or
	## another control byte, stop the program, not compiled yet. `[r13 + 8]`
	## is node's `currentDepth`, the depth below the last array or object
	## begun.
	items : List(Assembly.Statement)
	items = {
		dispatch = [Emit.mark("runtime_inspect")]
			.concat(RuntimeBuilders.tag_load_items(Rdi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.first_tag),
				Emit.jcc(B, "runtime_inspect_number"),
				Emit.cmp_imm(Rcx, Boxing.string_tag),
				Emit.jcc(E, "runtime_inspect_string"),
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(E, "runtime_inspect_array"),
				Emit.cmp_imm(Rcx, Boxing.object_tag),
				Emit.jcc(E, "runtime_inspect_object"),
				Emit.cmp_imm(Rcx, Boxing.function_tag),
				Emit.jcc(E, "runtime_inspect_function"),
				Emit.cmp_imm(Rcx, Boxing.collection_tag),
				Emit.jcc(E, "runtime_inspect_collection"),
				Emit.jmp("runtime_text_of"),
				Emit.mark("runtime_inspect_number"),
				Emit.mov(Rax, Rdi),
				Emit.jmp(Runtime.number_text),
				Emit.mark("runtime_inspect_string"),
			])
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.jmp("runtime_inspect_text"),
				Emit.mark("runtime_inspect_array"),
				Emit.zero(Rdx),
				Emit.jmp("runtime_inspect_list"),
				Emit.mark("runtime_inspect_object"),
				Emit.mov(Rax, Rdi),
			])
			.concat(RuntimeBuilders.unboxed_items(Rax))
			.concat([
				Emit.load(Rcx, Emit.mem(Rax, 0)),
				Emit.test(Rcx, Rcx),
				Emit.jcc(E, "runtime_inspect_plain"),
				Emit.load(Rcx, Emit.mem(Rax, 16)),
				Emit.load(Rcx, Emit.mem(Rcx, 0)),
				Emit.address_of(Rdx, RuntimeBuilders.error_mark),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(E, "runtime_inspect_error"),
				Emit.mark("runtime_inspect_plain"),
				Emit.imm(Rdx, 1),
				Emit.jmp("runtime_inspect_list"),
				# A function's text is its record's, 8 bytes in, by its distance.
				Emit.mark("runtime_inspect_function"),
			])
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.load(Rax, Emit.mem(Rdi, 8)),
				Emit.plus(Rax, Rdi),
				Emit.plus_imm(Rax, 8),
				Emit.ret,
				# A Map is listed by its entries (kind 2), a Set by its values (3).
				Emit.mark("runtime_inspect_collection"),
				Emit.mov(Rax, Rdi),
			])
			.concat(RuntimeBuilders.unboxed_items(Rax))
			.concat([
				Emit.load(Rcx, Emit.mem(Rax, 0)),
				Emit.cmp_imm(Rcx, 2),
				Emit.jcc(Ae, "runtime_iterator_written"),
				Emit.save(Rsi),
				Emit.save(Rcx),
				Emit.call(Runtime.items_of),
				Emit.mov(Rdi, Rax),
				Emit.restore(Rdx),
				Emit.plus_imm(Rdx, 2),
				Emit.restore(Rsi),
				Emit.jmp("runtime_inspect_list"),
			])
		escape_write =
			escapes
				.map(
					|(byte, letter)| {
						label = "runtime_quoted_not_${byte.to_str()}"
						[Emit.cmp_imm(Rdx, byte.to_i64()), Emit.jcc(Ne, label)]
							.concat(byte_written_items(92))
							.concat(byte_written_items(letter))
							.concat([Emit.jmp("runtime_quoted_written"), Emit.mark(label)])
					},
				)
				.join()
		# The nibble in `rax` written at `rdi` as an uppercase hex digit.
		nibble_written = |label| [
			Emit.cmp_imm(Rax, 10),
			Emit.jcc(B, "${label}_digit"),
			# 'A' - 10 - '0': past 9, the letters.
			Emit.plus_imm(Rax, 7),
			Emit.mark("${label}_digit"),
			Emit.plus_imm(Rax, '0'),
			Emit.byte_store(Emit.mem(Rdi, 0), Al),
			Emit.plus_imm(Rdi, 1),
		]
		# r9: whether a ' is in it; r10: whether a " is; r11: whether a ` or a
		# `${` is, either of which keeps node from quoting it with backticks.
		quoted = [
			Emit.mark("runtime_quoted"),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.zero(R8),
			Emit.zero(R9),
			Emit.zero(R10),
			Emit.zero(R11),
			Emit.mark("runtime_quoted_scan"),
			Emit.cmp(R8, Rcx),
			Emit.jcc(E, "runtime_quoted_scanned"),
			RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
			Emit.cmp_imm(Rax, '\''),
			Emit.jcc(Ne, "runtime_quoted_not_single"),
			Emit.imm(R9, 1),
			Emit.mark("runtime_quoted_not_single"),
			Emit.cmp_imm(Rax, '"'),
			Emit.jcc(Ne, "runtime_quoted_not_double"),
			Emit.imm(R10, 1),
			Emit.mark("runtime_quoted_not_double"),
			Emit.cmp_imm(Rax, '`'),
			Emit.jcc(Ne, "runtime_quoted_not_back"),
			Emit.imm(R11, 1),
			Emit.mark("runtime_quoted_not_back"),
			Emit.cmp_imm(Rax, '$'),
			Emit.jcc(Ne, "runtime_quoted_next"),
			Emit.lea(Rdx, Emit.mem(R8, 1)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_quoted_next"),
			Emit.byte_load(
				Rdx,
				Emit.mem_index({
					base: Rdi,
					index: Rdx,
					displacement: 8,
				}),
			),
			Emit.cmp_imm(Rdx, '{'),
			Emit.jcc(Ne, "runtime_quoted_next"),
			Emit.imm(R11, 1),
			Emit.mark("runtime_quoted_next"),
			Emit.plus_imm(R8, 1),
			Emit.jmp("runtime_quoted_scan"),
			Emit.mark("runtime_quoted_scanned"),
			# The quote, in r9, by node's rule: ', or " when a ' is in it and no
			# ", or ` when both are and neither a ` nor a `${`, else ' with each
			# ' escaped.
			Emit.test(R9, R9),
			Emit.imm(R9, '\''),
			Emit.jcc(E, "runtime_quoted_chosen"),
			Emit.test(R10, R10),
			Emit.imm(R9, '"'),
			Emit.jcc(E, "runtime_quoted_chosen"),
			Emit.test(R11, R11),
			Emit.imm(R9, '`'),
			Emit.jcc(E, "runtime_quoted_chosen"),
			Emit.imm(R9, '\''),
			Emit.mark("runtime_quoted_chosen"),
			Emit.save(Rdi),
			Emit.save(R9),
			# At most 4 bytes a byte (`\x1B`), and the quotes.
			Emit.mov(Rdi, Rcx),
			Emit.shl(Rdi, 2),
			Emit.plus_imm(Rdi, 10),
			Emit.call(Runtime.allocate),
			Emit.restore(R9),
			Emit.restore(R10),
			Emit.save(Rax),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.mov(Rax, R9),
			Emit.byte_store(Emit.mem(Rdi, 0), Al),
			Emit.plus_imm(Rdi, 1),
			Emit.load(Rcx, Emit.mem(R10, 0)),
			Emit.zero(R8),
			Emit.mark("runtime_quoted_copy"),
			Emit.cmp(R8, Rcx),
			Emit.jcc(E, "runtime_quoted_copied"),
			RuntimeBuilders.text_byte_item({ reg: Rdx, base: R10 }),
		]
			.concat(escape_write)
			.concat([
				Emit.cmp_imm(Rdx, 0x20),
				Emit.jcc(B, "runtime_quoted_hex"),
				Emit.cmp_imm(Rdx, 0x7F),
				Emit.jcc(E, "runtime_quoted_hex"),
				Emit.cmp_imm(Rdx, '\''),
				Emit.jcc(Ne, "runtime_quoted_raw"),
				Emit.cmp_imm(R9, '\''),
				Emit.jcc(Ne, "runtime_quoted_raw"),
			])
			.concat(byte_written_items(92))
			.concat([
				Emit.mark("runtime_quoted_raw"),
				Emit.mov(Rax, Rdx),
				Emit.byte_store(Emit.mem(Rdi, 0), Al),
				Emit.plus_imm(Rdi, 1),
				Emit.mark("runtime_quoted_written"),
				Emit.plus_imm(R8, 1),
				Emit.jmp("runtime_quoted_copy"),
				# Any other control byte, as node writes it: `\x1B`.
				Emit.mark("runtime_quoted_hex"),
			])
			.concat(byte_written_items(92))
			.concat(byte_written_items('x'))
			.concat([Emit.mov(Rax, Rdx), Emit.shr(Rax, 4)])
			.concat(nibble_written("runtime_quoted_high"))
			.concat([Emit.mov(Rax, Rdx), Emit.bit_and_imm(Rax, 15)])
			.concat(nibble_written("runtime_quoted_low"))
			.concat([
				Emit.jmp("runtime_quoted_written"),
				Emit.mark("runtime_quoted_copied"),
				Emit.mov(Rax, R9),
				Emit.byte_store(Emit.mem(Rdi, 0), Al),
				Emit.plus_imm(Rdi, 1),
				Emit.restore(Rax),
				Emit.mov(Rcx, Rdi),
				Emit.minus(Rcx, Rax),
				Emit.minus_imm(Rcx, 8),
				Emit.store(Emit.mem(Rax, 0), Rcx),
				Emit.ret,
			])
		in_range = |{ low, high, label }| [
			Emit.cmp_imm(Rax, low),
			Emit.jcc(B, "${label}_below"),
			Emit.cmp_imm(Rax, high),
			Emit.jcc(Be, "runtime_key_text_next"),
			Emit.mark("${label}_below"),
		]
		# A key is written bare when it is a letter or _, then letters, digits
		# and _, and quoted otherwise.
		key_text =
			[
				Emit.mark("runtime_key_text"),
				Emit.load(Rcx, Emit.mem(Rdi, 0)),
				Emit.test(Rcx, Rcx),
				Emit.jcc(E, "runtime_quoted"),
				Emit.zero(R8),
				Emit.mark("runtime_key_text_byte"),
				Emit.cmp(R8, Rcx),
				Emit.jcc(E, "runtime_key_text_bare"),
				RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
				Emit.cmp_imm(Rax, '_'),
				Emit.jcc(E, "runtime_key_text_next"),
			]
				.concat(
					in_range({
						low: 'a',
						high: 'z',
						label: "runtime_key_text_lower",
					}),
				)
				.concat(
					in_range({
						low: 'A',
						high: 'Z',
						label: "runtime_key_text_upper",
					}),
				)
				.concat([Emit.test(R8, R8), Emit.jcc(E, "runtime_quoted")])
				.concat(
					in_range({
						low: '0',
						high: '9',
						label: "runtime_key_text_digit",
					}),
				)
				.concat([
					Emit.jmp("runtime_quoted"),
					Emit.mark("runtime_key_text_next"),
					Emit.plus_imm(R8, 1),
					Emit.jmp("runtime_key_text_byte"),
					Emit.mark("runtime_key_text_bare"),
					Emit.mov(Rax, Rdi),
					Emit.ret,
				])
		# A string inside an array or an object that holds a line break and is
		# longer than 16 and than the line left (76 less the indentation, two
		# spaces a depth) is written as node writes it: a quoted piece a line,
		# each ending at a line break, joined with ` +` and a line indented two
		# past the depth's. Its frame holds the string (8), the depth (16), the
		# joint (24), the piece's start (32), the place (40) and the text so far
		# (48, 0 before the first piece).
		text = [
			Emit.mark("runtime_inspect_text"),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.cmp_imm(Rcx, 16),
			Emit.jcc(Be, "runtime_quoted"),
			Emit.mov(Rax, Rsi),
			Emit.plus(Rax, Rax),
			Emit.plus(Rax, Rcx),
			Emit.cmp_imm(Rax, 76),
			Emit.jcc(Be, "runtime_quoted"),
			Emit.zero(R8),
			Emit.mark("runtime_inspect_text_scan"),
			Emit.cmp(R8, Rcx),
			Emit.jcc(E, "runtime_quoted"),
			RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
			Emit.cmp_imm(Rax, 10),
			Emit.jcc(E, "runtime_inspect_text_split"),
			Emit.plus_imm(R8, 1),
			Emit.jmp("runtime_inspect_text_scan"),
			Emit.mark("runtime_inspect_text_split"),
			Emit.save(Rbp),
			Emit.mov(Rbp, Rsp),
			Emit.minus_imm(Rsp, 48),
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rsi),
			Emit.mov(Rdi, Rsi),
			Emit.plus(Rdi, Rdi),
			Emit.plus_imm(Rdi, 2),
			Emit.store(RuntimeBuilders.local(24), Rdi),
			Emit.plus_imm(Rdi, 11),
			Emit.call(Runtime.allocate),
			Emit.load(Rcx, RuntimeBuilders.local(24)),
			Emit.lea(Rdx, Emit.mem(Rcx, 3)),
			Emit.store(Emit.mem(Rax, 0), Rdx),
			Emit.store(RuntimeBuilders.local(24), Rax),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
		]
			.concat(byte_written_items(' '))
			.concat(byte_written_items('+'))
			.concat(byte_written_items('\n'))
			.concat([
				Emit.mov(R9, Rcx),
				Emit.mark("runtime_inspect_text_spaces"),
				Emit.test(R9, R9),
				Emit.jcc(E, "runtime_inspect_text_joint"),
			])
			.concat(byte_written_items(' '))
			.concat([
				Emit.minus_imm(R9, 1),
				Emit.jmp("runtime_inspect_text_spaces"),
				Emit.mark("runtime_inspect_text_joint"),
				Emit.zero(Rax),
				Emit.store(RuntimeBuilders.local(32), Rax),
				Emit.store(RuntimeBuilders.local(40), Rax),
				Emit.store(RuntimeBuilders.local(48), Rax),
				Emit.mark("runtime_inspect_text_next"),
				Emit.load(Rdi, RuntimeBuilders.local(8)),
				Emit.load(Rcx, Emit.mem(Rdi, 0)),
				Emit.load(R8, RuntimeBuilders.local(40)),
				Emit.cmp(R8, Rcx),
				Emit.jcc(E, "runtime_inspect_text_last"),
				RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
				Emit.plus_imm(R8, 1),
				Emit.store(RuntimeBuilders.local(40), R8),
				Emit.cmp_imm(Rax, 10),
				Emit.jcc(Ne, "runtime_inspect_text_next"),
				Emit.call("runtime_inspect_piece"),
				Emit.jmp("runtime_inspect_text_next"),
				Emit.mark("runtime_inspect_text_last"),
				Emit.load(Rax, RuntimeBuilders.local(32)),
				Emit.cmp(Rax, R8),
				Emit.jcc(E, "runtime_inspect_text_done"),
				Emit.call("runtime_inspect_piece"),
				Emit.mark("runtime_inspect_text_done"),
				Emit.load(Rax, RuntimeBuilders.local(48)),
				Emit.mov(Rsp, Rbp),
				Emit.restore(Rbp),
				Emit.ret,
				# The piece from the start to the place, quoted and joined on;
				# called in the frame above, whose `rbp` it keeps.
				Emit.mark("runtime_inspect_piece"),
				Emit.load(Rdx, RuntimeBuilders.local(40)),
				Emit.load(Rsi, RuntimeBuilders.local(32)),
				Emit.minus(Rdx, Rsi),
				Emit.save(Rdx),
				Emit.lea(Rdi, Emit.mem(Rdx, 8)),
				Emit.call(Runtime.allocate),
				Emit.restore(Rcx),
				Emit.store(Emit.mem(Rax, 0), Rcx),
				Emit.lea(Rdi, Emit.mem(Rax, 8)),
				Emit.load(R10, RuntimeBuilders.local(8)),
				Emit.load(Rsi, RuntimeBuilders.local(32)),
				Emit.lea(
					Rsi,
					Emit.mem_index({
						base: R10,
						index: Rsi,
						displacement: 8,
					}),
				),
				Emit.save(Rax),
				Instruction(RepMovsb),
				Emit.restore(Rdi),
				Emit.load(Rax, RuntimeBuilders.local(40)),
				Emit.store(RuntimeBuilders.local(32), Rax),
				Emit.call("runtime_quoted"),
				Emit.load(Rdi, RuntimeBuilders.local(48)),
				Emit.test(Rdi, Rdi),
				Emit.jcc(E, "runtime_inspect_piece_first"),
				Emit.save(Rax),
				Emit.load(Rsi, RuntimeBuilders.local(24)),
				Emit.call("runtime_concat"),
				Emit.mov(Rdi, Rax),
				Emit.restore(Rsi),
				Emit.call("runtime_concat"),
				Emit.mark("runtime_inspect_piece_first"),
				Emit.store(RuntimeBuilders.local(48), Rax),
				Emit.ret,
			])
		[dispatch, quoted, text, key_text, list_items].join()
	}
}

## The statements that write the byte `value` at `rdi` and step past it.
## They change `rax`.
byte_written_items : U8 -> List(Assembly.Statement)
byte_written_items = |value| [
	Emit.imm(Rax, value.to_i64()),
	Emit.byte_store(Emit.mem(Rdi, 0), Al),
	Emit.plus_imm(Rdi, 1),
]

## The statements that write `r9` spaces at `rdi`; `label` names their loop.
spaces_written_items : Str -> List(Assembly.Statement)
spaces_written_items = |label|
	[
		Emit.mark(label),
		Emit.test(R9, R9),
		Emit.jcc(E, "${label}_done"),
	]
		.concat(byte_written_items(' '))
		.concat([
			Emit.minus_imm(R9, 1),
			Emit.jmp(label),
			Emit.mark("${label}_done"),
		])

## The statements that copy entry `r11` of the list at `[rbp - 40]` to
## `rdi`. They change `rcx`, `rsi`, `r8` and `r9`.
entry_copied_items : List(Assembly.Statement)
entry_copied_items = [
	Emit.load(R8, Emit.mem(Rbp, -40)),
	Emit.mov(R9, R11),
	Emit.shl(R9, 3),
	Emit.plus(R8, R9),
	Emit.load(Rsi, Emit.mem(R8, 0)),
	Emit.load(Rcx, Emit.mem(Rsi, 0)),
	Emit.plus_imm(Rsi, 8),
	Instruction(RepMovsb),
]

## The statements that write a Map's or a Set's name and size, `Map(2) `,
## at `rdi` before its brace, from `[rbp - 328]`; `label` names their join.
name_written_items : Str -> List(Assembly.Statement)
name_written_items = |label| [
	Emit.load(Rsi, Emit.mem(Rbp, -328)),
	Emit.test(Rsi, Rsi),
	Emit.jcc(E, label),
	Emit.load(Rcx, Emit.mem(Rsi, 0)),
	Emit.plus_imm(Rsi, 8),
	Instruction(RepMovsb),
	Emit.mark(label),
]

## The statements that write the list's brace, `[` for an array (`[rbp -
## 24]` 0) or `{` for an object, or the closing one; `label` names their
## join.
brace_written_items : {
	label : Str,
	array : U8,
	object : U8,
} -> List(Assembly.Statement)
brace_written_items = |{ label, array, object }| [
	Emit.imm(Rax, array.to_i64()),
	Emit.load(Rcx, Emit.mem(Rbp, -24)),
	Emit.test(Rcx, Rcx),
	Emit.jcc(E, label),
	Emit.imm(Rax, object.to_i64()),
	Emit.mark(label),
	Emit.byte_store(Emit.mem(Rdi, 0), Al),
	Emit.plus_imm(Rdi, 1),
]

## A byte a string escapes inside an array or an object, and the letter
## after its backslash, as node writes them.
escapes : List((U8, U8))
escapes = [
	(10, 'n'),
	(9, 't'),
	(92, 92),
	(13, 'r'),
	(8, 'b'),
	(12, 'f'),
]

## `runtime_inspect_list`: the array or object at `rdi` (`rdx` 0 for an
## array, 1 for an object) at the depth `rsi`, by `runtime_inspect`'s rule.
## Its frame holds the list (`[rbp - 8]`), the depth (16), the kind (24),
## the count (32), the entries' texts (40), the next entry (48), the sum of
## their lengths (56), the longest (64), whether one holds a line break
## (72) and the result (80).
list_items : List(Assembly.Statement)
list_items = {
	start = [
		Emit.mark("runtime_inspect_list"),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, list_frame_size),
	]
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rsi),
			Emit.store(RuntimeBuilders.local(24), Rdx),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.store(RuntimeBuilders.local(32), Rcx),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_inspect_empty"),
			Emit.cmp_imm(Rsi, 2),
			Emit.jcc(A, "runtime_inspect_deep"),
			Emit.cmp_imm(Rcx, 100),
			Emit.jcc(A, "runtime_inspect_many"),
			# A Map's or a Set's braces are after its name and size,
			# `Map(2) `, at [rbp - 328]; 0 for an array or an object.
			Emit.zero(Rax),
			Emit.store(RuntimeBuilders.local(328), Rax),
			Emit.cmp_imm(Rdx, 2),
			Emit.jcc(B, "runtime_inspect_named"),
			Emit.address_of(Rdi, "runtime_text_map_open"),
			Emit.cmp_imm(Rdx, 2),
			Emit.jcc(E, "runtime_inspect_name"),
			Emit.address_of(Rdi, "runtime_text_set_open"),
			Emit.mark("runtime_inspect_name"),
			Emit.save(Rdi),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rcx })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.call(Runtime.number_text),
			Emit.mov(Rsi, Rax),
			Emit.restore(Rdi),
			Emit.call("runtime_concat"),
			Emit.mov(Rdi, Rax),
			Emit.address_of(Rsi, "runtime_text_size_close"),
			Emit.call("runtime_concat"),
			Emit.store(RuntimeBuilders.local(328), Rax),
			Emit.load(Rcx, RuntimeBuilders.local(32)),
			Emit.load(Rsi, RuntimeBuilders.local(16)),
			Emit.mark("runtime_inspect_named"),
			Emit.lea(Rax, Emit.mem(Rsi, 1)),
			Emit.store(Emit.mem(R13, 8), Rax),
			Emit.mov(Rdi, Rcx),
			Emit.shl(Rdi, 3),
			Emit.call(Runtime.allocate),
			Emit.store(RuntimeBuilders.local(40), Rax),
			Emit.zero(Rax),
			Emit.store(RuntimeBuilders.local(48), Rax),
			Emit.store(RuntimeBuilders.local(56), Rax),
			Emit.store(RuntimeBuilders.local(64), Rax),
			Emit.store(RuntimeBuilders.local(72), Rax),
		])
	entries = [
		Emit.mark("runtime_inspect_entry"),
		Emit.load(Rcx, RuntimeBuilders.local(48)),
		Emit.load(Rdx, RuntimeBuilders.local(32)),
		Emit.cmp(Rcx, Rdx),
		Emit.jcc(E, "runtime_inspect_measured"),
		Emit.load(R8, RuntimeBuilders.local(8)),
		Emit.load(R9, Emit.mem(R8, 16)),
		Emit.load(Rax, RuntimeBuilders.local(24)),
		Emit.cmp_imm(Rax, 1),
		Emit.jcc(E, "runtime_inspect_property"),
		Emit.cmp_imm(Rax, 2),
		Emit.jcc(E, "runtime_inspect_pair"),
		Emit.shl(Rcx, 3),
		Emit.plus(R9, Rcx),
		Emit.load(Rdi, Emit.mem(R9, 0)),
		Emit.load(Rsi, RuntimeBuilders.local(16)),
		Emit.plus_imm(Rsi, 1),
		Emit.call("runtime_inspect"),
		Emit.jmp("runtime_inspect_store"),
		Emit.mark("runtime_inspect_property"),
		Emit.shl(Rcx, 4),
		Emit.plus(R9, Rcx),
		Emit.save(R9),
		Emit.load(Rdi, Emit.mem(R9, 0)),
		Emit.call("runtime_key_text"),
		Emit.mov(Rdi, Rax),
		Emit.address_of(Rsi, "runtime_text_colon"),
		Emit.call("runtime_concat"),
		Emit.restore(R9),
		Emit.save(Rax),
		Emit.load(Rdi, Emit.mem(R9, 8)),
		Emit.load(Rsi, RuntimeBuilders.local(16)),
		Emit.plus_imm(Rsi, 1),
		Emit.call("runtime_inspect"),
		Emit.mov(Rsi, Rax),
		Emit.restore(Rdi),
		Emit.call("runtime_concat"),
		Emit.jmp("runtime_inspect_store"),
		# A Map's entry, `key => value`, from its array of the two.
		Emit.mark("runtime_inspect_pair"),
		Emit.shl(Rcx, 3),
		Emit.plus(R9, Rcx),
		Emit.load(R9, Emit.mem(R9, 0)),
		Emit.shl(R9, 16),
		Emit.shr(R9, 16),
		Emit.load(R9, Emit.mem(R9, 16)),
		Emit.save(R9),
		Emit.load(Rdi, Emit.mem(R9, 0)),
		Emit.load(Rsi, RuntimeBuilders.local(16)),
		Emit.plus_imm(Rsi, 1),
		Emit.call("runtime_inspect"),
		Emit.mov(Rdi, Rax),
		Emit.address_of(Rsi, "runtime_text_arrow"),
		Emit.call("runtime_concat"),
		Emit.restore(R9),
		Emit.save(Rax),
		Emit.load(Rdi, Emit.mem(R9, 8)),
		Emit.load(Rsi, RuntimeBuilders.local(16)),
		Emit.plus_imm(Rsi, 1),
		Emit.call("runtime_inspect"),
		Emit.mov(Rsi, Rax),
		Emit.restore(Rdi),
		Emit.call("runtime_concat"),
		Emit.mark("runtime_inspect_store"),
		Emit.load(Rcx, RuntimeBuilders.local(48)),
		Emit.load(R8, RuntimeBuilders.local(40)),
		Emit.mov(R9, Rcx),
		Emit.shl(R9, 3),
		Emit.plus(R8, R9),
		Emit.store(Emit.mem(R8, 0), Rax),
		Emit.load(Rdx, Emit.mem(Rax, 0)),
		Emit.load(R8, RuntimeBuilders.local(56)),
		Emit.plus(R8, Rdx),
		Emit.store(RuntimeBuilders.local(56), R8),
		Emit.load(R8, RuntimeBuilders.local(64)),
		Emit.cmp(Rdx, R8),
		Emit.jcc(Be, "runtime_inspect_not_longest"),
		Emit.store(RuntimeBuilders.local(64), Rdx),
		Emit.mark("runtime_inspect_not_longest"),
		Emit.zero(R8),
		Emit.mark("runtime_inspect_break_scan"),
		Emit.cmp(R8, Rdx),
		Emit.jcc(E, "runtime_inspect_scanned"),
		RuntimeBuilders.text_byte_item({ reg: R9, base: Rax }),
		Emit.cmp_imm(R9, 10),
		Emit.jcc(Ne, "runtime_inspect_no_break"),
		Emit.imm(R9, 1),
		Emit.store(RuntimeBuilders.local(72), R9),
		Emit.mark("runtime_inspect_no_break"),
		Emit.plus_imm(R8, 1),
		Emit.jmp("runtime_inspect_break_scan"),
		Emit.mark("runtime_inspect_scanned"),
		Emit.plus_imm(Rcx, 1),
		Emit.store(RuntimeBuilders.local(48), Rcx),
		Emit.jmp("runtime_inspect_entry"),
	]
	# rcx: the count; r10: the indentation, two spaces a level.
	measured = [
		Emit.mark("runtime_inspect_measured"),
		Emit.load(Rcx, RuntimeBuilders.local(32)),
		Emit.load(R10, RuntimeBuilders.local(16)),
		Emit.plus(R10, R10),
		Emit.load(Rax, RuntimeBuilders.local(24)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_inspect_ungrouped"),
		Emit.cmp_imm(Rcx, 6),
		Emit.jcc(Be, "runtime_inspect_ungrouped"),
		# Node groups an array of more than 6 items into columns when three
		# of its longest fit a line and its items are alike in length.
		Emit.load(R11, RuntimeBuilders.local(56)),
		Emit.plus(R11, Rcx),
		Emit.plus(R11, Rcx),
		Emit.load(R9, RuntimeBuilders.local(64)),
		Emit.plus_imm(R9, 2),
		Emit.mov(Rax, R9),
		Emit.plus(Rax, R9),
		Emit.plus(Rax, R9),
		Emit.plus(Rax, R10),
		Emit.cmp_imm(Rax, 80),
		Emit.jcc(Ae, "runtime_inspect_ungrouped"),
		Emit.load(Rax, RuntimeBuilders.local(64)),
		Emit.cmp_imm(Rax, 6),
		Emit.jcc(Be, "runtime_columns"),
		Emit.mov(Rax, R9),
		Emit.shl(Rax, 2),
		Emit.plus(Rax, R9),
		Emit.cmp(R11, Rax),
		Emit.jcc(A, "runtime_columns"),
		Emit.mark("runtime_inspect_ungrouped"),
		Emit.load(Rax, Emit.mem(R13, 8)),
		Emit.load(R8, RuntimeBuilders.local(16)),
		Emit.plus_imm(R8, 4),
		Emit.cmp(Rax, R8),
		Emit.jcc(Ae, "runtime_inspect_lines"),
		Emit.load(Rax, RuntimeBuilders.local(72)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_inspect_lines"),
		Emit.load(Rax, RuntimeBuilders.local(56)),
		Emit.plus(Rax, Rcx),
		Emit.plus(Rax, Rcx),
		Emit.plus(Rax, R10),
		Emit.plus_imm(Rax, 11),
		Emit.load(R8, RuntimeBuilders.local(328)),
		Emit.test(R8, R8),
		Emit.jcc(E, "runtime_inspect_unnamed"),
		Emit.load(R8, Emit.mem(R8, 0)),
		Emit.plus(Rax, R8),
		Emit.mark("runtime_inspect_unnamed"),
		Emit.cmp_imm(Rax, 80),
		Emit.jcc(A, "runtime_inspect_lines"),
	]
	# The result's room: the texts, and for each a separator, a line break
	# and the indentation, and the braces.
	room = |label| [
		Emit.mark(label),
		Emit.mov(Rdi, R10),
		Emit.plus_imm(Rdi, 4),
		Instruction(Imul({ to: Rdi, from: Rcx })),
		Emit.load(Rax, RuntimeBuilders.local(56)),
		Emit.plus(Rdi, Rax),
		Emit.plus(Rdi, R10),
		# The braces, and a Map's or a Set's name and size.
		Emit.plus_imm(Rdi, 40),
		Emit.save(R10),
		Emit.call(Runtime.allocate),
		Emit.restore(R10),
		Emit.store(RuntimeBuilders.local(80), Rax),
		Emit.lea(Rdi, Emit.mem(Rax, 8)),
		Emit.zero(R11),
	]
	one_line =
		room("runtime_inspect_one_line")
			.concat(name_written_items("runtime_inspect_one_named"))
			.concat(
				brace_written_items({
					label: "runtime_inspect_one_open",
					array: '[',
					object: '{',
				}),
			)
			.concat(byte_written_items(' '))
			.concat([
				Emit.mark("runtime_inspect_one_next"),
				Emit.load(Rcx, RuntimeBuilders.local(32)),
				Emit.cmp(R11, Rcx),
				Emit.jcc(E, "runtime_inspect_one_done"),
				Emit.test(R11, R11),
				Emit.jcc(E, "runtime_inspect_one_first"),
			])
			.concat(byte_written_items(','))
			.concat(byte_written_items(' '))
			.append(Emit.mark("runtime_inspect_one_first"))
			.concat(entry_copied_items)
			.concat([
				Emit.plus_imm(R11, 1),
				Emit.jmp("runtime_inspect_one_next"),
				Emit.mark("runtime_inspect_one_done"),
			])
			.concat(byte_written_items(' '))
			.concat(
				brace_written_items({
					label: "runtime_inspect_one_close",
					array: ']',
					object: '}',
				}),
			)
			.append(Emit.jmp("runtime_inspect_finish"))
	lines =
		room("runtime_inspect_lines")
			.concat(name_written_items("runtime_inspect_lines_named"))
			.concat(
				brace_written_items({
					label: "runtime_inspect_lines_open",
					array: '[',
					object: '{',
				}),
			)
			.concat([
				Emit.mark("runtime_inspect_lines_next"),
				Emit.load(Rcx, RuntimeBuilders.local(32)),
				Emit.cmp(R11, Rcx),
				Emit.jcc(E, "runtime_inspect_lines_done"),
				Emit.test(R11, R11),
				Emit.jcc(E, "runtime_inspect_lines_first"),
			])
			.concat(byte_written_items(','))
			.append(Emit.mark("runtime_inspect_lines_first"))
			.concat(byte_written_items('\n'))
			.concat([Emit.mov(R9, R10), Emit.plus_imm(R9, 2)])
			.concat(spaces_written_items("runtime_inspect_lines_indent"))
			.concat(entry_copied_items)
			.concat([
				Emit.plus_imm(R11, 1),
				Emit.jmp("runtime_inspect_lines_next"),
				Emit.mark("runtime_inspect_lines_done"),
			])
			.concat(byte_written_items('\n'))
			.append(Emit.mov(R9, R10))
			.concat(spaces_written_items("runtime_inspect_lines_outdent"))
			.concat(
				brace_written_items({
					label: "runtime_inspect_lines_close",
					array: ']',
					object: '}',
				}),
			)
	finish = [
		Emit.mark("runtime_inspect_finish"),
		Emit.load(Rax, RuntimeBuilders.local(80)),
		Emit.mov(Rcx, Rdi),
		Emit.minus(Rcx, Rax),
		Emit.minus_imm(Rcx, 8),
		Emit.store(Emit.mem(Rax, 0), Rcx),
		Emit.mark("runtime_inspect_leave"),
		Emit.mov(Rsp, Rbp),
		Emit.restore(Rbp),
		Emit.ret,
	]
	fixed = |{ label, kinds_texts }| {
		var $out = [Emit.mark(label), Emit.load(Rcx, RuntimeBuilders.local(24))]
		for (kind, text) in kinds_texts.map_with_index(|text, kind| (kind, text)) {
			$out = $out.concat([
				Emit.address_of(Rax, text),
				Emit.cmp_imm(Rcx, kind.to_i64_wrap()),
				Emit.jcc(E, "runtime_inspect_leave"),
			])
		}
		$out
	}
	[
		start,
		entries,
		measured,
		one_line,
		lines,
		finish,
		fixed({
			label: "runtime_inspect_empty",
			kinds_texts: [
				"runtime_text_empty_array",
				"runtime_text_empty_object",
				"runtime_text_empty_map",
				"runtime_text_empty_set",
			],
		}),
		fixed({
			label: "runtime_inspect_deep",
			kinds_texts: [
				"runtime_text_deep_array",
				"runtime_text_deep_object",
				"runtime_text_deep_map",
				"runtime_text_deep_set",
			],
		}),
		columns_items,
		[Emit.mark("runtime_inspect_many")],
		RuntimeBuilders.stopping_items("runtime_text_many"),
	]
		.join()
}

## The bytes of `runtime_inspect_list`'s frame: its own places, then
## `runtime_columns`', with the widest columns' 12 places last.
list_frame_size : I64
list_frame_size = 336

## `runtime_columns`: node's `groupArrayElements`, for an array of more than
## 6 items whose texts `runtime_inspect_list` has made and measured, and
## that node's test lets be grouped. With n items, the longest `max` long
## and `total` their lengths plus 2 each, `actual` is `max + 2`, the bias
## `sqrt(actual - total / n)`, `biased` is `actual - 3 - bias` (at least 1),
## and the columns are the least of `round(sqrt(2.5 * biased * n) /
## biased)`, `floor((80 - indentation) / actual)`, 12 (node's `compact`, 3,
## times 4) and 15. One column or none leaves the items as they were.
## Otherwise each row is its items, each padded to its column's widest, on
## the left when every item is a number and on the right otherwise, `, `
## between; the rows take the entries' place in the frame and are written
## one a line, as `runtime_inspect_lines` writes entries.
columns_items : List(Assembly.Statement)
columns_items = {
	columns = RuntimeBuilders.local(88)
	numbers_only = RuntimeBuilders.local(96)
	rows = RuntimeBuilders.local(104)
	row_start = RuntimeBuilders.local(112)
	row_count = RuntimeBuilders.local(120)
	rows_length = RuntimeBuilders.local(128)
	item = RuntimeBuilders.local(144)
	row_end = RuntimeBuilders.local(152)
	row = RuntimeBuilders.local(160)
	row_length = RuntimeBuilders.local(168)
	written_row = RuntimeBuilders.local(176)
	# The widest of column c is at [rbp + 8c - 304].
	widest = |reg| Based({
		base: Rbp,
		index: Scaled({ reg, scale: Times8 }),
		displacement: (0 - list_frame_size + 16).to_i32_wrap(),
	})
	# The length of entry `reg`'s text, in `rax`.
	text_length = |reg| [
		Emit.load(R8, RuntimeBuilders.local(40)),
		Emit.load(Rax, RuntimeBuilders.listed_item(reg)),
		Emit.load(Rax, Emit.mem(Rax, 0)),
	]
	counted = [
		Emit.mark("runtime_columns"),
		Emit.load(Rcx, RuntimeBuilders.local(32)),
		Emit.load(R9, RuntimeBuilders.local(64)),
		Emit.plus_imm(R9, 2),
		Emit.load(R11, RuntimeBuilders.local(56)),
		Emit.plus(R11, Rcx),
		Emit.plus(R11, Rcx),
		Instruction(Cvtsi2sd({ to: Xmm0, from: R9 })),
		Instruction(Cvtsi2sd({ to: Xmm1, from: R11 })),
		Instruction(Cvtsi2sd({ to: Xmm2, from: Rcx })),
		Emit.double_quotient(Xmm1, Xmm2),
		Emit.double_copy(Xmm3, Xmm0),
		Emit.double_difference(Xmm3, Xmm1),
		Emit.square_root(Xmm1, Xmm3),
	]
		.concat(RuntimeBuilders.double_items({ to: Xmm2, value: 3.0 }))
		.concat([Emit.double_difference(Xmm0, Xmm2), Emit.double_difference(Xmm0, Xmm1)])
		.concat(RuntimeBuilders.double_items({ to: Xmm2, value: 1.0 }))
		.concat([
			Instruction(Ucomisd({ left: Xmm0, right: Xmm2 })),
			Emit.jcc(Ae, "runtime_columns_biased"),
			Emit.double_copy(Xmm0, Xmm2),
			Emit.mark("runtime_columns_biased"),
		])
		.concat(RuntimeBuilders.double_items({ to: Xmm1, value: 2.5 }))
		.concat([
			Emit.double_product(Xmm1, Xmm0),
			Instruction(Cvtsi2sd({ to: Xmm2, from: Rcx })),
			Emit.double_product(Xmm2, Xmm1),
			Emit.square_root(Xmm3, Xmm2),
			Emit.double_quotient(Xmm3, Xmm0),
		])
		# Rounded half up: the answer is positive, so a truncation of it plus
		# a half.
		.concat(RuntimeBuilders.double_items({ to: Xmm2, value: 0.5 }))
		.concat([
			Emit.double_sum(Xmm3, Xmm2),
			Instruction(Cvttsd2si({ to: R8, from: Xmm3 })),
			Emit.load(R10, RuntimeBuilders.local(16)),
			Emit.plus(R10, R10),
			Emit.imm(Rax, 80),
			Emit.minus(Rax, R10),
			Emit.zero(Rdx),
			Instruction(Div(R9)),
			Emit.cmp(R8, Rax),
			Emit.jcc(Le, "runtime_columns_fit"),
			Emit.mov(R8, Rax),
			Emit.mark("runtime_columns_fit"),
			Emit.cmp_imm(R8, 12),
			Emit.jcc(Le, "runtime_columns_compact"),
			Emit.imm(R8, 12),
			Emit.mark("runtime_columns_compact"),
			Emit.cmp_imm(R8, 1),
			Emit.jcc(Le, "runtime_inspect_ungrouped"),
			Emit.store(columns, R8),
		])
	# Each column's widest, and whether every item is a number.
	measured = [
		Emit.zero(R9),
		Emit.mark("runtime_columns_cleared"),
		Emit.zero(Rax),
		Emit.store(widest(R9), Rax),
		Emit.plus_imm(R9, 1),
		Emit.cmp_imm(R9, 12),
		Emit.jcc(B, "runtime_columns_cleared"),
		Emit.zero(R9),
		Emit.zero(R11),
		Emit.mark("runtime_columns_widest"),
		Emit.load(Rcx, RuntimeBuilders.local(32)),
		Emit.cmp(R11, Rcx),
		Emit.jcc(E, "runtime_columns_widened"),
	]
		.concat(text_length(R11))
		.concat([
			Emit.load(Rdx, widest(R9)),
			Emit.cmp(Rax, Rdx),
			Emit.jcc(Be, "runtime_columns_narrower"),
			Emit.store(widest(R9), Rax),
			Emit.mark("runtime_columns_narrower"),
			Emit.plus_imm(R9, 1),
			Emit.load(Rdx, columns),
			Emit.cmp(R9, Rdx),
			Emit.jcc(B, "runtime_columns_same_row"),
			Emit.zero(R9),
			Emit.mark("runtime_columns_same_row"),
			Emit.plus_imm(R11, 1),
			Emit.jmp("runtime_columns_widest"),
			Emit.mark("runtime_columns_widened"),
			Emit.imm(Rax, 1),
			Emit.store(numbers_only, Rax),
			Emit.load(Rdi, RuntimeBuilders.local(8)),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.zero(R11),
			Emit.mark("runtime_columns_kinds"),
			Emit.cmp(R11, Rcx),
			Emit.jcc(E, "runtime_columns_kinded"),
			Emit.load(Rax, RuntimeBuilders.listed_item(R11)),
			Emit.shr(Rax, Boxing.tag_shift),
			Emit.plus_imm(R11, 1),
			Emit.cmp_imm(Rax, Boxing.first_tag),
			Emit.jcc(B, "runtime_columns_kinds"),
			Emit.zero(Rax),
			Emit.store(numbers_only, Rax),
			Emit.mark("runtime_columns_kinded"),
			# The rows: as many as the columns go into the items, rounded up.
			Emit.mov(Rax, Rcx),
			Emit.load(R8, columns),
			Emit.plus(Rax, R8),
			Emit.minus_imm(Rax, 1),
			Emit.zero(Rdx),
			Instruction(Div(R8)),
			Emit.store(row_count, Rax),
			Emit.mov(Rdi, Rax),
			Emit.shl(Rdi, 3),
			Emit.call(Runtime.allocate),
			Emit.store(rows, Rax),
			Emit.zero(Rax),
			Emit.store(row_start, Rax),
			Emit.store(row, Rax),
			Emit.store(rows_length, Rax),
		])
	# A row's length: each item's column's widest and its `, `, but for the
	# last item's `, ` (padded on the left), or all of the last but its own
	# length (on the right).
	row_measured = [
		Emit.mark("runtime_columns_row"),
		Emit.load(Rax, row),
		Emit.load(Rcx, row_count),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(E, "runtime_columns_done"),
		Emit.load(Rax, row_start),
		Emit.load(Rcx, columns),
		Emit.plus(Rax, Rcx),
		Emit.load(Rcx, RuntimeBuilders.local(32)),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Be, "runtime_columns_row_ended"),
		Emit.mov(Rax, Rcx),
		Emit.mark("runtime_columns_row_ended"),
		Emit.store(row_end, Rax),
		Emit.zero(R10),
		Emit.load(R11, row_start),
		Emit.zero(R9),
		Emit.mark("runtime_columns_length_next"),
		Emit.load(Rdx, widest(R9)),
		Emit.plus(R10, Rdx),
		Emit.plus_imm(R10, 2),
		Emit.plus_imm(R11, 1),
		Emit.plus_imm(R9, 1),
		Emit.load(Rax, row_end),
		Emit.cmp(R11, Rax),
		Emit.jcc(B, "runtime_columns_length_next"),
		Emit.minus_imm(R10, 2),
		Emit.load(Rax, numbers_only),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_columns_length_done"),
		Emit.minus(R10, Rdx),
		Emit.minus_imm(R11, 1),
	]
		.concat(text_length(R11))
		.concat([
			Emit.plus(R10, Rax),
			Emit.mark("runtime_columns_length_done"),
			Emit.store(row_length, R10),
			Emit.lea(Rdi, Emit.mem(R10, 8)),
			Emit.call(Runtime.allocate),
			Emit.load(R10, row_length),
			Emit.store(Emit.mem(Rax, 0), R10),
			Emit.store(written_row, Rax),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.load(R11, row_start),
			Emit.store(item, R11),
		])
	# Each item: its padding, its text and its `, ` on the left; its text,
	# its `, ` and its padding on the right.
	padding = |label| [
		Emit.load(R11, item),
		Emit.load(R9, row_start),
		Emit.mov(Rcx, R11),
		Emit.minus(Rcx, R9),
	]
		.concat(text_length(R11))
		.concat([Emit.load(R9, widest(Rcx)), Emit.minus(R9, Rax)])
		.concat(spaces_written_items(label))
	separator = |label|
		[
			Emit.load(R11, item),
			Emit.plus_imm(R11, 1),
			Emit.load(Rax, row_end),
			Emit.cmp(R11, Rax),
			Emit.jcc(E, label),
		]
			.concat(byte_written_items(','))
			.concat(byte_written_items(' '))
	text = [
		Emit.load(R11, item),
		Emit.load(R8, RuntimeBuilders.local(40)),
		Emit.load(Rsi, RuntimeBuilders.listed_item(R11)),
		Emit.load(Rcx, Emit.mem(Rsi, 0)),
		Emit.plus_imm(Rsi, 8),
		Instruction(RepMovsb),
	]
	cells =
		[
			Emit.mark("runtime_columns_item"),
			Emit.load(Rax, numbers_only),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_columns_on_the_right"),
		]
			.concat(padding("runtime_columns_left_pad"))
			.concat(text)
			.concat(separator("runtime_columns_item_written"))
			.append(Emit.jmp("runtime_columns_item_written"))
			.append(Emit.mark("runtime_columns_on_the_right"))
			.concat(text)
			.concat(separator("runtime_columns_item_written"))
			.concat(padding("runtime_columns_right_pad"))
			.concat([
				Emit.mark("runtime_columns_item_written"),
				Emit.load(R11, item),
				Emit.plus_imm(R11, 1),
				Emit.store(item, R11),
				Emit.load(Rax, row_end),
				Emit.cmp(R11, Rax),
				Emit.jcc(B, "runtime_columns_item"),
				Emit.load(R8, rows),
				Emit.load(R11, row),
				Emit.load(Rax, written_row),
				Emit.store(RuntimeBuilders.listed_item(R11), Rax),
				Emit.load(Rax, rows_length),
				Emit.load(Rcx, row_length),
				Emit.plus(Rax, Rcx),
				Emit.store(rows_length, Rax),
				Emit.plus_imm(R11, 1),
				Emit.store(row, R11),
				Emit.load(Rax, row_end),
				Emit.store(row_start, Rax),
				Emit.jmp("runtime_columns_row"),
			])
	done = [
		Emit.mark("runtime_columns_done"),
		Emit.load(Rax, rows),
		Emit.store(RuntimeBuilders.local(40), Rax),
		Emit.load(Rcx, row_count),
		Emit.store(RuntimeBuilders.local(32), Rcx),
		Emit.load(Rax, rows_length),
		Emit.store(RuntimeBuilders.local(56), Rax),
		Emit.load(R10, RuntimeBuilders.local(16)),
		Emit.plus(R10, R10),
		Emit.jmp("runtime_inspect_lines"),
	]
	[counted, measured, row_measured, cells, done].join()
}
