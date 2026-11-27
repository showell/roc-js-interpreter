## This module holds the machine code every compiled program carries beside
## its own: the start, which maps the heap; the bump allocator; buffered
## output; the stops (a message to stderr and exit 1); and `console.log`'s
## writing of a number. Each piece is a list of `Assembly` statements under
## labels that start `runtime_`, which no function of the program's takes, so
## the program's code calls them by name.
##
## **FOUR REGISTERS ARE THE RUNTIME'S FOR THE WHOLE RUN**, and no other code
## writes them: `r12` holds the lowest the stack may reach, `r13` the
## runtime's state (the output buffer's fill, node's inspect depth, the
## innermost `try`'s handler record, the timers' places, then the buffer,
## as `buffer_place` lays them out), `r14` the heap's end and `r15` the
## heap's state, its pages' places and table (`Heap`'s header lays it out).
## A routine may change every
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
import Heap
import RuntimeBuilders

Runtime :: [].{

	## The routine that writes the number whose bits are in `rax`.
	print_number : Str
	print_number = "runtime_print_number"

	## The routine that gives the text of the number whose bits are in
	## `rax`: a string's address (its length, then its bytes) in `rax`.
	number_text : Str
	number_text = "runtime_number_text"

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

	## Where a value that should be a number and isn't stops the program
	## (`runtime_check_number`'s stop), for code that tests the tag in line.
	not_a_number_stop : Str
	not_a_number_stop = "runtime_not_a_number_stop"

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

	## The stop of an item read of an array of numbers that finds no item.
	numbers_read_not_compiled : Str
	numbers_read_not_compiled = "runtime_numbers_read_not_compiled"

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

	## The routine that gives the bitwise operators' ToInt32 of `rdi`, a
	## number, in `rax`, sign-extended to 64 bits, and stops for any other
	## value. It changes `rcx`, `rdx`, `r8` and `xmm0`.
	word_of : Str
	word_of = "runtime_word_of"

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

	## Whether the program has ever given a class's instance an own
	## property of a name its class's table holds, shadowing a method: 1
	## once it has, else 0. Set by `runtime_set_property` when it adds the
	## key, read by ObjectTable's `runtime_get_method_hashed`.
	shadowed_place : X86.Mem
	shadowed_place = Emit.mem(R13, 56)

	## The same for a class's method called through a value: the array of
	## its receiver, in `r8`, then the `rsi` arguments at `rdi`.
	pack_received : Str
	pack_received = "runtime_pack_received"

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

	## `value instanceof C`: the value in `rdi`, the key that marks C's
	## instances at `rsi` (`NewInstance`'s), the boolean in `rax`.
	instance_of : Str
	instance_of = "runtime_instance_of"

	## The routine that gives an error's message of the value `rdi`, as
	## `new Error(v)` takes it: `""` for `undefined`, else `String(v)`, a
	## string's address in `rax`.
	error_message : Str
	error_message = "runtime_error_message"

	## The message of node's TypeError for a constant assigned.
	constant_assigned_text : Str
	constant_assigned_text = "runtime_text_constant_assigned"

	## The message of node's TypeError for `Map()` or `Set()` called
	## without `new`.
	new_required_text : Str -> Str
	new_required_text = |name| "runtime_text_new_required_${name}"

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

	## The routine of a function of `Math`, by its name: of one number,
	## `floor`, `ceil`, `round`, `trunc`, `abs`, `sign` and `sqrt`, its bits
	## in `rdi`; of two, `max` and `min`, the second in `rsi`; the answer's
	## bits in `rax`. Each changes `rcx`, `rdx` and `xmm0` to `xmm2` too.
	math_routine : Str -> Str
	math_routine = |name| "runtime_math_${name}"

	## The routine of `Date.now()`: the milliseconds since the epoch, whole,
	## as a number's bits in `rax`, from the kernel's real-time clock. It
	## changes `rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r11` and `xmm0` too.
	date_now : Str
	date_now = "runtime_date_now"

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

	## The routine that sets a timer, the function `rdi` called `rsi` ms on
	## the virtual clock (`undefined` or below 1 is 1), once (`rdx` 0) or
	## every `rsi` ms (1); it gives the timer, a handle `clear_timer` takes.
	set_timer : Str
	set_timer = "runtime_set_timer"

	## The routine that clears the timer `rdi`; any other value is let be.
	clear_timer : Str
	clear_timer = "runtime_clear_timer"

	## Where the program's code ends: each timer's callback runs, earliest
	## first, then the program exits 0.
	run_timers : Str
	run_timers = "runtime_run_timers"

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

	## The routine that gives `String(v)` of the value `rdi`, boxed, in `rax`;
	## `runtime_text_of` gives the same string's address, unboxed.
	text_of_boxed : Str
	text_of_boxed = "runtime_text_of_boxed"

	## The texts the runtime writes, each under its label.
	Text : [Space, Newline]

	## The label of one of the texts.
	text_label : Runtime.Text -> Str
	text_label = |text|
		match text {
			Space => "runtime_text_space"
			Newline => "runtime_text_newline"
		}

	## The statements that write one of the texts to stdout.
	text_items : Runtime.Text -> List(Assembly.Statement)
	text_items = |text| {
		label = Runtime.text_label(text)
		[
			Emit.address_of(Rsi, label),
			Emit.load(Rdx, Emit.mem(Rsi, 0)),
			Emit.plus_imm(Rsi, 8),
			Emit.call(write),
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
	## set, the heap's state laid out (`Heap.start_items`), then a call of the
	## program's own code at `main`.
	start_items : Str -> List(Assembly.Statement)
	start_items = |main| [
		Emit.imm(Rax, 9),
		Emit.zero(Rdi),
		Emit.imm(Rsi, Heap.mapped_size),
		Emit.imm(Rdx, 3),
		Emit.imm(R10, 0x4022),
		Emit.imm(R8, -1),
		Emit.zero(R9),
		Emit.syscall,
		Emit.test(Rax, Rax),
		Emit.jcc(S, "runtime_no_heap"),
		Emit.mov(R13, Rax),
		Emit.lea(R15, Emit.mem(Rax, buffer_place + buffer_size)),
		# 2 GiB is past an immediate of 32 bits, so the end is a sum.
		Emit.imm(R14, Heap.mapped_size),
		Emit.plus(R14, Rax),
	]
		.concat(Heap.start_items)
		.concat([
			Emit.mov(R12, Rsp),
			Emit.minus_imm(R12, stack_size),
			Emit.call(main),
		])

	## Every routine of this module's, which `RuntimeCode` lays down before
	## `LanguageRoutines.items`, `ArrayMethods.items`, `Inspect.items`,
	## `Collections.items`, `Timers.items` and the texts.
	routine_items : List(Assembly.Statement)
	routine_items = [
		Heap.items,
		output_items,
		heap_exit_items,
		stop_items,
		write_value_items,
		number_items,
		string_items,
		operator_items,
		property_items,
		container_items,
		loop_items,
	]
		.join()
}

## The routine that writes `rdx` bytes at `rsi` to stdout, through the
## buffer.
write : Str
write = "runtime_write"

## How far below the stack's start the program's frames may reach. Linux
## gives a program 8 MiB of stack unless told otherwise; what is left past
## this is for the runtime's own routines.
stack_size : I64
stack_size = 6 * 1024 * 1024

## Where the output buffer starts past `r13`, and its size. Before it are
## the buffer's fill (`[r13]`), node's inspect depth (8), the innermost
## `try`'s handler (16, 0 when none waits), the timers' places, 24 to
## 48, which `Timers` holds and describes, and whether a method was ever
## shadowed (56, `Runtime.shadowed_place`).
buffer_place : I64
buffer_place = 64

buffer_size : I64
buffer_size = 65536

digit_zero : U8
digit_zero = '0'

minus_sign : U8
minus_sign = '-'

## Buffered output. `runtime_write` copies into the buffer, which is written
## when the next bytes wouldn't fit, before a stop's message, and at the
## exit; bytes that would fill the buffer alone are written at once.
## `runtime_write_all` is the `write` system call until every byte is
## written.
output_items : List(Assembly.Statement)
output_items = [
	Emit.mark(write),
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
	Emit.jcc(Be, write),
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
	Emit.call("runtime_heap_exit"),
	Emit.call("runtime_flush"),
	Emit.restore(Rdi),
	Emit.imm(Rax, 231),
	Emit.syscall,
]

## `runtime_heap_exit`: the heap walked at the exit when the program's first
## argument asked for it (`Heap.mode_place`), the mode cleared first so a
## stop the walk makes doesn't walk again; with `heapstat`, its counts are
## written after the program's own output, a line:
## `heap: <n> blocks, <n> bytes asked, <n> bytes in blocks, <n> pages`.
heap_exit_items : List(Assembly.Statement)
heap_exit_items = {
	counted = |{ place, text }| [
		Emit.load(Rax, place),
		Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
		Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
		Emit.call(Runtime.print_number),
		Emit.address_of(Rsi, text),
		Emit.load(Rdx, Emit.mem(Rsi, 0)),
		Emit.plus_imm(Rsi, 8),
		Emit.call(write),
	]
	[
		[
			Emit.mark("runtime_heap_exit"),
			Emit.load(Rax, Heap.mode_place),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_heap_exit_done"),
			Emit.zero(Rcx),
			Emit.store(Heap.mode_place, Rcx),
			Emit.save(Rax),
			Emit.call(Heap.walk),
			Emit.restore(Rax),
			Emit.cmp_imm(Rax, 2),
			Emit.jcc(Ne, "runtime_heap_exit_done"),
			Emit.address_of(Rsi, "runtime_text_heap_counts"),
			Emit.load(Rdx, Emit.mem(Rsi, 0)),
			Emit.plus_imm(Rsi, 8),
			Emit.call(write),
		],
		counted({ place: Heap.blocks_place, text: "runtime_text_heap_blocks" }),
		counted({ place: Heap.asked_place, text: "runtime_text_heap_asked" }),
		counted({ place: Heap.held_place, text: "runtime_text_heap_held" }),
		counted({ place: Heap.pages_place, text: "runtime_text_heap_pages" }),
		[Emit.mark("runtime_heap_exit_done"), Emit.ret],
	].join()
}

## The stops: what was buffered is written, then the message at `rsi` (a
## string as the heap holds one) to stderr, and the exit is 1.
stop_items : List(Assembly.Statement)
stop_items =
	[
		Emit.mark("runtime_stop"),
		Emit.save(Rsi),
		# The heap walked when the program's first argument asked for it,
		# the mode cleared first so the walk's own stop doesn't walk again.
		Emit.load(Rax, Heap.mode_place),
		Emit.test(Rax, Rax),
		Emit.jcc(E, "runtime_stop_walked"),
		Emit.zero(Rcx),
		Emit.store(Heap.mode_place, Rcx),
		Emit.call(Heap.walk),
		Emit.mark("runtime_stop_walked"),
		Emit.call("runtime_flush"),
		Emit.restore(Rsi),
	]
		.concat(message_exit_items)
		.concat([
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
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_stack_overflow"))
		.append(Emit.mark(Heap.out_of_memory))
		.concat(RuntimeBuilders.stopping_items("runtime_text_out_of_memory"))
		.append(Emit.mark("runtime_no_heap"))
		.append(Emit.address_of(Rsi, "runtime_text_no_heap"))
		.concat(message_exit_items)

## The string at `rsi` (its length, then its bytes) written to stderr,
## then the exit, 1. A stop with no heap has no buffer to write first.
message_exit_items : List(Assembly.Statement)
message_exit_items = [
	Emit.load(Rdx, Emit.mem(Rsi, 0)),
	Emit.plus_imm(Rsi, 8),
	Emit.imm(Rdi, 2),
	Emit.call("runtime_write_all"),
	Emit.imm(Rdi, 1),
	Emit.imm(Rax, 231),
	Emit.syscall,
]

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
		Emit.jmp(write),
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
		.concat(RuntimeBuilders.stopping_items("runtime_text_value_not_written"))
		.concat(written("runtime_text_undefined"))
		.concat(written("runtime_text_null"))
		.concat(written("runtime_text_false"))
		.concat(written("runtime_text_true"))
		.concat([Emit.mark("runtime_write_string")])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.mark("runtime_write_text"),
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.lea(Rsi, Emit.mem(Rdi, 8)),
			Emit.jmp(write),
			Emit.mark("runtime_write_inspected"),
			Emit.zero(Rsi),
			Emit.call("runtime_inspect"),
			Emit.mov(Rdi, Rax),
			Emit.jmp("runtime_write_text"),
		])
}

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
		.concat(RuntimeBuilders.tag_load_items(Rdi))
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
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(Ne, "runtime_text_of_object"),
			Emit.address_of(Rsi, Runtime.comma_text),
			Emit.call(Runtime.join),
		])
		.concat(RuntimeBuilders.unboxed_items(Rax))
		.concat([
			Emit.ret,
			Emit.mark("runtime_text_of_object"),
			Emit.mov(Rax, Rdi),
		])
		.concat(RuntimeBuilders.unboxed_items(Rax))
		.concat([
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_text_of_plain"),
			Emit.load(Rcx, Emit.mem(Rax, 16)),
			Emit.load(Rcx, Emit.mem(Rcx, 0)),
			Emit.address_of(Rdx, RuntimeBuilders.error_mark),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(E, "runtime_error_text"),
			Emit.mark("runtime_text_of_plain"),
			Emit.address_of(Rax, "runtime_text_object_object"),
			Emit.ret,
		])
		.append(Emit.mark("runtime_text_of_function"))
		.concat(RuntimeBuilders.stopping_items("runtime_text_text_of_function"))
		.append(Emit.mark("runtime_text_of_collection"))
		.concat(RuntimeBuilders.unboxed_items(Rax))
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
		.concat(RuntimeBuilders.stopping_items("runtime_text_iterator_written"))
		.concat(given("runtime_text_undefined"))
		.concat(given("runtime_text_null"))
		.concat(given("runtime_text_false"))
		.concat(given("runtime_text_true"))
		.append(Emit.mark("runtime_text_of_string"))
		.concat(RuntimeBuilders.unboxed_items(Rax))
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
		Emit.call(Heap.allocate(String)),
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
		RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
		RuntimeBuilders.text_byte_item({ reg: Rdx, base: Rsi }),
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
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.mov(Rsi, Rax),
			Emit.call("runtime_concat"),
			Emit.restore(Rsi),
			Emit.mov(Rdi, Rax),
			Emit.call("runtime_concat"),
		])
		.concat(RuntimeBuilders.boxed_string_items)
		.append(Emit.ret)
	[text_of, concat, equal, template].join()
}

