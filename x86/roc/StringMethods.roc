## This module holds the string methods: the table of every one a call
## reaches by its routine, `runtime_string_method`, which calls one on a
## receiver whose kind is found as the program runs, and the routines of
## those that stand on their own here (`trim`, `trimStart`, `trimEnd`,
## `toUpperCase`, `toLowerCase`, `substring`, `repeat`, `padStart`,
## `padEnd`, `startsWith`, `endsWith`, `replace` and `replaceAll`).
##
## **One routine a method.** Each routine takes the string in `rdi`, its
## first two arguments in `rsi` and `rdx` (`undefined` for one not given)
## and the count of arguments in `rcx`, and answers in `rax`. A call on a
## known string calls it directly (BuiltinLowering's `string_method_items`).
## A call on a `Value` calls `runtime_string_method`, which calls the same
## routine when the receiver is a string, and otherwise calls the
## receiver's own property of the method's name, as
## `runtime_collection_method` does, so an object's or a class's `trim`
## still works.
##
## Each method matches node's on ASCII, the only strings the subset has.
## Where the interpreter's own methods refuse (StringRules: `$` in a
## replacement, `replaceAll` of the empty string, a count or a length that
## isn't a whole number, `startsWith` from a place), the routine stops.
##
## The methods a string shares with an array (`indexOf`, `includes`,
## `slice`, `lastIndexOf`) are not in the table: their routines take either
## receiver, so a call on a `Value` reaches them as an array's does.
import Assembly
import Boxing
import Emit
import Heap
import ObjectTable
import Runtime
import RuntimeBuilders

StringMethods :: [].{

	## A string method's name and the label of its routine.
	Method : { name : Str, routine : Str }

	## Every string method of the table, numbered by its place in it, the
	## number `runtime_string_method` takes in `rcx`.
	methods : List(StringMethods.Method)
	methods = [
		{ name: "charAt", routine: Runtime.char_at },
		{ name: "charCodeAt", routine: Runtime.char_code_at },
		{ name: "split", routine: Runtime.split },
		{ name: "trim", routine: "runtime_string_trim" },
		{ name: "trimStart", routine: "runtime_string_trim_start" },
		{ name: "trimEnd", routine: "runtime_string_trim_end" },
		{ name: "toUpperCase", routine: "runtime_string_upper_case" },
		{ name: "toLowerCase", routine: "runtime_string_lower_case" },
		{ name: "substring", routine: "runtime_string_substring" },
		{ name: "repeat", routine: "runtime_string_repeat" },
		{ name: "padStart", routine: "runtime_string_pad_start" },
		{ name: "padEnd", routine: "runtime_string_pad_end" },
		{ name: "startsWith", routine: "runtime_string_starts_with" },
		{ name: "endsWith", routine: "runtime_string_ends_with" },
		{ name: "replace", routine: "runtime_string_replace" },
		{ name: "replaceAll", routine: "runtime_string_replace_all" },
	]

	## The names of the table's methods.
	method_names : List(Str)
	method_names = StringMethods.methods.map(|method| method.name)

	## The method named `name` and its number, or `NotAStringMethod`.
	numbered_method : Str -> Try(
		{ method : StringMethods.Method, number : U64 },
		[NotAStringMethod],
	)
	numbered_method = |name| {
		var $number = 0
		for method in StringMethods.methods {
			if method.name == name {
				return Ok({ method, number: $number })
			}
			$number = $number + 1
		}
		Err(NotAStringMethod)
	}

	## The routine that calls the method numbered `rcx` of the receiver
	## `rdi`, its name the text `rsi`, with the arguments in the array `rdx`
	## (the module's header).
	method_dispatch : Str
	method_dispatch = "runtime_string_method"

	## The routines, laid down with Runtime's.
	items : List(Assembly.Statement)
	items = [
		dispatch_items,
		trim_items,
		case_items,
		substring_items,
		repeat_items,
		pad_items,
		affix_items,
		replace_items,
	].join()

	expect StringMethods.numbered_method("charAt") == Ok({
		method: { name: "charAt", routine: Runtime.char_at },
		number: 0,
	})
	expect StringMethods.numbered_method("indexOf") == Err(NotAStringMethod)
}

## The label of the cut of a string that ArrayMethods' `slice` lays down:
## the string `r10` (unboxed) from the place `rsi`, `rdx` bytes long, a new
## string in `rax`.
cut_label : Str
cut_label = "runtime_slice_string"

