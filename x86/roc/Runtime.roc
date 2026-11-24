## This module holds the machine code every compiled program carries beside
## its own: the start, which maps the heap; the bump allocator; buffered
## output; the stops (a message to stderr and exit 1); and `console.log`'s
## writing of a number. Each piece is a list of `Assembly` statements under
## labels that start `runtime_`, which no function of the program's takes, so
## the program's code calls them by name.
##
## **FOUR REGISTERS ARE THE RUNTIME'S FOR THE WHOLE RUN**, and no other code
## writes them: `r12` holds the lowest the stack may reach, `r13` the
## runtime's state (the output buffer's fill, then the buffer), `r14` the
## heap's end and `r15` the next free byte of it. A routine may change every
## other general register but `rbx` and `rbp`, and `xmm0` and `xmm1`; it
## takes its arguments in `rdi`, `rsi` and `rdx` and answers in `rax`.
##
## A number is written as node writes it when it is an integer of at most
## 2^53 in size, or NaN, an infinity or -0. Any other number is not written
## yet: the program stops, saying so, so its output can never be mistaken
## for node's.
import Assembly
import Boxing
import X86
import Emit

Runtime :: [].{

	## The routine that writes the number whose bits are in `rax`.
	print_number : Str
	print_number = "runtime_print_number"

	## The routine that gives the text of the number whose bits are in
	## `rax`: a string's address (its length, then its bytes) in `rax`.
	number_text : Str
	number_text = "runtime_number_text"

	## The routine that writes `rdx` bytes at `rsi` to stdout, through the
	## buffer.
	write : Str
	write = "runtime_write"

	## The routine that takes `rdi` bytes of the heap, its address in `rax`.
	allocate : Str
	allocate = "runtime_allocate"

	## The routine that ends the program with the exit code in `rdi`, once
	## the buffer is written.
	exit : Str
	exit = "runtime_exit"

	## Where a function whose frame would pass the stack's limit goes:
	## node's RangeError's line, and exit 1.
	stack_overflow : Str
	stack_overflow = "runtime_stack_overflow"

	## The routine that writes the value whose bits are in `rdi` as
	## `console.log` writes an argument.
	write_value : Str
	write_value = "runtime_write_value"

	## The routine that gives `rdi + rsi` as JavaScript's `+` does: a sum of
	## two numbers, else, when either is a string, the two joined as text.
	add : Str
	add = "runtime_add"

	## The routine that stops the program unless the value whose bits are
	## in `rax` is a number. It changes `rcx` alone.
	check_number : Str
	check_number = "runtime_check_number"

	## The routine that gives `rdi === rsi` as a boolean's bits.
	strict_equal : Str
	strict_equal = "runtime_strict_equal"

	## The routine that orders `rdi` and `rsi`, two numbers or two strings:
	## 0 when the first is less, 1 when they are equal, 2 when it is
	## greater, 3 when either is NaN.
	compare : Str
	compare = "runtime_compare"

	## The routine that gives 1 in `rax` when the value `rdi` is truthy,
	## else 0.
	truthy : Str
	truthy = "runtime_truthy"

	## The routine that joins a template's text so far (a string, `rdi`),
	## a substitution's value made text (`rsi`) and the template's next
	## piece (a string's address, `rdx`), the string they make in `rax`.
	template : Str
	template = "runtime_template"

	## The routine that reads the property named by the string at `rsi` of
	## the value `rdi`.
	get_property : Str
	get_property = "runtime_get_property"

	## The texts the runtime writes, each under its label.
	Text : [Space, Newline]

	## The statements that write one of the texts to stdout.
	text_items : Runtime.Text -> List(Assembly.Statement)
	text_items = |text| {
		label = text_label(text)
		[
			Emit.address_of(Rsi, label),
			Emit.load(Rdx, Emit.mem(Rsi, 0)),
			Emit.plus_imm(Rsi, 8),
			Emit.call(Runtime.write),
		]
	}

	## A string's bytes as the runtime holds one: its length in 8 bytes,
	## then its bytes.
	string_data : Str -> List(U8)
	string_data = |text| {
		bytes = text.to_utf8()
		X86.append_little_endian([], { value: bytes.len().to_i64_wrap(), size: 8 }).concat(bytes)
	}

	## The program's first statements: the heap mapped, the four registers
	## set, then a call of the program's own code at `main`.
	start_items : Str -> List(Assembly.Statement)
	start_items = |main| [
		Emit.imm(Rax, 9),
		Emit.zero(Rdi),
		Emit.imm(Rsi, heap_size),
		Emit.imm(Rdx, 3),
		Emit.imm(R10, 0x4022),
		Emit.imm(R8, -1),
		Emit.zero(R9),
		Emit.syscall,
		Emit.test(Rax, Rax),
		Emit.jcc(S, "runtime_no_heap"),
		Emit.mov(R13, Rax),
		Emit.lea(R15, Emit.mem(Rax, buffer_place + buffer_size)),
		Emit.mov(R14, Rax),
		Emit.plus_imm(R14, heap_size),
		Emit.mov(R12, Rsp),
		Emit.minus_imm(R12, stack_size),
		Emit.call(main),
	]

	## Every routine, then every text under its label.
	items : List(Assembly.Statement)
	items = [
		allocate_items,
		output_items,
		stop_items,
		write_value_items,
		number_items,
		string_items,
		operator_items,
		property_items,
	]
		.join()
		.concat(text_statements)
}

