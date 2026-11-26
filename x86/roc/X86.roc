## This module encodes x86-64 instructions as machine code. An instruction is
## a value of `Instruction`, and `X86.append_instruction` appends its bytes to a
## list: any mandatory prefix, the REX prefix, the opcode, the ModRM byte, a
## SIB byte and a displacement where the operand is in memory, then any
## immediate.
##
## Registers are named, never numbered, so no instruction can name a
## register that doesn't exist. A general register operand is 64 bits wide
## (REX.W), but for `Div32`'s, and an SSE2 operand is the low double of an xmm
## register.
##
## A jump or a call takes its offset as a rel32 already worked out, relative
## to the end of the instruction, and so does a memory operand at `Rip`: the
## rel32 is always the instruction's last four bytes, which is what lets
## `Assembly` write a placeholder and patch it once the target is known.
X86 :: [].{
	Register := [Rax, Rcx, Rdx, Rbx, Rsp, Rbp, Rsi, Rdi, R8, R9, R10, R11, R12, R13, R14, R15]

	Xmm := [
		Xmm0,
		Xmm1,
		Xmm2,
		Xmm3,
		Xmm4,
		Xmm5,
		Xmm6,
		Xmm7,
		Xmm8,
		Xmm9,
		Xmm10,
		Xmm11,
		Xmm12,
		Xmm13,
		Xmm14,
		Xmm15,
	]

	## The low byte of the first four general registers, as `setcc`, `movzx`
	## and a byte store name it. These four need no REX prefix, so a byte
	## operand never reads as `spl` or `sil`.
	ByteRegister := [Al, Cl, Dl, Bl]

	## A memory operand: a base register plus a scaled index plus a
	## displacement, or a displacement from the end of the instruction
	## (`Rip`).
	Mem : [
		Based(
			{
				base : X86.Register,
				index : X86.Index,
				displacement : I32,
			},
		),
		Rip(I32),
	]

	## The index register of a memory operand, scaled by 1, 2, 4 or 8. `Rsp`
	## can't be an index: its encoding means "no index".
	Index : [NoIndex, Scaled({ reg : X86.Register, scale : [Times1, Times2, Times4, Times8] })]

	## The integer operations that take two registers, or a register and an
	## immediate, and set the flags.
	AluOperation := [Add, Or, And, Sub, Xor, Cmp]

	ShiftOperation := [Shl, Shr, Sar]

	## The doubles' arithmetic, `to` the first operand and the answer;
	## `Sqrtsd` is the square root of `from` alone.
	SseOperation := [Addsd, Subsd, Mulsd, Divsd, Sqrtsd]

	## A jump's condition, as the flags read after a `Cmp`: `L`, `Le`, `G`,
	## `Ge` for signed integers; `B`, `Be`, `A`, `Ae` for unsigned ones and
	## after a `Ucomisd`, which also sets `P` when either double is a NaN.
	Condition := [O, No, B, Ae, E, Ne, Be, A, S, Ns, P, Np, L, Ge, Le, G]

	Instruction := [
		MovRegReg({ to : X86.Register, from : X86.Register }),
		# Seven bytes when the value fits a sign-extended I32, else movabs's ten.
		MovRegImm({ to : X86.Register, value : I64 }),
		MovRegMem({ to : X86.Register, from : X86.Mem }),
		MovMemReg({ to : X86.Mem, from : X86.Register }),
		Lea({ to : X86.Register, from : X86.Mem }),
		Alu(
			{
				operation : X86.AluOperation,
				to : X86.Register,
				from : X86.Register,
			},
		),
		AluImm(
			{
				operation : X86.AluOperation,
				to : X86.Register,
				value : I32,
			},
		),
		Imul({ to : X86.Register, from : X86.Register }),
		# rax times the register, signed, the whole 128-bit product in
		# rdx:rax (`imul r64`): its high half in rdx.
		ImulWide(X86.Register),
		# rdx:rax divided by the register, unsigned: the quotient in rax, the
		# remainder in rdx.
		Div(X86.Register),
		# rdx:rax divided by the register, signed: the quotient in rax, the
		# remainder, with the dividend's sign, in rdx.
		Idiv(X86.Register),
		# edx:eax divided by the register's low 32 bits, unsigned (`div r32`):
		# the quotient in eax, the remainder in edx, each zero-extended into
		# rax and rdx, as every write of a 32-bit register is. On Skylake it
		# takes about 4 ns, against about 10 for `div r64` and `idiv r64`.
		Div32(X86.Register),
		# rax's sign copied through rdx, for a signed divide.
		Cqo,
		Neg(X86.Register),
		# The byte register set to 1 when the condition holds, else to 0.
		Setcc({ condition : X86.Condition, to : X86.ByteRegister }),
		# The byte register's value, zero-extended to 64 bits.
		MovzxByte({ to : X86.Register, from : X86.ByteRegister }),
		MovByteStore({ to : X86.Mem, from : X86.ByteRegister }),
		# A byte of memory, zero-extended to 64 bits (`movzx r64, byte`).
		MovzxByteLoad({ to : X86.Register, from : X86.Mem }),
		# `rcx` bytes copied from `[rsi]` to `[rdi]`, both moved past them.
		RepMovsb,
		Test({ left : X86.Register, right : X86.Register }),
		Shift(
			{
				operation : X86.ShiftOperation,
				reg : X86.Register,
				count : U8,
			},
		),
		Push(X86.Register),
		Pop(X86.Register),
		Jmp(I32),
		Jcc({ condition : X86.Condition, offset : I32 }),
		Call(I32),
		# A call of the address the register holds (`call r64`).
		CallReg(X86.Register),
		Ret,
		Syscall,
		MovsdRegReg({ to : X86.Xmm, from : X86.Xmm }),
		# `from` copied to `to` when the condition holds (`cmovcc`), else `to`
		# kept: a choice of two values with no jump.
		Cmov(
			{
				condition : X86.Condition,
				to : X86.Register,
				from : X86.Register,
			},
		),
		MovsdLoad({ to : X86.Xmm, from : X86.Mem }),
		MovsdStore({ to : X86.Mem, from : X86.Xmm }),
		Sse(
			{
				operation : X86.SseOperation,
				to : X86.Xmm,
				from : X86.Xmm,
			},
		),
		Ucomisd({ left : X86.Xmm, right : X86.Xmm }),
		Cvtsi2sd({ to : X86.Xmm, from : X86.Register }),
		Cvttsd2si({ to : X86.Register, from : X86.Xmm }),
		MovqToXmm({ to : X86.Xmm, from : X86.Register }),
		MovqFromXmm({ to : X86.Register, from : X86.Xmm }),
	]

	## The bytes of `instruction` appended to `out`.
	append_instruction : List(U8), X86.Instruction -> List(U8)
	append_instruction = |out, instruction|
		match instruction {
			MovRegReg({ to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x89],
					reg: register_number(from),
					operand: Direct(register_number(to)),
				}),
			)
			MovRegImm({ to, value }) =>
				if value >= -2147483648 and value <= 2147483647 {
					append_encoded(
						out,
						{ ..integer_layout({
							opcode: [0xC7],
							reg: 0,
							operand: Direct(register_number(to)),
						}), immediate: Imm32(value) },
					)
				} else {
					number = register_number(to)
					X86.append_little_endian(
						out.concat([
							rex({
								wide: Wide,
								reg: 0,
								index: 0,
								base: number,
							}),
							0xB8 + number.bitwise_and(7),
						]),
						{ value, size: 8 },
					)
				}
			MovRegMem({ to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x8B],
					reg: register_number(to),
					operand: Memory(from),
				}),
			)
			MovMemReg({ to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x89],
					reg: register_number(from),
					operand: Memory(to),
				}),
			)
			Lea({ to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x8D],
					reg: register_number(to),
					operand: Memory(from),
				}),
			)
			Alu({ operation, to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [alu_digit(operation) * 8 + 1],
					reg: register_number(from),
					operand: Direct(register_number(to)),
				}),
			)
			AluImm({ operation, to, value }) => {
				wide = value.to_i64()
				if wide >= -128 and wide <= 127 {
					append_encoded(
						out,
						{ ..integer_layout({
							opcode: [0x83],
							reg: alu_digit(operation),
							operand: Direct(register_number(to)),
						}), immediate: Imm8(wide) },
					)
				} else {
					append_encoded(
						out,
						{ ..integer_layout({
							opcode: [0x81],
							reg: alu_digit(operation),
							operand: Direct(register_number(to)),
						}), immediate: Imm32(wide) },
					)
				}
			}
			Imul({ to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x0F, 0xAF],
					reg: register_number(to),
					operand: Direct(register_number(from)),
				}),
			)
			Div(reg) => append_encoded(
				out,
				integer_layout({
					opcode: [0xF7],
					reg: 6,
					operand: Direct(register_number(reg)),
				}),
			)
			ImulWide(reg) => append_encoded(
				out,
				integer_layout({
					opcode: [0xF7],
					reg: 5,
					operand: Direct(register_number(reg)),
				}),
			)
			Idiv(reg) => append_encoded(
				out,
				integer_layout({
					opcode: [0xF7],
					reg: 7,
					operand: Direct(register_number(reg)),
				}),
			)
			Div32(reg) => append_encoded(
				out,
				{ ..integer_layout({
					opcode: [0xF7],
					reg: 6,
					operand: Direct(register_number(reg)),
				}), wide: Narrow },
			)
			Cqo => out.concat([0x48, 0x99])
			Neg(reg) => append_encoded(
				out,
				integer_layout({
					opcode: [0xF7],
					reg: 3,
					operand: Direct(register_number(reg)),
				}),
			)
			Setcc({ condition, to }) => append_encoded(
				out,
				byte_layout({
					opcode: [0x0F, 0x90 + condition_code(condition)],
					reg: 0,
					operand: Direct(byte_register_number(to)),
				}),
			)
			MovzxByte({ to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x0F, 0xB6],
					reg: register_number(to),
					operand: Direct(byte_register_number(from)),
				}),
			)
			MovByteStore({ to, from }) => append_encoded(
				out,
				byte_layout({
					opcode: [0x88],
					reg: byte_register_number(from),
					operand: Memory(to),
				}),
			)
			MovzxByteLoad({ to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x0F, 0xB6],
					reg: register_number(to),
					operand: Memory(from),
				}),
			)
			RepMovsb => out.concat([0xF3, 0xA4])
			Test({ left, right }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x85],
					reg: register_number(right),
					operand: Direct(register_number(left)),
				}),
			)
			Shift({ operation, reg, count }) => {
				digit = match operation {
					Shl => 4
					Shr => 5
					Sar => 7
				}
				append_encoded(
					out,
					{ ..integer_layout({
						opcode: [0xC1],
						reg: digit,
						operand: Direct(register_number(reg)),
					}), immediate: Imm8(count.to_i64()) },
				)
			}
			Push(reg) => append_short(out, { opcode: 0x50, reg })
			Pop(reg) => append_short(out, { opcode: 0x58, reg })
			Jmp(offset) => X86.append_little_endian(
				out.append(0xE9),
				{ value: offset.to_i64(), size: 4 },
			)
			Jcc({ condition, offset }) => X86.append_little_endian(
				out.concat([0x0F, 0x80 + condition_code(condition)]),
				{ value: offset.to_i64(), size: 4 },
			)
			Call(offset) => X86.append_little_endian(
				out.append(0xE8),
				{ value: offset.to_i64(), size: 4 },
			)
			CallReg(reg) => append_encoded(
				out,
				{ ..integer_layout({
					opcode: [0xFF],
					reg: 2,
					operand: Direct(register_number(reg)),
				}), wide: Narrow },
			)
			Ret => out.append(0xC3)
			Syscall => out.concat([0x0F, 0x05])
			MovsdRegReg({ to, from }) => append_encoded(
				out,
				double_layout({
					prefix: [0xF2],
					opcode: [0x0F, 0x10],
					reg: xmm_number(to),
					operand: Direct(xmm_number(from)),
				}),
			)
			Cmov({ condition, to, from }) => append_encoded(
				out,
				integer_layout({
					opcode: [0x0F, 0x40 + condition_code(condition)],
					reg: register_number(to),
					operand: Direct(register_number(from)),
				}),
			)
			MovsdLoad({ to, from }) => append_encoded(
				out,
				double_layout({
					prefix: [0xF2],
					opcode: [0x0F, 0x10],
					reg: xmm_number(to),
					operand: Memory(from),
				}),
			)
			MovsdStore({ to, from }) => append_encoded(
				out,
				double_layout({
					prefix: [0xF2],
					opcode: [0x0F, 0x11],
					reg: xmm_number(from),
					operand: Memory(to),
				}),
			)
			Sse({ operation, to, from }) => {
				opcode = match operation {
					Sqrtsd => 0x51
					Addsd => 0x58
					Mulsd => 0x59
					Subsd => 0x5C
					Divsd => 0x5E
				}
				append_encoded(
					out,
					double_layout({
						prefix: [0xF2],
						opcode: [0x0F, opcode],
						reg: xmm_number(to),
						operand: Direct(xmm_number(from)),
					}),
				)
			}
			Ucomisd({ left, right }) => append_encoded(
				out,
				double_layout({
					prefix: [0x66],
					opcode: [0x0F, 0x2E],
					reg: xmm_number(left),
					operand: Direct(xmm_number(right)),
				}),
			)
			Cvtsi2sd({ to, from }) => append_encoded(
				out,
				crossing_layout({
					prefix: [0xF2],
					opcode: [0x0F, 0x2A],
					reg: xmm_number(to),
					operand: Direct(register_number(from)),
				}),
			)
			Cvttsd2si({ to, from }) => append_encoded(
				out,
				crossing_layout({
					prefix: [0xF2],
					opcode: [0x0F, 0x2C],
					reg: register_number(to),
					operand: Direct(xmm_number(from)),
				}),
			)
			MovqToXmm({ to, from }) => append_encoded(
				out,
				crossing_layout({
					prefix: [0x66],
					opcode: [0x0F, 0x6E],
					reg: xmm_number(to),
					operand: Direct(register_number(from)),
				}),
			)
			MovqFromXmm({ to, from }) => append_encoded(
				out,
				crossing_layout({
					prefix: [0x66],
					opcode: [0x0F, 0x7E],
					reg: xmm_number(from),
					operand: Direct(register_number(to)),
				}),
			)
		}

	## A general register's number, 0 to 15, as its encodings name it: two
	## registers are the same when their numbers are.
	register_index : X86.Register -> U8
	register_index = |reg| register_number(reg)

	## An xmm register's number, 0 to 15, as its encodings name it.
	xmm_index : X86.Xmm -> U8
	xmm_index = |xmm| xmm_number(xmm)

	## The bytes of one instruction alone.
	instruction_bytes : X86.Instruction -> List(U8)
	instruction_bytes = |instruction| X86.append_instruction([], instruction)

	## Bytes as hex, two lowercase digits a byte and a space between bytes,
	## as objdump prints an instruction.
	hex_text : List(U8) -> Str
	hex_text = |bytes| {
		digits = "0123456789abcdef".to_utf8()
		var $out = []
		for byte in bytes {
			if !$out.is_empty() {
				$out = $out.append(' ')
			}
			high = digits.get(byte.div_trunc_by(16).to_u64()) ?? crash "X86.hex_text: a nibble < 16"
			low = digits.get(byte.rem_by(16).to_u64()) ?? crash "X86.hex_text: a nibble < 16"
			$out = $out.append(high).append(low)
		}
		Str.from_utf8($out) ?? crash "X86.hex_text: hex digits are ASCII"
	}

	## `value`'s low `size` bytes appended to `out`, least significant first,
	## as x86-64 stores every number. A negative value is its two's
	## complement.
	append_little_endian : List(U8), { value : I64, size : U64 } -> List(U8)
	append_little_endian = |out, { value, size }| {
		var $bits = value.to_u64_wrap()
		var $bytes = out
		for _ in 0..<size {
			$bytes = $bytes.append($bits.rem_by(256).to_u8_wrap())
			$bits = $bits.div_trunc_by(256)
		}
		$bytes
	}

	# Each instruction's bytes in hex, held to the encoding the Intel manual
	# gives and objdump reads back (x86/README.md says how).
	expect hex_of(MovRegReg({ to: Rax, from: Rbx })) == "48 89 d8"
	expect hex_of(MovRegReg({ to: R8, from: Rax })) == "49 89 c0"
	expect hex_of(MovRegReg({ to: Rax, from: R9 })) == "4c 89 c8"
	expect hex_of(MovRegImm({ to: Rax, value: 1 })) == "48 c7 c0 01 00 00 00"
	expect hex_of(MovRegImm({ to: R15, value: -1 })) == "49 c7 c7 ff ff ff ff"
	expect hex_of(MovRegImm({ to: Rax, value: 2147483647 })) == "48 c7 c0 ff ff ff 7f"
	expect hex_of(MovRegImm({ to: Rax, value: 2147483648 })) == "48 b8 00 00 00 80 00 00 00 00"
	expect hex_of(MovRegImm({ to: Rax, value: -2147483648 })) == "48 c7 c0 00 00 00 80"
	expect hex_of(MovRegImm({ to: Rax, value: -2147483649 })) == "48 b8 ff ff ff 7f ff ff ff ff"
	expect hex_of(MovRegImm({ to: R10, value: 0x123456789 })) == "49 ba 89 67 45 23 01 00 00 00"
	expect hex_of(MovRegMem({ to: Rax, from: at_base(Rbx, 0) })) == "48 8b 03"
	expect hex_of(MovRegMem({ to: Rax, from: at_base(Rsp, 0) })) == "48 8b 04 24"
	expect hex_of(MovRegMem({ to: Rax, from: at_base(Rbp, 0) })) == "48 8b 45 00"
	expect hex_of(MovRegMem({ to: Rax, from: at_base(R13, 0) })) == "49 8b 45 00"
	expect hex_of(MovRegMem({ to: Rax, from: at_base(R12, 8) })) == "49 8b 44 24 08"
	expect hex_of(MovRegMem({ to: Rcx, from: at_base(Rbx, 127) })) == "48 8b 4b 7f"
	expect hex_of(MovRegMem({ to: Rcx, from: at_base(Rbx, 128) })) == "48 8b 8b 80 00 00 00"
	expect hex_of(MovRegMem({ to: Rcx, from: at_base(Rbx, -128) })) == "48 8b 4b 80"
	expect hex_of(MovRegMem({ to: Rcx, from: at_base(Rbx, -129) })) == "48 8b 8b 7f ff ff ff"
	expect hex_of(
		MovRegMem({
			to: Rax,
			from: at_index({
				base: Rbx,
				index: Rcx,
				scale: Times8,
				displacement: 16,
			}),
		}),
	) == "48 8b 44 cb 10"
	expect hex_of(
		MovRegMem({
			to: Rax,
			from: at_index({
				base: Rbx,
				index: R9,
				scale: Times4,
				displacement: 0,
			}),
		}),
	) == "4a 8b 04 8b"
	expect hex_of(MovRegMem({ to: Rax, from: Rip(-7) })) == "48 8b 05 f9 ff ff ff"
	expect hex_of(MovMemReg({ to: at_base(Rdi, -8), from: Rsi })) == "48 89 77 f8"
	expect hex_of(
		MovMemReg({
			to: at_index({
				base: R14,
				index: Rax,
				scale: Times1,
				displacement: 0,
			}),
			from: R11,
		}),
	) == "4d 89 1c 06"
	expect hex_of(Lea({ to: Rsi, from: Rip(16) })) == "48 8d 35 10 00 00 00"
	expect hex_of(
		Lea({
			to: R8,
			from: at_index({
				base: Rsp,
				index: R12,
				scale: Times2,
				displacement: 0,
			}),
		}),
	) == "4e 8d 04 64"
	expect hex_of(
		Alu({
			operation: Add,
			to: Rax,
			from: Rbx,
		}),
	) == "48 01 d8"
	expect hex_of(
		Alu({
			operation: Or,
			to: Rax,
			from: Rcx,
		}),
	) == "48 09 c8"
	expect hex_of(
		Alu({
			operation: And,
			to: Rax,
			from: Rcx,
		}),
	) == "48 21 c8"
	expect hex_of(
		Alu({
			operation: Sub,
			to: Rcx,
			from: Rdx,
		}),
	) == "48 29 d1"
	expect hex_of(
		Alu({
			operation: Xor,
			to: Rdi,
			from: Rdi,
		}),
	) == "48 31 ff"
	expect hex_of(
		Alu({
			operation: Cmp,
			to: R8,
			from: R9,
		}),
	) == "4d 39 c8"
	expect hex_of(
		AluImm({
			operation: Add,
			to: Rsp,
			value: 8,
		}),
	) == "48 83 c4 08"
	expect hex_of(
		AluImm({
			operation: Sub,
			to: Rsp,
			value: 4096,
		}),
	) == "48 81 ec 00 10 00 00"
	expect hex_of(
		AluImm({
			operation: Cmp,
			to: Rax,
			value: -1,
		}),
	) == "48 83 f8 ff"
	expect hex_of(
		AluImm({
			operation: And,
			to: R9,
			value: 127,
		}),
	) == "49 83 e1 7f"
	expect hex_of(
		AluImm({
			operation: Or,
			to: Rdx,
			value: 128,
		}),
	) == "48 81 ca 80 00 00 00"
	expect hex_of(
		AluImm({
			operation: Xor,
			to: Rbx,
			value: -128,
		}),
	) == "48 83 f3 80"
	expect hex_of(Imul({ to: Rax, from: Rbx })) == "48 0f af c3"
	expect hex_of(Imul({ to: R8, from: R15 })) == "4d 0f af c7"
	expect hex_of(ImulWide(Rcx)) == "48 f7 e9"
	expect hex_of(ImulWide(R8)) == "49 f7 e8"
	expect hex_of(Div(R8)) == "49 f7 f0"
	expect hex_of(Div(Rcx)) == "48 f7 f1"
	expect hex_of(Idiv(R9)) == "49 f7 f9"
	expect hex_of(Idiv(Rcx)) == "48 f7 f9"
	expect hex_of(Div32(Rcx)) == "f7 f1"
	expect hex_of(Div32(Rbx)) == "f7 f3"
	expect hex_of(Div32(R9)) == "41 f7 f1"
	expect hex_of(Div32(R15)) == "41 f7 f7"
	expect hex_of(Cqo) == "48 99"
	expect hex_of(Neg(Rax)) == "48 f7 d8"
	expect hex_of(Neg(R11)) == "49 f7 db"
	expect hex_of(Setcc({ condition: E, to: Al })) == "0f 94 c0"
	expect hex_of(Setcc({ condition: A, to: Al })) == "0f 97 c0"
	expect hex_of(Setcc({ condition: Np, to: Cl })) == "0f 9b c1"
	expect hex_of(Setcc({ condition: P, to: Dl })) == "0f 9a c2"
	expect hex_of(Setcc({ condition: Ae, to: Bl })) == "0f 93 c3"
	expect hex_of(MovzxByte({ to: Rax, from: Al })) == "48 0f b6 c0"
	expect hex_of(MovzxByte({ to: Rcx, from: Cl })) == "48 0f b6 c9"
	expect hex_of(MovzxByte({ to: R8, from: Dl })) == "4c 0f b6 c2"
	expect hex_of(MovByteStore({ to: at_base(Rsi, 0), from: Dl })) == "88 16"
	expect hex_of(MovByteStore({ to: at_base(Rsp, 8), from: Al })) == "88 44 24 08"
	expect hex_of(MovByteStore({ to: at_base(R9, 0), from: Bl })) == "41 88 19"
	expect hex_of(MovByteStore({ to: at_base(Rbp, -1), from: Cl })) == "88 4d ff"
	expect hex_of(Test({ left: Rax, right: Rax })) == "48 85 c0"
	expect hex_of(Test({ left: R12, right: Rcx })) == "49 85 cc"
	expect hex_of(
		Shift({
			operation: Shl,
			reg: Rax,
			count: 3,
		}),
	) == "48 c1 e0 03"
	expect hex_of(
		Shift({
			operation: Sar,
			reg: R11,
			count: 63,
		}),
	) == "49 c1 fb 3f"
	expect hex_of(
		Shift({
			operation: Shr,
			reg: Rcx,
			count: 48,
		}),
	) == "48 c1 e9 30"
	expect hex_of(MovzxByteLoad({ to: Rax, from: at_base(Rsi, 0) })) == "48 0f b6 06"
	expect hex_of(MovzxByteLoad({ to: R9, from: at_base(Rdi, 8) })) == "4c 0f b6 4f 08"
	expect hex_of(
		MovzxByteLoad({
			to: Rdx,
			from: at_index({
				base: Rsi,
				index: R8,
				scale: Times1,
				displacement: 8,
			}),
		}),
	) == "4a 0f b6 54 06 08"
	expect hex_of(RepMovsb) == "f3 a4"
	expect hex_of(Push(Rbp)) == "55"
	expect hex_of(Push(R12)) == "41 54"
	expect hex_of(Pop(Rbp)) == "5d"
	expect hex_of(Pop(R15)) == "41 5f"
	expect hex_of(Jmp(-5)) == "e9 fb ff ff ff"
	expect hex_of(Jcc({ condition: E, offset: 16 })) == "0f 84 10 00 00 00"
	expect hex_of(Jcc({ condition: L, offset: 0 })) == "0f 8c 00 00 00 00"
	expect hex_of(Jcc({ condition: P, offset: 256 })) == "0f 8a 00 01 00 00"
	expect hex_of(Jcc({ condition: G, offset: -6 })) == "0f 8f fa ff ff ff"
	expect hex_of(Call(0)) == "e8 00 00 00 00"
	expect hex_of(Ret) == "c3"
	expect hex_of(CallReg(Rax)) == "ff d0"
	expect hex_of(CallReg(R11)) == "41 ff d3"
	expect hex_of(Syscall) == "0f 05"
	expect hex_of(MovsdRegReg({ to: Xmm0, from: Xmm1 })) == "f2 0f 10 c1"
	expect hex_of(MovsdRegReg({ to: Xmm8, from: Xmm1 })) == "f2 44 0f 10 c1"
	expect hex_of(MovsdLoad({ to: Xmm0, from: at_base(Rsp, 8) })) == "f2 0f 10 44 24 08"
	expect hex_of(MovsdStore({ to: at_base(Rbx, 0), from: Xmm9 })) == "f2 44 0f 11 0b"
	expect hex_of(
		Sse({
			operation: Addsd,
			to: Xmm0,
			from: Xmm1,
		}),
	) == "f2 0f 58 c1"
	expect hex_of(
		Cmov({
			condition: Ae,
			to: Rcx,
			from: Rax,
		}),
	) == "48 0f 43 c8"
	expect hex_of(
		Cmov({
			condition: A,
			to: R9,
			from: R10,
		}),
	) == "4d 0f 47 ca"
	expect hex_of(
		Sse({
			operation: Subsd,
			to: Xmm0,
			from: Xmm1,
		}),
	) == "f2 0f 5c c1"
	expect hex_of(
		Sse({
			operation: Mulsd,
			to: Xmm3,
			from: Xmm4,
		}),
	) == "f2 0f 59 dc"
	expect hex_of(
		Sse({
			operation: Divsd,
			to: Xmm2,
			from: Xmm15,
		}),
	) == "f2 41 0f 5e d7"
	expect hex_of(
		Sse({
			operation: Sqrtsd,
			to: Xmm1,
			from: Xmm8,
		}),
	) == "f2 41 0f 51 c8"
	expect hex_of(Ucomisd({ left: Xmm0, right: Xmm1 })) == "66 0f 2e c1"
	expect hex_of(Cvtsi2sd({ to: Xmm0, from: Rax })) == "f2 48 0f 2a c0"
	expect hex_of(Cvtsi2sd({ to: Xmm9, from: R10 })) == "f2 4d 0f 2a ca"
	expect hex_of(Cvttsd2si({ to: Rax, from: Xmm0 })) == "f2 48 0f 2c c0"
	expect hex_of(MovqToXmm({ to: Xmm0, from: Rax })) == "66 48 0f 6e c0"
	expect hex_of(MovqFromXmm({ to: Rax, from: Xmm0 })) == "66 48 0f 7e c0"
	expect hex_of(MovqFromXmm({ to: R9, from: Xmm10 })) == "66 4d 0f 7e d1"
}

