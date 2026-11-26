## This module takes out the register moves the lowered code doesn't need.
## The lowering moves each value through a register of its own choosing
## (`rax` for most), so a value read from the frame into one of
## Registers' spare registers is `mov rax, [rbp-48]` then `mov r9, rax`, and
## a sum stored back is `mov rax, r9`, the store, and `mov r9, rax` again.
## `trim_moves` walks the whole program twice, the runtime's routines too,
## and does three things, each of which leaves what every register the code
## reads holds as it was:
##
## - **A copy between two registers that already hold one value is
##   dropped** (`copies_dropped`, forward): after `mov r9, rax`, a
##   `mov rax, r9` or a second `mov r9, rax` copies nothing.
## - **A move into a register nothing reads before it is written again is
##   dropped** (`dead_dropped`, backward): `mov r9, rax` then `mov r9, rcx`.
## - **A move through a register nothing reads after is joined into
##   one** (`dead_dropped` too): `mov rax, [rbp-48]` then `mov r9, rax`
##   becomes `mov r9, [rbp-48]`, when `rax` is written before it is read
##   again.
##
## **THE RULE, KEPT CONSERVATIVE.** A register is known to be unread only
## within a straight run, and only by the instructions `accesses` names
## every register of, as read or written (an operand of memory reads its
## base and index). Any other instruction (a call, a `ret`, a `syscall`, a
## divide, `rep movsb`), any jump, and any label a statement names (the
## lowering marks every instruction's place, and a label nothing names is
## passed by, as Forwarding passes it) counts every register as read there,
## so nothing is taken out that another way may read. `rsp` and `rbp` are
## always read. Only plain moves are taken out or joined: into a general or
## an xmm register, from a register, an immediate, an address (`lea`) or a
## place at `rbp`; a load from anywhere else stays, so no load that could
## fault is lost. No store to memory is taken out, so the frame holds what
## it held before. The upper half of an xmm register is never read by the
## lowered code (every operation on doubles is scalar), so a `movq` into one
## counts as a copy of the whole.
import Assembly
import Forwarding
import X86

Moves :: [].{

	## The statements with the moves the rule above finds unneeded taken out
	## or joined.
	trim_moves : List(Assembly.Statement) -> List(Assembly.Statement)
	trim_moves = |statements| {
		named = Forwarding.named_labels(statements)
		once = dead_dropped(copies_dropped(statements, named), named)
		dead_dropped(copies_dropped(once, named), named)
	}
}

## The registers an instruction reads and writes, as bits: a general
## register's number is its bit, an xmm register's 16 more.
Access : { reads : U32, writes : U32 }

## Every register, as bits.
every_unit : U32
every_unit = 0xFFFFFFFF

## `rsp` and `rbp`, which are always read.
frame_units : U32
frame_units = U32.bitwise_or(general_unit(Rsp), general_unit(Rbp))

## A general register's bit.
general_unit : X86.Register -> U32
general_unit = |register| U32.shl_wrap(1, X86.register_index(register))

## An xmm register's bit.
xmm_unit : X86.Xmm -> U32
xmm_unit = |xmm| U32.shl_wrap(1, 16 + X86.xmm_index(xmm))

## A byte register's bit: its general register's.
byte_unit : X86.ByteRegister -> U32
byte_unit = |byte|
	match byte {
		Al => general_unit(Rax)
		Cl => general_unit(Rcx)
		Dl => general_unit(Rdx)
		Bl => general_unit(Rbx)
	}

## The registers a memory operand reads: its base and its index.
mem_units : X86.Mem -> U32
mem_units = |mem|
	match mem {
		Based({ base, index: NoIndex, displacement: _ }) => general_unit(base)
		Based(
			{
				base,
				index: Scaled({ reg, scale: _ }),
				displacement: _,
			},
		) =>
			U32.bitwise_or(general_unit(base), general_unit(reg))
		Rip(_) => 0
	}

## Both sets of bits.
both : U32, U32 -> U32
both = |one, other| U32.bitwise_or(one, other)

