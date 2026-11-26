## This module takes out the register moves the lowered code doesn't need.
## The lowering moves each value through a register of its own choosing
## (`rax` for most), so a value read from the frame into one of
## Registers' spare registers is `mov rax, [rbp-48]` then `mov r9, rax`, and
## a sum stored back is `mov rax, r9`, the store, and `mov r9, rax` again.
## `trim_moves` walks the whole program twice, the runtime's routines too,
## and does five things, each of which leaves what every register the code
## reads holds as it was:
##
## - **A copy between two registers that already hold one value is
##   dropped** (`copies_dropped`, forward): after `mov r9, rax`, a
##   `mov rax, r9` or a second `mov r9, rax` copies nothing.
## - **A WHOLE NUMBER MADE ONCE: a `cvttsd2si` into a register that already
##   holds what it would make is dropped** (`copies_dropped` too): after
##   `cvttsd2si rcx, xmm0`, with neither written since, a second one of
##   `xmm0`, or of a register known to hold `xmm0`'s value, makes nothing
##   new. So `x[i] + y[i]` makes `i` an integer once.
## - **A move into a register nothing reads before it is written again is
##   dropped** (`dead_dropped`, backward): `mov r9, rax` then `mov r9, rcx`.
## - **A move through a register nothing reads after is joined into
##   one** (`dead_dropped` too): `mov rax, [rbp-48]` then `mov r9, rax`
##   becomes `mov r9, [rbp-48]`, when `rax` is written before it is read
##   again. So is a move into an operation's source (`mov rcx, rbx` then
##   `add rax, rcx` is `add rax, rbx`; an immediate moved in is the
##   operation's immediate) or into a compare's first, which it doesn't
##   write.
## - **A register stepped through another is stepped in place**
##   (`stepped_in_place`): `mov rax, r9`, `add rax, 1`, `mov r9, rax` is
##   `add r9, 1`, when nothing reads `rax` after, as an integer counter's
##   step lowers.
##
## **THE RULE, KEPT CONSERVATIVE.** What a register holds is known to be
## unread by walking backward over the instructions `accesses` names every
## register of, as read or written (an operand of memory reads its base and
## index), and over jumps: a jump reads what its label reads, and a
## conditional jump that and what the way it falls to reads.
## `settled_labels` finds what each label reads by walking the program
## backward again until no label's set grows. Any other instruction (a call,
## a `ret`, a `syscall`, a 64-bit divide, `rep movsb`) and any other statement (a
## call of a label, a `lea` of one, data) reads every register, and so does
## a label whose address is taken (by a call, a `lea` or a distance), so
## nothing is taken out that a way the walk can't follow may read. Two moves
## are joined only with no label a statement names between them (the
## lowering marks every instruction's place, and a label nothing names is
## passed by, as Forwarding passes it), and a copy is known only along a
## straight run, which goes on past a conditional jump (it writes no
## register, so the way that falls through holds what was known before
## it). Lowering runs Jumps before this, so the labels Jumps leaves unnamed
## (an item read's `done`, once its `jmp done` is gone) end no straight
## run. `rsp` and `rbp` are always read. Only plain moves are
## taken out or joined: into a general or an xmm register, from a
## register, an immediate, an address (`lea`) or a place at `rbp`; a load
## from anywhere else stays, so no load that could fault is lost. No store
## to memory is taken out, so the frame holds what it held before. The
## upper half of an xmm register is never read by the lowered code (every
## operation on doubles is scalar), so a `movq` into one counts as a copy
## of the whole.
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

## Whether an operation is a compare, which writes no register.
is_compare : X86.AluOperation -> Bool
is_compare = |operation|
	match operation {
		Cmp => True
		_ => False
	}

## The register an operation writes: none for a compare.
written_unless_compare : X86.AluOperation, X86.Register -> U32
written_unless_compare = |operation, to|
	match operation {
		Cmp => 0
		_ => general_unit(to)
	}