## `runtime_string_method`. A string's arguments are taken out of the array
## into the routine's registers and the routine is jumped to, so it answers
## the caller itself; any other receiver has its property of the method's
## name called with the array, the receiver first, in a frame holding the
## receiver (`[rbp - 8]`) and the array (16).
dispatch_items : List(Assembly.Statement)
dispatch_items = {
	var $cases = []
	var $number = 0
	for method in StringMethods.methods {
		$cases = $cases.concat([Emit.cmp_imm(R9, $number), Emit.jcc(E, method.routine)])
		$number = $number + 1
	}
	[Emit.mark(StringMethods.method_dispatch), Emit.mov(R9, Rcx)]
		.concat(
			RuntimeBuilders.unless_string_items({
				reg: Rdi,
				label: "runtime_string_method_property",
			}),
		)
		.concat([Emit.mov(R10, Rdx)])
		.concat(RuntimeBuilders.unboxed_items(R10))
		.concat([
			Emit.load(Rcx, Emit.mem(R10, 0)),
			Emit.load(R8, Emit.mem(R10, 16)),
			Emit.imm(Rsi, Boxing.undefined_bits),
			Emit.imm(Rdx, Boxing.undefined_bits),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_string_method_given"),
			Emit.load(Rsi, Emit.mem(R8, 0)),
			Emit.cmp_imm(Rcx, 1),
			Emit.jcc(E, "runtime_string_method_given"),
			Emit.load(Rdx, Emit.mem(R8, 8)),
			Emit.mark("runtime_string_method_given"),
		])
		.concat($cases)
		.concat([
			Emit.mark("runtime_string_method_property"),
			Emit.save(Rbp),
			Emit.mov(Rbp, Rsp),
			Emit.minus_imm(Rsp, 16),
			Emit.store(RuntimeBuilders.local(8), Rdi),
			Emit.store(RuntimeBuilders.local(16), Rdx),
			# A class's method of that name first (ObjectTable's header).
			Emit.mov(Rdx, Rsi),
			Emit.call("runtime_text_hash"),
			Emit.mov(R8, Rax),
			Emit.call(ObjectTable.get_method_hashed),
			Emit.mov(Rdi, Rax),
			Emit.load(Rsi, RuntimeBuilders.local(16)),
			Emit.load(Rdx, RuntimeBuilders.local(8)),
			Emit.call(Runtime.call_spread),
			Emit.mov(Rsp, Rbp),
			Emit.restore(Rbp),
			Emit.ret,
		])
}

## The statements that jump to `label` unless the byte in `rax` is
## JavaScript's whitespace in ASCII: a space, or a tab to a carriage return
## (9 to 13). They change `rax`.
unless_space_items : Str -> List(Assembly.Statement)
unless_space_items = |label| [
	Emit.cmp_imm(Rax, 32),
	Emit.jcc(E, "${label}_space"),
	Emit.minus_imm(Rax, 9),
	Emit.cmp_imm(Rax, 5),
	Emit.jcc(Ae, label),
	Emit.mark("${label}_space"),
]