## The register an operation writes: none for a compare.
written_unless_compare : X86.AluOperation, X86.Register -> U32
written_unless_compare = |operation, to|
	match operation {
		Cmp => 0
		_ => general_unit(to)
	}

## The registers an instruction reads and writes, for the instructions whose
## every register is named; `Opaque` for the rest (a call, a `ret`, a
## `syscall`, a divide, `rep movsb`, a jump), which may read any register.
accesses : X86.Instruction -> Try(Access, [Opaque])
accesses = |instruction|
	match instruction {
		MovRegReg({ to, from }) => Ok({ reads: general_unit(from), writes: general_unit(to) })
		MovRegImm({ to, value: _ }) => Ok({ reads: 0, writes: general_unit(to) })
		MovRegMem({ to, from }) | Lea({ to, from }) | MovzxByteLoad({ to, from }) =>
			Ok({ reads: mem_units(from), writes: general_unit(to) })
		MovMemReg({ to, from }) => Ok({ reads: both(mem_units(to), general_unit(from)), writes: 0 })
		MovByteStore({ to, from }) => Ok({ reads: both(mem_units(to), byte_unit(from)), writes: 0 })
		Alu({ operation, to, from }) =>
			Ok({
				reads: both(general_unit(to), general_unit(from)),
				writes: written_unless_compare(operation, to),
			})
		AluImm({ operation, to, value: _ }) =>
			Ok({ reads: general_unit(to), writes: written_unless_compare(operation, to) })
		Imul({ to, from }) => Ok({
			reads: both(general_unit(to), general_unit(from)),
			writes: general_unit(to),
		})
		Neg(register) => Ok({ reads: general_unit(register), writes: general_unit(register) })
		Shift({ operation: _, reg, count: _ }) => Ok({
			reads: general_unit(reg),
			writes: general_unit(reg),
		})
		Test({ left, right }) => Ok({
			reads: both(general_unit(left), general_unit(right)),
			writes: 0,
		})
		Setcc({ condition: _, to }) => Ok({ reads: byte_unit(to), writes: byte_unit(to) })
		MovzxByte({ to, from }) => Ok({ reads: byte_unit(from), writes: general_unit(to) })
		Push(register) => Ok({
			reads: both(general_unit(register), general_unit(Rsp)),
			writes: general_unit(Rsp),
		})
		Pop(register) => Ok({
			reads: general_unit(Rsp),
			writes: both(general_unit(register), general_unit(Rsp)),
		})
		MovsdRegReg({ to, from }) => Ok({
			reads: both(xmm_unit(to), xmm_unit(from)),
			writes: xmm_unit(to),
		})
		MovsdLoad({ to, from }) => Ok({ reads: mem_units(from), writes: xmm_unit(to) })
		MovsdStore({ to, from }) => Ok({ reads: both(mem_units(to), xmm_unit(from)), writes: 0 })
		Sse({ operation: _, to, from }) => Ok({
			reads: both(xmm_unit(to), xmm_unit(from)),
			writes: xmm_unit(to),
		})
		Ucomisd({ left, right }) => Ok({ reads: both(xmm_unit(left), xmm_unit(right)), writes: 0 })
		Cvtsi2sd({ to, from }) => Ok({
			reads: both(general_unit(from), xmm_unit(to)),
			writes: xmm_unit(to),
		})
		Cvttsd2si({ to, from }) => Ok({ reads: xmm_unit(from), writes: general_unit(to) })
		MovqToXmm({ to, from }) => Ok({ reads: general_unit(from), writes: xmm_unit(to) })
		MovqFromXmm({ to, from }) => Ok({ reads: xmm_unit(from), writes: general_unit(to) })
		_ => Err(Opaque)
	}

## Whether a memory operand is a place at `rbp`, which a load never faults on.
in_frame : X86.Mem -> Bool
in_frame = |mem|
	match mem {
		Based(
			{ base, index: NoIndex, displacement: _ },
		) => X86.register_index(base) == X86.register_index(Rbp)
		_ => False
	}

