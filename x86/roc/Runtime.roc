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

	## The routine that gives the number of `rdi`, a number, `undefined`,
	## `null` or a boolean, in `rax`, as `+` makes one (JavaScript's
	## ToNumber). It changes `rcx` alone.
	to_number : Str
	to_number = "runtime_to_number"

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
	## The message of node's TypeError for a constant assigned.
	constant_assigned_text : Str
	constant_assigned_text = "runtime_text_constant_assigned"

	## The message of node's TypeError for `Map()` or `Set()` called
	## without `new`.
	new_required_text : Str -> Str
	new_required_text = |name| "runtime_text_new_required_${name}"

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

	## The routine of a function of `Math`, by its name: of one number,
	## `floor`, `ceil`, `round`, `trunc`, `abs`, `sign` and `sqrt`, its bits
	## in `rdi`; of two, `max` and `min`, the second in `rsi`; the answer's
	## bits in `rax`. Each changes `rcx`, `rdx` and `xmm0` to `xmm2` too.
	math_routine : Str -> Str
	math_routine = |name| "runtime_math_${name}"

	## The functions of `Math` the runtime has a routine for.
	math_functions : List(Str)
	math_functions = ["floor", "ceil", "round", "trunc", "abs", "sign", "sqrt", "max", "min"]

	## The routine that gives the object `rdi`'s keys (`rsi` 0), its values
	## (1) or its entries (2), each a `[key, value]` array, a new array in
	## `rax`, as `Object.keys`, `values` and `entries` do.
	object_listing : Str
	object_listing = "runtime_object_listing"

	## The routine of `some`, `every`, `find` and `findIndex` (`rdx` 0 to 3)
	## of the array `rdi` and the function `rsi`, which it calls as `map`
	## does; it stops at the first item that settles the answer.
	search : Str
	search = "runtime_search"

	## The routine of `indexOf` (`r8` 0) and `includes` (1) of the array or
	## string `rdi`, the value `rsi` sought from the place `rdx` (a number,
	## when `rcx` is 2): the place, or -1, or whether it was found.
	index_of : Str
	index_of = "runtime_index_of"

	## The routine that appends to the array `rdi` (unboxed) the items of
	## `rsi` when it is an array, else `rsi` itself, as `concat` does.
	concat_item : Str
	concat_item = "runtime_concat_item"

	## The routine that sorts the array `rdi` in place, by the function
	## `rsi`, or by the items' texts when `rsi` is `undefined`, stably, the
	## `undefined` items last: the array in `rax`.
	sort : Str
	sort = "runtime_sort"

	## The routine that reverses the array `rdi` in place: the array in `rax`.
	reverse : Str
	reverse = "runtime_reverse"

	## The routine that gives the code of the character of the string `rdi`
	## at the place `rsi` (a number), or NaN past its end.
	char_code_at : Str
	char_code_at = "runtime_char_code_at"

	## The routine that splits the string `rdi` at each place the string
	## `rsi` is found, a new array of the pieces in `rax`; `""` splits it
	## into its characters.
	split : Str
	split = "runtime_split"

	## The routine that calls the function `rdi` through its value with the
	## items of the array `rsi` as its arguments: a call with a spread.
	call_spread : Str
	call_spread = "runtime_call_spread"

	## The routine that writes the items of the array `rdi` as
	## `console.log` writes its arguments, a line: `console.log(...xs)`.
	log_spread : Str
	log_spread = "runtime_log_spread"

	## The routine that gives `Math.max` (`rsi` 0) or `Math.min` (1) of the
	## items of the array `rdi`.
	extreme_of : Str
	extreme_of = "runtime_extreme_of"

	## The routine that sets on the object `rdi` the properties of `rsi`, as
	## `{ ...rsi }` does: an object's, none of a number, a boolean, `null`
	## or `undefined`.
	spread_fields : Str
	spread_fields = "runtime_spread_fields"

	## The routine that gives a new object of the properties of `rdi` but
	## those whose keys are the strings of the array `rsi`: an object
	## pattern's rest.
	properties_left : Str
	properties_left = "runtime_properties_left"

	## The routine that gives what `splice` removes from the array `rdi`,
	## an array, the arguments given in the array `rsi`, and changes it.
	splice : Str
	splice = "runtime_splice"

	## The routine that gives `lastIndexOf` of `rsi` in the array or the
	## string `rdi`.
	last_index_of : Str
	last_index_of = "runtime_last_index_of"

	## The routine that gives `String.fromCharCode` of the numbers in the
	## array `rdi`, a string.
	from_char_codes : Str
	from_char_codes = "runtime_from_char_codes"

	## The routine that gives `Array.from` of `rdi`, mapped by the function
	## `rsi` unless it is `undefined`.
	array_from : Str
	array_from = "runtime_array_from"

	## The routine that gives a new Map (`rdi` 0) or Set (1) of the items of
	## `rsi`, or of none when it is `undefined` or `null`.
	new_collection : Str
	new_collection = "runtime_new_collection"

	## The routine that gives a Map's or a Set's method `rcx` (0 get, 1 set,
	## 2 has, 3 delete, 4 clear, 5 add, 6 keys, 7 values, 8 entries) of the
	## receiver `rdi` with the arguments in the array `rdx`; of any other
	## receiver, the method its property named `rsi` holds, called.
	collection_method : Str
	collection_method = "runtime_collection_method"

	## The routine that gives what a `for ... of` walks of `rdi`: an array,
	## a Map, a Set or an iterator as it is, a string as its characters.
	iter_start : Str
	iter_start = "runtime_iter_start"

	## The routine that gives `String(v)` of the value `rdi`, boxed, in `rax`.
	text_of : Str
	text_of = "runtime_text_of_boxed"

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
		builtin_items,
		search_items,
		sort_items,
		string_method_items,
		spread_items,
		edit_items,
		collection_items,
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
	("runtime_text_size", "size"),
	("runtime_text_entry_before", "Iterator value "),
	("runtime_text_entry_after", " is not an entry object"),
	("runtime_text_object_map", "[object Map]"),
	("runtime_text_object_set", "[object Set]"),
	("runtime_text_map_open", "Map("),
	("runtime_text_set_open", "Set("),
	("runtime_text_size_close", ") "),
	("runtime_text_empty_map", "Map(0) {}"),
	("runtime_text_empty_set", "Set(0) {}"),
	("runtime_text_deep_map", "[Map]"),
	("runtime_text_deep_set", "[Set]"),
	("runtime_text_arrow", " => "),
	(Runtime.new_required_text("Map"), "Constructor Map requires 'new'"),
	(Runtime.new_required_text("Set"), "Constructor Set requires 'new'"),
	(
		"runtime_text_collection_method",
		"x86: this method of a Map, a Set or an iterator is not compiled yet\n",
	),
	(
		"runtime_text_iterator_written",
		"x86: console.log of an iterator, or a string made of one, is not compiled yet\n",
	),
	("runtime_text_cannot_read", "Cannot read properties of "),
	(Runtime.constant_assigned_text, "Assignment to constant variable."),
	("runtime_text_cannot_set", "Cannot set properties of "),
	("runtime_text_reading", " (reading '"),
	("runtime_text_setting", " (setting '"),
	("runtime_text_quote_closed", "')"),
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
		"runtime_text_wide_char",
		"x86: `String.fromCharCode` of a code past ASCII is not compiled yet\n",
	),
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
		"x86: an object with an integer key of ten digits or more is not compiled yet\n",
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
		"runtime_text_many",
		"x86: console.log of an array or object of more than 100 items is not compiled yet\n",
	),
	(
		"runtime_text_object_keys",
		Str.concat(
			"x86: `Object.keys`, `values` or `entries` of a value that is not a plain object",
			" is not compiled yet\n",
		),
	),
	("runtime_text_object_object", "[object Object]"),
	(
		"runtime_text_rest_listed",
		"x86: an object pattern's rest of an array or a string is not compiled yet\n",
	),
	(
		"runtime_text_spread_error",
		"x86: an error's properties spread or taken by a pattern's rest are not compiled yet\n",
	),
	(
		"runtime_text_index_of_place",
		"x86: `indexOf` or `includes` from a place that is not a number is not compiled yet\n",
	),
	(
		"runtime_text_index_of_sought",
		Str.concat(
			"x86: a string's `indexOf` or `includes` of a value that is not a string",
			" is not compiled yet\n",
		),
	),
	(
		"runtime_text_sort_answer",
		Str.concat(
			"x86: a `sort` whose function gives a value that is not a number, a boolean",
			" or undefined is not compiled yet\n",
		),
	),
	(
		"runtime_text_split_separator",
		"x86: `split` at a value that is not a string is not compiled yet\n",
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
		"x86: `+` of a function, which node makes its source's text, is not compiled yet\n",
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
		Emit.cmp_imm(Rcx, Boxing.collection_tag),
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
			Emit.cmp_imm(Rcx, Boxing.collection_tag),
			Emit.jcc(E, "runtime_text_of_collection"),
		])
		.concat(constant({ bits: Boxing.undefined_bits, label: "runtime_text_undefined" }))
		.concat(constant({ bits: Boxing.null_bits, label: "runtime_text_null" }))
		.concat(constant({ bits: Boxing.false_bits, label: "runtime_text_false" }))
		.concat(constant({ bits: Boxing.true_bits, label: "runtime_text_true" }))
		# An array is its items' texts joined with `,`; a plain object is
		# `[object Object]`; an error is its name and its message.
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(Ne, "runtime_text_of_object"),
			Emit.address_of(Rsi, Runtime.comma_text),
			Emit.call(Runtime.join),
		])
		.concat(unboxed_items(Rax))
		.concat([
			Emit.ret,
			Emit.mark("runtime_text_of_object"),
			Emit.mov(Rax, Rdi),
		])
		.concat(unboxed_items(Rax))
		.concat([
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_text_of_plain"),
			Emit.load(Rcx, Emit.mem(Rax, 16)),
			Emit.load(Rcx, Emit.mem(Rcx, 0)),
			Emit.address_of(Rdx, error_mark),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(E, "runtime_error_text"),
			Emit.mark("runtime_text_of_plain"),
			Emit.address_of(Rax, "runtime_text_object_object"),
			Emit.ret,
		])
		.append(Emit.mark("runtime_text_of_function"))
		.concat(stopping_items("runtime_text_text_of_function"))
		.append(Emit.mark("runtime_text_of_collection"))
		.concat(unboxed_items(Rax))
		.concat([
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.address_of(Rax, "runtime_text_object_map"),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_text_of_collection_done"),
			Emit.address_of(Rax, "runtime_text_object_set"),
			Emit.cmp_imm(Rcx, 1),
			Emit.jcc(E, "runtime_text_of_collection_done"),
			Emit.jmp("runtime_iterator_written"),
			Emit.mark("runtime_text_of_collection_done"),
			Emit.ret,
			Emit.mark("runtime_iterator_written"),
		])
		.concat(stopping_items("runtime_text_iterator_written"))
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

