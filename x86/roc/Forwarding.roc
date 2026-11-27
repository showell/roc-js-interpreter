## This module takes out the loads a function's code makes of a value a
## register, general or xmm, already holds. The lowering moves every value
## through the frame, an instruction at a time: a value stored to a place on
## the stack is loaded back from it by the next instruction, and the load
## waits for the store to reach it. `forward_loads` walks the statements once,
## keeping which registers hold the value of which places of the frame, and
## turns such a load into a move from the register (or into nothing, when it
## is the same register): `mov` or `movsd` between two of one kind, `movq`
## across. A holder of the load's own kind is preferred, so a value crosses
## between the kinds only when no register of its kind holds it. The stores
## all stay, so the frame holds what it held before.
##
## It knows only the places at `rbp` and the four moves between registers,
## the frame and the xmm registers that read or write them. Any other
## instruction forgets only the holdings of the registers it writes, as
## `Moves.accesses` names them, and a conditional jump forgets nothing (it
## writes no register; the way it falls to holds what was known). What may
## write memory forgets everything: a store elsewhere, a `push`, a call,
## `rep movsb`, a write of `rbp`, anything `Moves.accesses` can't describe,
## and any statement but a conditional jump. So does a label that a jump, a
## call, a `lea` or a distance names, so nothing is kept across a place
## another way may reach.
## A label nothing names (the lowering marks every instruction's place) is
## passed by. It runs over the whole program, the runtime's routines too, so
## every label's names are seen (RuntimePosts runs it over the runtime once,
## when js-x86 is built, with the names a program's whole would show).
import Assembly
import Moves
import X86

Forwarding :: [].{

	## The statements with each load of a value a register holds made a move.
	forward_loads : List(Assembly.Statement) -> List(Assembly.Statement)
	forward_loads = |statements| Forwarding.forward_loads_named(
		statements,
		Assembly.named_labels(statements),
	)

	## `forward_loads` with the labels that end a straight run given:
	## every label the whole program names, for statements that run beside
	## others (RuntimePosts).
	forward_loads_named : List(Assembly.Statement), Set(Str) -> List(Assembly.Statement)
	forward_loads_named = |statements, named| {
		var $out = List.with_capacity(statements.len())
		var $holdings = []
		for statement in statements {
			match statement {
				Mark(label) if !named.contains(label) => {
					$out = $out.append(statement)
				}
				Instruction(MovRegMem({ to, from: _ })) if is_frame_base(to) => {
					$out = $out.append(statement)
					$holdings = []
				}
				Instruction(MovRegMem({ to, from })) =>
					match frame_offset(from) {
						Ok(offset) => {
							unit = Moves.register_bit(to)
							if $holdings.any(|holding| holds(holding, { unit, offset })) {
								{}
							} else {
								match holder($holdings, { offset, preferred: is_general }) {
									Ok(General(register)) => {
										$out = $out.append(
											Instruction(MovRegReg({ to, from: register })),
										)
									}
									Ok(Double(xmm)) => {
										$out = $out.append(
											Instruction(MovqFromXmm({ to, from: xmm })),
										)
									}
									Err(NotHeld) => {
										$out = $out.append(statement)
									}
								}
								$holdings = without_register($holdings, unit).append({
									holder: General(to),
									unit,
									offset,
								})
							}
						}
						Err(Elsewhere) => {
							$out = $out.append(statement)
							$holdings = without_register($holdings, Moves.register_bit(to))
						}
					}
				Instruction(MovMemReg({ to, from })) =>
					match frame_offset(to) {
						Ok(offset) => {
							$out = $out.append(statement)
							$holdings = without_place($holdings, offset).append({
								holder: General(from),
								unit: Moves.register_bit(from),
								offset,
							})
						}
						Err(Elsewhere) => {
							$out = $out.append(statement)
							$holdings = []
						}
					}
				Instruction(MovsdLoad({ to, from })) =>
					match frame_offset(from) {
						Ok(offset) => {
							unit = Moves.xmm_bit(to)
							if $holdings.any(|holding| holds(holding, { unit, offset })) {
								{}
							} else {
								match holder($holdings, { offset, preferred: is_double }) {
									Ok(Double(xmm)) => {
										$out = $out.append(
											Instruction(MovsdRegReg({ to, from: xmm })),
										)
									}
									Ok(General(register)) => {
										$out = $out.append(
											Instruction(MovqToXmm({ to, from: register })),
										)
									}
									Err(NotHeld) => {
										$out = $out.append(statement)
									}
								}
								$holdings = without_register($holdings, unit).append({
									holder: Double(to),
									unit,
									offset,
								})
							}
						}
						Err(Elsewhere) => {
							$out = $out.append(statement)
							$holdings = without_register($holdings, Moves.xmm_bit(to))
						}
					}
				Instruction(MovsdStore({ to, from })) =>
					match frame_offset(to) {
						Ok(offset) => {
							$out = $out.append(statement)
							$holdings = without_place($holdings, offset).append({
								holder: Double(from),
								unit: Moves.xmm_bit(from),
								offset,
							})
						}
						Err(Elsewhere) => {
							$out = $out.append(statement)
							$holdings = []
						}
					}
				Instruction(instruction) => {
					$out = $out.append(statement)
					$holdings = holdings_after($holdings, instruction)
				}
				JccTo(_) => {
					$out = $out.append(statement)
				}
				_ => {
					$out = $out.append(statement)
					$holdings = []
				}
			}
		}
		$out
	}
}