## The heap's size: the program stops, out of memory, past it.
heap_size : I64
heap_size = 0x40000000

## How far below the stack's start the program's frames may reach. Linux
## gives a program 8 MiB of stack unless told otherwise; what is left past
## this is for the runtime's own routines.
stack_size : I64
stack_size = 6 * 1024 * 1024

## Where the output buffer starts past `r13`, and its size.
buffer_place : I64
buffer_place = 16

buffer_size : I64
buffer_size = 65536

digit_zero : U8
digit_zero = '0'

minus_sign : U8
minus_sign = '-'

## The texts' bytes, each a string as the heap holds one: its length in 8
## bytes, then its bytes.
text_statements : List(Assembly.Statement)
text_statements = {
	var $out = []
	for (label, text) in texts {
		$out = $out.concat([Mark(label), Data(Runtime.string_data(text))])
	}
	$out
}

## Every text, with its label.
texts : List((Str, Str))
texts = [
	(text_label(Space), " "),
	(text_label(Newline), "\n"),
	("runtime_text_undefined", "undefined"),
	("runtime_text_null", "null"),
	("runtime_text_false", "false"),
	("runtime_text_true", "true"),
	("runtime_text_infinity", "Infinity"),
	("runtime_text_negative_infinity", "-Infinity"),
	("runtime_text_not_a_number", "NaN"),
	("runtime_text_negative_zero", "-0"),
	(
		"runtime_text_not_written",
		Str.concat(
			"x86: console.log of a number that is not an integer",
			" of at most 2^53 is not compiled yet\n",
		),
	),
	("runtime_text_stack_overflow", "RangeError: Maximum call stack size exceeded\n"),
	(
		"runtime_text_out_of_memory",
		"x86: out of memory: the heap of 1 GiB is full, and no collector runs yet\n",
	),
	("runtime_text_no_heap", "x86: the heap could not be mapped\n"),
	("runtime_text_length", "length"),
	("runtime_text_zero", "0"),
	(
		"runtime_text_text_of_object",
		"x86: a string made of an array or an object is not compiled yet\n",
	),
	(
		"runtime_text_add_not_compiled",
		"x86: `+` of values neither of which is a string, nor both numbers, is not compiled yet\n",
	),
	(
		"runtime_text_arithmetic_not_compiled",
		"x86: arithmetic on a value that is not a number is not compiled yet\n",
	),
	(
		"runtime_text_compare_not_compiled",
		"x86: an order of values that are not two numbers or two strings is not compiled yet\n",
	),
	("runtime_text_property_not_compiled", "x86: this property read is not compiled yet\n"),
	(
		"runtime_text_value_not_written",
		"x86: console.log of this kind of value is not compiled yet\n",
	),
]

text_label : Runtime.Text -> Str
text_label = |text|
	match text {
		Space => "runtime_text_space"
		Newline => "runtime_text_newline"
	}