## Whether an instruction's general register operands are 64 bits wide
## (REX.W), as every integer instruction here is, or not, as the SSE2
## instructions between two xmm registers are.
Width : [Wide, Narrow]

## The ModRM byte's r/m operand: a register by its number, or memory.
Operand : [Direct(U8), Memory(X86.Mem)]

## An instruction with a ModRM byte, laid out as `append_encoded` writes it:
## the mandatory prefix, REX, the opcode, ModRM (with SIB and displacement)
## and the immediate. `reg` is the ModRM reg field, a register's number or an
## opcode's /digit.
Layout : {
	prefix : List(U8),
	wide : Width,
	opcode : List(U8),
	reg : U8,
	operand : Operand,
	immediate : [NoImmediate, Imm8(I64), Imm32(I64)],
}

integer_layout : {
	opcode : List(U8),
	reg : U8,
	operand : Operand,
} -> Layout
integer_layout = |{ opcode, reg, operand }| {
	prefix: [],
	wide: Wide,
	opcode,
	reg,
	operand,
	immediate: NoImmediate,
}

## An instruction on a byte register: no REX.W.
byte_layout : {
	opcode : List(U8),
	reg : U8,
	operand : Operand,
} -> Layout
byte_layout = |{ opcode, reg, operand }| {
	prefix: [],
	wide: Narrow,
	opcode,
	reg,
	operand,
	immediate: NoImmediate,
}

