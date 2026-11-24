## This module holds the machine code every compiled program carries beside
## its own: `console.log`'s writing of a number, and the texts it writes.
## Each piece is a list of `Assembly` statements under labels that start
## `runtime_`, which no function of the program's takes, so the program's
## code calls them by name.
##
## A number is written as node writes it when it is an integer of at most
## 2^53 in size, or NaN, an infinity or -0. Any other number (a fraction, or
## an integer too large for every one of them to be held exactly) is not
## written yet: the program writes a line saying so to stderr and exits 1, so
## its output can never be mistaken for node's.
import Assembly

Runtime :: [].{

	## The label of the routine that writes the number whose bits are in
	## `rax` to stdout. It may change every general register but `rbp` and
	## `rsp`, and `xmm0` and `xmm1`.
	print_number : Str
	print_number = "runtime_print_number"

	## The texts the runtime writes, each under its label: those
	## `console.log` writes besides numbers, the special numbers', and the
	## line that says a number is not written yet.
	Text : [
		True,
		False,
		Undefined,
		Space,
		Newline,
		Infinity,
		NegativeInfinity,
		NotANumber,
		NegativeZero,
		NotWritten,
	]

	## The statements that write one of the texts to stdout.
	text_items : Runtime.Text -> List(Assembly.Statement)
	text_items = |text| {
		{ label, bytes } = text_of(text)
		written_items({ descriptor: 1, label, size: bytes.len() })
	}

	## The routine at `print_number`, then every text under its label.
	items : List(Assembly.Statement)
	items = number_items.concat(text_statements)
}

digit_zero : U8
digit_zero = '0'

minus_sign : U8
minus_sign = '-'

## The bytes of the texts, each after its label.
text_statements : List(Assembly.Statement)
text_statements = {
	var $out = []
	for text in [
		True,
		False,
		Undefined,
		Space,
		Newline,
		Infinity,
		NegativeInfinity,
		NotANumber,
		NegativeZero,
		NotWritten,
	] {
		{ label, bytes } = text_of(text)
		$out = $out.concat([Mark(label), Data(bytes)])
	}
	$out
}

text_of : Runtime.Text -> { label : Str, bytes : List(U8) }
text_of = |text|
	match text {
		True => { label: "runtime_true", bytes: "true".to_utf8() }
		False => { label: "runtime_false", bytes: "false".to_utf8() }
		Undefined => { label: "runtime_undefined", bytes: "undefined".to_utf8() }
		Space => { label: "runtime_space", bytes: " ".to_utf8() }
		Newline => { label: "runtime_newline", bytes: "\n".to_utf8() }
		Infinity => { label: "runtime_infinity", bytes: "Infinity".to_utf8() }
		NegativeInfinity => { label: "runtime_negative_infinity", bytes: "-Infinity".to_utf8() }
		NotANumber => { label: "runtime_not_a_number", bytes: "NaN".to_utf8() }
		NegativeZero => { label: "runtime_negative_zero", bytes: "-0".to_utf8() }
		NotWritten => {
			label: "runtime_not_written",
			bytes: Str.concat(
				"x86: console.log of a number that is not an integer",
				" of at most 2^53 is not compiled yet\n",
			).to_utf8(),
		}
	}

## Linux's `write` of `size` bytes at `label` to a file descriptor.
written_items : {
	descriptor : I64,
	label : Str,
	size : U64,
} -> List(Assembly.Statement)
written_items = |{ descriptor, label, size }| [
	Instruction(MovRegImm({ to: Rax, value: 1 })),
	Instruction(MovRegImm({ to: Rdi, value: descriptor })),
	LeaTo({ to: Rsi, label }),
	Instruction(MovRegImm({ to: Rdx, value: size.to_i64_wrap() })),
	Instruction(Syscall),
]

## A text written to stdout, then a return.
special_items : Runtime.Text -> List(Assembly.Statement)
special_items = |text| {
	{ label, bytes } = text_of(text)
	[Mark("${label}_case")]
		.concat(written_items({ descriptor: 1, label, size: bytes.len() }))
		.append(Instruction(Ret))
}

## The bits of the number in `rax` compared with `bits`, and a jump to
## `label` when they are the same.
bits_case_items : { bits : U64, label : Str } -> List(Assembly.Statement)
bits_case_items = |{ bits, label }| [
	Instruction(MovRegImm({ to: Rcx, value: bits.to_i64_wrap() })),
	Instruction(
		Alu({
			operation: Cmp,
			to: Rax,
			from: Rcx,
		}),
	),
	JccTo({ condition: E, label }),
]

