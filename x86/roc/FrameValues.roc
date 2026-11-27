## This module takes out a function's frame traffic that carries nothing:
## the loads of a value a register already holds, and the stores of a value
## no way ever loads back. The lowering moves every value through the frame,
## an instruction at a time, and it works in `rax` and `xmm0`: a value pushed
## onto the bytecode's stack is stored to its place, and by the time the next
## instruction loads it back `rax` often holds something else. Registers'
## renaming keeps a function's busiest places in registers, but a versioned
## loop doubles the places a function has, and the four registers go to the
## busiest of all of them, so most of a fast copy's places stay in the frame.
## `trim_frame_statements` runs once over each function's statements, after Registers, and
## does two things:
##
## - **A LOAD OF A VALUE A REGISTER HOLDS IS A MOVE** (`forward_frame_loads`, forward).
##   Each register and each place of the frame has a value number: a store
##   gives its place the register's number, a copy between registers gives
##   the copy the source's, and any other write gives a register none. So
##   after `mov rax, rbx` and `mov [rbp-472], rax`, a load of `[rbp-472]` is
##   `mov rcx, rbx` even once `rax` is written again, which Forwarding, which
##   knows only the register a store came from, can't see. A place stored
##   from a register that holds an immediate is loaded as the immediate
##   (`mov rax, 2`). A label all of whose jumps come before it (an item
##   read's `done`, a side exit's way back) starts with what every way to it
##   knows; any other label a statement names starts with nothing known.
## - **A STORE NO WAY LOADS BACK IS DROPPED** (`drop_dead_stores`, backward).
##   A place is live where some way from there loads it before it is stored
##   again; a store to a place that isn't live there is taken out. Every
##   jump is followed (to a label this function marks; a jump anywhere else
##   is taken to load every place), and what is live at each label is found
##   by walking the statements backward again until no label's set grows.
##   A `ret` loads nothing. A call loads nothing of this frame: no routine
##   and no function reads a caller's places, since no place's address is
##   ever handed out (below).
##
## **THE RULE, KEPT CONSERVATIVE.** A function is left as it is when any
## instruction names `rbp` but as the base of a plain place (a `lea` of a
## place, a byte of one, an index at `rbp`) or as a register (but the four
## instructions that make the frame and take it down), so no place's address
## is taken and only the four plain moves of `Registers.plain_place` read or
## write the frame. Then nothing but those moves reads or writes a place:
## a store through any other register can't reach the frame, and neither can
## a call. The caller (`Lowering.code_walk`) passes nothing of a program with
## a `try`, as for Registers: a throw lands in a handler that reads the frame
## where no jump shows it. The labels another way may reach (a function's
## entries, which a call or a closure record names) are given as `outside`,
## and start with nothing known. Only the places from `rbp-8` down to
## `rbp-1024`, 8 bytes each, are tracked for the stores: a store to any
## other place stays. The stores' moves are left to Moves, which runs after
## and takes out a move into a register nothing reads once its store is gone.
import Assembly
import Moves
import X86

FrameValues :: [].{

	## One function's statements with the loads a register holds made moves
	## and the stores nothing loads taken out; the statements as they are when
	## the rule above keeps it from either. `outside` says whether a label the
	## function marks may be reached from elsewhere.
	trim_frame_statements : {
		statements : List(Assembly.Statement),
		outside : Str -> Bool,
	} -> List(Assembly.Statement)
	trim_frame_statements = |{ statements, outside }| {
		if !plain_frame(statements) {
			return statements
		}
		drop_dead_stores(forward_frame_loads(statements, outside))
	}
}

## Whether every instruction that names `rbp` names it as the base of a
## plain place, or makes or takes down the frame.
plain_frame : List(Assembly.Statement) -> Bool
plain_frame = |statements|
	statements.all(
		|statement|
			match statement {
				Instruction(instruction) =>
					if is_frame_making(instruction) {
						True
					} else {
						names_rbp = match Moves.accesses(instruction) {
							Ok({ reads, writes }) =>
								U32.bitwise_and(U32.bitwise_or(reads, writes), rbp_unit) != 0
							Err(Opaque) => False
						}
						!names_rbp or is_plain_place_move(instruction)
					}
				_ => True
			},
	)