## The statements that jump to `runtime_add_texts` when the value in `reg`
## is an array or an object, which `+` makes a string.
object_added_items : X86.Register -> List(Assembly.Statement)
object_added_items = |reg|
	RuntimeBuilders.tag_load_items(reg).concat([
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
		RuntimeBuilders.unless_number_items({ reg: Rdi, label: other })
			.concat(RuntimeBuilders.unless_number_items({ reg: Rsi, label: other }))
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
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.string_tag), Emit.jcc(E, "runtime_add_texts")])
		.concat(RuntimeBuilders.tag_load_items(Rsi))
		.concat([Emit.cmp_imm(Rcx, Boxing.string_tag), Emit.jcc(E, "runtime_add_texts")])
		# An array or an object is made a string first, so `+` joins.
		.concat(object_added_items(Rdi))
		.concat(object_added_items(Rsi))
		# A function would be its source's text; anything else left is a
		# number, `undefined`, `null` or a boolean, each made a number.
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.function_tag), Emit.jcc(E, "runtime_add_stop")])
		.concat(RuntimeBuilders.tag_load_items(Rsi))
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
		.concat(RuntimeBuilders.stopping_items("runtime_text_add_not_compiled"))
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
		.concat(RuntimeBuilders.boxed_string_items)
		.append(Emit.ret)
	check = [Emit.mark(Runtime.check_number)]
		.concat(RuntimeBuilders.tag_load_items(Rax))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(Ae, Runtime.not_a_number_stop),
			Emit.ret,
			Emit.mark(Runtime.not_a_number_stop),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_arithmetic_not_compiled"))
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
		.concat(
			RuntimeBuilders.unless_string_items({ reg: Rdi, label: "runtime_strict_equal_false" }),
		)
		.concat(
			RuntimeBuilders.unless_string_items({ reg: Rsi, label: "runtime_strict_equal_false" }),
		)
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat(RuntimeBuilders.unboxed_items(Rsi))
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
		.concat(RuntimeBuilders.unless_string_items({ reg: Rdi, label: "runtime_compare_mixed" }))
		.concat(RuntimeBuilders.unless_string_items({ reg: Rsi, label: "runtime_compare_mixed" }))
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat(RuntimeBuilders.unboxed_items(Rsi))
		.concat([
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.load(R10, Emit.mem(Rsi, 0)),
			Emit.zero(R8),
			Emit.mark("runtime_compare_byte"),
			Emit.cmp(R8, R9),
			Emit.jcc(E, "runtime_compare_first_ended"),
			Emit.cmp(R8, R10),
			Emit.jcc(E, "runtime_compare_greater"),
			RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
			RuntimeBuilders.text_byte_item({ reg: Rdx, base: Rsi }),
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
		.concat(RuntimeBuilders.stopping_items("runtime_text_compare_not_compiled"))
		.concat(answer({ label: "runtime_compare_less", value: 0 }))
		.concat(answer({ label: "runtime_compare_equal", value: 1 }))
		.concat(answer({ label: "runtime_compare_greater", value: 2 }))
		.concat(answer({ label: "runtime_compare_unordered", value: 3 }))
	truthy = [Emit.mark(Runtime.truthy)]
		.concat(RuntimeBuilders.unless_number_items({ reg: Rdi, label: "runtime_truthy_other" }))
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
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rax, Emit.mem(Rdi, 0)),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_truthy_no"),
		])
		.concat(answer({ label: "runtime_truthy_yes", value: 1 }))
		.concat(answer({ label: "runtime_truthy_no", value: 0 }))
	check_function = [Emit.mark(Runtime.check_function)]
		.concat(RuntimeBuilders.tag_load_items(Rax))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.function_tag),
			Emit.jcc(Ne, "runtime_not_a_function_stop"),
			Emit.ret,
			Emit.mark("runtime_not_a_function_stop"),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_not_a_function"))
	cell = [
		Emit.mark(Runtime.new_cell),
		Emit.imm(Rdi, 8),
		Emit.call(Heap.allocate(Cell)),
		Emit.store(Emit.mem(Rax, 0), Rsi),
		Emit.ret,
	]
	# The constants' payloads are 0 to 3: `undefined` NaN, `null` and
	# `false` 0, `true` 1.
	to_number = [Emit.mark(Runtime.to_number), Emit.mov(Rax, Rdi)]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.first_tag),
			Emit.jcc(B, "runtime_to_number_done"),
			Emit.mov(Rcx, Rdi),
		])
		.concat(RuntimeBuilders.unboxed_items(Rcx))
		.concat([
			Emit.imm(Rax, 0x7FF8000000000000),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_to_number_done"),
			Emit.imm(Rax, RuntimeBuilders.double_bits(1.0)),
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
		.concat(RuntimeBuilders.tag_load_items(Rdi))
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
		.concat(RuntimeBuilders.nullish_jump_items("runtime_get_property_nullish"))
		.concat(RuntimeBuilders.stopping_items("runtime_text_property_not_compiled"))
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
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.cmp_imm(Rcx, 2),
			Emit.jcc(Ae, "runtime_get_undefined"),
			Emit.load(Rax, Emit.mem(Rdi, 8)),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.ret,
		])
		.append(Emit.mark("runtime_get_property_object"))
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.mark("runtime_get_entry"),
			Emit.save(Rdi),
			Emit.call("runtime_object_entry"),
			Emit.restore(Rdi),
			Emit.test(Rax, Rax),
			# A class's instance reads what it lacks from its class's table.
			Emit.jcc(E, "runtime_get_inherited"),
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
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rax, Emit.mem(Rdi, 0)),
			Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
			Emit.ret,
			Emit.mark("runtime_get_length_other"),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_property_not_compiled"))

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
		Emit.jmp(write),
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
			Emit.call(Heap.allocate(String)),
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
		.concat(RuntimeBuilders.stopping_items("runtime_text_not_written"))
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