## An SSE2 instruction between doubles: no REX.W.
double_layout : {
	prefix : List(U8),
	opcode : List(U8),
	reg : U8,
	operand : Operand,
} -> Layout
double_layout = |{ prefix, opcode, reg, operand }| {
	prefix,
	wide: Narrow,
	opcode,
	reg,
	operand,
	immediate: NoImmediate,
}

## An SSE2 instruction between an xmm register and a 64-bit general one:
## REX.W.
crossing_layout : {
	prefix : List(U8),
	opcode : List(U8),
	reg : U8,
	operand : Operand,
} -> Layout
crossing_layout = |{ prefix, opcode, reg, operand }| {
	prefix,
	wide: Wide,
	opcode,
	reg,
	operand,
	immediate: NoImmediate,
}

append_encoded : List(U8), Layout -> List(U8)
append_encoded = |out, encoding| {
	{ reg, operand, .. } = encoding
	addressed = match operand {
		Direct(number) => {
			rex_byte = rex({
				wide: encoding.wide,
				reg,
				index: 0,
				base: number,
			})
			append_opcode(out, { encoding, rex_byte }).append(
				modrm({ mode: 3, reg, operand: number }),
			)
		}
		Memory(Rip(displacement)) => {
			rex_byte = rex({
				wide: encoding.wide,
				reg,
				index: 0,
				base: 0,
			})
			started = append_opcode(
				out,
				{ encoding, rex_byte },
			).append(modrm({ mode: 0, reg, operand: 5 }))
			X86.append_little_endian(started, { value: displacement.to_i64(), size: 4 })
		}
		Memory(Based({ base, index, displacement })) => {
			address = address_fields({ base, index, displacement })
			rex_byte = rex({
				wide: encoding.wide,
				reg,
				index: address.index_number,
				base: address.base_number,
			})
			started = append_opcode(out, { encoding, rex_byte }).append(
				modrm({ mode: address.mode, reg, operand: address.operand }),
			)
			with_sib = match address.sib {
				Sib(byte) => started.append(byte)
				NoSib => started
			}
			match address.mode {
				0 => with_sib
				1 => X86.append_little_endian(with_sib, { value: displacement.to_i64(), size: 1 })
				_ => X86.append_little_endian(with_sib, { value: displacement.to_i64(), size: 4 })
			}
		}
	}
	match encoding.immediate {
		NoImmediate => addressed
		Imm8(value) => X86.append_little_endian(addressed, { value, size: 1 })
		Imm32(value) => X86.append_little_endian(addressed, { value, size: 4 })
	}
}