## `trim`, `trimStart` and `trimEnd`: one routine, `r8` saying which ends (1
## the start, 2 the end, 3 both). `rsi` walks in from the start and `r9` from
## the end; a string with nothing trimmed is answered as it is.
trim_items : List(Assembly.Statement)
trim_items = {
	entry = |{ label, ends }| [
		Emit.mark(label),
		Emit.imm(R8, ends),
		Emit.jmp("runtime_string_trim_ends"),
	]
	[
		entry({ label: "runtime_string_trim", ends: 3 }),
		entry({ label: "runtime_string_trim_start", ends: 1 }),
		entry({ label: "runtime_string_trim_end", ends: 2 }),
		[Emit.mark("runtime_string_trim_ends"), Emit.mov(R10, Rdi)],
		RuntimeBuilders.unboxed_items(R10),
		[
			Emit.load(R9, Emit.mem(R10, 0)),
			Emit.zero(Rsi),
			Emit.mov(Rax, R8),
			Emit.bit_and_imm(Rax, 1),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_string_trim_started"),
			Emit.mark("runtime_string_trim_start_byte"),
			Emit.cmp(Rsi, R9),
			Emit.jcc(Ae, "runtime_string_trim_started"),
			Emit.byte_load(
				Rax,
				Emit.mem_index({
					base: R10,
					index: Rsi,
					displacement: 8,
				}),
			),
		],
		unless_space_items("runtime_string_trim_started"),
		[
			Emit.plus_imm(Rsi, 1),
			Emit.jmp("runtime_string_trim_start_byte"),
			Emit.mark("runtime_string_trim_started"),
			Emit.mov(Rax, R8),
			Emit.bit_and_imm(Rax, 2),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_string_trim_ended"),
			Emit.mark("runtime_string_trim_end_byte"),
			Emit.cmp(R9, Rsi),
			Emit.jcc(Be, "runtime_string_trim_ended"),
			Emit.byte_load(
				Rax,
				Emit.mem_index({
					base: R10,
					index: R9,
					displacement: 7,
				}),
			),
		],
		unless_space_items("runtime_string_trim_ended"),
		[
			Emit.minus_imm(R9, 1),
			Emit.jmp("runtime_string_trim_end_byte"),
			Emit.mark("runtime_string_trim_ended"),
			Emit.mov(Rdx, R9),
			Emit.minus(Rdx, Rsi),
			Emit.test(Rsi, Rsi),
			Emit.jcc(Ne, cut_label),
			Emit.load(Rcx, Emit.mem(R10, 0)),
			Emit.cmp(Rdx, Rcx),
			Emit.jcc(Ne, cut_label),
			Emit.mov(Rax, Rdi),
			Emit.ret,
		],
	].join()
}

## `toUpperCase` and `toLowerCase`: one routine, `r8` the first letter of the
## case changed (`a` or `A`). Each byte is copied to a new string, a letter
## of that case with its bit 32 flipped. `r10` is the string, `r11` the new
## one, `rcx` the length and `rdx` the place.
case_items : List(Assembly.Statement)
case_items = [
	[
		Emit.mark("runtime_string_upper_case"),
		# 97 is `a`, 65 `A`.
		Emit.imm(R8, 97),
		Emit.jmp("runtime_string_case"),
		Emit.mark("runtime_string_lower_case"),
		Emit.imm(R8, 65),
		Emit.mark("runtime_string_case"),
		Emit.mov(R10, Rdi),
	],
	RuntimeBuilders.unboxed_items(R10),
	[
		Emit.load(Rdi, Emit.mem(R10, 0)),
		Emit.plus_imm(Rdi, 8),
		Emit.call(Heap.allocate(String)),
		Emit.mov(R11, Rax),
		Emit.load(Rcx, Emit.mem(R10, 0)),
		Emit.store(Emit.mem(R11, 0), Rcx),
		Emit.zero(Rdx),
		Emit.mark("runtime_string_case_byte"),
		Emit.cmp(Rdx, Rcx),
		Emit.jcc(Ae, "runtime_string_case_done"),
		Emit.byte_load(
			Rax,
			Emit.mem_index({
				base: R10,
				index: Rdx,
				displacement: 8,
			}),
		),
		Emit.mov(R9, Rax),
		Emit.minus(R9, R8),
		Emit.cmp_imm(R9, 26),
		Emit.jcc(Ae, "runtime_string_case_kept"),
		Instruction(
			AluImm({
				operation: Xor,
				to: Rax,
				value: 32,
			}),
		),
		Emit.mark("runtime_string_case_kept"),
		Emit.byte_store(
			Emit.mem_index({
				base: R11,
				index: Rdx,
				displacement: 8,
			}),
			Al,
		),
		Emit.plus_imm(Rdx, 1),
		Emit.jmp("runtime_string_case_byte"),
		Emit.mark("runtime_string_case_done"),
		Emit.mov(Rax, R11),
	],
	RuntimeBuilders.boxed_string_items,
	[Emit.ret],
].join()