## The statements that jump to `runtime_add_texts` when the value in `reg`
## is an array or an object, which `+` makes a string.
object_added_items : X86.Register -> List(Assembly.Statement)
object_added_items = |reg|
	tag_load_items(reg).concat([
		Emit.cmp_imm(Rcx, Boxing.array_tag),
		Emit.jcc(E, "runtime_add_texts"),
		Emit.cmp_imm(Rcx, Boxing.object_tag),
		Emit.jcc(E, "runtime_add_texts"),
	])

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
		# An array or an object is made a string first, so `+` joins.
		.concat(object_added_items(Rdi))
		.concat(object_added_items(Rsi))
		# A function would be its source's text; anything else left is a
		# number, `undefined`, `null` or a boolean, each made a number.
		.concat(tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.function_tag), Emit.jcc(E, "runtime_add_stop")])
		.concat(tag_load_items(Rsi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.function_tag),
			Emit.jcc(E, "runtime_add_stop"),
			Emit.call(Runtime.to_number),
			Emit.mov(Rdi, Rsi),
			Emit.mov(Rsi, Rax),
			Emit.call(Runtime.to_number),
			Emit.to_xmm(Xmm0, Rsi),
			Emit.to_xmm(Xmm1, Rax),
			Emit.double_sum(Xmm0, Xmm1),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.ret,
			Emit.mark("runtime_add_stop"),
		])
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
	# The constants' payloads are 0 to 3: `undefined` NaN, `null` and
	# `false` 0, `true` 1.
	to_number = [Emit.mark(Runtime.to_number), Emit.mov(Rax, Rdi)]
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(B, "runtime_to_number_done"),
			Emit.mov(Rcx, Rdi),
		])
		.concat(unboxed_items(Rcx))
		.concat([
			Emit.imm(Rax, 0x7FF8000000000000),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_to_number_done"),
			Emit.imm(Rax, double_bits(1.0)),
			Emit.cmp_imm(Rcx, 3),
			Emit.jcc(E, "runtime_to_number_done"),
			Emit.zero(Rax),
			Emit.mark("runtime_to_number_done"),
			Emit.ret,
		])
	[
		add,
		check,
		equal,
		compare,
		truthy,
		check_function,
		cell,
		to_number,
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
			Emit.cmp_imm(Rcx, Boxing.collection_tag),
			Emit.jcc(E, "runtime_get_size"),
		])
		.concat(nullish_jump_items("runtime_get_property_nullish"))
		.concat(stopping_items("runtime_text_property_not_compiled"))
		.concat([
			Emit.mark("runtime_get_property_nullish"),
			Emit.zero(Rdx),
			Emit.jmp("runtime_property_error"),
			# A Map's or a Set's `size`; any other property is undefined.
			Emit.mark("runtime_get_size"),
			Emit.save(Rdi),
			Emit.mov(Rdi, Rsi),
			Emit.address_of(Rsi, "runtime_text_size"),
			Emit.call("runtime_text_equal"),
			Emit.restore(Rdi),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_get_undefined"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.cmp_imm(Rcx, 2),
			Emit.jcc(E, "runtime_get_undefined"),
			Emit.load(Rax, Emit.mem(Rdi, 8)),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.ret,
		])
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

## The statements that jump to `label` when the value in `rdi`, a
## property's or an index's receiver, is `undefined` or `null`. They change
## `rcx`.
nullish_jump_items : Str -> List(Assembly.Statement)
nullish_jump_items = |label| [
	Emit.imm(Rcx, Boxing.undefined_bits),
	Emit.cmp(Rdi, Rcx),
	Emit.jcc(E, label),
	Emit.imm(Rcx, Boxing.null_bits),
	Emit.cmp(Rdi, Rcx),
	Emit.jcc(E, label),
]

## At `label`, node's TypeError for an index of `undefined` or `null` in
## `rdi` read (`setting` 0) or written (1), the index `rsi` made its text.
keyed_error_items : { label : Str, setting : I64 } -> List(Assembly.Statement)
keyed_error_items = |{ label, setting }| [
	Emit.mark(label),
	Emit.save(Rdi),
	Emit.mov(Rdi, Rsi),
	Emit.call("runtime_text_of"),
	Emit.mov(Rsi, Rax),
	Emit.restore(Rdi),
	Emit.imm(Rdx, setting),
	Emit.jmp("runtime_property_error"),
]

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
		.concat(nullish_jump_items("runtime_set_property_nullish"))
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
			Emit.cmp_imm(Rax, 2),
			Emit.jcc(E, "runtime_integer_key"),
			Emit.save(Rax),
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
			Emit.restore(Rax),
			Emit.test(Rax, Rax),
			Emit.jcc(Ne, "runtime_set_property_index"),
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
			# An index key goes before the first key that isn't one or is a
			# greater one, as node orders them: r11 the entries, r10 their
			# bytes, r9 the place, the entries from it moved up one.
			Emit.mark("runtime_set_property_index"),
			Emit.load(R10, Emit.mem(Rdi, 0)),
			Emit.shl(R10, 4),
			Emit.load(R11, Emit.mem(Rdi, 16)),
			Emit.zero(R9),
			Emit.mark("runtime_set_property_place"),
			Emit.cmp(R9, R10),
			Emit.jcc(E, "runtime_set_property_insert"),
			Emit.load(
				Rcx,
				Emit.mem_index({
					base: R11,
					index: R9,
					displacement: 0,
				}),
			),
			Emit.call("runtime_index_before"),
			Emit.test(Rax, Rax),
			Emit.jcc(Ne, "runtime_set_property_insert"),
			Emit.plus_imm(R9, 16),
			Emit.jmp("runtime_set_property_place"),
			Emit.mark("runtime_set_property_insert"),
			Emit.mov(R8, R10),
			Emit.mark("runtime_set_property_shift"),
			Emit.cmp(R8, R9),
			Emit.jcc(E, "runtime_set_property_shifted"),
			Emit.minus_imm(R8, 16),
			Emit.plus(R8, R11),
			Emit.load(Rax, Emit.mem(R8, 0)),
			Emit.store(Emit.mem(R8, 16), Rax),
			Emit.load(Rax, Emit.mem(R8, 8)),
			Emit.store(Emit.mem(R8, 24), Rax),
			Emit.minus(R8, R11),
			Emit.jmp("runtime_set_property_shift"),
			Emit.mark("runtime_set_property_shifted"),
			Emit.plus(R9, R11),
			Emit.store(Emit.mem(R9, 0), Rsi),
			Emit.store(Emit.mem(R9, 8), Rdx),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.plus_imm(Rcx, 1),
			Emit.store(Emit.mem(Rdi, 0), Rcx),
			Emit.ret,
			Emit.mark("runtime_not_an_object"),
		])
		.concat(stopping_items("runtime_text_not_an_object"))
		.append(Emit.mark("runtime_integer_key"))
		.concat(stopping_items("runtime_text_integer_key"))
		.concat([
			Emit.mark("runtime_set_property_nullish"),
			Emit.imm(Rdx, 1),
			Emit.jmp("runtime_property_error"),
		])
	# Whether the index key `rsi` goes before the key `rcx`: 1 in `rax`
	# when that key is no index, or a greater one (more digits, or the same
	# count and a greater byte first). It keeps every register but `rax`,
	# `rcx` and `r8`.
	index_before = [
		Emit.mark("runtime_index_before"),
		Emit.save(Rdi),
		Emit.save(Rcx),
		Emit.mov(Rdi, Rcx),
		Emit.call("runtime_is_index_key"),
		Emit.restore(Rcx),
		Emit.restore(Rdi),
		Emit.test(Rax, Rax),
		Emit.jcc(E, "runtime_index_before_yes"),
		Emit.load(Rax, Emit.mem(Rsi, 0)),
		Emit.load(R8, Emit.mem(Rcx, 0)),
		Emit.cmp(Rax, R8),
		Emit.jcc(B, "runtime_index_before_yes"),
		Emit.jcc(A, "runtime_index_before_no"),
		Emit.save(Rdx),
		Emit.save(Rdi),
		Emit.zero(R8),
		Emit.mark("runtime_index_before_byte"),
		Emit.cmp(R8, Rax),
		Emit.jcc(E, "runtime_index_before_restored_no"),
		text_byte_item({ reg: Rdx, base: Rsi }),
		text_byte_item({ reg: Rdi, base: Rcx }),
		Emit.cmp(Rdx, Rdi),
		Emit.jcc(B, "runtime_index_before_restored_yes"),
		Emit.jcc(A, "runtime_index_before_restored_no"),
		Emit.plus_imm(R8, 1),
		Emit.jmp("runtime_index_before_byte"),
		Emit.mark("runtime_index_before_restored_yes"),
		Emit.restore(Rdi),
		Emit.restore(Rdx),
		Emit.mark("runtime_index_before_yes"),
		Emit.imm(Rax, 1),
		Emit.ret,
		Emit.mark("runtime_index_before_restored_no"),
		Emit.restore(Rdi),
		Emit.restore(Rdx),
		Emit.mark("runtime_index_before_no"),
		Emit.zero(Rax),
		Emit.ret,
	]
	# A key is an array index when it is "0", or digits not starting with 0:
	# 1 in `rax`, or 2 for ten digits or more, which may be past node's
	# indexes (below 2^32 - 1) and are not compiled yet; 0 for any other.
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
		Emit.cmp_imm(Rcx, 10),
		Emit.jcc(B, "runtime_is_index_key_done"),
		Emit.imm(Rax, 2),
		Emit.mark("runtime_is_index_key_done"),
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
		.concat(nullish_jump_items("runtime_get_index_nullish"))
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
		.concat(keyed_error_items({ label: "runtime_get_index_nullish", setting: 0 }))
	set_index = [Emit.mark(Runtime.set_index)]
		.concat(nullish_jump_items("runtime_set_index_nullish"))
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
		.concat(keyed_error_items({ label: "runtime_set_index_nullish", setting: 1 }))
	[
		new_array,
		new_object,
		entry,
		set_property,
		index_before,
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
			Emit.cmp_imm(Rcx, Boxing.collection_tag),
			Emit.jcc(E, "runtime_inspect_collection"),
			Emit.jmp("runtime_text_of"),
			Emit.mark("runtime_inspect_number"),
			Emit.mov(Rax, Rdi),
			Emit.jmp(Runtime.number_text),
			Emit.mark("runtime_inspect_string"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.jmp("runtime_inspect_text"),
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
			# A Map is listed by its entries (kind 2), a Set by its values (3).
			Emit.mark("runtime_inspect_collection"),
			Emit.mov(Rax, Rdi),
		])
		.concat(unboxed_items(Rax))
		.concat([
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.cmp_imm(Rcx, 2),
			Emit.jcc(E, "runtime_iterator_written"),
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
		text_byte_item({ reg: Rax, base: Rdi }),
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
		text_byte_item({ reg: Rdx, base: R10 }),
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
	# A string inside an array or an object that holds a line break and is
	# longer than 16 and than the line left (76 less the indentation, two
	# spaces a depth) is written as node writes it: a quoted piece a line,
	# each ending at a line break, joined with ` +` and a line indented two
	# past the depth's. Its frame holds the string (8), the depth (16), the
	# joint (24), the piece's start (32), the place (40) and the text so far
	# (48, 0 before the first piece).
	local = |offset| Emit.mem(Rbp, 0 - offset)
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
		text_byte_item({ reg: Rax, base: Rdi }),
		Emit.cmp_imm(Rax, 10),
		Emit.jcc(E, "runtime_inspect_text_split"),
		Emit.plus_imm(R8, 1),
		Emit.jmp("runtime_inspect_text_scan"),
		Emit.mark("runtime_inspect_text_split"),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 48),
		Emit.store(local(8), Rdi),
		Emit.store(local(16), Rsi),
		Emit.mov(Rdi, Rsi),
		Emit.plus(Rdi, Rdi),
		Emit.plus_imm(Rdi, 2),
		Emit.store(local(24), Rdi),
		Emit.plus_imm(Rdi, 11),
		Emit.call(Runtime.allocate),
		Emit.load(Rcx, local(24)),
		Emit.lea(Rdx, Emit.mem(Rcx, 3)),
		Emit.store(Emit.mem(Rax, 0), Rdx),
		Emit.store(local(24), Rax),
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
			Emit.store(local(32), Rax),
			Emit.store(local(40), Rax),
			Emit.store(local(48), Rax),
			Emit.mark("runtime_inspect_text_next"),
			Emit.load(Rdi, local(8)),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(R8, local(40)),
			Emit.cmp(R8, Rcx),
			Emit.jcc(E, "runtime_inspect_text_last"),
			text_byte_item({ reg: Rax, base: Rdi }),
			Emit.plus_imm(R8, 1),
			Emit.store(local(40), R8),
			Emit.cmp_imm(Rax, 10),
			Emit.jcc(Ne, "runtime_inspect_text_next"),
			Emit.call("runtime_inspect_piece"),
			Emit.jmp("runtime_inspect_text_next"),
			Emit.mark("runtime_inspect_text_last"),
			Emit.load(Rax, local(32)),
			Emit.cmp(Rax, R8),
			Emit.jcc(E, "runtime_inspect_text_done"),
			Emit.call("runtime_inspect_piece"),
			Emit.mark("runtime_inspect_text_done"),
			Emit.load(Rax, local(48)),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
			# The piece from the start to the place, quoted and joined on;
			# called in the frame above, whose `rbp` it keeps.
			Emit.mark("runtime_inspect_piece"),
			Emit.load(Rdx, local(40)),
			Emit.load(Rsi, local(32)),
			Emit.minus(Rdx, Rsi),
			Emit.save(Rdx),
			Emit.lea(Rdi, Emit.mem(Rdx, 8)),
			Emit.call(Runtime.allocate),
			Emit.restore(Rcx),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.load(R10, local(8)),
			Emit.load(Rsi, local(32)),
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
			Emit.load(Rax, local(40)),
			Emit.store(local(32), Rax),
			Emit.call("runtime_quoted"),
			Emit.load(Rdi, local(48)),
			Emit.test(Rdi, Rdi),
			Emit.jcc(E, "runtime_inspect_piece_first"),
			Emit.save(Rax),
			Emit.load(Rsi, local(24)),
			Emit.call("runtime_concat"),
			Emit.mov(Rdi, Rax),
			Emit.restore(Rsi),
			Emit.call("runtime_concat"),
			Emit.mark("runtime_inspect_piece_first"),
			Emit.store(local(48), Rax),
			Emit.ret,
		])
	[dispatch, quoted, text, key_text, list_items].join()
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
		Emit.minus_imm(Rsp, list_frame_size),
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
			Emit.jcc(A, "runtime_inspect_many"),
			# A Map's or a Set's braces are after its name and size,
			# `Map(2) `, at [rbp - 328]; 0 for an array or an object.
			Emit.zero(Rax),
			Emit.store(local(328), Rax),
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
			Emit.store(local(328), Rax),
			Emit.load(Rcx, local(32)),
			Emit.load(Rsi, local(16)),
			Emit.mark("runtime_inspect_named"),
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
		Emit.cmp_imm(Rax, 1),
		Emit.jcc(E, "runtime_inspect_property"),
		Emit.cmp_imm(Rax, 2),
		Emit.jcc(E, "runtime_inspect_pair"),
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
		Emit.load(Rsi, local(16)),
		Emit.plus_imm(Rsi, 1),
		Emit.call("runtime_inspect"),
		Emit.mov(Rdi, Rax),
		Emit.address_of(Rsi, "runtime_text_arrow"),
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
		Emit.load(R8, local(328)),
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
		Emit.load(Rax, local(56)),
		Emit.plus(Rdi, Rax),
		Emit.plus(Rdi, R10),
		# The braces, and a Map's or a Set's name and size.
		Emit.plus_imm(Rdi, 40),
		Emit.save(R10),
		Emit.call(Runtime.allocate),
		Emit.restore(R10),
		Emit.store(local(80), Rax),
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
	fixed = |{ label, kinds_texts }| {
		var $out = [Emit.mark(label), Emit.load(Rcx, local(24))]
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
		stopping_items("runtime_text_many"),
	]
		.join()
}