## How a base-and-index memory operand is encoded: ModRM's mode and r/m
## fields, the SIB byte if it needs one, and the register numbers whose high
## bits go in REX. A base of rsp or r12 (low bits 100) needs a SIB byte, and a
## base of rbp or r13 (low bits 101) with no displacement needs a zero byte of
## displacement, since mode 0 with those bits means something else.
address_fields : {
	base : X86.Register,
	index : X86.Index,
	displacement : I32,
} -> {
	mode : U8,
	operand : U8,
	sib : [Sib(U8), NoSib],
	index_number : U8,
	base_number : U8,
}
address_fields = |{ base, index, displacement }| {
	base_number = register_number(base)
	wide_displacement = displacement.to_i64()
	mode =
		if wide_displacement == 0 and base_number.bitwise_and(7) != 5 {
			0
		} else if wide_displacement >= -128 and wide_displacement <= 127 {
			1
		} else {
			2
		}
	match index {
		NoIndex =>
			if base_number.bitwise_and(7) == 4 {
				{
					mode,
					operand: 4,
					sib: Sib(
						modrm({
							mode: 0,
							reg: 4,
							operand: base_number,
						}),
					),
					index_number: 0,
					base_number,
				}
			} else {
				{
					mode,
					operand: base_number,
					sib: NoSib,
					index_number: 0,
					base_number,
				}
			}
		Scaled({ reg: Rsp, scale: _ }) => crash "X86.address_fields: rsp can't be an index register"
		Scaled({ reg: index_register, scale }) => {
			index_number = register_number(index_register)
			scale_bits = match scale {
				Times1 => 0
				Times2 => 1
				Times4 => 2
				Times8 => 3
			}
			{
				mode,
				operand: 4,
				sib: Sib(
					modrm({
						mode: scale_bits,
						reg: index_number,
						operand: base_number,
					}),
				),
				index_number,
				base_number,
			}
		}
	}
}