## `substring`: each place `undefined` takes its default (0, the length
## `r9`), a NaN or a negative one 0 and one past the length the length; the
## two are put in order and the string cut between them.
substring_items : List(Assembly.Statement)
substring_items = {
	held = |{ reg, label, unset }|
		[
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.cmp(reg, Rax),
			Emit.jcc(Ne, "${label}_given"),
			unset,
			Emit.jmp("${label}_held"),
			Emit.mark("${label}_given"),
		]
			.concat(
				RuntimeBuilders.unless_number_items({
					reg,
					label: "runtime_string_substring_stop",
				}),
			)
			.concat([
				Emit.to_xmm(Xmm0, reg),
				Instruction(Cvtsi2sd({ to: Xmm1, from: R9 })),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
				Emit.jcc(P, "${label}_none"),
				Emit.jcc(Ae, "${label}_whole"),
				Instruction(Cvttsd2si({ to: reg, from: Xmm0 })),
				Emit.cmp_imm(reg, 0),
				Emit.jcc(Ge, "${label}_held"),
				Emit.mark("${label}_none"),
				Emit.zero(reg),
				Emit.jmp("${label}_held"),
				Emit.mark("${label}_whole"),
				Emit.mov(reg, R9),
				Emit.mark("${label}_held"),
			])
	[
		[Emit.mark("runtime_string_substring"), Emit.mov(R10, Rdi)],
		RuntimeBuilders.unboxed_items(R10),
		[Emit.load(R9, Emit.mem(R10, 0))],
		held({
			reg: Rsi,
			label: "runtime_string_substring_start",
			unset: Emit.zero(Rsi),
		}),
		held({
			reg: Rdx,
			label: "runtime_string_substring_end",
			unset: Emit.mov(Rdx, R9),
		}),
		[
			Emit.cmp(Rsi, Rdx),
			Emit.jcc(Le, "runtime_string_substring_ordered"),
			Emit.mov(Rax, Rsi),
			Emit.mov(Rsi, Rdx),
			Emit.mov(Rdx, Rax),
			Emit.mark("runtime_string_substring_ordered"),
			Emit.minus(Rdx, Rsi),
			Emit.jmp(cut_label),
			Emit.mark("runtime_string_substring_stop"),
		],
		RuntimeBuilders.stopping_items("runtime_text_substring_place"),
	].join()
}

## The most bytes a string `repeat`, `padStart` or `padEnd` makes may hold:
## 2^30, the heap's size.
most_bytes : I64
most_bytes = 0x40000000

## `repeat`: a count `r9`, whole and at least 0 (none given is 0), and the
## string `r10` copied that many times into the one string `r11` allocated.
## The empty string repeated is itself.
repeat_items : List(Assembly.Statement)
repeat_items =
	[
		[
			Emit.mark("runtime_string_repeat"),
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.cmp(Rsi, Rax),
			Emit.jcc(Ne, "runtime_string_repeat_given"),
			Emit.address_of(Rax, "runtime_text_empty"),
		],
		RuntimeBuilders.boxed_string_items,
		[Emit.ret, Emit.mark("runtime_string_repeat_given")],
		RuntimeBuilders.unless_number_items({ reg: Rsi, label: "runtime_string_repeat_stop" }),
		RuntimeBuilders.whole_number_items({
			reg: Rsi,
			to: R9,
			label: "runtime_string_repeat_stop",
		}),
		[
			Emit.cmp_imm(R9, 0),
			Emit.jcc(L, "runtime_string_repeat_stop"),
			Emit.mov(R10, Rdi),
		],
		RuntimeBuilders.unboxed_items(R10),
		[
			Emit.load(Rax, Emit.mem(R10, 0)),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_string_repeat_same"),
			Emit.cmp_imm(R9, most_bytes),
			Emit.jcc(A, "runtime_string_too_long"),
			Instruction(Imul({ to: Rax, from: R9 })),
			Emit.cmp_imm(Rax, most_bytes),
			Emit.jcc(A, "runtime_string_too_long"),
			Emit.mov(R11, Rax),
			Emit.mov(Rdi, Rax),
			Emit.plus_imm(Rdi, 8),
			Emit.call(Heap.allocate(String)),
			Emit.store(Emit.mem(Rax, 0), R11),
			Emit.mov(R11, Rax),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.mark("runtime_string_repeat_copy"),
			Emit.test(R9, R9),
			Emit.jcc(E, "runtime_string_repeat_done"),
			Emit.load(Rcx, Emit.mem(R10, 0)),
			Emit.lea(Rsi, Emit.mem(R10, 8)),
			Instruction(RepMovsb),
			Emit.minus_imm(R9, 1),
			Emit.jmp("runtime_string_repeat_copy"),
			Emit.mark("runtime_string_repeat_done"),
			Emit.mov(Rax, R11),
		],
		RuntimeBuilders.boxed_string_items,
		[
			Emit.ret,
			Emit.mark("runtime_string_repeat_same"),
			Emit.mov(Rax, Rdi),
			Emit.ret,
			Emit.mark("runtime_string_repeat_stop"),
		],
		RuntimeBuilders.stopping_items("runtime_text_repeat_count"),
		[Emit.mark("runtime_string_too_long")],
		RuntimeBuilders.stopping_items("runtime_text_string_too_long"),
	].join()