## A register known to hold the value of the frame's place at `offset`, and
## its bit in `Moves.accesses`' sets.
Held : {
	holder : Holder,
	unit : U32,
	offset : I32,
}

## A general register or an xmm one: either may hold a place's 8 bytes.
Holder : [General(X86.Register), Double(X86.Xmm)]

## Whether a holder is a general register.
is_general : Holder -> Bool
is_general = |held|
	match held {
		General(_) => True
		Double(_) => False
	}

## Whether a holder is an xmm register.
is_double : Holder -> Bool
is_double = |held| !is_general(held)

## A place's offset from `rbp`, when it is in the frame (at `rbp`, with no
## index).
frame_offset : X86.Mem -> Try(I32, [Elsewhere])
frame_offset = |place|
	match place {
		Based({ base, index: NoIndex, displacement }) =>
			if X86.register_index(base) == X86.register_index(Rbp) {
				Ok(displacement)
			} else {
				Err(Elsewhere)
			}
		_ => Err(Elsewhere)
	}

## Whether `register` is `rbp`, which every place `frame_offset` finds is at.
is_frame_base : X86.Register -> Bool
is_frame_base = |register| X86.register_index(register) == X86.register_index(Rbp)

## What is known after an instruction `forward_loads` doesn't model as a
## move: the holdings of the registers it writes (as `Moves.accesses` names
## them) are forgotten, and every holding when it may write memory or
## writes `rbp`, or when `Moves.accesses` can't name what it writes.
holdings_after : List(Held), X86.Instruction -> List(Held)
holdings_after = |holdings, instruction|
	match Moves.accesses(instruction) {
		Ok({ reads: _, writes }) =>
			if stores_nothing(instruction) and U32.bitwise_and(
				writes,
				Moves.register_bit(Rbp),
			) == 0 {
				holdings.drop_if(|holding| U32.bitwise_and(holding.unit, writes) != 0)
			} else {
				[]
			}
		Err(Opaque) => []
	}

## Whether an instruction is known to write no memory: the instructions
## `Moves.accesses` names, but its stores and `push`. Any other may.
stores_nothing : X86.Instruction -> Bool
stores_nothing = |instruction|
	match instruction {
		MovRegReg(_) | MovRegImm(_) | MovRegMem(_) | Lea(_) | MovzxByteLoad(_) => True
		Alu(_) | AluImm(_) | Imul(_) | Bsr(_) | Neg(_) | Div32(_) | Shift(_) | Test(_) => True
		ShiftCl(_) | Movsxd(_) | Mov32(_) | Not(_) => True
		Setcc(_) | MovzxByte(_) | Pop(_) | Cmov(_) => True
		MovsdRegReg(_) | MovsdLoad(_) | Sse(_) | Ucomisd(_) => True
		Cvtsi2sd(_) | Cvttsd2si(_) | MovqToXmm(_) | MovqFromXmm(_) => True
		Cvtsi2sd32(_) | Cvttsd2si32(_) => True
		_ => False
	}

## Whether a holding is the register whose bit is `unit` holding the place at
## `offset`.
holds : Held, { unit : U32, offset : I32 } -> Bool
holds = |holding, { unit, offset }| holding.unit == unit and holding.offset == offset