## An array is 24 bytes, its length, its capacity and its items' address,
## and its items are 8 bytes each; an object is 40 bytes, its count of
## properties, its capacity, its entries' address, then its table's address
## and the count of entries the table covers (ObjectTable's header), and
## its entries are 16 bytes each, a key's address (a string) and the value.
## A full list is copied to one twice its size.
## `runtime_object_entry_scan`, which ObjectTable's `runtime_object_entry`
## calls for an object of few keys, gives the address of the value of the
## key `rsi` (a string) in the object `rdi`, or 0, keeping `rsi`, by
## searching the entries in order; `runtime_push_item` pushes `rsi` onto the
## array at `rdi`, its new length in `rax`.
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
		Emit.call(Heap.allocate(Array)),
		Emit.restore(Rcx),
		Emit.restore(Rdx),
		Emit.store(Emit.mem(Rax, 0), Rdx),
		Emit.store(Emit.mem(Rax, 8), Rcx),
		Emit.lea(Rdx, Emit.mem(Rax, 24)),
		Emit.store(Emit.mem(Rax, 16), Rdx),
	]
		.concat(RuntimeBuilders.boxed_items(Boxing.array_tag))
		.append(Emit.ret)
	new_object = [
		Emit.mark(Runtime.new_object),
		Emit.imm(Rdi, 40 + 4 * 16),
		Emit.call(Heap.allocate(Object)),
		Emit.zero(Rcx),
		Emit.store(Emit.mem(Rax, 0), Rcx),
		Emit.store(Emit.mem(Rax, 24), Rcx),
		Emit.store(Emit.mem(Rax, 32), Rcx),
		Emit.imm(Rcx, 4),
		Emit.store(Emit.mem(Rax, 8), Rcx),
		Emit.lea(Rdx, Emit.mem(Rax, 40)),
		Emit.store(Emit.mem(Rax, 16), Rdx),
	]
		.concat(RuntimeBuilders.boxed_items(Boxing.object_tag))
		.append(Emit.ret)
	entry = [
		Emit.mark("runtime_object_entry_scan"),
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
		.concat(RuntimeBuilders.nullish_jump_items("runtime_set_property_nullish"))
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.object_tag), Emit.jcc(Ne, "runtime_not_an_object")])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
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
			# A key new to an instance that its class's table holds shadows a
			# method: the lookups of methods' names go own-first from then on.
			Emit.save(Rdi),
			Emit.save(Rsi),
			Emit.save(Rdx),
		])
		.concat(RuntimeBuilders.instance_jump_items("runtime_set_property_instance"))
		.concat([
			Emit.jmp("runtime_set_property_unshadowed"),
			Emit.mark("runtime_set_property_instance"),
			Emit.load(Rdi, Emit.mem(Rdi, 16)),
			Emit.load(Rdi, Emit.mem(Rdi, 8)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.call("runtime_object_entry"),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_set_property_unshadowed"),
			Emit.imm(Rax, 1),
			Emit.store(Runtime.shadowed_place, Rax),
			Emit.mark("runtime_set_property_unshadowed"),
			Emit.restore(Rdx),
			Emit.restore(Rsi),
			Emit.restore(Rdi),
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
			Emit.call(Heap.allocate(Entries)),
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
			# The entries after it moved, so the table covers none of them.
			Emit.zero(R8),
			Emit.store(Emit.mem(Rdi, 32), R8),
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.plus_imm(Rcx, 1),
			Emit.store(Emit.mem(Rdi, 0), Rcx),
			Emit.ret,
			Emit.mark("runtime_not_an_object"),
		])
		.concat(RuntimeBuilders.stopping_items("runtime_text_not_an_object"))
		.append(Emit.mark("runtime_integer_key"))
		.concat(RuntimeBuilders.stopping_items("runtime_text_integer_key"))
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
		RuntimeBuilders.text_byte_item({ reg: Rdx, base: Rsi }),
		RuntimeBuilders.text_byte_item({ reg: Rdi, base: Rcx }),
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
		RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
		Emit.cmp_imm(Rax, '0'),
		Emit.jcc(Ne, "runtime_is_index_key_digit"),
		Emit.cmp_imm(Rcx, 1),
		Emit.jcc(E, "runtime_is_index_key_yes"),
		Emit.jmp("runtime_is_index_key_no"),
		Emit.mark("runtime_is_index_key_digit"),
		Emit.cmp(R8, Rcx),
		Emit.jcc(E, "runtime_is_index_key_yes"),
		RuntimeBuilders.text_byte_item({ reg: Rax, base: Rdi }),
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
		Emit.call(Heap.allocate(Items)),
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
			.concat(RuntimeBuilders.tag_load_items(Rdi))
			.concat([Emit.cmp_imm(Rcx, Boxing.array_tag), Emit.jcc(Ne, "runtime_not_an_array")])
			.concat(RuntimeBuilders.unboxed_items(Rdi))
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
		.concat(RuntimeBuilders.stopping_items("runtime_text_not_an_array"))
	get_index = [Emit.mark(Runtime.get_index)]
		.concat(RuntimeBuilders.nullish_jump_items("runtime_get_index_nullish"))
		.concat(RuntimeBuilders.tag_load_items(Rdi))
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
		.concat(
			RuntimeBuilders.unless_number_items({ reg: Rsi, label: "runtime_index_not_compiled" }),
		)
		.concat(key_index_items("runtime_get_undefined"))
		.concat(RuntimeBuilders.unboxed_items(Rdi))
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
		.concat(
			RuntimeBuilders.unless_number_items({ reg: Rsi, label: "runtime_index_not_compiled" }),
		)
		.concat(key_index_items("runtime_get_undefined"))
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rdx, Emit.mem(Rdi, 0)),
			Emit.cmp(Rcx, Rdx),
			Emit.jcc(Ae, "runtime_get_undefined"),
			Emit.save(Rdi),
			Emit.save(Rcx),
			Emit.imm(Rdi, 9),
			Emit.call(Heap.allocate(String)),
			Emit.restore(R8),
			Emit.restore(Rdi),
			Emit.imm(Rdx, 1),
			Emit.store(Emit.mem(Rax, 0), Rdx),
			RuntimeBuilders.text_byte_item({ reg: Rdx, base: Rdi }),
			Emit.byte_store(Emit.mem(Rax, 8), Dl),
		])
		.concat(RuntimeBuilders.boxed_string_items)
		.concat([Emit.ret, Emit.mark("runtime_get_index_object")])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat(RuntimeBuilders.tag_load_items(Rsi))
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
		.concat(RuntimeBuilders.unboxed_items(Rsi))
		.concat([Emit.jmp("runtime_get_entry"), Emit.mark("runtime_index_not_compiled")])
		.concat(RuntimeBuilders.stopping_items("runtime_text_index_not_compiled"))
		# An item read of an array of numbers that finds no item
		# (`Lowering`'s `NUMBER-ONLY ARRAYS`): its code goes on with a number.
		.concat([Emit.mark(Runtime.numbers_read_not_compiled)])
		.concat(RuntimeBuilders.stopping_items("runtime_text_numbers_read_not_compiled"))
		.concat(keyed_error_items({ label: "runtime_get_index_nullish", setting: 0 }))
	set_index = [Emit.mark(Runtime.set_index)]
		.concat(RuntimeBuilders.nullish_jump_items("runtime_set_index_nullish"))
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(E, "runtime_set_index_array"),
			Emit.cmp_imm(Rcx, Boxing.object_tag),
			Emit.jcc(Ne, "runtime_index_not_compiled"),
		])
		.concat(RuntimeBuilders.tag_load_items(Rsi))
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
		.concat(RuntimeBuilders.unboxed_items(Rsi))
		.concat([Emit.jmp(Runtime.set_property), Emit.mark("runtime_set_index_array")])
		.concat(
			RuntimeBuilders.unless_number_items({ reg: Rsi, label: "runtime_index_not_compiled" }),
		)
		.concat(key_index_items("runtime_index_not_compiled"))
		.concat(RuntimeBuilders.unboxed_items(Rdi))
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
		.concat(RuntimeBuilders.stopping_items("runtime_text_array_hole"))
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