## `padStart` and `padEnd`: one routine, `r8` 0 for the start and 1 for the
## end. The length wanted `r9` is whole (none given leaves the string as it
## is), the fill `r11` a string (none given is a space); a length no longer
## than the string's, or an empty fill, answers the string. Otherwise the
## new string is allocated once, the string copied in before or after the
## pad, which is the fill's bytes over and over (`runtime_string_pad_fill`).
pad_items : List(Assembly.Statement)
pad_items =
	[
		[
			Emit.mark("runtime_string_pad_start"),
			Emit.zero(R8),
			Emit.jmp("runtime_string_pad"),
			Emit.mark("runtime_string_pad_end"),
			Emit.imm(R8, 1),
			Emit.mark("runtime_string_pad"),
			Emit.mov(R10, Rdi),
		],
		RuntimeBuilders.unboxed_items(R10),
		[
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.cmp(Rdx, Rax),
			Emit.jcc(Ne, "runtime_string_pad_fill_given"),
			Emit.address_of(R11, Runtime.text_label(Space)),
			Emit.jmp("runtime_string_pad_filled"),
			Emit.mark("runtime_string_pad_fill_given"),
		],
		RuntimeBuilders.unless_string_items({ reg: Rdx, label: "runtime_string_pad_stop" }),
		[Emit.mov(R11, Rdx)],
		RuntimeBuilders.unboxed_items(R11),
		[
			Emit.mark("runtime_string_pad_filled"),
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.cmp(Rsi, Rax),
			Emit.jcc(E, "runtime_string_pad_same"),
		],
		RuntimeBuilders.unless_number_items({ reg: Rsi, label: "runtime_string_pad_stop" }),
		RuntimeBuilders.whole_number_items({
			reg: Rsi,
			to: R9,
			label: "runtime_string_pad_stop",
		}),
		[
			Emit.load(Rax, Emit.mem(R10, 0)),
			Emit.cmp(R9, Rax),
			Emit.jcc(Le, "runtime_string_pad_same"),
			Emit.load(Rcx, Emit.mem(R11, 0)),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_string_pad_same"),
			Emit.cmp_imm(R9, most_bytes),
			Emit.jcc(G, "runtime_string_too_long"),
			Emit.mov(Rdi, R9),
			Emit.plus_imm(Rdi, 8),
			Emit.call(Heap.allocate(String)),
			Emit.store(Emit.mem(Rax, 0), R9),
			Emit.save(Rax),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.test(R8, R8),
			Emit.jcc(E, "runtime_string_pad_first"),
			Emit.load(Rcx, Emit.mem(R10, 0)),
			Emit.lea(Rsi, Emit.mem(R10, 8)),
			Instruction(RepMovsb),
			Emit.call("runtime_string_pad_fill"),
			Emit.jmp("runtime_string_padded"),
			Emit.mark("runtime_string_pad_first"),
			Emit.call("runtime_string_pad_fill"),
			Emit.load(Rcx, Emit.mem(R10, 0)),
			Emit.lea(Rsi, Emit.mem(R10, 8)),
			Instruction(RepMovsb),
			Emit.mark("runtime_string_padded"),
			Emit.restore(Rax),
		],
		RuntimeBuilders.boxed_string_items,
		[
			Emit.ret,
			Emit.mark("runtime_string_pad_same"),
			Emit.mov(Rax, Rdi),
			Emit.ret,
			# The pad, the length wanted less the string's, written at `rdi`
			# from the fill's bytes in turn (`rcx` the place in the fill, `rdx`
			# the bytes left).
			Emit.mark("runtime_string_pad_fill"),
			Emit.load(Rax, Emit.mem(R10, 0)),
			Emit.mov(Rdx, R9),
			Emit.minus(Rdx, Rax),
			Emit.zero(Rcx),
			Emit.mark("runtime_string_pad_fill_byte"),
			Emit.test(Rdx, Rdx),
			Emit.jcc(E, "runtime_string_pad_fill_done"),
			Emit.load(Rsi, Emit.mem(R11, 0)),
			Emit.cmp(Rcx, Rsi),
			Emit.jcc(B, "runtime_string_pad_fill_held"),
			Emit.zero(Rcx),
			Emit.mark("runtime_string_pad_fill_held"),
			Emit.byte_load(
				Rax,
				Emit.mem_index({
					base: R11,
					index: Rcx,
					displacement: 8,
				}),
			),
			Emit.byte_store(Emit.mem(Rdi, 0), Al),
			Emit.plus_imm(Rdi, 1),
			Emit.plus_imm(Rcx, 1),
			Emit.minus_imm(Rdx, 1),
			Emit.jmp("runtime_string_pad_fill_byte"),
			Emit.mark("runtime_string_pad_fill_done"),
			Emit.ret,
			Emit.mark("runtime_string_pad_stop"),
		],
		RuntimeBuilders.stopping_items("runtime_text_pad"),
	].join()