## `rbp`'s bit in `Moves.accesses`' sets.
rbp_unit : U32
rbp_unit = Moves.register_bit(Rbp)

## The instructions that make a frame and take it down.
is_frame_making : X86.Instruction -> Bool
is_frame_making = |instruction|
	match instruction {
		Push(Rbp) | Pop(Rbp) => True
		MovRegReg({ to: Rbp, from: Rsp }) | MovRegReg({ to: Rsp, from: Rbp }) => True
		_ => False
	}

## Whether an instruction is one of the four plain moves of a place at
## `rbp`, with no index, and names `rbp` only as that place's base.
is_plain_place_move : X86.Instruction -> Bool
is_plain_place_move = |instruction|
	match instruction {
		MovRegMem({ to, from }) => !is_rbp(to) and frame_offset(from).is_ok()
		MovMemReg({ to, from }) => !is_rbp(from) and frame_offset(to).is_ok()
		MovsdLoad({ to: _, from }) => frame_offset(from).is_ok()
		MovsdStore({ to, from: _ }) => frame_offset(to).is_ok()
		_ => False
	}

## Whether a register is `rbp`, the frame's.
is_rbp : X86.Register -> Bool
is_rbp = |register| X86.register_index(register) == X86.register_index(Rbp)

## A memory operand's offset from `rbp`, when it is a place at `rbp` with no
## index.
frame_offset : X86.Mem -> Try(I32, [Elsewhere])
frame_offset = |mem|
	match mem {
		Based({ base, index: NoIndex, displacement }) if is_rbp(base) => Ok(displacement)
		_ => Err(Elsewhere)
	}

# Forward: the value numbers.

## What is known at a point: each register's value number (a general
## register's index, an xmm register's 16 more; 0 for none), each place's,
## and the immediates some numbers are.
Numbering : {
	units : List(U64),
	places : Dict(I32, U64),
	immediates : Dict(U64, I64),
}

## Nothing known: every register's number 0, no place's.
fresh_numbering : Numbering
fresh_numbering = {
	units: List.repeat(0, 32),
	places: Dict.empty(),
	immediates: Dict.empty(),
}

## A general register's place among a numbering's units.
general_unit : X86.Register -> U64
general_unit = |register| X86.register_index(register).to_u64()

## An xmm register's place among a numbering's units.
xmm_unit : X86.Xmm -> U64
xmm_unit = |xmm| 16 + X86.xmm_index(xmm).to_u64()

## A register's value number.
number_of : Numbering, U64 -> U64
number_of = |numbering, unit|
	match numbering.units.get(unit) {
		Ok(number) => number
		Err(_) => crash "FrameValues.number_of: a unit past the 32 registers"
	}

## The numbering with a register's number set.
with_number : Numbering, { unit : U64, number : U64 } -> Numbering
with_number = |numbering, { unit, number }| {
	..numbering,
	units: numbering.units.set(unit, number) ?? crash "FrameValues.with_number: a unit",
}

## The numbering with a place's number set.
with_place : Numbering, { offset : I32, number : U64 } -> Numbering
with_place = |numbering, { offset, number }| {
	..numbering,
	places: numbering.places.insert(offset, number),
}

## The numbering with every register forgotten, the places kept.
registers_forgotten : Numbering -> Numbering
registers_forgotten = |numbering| { ..numbering, units: List.repeat(0, 32) }

## The numbering after an instruction that is no plain move of the frame or
## between registers: what it writes forgotten, and every register when it
## may write any. No place changes: only the plain moves write the frame.
numbering_after : Numbering, X86.Instruction -> Numbering
numbering_after = |numbering, instruction|
	match Moves.accesses(instruction) {
		Ok({ reads: _, writes }) => {
			var $numbering = numbering
			for unit in 0..<32 {
				bit = U32.shl_wrap(1, unit.to_u8_wrap())
				if U32.bitwise_and(writes, bit) != 0 {
					$numbering = with_number($numbering, { unit, number: 0 })
				}
			}
			$numbering
		}
		Err(Opaque) => registers_forgotten(numbering)
	}