## The statements that stop the program with the text at `label`.
stopping_items : Str -> List(Assembly.Statement)
stopping_items = |label| [Emit.address_of(Rsi, label), Emit.jmp("runtime_stop")]

## The bump allocator: `rdi` rounded up to 8, taken from `r15`. It changes
## `rax` and `rdi` alone.
allocate_items : List(Assembly.Statement)
allocate_items = [
	Emit.mark(Runtime.allocate),
	Emit.plus_imm(Rdi, 7),
	Emit.bit_and_imm(Rdi, -8),
	Emit.mov(Rax, R15),
	Emit.plus(R15, Rdi),
	Emit.cmp(R15, R14),
	Emit.jcc(A, "runtime_out_of_memory"),
	Emit.ret,
]

## Buffered output. `runtime_write` copies into the buffer, which is written
## when the next bytes wouldn't fit, before a stop's message, and at the
## exit; bytes that would fill the buffer alone are written at once.
## `runtime_write_all` is the `write` system call until every byte is
## written.
output_items : List(Assembly.Statement)
output_items = [
	Emit.mark(Runtime.write),
	Emit.load(Rax, Emit.mem(R13, 0)),
	Emit.imm(Rcx, buffer_size),
	Emit.minus(Rcx, Rax),
	Emit.cmp(Rdx, Rcx),
	Emit.jcc(A, "runtime_write_full"),
	Emit.mov(Rcx, Rax),
	Emit.plus(Rcx, Rdx),
	Emit.store(Emit.mem(R13, 0), Rcx),
	Emit.lea(Rdi, Emit.mem(R13, buffer_place)),
	Emit.plus(Rdi, Rax),
	Emit.mov(Rcx, Rdx),
	Instruction(RepMovsb),
	Emit.ret,
	Emit.mark("runtime_write_full"),
	Emit.save(Rsi),
	Emit.save(Rdx),
	Emit.call("runtime_flush"),
	Emit.restore(Rdx),
	Emit.restore(Rsi),
	Emit.cmp_imm(Rdx, buffer_size),
	Emit.jcc(Be, Runtime.write),
	Emit.imm(Rdi, 1),
	Emit.jmp("runtime_write_all"),
	Emit.mark("runtime_flush"),
	Emit.load(Rdx, Emit.mem(R13, 0)),
	Emit.lea(Rsi, Emit.mem(R13, buffer_place)),
	Emit.imm(Rdi, 1),
	Emit.zero(Rax),
	Emit.store(Emit.mem(R13, 0), Rax),
	Emit.mark("runtime_write_all"),
	Emit.test(Rdx, Rdx),
	Emit.jcc(E, "runtime_written"),
	Emit.imm(Rax, 1),
	Emit.syscall,
	Emit.test(Rax, Rax),
	Emit.jcc(Le, "runtime_write_failed"),
	Emit.plus(Rsi, Rax),
	Emit.minus(Rdx, Rax),
	Emit.jmp("runtime_write_all"),
	Emit.mark("runtime_written"),
	Emit.ret,
	# A write that fails (a closed pipe) leaves nothing to report it on.
	Emit.mark("runtime_write_failed"),
	Emit.imm(Rdi, 1),
	Emit.imm(Rax, 231),
	Emit.syscall,
	Emit.mark(Runtime.exit),
	Emit.save(Rdi),
	Emit.call("runtime_flush"),
	Emit.restore(Rdi),
	Emit.imm(Rax, 231),
	Emit.syscall,
]

## The stops: what was buffered is written, then the message at `rsi` (a
## string as the heap holds one) to stderr, and the exit is 1.
stop_items : List(Assembly.Statement)
stop_items =
	[
		Emit.mark("runtime_stop"),
		Emit.save(Rsi),
		Emit.call("runtime_flush"),
		Emit.restore(Rsi),
		Emit.load(Rdx, Emit.mem(Rsi, 0)),
		Emit.plus_imm(Rsi, 8),
		Emit.imm(Rdi, 2),
		Emit.call("runtime_write_all"),
		Emit.imm(Rdi, 1),
		Emit.imm(Rax, 231),
		Emit.syscall,
		Emit.mark(Runtime.stack_overflow),
	]
		.concat(stopping_items("runtime_text_stack_overflow"))
		.append(Emit.mark("runtime_out_of_memory"))
		.concat(stopping_items("runtime_text_out_of_memory"))
		.append(Emit.mark("runtime_no_heap"))
		.concat([
			Emit.address_of(Rsi, "runtime_text_no_heap"),
			Emit.load(Rdx, Emit.mem(Rsi, 0)),
			Emit.plus_imm(Rsi, 8),
			Emit.imm(Rdi, 2),
			Emit.call("runtime_write_all"),
			Emit.imm(Rdi, 1),
			Emit.imm(Rax, 231),
			Emit.syscall,
		])