## `startsWith` and `endsWith`: one routine, `r8` 0 for the start and 1 for
## the end. The string sought `r11` is compared byte by byte with the
## string `r10` at the place `rdx`, its start or its end less the length
## sought `rcx`.
affix_items : List(Assembly.Statement)
affix_items =
	[
		[
			Emit.mark("runtime_string_starts_with"),
			Emit.zero(R8),
			Emit.jmp("runtime_string_affix"),
			Emit.mark("runtime_string_ends_with"),
			Emit.imm(R8, 1),
			Emit.mark("runtime_string_affix"),
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.cmp(Rdx, Rax),
			Emit.jcc(Ne, "runtime_string_affix_stop"),
		],
		RuntimeBuilders.unless_string_items({ reg: Rsi, label: "runtime_string_affix_stop" }),
		[Emit.mov(R10, Rdi), Emit.mov(R11, Rsi)],
		RuntimeBuilders.unboxed_items(R10),
		RuntimeBuilders.unboxed_items(R11),
		[
			Emit.load(Rcx, Emit.mem(R11, 0)),
			Emit.load(R9, Emit.mem(R10, 0)),
			Emit.cmp(Rcx, R9),
			Emit.jcc(A, "runtime_string_affix_no"),
			Emit.zero(Rdx),
			Emit.test(R8, R8),
			Emit.jcc(E, "runtime_string_affix_placed"),
			Emit.mov(Rdx, R9),
			Emit.minus(Rdx, Rcx),
			Emit.mark("runtime_string_affix_placed"),
			Emit.zero(Rsi),
			Emit.mark("runtime_string_affix_byte"),
			Emit.cmp(Rsi, Rcx),
			Emit.jcc(Ae, "runtime_string_affix_yes"),
			Emit.byte_load(
				Rax,
				Emit.mem_index({
					base: R11,
					index: Rsi,
					displacement: 8,
				}),
			),
			Emit.mov(R9, Rdx),
			Emit.plus(R9, Rsi),
			Emit.byte_load(
				R9,
				Emit.mem_index({
					base: R10,
					index: R9,
					displacement: 8,
				}),
			),
			Emit.cmp(Rax, R9),
			Emit.jcc(Ne, "runtime_string_affix_no"),
			Emit.plus_imm(Rsi, 1),
			Emit.jmp("runtime_string_affix_byte"),
			Emit.mark("runtime_string_affix_yes"),
			Emit.imm(Rax, Boxing.true_bits),
			Emit.ret,
			Emit.mark("runtime_string_affix_no"),
			Emit.imm(Rax, Boxing.false_bits),
			Emit.ret,
			Emit.mark("runtime_string_affix_stop"),
		],
		RuntimeBuilders.stopping_items("runtime_text_affix"),
	].join()