## Whether an instruction is a plain move into a register, which may be
## taken out when nothing reads what it writes.
is_plain_move : X86.Instruction -> Bool
is_plain_move = |instruction|
	match instruction {
		MovRegReg(_) | MovRegImm(_) | Lea(_) => True
		MovqToXmm(_) | MovqFromXmm(_) | MovsdRegReg(_) => True
		MovRegMem({ to: _, from }) => in_frame(from)
		MovsdLoad({ to: _, from }) => in_frame(from)
		_ => False
	}

## The registers read before an instruction, given those read after it.
read_before : X86.Instruction, U32 -> U32
read_before = |instruction, after|
	match accesses(instruction) {
		Ok({ reads, writes }) => {
			kept = U32.bitwise_and(after, U32.bitwise_xor(writes, every_unit))
			both(both(kept, reads), frame_units)
		}
		Err(Opaque) => every_unit
	}

## One move into the register `through` and the move out of it after,
## joined into one move, when nothing reads `through` after the second;
## `Apart` when the two aren't such a pair.
one_move_of : X86.Instruction,
{
	next : X86.Instruction,
	after : U32,
} -> Try(X86.Instruction, [Apart])
one_move_of = |first, { next, after }| {
	through = match first {
		MovRegReg({ to, from: _ }) | MovRegImm({ to, value: _ }) | MovRegMem({ to, from: _ }) => to
		Lea({ to, from: _ }) | MovqFromXmm({ to, from: _ }) => to
		_ => return Err(Apart)
	}
	through_unit = general_unit(through)
	if U32.bitwise_and(
		after,
		through_unit,
	) != 0 or through_unit == general_unit(Rsp) or through_unit == general_unit(Rbp) {
		return Err(Apart)
	}
	reads_through = |register| X86.register_index(register) == X86.register_index(through)
	match (first, next) {
		(MovRegReg({ to: _, from: source }), MovRegReg({ to, from })) if reads_through(from) =>
			Ok(MovRegReg({ to, from: source }))
		(MovRegImm({ to: _, value }), MovRegReg({ to, from })) if reads_through(from) =>
			Ok(MovRegImm({ to, value }))
		(MovRegMem({ to: _, from: place }), MovRegReg({ to, from })) if reads_through(from) =>
			Ok(MovRegMem({ to, from: place }))
		(Lea({ to: _, from: place }), MovRegReg({ to, from })) if reads_through(from) =>
			Ok(Lea({ to, from: place }))
		(MovqFromXmm({ to: _, from: source }), MovRegReg({ to, from })) if reads_through(from) =>
			Ok(MovqFromXmm({ to, from: source }))
		(MovRegReg({ to: _, from: source }), MovMemReg({ to, from }))
		if reads_through(from) and U32.bitwise_and(mem_units(to), through_unit) == 0 =>
			Ok(MovMemReg({ to, from: source }))
		(MovqFromXmm({ to: _, from: source }), MovMemReg({ to, from }))
		if reads_through(from) and U32.bitwise_and(mem_units(to), through_unit) == 0 =>
			Ok(MovsdStore({ to, from: source }))
		(MovRegReg({ to: _, from: source }), MovqToXmm({ to, from })) if reads_through(from) =>
			Ok(MovqToXmm({ to, from: source }))
		(MovRegMem({ to: _, from: place }), MovqToXmm({ to, from })) if reads_through(from) =>
			Ok(MovsdLoad({ to, from: place }))
		_ => Err(Apart)
	}
}

