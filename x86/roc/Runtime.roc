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
## takes its arguments in `rdi`, `rsi` and `rdx` and answers in `rax`. The
## routines that call a function (`map` and the rest) change `rbx` too,
## the closure record a call passes, and every register a function may.
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

	## The routine that makes an array of `rdi` items: the array in `rax`,
	## the address of its items, for the caller to fill, in `rdx`.
	new_array : Str
	new_array = "runtime_new_array"

	## The routine that makes an empty object, in `rax`.
	new_object : Str
	new_object = "runtime_new_object"

	## The routine that sets the property named by the string at `rsi` of
	## the object `rdi` to `rdx`.
	set_property : Str
	set_property = "runtime_set_property"

	## The routine that reads `rdi[rsi]`.
	get_index : Str
	get_index = "runtime_get_index"

	## The routine that sets `rdi[rsi]` to `rdx`.
	set_index : Str
	set_index = "runtime_set_index"

	## The routine that pushes `rsi` onto the array `rdi`, its new length
	## (a number) in `rax`.
	push : Str
	push = "runtime_push"

	## The routine that pops the array `rdi`, the item in `rax`.
	pop : Str
	pop = "runtime_pop"

	## The routine that gives `rdi % rsi` of two whole numbers of at most
	## 2^53 in size, and stops for any other.
	remainder : Str
	remainder = "runtime_remainder"

	## The routine that gives a `for ... of`'s next item: of the array `rdi`
	## at the place `rsi` (a number), the item in `rax` and 1 in `rdx`, or 0
	## in `rdx` past the end.
	next_item : Str
	next_item = "runtime_next_item"

	## The routine that stops the program unless the value in `rax` is a
	## function. It changes `rcx` alone.
	check_function : Str
	check_function = "runtime_check_function"

	## The routines of an array's methods that take a function, the array in
	## `rdi` and the function in `rsi`: `map` (the new array in `rax`),
	## `filter` (the same), `forEach` (`undefined`), and `reduce`, with its
	## first value in `rdx` when `rcx` is 2. Each calls the function through
	## its value, so `rbx` changes.
	map : Str
	map = "runtime_map"

	filter : Str
	filter = "runtime_filter"

	for_each : Str
	for_each = "runtime_for_each"

	reduce : Str
	reduce = "runtime_reduce"

	## The routine that joins the array `rdi`'s items as text, the string at
	## `rsi` (an address) between them: the string in `rax`.
	join : Str
	join = "runtime_join"

	## The routine that gives the items of the array `rdi` from the place
	## `rsi` to the place `rdx` (numbers; `rcx` says how many of the two
	## were given), a new array in `rax`.
	slice : Str
	slice = "runtime_slice"

	## The routine that gives the character of the string `rdi` at the place
	## `rsi`, or `""` past its end.
	char_at : Str
	char_at = "runtime_char_at"

	## The routine that gives `rdi ** rsi` of two numbers: of a whole base
	## and a whole exponent of at least 0, exactly, by squaring; it stops
	## for any other, and for a power past 2^53 in size.
	power : Str
	power = "runtime_power"

	## The routine that gives `typeof rdi`, a string, in `rax`.
	type_of : Str
	type_of = "runtime_type_of"

	## The routine that makes an array of the `rsi` arguments at `rdi`, the
	## first there and each next 8 bytes on, in `rax`: the parameters of a
	## function with a pattern, a default or a rest, packed.
	pack : Str
	pack = "runtime_pack"

	## The routine that gives the array a `for ... of` or an array pattern
	## walks of the value `rdi`: an array as it is, a string as a new array
	## of its characters; it stops for any other.
	items_of : Str
	items_of = "runtime_items_of"

	## Where a throw goes, the value thrown in `rax`: to the innermost
	## `try`'s handler, whose record (`Runtime.handler_place` holds its
	## address, on the machine's stack) holds the handler before it, the
	## frame's `rbp` and the code that takes the throw, which it enters with
	## `rsp` above the record and the value in `rax`; with none, the program
	## stops.
	throw : Str
	throw = "runtime_throw"

	## The innermost `try`'s handler record, or 0.
	handler_place : X86.Mem
	handler_place = Emit.mem(R13, 16)

	## The routine that makes an error, an object holding its `name` (the
	## string at `rdi`) and its `message` (the string at `rsi`) and a key no
	## program can name, which marks it an error for console.log: the object
	## in `rax`.
	new_error : Str
	new_error = "runtime_new_error"

	## The routine that gives an error's message of the value `rdi`, as
	## `new Error(v)` takes it: `""` for `undefined`, else `String(v)`, a
	## string's address in `rax`.
	error_message : Str
	error_message = "runtime_error_message"

	## The label of the text of an error's name, `Error` or `TypeError` and
	## the rest.
	error_name_label : Str -> Str
	error_name_label = |name| "runtime_text_error_${name}"

	## The routine that stops the program when the value in `rax`, which an
	## object pattern takes apart, is `null` or `undefined` (node throws a
	## TypeError). It changes `rcx` alone.
	check_destructurable : Str
	check_destructurable = "runtime_check_destructurable"

	## The text `join` puts between items when it is given none.
	comma_text : Str
	comma_text = "runtime_text_comma"

	## The routine that makes a variable's cell, 8 bytes holding `rsi`: its
	## address in `rax`. It changes `rax` and `rdi` alone.
	new_cell : Str
	new_cell = "runtime_new_cell"

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
		container_items,
		inspect_items,
		loop_items,
		callback_items,
		slice_items,
		language_items,
		exception_items,
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

## Where the output buffer starts past `r13`, and its size. Before it are
## the buffer's fill (`[r13]`), node's inspect depth (8) and the innermost
## `try`'s handler (16, 0 when none waits).
buffer_place : I64
buffer_place = 24

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
	# The error's key: one byte, 0xFF, which no string a program writes
	# holds, since a string here is ASCII.
	$out.concat([Mark(error_mark), Data([1, 0, 0, 0, 0, 0, 0, 0, 0xFF])])
}

