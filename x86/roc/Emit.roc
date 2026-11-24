## This module holds short names for the assembly statements the lowering
## and the runtime write most, so a routine reads as its instructions do in
## the manual, one a line: `Emit.load(Rax, Emit.mem(Rdi, 8))` is
## `mov rax, [rdi + 8]`. Each gives one `Assembly.Statement`; `Emit.mem`
## gives a memory operand.
import Assembly
import X86

Emit :: [].{

	## `[base + displacement]`.
	mem : X86.Register, I64 -> X86.Mem
	mem = |base, displacement| Based({
		base,
		index: NoIndex,
		displacement: displacement.to_i32_wrap(),
	})

	## `[base + index + displacement]`.
	mem_index : {
		base : X86.Register,
		index : X86.Register,
		displacement : I64,
	} -> X86.Mem
	mem_index = |{ base, index, displacement }| Based({
		base,
		index: Scaled({ reg: index, scale: Times1 }),
		displacement: displacement.to_i32_wrap(),
	})

	mov : X86.Register, X86.Register -> Assembly.Statement
	mov = |to, from| Instruction(MovRegReg({ to, from }))

	## A register set to a constant.
	imm : X86.Register, I64 -> Assembly.Statement
	imm = |to, value| Instruction(MovRegImm({ to, value }))

	load : X86.Register, X86.Mem -> Assembly.Statement
	load = |to, from| Instruction(MovRegMem({ to, from }))

	store : X86.Mem, X86.Register -> Assembly.Statement
	store = |to, from| Instruction(MovMemReg({ to, from }))

	## A byte of memory loaded, zero-extended.
	byte_load : X86.Register, X86.Mem -> Assembly.Statement
	byte_load = |to, from| Instruction(MovzxByteLoad({ to, from }))

	byte_store : X86.Mem, X86.ByteRegister -> Assembly.Statement
	byte_store = |to, from| Instruction(MovByteStore({ to, from }))

	lea : X86.Register, X86.Mem -> Assembly.Statement
	lea = |to, from| Instruction(Lea({ to, from }))

	## A register set to a label's address.
	address_of : X86.Register, Str -> Assembly.Statement
	address_of = |to, label| LeaTo({ to, label })

	plus : X86.Register, X86.Register -> Assembly.Statement
	plus = |to, from| Instruction(Alu({ operation: Add, to, from }))

	minus : X86.Register, X86.Register -> Assembly.Statement
	minus = |to, from| Instruction(Alu({ operation: Sub, to, from }))

	plus_imm : X86.Register, I64 -> Assembly.Statement
	plus_imm = |to, value| immediate_item({ operation: Add, to, value })

	minus_imm : X86.Register, I64 -> Assembly.Statement
	minus_imm = |to, value| immediate_item({ operation: Sub, to, value })

	cmp : X86.Register, X86.Register -> Assembly.Statement
	cmp = |to, from| Instruction(Alu({ operation: Cmp, to, from }))

	cmp_imm : X86.Register, I64 -> Assembly.Statement
	cmp_imm = |to, value| immediate_item({ operation: Cmp, to, value })

	## A register cleared to 0.
	zero : X86.Register -> Assembly.Statement
	zero = |to| Instruction(Alu({ operation: Xor, to, from: to }))

	## A register and-ed with a constant: the allocator's rounding.
	bit_and_imm : X86.Register, I64 -> Assembly.Statement
	bit_and_imm = |to, value| immediate_item({ operation: And, to, value })

	test : X86.Register, X86.Register -> Assembly.Statement
	test = |left, right| Instruction(Test({ left, right }))

	## A shift left: with a shift right after, a value's tag cleared.
	shl : X86.Register, U8 -> Assembly.Statement
	shl = |reg, count| Instruction(Shift({ operation: Shl, reg, count }))

	## A logical shift right: a value's tag, out of its top bits.
	shr : X86.Register, U8 -> Assembly.Statement
	shr = |reg, count| Instruction(Shift({ operation: Shr, reg, count }))

	## The register pushed on the machine's stack.
	save : X86.Register -> Assembly.Statement
	save = |reg| Instruction(Push(reg))

	## The register popped from the machine's stack.
	restore : X86.Register -> Assembly.Statement
	restore = |reg| Instruction(Pop(reg))

	jmp : Str -> Assembly.Statement
	jmp = |label| JmpTo(label)

	jcc : X86.Condition, Str -> Assembly.Statement
	jcc = |condition, label| JccTo({ condition, label })

	call : Str -> Assembly.Statement
	call = |label| CallTo(label)

	mark : Str -> Assembly.Statement
	mark = |label| Mark(label)

	ret : Assembly.Statement
	ret = Instruction(Ret)

	syscall : Assembly.Statement
	syscall = Instruction(Syscall)

	## The general register's bits moved to an xmm register.
	to_xmm : X86.Xmm, X86.Register -> Assembly.Statement
	to_xmm = |to, from| Instruction(MovqToXmm({ to, from }))
}

## An integer operation of a register and an immediate, which the encoder
## holds to 32 bits.
immediate_item : {
	operation : X86.AluOperation,
	to : X86.Register,
	value : I64,
} -> Assembly.Statement
immediate_item = |{ operation, to, value }| Instruction(
	AluImm({ operation, to, value: value.to_i32_wrap() }),
)