## `runtime_remainder`, by `idiv`: the remainder has the dividend's sign,
## and a zero one is -0 when the dividend is negative; `% 0` is NaN, and so
## is the remainder of an infinity or a NaN (its exponent's bits all set).
## `runtime_next_item`, for `for ... of`. `runtime_word_of`, for the
## bitwise operators: a number below 2^63 in size is truncated by
## `cvttsd2si`, whose low 32 bits are its ToInt32; NaN, an infinity and
## anything larger give `cvttsd2si`'s -2^63, the one value `cmp rax, 1`
## overflows on. Of those, NaN and the infinities (the exponent's bits all
## set) give 0, and a finite number of 2^63 or more in size is its 53 bits
## of mantissa shifted up by its exponent less 1075, at least 11: by 32 or
## more its low 32 bits are 0, and by less they are the mantissa's shifted,
## negated for a negative number.
loop_items : List(Assembly.Statement)
loop_items = {
	remainder = [Emit.mark(Runtime.remainder)]
		.concat(
			RuntimeBuilders.unless_number_items({ reg: Rdi, label: "runtime_not_a_number_stop" }),
		)
		.concat(
			RuntimeBuilders.unless_number_items({ reg: Rsi, label: "runtime_not_a_number_stop" }),
		)
		.concat([
			Emit.mov(Rax, Rdi),
			Emit.shl(Rax, 1),
			Emit.imm(Rcx, (0xFFE0000000000000).to_i64_wrap()),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(Ae, "runtime_remainder_not_a_number"),
		])
		.concat(
			RuntimeBuilders.whole_number_items({
				reg: Rdi,
				to: R8,
				label: "runtime_remainder_stop",
			}),
		)
		.concat(
			RuntimeBuilders.whole_number_items({
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
		.concat(RuntimeBuilders.stopping_items("runtime_text_remainder"))
	# r11: the next place, a whole number.
	next_item = [Emit.mark(Runtime.next_item)]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.collection_tag),
			Emit.jcc(E, "runtime_next_item_collection"),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
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
		.concat(RuntimeBuilders.unboxed_items(Rax))
		.concat([
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.cmp_imm(Rcx, 2),
			Emit.jcc(E, "runtime_next_item_iterator"),
			Emit.jcc(A, "runtime_not_iterable"),
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
	word_of = [Emit.mark(Runtime.word_of)]
		.concat(RuntimeBuilders.unless_number_items({ reg: Rdi, label: Runtime.not_a_number_stop }))
		.concat([
			Emit.to_xmm(Xmm0, Rdi),
			Instruction(Cvttsd2si({ to: Rax, from: Xmm0 })),
			Emit.cmp_imm(Rax, 1),
			Emit.jcc(O, "runtime_word_of_large"),
			Instruction(Movsxd({ to: Rax, from: Rax })),
			Emit.ret,
			Emit.mark("runtime_word_of_large"),
			Emit.mov(Rcx, Rdi),
			Emit.shr(Rcx, 52),
			Emit.bit_and_imm(Rcx, 0x7FF),
			Emit.cmp_imm(Rcx, 0x7FF),
			Emit.jcc(E, "runtime_word_of_zero"),
			Emit.minus_imm(Rcx, 1075),
			Emit.cmp_imm(Rcx, 32),
			Emit.jcc(Ae, "runtime_word_of_zero"),
			Emit.mov(Rdx, Rdi),
			Emit.shl(Rdx, 12),
			Emit.shr(Rdx, 12),
			Emit.imm(R8, 0x10000000000000),
			Instruction(
				Alu({
					operation: Or,
					to: Rdx,
					from: R8,
				}),
			),
			Instruction(ShiftCl({ operation: Shl, reg: Rdx })),
			Emit.test(Rdi, Rdi),
			Emit.jcc(Ns, "runtime_word_of_positive"),
			Instruction(Neg(Rdx)),
			Emit.mark("runtime_word_of_positive"),
			Instruction(Movsxd({ to: Rax, from: Rdx })),
			Emit.ret,
			Emit.mark("runtime_word_of_zero"),
			Emit.zero(Rax),
			Emit.ret,
		])
	[remainder, next_item, word_of].join()
}