## The routine at `Runtime.print_number`. The special numbers are told by
## their bits; any other number is converted to an integer and back, and is
## written only when that gives it back exactly and its size is at most
## 2^53. Its digits are written from the last, by division by ten, into 32
## bytes of the stack, then written with one system call.
number_items : List(Assembly.Statement)
number_items = {
	buffer_end = Based({
		base: Rsp,
		index: NoIndex,
		displacement: 32,
	})
	written_at_rsi = Based({
		base: Rsi,
		index: NoIndex,
		displacement: 0,
	})
	not_written = text_of(NotWritten)
	[Mark(Runtime.print_number)]
		.concat(bits_case_items({ bits: 0x7FF0000000000000, label: "runtime_infinity_case" }))
		.concat(
			bits_case_items({ bits: 0xFFF0000000000000, label: "runtime_negative_infinity_case" }),
		)
		.concat(bits_case_items({ bits: 0x8000000000000000, label: "runtime_negative_zero_case" }))
		.concat([
			Instruction(MovqToXmm({ to: Xmm0, from: Rax })),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm0 })),
			JccTo({ condition: P, label: "runtime_not_a_number_case" }),
			Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
			Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			JccTo({ condition: Ne, label: "runtime_not_written_case" }),
			# r9 is 1 for a negative number, whose size goes on in rcx.
			Instruction(
				Alu({
					operation: Xor,
					to: R9,
					from: R9,
				}),
			),
			Instruction(Test({ left: Rcx, right: Rcx })),
			JccTo({ condition: Ns, label: "runtime_number_size" }),
			Instruction(MovRegImm({ to: R9, value: 1 })),
			Instruction(Neg(Rcx)),
			Mark("runtime_number_size"),
			Instruction(MovRegImm({ to: Rdx, value: 9007199254740992 })),
			Instruction(
				Alu({
					operation: Cmp,
					to: Rcx,
					from: Rdx,
				}),
			),
			JccTo({ condition: A, label: "runtime_not_written_case" }),
			Instruction(
				AluImm({
					operation: Sub,
					to: Rsp,
					value: 32,
				}),
			),
			Instruction(Lea({ to: Rsi, from: buffer_end })),
			Instruction(MovRegImm({ to: R8, value: 10 })),
			Mark("runtime_number_digit"),
			Instruction(
				Alu({
					operation: Xor,
					to: Rdx,
					from: Rdx,
				}),
			),
			Instruction(MovRegReg({ to: Rax, from: Rcx })),
			Instruction(Div(R8)),
			Instruction(
				AluImm({
					operation: Add,
					to: Rdx,
					value: digit_zero.to_i32(),
				}),
			),
			Instruction(
				AluImm({
					operation: Sub,
					to: Rsi,
					value: 1,
				}),
			),
			Instruction(MovByteStore({ to: written_at_rsi, from: Dl })),
			Instruction(MovRegReg({ to: Rcx, from: Rax })),
			Instruction(Test({ left: Rcx, right: Rcx })),
			JccTo({ condition: Ne, label: "runtime_number_digit" }),
			Instruction(Test({ left: R9, right: R9 })),
			JccTo({ condition: E, label: "runtime_number_write" }),
			Instruction(
				AluImm({
					operation: Sub,
					to: Rsi,
					value: 1,
				}),
			),
			Instruction(MovRegImm({ to: Rdx, value: minus_sign.to_i64() })),
			Instruction(MovByteStore({ to: written_at_rsi, from: Dl })),
			Mark("runtime_number_write"),
			Instruction(Lea({ to: Rdx, from: buffer_end })),
			Instruction(
				Alu({
					operation: Sub,
					to: Rdx,
					from: Rsi,
				}),
			),
			Instruction(MovRegImm({ to: Rax, value: 1 })),
			Instruction(MovRegImm({ to: Rdi, value: 1 })),
			Instruction(Syscall),
			Instruction(
				AluImm({
					operation: Add,
					to: Rsp,
					value: 32,
				}),
			),
			Instruction(Ret),
		])
		.concat(special_items(Infinity))
		.concat(special_items(NegativeInfinity))
		.concat(special_items(NotANumber))
		.concat(special_items(NegativeZero))
		.concat([Mark("runtime_not_written_case")])
		.concat(
			written_items({
				descriptor: 2,
				label: not_written.label,
				size: not_written.bytes.len(),
			}),
		)
		.concat([
			Instruction(MovRegImm({ to: Rax, value: 231 })),
			Instruction(MovRegImm({ to: Rdi, value: 1 })),
			Instruction(Syscall),
		])
}
