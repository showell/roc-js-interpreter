## This module keeps a function's busiest places of the frame in registers.
## The lowering moves every value through the frame, an instruction at a
## time, so a loop's variables and the bytecode's stack places are stored
## and loaded back again and again, each load waiting for its store.
## `promote_statements` takes one function's statements and renames each of
## its four busiest places at `rbp` to a register of its own (`r9`, `r10`,
## `r11`, which no lowered instruction uses, only the runtime's routines,
## and `rbx`, which only a function that captures cells uses, for its
## closure record): a load of the place becomes a move from the register, a
## store a move to it.
##
## **THE RULE, KEPT CONSERVATIVE.** A place is renamed only when every
## instruction that names it is one of the four plain moves (`mov` to or
## from a general register, `movsd` to or from an xmm register), with no
## index, so nothing takes its address or reads a byte of it. A function is
## renamed only when it has a loop, or calls no function of the program (a
## leaf, such as the Nibble machine's `step`, whose few loads and stores of
## its places outnumber the saves), so recursive fib, which has neither,
## pays nothing for it; when nothing in it names `rbp` but as such a place's base;
## and a spare register the function names itself (`rbx` in a function that
## captures cells) is left to it, the places going to the others. The caller
## (`Lowering.code_walk`) renames nothing in a program with a `try`: a throw
## a handler catches would skip the restores below, and the handler's
## function would carry on with its caller's registers spoiled. With no
## `try`, a throw ends the program, and so does every way out of a function
## but its `ret`.
##
## **WHAT THE FRAME STILL HOLDS.** Around every call (a routine of the
## runtime, a function of the program, through a value too) and every
## `syscall` (which spoils `r11`), each register is stored to its place
## before and loaded back after, so the callee may use them freely and a
## routine that reads the frame through a call (none does) would still see
## it. The function saves the registers it uses below its frame at its
## entries and puts them back before its `ret`, so a routine of the runtime
## that holds one across a call of the program's code (a callback) gets it
## back as it was.
import Assembly
import X86

Registers :: [].{

	## One function's statements, its busiest places at `rbp` kept in
	## registers, with its frame of `frame_bytes` made room below for the
	## registers it saves; the statements as they are when the rule above
	## keeps it from renaming any.
	promote_statements : {
		statements : List(Assembly.Statement),
		frame_bytes : U64,
		worth_renaming : Bool,
	} -> List(Assembly.Statement)
	promote_statements = |{ statements, frame_bytes, worth_renaming }| {
		if !worth_renaming {
			return statements
		}
		var $counts = Dict.empty()
		var $barred = []
		# The spare registers the function names itself, which it keeps.
		var $named_spares = []
		for statement in statements {
			match statement {
				Instruction(instruction) => {
					named_here = registers_named(instruction).keep_if(is_spare)
					$named_spares = $named_spares.concat(named_here)
					match plain_place(instruction) {
						Ok(displacement) => {
							$counts = $counts.insert(
								displacement,
								match $counts.get(displacement) {
									Ok(count) => count + 1
									Err(_) => 1
								},
							)
						}
						Err(NotPlain) =>
							for mem in mems_named(instruction) {
								match mem {
									Based({ base: Rbp, index: _, displacement }) => {
										$barred = $barred.append(displacement)
									}
									_ => {}
								}
							}
					}
					names_frame = direct_registers(instruction).any(is_frame_pointer)
					if names_frame and !is_frame_making(instruction) {
						return statements
					}
				}
				_ => {}
			}
		}
		same = |one, other| X86.register_index(one) == X86.register_index(other)
		free = spare_registers.drop_if(|spare| $named_spares.any(|named| same(named, spare)))
		chosen =
			$counts
				.to_list()
				.keep_if(
					|
						(displacement, count),
					| count >= 4 and displacement < 0 and !$barred.contains(displacement),
				)
				.sort_with(
					|(_, one_count), (_, other_count)|
						if one_count > other_count {
							Before
						} else if one_count < other_count {
							After
						} else {
							Same
						},
				)
				.take_first(free.len())
				.map_with_index(
					|(displacement, _), at| {
						register =
							free.get(at)
								?? crash "Registers.promote_statements: a spare register"
						{ displacement, register }
					},
				)
		if chosen.is_empty() {
			return statements
		}
		saved = chosen.map_with_index(
			|{ displacement: _, register }, at| {
				save = place((0 - frame_bytes.to_i32_wrap()) - 8 * (at.to_i32_wrap() + 1))
				{ register, save }
			},
		)
		spills = chosen.map(
			|{ displacement, register }| Instruction(
				MovMemReg({ to: place(displacement), from: register }),
			),
		)
		reloads = chosen.map(
			|{ displacement, register }| Instruction(
				MovRegMem({ to: register, from: place(displacement) }),
			),
		)
		var $out = List.with_capacity(statements.len())
		var $after_frame_pointer = False
		for statement in statements {
			made_frame = $after_frame_pointer
			$after_frame_pointer = match statement {
				Instruction(MovRegReg({ to: Rbp, from: Rsp })) => True
				_ => False
			}
			match statement {
				Instruction(AluImm({ operation: Sub, to: Rsp, value })) if made_frame => {
					$out =
						$out
							.append(
								Instruction(
									AluImm({
										operation: Sub,
										to: Rsp,
										value: value + 8 * saved.len().to_i32_wrap(),
									}),
								),
							)
							.concat(
								saved.map(
									|{ register, save }| Instruction(
										MovMemReg({ to: save, from: register }),
									),
								),
							)
				}
				Instruction(MovRegReg({ to: Rsp, from: Rbp })) => {
					$out =
						$out
							.concat(
								saved.map(
									|{ register, save }| Instruction(
										MovRegMem({ to: register, from: save }),
									),
								),
							)
							.append(statement)
				}
				Instruction(Call(_)) | CallTo(_) => {
					$out = $out.concat(spills).append(statement).concat(reloads)
				}
				Instruction(CallReg(_)) | Instruction(Syscall) => {
					$out = $out.concat(spills).append(statement).concat(reloads)
				}
				Instruction(instruction) => {
					$out = $out.append(Instruction(rename_place(instruction, chosen)))
				}
				_ => {
					$out = $out.append(statement)
				}
			}
		}
		$out
	}
}