register_number : X86.Register -> U8
register_number = |reg|
	match reg {
		Rax => 0
		Rcx => 1
		Rdx => 2
		Rbx => 3
		Rsp => 4
		Rbp => 5
		Rsi => 6
		Rdi => 7
		R8 => 8
		R9 => 9
		R10 => 10
		R11 => 11
		R12 => 12
		R13 => 13
		R14 => 14
		R15 => 15
	}

byte_register_number : X86.ByteRegister -> U8
byte_register_number = |reg|
	match reg {
		Al => 0
		Cl => 1
		Dl => 2
		Bl => 3
	}

xmm_number : X86.Xmm -> U8
xmm_number = |xmm|
	match xmm {
		Xmm0 => 0
		Xmm1 => 1
		Xmm2 => 2
		Xmm3 => 3
		Xmm4 => 4
		Xmm5 => 5
		Xmm6 => 6
		Xmm7 => 7
		Xmm8 => 8
		Xmm9 => 9
		Xmm10 => 10
		Xmm11 => 11
		Xmm12 => 12
		Xmm13 => 13
		Xmm14 => 14
		Xmm15 => 15
	}

## The /digit of an ALU operation: its ModRM reg field with an immediate,
## and, times eight plus one, its opcode between two registers.
alu_digit : X86.AluOperation -> U8
alu_digit = |operation|
	match operation {
		Add => 0
		Or => 1
		And => 4
		Sub => 5
		Xor => 6
		Cmp => 7
	}

