## This module takes out a function's frame traffic that carries nothing:
## the loads of a value a register already holds, and the stores of a value
## no way ever loads back. The lowering moves every value through the frame,
## an instruction at a time, and it works in `rax` and `xmm0`: a value pushed
## onto the bytecode's stack is stored to its place, and by the time the next
## instruction loads it back `rax` often holds something else. Registers'
## renaming keeps a function's busiest places in registers, but a versioned
## loop doubles the places a function has, and the four registers go to the
## busiest of all of them, so most of a fast copy's places stay in the frame.
## `trimmed` runs once over each function's statements, after Registers, and
## does two things:
##
## - **A LOAD OF A VALUE A REGISTER HOLDS IS A MOVE** (`forwarded`, forward).
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
## - **A STORE NO WAY LOADS BACK IS DROPPED** (`dead_dropped`, backward).
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
	trimmed : {
		statements : List(Assembly.Statement),
		outside : Str -> Bool,
	} -> List(Assembly.Statement)
	trimmed = |{ statements, outside }| {
		if !plain_frame(statements) {
			return statements
		}
		dead_dropped(forwarded(statements, outside))
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

# ── Forward: the value numbers ─────────────────────────────────────────────

## What is known at a point: each register's value number (a general
## register's index, an xmm register's 16 more; 0 for none), each place's,
## and the immediates some numbers are.
Known : {
	units : List(U64),
	places : Dict(I32, U64),
	immediates : Dict(U64, I64),
}

nothing_known : Known
nothing_known = { units: List.repeat(0, 32), places: Dict.empty(), immediates: Dict.empty() }

general_unit : X86.Register -> U64
general_unit = |register| X86.register_index(register).to_u64()

xmm_unit : X86.Xmm -> U64
xmm_unit = |xmm| 16 + X86.xmm_index(xmm).to_u64()

## A register's value number.
number_of : Known, U64 -> U64
number_of = |known, unit| known.units.get(unit) ?? 0

## What is known with a register's number set.
with_number : Known, U64, U64 -> Known
with_number = |known, unit, number| {
	..known,
	units: known.units.set(unit, number) ?? crash "FrameValues.with_number: a unit",
}

## What is known with every register forgotten, the places kept.
registers_forgotten : Known -> Known
registers_forgotten = |known| { ..known, units: List.repeat(0, 32) }

## What is known after an instruction that is no plain move of the frame or
## between registers: what it writes forgotten, and every register when it
## may write any. No place changes: only the plain moves write the frame.
after_other : Known, X86.Instruction -> Known
after_other = |known, instruction|
	match Moves.accesses(instruction) {
		Ok({ reads: _, writes }) => {
			var $known = known
			for unit in 0..<32 {
				bit = U32.shl_wrap(1, unit.to_u8_wrap())
				if U32.bitwise_and(writes, bit) != 0 {
					$known = with_number($known, unit, 0)
				}
			}
			$known
		}
		Err(Opaque) => registers_forgotten(known)
	}

## What two ways both know.
met : Known, Known -> Known
met = |one, other| {
	var $units = List.with_capacity(32)
	for unit in 0..<32 {
		mine = number_of(one, unit)
		$units = $units.append(if mine == number_of(other, unit) { mine } else { 0 })
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
	{ units: $units, places: $places, immediates: $immediates }
}

## The general registers, in the order a holder is looked for, `rsp` and
## `rbp` left out.
holders : List(X86.Register)
holders = [Rax, Rcx, Rdx, Rbx, Rsi, Rdi, R8, R9, R10, R11, R12, R13, R14, R15]

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
general_holder : Known, U64 -> Try(X86.Register, [NotHeld])
general_holder = |known, number|
	holders.find_first(|register| number_of(known, general_unit(register)) == number).map_err(|_| NotHeld)

## An xmm register holding the value number.
xmm_holder : Known, U64 -> Try(X86.Xmm, [NotHeld])
xmm_holder = |known, number|
	xmm_holders.find_first(|xmm| number_of(known, xmm_unit(xmm)) == number).map_err(|_| NotHeld)

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

## The statements with each load of a place whose value a register holds
## made a move from it (or nothing, when the load's own register holds it),
## or the immediate it is.
forwarded : List(Assembly.Statement), (Str -> Bool) -> List(Assembly.Statement)
forwarded = |statements, outside| {
	named = Assembly.named_labels(statements)
	metable = forward_only(statements, outside)
	var $out = List.with_capacity(statements.len())
	var $known = nothing_known
	var $next = 1
	var $falls = True
	var $waiting = Dict.empty()
	for statement in statements {
		match statement {
			Mark(label) => {
				$out = $out.append(statement)
				if metable.contains(label) {
					brought = $waiting.get(label) ?? nothing_known
					$known = if $falls { met(brought, $known) } else { brought }
				} else if named.contains(label) or outside(label) {
					$known = nothing_known
				}
				$falls = True
			}
			JmpTo(label) => {
				$out = $out.append(statement)
				if metable.contains(label) {
					$waiting = $waiting.insert(label, waited($waiting, label, $known))
				}
				$falls = False
			}
			JccTo({ condition: _, label }) => {
				$out = $out.append(statement)
				if metable.contains(label) {
					$waiting = $waiting.insert(label, waited($waiting, label, $known))
				}
			}
			Instruction(instruction) => {
				match instruction {
					MovRegMem({ to, from }) =>
						match frame_offset(from) {
							Ok(offset) => {
								unit = general_unit(to)
								number = $known.places.get(offset) ?? 0
								if number == 0 {
									$out = $out.append(statement)
									$known = with_number($known, unit, $next)
									$known = { ..$known, places: $known.places.insert(offset, $next) }
									$next = $next + 1
								} else {
									if number_of($known, unit) != number {
										made = match general_holder($known, number) {
											Ok(register) => MovRegReg({ to, from: register })
											Err(NotHeld) =>
												match xmm_holder($known, number) {
													Ok(xmm) => MovqFromXmm({ to, from: xmm })
													Err(NotHeld) =>
														match $known.immediates.get(number) {
															Ok(value) => MovRegImm({ to, value })
															Err(_) => instruction
														}
												}
										}
										$out = $out.append(Instruction(made))
									}
									$known = with_number($known, unit, number)
								}
							}
							Err(Elsewhere) => {
								$out = $out.append(statement)
								$known = after_other($known, instruction)
							}
						}
					MovsdLoad({ to, from }) =>
						match frame_offset(from) {
							Ok(offset) => {
								unit = xmm_unit(to)
								number = $known.places.get(offset) ?? 0
								if number == 0 {
									$out = $out.append(statement)
									$known = with_number($known, unit, $next)
									$known = { ..$known, places: $known.places.insert(offset, $next) }
									$next = $next + 1
								} else {
									if number_of($known, unit) != number {
										made = match xmm_holder($known, number) {
											Ok(xmm) => MovsdRegReg({ to, from: xmm })
											Err(NotHeld) =>
												match general_holder($known, number) {
													Ok(register) => MovqToXmm({ to, from: register })
													Err(NotHeld) => instruction
												}
										}
										$out = $out.append(Instruction(made))
									}
									$known = with_number($known, unit, number)
								}
							}
							Err(Elsewhere) => {
								$out = $out.append(statement)
								$known = after_other($known, instruction)
							}
						}
					MovMemReg({ to, from }) => {
						$out = $out.append(statement)
						match frame_offset(to) {
							Ok(offset) => {
								unit = general_unit(from)
								if number_of($known, unit) == 0 {
									$known = with_number($known, unit, $next)
									$next = $next + 1
								}
								$known = { ..$known, places: $known.places.insert(offset, number_of($known, unit)) }
							}
							Err(Elsewhere) => {}
						}
					}
					MovsdStore({ to, from }) => {
						$out = $out.append(statement)
						match frame_offset(to) {
							Ok(offset) => {
								unit = xmm_unit(from)
								if number_of($known, unit) == 0 {
									$known = with_number($known, unit, $next)
									$next = $next + 1
								}
								$known = { ..$known, places: $known.places.insert(offset, number_of($known, unit)) }
							}
							Err(Elsewhere) => {}
						}
					}
					MovRegReg({ to, from }) if !is_frame_making(instruction) => {
						$out = $out.append(statement)
						copied = copied_number($known, { from: general_unit(from), next: $next })
						$next = copied.next
						$known = with_number(copied.known, general_unit(to), copied.number)
					}
					MovqToXmm({ to, from }) => {
						$out = $out.append(statement)
						copied = copied_number($known, { from: general_unit(from), next: $next })
						$next = copied.next
						$known = with_number(copied.known, xmm_unit(to), copied.number)
					}
					MovqFromXmm({ to, from }) => {
						$out = $out.append(statement)
						copied = copied_number($known, { from: xmm_unit(from), next: $next })
						$next = copied.next
						$known = with_number(copied.known, general_unit(to), copied.number)
					}
					MovsdRegReg({ to, from }) => {
						$out = $out.append(statement)
						copied = copied_number($known, { from: xmm_unit(from), next: $next })
						$next = copied.next
						$known = with_number(copied.known, xmm_unit(to), copied.number)
					}
					MovRegImm({ to, value }) => {
						$out = $out.append(statement)
						$known = with_number($known, general_unit(to), $next)
						$known = { ..$known, immediates: $known.immediates.insert($next, value) }
						$next = $next + 1
					}
					Ret | Jmp(_) => {
						$out = $out.append(statement)
						$known = nothing_known
						$falls = False
					}
					Pop(Rbp) => {
						$out = $out.append(statement)
						$known = nothing_known
					}
					_ => {
						$out = $out.append(statement)
						$known = after_other($known, instruction)
					}
				}
				match instruction {
					Ret | Jmp(_) => {}
					_ => {
						$falls = True
					}
				}
			}
			CallTo(_) => {
				$out = $out.append(statement)
				$known = registers_forgotten($known)
				$falls = True
			}
			LeaTo({ to, label: _ }) => {
				$out = $out.append(statement)
				$known = with_number($known, general_unit(to), 0)
				$falls = True
			}
			_ => {
				$out = $out.append(statement)
				$known = nothing_known
				$falls = True
			}
		}
	}
	$out
}

## What a label waits with: what every jump to it so far knew, met with this
## one's.
waited : Dict(Str, Known), Str, Known -> Known
waited = |waiting, label, known|
	match waiting.get(label) {
		Ok(before) => met(before, known)
		Err(_) => known
	}

## The value number a copy from `from` carries, one made for it when it has
## none.
copied_number : Known, { from : U64, next : U64 } -> { known : Known, number : U64, next : U64 }
copied_number = |known, { from, next }| {
	number = number_of(known, from)
	if number != 0 {
		{ known, number, next }
	} else {
		{ known: with_number(known, from, next), number: next, next: next + 1 }
	}
}

# ── Backward: the stores nothing loads ─────────────────────────────────────

## The tracked places live at a point, a bit each: the place at
## `rbp - 8 * (k + 1)` is bit `k`, `low` the first 64 and `high` the next.
Live : { low : U64, high : U64 }

no_place : Live
no_place = { low: 0, high: 0 }

every_place : Live
every_place = { low: 0xFFFF_FFFF_FFFF_FFFF, high: 0xFFFF_FFFF_FFFF_FFFF }

## The bit of a tracked place: from `rbp-8` to `rbp-1024`, 8 bytes each.
place_bit : I32 -> Try(Live, [Untracked])
place_bit = |offset| {
	if offset >= 0 or offset < -1024 or ((0 - offset) // 8) * 8 != 0 - offset {
		return Err(Untracked)
	}
	k = ((0 - offset) // 8 - 1).to_u8_wrap()
	if k < 64 {
		Ok({ low: U64.shl_wrap(1, k), high: 0 })
	} else {
		Ok({ low: 0, high: U64.shl_wrap(1, k - 64) })
	}
}

joined : Live, Live -> Live
joined = |one, other| {
	low: U64.bitwise_or(one.low, other.low),
	high: U64.bitwise_or(one.high, other.high),
}

without : Live, Live -> Live
without = |live, bit| {
	low: U64.bitwise_and(live.low, U64.bitwise_xor(bit.low, 0xFFFF_FFFF_FFFF_FFFF)),
	high: U64.bitwise_and(live.high, U64.bitwise_xor(bit.high, 0xFFFF_FFFF_FFFF_FFFF)),
}

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
			labels.get(label) ?? no_place
		} else {
			every_place
		}
	match statement {
		JmpTo(label) => at_label(label)
		JccTo({ condition: _, label }) => joined(after, at_label(label))
		Instruction(Ret) => no_place
		Instruction(Jmp(_)) | Instruction(Jcc(_)) => every_place
		Data(_) | Distance(_) => every_place
		_ => after
	}
}

## The places live at each label a jump names, found by walking backward
## again until no label's set grows.
settled : List(Assembly.Statement), Set(Str), Set(Str) -> Dict(Str, Live)
settled = |statements, marked, jumped| {
	var $labels = Dict.empty()
	for _ in 0..<statements.len() {
		var $live = every_place
		var $grown = False
		for back in 0..<statements.len() {
			at = statements.len() - 1 - back
			statement = statements.get(at) ?? crash "FrameValues.settled: a statement"
			match statement {
				Mark(label) if jumped.contains(label) => {
					known = $labels.get(label) ?? no_place
					now = joined(known, $live)
					if now != known {
						$labels = $labels.insert(label, now)
						$grown = True
					}
				}
				Mark(_) => {}
				Instruction(instruction) =>
					match place_move(instruction) {
						Ok({ offset, stores }) =>
							match place_bit(offset) {
								Ok(bit) => {
									$live = if stores { without($live, bit) } else { joined($live, bit) }
								}
								Err(Untracked) => {}
							}
						Err(NotPlain) => {
							$live = live_before_flow(statement, { after: $live, labels: $labels, marked })
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
	crash "FrameValues.settled: what is live at the labels never settled"
}

## The statements with each store to a tracked place that isn't live after
## it taken out.
dead_dropped : List(Assembly.Statement) -> List(Assembly.Statement)
dead_dropped = |statements| {
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
	labels = settled(statements, $marked, $jumped)
	var $kept = List.with_capacity(statements.len())
	var $live = every_place
	for back in 0..<statements.len() {
		at = statements.len() - 1 - back
		statement = statements.get(at) ?? crash "FrameValues.dead_dropped: a statement"
		match statement {
			Instruction(instruction) =>
				match place_move(instruction) {
					Ok({ offset, stores }) =>
						match place_bit(offset) {
							Ok(bit) =>
								if stores {
									if holds_any($live, bit) {
										$kept = $kept.append(statement)
										$live = without($live, bit)
									}
								} else {
									$kept = $kept.append(statement)
									$live = joined($live, bit)
								}
							Err(Untracked) => {
								$kept = $kept.append(statement)
							}
						}
					Err(NotPlain) => {
						$kept = $kept.append(statement)
						$live = live_before_flow(statement, { after: $live, labels, marked: $marked })
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
	reversed($kept)
}

reversed : List(Assembly.Statement) -> List(Assembly.Statement)
reversed = |statements| {
	var $out = List.with_capacity(statements.len())
	for back in 0..<statements.len() {
		at = statements.len() - 1 - back
		$out = $out.append(statements.get(at) ?? crash "FrameValues.reversed: a statement")
	}
	$out
}

## The frame's place at `displacement`, for the expects.
slot : I32 -> X86.Mem
slot = |displacement| Based({ base: Rbp, index: NoIndex, displacement })

## Whether `trimmed` makes of `statements` the code of `expected`.
trims_to : List(Assembly.Statement), List(Assembly.Statement) -> Bool
trims_to = |statements, expected|
	Assembly.assemble(FrameValues.trimmed({ statements, outside: |_| False }))
		== Assembly.assemble(expected)

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
		Instruction(Alu({ operation: Add, to: Rcx, from: Rdx })),
		Instruction(MovRegReg({ to: Rax, from: Rcx })),
		Instruction(Ret),
	]
	expected = [
		Assembly.Statement.Instruction(MovRegReg({ to: Rax, from: Rbx })),
		Instruction(MovRegImm({ to: Rax, value: 2 })),
		Instruction(MovRegReg({ to: Rcx, from: Rbx })),
		Instruction(MovRegReg({ to: Rdx, from: Rax })),
		Instruction(Alu({ operation: Add, to: Rcx, from: Rdx })),
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
		FrameValues.trimmed({ statements: body.append(Mark("elsewhere")), outside: |_| False }),
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