## The registers a function's places may be kept in.
spare_registers : List(X86.Register)
spare_registers = [R9, R10, R11, Rbx]

## Whether a register is one of the spare ones.
is_spare : X86.Register -> Bool
is_spare = |register|
	spare_registers.any(|one| X86.register_index(one) == X86.register_index(register))

## Whether a register is `rbp`, the frame's.
is_frame_pointer : X86.Register -> Bool
is_frame_pointer = |register| X86.register_index(register) == X86.register_index(Rbp)

## Whether `promoted` makes of `statements` the code of `expected`, for the
## expects.
promotes_to : List(Assembly.Statement), List(Assembly.Statement) -> Bool
promotes_to = |statements, expected|
	Assembly.assemble(
		Registers.promote_statements({ statements, frame_bytes: 16, worth_renaming: True }),
	)
		== Assembly.assemble(expected)

## The place at `displacement` from `rbp`.
place : I32 -> X86.Mem
place = |displacement| Based({ base: Rbp, index: NoIndex, displacement })

## The instructions that make a frame and take it down, which name `rbp` as
## a register and are left as they are.
is_frame_making : X86.Instruction -> Bool
is_frame_making = |instruction|
	match instruction {
		Push(Rbp) | Pop(Rbp) => True
		MovRegReg({ to: Rbp, from: Rsp }) | MovRegReg({ to: Rsp, from: Rbp }) => True
		_ => False
	}

## The displacement of the place at `rbp` that one of the four plain moves
## loads or stores.
plain_place : X86.Instruction -> Try(I32, [NotPlain])
plain_place = |instruction|
	match instruction {
		MovRegMem(
			{ to: _, from: Based({ base: Rbp, index: NoIndex, displacement }) },
		) => Ok(displacement)
		MovMemReg(
			{ to: Based({ base: Rbp, index: NoIndex, displacement }), from: _ },
		) => Ok(displacement)
		MovsdLoad(
			{ to: _, from: Based({ base: Rbp, index: NoIndex, displacement }) },
		) => Ok(displacement)
		MovsdStore(
			{ to: Based({ base: Rbp, index: NoIndex, displacement }), from: _ },
		) => Ok(displacement)
		_ => Err(NotPlain)
	}

## The instruction with each plain move of a chosen place made a move to or
## from its register.
rename_place : X86.Instruction,
List(
	{ displacement : I32, register : X86.Register },
) -> X86.Instruction
rename_place = |instruction, chosen| {
	held = |displacement|
		chosen
			.find_first(|pick| pick.displacement == displacement)
			.map_ok(|pick| pick.register)
	match plain_place(instruction).map_ok(held) {
		Ok(Ok(register)) =>
			match instruction {
				MovRegMem({ to, from: _ }) => MovRegReg({ to, from: register })
				MovMemReg({ to: _, from }) => MovRegReg({ to: register, from })
				MovsdLoad({ to, from: _ }) => MovqToXmm({ to, from: register })
				MovsdStore({ to: _, from }) => MovqFromXmm({ to: register, from })
				_ => instruction
			}
		_ => instruction
	}
}

## The memory operands an instruction names.
mems_named : X86.Instruction -> List(X86.Mem)
mems_named = |instruction|
	match instruction {
		MovRegMem({ to: _, from }) | Lea({ to: _, from }) | MovzxByteLoad({ to: _, from }) => [from]
		MovsdLoad({ to: _, from }) => [from]
		MovMemReg({ to, from: _ })
		| MovByteStore({ to, from: _ })
		| MovsdStore({ to, from: _ }) => [to]
		_ => []
	}