## What two ways both know.
meet : Numbering, Numbering -> Numbering
meet = |one, other| {
	var $units = List.with_capacity(32)
	for unit in 0..<32 {
		mine = number_of(one, unit)
		kept = if mine == number_of(other, unit) {
			mine
		} else {
			0
		}
		$units = $units.append(kept)
	}
	var $places = Dict.empty()
	for (offset, number) in one.places.to_list() {
		if other.places.get(offset) == Ok(number) {
			$places = $places.insert(offset, number)
		}
	}
	var $immediates = one.immediates
	for (number, value) in other.immediates.to_list() {
		$immediates = $immediates.insert(number, value)
	}
	{
		units: $units,
		places: $places,
		immediates: $immediates,
	}
}

## The general registers, in the order a holder is looked for, `rsp` and
## `rbp` left out.
holders : List(X86.Register)
holders = [Rax, Rcx, Rdx, Rbx, Rsi, Rdi, R8, R9, R10, R11, R12, R13, R14, R15]

## The xmm registers, in the order a holder is looked for.
xmm_holders : List(X86.Xmm)
xmm_holders = [
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

## A general register holding the value number.
general_holder : Numbering, U64 -> Try(X86.Register, [NotHeld])
general_holder = |numbering, number| {
	holding = |register| number_of(numbering, general_unit(register)) == number
	holders.find_first(holding).map_err(|_| NotHeld)
}

## An xmm register holding the value number.
xmm_holder : Numbering, U64 -> Try(X86.Xmm, [NotHeld])
xmm_holder = |numbering, number| {
	holding = |xmm| number_of(numbering, xmm_unit(xmm)) == number
	xmm_holders.find_first(holding).map_err(|_| NotHeld)
}

## The labels whose every naming is a jump that comes before the label,
## where what each jump knew can be met; not one `outside` reaches.
forward_only : List(Assembly.Statement), (Str -> Bool) -> Set(Str)
forward_only = |statements, outside| {
	var $marks = Dict.empty()
	for (statement, at) in statements.map_with_index(|statement, at| (statement, at)) {
		match statement {
			Mark(label) => {
				$marks = $marks.insert(label, at)
			}
			_ => {}
		}
	}
	var $jumped = Set.empty()
	var $spoiled = Set.empty()
	for (statement, at) in statements.map_with_index(|statement, at| (statement, at)) {
		match statement {
			JmpTo(label) | JccTo({ condition: _, label }) =>
				match $marks.get(label) {
					Ok(marked) if at < marked => {
						$jumped = $jumped.insert(label)
					}
					_ => {
						$spoiled = $spoiled.insert(label)
					}
				}
			CallTo(label) | Distance(label) | LeaTo({ to: _, label }) => {
				$spoiled = $spoiled.insert(label)
			}
			_ => {}
		}
	}
	$jumped.keep_if(|label| !$spoiled.contains(label) and !outside(label))
}

## A load of a general register from a place whose number is known: a move
## from a register holding it, or its immediate, or the load as it was; or
## nothing, when the load's own register holds it.
general_load_instructions : Numbering,
{
	to : X86.Register,
	number : U64,
	load : X86.Instruction,
} -> List(X86.Instruction)
general_load_instructions = |numbering, { to, number, load }| {
	if number_of(numbering, general_unit(to)) == number {
		return []
	}
	match general_holder(numbering, number) {
		Ok(register) => [MovRegReg({ to, from: register })]
		Err(NotHeld) =>
			match xmm_holder(numbering, number) {
				Ok(xmm) => [MovqFromXmm({ to, from: xmm })]
				Err(NotHeld) =>
					match numbering.immediates.get(number) {
						Ok(value) => [MovRegImm({ to, value })]
						Err(_) => [load]
					}
			}
	}
}

## A load of an xmm register from a place whose number is known, as
## `general_load_instructions` makes one.
xmm_load_instructions : Numbering,
{
	to : X86.Xmm,
	number : U64,
	load : X86.Instruction,
} -> List(X86.Instruction)
xmm_load_instructions = |numbering, { to, number, load }| {
	if number_of(numbering, xmm_unit(to)) == number {
		return []
	}
	match xmm_holder(numbering, number) {
		Ok(xmm) => [MovsdRegReg({ to, from: xmm })]
		Err(NotHeld) =>
			match general_holder(numbering, number) {
				Ok(register) => [MovqToXmm({ to, from: register })]
				Err(NotHeld) => [load]
			}
	}
}

## One instruction's walk: what it becomes, the numbering after it, and the
## next fresh number.
Step : {
	made : List(X86.Instruction),
	numbering : Numbering,
	next : U64,
}

## A load of the register at `unit` from the place at `offset`, made by
## `made_of` when the place's number is known.
load_step : Numbering,
{
	unit : U64,
	offset : I32,
	next : U64,
	load : X86.Instruction,
	made_of : U64 -> List(X86.Instruction),
} -> Step
load_step = |numbering, { unit, offset, next, load, made_of }|
	match numbering.places.get(offset) {
		Ok(number) => {
			made: made_of(number),
			numbering: with_number(numbering, { unit, number }),
			next,
		}
		Err(_) => {
			made: [load],
			numbering: with_place(
				with_number(numbering, { unit, number: next }),
				{ offset, number: next },
			),
			next: next + 1,
		}
	}

## A store from the register at `unit` to the place at `offset`.
store_step : Numbering,
{
	unit : U64,
	offset : I32,
	next : U64,
	store : X86.Instruction,
} -> Step
store_step = |numbering, { unit, offset, next, store }| {
	given = copied_number(numbering, { from: unit, next })
	{
		made: [store],
		numbering: with_place(given.numbering, { offset, number: given.number }),
		next: given.next,
	}
}

## A copy from the register at `from` to the one at `to`.
copy_step : Numbering,
{
	from : U64,
	to : U64,
	next : U64,
	copy : X86.Instruction,
} -> Step
copy_step = |numbering, { from, to, next, copy }| {
	given = copied_number(numbering, { from, next })
	{
		made: [copy],
		numbering: with_number(given.numbering, { unit: to, number: given.number }),
		next: given.next,
	}
}

## An instruction's walk forward (but `ret` and a jump by offset, which the
## walk itself takes).
instruction_step : Numbering, { instruction : X86.Instruction, next : U64 } -> Step
instruction_step = |numbering, { instruction, next }| {
	unchanged = {
		made: [instruction],
		numbering: numbering_after(numbering, instruction),
		next,
	}
	match instruction {
		MovRegMem({ to, from }) =>
			match frame_offset(from) {
				Ok(offset) => load_step(
					numbering,
					{
						unit: general_unit(to),
						offset,
						next,
						load: instruction,
						made_of: |number|
							general_load_instructions(numbering, { to, number, load: instruction }),
					},
				)
				Err(Elsewhere) => unchanged
			}
		MovsdLoad({ to, from }) =>
			match frame_offset(from) {
				Ok(offset) => load_step(
					numbering,
					{
						unit: xmm_unit(to),
						offset,
						next,
						load: instruction,
						made_of: |number|
							xmm_load_instructions(numbering, { to, number, load: instruction }),
					},
				)
				Err(Elsewhere) => unchanged
			}
		MovMemReg({ to, from }) =>
			match frame_offset(to) {
				Ok(offset) => store_step(
					numbering,
					{
						unit: general_unit(from),
						offset,
						next,
						store: instruction,
					},
				)
				Err(Elsewhere) => { made: [instruction], numbering, next }
			}
		MovsdStore({ to, from }) =>
			match frame_offset(to) {
				Ok(offset) => store_step(
					numbering,
					{
						unit: xmm_unit(from),
						offset,
						next,
						store: instruction,
					},
				)
				Err(Elsewhere) => { made: [instruction], numbering, next }
			}
		MovRegReg({ to, from }) if !is_frame_making(instruction) => copy_step(
			numbering,
			{
				from: general_unit(from),
				to: general_unit(to),
				next,
				copy: instruction,
			},
		)
		MovqToXmm({ to, from }) => copy_step(
			numbering,
			{
				from: general_unit(from),
				to: xmm_unit(to),
				next,
				copy: instruction,
			},
		)
		MovqFromXmm({ to, from }) => copy_step(
			numbering,
			{
				from: xmm_unit(from),
				to: general_unit(to),
				next,
				copy: instruction,
			},
		)
		MovsdRegReg({ to, from }) => copy_step(
			numbering,
			{
				from: xmm_unit(from),
				to: xmm_unit(to),
				next,
				copy: instruction,
			},
		)
		MovRegImm({ to, value }) => {
			numbered = with_number(numbering, { unit: general_unit(to), number: next })
			{
				made: [instruction],
				numbering: { ..numbered, immediates: numbered.immediates.insert(next, value) },
				next: next + 1,
			}
		}
		Pop(Rbp) => { made: [instruction], numbering: fresh_numbering, next }
		_ => unchanged
	}
}

## The statements with each load of a place whose value a register holds
## made a move from it (or nothing, when the load's own register holds it),
## or the immediate it is.
forward_frame_loads : List(Assembly.Statement), (Str -> Bool) -> List(Assembly.Statement)
forward_frame_loads = |statements, outside| {
	named = Assembly.named_labels(statements)
	metable = forward_only(statements, outside)
	var $out = List.with_capacity(statements.len())
	var $numbering = fresh_numbering
	var $next = 1
	var $falls = True
	var $waiting = Dict.empty()
	for statement in statements {
		match statement {
			Mark(label) => {
				$out = $out.append(statement)
				$numbering = numbering_at_label(
					$numbering,
					{
						label,
						metable: metable.contains(label),
						reached: named.contains(label) or outside(label),
						falls: $falls,
						waiting: $waiting,
					},
				)
				$falls = True
			}
			JmpTo(label) => {
				$out = $out.append(statement)
				if metable.contains(label) {
					$waiting = waiting_with($waiting, { label, numbering: $numbering })
				}
				$falls = False
			}
			JccTo({ condition: _, label }) => {
				$out = $out.append(statement)
				if metable.contains(label) {
					$waiting = waiting_with($waiting, { label, numbering: $numbering })
				}
			}
			Instruction(Ret) | Instruction(Jmp(_)) => {
				$out = $out.append(statement)
				$numbering = fresh_numbering
				$falls = False
			}
			Instruction(instruction) => {
				step = instruction_step($numbering, { instruction, next: $next })
				$out = $out.concat(step.made.map(|made| Instruction(made)))
				$numbering = step.numbering
				$next = step.next
				$falls = True
			}
			CallTo(_) => {
				$out = $out.append(statement)
				$numbering = registers_forgotten($numbering)
				$falls = True
			}
			LeaTo({ to, label: _ }) => {
				$out = $out.append(statement)
				$numbering = with_number($numbering, { unit: general_unit(to), number: 0 })
				$falls = True
			}
			_ => {
				$out = $out.append(statement)
				$numbering = fresh_numbering
				$falls = True
			}
		}
	}
	$out
}

## The numbering at a label: what every way to it knew, met, for one whose
## jumps all come before it; nothing, for one another way may reach; what
## the way that falls to it knew, for one nothing names.
numbering_at_label : Numbering,
{
	label : Str,
	metable : Bool,
	reached : Bool,
	falls : Bool,
	waiting : Dict(Str, Numbering),
} -> Numbering
numbering_at_label = |numbering, { label, metable, reached, falls, waiting }| {
	if !metable {
		return if reached {
			fresh_numbering
		} else {
			numbering
		}
	}
	brought = waiting.get(label) ?? fresh_numbering
	if falls {
		meet(brought, numbering)
	} else {
		brought
	}
}

## The numberings labels wait with, a jump to `label` with `numbering` met
## into what every jump to it so far knew.
waiting_with : Dict(Str, Numbering), { label : Str, numbering : Numbering } -> Dict(Str, Numbering)
waiting_with = |waiting, { label, numbering }| {
	met = match waiting.get(label) {
		Ok(before) => meet(before, numbering)
		Err(_) => numbering
	}
	waiting.insert(label, met)
}

## The value number a copy from `from` carries, one made for it when it has
## none.
copied_number : Numbering,
{ from : U64, next : U64 } -> {
	numbering : Numbering,
	number : U64,
	next : U64,
}
copied_number = |numbering, { from, next }| {
	number = number_of(numbering, from)
	if number != 0 {
		{ numbering, number, next }
	} else {
		{
			numbering: with_number(numbering, { unit: from, number: next }),
			number: next,
			next: next + 1,
		}
	}
}

# Backward: the stores nothing loads.

## The tracked places live at a point, a bit each: the place at
## `rbp - 8 * (k + 1)` is bit `k`, `low` the first 64 and `high` the next.
Live : { low : U64, high : U64 }

## No tracked place live.
all_dead : Live
all_dead = { low: 0, high: 0 }

## Every tracked place live.
all_live : Live
all_live = { low: 0xFFFF_FFFF_FFFF_FFFF, high: 0xFFFF_FFFF_FFFF_FFFF }

## The bit of a tracked place: from `rbp-8` to `rbp-1024`, 8 bytes each.
place_bit : I32 -> Try(Live, [Untracked])
place_bit = |offset| {
	depth = 0 - offset
	if offset >= 0 or depth > 1024 or (depth // 8) * 8 != depth {
		return Err(Untracked)
	}
	bit_index = (depth // 8 - 1).to_u8_wrap()
	if bit_index < 64 {
		Ok({ low: U64.shl_wrap(1, bit_index), high: 0 })
	} else {
		Ok({ low: 0, high: U64.shl_wrap(1, bit_index - 64) })
	}
}

## The places live in either.
join_live : Live, Live -> Live
join_live = |one, other| {
	low: U64.bitwise_or(one.low, other.low),
	high: U64.bitwise_or(one.high, other.high),
}

## The places live but those of `bit`.
live_without : Live, Live -> Live
live_without = |live, bit| {
	low: U64.bitwise_and(live.low, U64.bitwise_xor(bit.low, 0xFFFF_FFFF_FFFF_FFFF)),
	high: U64.bitwise_and(live.high, U64.bitwise_xor(bit.high, 0xFFFF_FFFF_FFFF_FFFF)),
}

## Whether any place of `bit` is live.
holds_any : Live, Live -> Bool
holds_any = |live, bit|
	U64.bitwise_and(live.low, bit.low) != 0 or U64.bitwise_and(live.high, bit.high) != 0

## A plain move's place and whether it stores to it.
place_move : X86.Instruction -> Try({ offset : I32, stores : Bool }, [NotPlain])
place_move = |instruction|
	match instruction {
		MovRegMem({ to: _, from }) | MovsdLoad({ to: _, from }) =>
			frame_offset(from).map_ok(|offset| { offset, stores: False }).map_err(|_| NotPlain)
		MovMemReg({ to, from: _ }) | MovsdStore({ to, from: _ }) =>
			frame_offset(to).map_ok(|offset| { offset, stores: True }).map_err(|_| NotPlain)
		_ => Err(NotPlain)
	}

## The places live before a statement that is no plain move, given those
## live after it and at each label: a jump's are its label's (every place,
## for a label this function doesn't mark), a conditional jump's both, none
## before a `ret`, and every one before a jump by offset or data.
live_before_flow : Assembly.Statement,
{
	after : Live,
	labels : Dict(Str, Live),
	marked : Set(Str),
} -> Live
live_before_flow = |statement, { after, labels, marked }| {
	at_label = |label|
		if marked.contains(label) {
			labels.get(label) ?? all_dead
		} else {
			all_live
		}
	match statement {
		JmpTo(label) => at_label(label)
		JccTo({ condition: _, label }) => join_live(after, at_label(label))
		Instruction(Ret) => all_dead
		Instruction(Jmp(_)) | Instruction(Jcc(_)) => all_live
		Data(_) | Distance(_) => all_live
		_ => after
	}
}

## The places live before a plain move, given those live after it.
live_before_move : Live, { offset : I32, stores : Bool } -> Live
live_before_move = |after, { offset, stores }|
	match place_bit(offset) {
		Ok(bit) =>
			if stores {
				live_without(after, bit)
			} else {
				join_live(after, bit)
			}
		Err(Untracked) => after
	}

## The places live at each label a jump names, found by walking backward
## again until no label's set grows.
settle_labels : List(Assembly.Statement),
{
	marked : Set(Str),
	jumped : Set(Str),
} -> Dict(Str, Live)
settle_labels = |statements, { marked, jumped }| {
	var $labels = Dict.empty()
	for _ in 0..<statements.len() {
		var $live = all_live
		var $grown = False
		for back in 0..<statements.len() {
			at = statements.len() - 1 - back
			statement = statements.get(at) ?? crash "FrameValues.settle_labels: a statement"
			match statement {
				Mark(label) if jumped.contains(label) => {
					known = $labels.get(label) ?? all_dead
					now = join_live(known, $live)
					if now != known {
						$labels = $labels.insert(label, now)
						$grown = True
					}
				}
				Mark(_) => {}
				Instruction(instruction) =>
					match place_move(instruction) {
						Ok(move) => {
							$live = live_before_move($live, move)
						}
						Err(NotPlain) => {
							$live = live_before_flow(
								statement,
								{ after: $live, labels: $labels, marked },
							)
						}
					}
				_ => {
					$live = live_before_flow(statement, { after: $live, labels: $labels, marked })
				}
			}
		}
		if !$grown {
			return $labels
		}
	}
	crash "FrameValues.settle_labels: what is live at the labels never settled"
}

## The statements with each store to a tracked place that isn't live after
## it taken out.
drop_dead_stores : List(Assembly.Statement) -> List(Assembly.Statement)
drop_dead_stores = |statements| {
	var $marked = Set.empty()
	var $jumped = Set.empty()
	for statement in statements {
		match statement {
			Mark(label) => {
				$marked = $marked.insert(label)
			}
			JmpTo(label) | JccTo({ condition: _, label }) => {
				$jumped = $jumped.insert(label)
			}
			_ => {}
		}
	}
	labels = settle_labels(statements, { marked: $marked, jumped: $jumped })
	var $kept = List.with_capacity(statements.len())
	var $live = all_live
	for back in 0..<statements.len() {
		at = statements.len() - 1 - back
		statement = statements.get(at) ?? crash "FrameValues.drop_dead_stores: a statement"
		match statement {
			Instruction(instruction) =>
				match place_move(instruction) {
					Ok(move) => {
						dead = match place_bit(move.offset) {
							Ok(bit) => move.stores and !holds_any($live, bit)
							Err(Untracked) => False
						}
						if !dead {
							$kept = $kept.append(statement)
						}
						$live = live_before_move($live, move)
					}
					Err(NotPlain) => {
						$kept = $kept.append(statement)
						$live = live_before_flow(
							statement,
							{ after: $live, labels, marked: $marked },
						)
					}
				}
			Mark(_) => {
				$kept = $kept.append(statement)
			}
			_ => {
				$kept = $kept.append(statement)
				$live = live_before_flow(statement, { after: $live, labels, marked: $marked })
			}
		}
	}
	reverse_kept($kept)
}

## The backward walk's kept statements in the order they run.
reverse_kept : List(Assembly.Statement) -> List(Assembly.Statement)
reverse_kept = |statements| {
	var $out = List.with_capacity(statements.len())
	for back in 0..<statements.len() {
		at = statements.len() - 1 - back
		$out = $out.append(statements.get(at) ?? crash "FrameValues.reverse_kept: a statement")
	}
	$out
}

## The frame's place at `displacement`, for the expects.
slot : I32 -> X86.Mem
slot = |displacement| Based({ base: Rbp, index: NoIndex, displacement })

## Whether `trim_frame_statements` makes of `statements` the code of `expected`.
trims_to : List(Assembly.Statement), List(Assembly.Statement) -> Bool
trims_to = |statements, expected|
	Assembly.assemble(FrameValues.trim_frame_statements({ statements, outside: |_| False }))
		== Assembly.assemble(expected)

## `rcx` plus `rdx` into `rcx`, for the expects.
sum : X86.Instruction
sum = Alu({
	operation: Add,
	to: Rcx,
	from: Rdx,
})

expect {
	# A copy's number survives the copy's register being written: the load
	# is a move from the register copied, and both stores go, since nothing
	# loads either place again before the `ret`.
	body = [
		Assembly.Statement.Instruction(MovRegReg({ to: Rax, from: Rbx })),
		Instruction(MovMemReg({ to: slot(-16), from: Rax })),
		Instruction(MovRegImm({ to: Rax, value: 2 })),
		Instruction(MovMemReg({ to: slot(-8), from: Rax })),
		Instruction(MovRegMem({ to: Rcx, from: slot(-16) })),
		Instruction(MovRegMem({ to: Rdx, from: slot(-8) })),
		Instruction(sum),
		Instruction(MovRegReg({ to: Rax, from: Rcx })),
		Instruction(Ret),
	]
	expected = [
		Assembly.Statement.Instruction(MovRegReg({ to: Rax, from: Rbx })),
		Instruction(MovRegImm({ to: Rax, value: 2 })),
		Instruction(MovRegReg({ to: Rcx, from: Rbx })),
		Instruction(MovRegReg({ to: Rdx, from: Rax })),
		Instruction(sum),
		Instruction(MovRegReg({ to: Rax, from: Rcx })),
		Instruction(Ret),
	]
	trims_to(body, expected)
}

expect {
	# A store before a jump to a label every place is live at stays; a store
	# overwritten on every way goes, and so does one whose one load, on a
	# jump's way, became a move from the register stored.
	body = [
		Assembly.Statement.Instruction(MovMemReg({ to: slot(-8), from: Rax })),
		JccTo({ condition: E, label: "exit" }),
		Instruction(MovMemReg({ to: slot(-8), from: Rcx })),
		Instruction(MovMemReg({ to: slot(-16), from: Rcx })),
		Instruction(MovMemReg({ to: slot(-16), from: Rdx })),
		JmpTo("elsewhere"),
		Mark("exit"),
		Instruction(MovRegMem({ to: Rsi, from: slot(-8) })),
		Instruction(Ret),
	]
	expected = [
		Assembly.Statement.JccTo({ condition: E, label: "exit" }),
		Instruction(MovMemReg({ to: slot(-8), from: Rcx })),
		Instruction(MovMemReg({ to: slot(-16), from: Rdx })),
		JmpTo("elsewhere"),
		Mark("exit"),
		Instruction(MovRegReg({ to: Rsi, from: Rax })),
		Instruction(Ret),
		Mark("elsewhere"),
	]
	# "elsewhere" is marked past the end so the code assembles: the jump to
	# it is a jump this function marks, and nothing loads after it.
	Assembly.assemble(
		FrameValues.trim_frame_statements({
			statements: body.append(Mark("elsewhere")),
			outside: |_| False,
		}),
	)
		== Assembly.assemble(expected)
}

expect {
	# A function that takes a place's address is left as it is.
	body = [
		Assembly.Statement.Instruction(MovMemReg({ to: slot(-8), from: Rax })),
		Instruction(Lea({ to: Rdi, from: slot(-8) })),
		Instruction(Ret),
	]
	trims_to(body, body)
}