## The statements, walked backward, with each plain move whose register
## nothing reads after taken out, and each pair `one_move_of` joins made one.
dead_dropped : List(Assembly.Statement), Set(Str) -> List(Assembly.Statement)
dead_dropped = |statements, named| {
	var $kept = List.with_capacity(statements.len())
	var $read = every_unit
	# The instruction kept just after this one, and what is read after it.
	var $next = NoNext
	for back in 0..<statements.len() {
		at = statements.len() - 1 - back
		statement = statements.get(at) ?? crash "Moves.dead_dropped: a statement"
		match statement {
			Mark(label) if !named.contains(label) => {
				$kept = $kept.append(statement)
			}
			Instruction(instruction) => {
				joining = match $next {
					Next(following) => one_move_of(instruction, following).map_ok(
						|made| { made, after: following.after },
					)
					NoNext => Err(Apart)
				}
				match joining {
					Ok({ made, after }) => {
						$kept = drop_last_instruction($kept).append(Instruction(made))
						$next = Next({ next: made, after })
						$read = read_before(made, after)
					}
					Err(Apart) => {
						unread = match accesses(instruction) {
							Ok(
								{ reads: _, writes },
							) => is_plain_move(instruction) and U32.bitwise_and(writes, $read) == 0
							Err(Opaque) => False
						}
						if !unread {
							$kept = $kept.append(statement)
							$next = Next({ next: instruction, after: $read })
							$read = read_before(instruction, $read)
						}
					}
				}
			}
			_ => {
				$kept = $kept.append(statement)
				$next = NoNext
				$read = every_unit
			}
		}
	}
	reverse_statements($kept)
}

## The statements in the other order.
reverse_statements : List(Assembly.Statement) -> List(Assembly.Statement)
reverse_statements = |statements| {
	var $out = List.with_capacity(statements.len())
	for back in 0..<statements.len() {
		at = statements.len() - 1 - back
		statement = statements.get(at) ?? crash "Moves.reverse_statements: a statement"
		$out = $out.append(statement)
	}
	$out
}

## The backward walk's kept statements with the last instruction taken off,
## and any unnamed labels after it (kept later in the reversed list) kept.
drop_last_instruction : List(Assembly.Statement) -> List(Assembly.Statement)
drop_last_instruction = |kept| {
	var $marks = []
	var $rest = kept
	for _ in 0..<kept.len() {
		match $rest.last() {
			Ok(Instruction(_)) => {
				return $rest.drop_last(1).concat(reverse_statements($marks))
			}
			Ok(other) => {
				$marks = $marks.append(other)
				$rest = $rest.drop_last(1)
			}
			Err(_) => {
				return kept
			}
		}
	}
	kept
}

## A copy from one whole register to another, by their units' numbers (an
## xmm register's 16 more).
copy_of : X86.Instruction -> Try({ to : U8, from : U8 }, [NotCopy])
copy_of = |instruction|
	match instruction {
		MovRegReg({ to, from }) => Ok({
			to: X86.register_index(to),
			from: X86.register_index(from),
		})
		MovqToXmm({ to, from }) => Ok({
			to: 16 + X86.xmm_index(to),
			from: X86.register_index(from),
		})
		MovqFromXmm({ to, from }) => Ok({
			to: X86.register_index(to),
			from: 16 + X86.xmm_index(from),
		})
		_ => Err(NotCopy)
	}

## Two registers known to hold one value.
Same : { one : U8, other : U8 }

## Whether two registers are known to hold one value.
is_known_same : List(Same), Same -> Bool
is_known_same = |sames, { one, other }| {
	pairs = |same| same.one == one and same.other == other
	sames.any(|same| pairs(same) or pairs({ one: same.other, other: same.one }))
}

## What is known with the registers `written` (as bits) written.
without_written : List(Same), U32 -> List(Same)
without_written = |sames, written|
	sames.drop_if(
		|same| U32.bitwise_and(
			written,
			both(U32.shl_wrap(1, same.one), U32.shl_wrap(1, same.other)),
		) != 0,
	)