## A register known to hold the value at `offset`: one `preferred` takes
## (of the kind the load writes, so no value crosses between the two kinds
## of register when it needn't), else any.
holder : List(Held), { offset : I32, preferred : Holder -> Bool } -> Try(Holder, [NotHeld])
holder = |holdings, { offset, preferred }| {
	at = holdings.keep_if(|holding| holding.offset == offset)
	match at.find_first(|holding| preferred(holding.holder)) {
		Ok(holding) => Ok(holding.holder)
		Err(_) =>
			match at.first() {
				Ok(holding) => Ok(holding.holder)
				Err(_) => Err(NotHeld)
			}
	}
}

## What is known with the register whose bit is `unit` written.
without_register : List(Held), U32 -> List(Held)
without_register = |holdings, unit| holdings.drop_if(|holding| holding.unit == unit)

## What is known with the place at `offset` written.
without_place : List(Held), I32 -> List(Held)
without_place = |holdings, offset| holdings.drop_if(|holding| holding.offset == offset)

## The frame's place at `displacement`, for the expects.
slot : I32 -> X86.Mem
slot = |displacement| Based({ base: Rbp, index: NoIndex, displacement })

## Whether `forward_loads` makes of `statements` the code of `expected`.
forwards_to : List(Assembly.Statement), List(Assembly.Statement) -> Bool
forwards_to = |
	statements,
	expected,
| Assembly.assemble(Forwarding.forward_loads(statements)) == Assembly.assemble(expected)

expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	forwards_to([stored, Instruction(MovRegMem({ to: Rax, from: slot(-8) }))], [stored])
}

expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	forwards_to(
		[stored, Instruction(MovRegMem({ to: Rdi, from: slot(-8) }))],
		[stored, Instruction(MovRegReg({ to: Rdi, from: Rax }))],
	)
}

expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	forwards_to(
		[stored, Instruction(MovsdLoad({ to: Xmm1, from: slot(-8) }))],
		[stored, Instruction(MovqToXmm({ to: Xmm1, from: Rax }))],
	)
}

# A label a jump names forgets: another way may reach it.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	loaded = Instruction(MovRegMem({ to: Rax, from: slot(-8) }))
	forwards_to(
		[
			stored,
			Mark("there"),
			loaded,
			JmpTo("there"),
		],
		[
			stored,
			Mark("there"),
			loaded,
			JmpTo("there"),
		],
	)
}

# A label nothing names is passed by.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	loaded = Instruction(MovRegMem({ to: Rax, from: slot(-8) }))
	forwards_to([stored, Mark("here"), loaded], [stored, Mark("here")])
}

# A store of a double to the place forgets the register that held it: the
# xmm register it came from holds the place now.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	written = Instruction(MovsdStore({ to: slot(-8), from: Xmm0 }))
	loaded = Instruction(MovRegMem({ to: Rcx, from: slot(-8) }))
	forwards_to(
		[stored, written, loaded],
		[
			stored,
			written,
			Instruction(MovqFromXmm({ to: Rcx, from: Xmm0 })),
		],
	)
}

# A register loaded again from elsewhere no longer holds the place.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	other = Instruction(MovRegMem({ to: Rax, from: slot(-16) }))
	loaded = Instruction(MovRegMem({ to: Rcx, from: slot(-8) }))
	forwards_to([stored, other, loaded], [stored, other, loaded])
}

# An instruction that writes neither the place nor its register keeps what
# is known: a `movabs` into another register, a compare of doubles, a
# conditional move into another register, a conditional jump.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	between = [
		Instruction(MovRegImm({ to: Rcx, value: 0x123456789 })),
		Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
		Instruction(
			Cmov({
				condition: Ae,
				to: Rdx,
				from: Rcx,
			}),
		),
		JccTo({ condition: E, label: "there" }),
	]
	forwards_to(
		[stored].concat(between).concat([
			Instruction(MovRegMem({ to: Rdi, from: slot(-8) })),
			Mark("there"),
		]),
		[stored].concat(between).concat([
			Instruction(MovRegReg({ to: Rdi, from: Rax })),
			Mark("there"),
		]),
	)
}