## `runtime_write_value`: a number as `runtime_print_number` writes it, and
## `undefined`, `null` and the booleans by their words.
write_value_items : List(Assembly.Statement)
write_value_items = {
	constant = |{ bits, label }| [
		Emit.imm(Rcx, bits),
		Emit.cmp(Rdi, Rcx),
		Emit.jcc(E, "${label}_case"),
	]
	written = |label| [
		Emit.mark("${label}_case"),
		Emit.address_of(Rsi, label),
		Emit.load(Rdx, Emit.mem(Rsi, 0)),
		Emit.plus_imm(Rsi, 8),
		Emit.jmp(Runtime.write),
	]
	[
		Emit.mark(Runtime.write_value),
		Emit.mov(Rax, Rdi),
		Emit.mov(Rcx, Rdi),
		Emit.shr(Rcx, Boxing.tag_shift),
		Emit.cmp_imm(Rcx, Boxing.first_tag),
		Emit.jcc(B, Runtime.print_number),
		Emit.cmp_imm(Rcx, Boxing.string_tag),
		Emit.jcc(E, "runtime_write_string"),
	]
		.concat(constant({ bits: Boxing.undefined_bits, label: "runtime_text_undefined" }))
		.concat(constant({ bits: Boxing.null_bits, label: "runtime_text_null" }))
		.concat(constant({ bits: Boxing.false_bits, label: "runtime_text_false" }))
		.concat(constant({ bits: Boxing.true_bits, label: "runtime_text_true" }))
		.concat(stopping_items("runtime_text_value_not_written"))
		.concat(written("runtime_text_undefined"))
		.concat(written("runtime_text_null"))
		.concat(written("runtime_text_false"))
		.concat(written("runtime_text_true"))
		.concat([Emit.mark("runtime_write_string")])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.lea(Rsi, Emit.mem(Rdi, 8)),
			Emit.jmp(Runtime.write),
		])
}

## The statements that put the tag of the value in `from` in `rcx`.
tag_load_items : X86.Register -> List(Assembly.Statement)
tag_load_items = |from| [Emit.mov(Rcx, from), Emit.shr(Rcx, Boxing.tag_shift)]

## The statements that jump to `label` unless the value in `reg` is a
## string, with `rcx` its tag after.
unless_string_items : { reg : X86.Register, label : Str } -> List(Assembly.Statement)
unless_string_items = |{ reg, label }|
	tag_load_items(reg).concat([Emit.cmp_imm(Rcx, Boxing.string_tag), Emit.jcc(Ne, label)])

## The statements that jump to `label` unless the value in `reg` is a
## number.
unless_number_items : { reg : X86.Register, label : Str } -> List(Assembly.Statement)
unless_number_items = |{ reg, label }|
	tag_load_items(reg).concat([Emit.cmp_imm(Rcx, Boxing.first_tag), Emit.jcc(Ae, label)])

## The byte `r8` of the string at `base` loaded into `reg`.
text_byte_item : { reg : X86.Register, base : X86.Register } -> Assembly.Statement
text_byte_item = |{ reg, base }| Emit.byte_load(
	reg,
	Emit.mem_index({ base, index: R8, displacement: 8 }),
)

## The pointer a boxed value holds, its tag cleared, in the same register:
## the top 16 bits shifted out and back as zeros.
unboxed_items : X86.Register -> List(Assembly.Statement)
unboxed_items = |reg| [Emit.shl(reg, 16), Emit.shr(reg, 16)]