## The bytes of `runtime_inspect_list`'s frame: its own places, then
## `runtime_columns`', with the widest columns' 12 places last.
list_frame_size : I64
list_frame_size = 336

## A double's bits put in an xmm register, through `rax`.
double_items : { to : X86.Xmm, value : F64 } -> List(Assembly.Statement)
double_items = |{ to, value }| [Emit.imm(Rax, double_bits(value)), Emit.to_xmm(to, Rax)]

## A double's bits, as an immediate takes them.
double_bits : F64 -> I64
double_bits = |value| value.to_bits().to_i64_wrap()

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
	local = |offset| Emit.mem(Rbp, 0 - offset)
	columns = local(88)
	numbers_only = local(96)
	rows = local(104)
	row_start = local(112)
	row_count = local(120)
	rows_length = local(128)
	item = local(144)
	row_end = local(152)
	row = local(160)
	row_length = local(168)
	written_row = local(176)
	# The widest of column c is at [rbp + 8c - 304].
	widest = |reg| Based({
		base: Rbp,
		index: Scaled({ reg, scale: Times8 }),
		displacement: (0 - list_frame_size + 16).to_i32_wrap(),
	})
	# The length of entry `reg`'s text, in `rax`.
	text_length = |reg| [
		Emit.load(R8, local(40)),
		Emit.load(Rax, listed_item(reg)),
		Emit.load(Rax, Emit.mem(Rax, 0)),
	]
	counted = [
		Emit.mark("runtime_columns"),
		Emit.load(Rcx, local(32)),
		Emit.load(R9, local(64)),
		Emit.plus_imm(R9, 2),
		Emit.load(R11, local(56)),
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
		.concat(double_items({ to: Xmm2, value: 3.0 }))
		.concat([Emit.double_difference(Xmm0, Xmm2), Emit.double_difference(Xmm0, Xmm1)])
		.concat(double_items({ to: Xmm2, value: 1.0 }))
		.concat([
			Instruction(Ucomisd({ left: Xmm0, right: Xmm2 })),
			Emit.jcc(Ae, "runtime_columns_biased"),
			Emit.double_copy(Xmm0, Xmm2),
			Emit.mark("runtime_columns_biased"),
		])
		.concat(double_items({ to: Xmm1, value: 2.5 }))
		.concat([
			Emit.double_product(Xmm1, Xmm0),
			Instruction(Cvtsi2sd({ to: Xmm2, from: Rcx })),
			Emit.double_product(Xmm2, Xmm1),
			Emit.square_root(Xmm3, Xmm2),
			Emit.double_quotient(Xmm3, Xmm0),
		])
		# Rounded half up: the answer is positive, so a truncation of it plus
		# a half.
		.concat(double_items({ to: Xmm2, value: 0.5 }))
		.concat([
			Emit.double_sum(Xmm3, Xmm2),
			Instruction(Cvttsd2si({ to: R8, from: Xmm3 })),
			Emit.load(R10, local(16)),
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
		Emit.load(Rcx, local(32)),
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
			Emit.load(Rdi, local(8)),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.zero(R11),
			Emit.mark("runtime_columns_kinds"),
			Emit.cmp(R11, Rcx),
			Emit.jcc(E, "runtime_columns_kinded"),
			Emit.load(Rax, listed_item(R11)),
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
		Emit.load(Rcx, local(32)),
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
		Emit.load(R8, local(40)),
		Emit.load(Rsi, listed_item(R11)),
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
				Emit.store(listed_item(R11), Rax),
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
		Emit.store(local(40), Rax),
		Emit.load(Rcx, row_count),
		Emit.store(local(32), Rcx),
		Emit.load(Rax, rows_length),
		Emit.store(local(56), Rax),
		Emit.load(R10, local(16)),
		Emit.plus(R10, R10),
		Emit.jmp("runtime_inspect_lines"),
	]
	[counted, measured, row_measured, cells, done].join()
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
	# r11: the next place, a whole number.
	next_item = [Emit.mark(Runtime.next_item)]
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.collection_tag),
			Emit.jcc(E, "runtime_next_item_collection"),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.to_xmm(Xmm0, Rsi),
			Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
			Emit.lea(R11, Emit.mem(Rcx, 1)),
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(Ae, "runtime_next_item_none"),
		])
		.concat(item_address_items)
		.concat([
			Emit.load(Rax, Emit.mem(R8, 0)),
			Emit.imm(Rdx, 1),
			Emit.mark("runtime_next_item_place"),
			Instruction(Cvtsi2sd({ to: Xmm0, from: R11 })),
			Instruction(MovqFromXmm({ to: Rcx, from: Xmm0 })),
			Emit.ret,
			Emit.mark("runtime_next_item_none"),
			Emit.zero(Rdx),
			Emit.ret,
			# A Map gives its entries and a Set its values, from the place; an
			# iterator keeps its own place, which moves.
			Emit.mark("runtime_next_item_collection"),
			Emit.mov(Rax, Rdi),
		])
		.concat(unboxed_items(Rax))
		.concat([
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.cmp_imm(Rcx, 2),
			Emit.jcc(E, "runtime_next_item_iterator"),
			Emit.imm(Rdx, 2),
			Emit.minus(Rdx, Rcx),
			Emit.to_xmm(Xmm0, Rsi),
			Instruction(Cvttsd2si({ to: Rsi, from: Xmm0 })),
			Emit.call("runtime_collection_next"),
			Emit.mov(R11, Rcx),
			Emit.jmp("runtime_next_item_place"),
			Emit.mark("runtime_next_item_iterator"),
			Emit.save(Rax),
			Emit.load(Rdi, Emit.mem(Rax, 8)),
			Emit.load(Rsi, Emit.mem(Rax, 16)),
			Emit.load(Rdx, Emit.mem(Rax, 24)),
			Emit.call("runtime_collection_next"),
			Emit.restore(R10),
			Emit.store(Emit.mem(R10, 16), Rcx),
			Emit.zero(Rcx),
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
	# r8: 1 for a string, whose bytes are sliced, 0 for an array.
	slice = [
		Emit.mark(Runtime.slice),
		Emit.mov(R11, Rcx),
		Emit.zero(R8),
	]
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(Ne, "runtime_slice_array"),
			Emit.imm(R8, 1),
			Emit.jmp("runtime_slice_listed"),
			Emit.mark("runtime_slice_array"),
		])
		.concat(array_check_items)
		.concat([Emit.mark("runtime_slice_listed")])
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
			Emit.lea(Rsi, listed_item(Rsi)),
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
		.concat(boxed_string_items)
		.concat([Emit.ret, Emit.mark("runtime_slice_not_a_number")])
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
			Emit.cmp_imm(Rcx, Boxing.collection_tag),
			Emit.jcc(E, "runtime_items_of_collection"),
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
		double_items({ to: Xmm0, value })
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
		.concat(double_items({ to: Xmm2, value: -1.0 }))
		.concat([
			Emit.double_sum(Xmm1, Xmm2),
			Emit.mark("runtime_math_round_floored"),
			Emit.double_difference(Xmm0, Xmm1),
		])
		.concat(double_items({ to: Xmm2, value: 0.5 }))
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
		Emit.imm(Rax, double_bits(1.0)),
		Emit.jcc(A, "runtime_math_done"),
		Emit.imm(Rax, double_bits(-1.0)),
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
	local = |offset| Emit.mem(Rbp, 0 - offset)
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
	text_of_boxed = [Emit.mark(Runtime.text_of), Emit.call("runtime_text_of")]
		.concat(boxed_string_items)
		.append(Emit.ret)
	# Its frame: the object (`[rbp - 8]`), the kind (16), the array made
	# (24) and the place (32).
	listing = [
		Emit.mark(Runtime.object_listing),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 32),
	]
		.concat(tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.object_tag), Emit.jcc(Ne, "runtime_object_listing_stop")])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.store(local(8), Rdi),
			Emit.store(local(16), Rsi),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_object_listing_plain"),
			Emit.load(Rdx, Emit.mem(Rdi, 16)),
			Emit.load(Rdx, Emit.mem(Rdx, 0)),
			Emit.address_of(Rax, error_mark),
			Emit.cmp(Rdx, Rax),
			Emit.jcc(E, "runtime_object_listing_stop"),
			Emit.mark("runtime_object_listing_plain"),
			Emit.mov(Rdi, Rcx),
			Emit.call(Runtime.new_array),
			Emit.store(local(24), Rax),
			Emit.zero(Rax),
			Emit.store(local(32), Rax),
			Emit.mark("runtime_object_listing_next"),
			Emit.load(Rdi, local(8)),
			Emit.load(Rcx, local(32)),
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(E, "runtime_object_listing_done"),
			Emit.shl(Rcx, 4),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.plus(R8, Rcx),
			Emit.load(Rax, Emit.mem(R8, 0)),
		])
		.concat(boxed_items(Boxing.string_tag))
		.concat([
			Emit.load(Rsi, Emit.mem(R8, 8)),
			Emit.load(Rdx, local(16)),
			Emit.test(Rdx, Rdx),
			Emit.jcc(E, "runtime_object_listing_item"),
			Emit.mov(Rax, Rsi),
			Emit.cmp_imm(Rdx, 1),
			Emit.jcc(E, "runtime_object_listing_item"),
			Emit.load(Rax, Emit.mem(R8, 0)),
		])
		.concat(boxed_items(Boxing.string_tag))
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
			Emit.load(Rdi, local(24)),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rcx, local(32)),
			Emit.store(listed_item(Rcx), Rax),
			Emit.plus_imm(Rcx, 1),
			Emit.store(local(32), Rcx),
			Emit.jmp("runtime_object_listing_next"),
			Emit.mark("runtime_object_listing_done"),
			Emit.load(Rax, local(24)),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
			Emit.mark("runtime_object_listing_stop"),
		])
		.concat(stopping_items("runtime_text_object_keys"))
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
		error_text,
		text_of_boxed,
		listing,
	].join()
}