## The registers an instruction reads and writes, for the instructions whose
## every register is named; `Opaque` for the rest (a call, a `ret`, a
## `syscall`, a 64-bit divide, `rep movsb`, a jump), which may read any
## register.
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
		# `div r32` reads edx:eax and its divisor, and writes eax and edx,
		# each zero-extended into its whole register.
		Div32(register) => Ok({
			reads: both(both(general_unit(Rax), general_unit(Rdx)), general_unit(register)),
			writes: both(general_unit(Rax), general_unit(Rdx)),
		})
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
		Cmov({ condition: _, to, from }) => Ok({
			reads: both(general_unit(to), general_unit(from)),
			writes: general_unit(to),
		})
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
		(MovRegReg({ to: _, from: source }), MovqToXmm({ to, from })) if reads_through(from) =>
			Ok(MovqToXmm({ to, from: source }))
		# An operation's source read through the register: from the source
		# itself, or as an immediate.
		(MovRegReg({ to: _, from: source }), Alu({ operation, to, from }))
		if reads_through(from) and !reads_through(to) =>
			Ok(Alu({ operation, to, from: source }))
		(MovRegImm({ to: _, value }), Alu({ operation, to, from }))
		if reads_through(from) and !reads_through(to) and fits_i32(value) =>
			Ok(AluImm({ operation, to, value: value.to_i32_wrap() }))
		# A compare writes neither register, so its first may be read
		# through one too.
		(MovRegReg({ to: _, from: source }), Alu({ operation: Cmp, to, from }))
		if reads_through(to) and !reads_through(from) =>
			Ok(Alu({ operation: Cmp, to: source, from }))
		_ => Err(Apart)
	}
}

## Whether an immediate fits an instruction's sign-extended 32 bits.
fits_i32 : I64 -> Bool
fits_i32 = |value| value >= -2147483648 and value <= 2147483647

## The statements, walked backward, with each plain move whose register
## nothing reads after taken out, and each pair `one_move_of` joins made one.
dead_dropped : List(Assembly.Statement), Set(Str) -> List(Assembly.Statement)
dead_dropped = |statements, named| {
	labels = settled_labels(statements, named)
	var $kept = List.with_capacity(statements.len())
	var $read = every_unit
	# The instruction kept just after this one, and what is read after it;
	# and the one kept after that, in a straight run.
	var $next = NoNext
	var $second = NoNext
	for back in 0..<statements.len() {
		at = statements.len() - 1 - back
		statement = statements.get(at) ?? crash "Moves.dead_dropped: a statement"
		match statement {
			Mark(label) if !named.contains(label) => {
				$kept = $kept.append(statement)
			}
			Mark(_) => {
				$kept = $kept.append(statement)
				$next = NoNext
				$second = NoNext
			}
			Instruction(instruction) => {
				stepped = match ($next, $second) {
					(Next(following), Next(last)) => stepped_in_place(
						instruction,
						{ following, last },
					)
					_ => Err(Apart)
				}
				joining = match ($next, stepped) {
					(_, Ok(_)) => Err(Apart)
					(Next(following), _) => one_move_of(instruction, following).map_ok(
						|made| { made, after: following.after },
					)
					(NoNext, _) => Err(Apart)
				}
				match (stepped, joining) {
					(Ok({ made, after }), _) => {
						# The operation and the move back, kept already, go.
						$kept = drop_last_instruction(drop_last_instruction($kept))
						$kept = $kept.append(Instruction(made))
						$next = Next({ next: made, after })
						$second = NoNext
						$read = read_before(made, after)
					}
					(_, Ok({ made, after })) => {
						$kept = drop_last_instruction($kept).append(Instruction(made))
						$next = Next({ next: made, after })
						$read = read_before(made, after)
					}
					_ => {
						unread = match accesses(instruction) {
							Ok(
								{ reads: _, writes },
							) => is_plain_move(instruction) and U32.bitwise_and(writes, $read) == 0
							Err(Opaque) => False
						}
						if !unread {
							$kept = $kept.append(statement)
							$second = $next
							$next = Next({ next: instruction, after: $read })
							$read = read_before(instruction, $read)
						}
					}
				}
			}
			_ => {
				$kept = $kept.append(statement)
				$next = NoNext
				$second = NoNext
				$read = read_before_flow(statement, { after: $read, labels })
			}
		}
	}
	reverse_statements($kept)
}