condition_code : X86.Condition -> U8
condition_code = |condition|
	match condition {
		O => 0x0
		No => 0x1
		B => 0x2
		Ae => 0x3
		E => 0x4
		Ne => 0x5
		Be => 0x6
		A => 0x7
		S => 0x8
		Ns => 0x9
		P => 0xA
		Np => 0xB
		L => 0xC
		Ge => 0xD
		Le => 0xE
		G => 0xF
	}

## The REX prefix for a width and the high bits of the three register
## fields: 0x40 with W, R, X and B set.
rex : {
	wide : Width,
	reg : U8,
	index : U8,
	base : U8,
} -> U8
rex = |{ wide, reg, index, base }| {
	w_bit = match wide {
		Wide => 8
		Narrow => 0
	}
	0x40 + w_bit + high_bit(reg) * 4 + high_bit(index) * 2 + high_bit(base)
}

## A REX byte as the instruction carries it: left out when it is the bare
## 0x40, which says nothing.
rex_bytes : U8 -> List(U8)
rex_bytes = |byte|
	if byte == 0x40 {
		[]
	} else {
		[byte]
	}

high_bit : U8 -> U8
high_bit = |number| number.div_trunc_by(8)

## A ModRM byte, or a SIB byte, which has the same three fields: two bits,
## then three, then three.
modrm : {
	mode : U8,
	reg : U8,
	operand : U8,
} -> U8
modrm = |{ mode, reg, operand }| mode * 64 + reg.bitwise_and(7) * 8 + operand.bitwise_and(7)