## `runtime_search`, `runtime_index_of`, `runtime_concat_item` and
## `runtime_reverse`. A search's frame holds the array (`[rbp - 8]`), the
## function (16), the kind (24), the place (32), the length it started with
## (40) and the item (48): `find` and `findIndex` go on to that length,
## reading `undefined` past the end, while `some` and `every` stop at the end.
search_items : List(Assembly.Statement)
search_items = {
	local = |offset| Emit.mem(Rbp, 0 - offset)
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
		.concat(array_check_items)
		.concat([
			Emit.mov(Rax, Rsi),
			Emit.call(Runtime.check_function),
			Emit.store(local(8), Rdi),
			Emit.store(local(16), Rsi),
			Emit.store(local(24), Rdx),
			Emit.zero(Rax),
			Emit.store(local(32), Rax),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.store(local(40), Rcx),
			Emit.mark("runtime_search_next"),
			Emit.load(Rdx, local(32)),
			Emit.load(Rcx, local(40)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_search_ended"),
			Emit.load(Rdi, local(8)),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.imm(Rsi, Boxing.undefined_bits),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ae, "runtime_search_past"),
			Emit.load(Rsi, listed_item(Rdx)),
			Emit.jmp("runtime_search_call"),
			Emit.mark("runtime_search_past"),
			Emit.load(Rax, local(24)),
			Emit.cmp_imm(Rax, 2),
			Emit.jcc(B, "runtime_search_ended"),
			Emit.mark("runtime_search_call"),
			Emit.store(local(48), Rsi),
			Emit.load(Rdi, local(16)),
			Emit.load(Rcx, local(8)),
			Emit.call("runtime_call_back"),
			Emit.mov(Rdi, Rax),
			Emit.call(Runtime.truthy),
			Emit.load(Rdx, local(24)),
			Emit.cmp_imm(Rdx, 1),
			Emit.jcc(E, "runtime_search_every"),
			Emit.test(Rax, Rax),
			Emit.jcc(Ne, "runtime_search_found"),
			Emit.jmp("runtime_search_step"),
			Emit.mark("runtime_search_every"),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_search_found"),
			Emit.mark("runtime_search_step"),
			Emit.load(Rax, local(32)),
			Emit.plus_imm(Rax, 1),
			Emit.store(local(32), Rax),
			Emit.jmp("runtime_search_next"),
			Emit.mark("runtime_search_found"),
			Emit.load(Rax, local(48)),
			Emit.cmp_imm(Rdx, 2),
			Emit.jcc(E, "runtime_search_leave"),
			Emit.load(Rax, local(32)),
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
		.concat([Emit.mark("runtime_search_ended"), Emit.load(Rdx, local(24))])
		.concat(
			answers({
				label: "runtime_search_ended",
				values: [
					Boxing.false_bits,
					Boxing.true_bits,
					Boxing.undefined_bits,
					double_bits(-1.0),
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
		.concat(unless_number_items({ reg: Rdx, label: "runtime_index_of_place_stop" }))
		.concat([
			Emit.to_xmm(Xmm0, Rdx),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
			Emit.jcc(P, "runtime_index_of_started"),
		])
		.concat(double_items({ to: Xmm1, value: 9007199254740992.0 }))
		.concat([
			Emit.imm(R9, 9007199254740992),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(Ae, "runtime_index_of_started"),
		])
		.concat(double_items({ to: Xmm1, value: -9007199254740992.0 }))
		.concat([
			Emit.imm(R9, -9007199254740992),
			Instruction(Ucomisd({ left: Xmm1, right: Xmm0 })),
			Emit.jcc(Ae, "runtime_index_of_started"),
			Instruction(Cvttsd2si({ to: R9, from: Xmm0 })),
			Emit.mark("runtime_index_of_started"),
		])
		.concat(tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.string_tag),
			Emit.jcc(E, "runtime_index_of_string"),
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(Ne, "runtime_not_an_array"),
		])
		.concat(unboxed_items(Rdi))
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
		Emit.load(Rdi, listed_item(R9)),
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
		.concat(unless_number_items({ reg: Rsi, label: "runtime_index_of_next" }))
		.concat([
			Emit.to_xmm(Xmm0, Rsi),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
			Emit.jcc(Np, "runtime_index_of_next"),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(Rax, listed_item(R9)),
		])
		.concat(unless_number_items({ reg: Rax, label: "runtime_index_of_next" }))
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
			.concat(unless_string_items({ reg: Rsi, label: "runtime_index_of_sought_stop" }))
			.concat(unboxed_items(Rdi))
			.concat(unboxed_items(Rsi))
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
				text_byte_item({ reg: Rax, base: Rdi }),
				Emit.mov(R8, Rcx),
				text_byte_item({ reg: R8, base: Rsi }),
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
		Emit.imm(Rax, double_bits(-1.0)),
		Emit.mark("runtime_index_of_done"),
		Emit.ret,
		Emit.mark("runtime_index_of_place_stop"),
	]
		.concat(stopping_items("runtime_text_index_of_place"))
		.append(Emit.mark("runtime_index_of_sought_stop"))
		.concat(stopping_items("runtime_text_index_of_sought"))
	# r9: the items appended, r10 their count, r11 the place.
	concat_item =
		[Emit.mark(Runtime.concat_item)]
			.concat(tag_load_items(Rsi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(E, "runtime_concat_items"),
				Emit.jmp("runtime_push_item"),
				Emit.mark("runtime_concat_items"),
			])
			.concat(unboxed_items(Rsi))
			.concat([
				Emit.mov(R9, Rsi),
				Emit.zero(R11),
				Emit.mark("runtime_concat_next"),
				Emit.load(R10, Emit.mem(R9, 0)),
				Emit.cmp(R11, R10),
				Emit.jcc(E, "runtime_concat_done"),
				Emit.load(R8, Emit.mem(R9, 16)),
				Emit.load(Rsi, listed_item(R11)),
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
			.concat(array_check_items)
			.concat(unboxed_items(Rdi))
			.concat([
				Emit.load(R8, Emit.mem(Rdi, 16)),
				Emit.zero(Rdx),
				Emit.load(R9, Emit.mem(Rdi, 0)),
				Emit.mark("runtime_reverse_next"),
				Emit.minus_imm(R9, 1),
				Emit.cmp(Rdx, R9),
				Emit.jcc(Ge, "runtime_reverse_done"),
				Emit.load(Rcx, listed_item(Rdx)),
				Emit.load(R10, listed_item(R9)),
				Emit.store(listed_item(Rdx), R10),
				Emit.store(listed_item(R9), Rcx),
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
	local = |offset| Emit.mem(Rbp, 0 - offset)
	listed = |{ list, place }| [Emit.load(R8, local(list)), Emit.load(Rcx, local(place))]
	start = [
		Emit.mark(Runtime.sort),
		Emit.save(Rbp),
		Emit.mov(Rbp, Rsp),
		Emit.minus_imm(Rsp, 96),
	]
		.concat(array_check_items)
		.concat([
			Emit.store(local(8), Rdi),
			Emit.store(local(16), Rsi),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rsi, Rcx),
			Emit.jcc(E, "runtime_sort_by_text"),
			Emit.mov(Rax, Rsi),
			Emit.call(Runtime.check_function),
			Emit.mark("runtime_sort_by_text"),
		])
		.concat(unboxed_items(Rdi))
		# The items that aren't `undefined` copied to a list of their own,
		# and a second list as long.
		.concat([
			Emit.load(Rdi, Emit.mem(Rdi, 0)),
			Emit.shl(Rdi, 3),
			Emit.save(Rdi),
			Emit.call(Runtime.allocate),
			Emit.store(local(32), Rax),
			Emit.restore(Rdi),
			Emit.call(Runtime.allocate),
			Emit.store(local(40), Rax),
			Emit.load(Rdi, local(8)),
		])
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.load(R10, local(32)),
			Emit.zero(Rcx),
			Emit.zero(Rdx),
			Emit.imm(R11, Boxing.undefined_bits),
			Emit.mark("runtime_sort_kept"),
			Emit.cmp(Rcx, R9),
			Emit.jcc(E, "runtime_sort_counted"),
			Emit.load(Rax, listed_item(Rcx)),
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
			Emit.store(local(24), Rdx),
			Emit.imm(Rax, 1),
			Emit.store(local(48), Rax),
		])
	# One pass of runs of the width: each pair of runs merged into the list
	# written, then the two lists change places.
	passes = [
		Emit.mark("runtime_sort_pass"),
		Emit.load(Rax, local(48)),
		Emit.load(Rcx, local(24)),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Ae, "runtime_sort_sorted"),
		Emit.zero(Rax),
		Emit.store(local(56), Rax),
		Emit.mark("runtime_sort_run"),
		Emit.load(Rax, local(56)),
		Emit.load(Rcx, local(24)),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Ae, "runtime_sort_passed"),
		Emit.store(local(80), Rax),
		Emit.store(local(96), Rax),
		Emit.load(Rdx, local(48)),
		Emit.plus(Rax, Rdx),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Be, "runtime_sort_middle"),
		Emit.mov(Rax, Rcx),
		Emit.mark("runtime_sort_middle"),
		Emit.store(local(64), Rax),
		Emit.store(local(88), Rax),
		Emit.plus(Rax, Rdx),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(Be, "runtime_sort_end"),
		Emit.mov(Rax, Rcx),
		Emit.mark("runtime_sort_end"),
		Emit.store(local(72), Rax),
	]
	merge =
		[
			Emit.mark("runtime_sort_merge"),
			Emit.load(Rax, local(96)),
			Emit.load(Rcx, local(72)),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ae, "runtime_sort_merged"),
			Emit.load(Rax, local(80)),
			Emit.load(Rcx, local(64)),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ae, "runtime_sort_right"),
			Emit.load(Rax, local(88)),
			Emit.load(Rcx, local(72)),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ae, "runtime_sort_left"),
		]
			.concat(listed({ list: 32, place: 80 }))
			.append(Emit.load(Rdi, listed_item(Rcx)))
			.concat(listed({ list: 32, place: 88 }))
			.concat([
				Emit.load(Rsi, listed_item(Rcx)),
				Emit.call("runtime_sort_greater"),
				Emit.test(Rax, Rax),
				Emit.jcc(Ne, "runtime_sort_right"),
				Emit.mark("runtime_sort_left"),
			])
			.concat(listed({ list: 32, place: 80 }))
			.concat([
				Emit.load(Rax, listed_item(Rcx)),
				Emit.plus_imm(Rcx, 1),
				Emit.store(local(80), Rcx),
				Emit.jmp("runtime_sort_written"),
				Emit.mark("runtime_sort_right"),
			])
			.concat(listed({ list: 32, place: 88 }))
			.concat([
				Emit.load(Rax, listed_item(Rcx)),
				Emit.plus_imm(Rcx, 1),
				Emit.store(local(88), Rcx),
				Emit.mark("runtime_sort_written"),
			])
			.concat(listed({ list: 40, place: 96 }))
			.concat([
				Emit.store(listed_item(Rcx), Rax),
				Emit.plus_imm(Rcx, 1),
				Emit.store(local(96), Rcx),
				Emit.jmp("runtime_sort_merge"),
				Emit.mark("runtime_sort_merged"),
				Emit.load(Rax, local(72)),
				Emit.store(local(56), Rax),
				Emit.jmp("runtime_sort_run"),
				Emit.mark("runtime_sort_passed"),
				Emit.load(Rax, local(32)),
				Emit.load(Rcx, local(40)),
				Emit.store(local(32), Rcx),
				Emit.store(local(40), Rax),
				Emit.load(Rax, local(48)),
				Emit.plus(Rax, Rax),
				Emit.store(local(48), Rax),
				Emit.jmp("runtime_sort_pass"),
			])
	# The sorted items back in the array, then its `undefined` ones.
	finish = [Emit.mark("runtime_sort_sorted"), Emit.load(Rdi, local(8))]
		.concat(unboxed_items(Rdi))
		.concat([
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.load(R10, local(32)),
			Emit.load(R11, local(24)),
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
			Emit.store(listed_item(Rcx), Rax),
			Emit.plus_imm(Rcx, 1),
			Emit.jmp("runtime_sort_copied"),
			Emit.mark("runtime_sort_done"),
			Emit.load(Rax, local(8)),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
		])
	# 1 in `rax` when `rdi` goes after `rsi`: the function's answer above
	# 0 (a number, or `true`), or the first's text after the second's.
	greater = [
		Emit.mark("runtime_sort_greater"),
		Emit.load(Rax, local(16)),
		Emit.imm(Rcx, Boxing.undefined_bits),
		Emit.cmp(Rax, Rcx),
		Emit.jcc(E, "runtime_sort_texts"),
		Emit.save(Rsi),
		Emit.save(Rdi),
		Emit.mov(Rbx, Rax),
	]
		.concat(unboxed_items(Rbx))
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
		.concat(unless_number_items({ reg: Rax, label: "runtime_sort_not_a_number" }))
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
		.concat(stopping_items("runtime_text_sort_answer"))
		.concat([
			Emit.mark("runtime_sort_texts"),
			Emit.save(Rsi),
			Emit.call(Runtime.text_of),
			Emit.restore(Rdi),
			Emit.save(Rax),
			Emit.call(Runtime.text_of),
			Emit.mov(Rsi, Rax),
			Emit.restore(Rdi),
			Emit.call(Runtime.compare),
			Emit.cmp_imm(Rax, 2),
			Emit.jcc(E, "runtime_sort_yes"),
			Emit.jmp("runtime_sort_no"),
		])
	[start, passes, merge, finish, greater].join()
}