## The string at the address in `rax` boxed, in `rax`. It changes `rcx`.
boxed_string_items : List(Assembly.Statement)
boxed_string_items = [Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)), Emit.plus(Rax, Rcx)]

## `runtime_text_of`, JavaScript's `String(v)` of the value in `rdi`, the
## string's address in `rax`; `runtime_concat`, the string at `rdi` then
## the one at `rsi`, a new string's address in `rax`; `runtime_text_equal`,
## 1 in `rax` when the strings at `rdi` and `rsi` hold the same bytes,
## else 0, changing `rax`, `rcx`, `rdx` and `r8` alone; and
## `runtime_template`.
string_items : List(Assembly.Statement)
string_items = {
	constant = |{ bits, label }| [
		Emit.imm(Rcx, bits),
		Emit.cmp(Rdi, Rcx),
		Emit.jcc(E, "${label}_text_case"),
	]
	given = |label| [
		Emit.mark("${label}_text_case"),
		Emit.address_of(Rax, label),
		Emit.ret,
	]
	text_of = [Emit.mark("runtime_text_of"), Emit.mov(Rax, Rdi)]
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(B, "runtime_text_of_number"),
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(E, "runtime_text_of_string"),
		])
		.concat(constant({ bits: Boxing.undefined_bits, label: "runtime_text_undefined" }))
		.concat(constant({ bits: Boxing.null_bits, label: "runtime_text_null" }))
		.concat(constant({ bits: Boxing.false_bits, label: "runtime_text_false" }))
		.concat(constant({ bits: Boxing.true_bits, label: "runtime_text_true" }))
		.concat(stopping_items("runtime_text_text_of_object"))
		.concat(given("runtime_text_undefined"))
		.concat(given("runtime_text_null"))
		.concat(given("runtime_text_false"))
		.concat(given("runtime_text_true"))
		.append(Emit.mark("runtime_text_of_string"))
		.concat(unboxed_items(Rax))
		.append(Emit.ret)
		# String(-0) is "0", though console.log writes it as -0.
		.concat([
			Emit.mark("runtime_text_of_number"),
			Emit.imm(Rcx, (0x8000000000000000).to_i64_wrap()),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ne, Runtime.number_text),
			Emit.address_of(Rax, "runtime_text_zero"),
			Emit.ret,
		])
	concat = [
		Emit.mark("runtime_concat"),
		Emit.save(Rdi),
		Emit.save(Rsi),
		Emit.load(Rax, Emit.mem(Rdi, 0)),
		Emit.load(Rcx, Emit.mem(Rsi, 0)),
		Emit.plus(Rax, Rcx),
		Emit.lea(Rdi, Emit.mem(Rax, 8)),
		Emit.call(Runtime.allocate),
		Emit.restore(Rsi),
		Emit.restore(Rdx),
		Emit.load(Rcx, Emit.mem(Rdx, 0)),
		Emit.load(R8, Emit.mem(Rsi, 0)),
		Emit.mov(R9, Rcx),
		Emit.plus(R9, R8),
		Emit.store(Emit.mem(Rax, 0), R9),
		Emit.lea(Rdi, Emit.mem(Rax, 8)),
		Emit.mov(R10, Rsi),
		Emit.lea(Rsi, Emit.mem(Rdx, 8)),
		Instruction(RepMovsb),
		Emit.lea(Rsi, Emit.mem(R10, 8)),
		Emit.mov(Rcx, R8),
		Instruction(RepMovsb),
		Emit.ret,
	]
	equal = [
		Emit.mark("runtime_text_equal"),
		Emit.cmp(Rdi, Rsi),
		Emit.jcc(E, "runtime_text_equal_yes"),
		Emit.load(Rcx, Emit.mem(Rdi, 0)),
		Emit.load(Rdx, Emit.mem(Rsi, 0)),
		Emit.cmp(Rcx, Rdx),
		Emit.jcc(Ne, "runtime_text_equal_no"),
		Emit.zero(R8),
		Emit.mark("runtime_text_equal_byte"),
		Emit.cmp(R8, Rcx),
		Emit.jcc(E, "runtime_text_equal_yes"),
		text_byte_item({ reg: Rax, base: Rdi }),
		text_byte_item({ reg: Rdx, base: Rsi }),
		Emit.cmp(Rax, Rdx),
		Emit.jcc(Ne, "runtime_text_equal_no"),
		Emit.plus_imm(R8, 1),
		Emit.jmp("runtime_text_equal_byte"),
		Emit.mark("runtime_text_equal_yes"),
		Emit.imm(Rax, 1),
		Emit.ret,
		Emit.mark("runtime_text_equal_no"),
		Emit.zero(Rax),
		Emit.ret,
	]
	template = [
		Emit.mark(Runtime.template),
		Emit.save(Rdx),
		Emit.save(Rdi),
		Emit.mov(Rdi, Rsi),
		Emit.call("runtime_text_of"),
		Emit.restore(Rdi),
	]
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.mov(Rsi, Rax),
			Emit.call("runtime_concat"),
			Emit.restore(Rsi),
			Emit.mov(Rdi, Rax),
			Emit.call("runtime_concat"),
		])
		.concat(boxed_string_items)
		.append(Emit.ret)
	[text_of, concat, equal, template].join()
}