## A register stepped in place through another, `mov t, s`, an operation on
## `t` and `mov s, t`, made the one operation on `s`, when nothing reads `t`
## after the last (`last.after`) and the operation's source isn't `t`:
## `mov rax, r9; add rax, 1; mov r9, rax` is `add r9, 1`. The flags are the
## operation's either way.
stepped_in_place : X86.Instruction,
{
	following : { next : X86.Instruction, after : U32 },
	last : { next : X86.Instruction, after : U32 },
} -> Try({ made : X86.Instruction, after : U32 }, [Apart])
stepped_in_place = |first, { following, last }| {
	(through, source) = match first {
		MovRegReg({ to, from }) => (to, from)
		_ => return Err(Apart)
	}
	same = |one, other| X86.register_index(one) == X86.register_index(other)
	moved_back = match last.next {
		MovRegReg({ to, from }) => same(to, source) and same(from, through)
		_ => False
	}
	unread = U32.bitwise_and(last.after, general_unit(through)) == 0
	if !moved_back or !unread or same(through, source) or same(through, Rsp) or same(through, Rbp) {
		return Err(Apart)
	}
	made = match following.next {
		Alu(
			{ operation, to, from },
		) if !is_compare(operation) and same(to, through) and !same(from, through) =>
			Ok(Alu({ operation, to: source, from }))
		AluImm({ operation, to, value }) if !is_compare(operation) and same(to, through) =>
			Ok(AluImm({ operation, to: source, value }))
		_ => Err(Apart)
	}?
	Ok({ made, after: last.after })
}

## What a backward walk knows of the labels: those a statement names; those
## among them whose address is taken, named by a call, a `lea` or a distance, where any
## register may be read; and what is read at each of the others, which only
## jumps reach.
Labels : {
	named : Set(Str),
	addressed : Set(Str),
	reads : Dict(Str, U32),
}

## The labels a call, a `lea` or a distance names.
addressed_labels : List(Assembly.Statement) -> Set(Str)
addressed_labels = |statements| {
	var $addressed = Set.empty()
	for statement in statements {
		match statement {
			CallTo(label) | Distance(label) | LeaTo({ to: _, label }) => {
				$addressed = $addressed.insert(label)
			}
			_ => {}
		}
	}
	$addressed
}

## The registers read at a label: every one at a label whose address is taken, else what the walk
## has found so far (none, before it has passed the label).
label_reads : Labels, Str -> U32
label_reads = |labels, label|
	if labels.addressed.contains(label) {
		every_unit
	} else {
		match labels.reads.get(label) {
			Ok(reads) => reads
			Err(_) => 0
		}
	}

## The registers read before a statement that is neither an instruction nor
## a label, given those read after it: a jump's are its label's, a
## conditional jump's both, and every one before anything else (a call, a
## `lea` of a label, data).
read_before_flow : Assembly.Statement, { after : U32, labels : Labels } -> U32
read_before_flow = |statement, { after, labels }|
	match statement {
		JmpTo(label) => label_reads(labels, label)
		JccTo({ condition: _, label }) => both(after, label_reads(labels, label))
		_ => every_unit
	}