## `runtime_char_code_at` and `runtime_split`. A split's frame holds the
## string (`[rbp - 8]`), the separator (16), the array (24), the piece's
## start (32) and the place (40).
string_method_items : List(Assembly.Statement)
string_method_items = {
	local = |offset| Emit.mem(Rbp, 0 - offset)
	char_code =
		[Emit.mark(Runtime.char_code_at)]
			.concat(unless_string_items({ reg: Rdi, label: "runtime_index_not_compiled" }))
			.concat(unless_number_items({ reg: Rsi, label: "runtime_index_not_compiled" }))
			.concat(unboxed_items(Rdi))
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
				text_byte_item({ reg: Rax, base: Rdi }),
				Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
				Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
				Emit.mark("runtime_char_code_done"),
				Emit.ret,
			])
	# The piece of the string from the start to the place, pushed.
	piece = [
		Emit.mark("runtime_split_piece"),
		Emit.load(Rdx, local(40)),
		Emit.load(Rcx, local(32)),
		Emit.minus(Rdx, Rcx),
		Emit.save(Rdx),
		Emit.lea(Rdi, Emit.mem(Rdx, 8)),
		Emit.call(Runtime.allocate),
		Emit.restore(Rcx),
		Emit.store(Emit.mem(Rax, 0), Rcx),
		Emit.lea(Rdi, Emit.mem(Rax, 8)),
		Emit.load(Rsi, local(8)),
		Emit.load(Rdx, local(32)),
		Emit.plus(Rsi, Rdx),
		Emit.plus_imm(Rsi, 8),
		Instruction(RepMovsb),
	]
		.concat(boxed_string_items)
		.concat([Emit.mov(Rsi, Rax), Emit.load(Rdi, local(24))])
		.concat(unboxed_items(Rdi))
		.concat([Emit.call("runtime_push_item"), Emit.ret])
	split =
		[
			Emit.mark(Runtime.split),
			Emit.save(Rbp),
			Emit.mov(Rbp, Rsp),
			Emit.minus_imm(Rsp, 48),
		]
			.concat(unless_string_items({ reg: Rdi, label: "runtime_index_not_compiled" }))
			.concat(unless_string_items({ reg: Rsi, label: "runtime_split_stop" }))
			.concat(unboxed_items(Rdi))
			.concat(unboxed_items(Rsi))
			.concat([
				Emit.store(local(8), Rdi),
				Emit.store(local(16), Rsi),
				Emit.zero(Rdi),
				Emit.call(Runtime.new_array),
				Emit.store(local(24), Rax),
				Emit.zero(Rax),
				Emit.store(local(32), Rax),
				Emit.store(local(40), Rax),
				Emit.load(Rsi, local(16)),
				Emit.load(Rcx, Emit.mem(Rsi, 0)),
				Emit.test(Rcx, Rcx),
				Emit.jcc(E, "runtime_split_characters"),
				# A place where the separator's bytes are the string's: the
				# piece before it pushed, the next starting past it.
				Emit.mark("runtime_split_scan"),
				Emit.load(Rdi, local(8)),
				Emit.load(Rsi, local(16)),
				Emit.load(R9, local(40)),
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
				text_byte_item({ reg: Rax, base: Rdi }),
				Emit.mov(R8, Rcx),
				text_byte_item({ reg: R8, base: Rsi }),
				Emit.cmp(Rax, R8),
				Emit.jcc(Ne, "runtime_split_on"),
				Emit.plus_imm(Rcx, 1),
				Emit.jmp("runtime_split_byte"),
				Emit.mark("runtime_split_on"),
				Emit.plus_imm(R9, 1),
				Emit.store(local(40), R9),
				Emit.jmp("runtime_split_scan"),
				Emit.mark("runtime_split_found"),
				Emit.call("runtime_split_piece"),
				Emit.load(Rax, local(40)),
				Emit.load(Rsi, local(16)),
				Emit.load(Rcx, Emit.mem(Rsi, 0)),
				Emit.plus(Rax, Rcx),
				Emit.store(local(40), Rax),
				Emit.store(local(32), Rax),
				Emit.jmp("runtime_split_scan"),
				Emit.mark("runtime_split_last"),
				Emit.load(Rax, Emit.mem(Rdi, 0)),
				Emit.store(local(40), Rax),
				Emit.call("runtime_split_piece"),
				Emit.jmp("runtime_split_done"),
				# Each character a piece of its own.
				Emit.mark("runtime_split_characters"),
				Emit.load(Rdi, local(8)),
				Emit.load(Rax, local(40)),
				Emit.load(Rcx, Emit.mem(Rdi, 0)),
				Emit.cmp(Rax, Rcx),
				Emit.jcc(E, "runtime_split_done"),
				Emit.store(local(32), Rax),
				Emit.plus_imm(Rax, 1),
				Emit.store(local(40), Rax),
				Emit.call("runtime_split_piece"),
				Emit.jmp("runtime_split_characters"),
				Emit.mark("runtime_split_done"),
				Emit.load(Rax, local(24)),
				Emit.mov(Rsp, Rbp),
				Emit.restore(Rbp),
				Emit.ret,
				Emit.mark("runtime_split_stop"),
			])
			.concat(stopping_items("runtime_text_split_separator"))
	[char_code, piece, split].join()
}

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
	Emit.address_of(Rdx, error_mark),
	Emit.cmp(Rcx, Rdx),
	Emit.jcc(E, "runtime_spread_error"),
	Emit.mark(label),
]