## `runtime_add`, `runtime_check_number`, `runtime_strict_equal`,
## `runtime_compare` and `runtime_truthy`.
operator_items : List(Assembly.Statement)
operator_items = {
	both_numbers = |other|
		unless_number_items({ reg: Rdi, label: other })
			.concat(unless_number_items({ reg: Rsi, label: other }))
			.concat([Emit.to_xmm(Xmm0, Rdi), Emit.to_xmm(Xmm1, Rsi)])
	answer = |{ label, value }| [
		Emit.mark(label),
		Emit.imm(Rax, value),
		Emit.ret,
	]
	add = [Emit.mark(Runtime.add)]
		.concat(both_numbers("runtime_add_other"))
		.concat([
			Instruction(
				Sse({
					operation: Addsd,
					to: Xmm0,
					from: Xmm1,
				}),
			),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.ret,
			Emit.mark("runtime_add_other"),
		])
		.concat(tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.string_tag), Emit.jcc(E, "runtime_add_texts")])
		.concat(tag_load_items(Rsi))
		.concat([Emit.cmp_imm(Rcx, Boxing.string_tag), Emit.jcc(E, "runtime_add_texts")])
		.concat(stopping_items("runtime_text_add_not_compiled"))
		.concat([
			Emit.mark("runtime_add_texts"),
			Emit.save(Rsi),
			Emit.call("runtime_text_of"),
			Emit.restore(Rsi),
			Emit.save(Rax),
			Emit.mov(Rdi, Rsi),
			Emit.call("runtime_text_of"),
			Emit.mov(Rsi, Rax),
			Emit.restore(Rdi),
			Emit.call("runtime_concat"),
		])
		.concat(boxed_string_items)
		.append(Emit.ret)
	check = [Emit.mark(Runtime.check_number)]
		.concat(tag_load_items(Rax))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(Ae, "runtime_not_a_number_stop"),
			Emit.ret,
			Emit.mark("runtime_not_a_number_stop"),
		])
		.concat(stopping_items("runtime_text_arithmetic_not_compiled"))
	equal = [Emit.mark(Runtime.strict_equal)]
		.concat(both_numbers("runtime_strict_equal_other"))
		.concat([
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(P, "runtime_strict_equal_false"),
			Emit.jcc(E, "runtime_strict_equal_true"),
			Emit.jmp("runtime_strict_equal_false"),
			Emit.mark("runtime_strict_equal_other"),
			Emit.cmp(Rdi, Rsi),
			Emit.jcc(E, "runtime_strict_equal_true"),
		])
		.concat(unless_string_items({ reg: Rdi, label: "runtime_strict_equal_false" }))
		.concat(unless_string_items({ reg: Rsi, label: "runtime_strict_equal_false" }))
		.concat(unboxed_items(Rdi))
		.concat(unboxed_items(Rsi))
		.concat([
			Emit.call("runtime_text_equal"),
			Emit.imm(Rcx, Boxing.false_bits),
			Emit.plus(Rax, Rcx),
			Emit.ret,
		])
		.concat(answer({ label: "runtime_strict_equal_true", value: Boxing.true_bits }))
		.concat(answer({ label: "runtime_strict_equal_false", value: Boxing.false_bits }))
	compare = [Emit.mark(Runtime.compare)]
		.concat(both_numbers("runtime_compare_other"))
		.concat([
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(P, "runtime_compare_unordered"),
			Emit.jcc(B, "runtime_compare_less"),
			Emit.jcc(E, "runtime_compare_equal"),
			Emit.jmp("runtime_compare_greater"),
			Emit.mark("runtime_compare_other"),
		])
		.concat(unless_string_items({ reg: Rdi, label: "runtime_compare_mixed" }))
		.concat(unless_string_items({ reg: Rsi, label: "runtime_compare_mixed" }))
		.concat(unboxed_items(Rdi))
		.concat(unboxed_items(Rsi))
		.concat([
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.load(R10, Emit.mem(Rsi, 0)),
			Emit.zero(R8),
			Emit.mark("runtime_compare_byte"),
			Emit.cmp(R8, R9),
			Emit.jcc(E, "runtime_compare_first_ended"),
			Emit.cmp(R8, R10),
			Emit.jcc(E, "runtime_compare_greater"),
			text_byte_item({ reg: Rax, base: Rdi }),
			text_byte_item({ reg: Rdx, base: Rsi }),
			Emit.cmp(Rax, Rdx),
			Emit.jcc(B, "runtime_compare_less"),
			Emit.jcc(A, "runtime_compare_greater"),
			Emit.plus_imm(R8, 1),
			Emit.jmp("runtime_compare_byte"),
			Emit.mark("runtime_compare_first_ended"),
			Emit.cmp(R8, R10),
			Emit.jcc(E, "runtime_compare_equal"),
			Emit.jmp("runtime_compare_less"),
			Emit.mark("runtime_compare_mixed"),
		])
		.concat(stopping_items("runtime_text_compare_not_compiled"))
		.concat(answer({ label: "runtime_compare_less", value: 0 }))
		.concat(answer({ label: "runtime_compare_equal", value: 1 }))
		.concat(answer({ label: "runtime_compare_greater", value: 2 }))
		.concat(answer({ label: "runtime_compare_unordered", value: 3 }))
	truthy = [Emit.mark(Runtime.truthy)]
		.concat(unless_number_items({ reg: Rdi, label: "runtime_truthy_other" }))
		.concat([
			Emit.to_xmm(Xmm0, Rdi),
			Emit.zero(Rcx),
			Emit.to_xmm(Xmm1, Rcx),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(P, "runtime_truthy_no"),
			Emit.jcc(E, "runtime_truthy_no"),
			Emit.jmp("runtime_truthy_yes"),
			Emit.mark("runtime_truthy_other"),
			Emit.imm(Rax, Boxing.true_bits),
			Emit.cmp(Rdi, Rax),
			Emit.jcc(E, "runtime_truthy_yes"),
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(E, "runtime_truthy_no"),
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(Ne, "runtime_truthy_yes"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rax, Emit.mem(Rdi, 0)),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_truthy_no"),
		])
		.concat(answer({ label: "runtime_truthy_yes", value: 1 }))
		.concat(answer({ label: "runtime_truthy_no", value: 0 }))
	[add, check, equal, compare, truthy].join()
}