## What is read at each label only jumps reach, found by walking the
## statements backward again until no label's set grows: each set only
## grows, and a walk that grows none has found them all.
settled_labels : List(Assembly.Statement), Set(Str) -> Labels
settled_labels = |statements, named| {
	var $labels = {
		named,
		addressed: addressed_labels(statements),
		reads: Dict.empty(),
	}
	for _ in 0..<statements.len() {
		var $read = every_unit
		var $grown = False
		for back in 0..<statements.len() {
			at = statements.len() - 1 - back
			statement = statements.get(at) ?? crash "Moves.settled_labels: a statement"
			match statement {
				Mark(label) =>
					if named.contains(label) and !$labels.addressed.contains(label) {
						known = label_reads($labels, label)
						now = both(known, $read)
						if now != known {
							$labels = { ..$labels, reads: $labels.reads.insert(label, now) }
							$grown = True
						}
					}
				Instruction(instruction) => {
					$read = read_before(instruction, $read)
				}
				_ => {
					$read = read_before_flow(statement, { after: $read, labels: $labels })
				}
			}
		}
		if !$grown {
			return $labels
		}
	}
	crash "Moves.settled_labels: what is read at the labels never settled"
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

## A whole number made of a double (`cvttsd2si`): the general register
## `to` holds the integer part of the xmm register `from`, by their units'
## numbers.
Truncated : { to : U8, from : U8 }

## What is known with the registers `written` (as bits) written.
truncations_without : List(Truncated), U32 -> List(Truncated)
truncations_without = |truncations, written|
	truncations.drop_if(
		|truncated| U32.bitwise_and(
			written,
			both(U32.shl_wrap(1, truncated.to), U32.shl_wrap(1, truncated.from)),
		) != 0,
	)

## A `cvttsd2si` whose register already holds what it would make: the same
## register made of the same xmm register, or of one known to hold its value.
is_known_truncation : { truncations : List(Truncated), sames : List(Same) }, X86.Instruction -> Bool
is_known_truncation = |{ truncations, sames }, instruction|
	match instruction {
		Cvttsd2si({ to, from }) => {
			to_unit = X86.register_index(to)
			from_unit = 16 + X86.xmm_index(from)
			same_source = |source| {
				known = is_known_same(sames, { one: source, other: from_unit })
				source == from_unit or known
			}
			truncations.any(|truncated| truncated.to == to_unit and same_source(truncated.from))
		}
		_ => False
	}

## The truncation an instruction makes, if it is a `cvttsd2si`.
truncation_made : X86.Instruction -> List(Truncated)
truncation_made = |instruction|
	match instruction {
		Cvttsd2si({ to, from }) => [{ to: X86.register_index(to), from: 16 + X86.xmm_index(from) }]
		_ => []
	}

## The statements, walked forward, with each copy between two registers
## known to hold one value taken out, and each `cvttsd2si` into a register
## that already holds what it would make. What is known holds along a
## straight run and past a conditional jump, which writes no register, to
## the way that falls through.
copies_dropped : List(Assembly.Statement), Set(Str) -> List(Assembly.Statement)
copies_dropped = |statements, named| {
	var $kept = List.with_capacity(statements.len())
	var $sames = []
	var $truncations = []
	for statement in statements {
		match statement {
			Mark(label) if !named.contains(label) => {
				$kept = $kept.append(statement)
			}
			JccTo(_) => {
				$kept = $kept.append(statement)
			}
			Instruction(instruction) =>
				match (copy_of(instruction), accesses(instruction)) {
					(Ok({ to, from }), _) =>
						if to == from or is_known_same($sames, { one: to, other: from }) {
							{}
						} else {
							$truncations = truncations_without($truncations, U32.shl_wrap(1, to))
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
						known = { truncations: $truncations, sames: $sames }
						if !is_known_truncation(known, instruction) {
							$sames = without_written($sames, writes)
							made = truncation_made(instruction)
							$truncations = truncations_without($truncations, writes).concat(made)
							$kept = $kept.append(statement)
						}
					}
					(Err(NotCopy), Err(Opaque)) => {
						$sames = []
						$truncations = []
						$kept = $kept.append(statement)
					}
				}
			_ => {
				$sames = []
				$truncations = []
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

# A second `cvttsd2si` of the same value into the same register goes, past
# a conditional jump, which writes no register; with that register written
# between, it stays.
expect {
	head = [
		Assembly.Statement.Instruction(MovqToXmm({ to: Xmm0, from: R9 })),
		Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
		JccTo({ condition: Ae, label: "out" }),
		Instruction(MovRegReg({ to: Rax, from: R9 })),
		Instruction(MovqToXmm({ to: Xmm1, from: Rax })),
	]
	tail = [
		Assembly.Statement.Instruction(MovMemReg({ to: slot(-8), from: Rcx })),
		Instruction(Ret),
		Mark("out"),
		Instruction(Ret),
	]
	again = Assembly.Statement.Instruction(Cvttsd2si({ to: Rcx, from: Xmm1 }))
	stepped = Instruction(
		AluImm({
			operation: Add,
			to: Rcx,
			value: 1,
		}),
	)
	spoiled = head.append(stepped).append(again).concat(tail)
	trims_to(head.append(again).concat(tail), head.concat(tail)) and trims_to(spoiled, spoiled)
}

# A jump reads what its label reads: `rax`, read at the loop's top, stays
# though the way that falls through writes it again, and `rcx`, read on
# neither way, goes.
expect {
	trims_to(
		[
			Mark("top"),
			Instruction(MovMemReg({ to: slot(-16), from: Rax })),
			Instruction(MovRegImm({ to: Rax, value: 1 })),
			Instruction(MovRegImm({ to: Rcx, value: 2 })),
			JccTo({ condition: E, label: "top" }),
			Instruction(MovRegImm({ to: Rax, value: 3 })),
			JmpTo("top"),
		],
		[
			Mark("top"),
			Instruction(MovMemReg({ to: slot(-16), from: Rax })),
			Instruction(MovRegImm({ to: Rax, value: 1 })),
			JccTo({ condition: E, label: "top" }),
			Instruction(MovRegImm({ to: Rax, value: 3 })),
			JmpTo("top"),
		],
	)
}

# A call and a `ret` read every register: nothing before them goes.
expect {
	body = [
		Assembly.Statement.Instruction(MovRegImm({ to: Rcx, value: 1 })),
		CallTo("routine"),
		Instruction(MovRegImm({ to: Rdx, value: 1 })),
		Instruction(Ret),
		Mark("routine"),
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