error_mark : Str
error_mark = "runtime_text_error_mark"

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
	("runtime_text_call_stack", "Maximum call stack size exceeded"),
	("runtime_text_name", "name"),
	("runtime_text_message", "message"),
	(Runtime.error_name_label("Error"), "Error"),
	(Runtime.error_name_label("TypeError"), "TypeError"),
	(Runtime.error_name_label("RangeError"), "RangeError"),
	(Runtime.error_name_label("ReferenceError"), "ReferenceError"),
	(Runtime.error_name_label("SyntaxError"), "SyntaxError"),
	(
		"runtime_text_uncaught",
		Str.concat(
			"x86: a throw that nothing catches, which node reports with its source line,",
			" is not compiled yet\n",
		),
	),
	(
		"runtime_text_error_written",
		"x86: console.log of an error, which node writes with its stack, is not compiled yet\n",
	),
	(
		"runtime_text_out_of_memory",
		"x86: out of memory: the heap of 1 GiB is full, and no collector runs yet\n",
	),
	("runtime_text_no_heap", "x86: the heap could not be mapped\n"),
	("runtime_text_length", "length"),
	("runtime_text_zero", "0"),
	(
		"runtime_text_remainder",
		"x86: `%` of numbers that are not whole numbers of at most 2^53 is not compiled yet\n",
	),
	(
		"runtime_text_not_iterable",
		Str.concat(
			"x86: a `for ... of` or an array pattern over a value that is neither",
			" an array nor a string is not compiled yet\n",
		),
	),
	("runtime_text_empty_array", "[]"),
	("runtime_text_comma", ","),
	("runtime_text_empty", ""),
	(
		"runtime_text_empty_reduce",
		Str.concat(
			"x86: `reduce` of an empty array with no first value,",
			" which throws in node, is not compiled yet\n",
		),
	),
	(
		"runtime_text_slice_place",
		"x86: `slice` from a place that is not a number is not compiled yet\n",
	),
	("runtime_text_empty_object", "{}"),
	(
		"runtime_text_not_destructurable",
		"x86: an object pattern of null or undefined, which throws in node, is not compiled yet\n",
	),
	("runtime_text_type_number", "number"),
	("runtime_text_type_string", "string"),
	("runtime_text_type_boolean", "boolean"),
	("runtime_text_type_object", "object"),
	("runtime_text_type_function", "function"),
	(
		"runtime_text_power",
		Str.concat(
			"x86: `**` of numbers that are not whole, with a negative exponent,",
			" or past 2^53 in size, is not compiled yet\n",
		),
	),
	("runtime_text_deep_array", "[Array]"),
	("runtime_text_deep_object", "[Object]"),
	("runtime_text_colon", ": "),
	(
		"runtime_text_not_an_object",
		"x86: a property written on a value that is not an object is not compiled yet\n",
	),
	(
		"runtime_text_integer_key",
		"x86: an object with an integer key, which node orders first, is not compiled yet\n",
	),
	(
		"runtime_text_index_not_compiled",
		"x86: an index of this kind of value, or of this kind, is not compiled yet\n",
	),
	(
		"runtime_text_array_hole",
		"x86: an array written past its end, leaving holes, is not compiled yet\n",
	),
	(
		"runtime_text_not_an_array",
		"x86: an array method called on a value that is not an array is not compiled yet\n",
	),
	(
		"runtime_text_columns",
		"x86: console.log of an array that node lays out in columns is not compiled yet\n",
	),
	(
		"runtime_text_quotes",
		Str.concat(
			"x86: console.log of a string holding both quotes, or a control byte,",
			" inside an array or object is not compiled yet\n",
		),
	),
	(
		"runtime_text_text_of_object",
		"x86: a string made of an array or an object is not compiled yet\n",
	),
	(
		"runtime_text_text_of_function",
		"x86: a string made of a function, its source's text, is not compiled yet\n",
	),
	(
		"runtime_text_not_a_function",
		Str.concat(
			"x86: a call of a value that is not a function,",
			" which throws in node, is not compiled yet\n",
		),
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
		# Node's RangeError, thrown where a `try` waits, else its line.
		Emit.mark(Runtime.stack_overflow),
		Emit.load(Rcx, Runtime.handler_place),
		Emit.test(Rcx, Rcx),
		Emit.jcc(E, "runtime_stack_overflow_stop"),
		Emit.address_of(Rdi, Runtime.error_name_label("RangeError")),
		Emit.address_of(Rsi, "runtime_text_call_stack"),
		Emit.call(Runtime.new_error),
		Emit.jmp(Runtime.throw),
		Emit.mark("runtime_stack_overflow_stop"),
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
		Emit.cmp_imm(Rcx, Boxing.array_tag),
		Emit.jcc(E, "runtime_write_inspected"),
		Emit.cmp_imm(Rcx, Boxing.object_tag),
		Emit.jcc(E, "runtime_write_inspected"),
		Emit.cmp_imm(Rcx, Boxing.function_tag),
		Emit.jcc(E, "runtime_write_inspected"),
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
			Emit.mark("runtime_write_text"),
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.lea(Rsi, Emit.mem(Rdi, 8)),
			Emit.jmp(Runtime.write),
			Emit.mark("runtime_write_inspected"),
			Emit.zero(Rsi),
			Emit.call("runtime_inspect"),
			Emit.mov(Rdi, Rax),
			Emit.jmp("runtime_write_text"),
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
			Emit.cmp_imm(Rcx, Boxing.function_tag),
			Emit.jcc(E, "runtime_text_of_function"),
		])
		.concat(constant({ bits: Boxing.undefined_bits, label: "runtime_text_undefined" }))
		.concat(constant({ bits: Boxing.null_bits, label: "runtime_text_null" }))
		.concat(constant({ bits: Boxing.false_bits, label: "runtime_text_false" }))
		.concat(constant({ bits: Boxing.true_bits, label: "runtime_text_true" }))
		.concat(stopping_items("runtime_text_text_of_object"))
		.append(Emit.mark("runtime_text_of_function"))
		.concat(stopping_items("runtime_text_text_of_function"))
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
	check_function = [Emit.mark(Runtime.check_function)]
		.concat(tag_load_items(Rax))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.function_tag),
			Emit.jcc(Ne, "runtime_not_a_function_stop"),
			Emit.ret,
			Emit.mark("runtime_not_a_function_stop"),
		])
		.concat(stopping_items("runtime_text_not_a_function"))
	cell = [
		Emit.mark(Runtime.new_cell),
		Emit.imm(Rdi, 8),
		Emit.call(Runtime.allocate),
		Emit.store(Emit.mem(Rax, 0), Rsi),
		Emit.ret,
	]
	[
		add,
		check,
		equal,
		compare,
		truthy,
		check_function,
		cell,
	].join()
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
			Emit.cmp_imm(Rcx, Boxing.object_tag),
			Emit.jcc(E, "runtime_get_property_object"),
		])
		.concat(stopping_items("runtime_text_property_not_compiled"))
		.append(Emit.mark("runtime_get_property_object"))
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.mark("runtime_get_entry"),
			Emit.call("runtime_object_entry"),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_get_undefined"),
			Emit.load(Rax, Emit.mem(Rax, 0)),
			Emit.ret,
			Emit.mark("runtime_get_undefined"),
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.ret,
		])
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