## `runtime_call_spread`, `runtime_log_spread`, `runtime_extreme_of`,
## `runtime_spread_fields` and `runtime_properties_left`. Each walk's frame
## holds its list (`[rbp - 8]`), what it makes or its kind (16), the place
## (24) and, for a rest, the keys left out (32).
spread_items : List(Assembly.Statement)
spread_items = {
	local = |offset| Emit.mem(Rbp, 0 - offset)
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
		Emit.load(Rdi, local(8)),
		Emit.load(Rcx, local(24)),
		Emit.load(Rdx, Emit.mem(Rdi, 0)),
		Emit.cmp(Rcx, Rdx),
		Emit.jcc(Ae, label),
		Emit.load(R8, Emit.mem(Rdi, 16)),
		Emit.load(Rax, listed_item(Rcx)),
		Emit.plus_imm(Rcx, 1),
		Emit.store(local(24), Rcx),
	]
	# The items pushed, the last first, as a call through a value takes them.
	call_spread =
		[
			Emit.mark(Runtime.call_spread),
			Emit.mov(Rax, Rdi),
			Emit.call(Runtime.check_function),
		]
			.concat(tag_load_items(Rsi))
			.concat([Emit.cmp_imm(Rcx, Boxing.array_tag), Emit.jcc(Ne, "runtime_not_an_array")])
			.concat([Emit.save(Rbp), Emit.mov(Rbp, Rsp)])
			.concat(unboxed_items(Rsi))
			.concat([
				Emit.load(Rcx, Emit.mem(Rsi, 0)),
				Emit.load(R8, Emit.mem(Rsi, 16)),
				Emit.mov(Rdx, Rcx),
				Emit.mark("runtime_call_spread_push"),
				Emit.test(Rdx, Rdx),
				Emit.jcc(E, "runtime_call_spread_pushed"),
				Emit.minus_imm(Rdx, 1),
				Emit.load(Rax, listed_item(Rdx)),
				Emit.save(Rax),
				Emit.jmp("runtime_call_spread_push"),
				Emit.mark("runtime_call_spread_pushed"),
				Emit.mov(Rbx, Rdi),
			])
			.concat(unboxed_items(Rbx))
			.concat([
				Emit.load(Rax, Emit.mem(Rbx, 0)),
				Emit.plus(Rax, Rbx),
				Instruction(CallReg(Rax)),
			])
			.concat(leave)
	log_spread =
		framed({ label: Runtime.log_spread, size: 32 })
			.concat(array_check_items)
			.concat(unboxed_items(Rdi))
			.concat([
				Emit.store(local(8), Rdi),
				Emit.zero(Rax),
				Emit.store(local(24), Rax),
				Emit.mark("runtime_log_spread_next"),
			])
			.concat(next_item("runtime_log_spread_done"))
			.concat([
				Emit.store(local(16), Rax),
				Emit.cmp_imm(Rcx, 1),
				Emit.jcc(E, "runtime_log_spread_first"),
			])
			.concat(Runtime.text_items(Space))
			.concat([
				Emit.mark("runtime_log_spread_first"),
				Emit.load(Rdi, local(16)),
				Emit.call(Runtime.write_value),
				Emit.jmp("runtime_log_spread_next"),
				Emit.mark("runtime_log_spread_done"),
			])
			.concat(Runtime.text_items(Newline))
			.concat(leave)
	extreme_of =
		framed({ label: Runtime.extreme_of, size: 32 })
			.concat(array_check_items)
			.concat(unboxed_items(Rdi))
			.concat([
				Emit.store(local(8), Rdi),
				Emit.store(local(32), Rsi),
				Emit.zero(Rax),
				Emit.store(local(24), Rax),
				Emit.imm(Rax, 0x7FF0000000000000),
				Emit.test(Rsi, Rsi),
				Emit.jcc(Ne, "runtime_extreme_of_started"),
				Emit.imm(Rax, (0xFFF0000000000000).to_i64_wrap()),
				Emit.mark("runtime_extreme_of_started"),
				Emit.store(local(16), Rax),
				Emit.mark("runtime_extreme_of_next"),
			])
			.concat(next_item("runtime_extreme_of_done"))
			.concat([
				Emit.call(Runtime.check_number),
				Emit.mov(Rsi, Rax),
				Emit.load(Rdi, local(16)),
				Emit.load(Rax, local(32)),
				Emit.test(Rax, Rax),
				Emit.jcc(Ne, "runtime_extreme_of_min"),
				Emit.call(Runtime.math_routine("max")),
				Emit.jmp("runtime_extreme_of_kept"),
				Emit.mark("runtime_extreme_of_min"),
				Emit.call(Runtime.math_routine("min")),
				Emit.mark("runtime_extreme_of_kept"),
				Emit.store(local(16), Rax),
				Emit.jmp("runtime_extreme_of_next"),
				Emit.mark("runtime_extreme_of_done"),
				Emit.load(Rax, local(16)),
			])
			.concat(leave)
	# An object's entries are copied below; an array or a string goes to
	# `${label}_listed`, boxed; anything else has no properties.
	keyed = |label|
		tag_load_items(Rsi)
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
			.concat(unboxed_items(Rsi))
			.concat(not_an_error_items("${label}_plain"))
	# An array's items, or a string's characters, set on the object at
	# [rbp - 16] under their places' texts: `{ ...[10, 20] }` is
	# `{ '0': 10, '1': 20 }`.
	listed_fields =
		[Emit.mark("runtime_spread_fields_listed")]
			.concat(tag_load_items(Rsi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(E, "runtime_spread_fields_array"),
				Emit.mov(Rdi, Rsi),
				Emit.call(Runtime.items_of),
				Emit.mov(Rsi, Rax),
				Emit.mark("runtime_spread_fields_array"),
			])
			.concat(unboxed_items(Rsi))
			.concat([
				Emit.store(local(8), Rsi),
				Emit.zero(Rax),
				Emit.store(local(24), Rax),
				Emit.mark("runtime_spread_fields_item"),
				Emit.load(Rdi, local(8)),
				Emit.load(Rcx, local(24)),
				Emit.load(Rdx, Emit.mem(Rdi, 0)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, "runtime_spread_fields_done"),
				Emit.load(R8, Emit.mem(Rdi, 16)),
				Emit.load(Rax, listed_item(Rcx)),
				Emit.store(local(32), Rax),
				Instruction(Cvtsi2sd({ to: Xmm0, from: Rcx })),
				Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
				Emit.call(Runtime.number_text),
				Emit.mov(Rsi, Rax),
				Emit.load(Rdi, local(16)),
				Emit.load(Rdx, local(32)),
				Emit.call(Runtime.set_property),
				Emit.load(Rcx, local(24)),
				Emit.plus_imm(Rcx, 1),
				Emit.store(local(24), Rcx),
				Emit.jmp("runtime_spread_fields_item"),
			])
	# Each entry of the object at [rbp - 8] whose key isn't left out, set
	# on the object at [rbp - 16].
	copied = |label|
		[
			Emit.zero(Rax),
			Emit.store(local(24), Rax),
			Emit.mark("${label}_next"),
			Emit.load(Rdi, local(8)),
			Emit.load(Rcx, local(24)),
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(Ae, "${label}_done"),
			Emit.plus_imm(Rcx, 1),
			Emit.store(local(24), Rcx),
			Emit.minus_imm(Rcx, 1),
			Emit.shl(Rcx, 4),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.plus(R8, Rcx),
			Emit.load(Rsi, Emit.mem(R8, 0)),
			Emit.load(Rdx, Emit.mem(R8, 8)),
			Emit.load(R9, local(32)),
			Emit.zero(R11),
			Emit.mark("${label}_key"),
			Emit.load(R10, Emit.mem(R9, 0)),
			Emit.cmp(R11, R10),
			Emit.jcc(E, "${label}_kept"),
			Emit.load(R8, Emit.mem(R9, 16)),
			Emit.load(Rdi, listed_item(R11)),
		]
			.concat(unboxed_items(Rdi))
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
				Emit.load(Rdi, local(16)),
				Emit.call(Runtime.set_property),
				Emit.jmp("${label}_next"),
			])
	spread_fields =
		framed({ label: Runtime.spread_fields, size: 32 })
			.concat([Emit.store(local(16), Rdi)])
			.concat(keyed("runtime_spread_fields"))
			.concat([
				Emit.store(local(8), Rsi),
				# No key is left out: an empty list of them.
				Emit.zero(Rdi),
				Emit.call(Runtime.new_array),
			])
			.concat(unboxed_items(Rax))
			.append(Emit.store(local(32), Rax))
			.concat(copied("runtime_spread_fields_copy"))
			.concat([
				Emit.mark("runtime_spread_fields_done"),
				Emit.mark("runtime_spread_fields_copy_done"),
			])
			.concat(leave)
			.concat(listed_fields)
	left =
		framed({ label: Runtime.properties_left, size: 32 })
			.concat(unboxed_items(Rsi))
			.concat([
				Emit.store(local(32), Rsi),
				Emit.mov(Rsi, Rdi),
				Emit.call(Runtime.new_object),
				Emit.store(local(16), Rax),
				Emit.mov(Rdi, Rax),
			])
			.concat(keyed("runtime_properties_left"))
			.concat([Emit.store(local(8), Rsi)])
			.concat(copied("runtime_properties_left_copy"))
			.concat([
				Emit.mark("runtime_properties_left_done"),
				Emit.mark("runtime_properties_left_copy_done"),
				Emit.load(Rax, local(16)),
			])
			.concat(leave)
			.append(Emit.mark("runtime_properties_left_listed"))
			.concat(unboxed_items(Rsi))
			.concat([
				Emit.load(Rcx, Emit.mem(Rsi, 0)),
				Emit.test(Rcx, Rcx),
				Emit.jcc(E, "runtime_properties_left_done"),
			])
			.concat(stopping_items("runtime_text_rest_listed"))
			.append(Emit.mark("runtime_spread_error"))
			.concat(stopping_items("runtime_text_spread_error"))
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
	[throw, new_error, property_error, message].join()
}