## `runtime_get_property`: a string's or an array's `length`.
property_items : List(Assembly.Statement)
property_items =
	[Emit.mark(Runtime.get_property)]
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(E, "runtime_get_length"),
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(E, "runtime_get_length"),
		])
		.concat(stopping_items("runtime_text_property_not_compiled"))
		.concat([
			Emit.mark("runtime_get_length"),
			Emit.save(Rdi),
			Emit.mov(Rdi, Rsi),
			Emit.address_of(Rsi, "runtime_text_length"),
			Emit.call("runtime_text_equal"),
			Emit.restore(Rdi),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_get_length_other"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rax, Emit.mem(Rdi, 0)),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.ret,
			Emit.mark("runtime_get_length_other"),
		])
		.concat(stopping_items("runtime_text_property_not_compiled"))

## The bits of the number in `rax` compared with `bits`, and a jump to
## `label` when they are the same.
bits_case_items : { bits : U64, label : Str } -> List(Assembly.Statement)
bits_case_items = |{ bits, label }| [
	Emit.imm(Rcx, bits.to_i64_wrap()),
	Emit.cmp(Rax, Rcx),
	Emit.jcc(E, label),
]

## `runtime_number_text` and `runtime_print_number`. The special numbers
## are told by their bits and have texts of their own; any other number is
## converted to an integer and back, and is written only when that gives it
## back exactly and its size is at most 2^53. Its digits are made from the
## last, by division by ten, into 32 bytes of the stack, then copied to a
## string on the heap.
number_items : List(Assembly.Statement)
number_items = {
	buffer_end = Emit.mem(Rsp, 32)
	written_at_rsi = Emit.mem(Rsi, 0)
	special = |label| [Emit.address_of(Rax, label), Emit.ret]
	[
		Emit.mark(Runtime.print_number),
		Emit.call(Runtime.number_text),
		Emit.load(Rdx, Emit.mem(Rax, 0)),
		Emit.lea(Rsi, Emit.mem(Rax, 8)),
		Emit.jmp(Runtime.write),
		Emit.mark(Runtime.number_text),
	]
		.concat(bits_case_items({ bits: 0x7FF0000000000000, label: "runtime_infinity_case" }))
		.concat(
			bits_case_items({ bits: 0xFFF0000000000000, label: "runtime_negative_infinity_case" }),
		)
		.concat(bits_case_items({ bits: 0x8000000000000000, label: "runtime_negative_zero_case" }))
		.concat([
			Emit.to_xmm(Xmm0, Rax),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
			Emit.jcc(P, "runtime_not_a_number_case"),
			Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
			Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(Ne, "runtime_not_written_case"),
			# r9 is 1 for a negative number, whose size goes on in rcx.
			Emit.zero(R9),
			Emit.test(Rcx, Rcx),
			Emit.jcc(Ns, "runtime_number_size"),
			Emit.imm(R9, 1),
			Instruction(Neg(Rcx)),
			Emit.mark("runtime_number_size"),
			Emit.imm(Rdx, 9007199254740992),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(A, "runtime_not_written_case"),
			Emit.minus_imm(Rsp, 32),
			Emit.lea(Rsi, buffer_end),
			Emit.imm(R8, 10),
			Emit.mark("runtime_number_digit"),
			Emit.zero(Rdx),
			Emit.mov(Rax, Rcx),
			Instruction(Div(R8)),
			Emit.plus_imm(Rdx, digit_zero.to_i64()),
			Emit.minus_imm(Rsi, 1),
			Instruction(MovByteStore({ to: written_at_rsi, from: Dl })),
			Emit.mov(Rcx, Rax),
			Emit.test(Rcx, Rcx),
			Emit.jcc(Ne, "runtime_number_digit"),
			Emit.test(R9, R9),
			Emit.jcc(E, "runtime_number_copy"),
			Emit.minus_imm(Rsi, 1),
			Emit.imm(Rdx, minus_sign.to_i64()),
			Instruction(MovByteStore({ to: written_at_rsi, from: Dl })),
			Emit.mark("runtime_number_copy"),
			Emit.lea(Rdx, buffer_end),
			Emit.minus(Rdx, Rsi),
			Emit.lea(Rdi, Emit.mem(Rdx, 8)),
			Emit.call(Runtime.allocate),
			Emit.store(Emit.mem(Rax, 0), Rdx),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.mov(Rcx, Rdx),
			Instruction(RepMovsb),
			Emit.plus_imm(Rsp, 32),
			Emit.ret,
			Emit.mark("runtime_infinity_case"),
		])
		.concat(special("runtime_text_infinity"))
		.append(Emit.mark("runtime_negative_infinity_case"))
		.concat(special("runtime_text_negative_infinity"))
		.append(Emit.mark("runtime_not_a_number_case"))
		.concat(special("runtime_text_not_a_number"))
		.append(Emit.mark("runtime_negative_zero_case"))
		.concat(special("runtime_text_negative_zero"))
		.append(Emit.mark("runtime_not_written_case"))
		.concat(stopping_items("runtime_text_not_written"))
}