## The statements that jump to `label` unless `rsi`, a number, is a whole
## number, which they leave in `rcx` (a negative one as a huge unsigned).
key_index_items : Str -> List(Assembly.Statement)
key_index_items = |label| [
	Emit.to_xmm(Xmm0, Rsi),
	Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
	Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
	Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
	Emit.jcc(P, label),
	Emit.jcc(Ne, label),
]

## The address of item `rcx` of the array at `rdi`, in `r8`. It changes
## `rcx`.
item_address_items : List(Assembly.Statement)
item_address_items = [
	Emit.load(R8, Emit.mem(Rdi, 16)),
	Emit.shl(Rcx, 3),
	Emit.plus(R8, Rcx),
]

## The statements that put the boxed value of the pointer in `rax`, with
## `tag`, in `rax`. They change `rcx`.
boxed_items : I64 -> List(Assembly.Statement)
boxed_items = |tag| [Emit.imm(Rcx, Boxing.tag_bits(tag)), Emit.plus(Rax, Rcx)]

## An array is 24 bytes, its length, its capacity and its items' address,
## and its items are 8 bytes each; an object is 24 bytes, its count of
## properties, its capacity and its entries' address, and its entries are
## 16 bytes each, a key's address (a string) and the value. A full list is
## copied to one twice its size. `runtime_object_entry` gives the address
## of the value of the key `rsi` (a string) in the object `rdi`, or 0,
## keeping `rsi`; `runtime_push_item` pushes `rsi` onto the array at `rdi`,
## its new length in `rax`.
container_items : List(Assembly.Statement)
container_items = {
	new_array = [
		Emit.mark(Runtime.new_array),
		Emit.save(Rdi),
		Emit.mov(Rcx, Rdi),
		Emit.cmp_imm(Rcx, 4),
		Emit.jcc(Ae, "runtime_new_array_sized"),
		Emit.imm(Rcx, 4),
		Emit.mark("runtime_new_array_sized"),
		Emit.save(Rcx),
		Emit.mov(Rdi, Rcx),
		Emit.shl(Rdi, 3),
		Emit.plus_imm(Rdi, 24),
		Emit.call(Runtime.allocate),
		Emit.restore(Rcx),
		Emit.restore(Rdx),
		Emit.store(Emit.mem(Rax, 0), Rdx),
		Emit.store(Emit.mem(Rax, 8), Rcx),
		Emit.lea(Rdx, Emit.mem(Rax, 24)),
		Emit.store(Emit.mem(Rax, 16), Rdx),
	]
		.concat(boxed_items(Boxing.array_tag))
		.append(Emit.ret)
	new_object = [
		Emit.mark(Runtime.new_object),
		Emit.imm(Rdi, 24 + 4 * 16),
		Emit.call(Runtime.allocate),
		Emit.zero(Rcx),
		Emit.store(Emit.mem(Rax, 0), Rcx),
		Emit.imm(Rcx, 4),
		Emit.store(Emit.mem(Rax, 8), Rcx),
		Emit.lea(Rdx, Emit.mem(Rax, 24)),
		Emit.store(Emit.mem(Rax, 16), Rdx),
	]
		.concat(boxed_items(Boxing.object_tag))
		.append(Emit.ret)
	entry = [
		Emit.mark("runtime_object_entry"),
		Emit.load(R10, Emit.mem(Rdi, 0)),
		Emit.shl(R10, 4),
		Emit.load(R11, Emit.mem(Rdi, 16)),
		Emit.zero(R9),
		Emit.mark("runtime_object_entry_next"),
		Emit.cmp(R9, R10),
		Emit.jcc(E, "runtime_object_entry_none"),
		Emit.load(
			Rdi,
			Emit.mem_index({
				base: R11,
				index: R9,
				displacement: 0,
			}),
		),
		Emit.call("runtime_text_equal"),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_object_entry_found"),
		Emit.plus_imm(R9, 16),
		Emit.jmp("runtime_object_entry_next"),
		Emit.mark("runtime_object_entry_found"),
		Emit.lea(
			Rax,
			Emit.mem_index({
				base: R11,
				index: R9,
				displacement: 8,
			}),
		),
		Emit.ret,
		Emit.mark("runtime_object_entry_none"),
		Emit.zero(Rax),
		Emit.ret,
	]
	set_property = [Emit.mark(Runtime.set_property)]
		.concat(tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.object_tag), Emit.jcc(Ne, "runtime_not_an_object")])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.save(Rdi),
			Emit.save(Rdx),
			Emit.call("runtime_object_entry"),
			Emit.restore(Rdx),
			Emit.restore(Rdi),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_set_property_new"),
			Emit.store(Emit.mem(Rax, 0), Rdx),
			Emit.ret,
			Emit.mark("runtime_set_property_new"),
			Emit.save(Rdi),
			Emit.mov(Rdi, Rsi),
			Emit.call("runtime_is_index_key"),
			Emit.restore(Rdi),
			Emit.test(Rax, Rax),
			Emit.jcc(Ne, "runtime_integer_key"),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(R8, Emit.mem(Rdi, 8)),
			Emit.cmp(Rcx, R8),
			Emit.jcc(B, "runtime_set_property_room"),
			Emit.save(Rdi),
			Emit.save(Rsi),
			Emit.save(Rdx),
			Emit.mov(Rdi, R8),
			Emit.shl(Rdi, 5),
			Emit.call(Runtime.allocate),
			Emit.restore(Rdx),
			Emit.restore(Rsi),
			Emit.restore(Rdi),
			Emit.load(R8, Emit.mem(Rdi, 8)),
			Emit.plus(R8, R8),
			Emit.store(Emit.mem(Rdi, 8), R8),
			Emit.save(Rsi),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.shl(Rcx, 4),
			Emit.load(Rsi, Emit.mem(Rdi, 16)),
			Emit.mov(R9, Rdi),
			Emit.mov(Rdi, Rax),
			Instruction(RepMovsb),
			Emit.store(Emit.mem(R9, 16), Rax),
			Emit.mov(Rdi, R9),
			Emit.restore(Rsi),
			Emit.mark("runtime_set_property_room"),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.mov(R8, Rcx),
			Emit.shl(R8, 4),
			Emit.load(R9, Emit.mem(Rdi, 16)),
			Emit.plus(R9, R8),
			Emit.store(Emit.mem(R9, 0), Rsi),
			Emit.store(Emit.mem(R9, 8), Rdx),
			Emit.plus_imm(Rcx, 1),
			Emit.store(Emit.mem(Rdi, 0), Rcx),
			Emit.ret,
			Emit.mark("runtime_not_an_object"),
		])
		.concat(stopping_items("runtime_text_not_an_object"))
		.append(Emit.mark("runtime_integer_key"))
		.concat(stopping_items("runtime_text_integer_key"))
	# A key is an array index when it is "0", or digits not starting with 0.
	index_key = [
		Emit.mark("runtime_is_index_key"),
		Emit.load(Rcx, Emit.mem(Rdi, 0)),
		Emit.test(Rcx, Rcx),
		Emit.jcc(E, "runtime_is_index_key_no"),
		Emit.zero(R8),
		text_byte_item({ reg: Rax, base: Rdi }),
		Emit.cmp_imm(Rax, '0'),
		Emit.jcc(Ne, "runtime_is_index_key_digit"),
		Emit.cmp_imm(Rcx, 1),
		Emit.jcc(E, "runtime_is_index_key_yes"),
		Emit.jmp("runtime_is_index_key_no"),
		Emit.mark("runtime_is_index_key_digit"),
		Emit.cmp(R8, Rcx),
		Emit.jcc(E, "runtime_is_index_key_yes"),
		text_byte_item({ reg: Rax, base: Rdi }),
		Emit.cmp_imm(Rax, '0'),
		Emit.jcc(B, "runtime_is_index_key_no"),
		Emit.cmp_imm(Rax, '9'),
		Emit.jcc(A, "runtime_is_index_key_no"),
		Emit.plus_imm(R8, 1),
		Emit.jmp("runtime_is_index_key_digit"),
		Emit.mark("runtime_is_index_key_yes"),
		Emit.imm(Rax, 1),
		Emit.ret,
		Emit.mark("runtime_is_index_key_no"),
		Emit.zero(Rax),
		Emit.ret,
	]
	push_item = [
		Emit.mark("runtime_push_item"),
		Emit.load(Rcx, Emit.mem(Rdi, 0)),
		Emit.load(R8, Emit.mem(Rdi, 8)),
		Emit.cmp(Rcx, R8),
		Emit.jcc(B, "runtime_push_item_room"),
		Emit.save(Rdi),
		Emit.save(Rsi),
		Emit.mov(Rdi, R8),
		Emit.shl(Rdi, 4),
		Emit.call(Runtime.allocate),
		Emit.restore(Rsi),
		Emit.restore(Rdi),
		Emit.load(R8, Emit.mem(Rdi, 8)),
		Emit.plus(R8, R8),
		Emit.store(Emit.mem(Rdi, 8), R8),
		Emit.save(Rsi),
		Emit.load(Rcx, Emit.mem(Rdi, 0)),
		Emit.shl(Rcx, 3),
		Emit.load(Rsi, Emit.mem(Rdi, 16)),
		Emit.mov(R9, Rdi),
		Emit.mov(Rdi, Rax),
		Instruction(RepMovsb),
		Emit.store(Emit.mem(R9, 16), Rax),
		Emit.mov(Rdi, R9),
		Emit.restore(Rsi),
		Emit.mark("runtime_push_item_room"),
		Emit.load(Rcx, Emit.mem(Rdi, 0)),
		Emit.mov(R9, Rcx),
	]
		.concat(item_address_items)
		.concat([
			Emit.store(Emit.mem(R8, 0), Rsi),
			Emit.plus_imm(R9, 1),
			Emit.store(Emit.mem(Rdi, 0), R9),
			Emit.mov(Rax, R9),
			Emit.ret,
		])
	array_receiver = |label|
		[Emit.mark(label)]
			.concat(tag_load_items(Rdi))
			.concat([Emit.cmp_imm(Rcx, Boxing.array_tag), Emit.jcc(Ne, "runtime_not_an_array")])
			.concat(unboxed_items(Rdi))
	push = array_receiver(Runtime.push)
		.concat([
			Emit.call("runtime_push_item"),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.ret,
		])
	pop = array_receiver(Runtime.pop)
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_get_undefined"),
			Emit.minus_imm(Rcx, 1),
			Emit.store(Emit.mem(Rdi, 0), Rcx),
		])
		.concat(item_address_items)
		.concat([
			Emit.load(Rax, Emit.mem(R8, 0)),
			Emit.ret,
			Emit.mark("runtime_not_an_array"),
		])
		.concat(stopping_items("runtime_text_not_an_array"))
	get_index = [Emit.mark(Runtime.get_index)]
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(E, "runtime_get_index_array"),
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(E, "runtime_get_index_string"),
			Emit.cmp_imm(Rcx, Boxing.object_tag),
			Emit.jcc(E, "runtime_get_index_object"),
			Emit.jmp("runtime_index_not_compiled"),
			Emit.mark("runtime_get_index_array"),
		])
		.concat(unless_number_items({ reg: Rsi, label: "runtime_index_not_compiled" }))
		.concat(key_index_items("runtime_get_undefined"))
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(Ae, "runtime_get_undefined"),
		])
		.concat(item_address_items)
		.concat([
			Emit.load(Rax, Emit.mem(R8, 0)),
			Emit.ret,
			Emit.mark("runtime_get_index_string"),
		])
		.concat(unless_number_items({ reg: Rsi, label: "runtime_index_not_compiled" }))
		.concat(key_index_items("runtime_get_undefined"))
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(Ae, "runtime_get_undefined"),
			Emit.save(Rdi),
			Emit.save(Rcx),
			Emit.imm(Rdi, 9),
			Emit.call(Runtime.allocate),
			Emit.restore(R8),
			Emit.restore(Rdi),
			Emit.imm(Rdx, 1),
			Emit.store(Emit.mem(Rax, 0), Rdx),
			text_byte_item({ reg: Rdx, base: Rdi }),
			Emit.byte_store(Emit.mem(Rax, 8), Dl),
		])
		.concat(boxed_string_items)
		.concat([Emit.ret, Emit.mark("runtime_get_index_object")])
		.concat(unboxed_items(Rdi))
		.concat(tag_load_items(Rsi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(E, "runtime_get_index_text"),
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(Ae, "runtime_index_not_compiled"),
			Emit.save(Rdi),
			Emit.mov(Rax, Rsi),
			Emit.call(Runtime.number_text),
			Emit.mov(Rsi, Rax),
			Emit.restore(Rdi),
			Emit.jmp("runtime_get_entry"),
			Emit.mark("runtime_get_index_text"),
		])
		.concat(unboxed_items(Rsi))
		.concat([Emit.jmp("runtime_get_entry"), Emit.mark("runtime_index_not_compiled")])
		.concat(stopping_items("runtime_text_index_not_compiled"))
	set_index = [Emit.mark(Runtime.set_index)]
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(E, "runtime_set_index_array"),
			Emit.cmp_imm(Rcx, Boxing.object_tag),
			Emit.jcc(Ne, "runtime_index_not_compiled"),
		])
		.concat(tag_load_items(Rsi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(E, "runtime_set_index_text"),
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(Ae, "runtime_index_not_compiled"),
			Emit.save(Rdi),
			Emit.save(Rdx),
			Emit.mov(Rax, Rsi),
			Emit.call(Runtime.number_text),
			Emit.mov(Rsi, Rax),
			Emit.restore(Rdx),
			Emit.restore(Rdi),
			Emit.jmp(Runtime.set_property),
			Emit.mark("runtime_set_index_text"),
		])
		.concat(unboxed_items(Rsi))
		.concat([Emit.jmp(Runtime.set_property), Emit.mark("runtime_set_index_array")])
		.concat(unless_number_items({ reg: Rsi, label: "runtime_index_not_compiled" }))
		.concat(key_index_items("runtime_index_not_compiled"))
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, R9),
			Emit.jcc(E, "runtime_set_index_append"),
			Emit.jcc(A, "runtime_array_hole"),
		])
		.concat(item_address_items)
		.concat([
			Emit.store(Emit.mem(R8, 0), Rdx),
			Emit.ret,
			Emit.mark("runtime_set_index_append"),
			Emit.mov(Rsi, Rdx),
			Emit.jmp("runtime_push_item"),
			Emit.mark("runtime_array_hole"),
		])
		.concat(stopping_items("runtime_text_array_hole"))
	[
		new_array,
		new_object,
		entry,
		set_property,
		index_key,
		push_item,
		push,
		pop,
		get_index,
		set_index,
	].join()
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
inspect_items : List(Assembly.Statement)
inspect_items = {
	dispatch = [Emit.mark("runtime_inspect")]
		.concat(tag_load_items(Rdi))
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
			Emit.jmp("runtime_text_of"),
			Emit.mark("runtime_inspect_number"),
			Emit.mov(Rax, Rdi),
			Emit.jmp(Runtime.number_text),
			Emit.mark("runtime_inspect_string"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.jmp("runtime_quoted"),
			Emit.mark("runtime_inspect_array"),
			Emit.zero(Rdx),
			Emit.jmp("runtime_inspect_list"),
			Emit.mark("runtime_inspect_object"),
			Emit.mov(Rax, Rdi),
		])
		.concat(unboxed_items(Rax))
		.concat([
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_inspect_plain"),
			Emit.load(Rcx, Emit.mem(Rax, 16)),
			Emit.load(Rcx, Emit.mem(Rcx, 0)),
			Emit.address_of(Rdx, error_mark),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(E, "runtime_inspect_error"),
			Emit.mark("runtime_inspect_plain"),
			Emit.imm(Rdx, 1),
			Emit.jmp("runtime_inspect_list"),
			# A function's text is its record's, 8 bytes in, by its distance.
			Emit.mark("runtime_inspect_function"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rax, Emit.mem(Rdi, 8)),
			Emit.plus(Rax, Rdi),
			Emit.plus_imm(Rax, 8),
			Emit.ret,
		])
	escape_scan =
		escapes
			.map(
				|(byte, _)| [
					Emit.cmp_imm(Rax, byte.to_i64()),
					Emit.jcc(E, "runtime_quoted_escaped"),
				],
			)
			.join()
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
	# r9: whether a ' is in it; r10: whether a " is; r11: the escapes.
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
		text_byte_item({ reg: Rax, base: Rdi }),
	]
		.concat(escape_scan)
		.concat([
			Emit.cmp_imm(Rax, 0x20),
			Emit.jcc(B, "runtime_quotes"),
			Emit.cmp_imm(Rax, 0x7F),
			Emit.jcc(E, "runtime_quotes"),
			Emit.cmp_imm(Rax, '\''),
			Emit.jcc(Ne, "runtime_quoted_not_single"),
			Emit.imm(R9, 1),
			Emit.mark("runtime_quoted_not_single"),
			Emit.cmp_imm(Rax, '"'),
			Emit.jcc(Ne, "runtime_quoted_next"),
			Emit.imm(R10, 1),
			Emit.jmp("runtime_quoted_next"),
			Emit.mark("runtime_quoted_escaped"),
			Emit.plus_imm(R11, 1),
			Emit.mark("runtime_quoted_next"),
			Emit.plus_imm(R8, 1),
			Emit.jmp("runtime_quoted_scan"),
			Emit.mark("runtime_quoted_scanned"),
			# The quote, in r9: ', or " when a ' is in it and no ".
			Emit.test(R9, R9),
			Emit.imm(R9, '\''),
			Emit.jcc(E, "runtime_quoted_chosen"),
			Emit.test(R10, R10),
			Emit.jcc(Ne, "runtime_quotes"),
			Emit.imm(R9, '"'),
			Emit.mark("runtime_quoted_chosen"),
			Emit.save(Rdi),
			Emit.save(R9),
			Emit.lea(
				Rdi,
				Emit.mem_index({
					base: Rcx,
					index: R11,
					displacement: 10,
				}),
			),
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
			text_byte_item({ reg: Rdx, base: R10 }),
		])
		.concat(escape_write)
		.concat([
			Emit.mov(Rax, Rdx),
			Emit.byte_store(Emit.mem(Rdi, 0), Al),
			Emit.plus_imm(Rdi, 1),
			Emit.mark("runtime_quoted_written"),
			Emit.plus_imm(R8, 1),
			Emit.jmp("runtime_quoted_copy"),
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
			Emit.mark("runtime_quotes"),
		])
		.concat(stopping_items("runtime_text_quotes"))
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
			text_byte_item({ reg: Rax, base: Rdi }),
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
	[dispatch, quoted, key_text, list_items].join()
}