## `runtime_splice`, `runtime_last_index_of` and `runtime_from_char_codes`.
## splice's frame holds the array (`[rbp - 8]`), the arguments (16), the
## start (24), the count removed (32), what is removed (40), the array
## that takes the old one's place (48) and the count put in (56). The new
## array's items become the old array's, so every reference sees the change.
edit_items : List(Assembly.Statement)
edit_items = {
	local = |offset| Emit.mem(Rbp, 0 - offset)
	argument = |{ at, reg }| [
		Emit.load(R10, local(16)),
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
			.concat(array_check_items)
			.concat(unboxed_items(Rdi))
			.concat(unboxed_items(Rsi))
			.concat([
				Emit.store(local(8), Rdi),
				Emit.store(local(16), Rsi),
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
			.concat(unless_number_items({ reg: Rsi, label: "runtime_slice_not_a_number" }))
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
			.concat(unless_number_items({ reg: Rdx, label: "runtime_slice_not_a_number" }))
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
				Emit.store(local(24), Rsi),
				Emit.store(local(32), Rdx),
				# What is removed, copied out.
				Emit.mov(Rdi, Rdx),
				Emit.call(Runtime.new_array),
				Emit.store(local(40), Rax),
				Emit.mov(Rdi, Rdx),
				Emit.load(R10, local(8)),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rsi, local(24)),
				Emit.lea(Rsi, listed_item(Rsi)),
				Emit.load(Rcx, local(32)),
				Emit.shl(Rcx, 3),
				Instruction(RepMovsb),
				# The count put in: the arguments past the first two.
				Emit.load(R10, local(16)),
				Emit.load(Rcx, Emit.mem(R10, 0)),
				Emit.minus_imm(Rcx, 2),
				Emit.cmp_imm(Rcx, 0),
				Emit.jcc(Ge, "runtime_splice_put"),
				Emit.zero(Rcx),
				Emit.mark("runtime_splice_put"),
				Emit.store(local(56), Rcx),
				# The new length, and the items: those before the start, those
				# put in, then those after what is removed.
				Emit.load(R10, local(8)),
				Emit.load(Rdi, Emit.mem(R10, 0)),
				Emit.load(Rax, local(32)),
				Emit.minus(Rdi, Rax),
				Emit.plus(Rdi, Rcx),
				Emit.call(Runtime.new_array),
				Emit.store(local(48), Rax),
				Emit.mov(Rdi, Rdx),
				Emit.load(R10, local(8)),
				Emit.load(Rsi, Emit.mem(R10, 16)),
				Emit.load(Rcx, local(24)),
				Emit.shl(Rcx, 3),
				Instruction(RepMovsb),
				Emit.load(R10, local(16)),
				Emit.load(Rsi, Emit.mem(R10, 16)),
				Emit.plus_imm(Rsi, 16),
				Emit.load(Rcx, local(56)),
				Emit.shl(Rcx, 3),
				Instruction(RepMovsb),
				Emit.load(R10, local(8)),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rax, local(24)),
				Emit.load(Rcx, local(32)),
				Emit.plus(Rax, Rcx),
				Emit.lea(Rsi, listed_item(Rax)),
				Emit.load(Rcx, Emit.mem(R10, 0)),
				Emit.minus(Rcx, Rax),
				Emit.shl(Rcx, 3),
				Instruction(RepMovsb),
				Emit.load(Rax, local(48)),
			])
			.concat(unboxed_items(Rax))
			.concat([
				Emit.load(R10, local(8)),
				Emit.load(Rcx, Emit.mem(Rax, 0)),
				Emit.store(Emit.mem(R10, 0), Rcx),
				Emit.load(Rcx, Emit.mem(Rax, 8)),
				Emit.store(Emit.mem(R10, 8), Rcx),
				Emit.load(Rcx, Emit.mem(Rax, 16)),
				Emit.store(Emit.mem(R10, 16), Rcx),
				Emit.load(Rax, local(40)),
				Emit.mov(Rsp, Rbp),
				Emit.restore(Rbp),
				Emit.ret,
			])
	# An array's items from the last, compared by `===`; a string's places
	# from the last where the string sought fits, byte by byte. r9 the
	# place, r10 the receiver, r11 the value sought.
	last_index_of =
		[Emit.mark(Runtime.last_index_of), Emit.mov(R11, Rsi)]
			.concat(tag_load_items(Rdi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.string_tag),
				Emit.jcc(E, "runtime_last_index_of_string"),
			])
			.concat(array_check_items)
			.concat(unboxed_items(Rdi))
			.concat([
				Emit.mov(R10, Rdi),
				Emit.load(R9, Emit.mem(R10, 0)),
				Emit.mark("runtime_last_index_of_item"),
				Emit.minus_imm(R9, 1),
				Emit.cmp_imm(R9, 0),
				Emit.jcc(L, "runtime_last_index_of_none"),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rdi, listed_item(R9)),
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
			.concat(unless_string_items({ reg: Rsi, label: "runtime_index_of_sought_stop" }))
			.concat(unboxed_items(Rdi))
			.concat(unboxed_items(Rsi))
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
				text_byte_item({ reg: Rax, base: Rdi }),
				Emit.mov(R8, Rcx),
				text_byte_item({ reg: R8, base: Rsi }),
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
				Emit.imm(Rax, double_bits(-1.0)),
				Emit.ret,
			])
	# Each number made a whole one and its low 16 bits taken, as
	# JavaScript's ToUint16 does; one past ASCII stops the program.
	from_char_codes =
		[Emit.mark(Runtime.from_char_codes)]
			.concat(unboxed_items(Rdi))
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
				Emit.load(Rdx, listed_item(R11)),
			])
			.concat(unless_number_items({ reg: Rdx, label: "runtime_not_a_number_stop" }))
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
			.concat(boxed_string_items)
			.append(Emit.ret)
			.append(Emit.mark("runtime_from_char_codes_wide"))
			.concat(stopping_items("runtime_text_wide_char"))
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
			.concat(tag_load_items(Rdi))
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
			.concat(unless_number_items({ reg: Rax, label: "runtime_array_from_sized" }))
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
			.concat(unboxed_items(R10))
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
			.concat(unboxed_items(R10))
			.concat([
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rcx, Emit.mem(Rbp, -32)),
				Emit.store(listed_item(Rcx), Rax),
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

## The Maps and the Sets (`Boxing.collection_tag`): `runtime_new_collection`,
## `runtime_collection_method` and the walks of a Map, a Set or an
## iterator, which `for ... of`, a spread and `forEach` share. An entry
## deleted keeps its place, its key `Boxing.gone_bits`, so a walk under
## way meets the entries after it and those set later, as JavaScript's do;
## `clear` deletes each entry the same way.
collection_items : List(Assembly.Statement)
collection_items = {
	local = |offset| Emit.mem(Rbp, 0 - offset)
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
				Emit.store(local(8), Rdi),
				Emit.store(local(16), Rsi),
				Emit.zero(Rax),
				Emit.store(local(24), Rax),
				Emit.mark("runtime_collection_find_next"),
				Emit.load(R10, local(8)),
				Emit.load(Rcx, local(24)),
				Emit.load(Rdx, Emit.mem(R10, 16)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, "runtime_collection_find_none"),
				Emit.shl(Rcx, 4),
				Emit.load(R8, Emit.mem(R10, 32)),
				Emit.plus(R8, Rcx),
				Emit.load(Rdi, Emit.mem(R8, 0)),
				Emit.load(Rsi, local(16)),
				Emit.cmp(Rdi, Rsi),
				Emit.jcc(E, "runtime_collection_find_found"),
			])
			.concat(tag_load_items(Rdi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.string_tag),
				Emit.jcc(Ne, "runtime_collection_find_number"),
			])
			.concat(unless_string_items({ reg: Rsi, label: "runtime_collection_find_step" }))
			.concat(unboxed_items(Rdi))
			.concat(unboxed_items(Rsi))
			.concat([
				Emit.call("runtime_text_equal"),
				Emit.test(Rax, Rax),
				Emit.jcc(Ne, "runtime_collection_find_found"),
				Emit.jmp("runtime_collection_find_step"),
				Emit.mark("runtime_collection_find_number"),
				Emit.cmp_imm(Rcx, Boxing.first_tag),
				Emit.jcc(Ae, "runtime_collection_find_step"),
			])
			.concat(unless_number_items({ reg: Rsi, label: "runtime_collection_find_step" }))
			.concat([
				Emit.to_xmm(Xmm0, Rdi),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
				Emit.jcc(Np, "runtime_collection_find_step"),
				Emit.to_xmm(Xmm0, Rsi),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
				Emit.jcc(P, "runtime_collection_find_found"),
				Emit.mark("runtime_collection_find_step"),
				Emit.load(Rcx, local(24)),
				Emit.plus_imm(Rcx, 1),
				Emit.store(local(24), Rcx),
				Emit.jmp("runtime_collection_find_next"),
				Emit.mark("runtime_collection_find_found"),
				Emit.load(R10, local(8)),
				Emit.load(Rax, local(24)),
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
				Emit.store(local(8), Rax),
				Emit.mov(Rdi, Rsi),
			])
			.concat(nullish_jump_items("runtime_new_collection_done"))
			.concat([Emit.call(Runtime.items_of)])
			.concat(unboxed_items(Rax))
			.concat([
				Emit.store(local(16), Rax),
				Emit.zero(Rax),
				Emit.store(local(24), Rax),
				Emit.mark("runtime_new_collection_next"),
				Emit.load(R10, local(16)),
				Emit.load(Rcx, local(24)),
				Emit.load(Rdx, Emit.mem(R10, 0)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, "runtime_new_collection_done"),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rsi, listed_item(Rcx)),
				Emit.plus_imm(Rcx, 1),
				Emit.store(local(24), Rcx),
				Emit.load(Rdi, local(8)),
				Emit.load(Rcx, Emit.mem(Rdi, 0)),
				Emit.test(Rcx, Rcx),
				Emit.jcc(Ne, "runtime_new_collection_value"),
			])
			.concat(tag_load_items(Rsi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(Ne, "runtime_new_collection_not_entry"),
				Emit.mov(R9, Rsi),
			])
			.concat(unboxed_items(R9))
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
				Emit.load(Rax, local(8)),
			])
			.concat(boxed_items(Boxing.collection_tag))
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
			.concat(tag_load_items(Rdi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(E, "runtime_collection_next_array"),
			])
			.concat(unboxed_items(Rdi))
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
			.concat(unboxed_items(Rdi))
			.concat([
				Emit.load(Rcx, Emit.mem(Rdi, 0)),
				Emit.cmp(R9, Rcx),
				Emit.jcc(Ae, "runtime_collection_next_none"),
				Emit.load(R8, Emit.mem(Rdi, 16)),
				Emit.load(R8, listed_item(R9)),
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
			.concat(tag_load_items(Rdi))
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
			.concat([Emit.store(local(8), Rdi), Emit.mov(Rax, Rdi)])
			.concat(unboxed_items(Rax))
			.concat([
				Emit.zero(Rcx),
				Emit.store(local(16), Rcx),
				Emit.store(local(40), Rcx),
				Emit.load(Rcx, Emit.mem(Rax, 0)),
				Emit.cmp_imm(Rcx, 2),
				Emit.jcc(E, "runtime_items_of_iterator"),
				Emit.imm(Rdx, 2),
				Emit.minus(Rdx, Rcx),
				Emit.store(local(24), Rdx),
				Emit.jmp("runtime_items_of_walk"),
				Emit.mark("runtime_items_of_iterator"),
				Emit.store(local(40), Rax),
				Emit.load(Rcx, Emit.mem(Rax, 8)),
				Emit.store(local(8), Rcx),
				Emit.load(Rcx, Emit.mem(Rax, 16)),
				Emit.store(local(16), Rcx),
				Emit.load(Rcx, Emit.mem(Rax, 24)),
				Emit.store(local(24), Rcx),
				Emit.mark("runtime_items_of_walk"),
				Emit.zero(Rdi),
				Emit.call(Runtime.new_array),
				Emit.store(local(32), Rax),
				Emit.mark("runtime_items_of_step"),
				Emit.load(Rdi, local(8)),
				Emit.load(Rsi, local(16)),
				Emit.load(Rdx, local(24)),
				Emit.call("runtime_collection_next"),
				Emit.store(local(16), Rcx),
				Emit.test(Rdx, Rdx),
				Emit.jcc(E, "runtime_items_of_walked"),
				Emit.load(Rdi, local(32)),
			])
			.concat(unboxed_items(Rdi))
			.concat([
				Emit.mov(Rsi, Rax),
				Emit.call("runtime_push_item"),
				Emit.jmp("runtime_items_of_step"),
				Emit.mark("runtime_items_of_walked"),
				Emit.load(Rax, local(40)),
				Emit.test(Rax, Rax),
				Emit.jcc(E, "runtime_items_of_given"),
				Emit.load(Rcx, local(16)),
				Emit.store(Emit.mem(Rax, 16), Rcx),
				Emit.mark("runtime_items_of_given"),
				Emit.load(Rax, local(32)),
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
		.concat(boxed_items(Boxing.collection_tag))
		.append(Emit.ret)
	# A Map's or a Set's `forEach`: the function `rsi` called with each
	# live entry's value, its key and the Map or Set `rdi`, entries set
	# during the walk met too. Its frame: the Map or Set (8), the function
	# (16) and the place (24).
	for_each =
		framed({ label: "runtime_collection_for_each", size: 32 })
			.concat([
				Emit.store(local(8), Rdi),
				Emit.store(local(16), Rsi),
				Emit.mov(Rax, Rsi),
				Emit.call(Runtime.check_function),
				Emit.zero(Rax),
				Emit.store(local(24), Rax),
				Emit.mark("runtime_collection_for_each_next"),
				Emit.load(R10, local(8)),
			])
			.concat(unboxed_items(R10))
			.concat([
				Emit.load(Rcx, local(24)),
				Emit.load(Rdx, Emit.mem(R10, 16)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, "runtime_collection_for_each_done"),
				Emit.mov(Rax, Rcx),
				Emit.shl(Rax, 4),
				Emit.load(R8, Emit.mem(R10, 32)),
				Emit.plus(R8, Rax),
				Emit.plus_imm(Rcx, 1),
				Emit.store(local(24), Rcx),
				Emit.load(Rsi, Emit.mem(R8, 0)),
				Emit.imm(Rax, Boxing.gone_bits),
				Emit.cmp(Rsi, Rax),
				Emit.jcc(E, "runtime_collection_for_each_next"),
				Emit.load(Rax, local(8)),
				Emit.save(Rax),
				Emit.save(Rsi),
				Emit.load(Rax, Emit.mem(R8, 8)),
				Emit.save(Rax),
				Emit.load(Rbx, local(16)),
			])
			.concat(unboxed_items(Rbx))
			.concat([
				Emit.load(Rax, Emit.mem(Rbx, 0)),
				Emit.plus(Rax, Rbx),
				Emit.imm(Rcx, 3),
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
				Emit.store(local(8), Rdi),
				Emit.store(local(16), Rcx),
				Emit.store(local(24), Rdx),
				Emit.store(local(48), Rsi),
			])
			.concat(tag_load_items(Rdi))
			.concat([
				Emit.cmp_imm(Rcx, Boxing.collection_tag),
				Emit.jcc(E, "runtime_collection_method_own"),
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(Ne, "runtime_collection_method_property"),
				Emit.load(Rcx, local(16)),
				Emit.cmp_imm(Rcx, 6),
				Emit.jcc(B, "runtime_collection_method_property"),
				Emit.mark("runtime_collection_method_iterator"),
				Emit.load(Rsi, local(16)),
				Emit.minus_imm(Rsi, 6),
				Emit.load(Rdi, local(8)),
				Emit.call("runtime_iterator_of"),
			])
			.concat(leave)
			.concat([
				Emit.mark("runtime_collection_method_property"),
				Emit.load(Rdi, local(8)),
				Emit.load(Rsi, local(48)),
				Emit.call(Runtime.get_property),
				Emit.mov(Rdi, Rax),
				Emit.load(Rsi, local(24)),
				Emit.call(Runtime.call_spread),
			])
			.concat(leave)
			.concat([Emit.mark("runtime_collection_method_own"), Emit.mov(Rax, Rdi)])
			.concat(unboxed_items(Rax))
			.concat([
				Emit.load(Rcx, Emit.mem(Rax, 0)),
				Emit.cmp_imm(Rcx, 2),
				Emit.jcc(E, "runtime_collection_method_stop"),
				Emit.load(R10, local(24)),
			])
			.concat(unboxed_items(R10))
			.concat([
				Emit.load(Rcx, Emit.mem(R10, 0)),
				Emit.imm(Rax, Boxing.undefined_bits),
				Emit.store(local(32), Rax),
				Emit.store(local(40), Rax),
				Emit.test(Rcx, Rcx),
				Emit.jcc(E, "runtime_collection_method_given"),
				Emit.load(R8, Emit.mem(R10, 16)),
				Emit.load(Rax, Emit.mem(R8, 0)),
				Emit.store(local(32), Rax),
				Emit.cmp_imm(Rcx, 1),
				Emit.jcc(E, "runtime_collection_method_given"),
				Emit.load(Rax, Emit.mem(R8, 8)),
				Emit.store(local(40), Rax),
				Emit.mark("runtime_collection_method_given"),
				Emit.load(Rdi, local(8)),
			])
			.concat(unboxed_items(Rdi))
			.concat([
				Emit.load(Rsi, local(32)),
				# r8: 0 for a Map, 1 for a Set.
				Emit.load(R8, Emit.mem(Rdi, 0)),
				Emit.load(Rcx, local(16)),
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
				Emit.load(Rax, local(8)),
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
				Emit.load(Rdx, local(40)),
				Emit.call("runtime_collection_put"),
				Emit.load(Rax, local(8)),
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
				Emit.load(Rdi, local(8)),
			])
			.concat(unboxed_items(Rdi))
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
			.concat(answer({ label: "runtime_collection_method_true", value: Boxing.true_bits }))
			.concat(answer({ label: "runtime_collection_method_false", value: Boxing.false_bits }))
			.append(Emit.mark("runtime_collection_method_stop"))
			.concat(stopping_items("runtime_text_collection_method"))
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