## A one-byte opcode with the register in its low three bits (`push`,
## `pop`), and REX.B for the high eight.
append_short : List(U8), { opcode : U8, reg : X86.Register } -> List(U8)
append_short = |out, { opcode, reg }| {
	number = register_number(reg)
	out.concat(
		rex_bytes(
			rex({
				wide: Narrow,
				reg: 0,
				index: 0,
				base: number,
			}),
		),
	).append(opcode + number.bitwise_and(7))
}

## The bytes before ModRM: the mandatory prefix, the REX byte if it says
## anything, and the opcode.
append_opcode : List(U8), { encoding : Layout, rex_byte : U8 } -> List(U8)
append_opcode = |
	out,
	{ encoding, rex_byte },
| out.concat(encoding.prefix).concat(rex_bytes(rex_byte)).concat(encoding.opcode)

## An instruction's bytes as hex, as objdump prints them, for the expects.
hex_of : X86.Instruction -> Str
hex_of = |instruction| X86.hex_text(X86.instruction_bytes(instruction))

## A memory operand at a base register and a displacement, for the expects.
at_base : X86.Register, I32 -> X86.Mem
at_base = |base, displacement| Based({ base, index: NoIndex, displacement })

## A memory operand with an index register, for the expects.
at_index : {
	base : X86.Register,
	index : X86.Register,
	scale : [Times1, Times2, Times4, Times8],
	displacement : I32,
} -> X86.Mem
at_index = |{ base, index, scale, displacement }| Based({
	base,
	index: Scaled({ reg: index, scale }),
	displacement,
})