## `runtime_inspect_list`: the array or object at `rdi` (`rdx` 0 for an
## array, 1 for an object) at the depth `rsi`, by `runtime_inspect`'s rule.
## Its frame holds the list (`[rbp - 8]`), the depth (16), the kind (24),
## the count (32), the entries' texts (40), the next entry (48), the sum of
## their lengths (56), the longest (64), whether one holds a line break
## (72) and the result (80).
list_items : List(Assembly.Statement)
list_items = {
	local = |offset| Emit.mem(Rbp, 0 - offset)
	start = [
		Emit.mark("runtime_inspect_list"),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 96),
	]
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.store(local(8), Rdi),
			Emit.store(local(16), Rsi),
			Emit.store(local(24), Rdx),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.store(local(32), Rcx),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_inspect_empty"),
			Emit.cmp_imm(Rsi, 2),
			Emit.jcc(A, "runtime_inspect_deep"),
			Emit.cmp_imm(Rcx, 100),
			Emit.jcc(A, "runtime_columns"),
			Emit.lea(Rax, Emit.mem(Rsi, 1)),
			Emit.store(Emit.mem(R13, 8), Rax),
			Emit.mov(Rdi, Rcx),
			Emit.shl(Rdi, 3),
			Emit.call(Runtime.allocate),
			Emit.store(local(40), Rax),
			Emit.zero(Rax),
			Emit.store(local(48), Rax),
			Emit.store(local(56), Rax),
			Emit.store(local(64), Rax),
			Emit.store(local(72), Rax),
		])
	entries = [
		Emit.mark("runtime_inspect_entry"),
		Emit.load(Rcx, local(48)),
		Emit.load(Rdx, local(32)),
		Emit.cmp(Rcx, Rdx),
		Emit.jcc(E, "runtime_inspect_measured"),
		Emit.load(R8, local(8)),
		Emit.load(R9, Emit.mem(R8, 16)),
		Emit.load(Rax, local(24)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_inspect_property"),
		Emit.shl(Rcx, 3),
		Emit.plus(R9, Rcx),
		Emit.load(Rdi, Emit.mem(R9, 0)),
		Emit.load(Rsi, local(16)),
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
		Emit.load(Rsi, local(16)),
		Emit.plus_imm(Rsi, 1),
		Emit.call("runtime_inspect"),
		Emit.mov(Rsi, Rax),
		Emit.restore(Rdi),
		Emit.call("runtime_concat"),
		Emit.mark("runtime_inspect_store"),
		Emit.load(Rcx, local(48)),
		Emit.load(R8, local(40)),
		Emit.mov(R9, Rcx),
		Emit.shl(R9, 3),
		Emit.plus(R8, R9),
		Emit.store(Emit.mem(R8, 0), Rax),
		Emit.load(Rdx, Emit.mem(Rax, 0)),
		Emit.load(R8, local(56)),
		Emit.plus(R8, Rdx),
		Emit.store(local(56), R8),
		Emit.load(R8, local(64)),
		Emit.cmp(Rdx, R8),
		Emit.jcc(Be, "runtime_inspect_not_longest"),
		Emit.store(local(64), Rdx),
		Emit.mark("runtime_inspect_not_longest"),
		Emit.zero(R8),
		Emit.mark("runtime_inspect_break_scan"),
		Emit.cmp(R8, Rdx),
		Emit.jcc(E, "runtime_inspect_scanned"),
		text_byte_item({ reg: R9, base: Rax }),
		Emit.cmp_imm(R9, 10),
		Emit.jcc(Ne, "runtime_inspect_no_break"),
		Emit.imm(R9, 1),
		Emit.store(local(72), R9),
		Emit.mark("runtime_inspect_no_break"),
		Emit.plus_imm(R8, 1),
		Emit.jmp("runtime_inspect_break_scan"),
		Emit.mark("runtime_inspect_scanned"),
		Emit.plus_imm(Rcx, 1),
		Emit.store(local(48), Rcx),
		Emit.jmp("runtime_inspect_entry"),
	]
	# rcx: the count; r10: the indentation, two spaces a level.
	measured = [
		Emit.mark("runtime_inspect_measured"),
		Emit.load(Rcx, local(32)),
		Emit.load(R10, local(16)),
		Emit.plus(R10, R10),
		Emit.load(Rax, local(24)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_inspect_ungrouped"),
		Emit.cmp_imm(Rcx, 6),
		Emit.jcc(Be, "runtime_inspect_ungrouped"),
		# Node groups an array of more than 6 items into columns when three
		# of its longest fit a line and its items are alike in length.
		Emit.load(R11, local(56)),
		Emit.plus(R11, Rcx),
		Emit.plus(R11, Rcx),
		Emit.load(R9, local(64)),
		Emit.plus_imm(R9, 2),
		Emit.mov(Rax, R9),
		Emit.plus(Rax, R9),
		Emit.plus(Rax, R9),
		Emit.plus(Rax, R10),
		Emit.cmp_imm(Rax, 80),
		Emit.jcc(Ae, "runtime_inspect_ungrouped"),
		Emit.load(Rax, local(64)),
		Emit.cmp_imm(Rax, 6),
		Emit.jcc(Be, "runtime_columns"),
		Emit.mov(Rax, R9),
		Emit.shl(Rax, 2),
		Emit.plus(Rax, R9),
		Emit.cmp(R11, Rax),
		Emit.jcc(A, "runtime_columns"),
		Emit.mark("runtime_inspect_ungrouped"),
		Emit.load(Rax, Emit.mem(R13, 8)),
		Emit.load(R8, local(16)),
		Emit.plus_imm(R8, 4),
		Emit.cmp(Rax, R8),
		Emit.jcc(Ae, "runtime_inspect_lines"),
		Emit.load(Rax, local(72)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_inspect_lines"),
		Emit.load(Rax, local(56)),
		Emit.plus(Rax, Rcx),
		Emit.plus(Rax, Rcx),
		Emit.plus(Rax, R10),
		Emit.plus_imm(Rax, 11),
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
		Emit.load(Rax, local(56)),
		Emit.plus(Rdi, Rax),
		Emit.plus(Rdi, R10),
		Emit.plus_imm(Rdi, 24),
		Emit.save(R10),
		Emit.call(Runtime.allocate),
		Emit.restore(R10),
		Emit.store(local(80), Rax),
		Emit.lea(Rdi, Emit.mem(Rax, 8)),
		Emit.zero(R11),
	]
	one_line =
		room("runtime_inspect_one_line")
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
				Emit.load(Rcx, local(32)),
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
			.concat(
				brace_written_items({
					label: "runtime_inspect_lines_open",
					array: '[',
					object: '{',
				}),
			)
			.concat([
				Emit.mark("runtime_inspect_lines_next"),
				Emit.load(Rcx, local(32)),
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
		Emit.load(Rax, local(80)),
		Emit.mov(Rcx, Rdi),
		Emit.minus(Rcx, Rax),
		Emit.minus_imm(Rcx, 8),
		Emit.store(Emit.mem(Rax, 0), Rcx),
		Emit.mark("runtime_inspect_leave"),
		Emit.mov(Rsp, Rbp),
		Emit.restore(Rbp),
		Emit.ret,
	]
	fixed = |{ label, array, object }| [
		Emit.mark(label),
		Emit.address_of(Rax, array),
		Emit.load(Rcx, local(24)),
		Emit.test(Rcx, Rcx),
		Emit.jcc(E, "runtime_inspect_leave"),
		Emit.address_of(Rax, object),
		Emit.jmp("runtime_inspect_leave"),
	]
	[
		start,
		entries,
		measured,
		one_line,
		lines,
		finish,
		fixed({
			label: "runtime_inspect_empty",
			array: "runtime_text_empty_array",
			object: "runtime_text_empty_object",
		}),
		fixed({
			label: "runtime_inspect_deep",
			array: "runtime_text_deep_array",
			object: "runtime_text_deep_object",
		}),
		[Emit.mark("runtime_columns")],
		stopping_items("runtime_text_columns"),
	]
		.join()
}

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

## `runtime_remainder`, by `idiv`: the remainder has the dividend's sign,
## and a zero one is -0 when the dividend is negative; `% 0` is NaN.
## `runtime_next_item`, for `for ... of`.
loop_items : List(Assembly.Statement)
loop_items = {
	remainder = [Emit.mark(Runtime.remainder)]
		.concat(unless_number_items({ reg: Rdi, label: "runtime_not_a_number_stop" }))
		.concat(unless_number_items({ reg: Rsi, label: "runtime_not_a_number_stop" }))
		.concat(
			whole_number_items({
				reg: Rdi,
				to: R8,
				label: "runtime_remainder_stop",
			}),
		)
		.concat(
			whole_number_items({
				reg: Rsi,
				to: R9,
				label: "runtime_remainder_stop",
			}),
		)
		.concat([
			Emit.test(R9, R9),
			Emit.jcc(E, "runtime_remainder_not_a_number"),
			Emit.mov(Rax, R8),
			Instruction(Cqo),
			Instruction(Idiv(R9)),
			Emit.test(Rdx, Rdx),
			Emit.jcc(E, "runtime_remainder_zero"),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rdx })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.ret,
			Emit.mark("runtime_remainder_zero"),
			Emit.zero(Rax),
			Emit.test(Rdi, Rdi),
			Emit.jcc(Ns, "runtime_remainder_done"),
			Emit.imm(Rax, (0x8000000000000000).to_i64_wrap()),
			Emit.mark("runtime_remainder_done"),
			Emit.ret,
			Emit.mark("runtime_remainder_not_a_number"),
			Emit.imm(Rax, 0x7FF8000000000000),
			Emit.ret,
			Emit.mark("runtime_remainder_stop"),
		])
		.concat(stopping_items("runtime_text_remainder"))
	next_item = [Emit.mark(Runtime.next_item)]
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.to_xmm(Xmm0, Rsi),
			Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(Ae, "runtime_next_item_none"),
		])
		.concat(item_address_items)
		.concat([
			Emit.load(Rax, Emit.mem(R8, 0)),
			Emit.imm(Rdx, 1),
			Emit.ret,
			Emit.mark("runtime_next_item_none"),
			Emit.zero(Rdx),
			Emit.ret,
		])
	[remainder, next_item].join()
}

