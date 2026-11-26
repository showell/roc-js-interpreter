## This module takes out the loads a function's code makes of a value a
## general register already holds. The lowering moves every value through the
## frame, an instruction at a time: a value stored to a place on the stack is
## loaded back from it by the next instruction, and the load waits for the
## store to reach it. `forward_loads` walks the statements once, keeping which
## registers hold the value of which places of the frame, and turns such a
## load into a move from the register (or into nothing, when it is the same
## register). The stores all stay, so the frame holds what it held before.
##
## It knows only the places at `rbp` and the four moves between registers,
## the frame and the xmm registers that read or write them; any other
## statement (a jump, a call, arithmetic, a store elsewhere) forgets
## everything, and so does a label that a jump, a call, a `lea` or a
## distance names, so nothing is kept across a place another way may reach.
## A label nothing names (the lowering marks every instruction's place) is
## passed by. It runs over the whole program, the runtime's routines too, so
## every label's names are seen.
import Assembly
import X86

Forwarding :: [].{

	## The statements with each load of a value a register holds made a move.
	forward_loads : List(Assembly.Statement) -> List(Assembly.Statement)
	forward_loads = |statements| {
		named = Forwarding.named_labels(statements)
		var $out = List.with_capacity(statements.len())
		var $holdings = []
		for statement in statements {
			match statement {
				Mark(label) if !named.contains(label) => {
					$out = $out.append(statement)
				}
				Instruction(MovRegMem({ to, from })) =>
					match frame_offset(from) {
						Ok(offset) => {
							number = X86.register_index(to)
							if $holdings.any(|holding| holds(holding, { number, offset })) {
								{}
							} else {
								match holder($holdings, offset) {
									Ok(register) => {
										$out = $out.append(
											Instruction(MovRegReg({ to, from: register })),
										)
									}
									Err(NotHeld) => {
										$out = $out.append(statement)
									}
								}
								$holdings = without_register($holdings, number).append({
									register: to,
									number,
									offset,
								})
							}
						}
						Err(Elsewhere) => {
							$out = $out.append(statement)
							$holdings = without_register($holdings, X86.register_index(to))
						}
					}
				Instruction(MovMemReg({ to, from })) =>
					match frame_offset(to) {
						Ok(offset) => {
							$out = $out.append(statement)
							$holdings = without_place($holdings, offset).append({
								register: from,
								number: X86.register_index(from),
								offset,
							})
						}
						Err(Elsewhere) => {
							$out = $out.append(statement)
							$holdings = []
						}
					}
				Instruction(MovsdLoad({ to, from })) =>
					match frame_offset(from).map_ok(|offset| holder($holdings, offset)) {
						Ok(Ok(register)) => {
							$out = $out.append(Instruction(MovqToXmm({ to, from: register })))
						}
						_ => {
							$out = $out.append(statement)
						}
					}
				Instruction(MovsdStore({ to, from: _ })) =>
					match frame_offset(to) {
						Ok(offset) => {
							$out = $out.append(statement)
							$holdings = without_place($holdings, offset)
						}
						Err(Elsewhere) => {
							$out = $out.append(statement)
							$holdings = []
						}
					}
				_ => {
					$out = $out.append(statement)
					$holdings = []
				}
			}
		}
		$out
	}

	## Every label a statement names: a place another way may reach.
	named_labels : List(Assembly.Statement) -> Set(Str)
	named_labels = |statements| {
		var $named = Set.empty()
		for statement in statements {
			match statement {
				JmpTo(label) | CallTo(label) | Distance(label) => {
					$named = $named.insert(label)
				}
				JccTo({ condition: _, label }) | LeaTo({ to: _, label }) => {
					$named = $named.insert(label)
				}
				_ => {}
			}
		}
		$named
	}
}

## A register known to hold the value of the frame's place at `offset`.
Held : {
	register : X86.Register,
	number : U8,
	offset : I32,
}

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

## Whether a holding is the register numbered `number` holding the place at
## `offset`.
holds : Held, { number : U8, offset : I32 } -> Bool
holds = |holding, { number, offset }| holding.number == number and holding.offset == offset

## A register known to hold the value at `offset`.
holder : List(Held), I32 -> Try(X86.Register, [NotHeld])
holder = |holdings, offset|
	match holdings.find_first(|holding| holding.offset == offset) {
		Ok(holding) => Ok(holding.register)
		Err(_) => Err(NotHeld)
	}

## What is known with the register numbered `number` written.
without_register : List(Held), U8 -> List(Held)
without_register = |holdings, number| holdings.drop_if(|holding| holding.number == number)

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

# A store of a double to the place forgets the register that held it.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	written = Instruction(MovsdStore({ to: slot(-8), from: Xmm0 }))
	loaded = Instruction(MovRegMem({ to: Rcx, from: slot(-8) }))
	forwards_to([stored, written, loaded], [stored, written, loaded])
}

# A register loaded again from elsewhere no longer holds the place.
expect {
	stored = Instruction(MovMemReg({ to: slot(-8), from: Rax }))
	other = Instruction(MovRegMem({ to: Rax, from: slot(-16) }))
	loaded = Instruction(MovRegMem({ to: Rcx, from: slot(-8) }))
	forwards_to([stored, other, loaded], [stored, other, loaded])
}