## The statements, walked forward, with each copy between two registers
## known to hold one value taken out.
copies_dropped : List(Assembly.Statement), Set(Str) -> List(Assembly.Statement)
copies_dropped = |statements, named| {
	var $kept = List.with_capacity(statements.len())
	var $sames = []
	for statement in statements {
		match statement {
			Mark(label) if !named.contains(label) => {
				$kept = $kept.append(statement)
			}
			Instruction(instruction) =>
				match (copy_of(instruction), accesses(instruction)) {
					(Ok({ to, from }), _) =>
						if to == from or is_known_same($sames, { one: to, other: from }) {
							{}
						} else {
							kept_sames = without_written($sames, U32.shl_wrap(1, to))
							$sames =
								kept_sames
									.keep_if(|same| same.one == from or same.other == from)
									.map(
										|same| {
											one: to,
											other: if same.one == from {
												same.other
											} else {
												same.one
											},
										},
									)
									.concat(kept_sames)
									.append({ one: to, other: from })
							$kept = $kept.append(statement)
						}
					(Err(NotCopy), Ok({ reads: _, writes })) => {
						$sames = without_written($sames, writes)
						$kept = $kept.append(statement)
					}
					(Err(NotCopy), Err(Opaque)) => {
						$sames = []
						$kept = $kept.append(statement)
					}
				}
			_ => {
				$sames = []
				$kept = $kept.append(statement)
			}
		}
	}
	$kept
}

## Whether `trim_moves` makes of `statements` the code of `expected`, for
## the expects.
trims_to : List(Assembly.Statement), List(Assembly.Statement) -> Bool
trims_to = |statements, expected|
	Assembly.assemble(Moves.trim_moves(statements)) == Assembly.assemble(expected)

## The frame's place at `displacement`, for the expects.
slot : I32 -> X86.Mem
slot = |displacement| Based({ base: Rbp, index: NoIndex, displacement })

# A load through rax into r9, rax written again after: one load into r9.
expect {
	trims_to(
		[
			Instruction(MovRegMem({ to: Rax, from: slot(-8) })),
			Instruction(MovRegReg({ to: R9, from: Rax })),
			Instruction(MovRegMem({ to: Rax, from: slot(-16) })),
			Instruction(MovMemReg({ to: slot(-24), from: Rax })),
			Instruction(MovMemReg({ to: slot(-32), from: R9 })),
			Instruction(Ret),
		],
		[
			Instruction(MovRegMem({ to: R9, from: slot(-8) })),
			Instruction(MovRegMem({ to: Rax, from: slot(-16) })),
			Instruction(MovMemReg({ to: slot(-24), from: Rax })),
			Instruction(MovMemReg({ to: slot(-32), from: R9 })),
			Instruction(Ret),
		],
	)
}

# A copy back of a register that holds the value already goes, and a move
# overwritten before it is read goes.
expect {
	trims_to(
		[
			Instruction(MovRegReg({ to: R9, from: Rax })),
			Instruction(MovMemReg({ to: slot(-8), from: Rax })),
			Instruction(MovRegReg({ to: Rax, from: R9 })),
			Instruction(MovRegImm({ to: R10, value: 1 })),
			Instruction(MovRegImm({ to: R10, value: 2 })),
			Instruction(Ret),
		],
		[
			Instruction(MovRegReg({ to: R9, from: Rax })),
			Instruction(MovMemReg({ to: slot(-8), from: Rax })),
			Instruction(MovRegImm({ to: R10, value: 2 })),
			Instruction(Ret),
		],
	)
}

# A label a jump names, a call and a `ret` read every register: nothing
# before them goes.
expect {
	body = [
		Assembly.Statement.Instruction(MovRegMem({ to: Rax, from: slot(-8) })),
		Instruction(MovRegReg({ to: R9, from: Rax })),
		Mark("there"),
		Instruction(MovRegImm({ to: Rax, value: 1 })),
		CallTo("there"),
		Instruction(MovRegImm({ to: Rcx, value: 1 })),
		Instruction(Ret),
	]
	trims_to(body, body)
}

# A load from anywhere but the frame stays, though nothing reads it.
expect {
	body = [
		Assembly.Statement.Instruction(
			MovRegMem({
				to: Rax,
				from: Based({
					base: Rdi,
					index: NoIndex,
					displacement: 0,
				}),
			}),
		),
		Instruction(MovRegImm({ to: Rax, value: 1 })),
		Instruction(Ret),
	]
	trims_to(body, body)
}