## The statements that stop the program unless the value in `rdi` is an
## array. They change `rcx`.
array_check_items : List(Assembly.Statement)
array_check_items =
	tag_load_items(Rdi).concat([
		Emit.cmp_imm(Rcx, Boxing.array_tag),
		Emit.jcc(Ne, "runtime_not_an_array"),
	])

## The address of item `index` of the items whose address is in `r8`.
listed_item : X86.Register -> X86.Mem
listed_item = |index| Based({
	base: R8,
	index: Scaled({ reg: index, scale: Times8 }),
	displacement: 0,
})

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
	local = |offset| Emit.mem(Rbp, 0 - offset)
	call_back = [
		Emit.mark("runtime_call_back"),
		Emit.save(Rcx),
		Instruction(Cvtsi2sd({ to: Xmm0, from: Rdx })),
		Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
		Emit.save(Rax),
		Emit.save(Rsi),
		Emit.mov(Rbx, Rdi),
	]
		.concat(unboxed_items(Rbx))
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
		Emit.imm(Rdx, 2),
	]
	start = [
		Emit.mark("runtime_walk"),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 48),
	]
		.concat(array_check_items)
		.concat([Emit.mov(Rax, Rsi), Emit.call(Runtime.check_function)])
		.concat([
			Emit.store(local(8), Rdi),
			Emit.store(local(16), Rsi),
			Emit.store(local(24), Rdx),
			Emit.zero(Rax),
			Emit.store(local(32), Rax),
			Emit.zero(Rcx),
			Emit.test(Rdx, Rdx),
			Emit.jcc(Ne, "runtime_walk_sized"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.mark("runtime_walk_sized"),
			Emit.mov(Rdi, Rcx),
			Emit.call(Runtime.new_array),
			Emit.store(local(40), Rax),
		])
	walk = [Emit.mark("runtime_walk_next"), Emit.load(Rdi, local(8))]
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(Rdx, local(32)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_walk_done"),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rsi, listed_item(Rdx)),
			Emit.store(local(48), Rsi),
			Emit.load(Rdi, local(16)),
			Emit.load(Rcx, local(8)),
			Emit.call("runtime_call_back"),
			Emit.load(Rdx, local(24)),
			Emit.test(Rdx, Rdx),
			Emit.jcc(Ne, "runtime_walk_kept"),
			Emit.load(Rdi, local(40)),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rdx, local(32)),
			Emit.store(listed_item(Rdx), Rax),
			Emit.jmp("runtime_walk_stepped"),
			Emit.mark("runtime_walk_kept"),
			Emit.cmp_imm(Rdx, 1),
			Emit.jcc(Ne, "runtime_walk_stepped"),
			Emit.mov(Rdi, Rax),
			Emit.call(Runtime.truthy),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_walk_stepped"),
			Emit.load(Rdi, local(40)),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rsi, local(48)),
			Emit.call("runtime_push_item"),
			Emit.mark("runtime_walk_stepped"),
			Emit.load(Rax, local(32)),
			Emit.plus_imm(Rax, 1),
			Emit.store(local(32), Rax),
			Emit.jmp("runtime_walk_next"),
			Emit.mark("runtime_walk_done"),
			Emit.load(Rax, local(40)),
			Emit.load(Rdx, local(24)),
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
		.concat(array_check_items)
		.concat([
			Emit.mov(Rax, Rsi),
			Emit.call(Runtime.check_function),
			Emit.store(local(8), Rdi),
			Emit.store(local(16), Rsi),
			Emit.store(local(24), Rdx),
			Emit.zero(Rax),
			Emit.store(local(32), Rax),
			Emit.cmp_imm(R11, 2),
			Emit.jcc(E, "runtime_reduce_next"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_reduce_empty"),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rax, Emit.mem(R8, 0)),
			Emit.store(local(24), Rax),
			Emit.imm(Rax, 1),
			Emit.store(local(32), Rax),
			Emit.mark("runtime_reduce_next"),
			Emit.load(Rdi, local(8)),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(Rdx, local(32)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_reduce_done"),
			Emit.load(Rax, local(8)),
			Emit.save(Rax),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rdx })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.save(Rax),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rax, listed_item(Rdx)),
			Emit.save(Rax),
			Emit.load(Rax, local(24)),
			Emit.save(Rax),
			Emit.load(Rbx, local(16)),
		])
		.concat(unboxed_items(Rbx))
		.concat([
			Emit.load(Rax, Emit.mem(Rbx, 0)),
			Emit.plus(Rax, Rbx),
			Emit.imm(Rcx, 4),
			Instruction(CallReg(Rax)),
			Emit.plus_imm(Rsp, 32),
			Emit.store(local(24), Rax),
			Emit.load(Rax, local(32)),
			Emit.plus_imm(Rax, 1),
			Emit.store(local(32), Rax),
			Emit.jmp("runtime_reduce_next"),
			Emit.mark("runtime_reduce_done"),
			Emit.load(Rax, local(24)),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
			Emit.mark("runtime_reduce_empty"),
		])
		.concat(stopping_items("runtime_text_empty_reduce"))
	[call_back, kinds, start, walk, reduce].join()
}