## The general registers an instruction names, its memory operands' bases
## and indexes among them. (`RepMovsb`, `Div`, `Cqo` and the like name
## others by their nature, none of them `rbp` or a spare one.)
registers_named : X86.Instruction -> List(X86.Register)
registers_named = |instruction| {
	based = mems_named(instruction).join_map(
		|mem|
			match mem {
				Based(
					{
						base,
						index: Scaled({ reg, scale: _ }),
						displacement: _,
					},
				) => [base, reg]
				Based({ base, index: NoIndex, displacement: _ }) => [base]
				Rip(_) => []
			},
	)
	direct_registers(instruction).concat(based)
}

## The general registers an instruction names as operands of their own, not
## as a memory operand's base or index.
direct_registers : X86.Instruction -> List(X86.Register)
direct_registers = |instruction|
	match instruction {
		MovRegReg({ to, from }) | Alu({ operation: _, to, from }) | Imul({ to, from }) => [to, from]
		Cmov({ condition: _, to, from }) => [to, from]
		MovRegImm({ to, value: _ }) | AluImm({ operation: _, to, value: _ }) => [to]
		MovRegMem({ to, from: _ }) | Lea({ to, from: _ }) | MovzxByteLoad({ to, from: _ }) => [to]
		MovMemReg({ to: _, from }) => [from]
		MovzxByte({ to, from: _ })
		| Cvttsd2si({ to, from: _ })
		| MovqFromXmm({ to, from: _ }) => [to]
		Cvtsi2sd({ to: _, from }) | MovqToXmm({ to: _, from }) => [from]
		Div(register) | Idiv(register) | ImulWide(register) | Neg(register) => [register]
		Push(register) | Pop(register) | CallReg(register) => [register]
		Test({ left, right }) => [left, right]
		Shift({ operation: _, reg, count: _ }) => [reg]
		_ => []
	}

expect {
	# A loop's place loaded and stored often is kept in r9, spilled around a
	# call, and r9 is saved below the frame and put back before the `ret`.
	slot = place(-8)
	body = [
		Assembly.Statement.Instruction(Push(Rbp)),
		Instruction(MovRegReg({ to: Rbp, from: Rsp })),
		Instruction(
			AluImm({
				operation: Sub,
				to: Rsp,
				value: 16,
			}),
		),
		Instruction(MovMemReg({ to: slot, from: Rax })),
		Instruction(MovRegMem({ to: Rcx, from: slot })),
		Instruction(MovsdLoad({ to: Xmm0, from: slot })),
		Instruction(MovsdStore({ to: slot, from: Xmm0 })),
		CallTo("routine"),
		Instruction(MovRegReg({ to: Rsp, from: Rbp })),
		Instruction(Pop(Rbp)),
		Instruction(Ret),
	]
	save = place(-24)
	expected = [
		Assembly.Statement.Instruction(Push(Rbp)),
		Instruction(MovRegReg({ to: Rbp, from: Rsp })),
		Instruction(
			AluImm({
				operation: Sub,
				to: Rsp,
				value: 24,
			}),
		),
		Instruction(MovMemReg({ to: save, from: R9 })),
		Instruction(MovRegReg({ to: R9, from: Rax })),
		Instruction(MovRegReg({ to: Rcx, from: R9 })),
		Instruction(MovqToXmm({ to: Xmm0, from: R9 })),
		Instruction(MovqFromXmm({ to: R9, from: Xmm0 })),
		Instruction(MovMemReg({ to: slot, from: R9 })),
		CallTo("routine"),
		Instruction(MovRegMem({ to: R9, from: slot })),
		Instruction(MovRegMem({ to: R9, from: save })),
		Instruction(MovRegReg({ to: Rsp, from: Rbp })),
		Instruction(Pop(Rbp)),
		Instruction(Ret),
	]
	promotes_to(body, expected)
}

expect {
	# A place whose address is taken stays in the frame, and so does every
	# place of a function with no loop.
	slot = place(-8)
	body = [
		Assembly.Statement.Instruction(MovMemReg({ to: slot, from: Rax })),
		Instruction(MovRegMem({ to: Rcx, from: slot })),
		Instruction(MovRegMem({ to: Rcx, from: slot })),
		Instruction(MovRegMem({ to: Rcx, from: slot })),
		Instruction(Lea({ to: Rdi, from: slot })),
	]
	unlooped = body.drop_last(1)
	kept = Assembly.assemble(
		Registers.promote_statements({
			statements: unlooped,
			frame_bytes: 16,
			worth_renaming: False,
		}),
	)
	promotes_to(body, body) and kept == Assembly.assemble(unlooped)
}