## `replace` and `replaceAll` of a string by a string with no `$` (node reads
## `$&` and its kin as patterns). `replaceAll` is `split` at the string
## sought, then `join` with the replacement. `replace` finds the first place
## (`runtime_index_of`) and copies the three pieces into one new string:
## `r10` the string, `r11` the string sought, `rdx` the replacement, `r9` the
## place and `r8` the new string.
replace_items : List(Assembly.Statement)
replace_items = {
	checked = |label|
		RuntimeBuilders.unless_string_items({ reg: Rsi, label: "runtime_string_replace_stop" })
			.concat(
				RuntimeBuilders.unless_string_items({
					reg: Rdx,
					label: "runtime_string_replace_stop",
				}),
			)
			.concat([Emit.call("runtime_string_unpatterned"), Emit.mark(label)])
	[
		[Emit.mark("runtime_string_replace_all")],
		checked("runtime_string_replace_all_checked"),
		[Emit.mov(Rax, Rsi)],
		RuntimeBuilders.unboxed_items(Rax),
		[
			Emit.load(Rax, Emit.mem(Rax, 0)),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_string_replace_stop"),
			Emit.save(Rdx),
			Emit.imm(Rcx, 1),
			Emit.call(Runtime.split),
			Emit.mov(Rdi, Rax),
			Emit.restore(Rsi),
		],
		RuntimeBuilders.unboxed_items(Rsi),
		[Emit.jmp(Runtime.join), Emit.mark("runtime_string_replace")],
		checked("runtime_string_replace_checked"),
		[
			Emit.save(Rdi),
			Emit.save(Rsi),
			Emit.save(Rdx),
			Emit.imm(Rcx, 1),
			Emit.zero(R8),
			Emit.call(Runtime.index_of),
			Emit.to_xmm(Xmm0, Rax),
			Instruction(Cvttsd2si({ to: R9, from: Xmm0 })),
			Emit.restore(Rdx),
			Emit.restore(Rsi),
			Emit.restore(Rdi),
			Emit.cmp_imm(R9, 0),
			Emit.jcc(L, "runtime_string_replace_same"),
			Emit.mov(R10, Rdi),
			Emit.mov(R11, Rsi),
		],
		RuntimeBuilders.unboxed_items(R10),
		RuntimeBuilders.unboxed_items(R11),
		RuntimeBuilders.unboxed_items(Rdx),
		[
			Emit.load(Rcx, Emit.mem(R10, 0)),
			Emit.load(Rax, Emit.mem(R11, 0)),
			Emit.minus(Rcx, Rax),
			Emit.load(Rax, Emit.mem(Rdx, 0)),
			Emit.plus(Rcx, Rax),
			Emit.save(Rcx),
			Emit.mov(Rdi, Rcx),
			Emit.plus_imm(Rdi, 8),
			Emit.call(Heap.allocate(String)),
			Emit.restore(Rcx),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			Emit.mov(R8, Rax),
			Emit.lea(Rdi, Emit.mem(Rax, 8)),
			Emit.mov(Rcx, R9),
			Emit.lea(Rsi, Emit.mem(R10, 8)),
			Instruction(RepMovsb),
			Emit.load(Rcx, Emit.mem(Rdx, 0)),
			Emit.lea(Rsi, Emit.mem(Rdx, 8)),
			Instruction(RepMovsb),
			Emit.load(Rax, Emit.mem(R11, 0)),
			Emit.plus(Rax, R9),
			Emit.load(Rcx, Emit.mem(R10, 0)),
			Emit.minus(Rcx, Rax),
			Emit.lea(
				Rsi,
				Emit.mem_index({
					base: R10,
					index: Rax,
					displacement: 8,
				}),
			),
			Instruction(RepMovsb),
			Emit.mov(Rax, R8),
		],
		RuntimeBuilders.boxed_string_items,
		[
			Emit.ret,
			Emit.mark("runtime_string_replace_same"),
			Emit.mov(Rax, Rdi),
			Emit.ret,
			# A replacement in `rdx` holding `$` stops; `rdi`, `rsi` and `rdx`
			# are kept.
			Emit.mark("runtime_string_unpatterned"),
			Emit.mov(R9, Rdx),
		],
		RuntimeBuilders.unboxed_items(R9),
		[
			Emit.load(Rcx, Emit.mem(R9, 0)),
			Emit.zero(R8),
			Emit.mark("runtime_string_unpatterned_byte"),
			Emit.cmp(R8, Rcx),
			Emit.jcc(Ae, "runtime_string_unpatterned_done"),
			RuntimeBuilders.text_byte_item({ reg: Rax, base: R9 }),
			# 36 is `$`.
			Emit.cmp_imm(Rax, 36),
			Emit.jcc(E, "runtime_string_replace_stop"),
			Emit.plus_imm(R8, 1),
			Emit.jmp("runtime_string_unpatterned_byte"),
			Emit.mark("runtime_string_unpatterned_done"),
			Emit.ret,
			Emit.mark("runtime_string_replace_stop"),
		],
		RuntimeBuilders.stopping_items("runtime_text_replace"),
	].join()
}