## `runtime_join`, `runtime_slice` and `runtime_char_at`. join's frame holds
## the array (`[rbp - 8]`), the separator (16), the text so far (24) and
## the place (32).
slice_items : List(Assembly.Statement)
slice_items = {
	local = |offset| Emit.mem(Rbp, 0 - offset)
	join = [
		Emit.mark(Runtime.join),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 32),
	]
		.concat(array_check_items)
		.concat([
			Emit.store(local(8), Rdi),
			Emit.store(local(16), Rsi),
			Emit.address_of(Rax, "runtime_text_empty"),
			Emit.store(local(24), Rax),
			Emit.zero(Rax),
			Emit.store(local(32), Rax),
			Emit.mark("runtime_join_next"),
			Emit.load(Rdi, local(8)),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(Rdx, local(32)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_join_done"),
			Emit.test(Rdx, Rdx),
			Emit.jcc(E, "runtime_join_item"),
			Emit.load(Rdi, local(24)),
			Emit.load(Rsi, local(16)),
			Emit.call("runtime_concat"),
			Emit.store(local(24), Rax),
			Emit.mark("runtime_join_item"),
			Emit.load(Rdi, local(8)),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rdx, local(32)),
			Emit.load(Rdi, listed_item(Rdx)),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rdi, Rcx),
			Emit.jcc(E, "runtime_join_stepped"),
			Emit.imm(Rcx, Boxing.null_bits),
			Emit.cmp(Rdi, Rcx),
			Emit.jcc(E, "runtime_join_stepped"),
			Emit.call("runtime_text_of"),
			Emit.mov(Rsi, Rax),
			Emit.load(Rdi, local(24)),
			Emit.call("runtime_concat"),
			Emit.store(local(24), Rax),
			Emit.mark("runtime_join_stepped"),
			Emit.load(Rax, local(32)),
			Emit.plus_imm(Rax, 1),
			Emit.store(local(32), Rax),
			Emit.jmp("runtime_join_next"),
			Emit.mark("runtime_join_done"),
			Emit.load(Rax, local(24)),
		])
		.concat(boxed_string_items)
		.concat([
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
		])
	# A place given as a number, made a whole one counted from the start:
	# from the end when negative, then held between 0 and the length (r9).
	place = |{ reg, label }|
		unless_number_items({ reg, label: "runtime_slice_not_a_number" })
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
	slice = [Emit.mark(Runtime.slice), Emit.mov(R11, Rcx)]
		.concat(array_check_items)
		.concat(unboxed_items(Rdi))
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
			Emit.lea(Rsi, listed_item(Rsi)),
			Emit.shl(Rcx, 3),
			Instruction(RepMovsb),
			Emit.ret,
			Emit.mark("runtime_slice_not_a_number"),
		])
		.concat(stopping_items("runtime_text_slice_place"))
	char_at = [Emit.mark(Runtime.char_at)]
		.concat(unless_string_items({ reg: Rdi, label: "runtime_index_not_compiled" }))
		.concat([
			Emit.call(Runtime.get_index),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ne, "runtime_char_at_found"),
			Emit.address_of(Rax, "runtime_text_empty"),
		])
		.concat(boxed_string_items)
		.concat([Emit.mark("runtime_char_at_found"), Emit.ret])
	[join, slice, char_at].join()
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
			whole_number_items({
				reg: Rdi,
				to: R10,
				label: "runtime_power_stop",
			}),
		)
		.concat(
			whole_number_items({
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
		.concat(stopping_items("runtime_text_power"))
	typed = |{ label, text }| [
		Emit.mark(label),
		Emit.address_of(Rax, text),
		Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)),
		Emit.plus(Rax, Rcx),
		Emit.ret,
	]
	type_of = [Emit.mark(Runtime.type_of)]
		.concat(tag_load_items(Rdi))
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
	]
	# r10: the string; r9: its length; r11: the array; rdx: its items.
	items_of = [Emit.mark(Runtime.items_of), Emit.mov(Rax, Rdi)]
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(E, "runtime_items_of_done"),
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(Ne, "runtime_not_iterable"),
		])
		.concat(unboxed_items(Rdi))
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
			Emit.imm(Rdi, 9),
			Emit.call(Runtime.allocate),
			Emit.imm(Rcx, 1),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			text_byte_item({ reg: Rcx, base: R10 }),
			Emit.byte_store(Emit.mem(Rax, 8), Cl),
		])
		.concat(boxed_string_items)
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
		.concat(stopping_items("runtime_text_not_iterable"))
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
		.concat(stopping_items("runtime_text_not_destructurable"))
	[power, type_of, pack, items_of, check_destructurable].join()
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
		.concat(stopping_items("runtime_text_uncaught"))
		.append(Emit.mark("runtime_inspect_error"))
		.concat(stopping_items("runtime_text_error_written"))
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
			Emit.address_of(Rsi, error_mark),
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
	message = [
		Emit.mark(Runtime.error_message),
		Emit.imm(Rcx, Boxing.undefined_bits),
		Emit.cmp(Rdi, Rcx),
		Emit.jcc(Ne, "runtime_text_of"),
		Emit.address_of(Rax, "runtime_text_empty"),
		Emit.ret,
	]
	[throw, new_error, message].join()
}