# An instruction that writes the holding register forgets it.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	added = Instruction(
		AluImm({
			operation: Add,
			to: Rax,
			value: 1,
		}),
	)
	loaded = Instruction(MovRegMem({ to: Rdi, from: slot(-8) }))
	forwards_to([stored, added, loaded], [stored, added, loaded])
}

# So does a conditional move into it.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	moved = Instruction(
		Cmov({
			condition: Ae,
			to: Rax,
			from: Rcx,
		}),
	)
	loaded = Instruction(MovRegMem({ to: Rdi, from: slot(-8) }))
	forwards_to([stored, moved, loaded], [stored, moved, loaded])
}

# A store through another base register may write the place: it forgets.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	elsewhere = Instruction(
		MovMemReg({
			to: Based({
				base: Rcx,
				index: NoIndex,
				displacement: 0,
			}),
			from: Rdx,
		}),
	)
	loaded = Instruction(MovRegMem({ to: Rdi, from: slot(-8) }))
	forwards_to([stored, elsewhere, loaded], [stored, elsewhere, loaded])
}

# A call forgets, by a label or by an instruction.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	loaded = Instruction(MovRegMem({ to: Rdi, from: slot(-8) }))
	called = [
		stored,
		CallTo("there"),
		loaded,
		Mark("there"),
	]
	direct = [stored, Instruction(Call(0)), loaded]
	forwards_to(called, called) and forwards_to(direct, direct)
}

# A `push` writes memory: it forgets.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	pushed = Instruction(Push(Rcx))
	loaded = Instruction(MovRegMem({ to: Rdi, from: slot(-8) }))
	forwards_to([stored, pushed, loaded], [stored, pushed, loaded])
}

# A double stored from an xmm register feeds a load of it into another, and
# a general load of it.
expect {
	stored = Instruction(MovsdStore({ to: slot(-8), from: Xmm1 }))
	forwards_to(
		[
			stored,
			Instruction(MovsdLoad({ to: Xmm0, from: slot(-8) })),
			Instruction(MovRegMem({ to: Rax, from: slot(-8) })),
		],
		[
			stored,
			Instruction(MovsdRegReg({ to: Xmm0, from: Xmm1 })),
			Instruction(MovqFromXmm({ to: Rax, from: Xmm1 })),
		],
	)
}

# A load into the xmm register that holds the place is taken out, and a
# general register that holds it is preferred for a general load.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rcx }))
	loaded = Instruction(MovsdLoad({ to: Xmm2, from: slot(-8) }))
	forwards_to(
		[
			stored,
			loaded,
			Instruction(MovsdLoad({ to: Xmm2, from: slot(-8) })),
			Instruction(MovRegMem({ to: Rdx, from: slot(-8) })),
		],
		[
			stored,
			Instruction(MovqToXmm({ to: Xmm2, from: Rcx })),
			Instruction(MovRegReg({ to: Rdx, from: Rcx })),
		],
	)
}

# An operation on doubles into the holding xmm register forgets it.
expect {
	stored = Instruction(MovsdStore({ to: slot(-8), from: Xmm1 }))
	added = Instruction(
		Sse({
			operation: Addsd,
			to: Xmm1,
			from: Xmm2,
		}),
	)
	loaded = Instruction(MovsdLoad({ to: Xmm0, from: slot(-8) }))
	forwards_to([stored, added, loaded], [stored, added, loaded])
}

# So does a double loaded into it from elsewhere.
expect {
	stored = Instruction(MovsdStore({ to: slot(-8), from: Xmm1 }))
	other = Instruction(
		MovsdLoad({
			to: Xmm1,
			from: Based({
				base: Rax,
				index: NoIndex,
				displacement: 8,
			}),
		}),
	)
	loaded = Instruction(MovsdLoad({ to: Xmm0, from: slot(-8) }))
	forwards_to([stored, other, loaded], [stored, other, loaded])
}

# A store of a double through another base register forgets.
expect {
	stored = Instruction(MovsdStore({ to: slot(-8), from: Xmm1 }))
	elsewhere = Instruction(
		MovsdStore({
			to: Based({
				base: Rax,
				index: NoIndex,
				displacement: 0,
			}),
			from: Xmm3,
		}),
	)
	loaded = Instruction(MovsdLoad({ to: Xmm0, from: slot(-8) }))
	forwards_to([stored, elsewhere, loaded], [stored, elsewhere, loaded])
}
