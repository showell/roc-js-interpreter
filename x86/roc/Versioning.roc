## This module places some loops twice in the bytecode, before they are
## lowered again: a generic copy, the loop as it was, and a fast copy whose
## variables are slots of their own, with a guard at the loop's entry that
## chooses between them. A loop is versioned when it reads, as a number, a
## variable it never writes that the lowering keeps as a `Value` at its head
## (sat's `nw` and `base`). The guard tests each such variable, and each
## variable the loop writes and reads as a number from before (its counters),
## for a whole number of 32 bits; when every test holds, the fast copy runs
## with those as `Integer`s, so the loop's arithmetic, orderings and indexes
## on them are integers'. When one fails, the generic copy runs. A variable
## the loop never writes can't change while it runs, so the fast copy stays
## right for the whole loop and never leaves it but by the loop's own exits.
##
## **THE LAYOUT.** The loop's instructions, from its head to its `Loop`,
## become: the guard (a `Jump` to the fast copy, which the lowering makes
## the tests: `LoweringBasics.Guard`), the generic copy, the fast copy, then
## one exit for each place the loop leaves to (a `Jump` there, which the
## lowering makes the copies back: `LoweringBasics.Versions`' `exits`). A
## jump from before the loop to its head lands on the guard; the generic
## copy's jumps stay inside it or leave as before; the fast copy's jumps stay
## inside it or go to its exits. The fast copy names, in place of each slot
## the loop writes or the guard tests, a slot of its own past the frame's,
## so the two copies' kinds never meet: the guard copies each in, and each
## exit copies back those the loop writes.
##
## **WHEN IN DOUBT, NOT VERSIONED.** A program with a `try` is left as it
## is, and so is a loop that makes a closure or a cell, steps a `for ... of`
## (whose slot holds a second slot's place), names a cell in a slot it
## would rename, is entered other than at its head, or leaves backwards but
## by its own `Loop`. A loop inside a versioned loop is copied with it, not
## versioned again. The lowering lowers the versioned program after the
## program as it was has lowered, and keeps the program as it was when the
## versioned one is refused, so versioning never refuses a program, and a
## program with no loop to version is lowered once, to the same bytes.
##
## **THE BUDGET.** A function may copy at most `most_function_instructions`
## instructions into its fast copies, and the program at most
## `most_program_instructions`; a loop past either is left as it is.
import js.Ast
import js.Bytecode
import LoweringBasics

Versioning :: [].{

	## A program with its loops versioned, each code's guards and exits, how
	## many loops were versioned and how many instructions their fast copies
	## hold.
	Versioned : {
		program : Bytecode.Program,
		versions : List(LoweringBasics.Versions),
		loops : U64,
		instructions : U64,
	}

	## The program with each loop the rules and the budget allow versioned,
	## given each code's kinds at its loops' heads (`heads`, by the head's
	## place) and the slots of its frame that hold a cell (`cells`), from the
	## program's lowering as it is.
	versioned_program : {
		program : Bytecode.Program,
		heads : List(Dict(U64, LoweringBasics.State)),
		cells : List(List(U64)),
	} -> Versioning.Versioned
	versioned_program = |{ program, heads, cells }| {
		unversioned = {
			program,
			versions: program.codes.map(|_| LoweringBasics.plain_versions),
			loops: 0,
			instructions: 0,
		}
		if program.codes.any(has_try) {
			return unversioned
		}
		var $codes = []
		var $versions = []
		var $loops = 0
		var $instructions = 0
		for (code, index) in program.codes.map_with_index(|code, index| (code, index)) {
			done = code_versioned(
				code,
				{
					heads: heads.get(index) ?? Dict.empty(),
					cells: cells.get(index) ?? [],
					left: Versioning.most_program_instructions - $instructions,
				},
			)
			$codes = $codes.append(done.code)
			$versions = $versions.append(done.versions)
			$loops = $loops + done.loops
			$instructions = $instructions + done.instructions
		}
		if $loops == 0 {
			return unversioned
		}
		{
			program: { ..program, codes: $codes },
			versions: $versions,
			loops: $loops,
			instructions: $instructions,
		}
	}

	## The most instructions one function's fast copies may hold: propagate's
	## watch loop in the SAT race is about 200.
	most_function_instructions : U64
	most_function_instructions = 400

	## The most instructions the program's fast copies may hold.
	most_program_instructions : U64
	most_program_instructions = 1600
}

## A loop chosen to be versioned: its head and its `Loop`'s places, the
## slots the guard tests, and each slot the fast copy names in place of one
## of the loop's (`renamed`, the loop's slot first).
Chosen : {
	head : U64,
	back : U64,
	checked : List(U64),
	written : List(U64),
	renamed : List((U64, U64)),
}

has_try : Bytecode.Code -> Bool
has_try = |code|
	code.ops.any(
		|instruction|
			match instruction {
				EnterTry(_) | LeaveTry | Rethrow => True
				_ => False
			},
	)

## One code with the loops the rules and the budget allow versioned. `left`
## is what the program's budget has left.
code_versioned : Bytecode.Code,
{
	heads : Dict(U64, LoweringBasics.State),
	cells : List(U64),
	left : U64,
} -> {
	code : Bytecode.Code,
	versions : LoweringBasics.Versions,
	loops : U64,
	instructions : U64,
}
code_versioned = |code, { heads, cells, left }| {
	budget = U64.min(Versioning.most_function_instructions, left)
	var $chosen = []
	var $used = 0
	var $frame = code.frame_size
	for (head, back) in outer_first_loops(code) {
		inside_chosen = $chosen.any(|chosen| head >= chosen.head and back <= chosen.back)
		size = back - head + 1
		if !inside_chosen and $used + size <= budget {
			match loop_choice(code, { head, back, heads, cells, frame: $frame }) {
				Ok(chosen) => {
					$chosen = $chosen.append(chosen)
					$used = $used + size
					$frame = $frame + chosen.renamed.len()
				}
				Err(NotVersioned) => {}
			}
		}
	}
	if $chosen.is_empty() {
		return { code, versions: LoweringBasics.plain_versions, loops: 0, instructions: 0 }
	}
	placed = placed_code(code, $chosen.sort_with(|a, b| place_order(a.head, b.head)))
	{
		code: { ..code, ops: placed.instructions, frame_size: $frame },
		versions: placed.versions,
		loops: $chosen.len(),
		instructions: $used,
	}
}

## Each loop of the code, its head's place and its `Loop`'s, the outer ones
## of a nest first.
outer_first_loops : Bytecode.Code -> List((U64, U64))
outer_first_loops = |code| {
	var $out = []
	for (instruction, at) in code.ops.map_with_index(|instruction, at| (instruction, at)) {
		match instruction {
			Loop(back) => {
				$out = $out.append((at + 1 - back, at))
			}
			_ => {}
		}
	}
	$out.sort_with(
		|(head_a, back_a), (head_b, back_b)|
			match place_order(head_a, head_b) {
				Same => place_order(back_b, back_a)
				order => order
			},
	)
}

## Two places in order.
place_order : U64, U64 -> [Before, Same, After]
place_order = |one, other|
	if one < other {
		Before
	} else if one > other {
		After
	} else {
		Same
	}

## The loop from `head` to `back` chosen, or not: the rules in the header,
## and at least one slot it reads as a number and never writes that holds a
## `Value` at its head. Its fast slots start at `frame`.
loop_choice : Bytecode.Code,
{
	head : U64,
	back : U64,
	heads : Dict(U64, LoweringBasics.State),
	cells : List(U64),
	frame : U64,
} -> Try(Chosen, [NotVersioned])
loop_choice = |code, { head, back, heads, cells, frame }| {
	if back < head + 2 {
		return Err(NotVersioned)
	}
	state = heads.get(head) ?? return Err(NotVersioned)
	inside = |place| place >= head and place <= back
	for (instruction, at) in code.ops.map_with_index(|instruction, at| (instruction, at)) {
		if inside(at) and !is_copyable(instruction) {
			return Err(NotVersioned)
		}
		crossing = match jump_target(instruction, at) {
			Ok(target) => (inside(at) and target < head) or (!inside(at) and inside(target) and target != head)
			Err(NoJump) => False
		}
		if crossing {
			return Err(NotVersioned)
		}
	}
	body = code.ops.sublist({ start: head, len: back - head + 1 })
	written = written_slots(body)
	if written.any(|slot| cells.contains(slot)) {
		return Err(NotVersioned)
	}
	kind_at_head = |slot|
		match state.slots.get(slot) {
			Ok(Ready(kind)) => Ok(kind)
			_ => Err(NotReady)
		}
	numeric = numeric_slots(body)
	invariant = numeric.keep_if(
		|slot|
			!written.contains(slot) and !cells.contains(slot) and kind_at_head(slot) == Ok(Value),
	)
	if invariant.is_empty() {
		return Err(NotVersioned)
	}
	counters = numeric.keep_if(
		|slot| {
			kind = kind_at_head(slot)
			written.contains(slot) and read_first(body, slot) and (kind == Ok(Value) or kind == Ok(Number))
		},
	)
	renamed_slots = written.concat(invariant)
	renamed = renamed_slots.map_with_index(|slot, at| (slot, frame + at))
	Ok({
		head,
		back,
		checked: invariant.concat(counters),
		written,
		renamed,
	})
}

## Whether a loop's instruction may be copied: none that makes a closure or
## a cell, steps a `for ... of`, or takes part in a `try`.
is_copyable : Bytecode.Op -> Bool
is_copyable = |instruction|
	match instruction {
		MakeClosure(_) | NewBox(_) | CopyBox(_) | SetBoxed(_) => False
		IterStart(_) | IterNext(_) => False
		EnterTry(_) | LeaveTry | Rethrow => False
		_ => True
	}

## The slots the instructions write, each once, in the order first written.
written_slots : List(Bytecode.Op) -> List(U64)
written_slots = |body| {
	var $out = []
	for instruction in body {
		match written_slot(instruction) {
			Ok(slot) =>
				if !$out.contains(slot) {
					$out = $out.append(slot)
				}
			Err(NoSlot) => {}
		}
	}
	$out
}

## The slot an instruction writes in the frame.
written_slot : Bytecode.Op -> Try(U64, [NoSlot])
written_slot = |instruction|
	match instruction {
		StoreLocal(slot) | SetLocal(slot) => Ok(slot)
		UpdateLocal({ slot, step: _ }) | AppendLocal({ slot, at: _ }) => Ok(slot)
		_ => Err(NoSlot)
	}

## Whether the first of the instructions that names `slot` reads it (so the
## loop reads what it held before it was entered), not writes it.
read_first : List(Bytecode.Op), U64 -> Bool
read_first = |body, slot| {
	for instruction in body {
		match instruction {
			LoadLocal(read) if read == slot => return True
			UpdateLocal({ slot: stepped, step: _ }) if stepped == slot => return True
			AppendLocal({ slot: appended, at: _ }) if appended == slot => return True
			StoreLocal(set) | SetLocal(set) if set == slot => return False
			_ => {}
		}
	}
	False
}

## The slots some `LoadLocal` of the instructions pushes a value that is
## used as a number (`is_numeric_use`), each once.
numeric_slots : List(Bytecode.Op) -> List(U64)
numeric_slots = |body| {
	var $out = []
	for (instruction, at) in body.map_with_index(|instruction, at| (instruction, at)) {
		match instruction {
			LoadLocal(slot) =>
				if !$out.contains(slot) and is_numeric_use(body, at) {
					$out = $out.append(slot)
				}
			_ => {}
		}
	}
	$out
}

## Whether the value the instruction at `at` pushes is next taken as a
## number, in the straight run after it: an operand of an arithmetic, an
## ordering, an equality or a bitwise operator, or an item read's or write's
## index. Its depth below the top is followed through the pushes and the
## operators above it.
is_numeric_use : List(Bytecode.Op), U64 -> Bool
is_numeric_use = |body, at| {
	var $above = 0
	var $place = at + 1
	while $place < body.len() {
		instruction = body.get($place) ?? crash "Versioning.is_numeric_use: a place"
		match instruction {
			Binary(operator, _) =>
				if $above <= 1 {
					return is_numeric_operator(operator)
				} else {
					$above = $above - 1
				}
			GetIndex(_) =>
				if $above <= 1 {
					return $above == 0
				} else {
					$above = $above - 1
				}
			SetIndex(_) =>
				if $above <= 2 {
					return $above == 1
				} else {
					$above = $above - 2
				}
			Unary(_, _) | GetProperty(_, _) =>
				if $above == 0 {
					return False
				}
			PushNumber(_) | PushText(_) | PushBoolean(_) | PushNull | PushUndefined => {
				$above = $above + 1
			}
			LoadLocal(_) | LoadBoxed(_) | LoadBuiltin(_) => {
				$above = $above + 1
			}
			_ => return False
		}
		$place = $place + 1
	}
	False
}

is_numeric_operator : Ast.BinaryOperator -> Bool
is_numeric_operator = |operator|
	match operator {
		Add | Subtract | Multiply | Divide | Remainder => True
		StrictEqual | StrictNotEqual => True
		Less | LessOrEqual | Greater | GreaterOrEqual => True
		BitAnd | BitOr | BitExclusiveOr => True
		ShiftLeft | ShiftRight | ShiftRightUnsigned => True
		Power => False
	}

## Where an instruction of the code as it was is placed: outside every
## chosen loop it is placed once; inside one, in the generic copy and the
## fast copy.
Placement : {
	# Where each old place's instruction is placed (the generic copy's, in a
	# loop), and where a jump from outside its loop lands on it: the guard,
	# for a loop's head.
	placed_at : List(U64),
	landing_places : List(U64),
}

## The code's instructions with each chosen loop (in the order of their
## heads) placed twice, and their guards and exits.
placed_code : Bytecode.Code,
List(Chosen) -> {
	instructions : List(Bytecode.Op),
	versions : LoweringBasics.Versions,
}
placed_code = |code, chosen_loops| {
	# Where each instruction, guard and exit goes.
	var $placed_at = []
	var $landing_places = []
	var $place = 0
	# For each chosen loop: its guard's place, its fast copy's first place,
	# and its exits, each the old place it leaves to and its own place.
	var $layouts = []
	var $old = 0
	for loop in chosen_loops {
		while $old < loop.head {
			$placed_at = $placed_at.append($place)
			$landing_places = $landing_places.append($place)
			$place = $place + 1
			$old = $old + 1
		}
		size = loop.back - loop.head + 1
		guard = $place
		generic = guard + 1
		fast = generic + size
		for step in 0..<size {
			$placed_at = $placed_at.append(generic + step)
			$landing_places = $landing_places.append(
				if step == 0 {
					guard
				} else {
					generic + step
				},
			)
		}
		leaves = exit_targets(code, loop)
		exits_start = fast + size
		$layouts = $layouts.append({ loop, guard, fast, exits_start, leaves })
		$place = exits_start + leaves.len()
		$old = loop.back + 1
	}
	while $old < code.ops.len() {
		$placed_at = $placed_at.append($place)
		$landing_places = $landing_places.append($place)
		$place = $place + 1
		$old = $old + 1
	}
	placement = { placed_at: $placed_at, landing_places: $landing_places }
	var $out = []
	var $guards = Dict.empty()
	var $exits = Dict.empty()
	var $old_at = 0
	for layout in $layouts {
		loop = layout.loop
		while $old_at < loop.head {
			$out = $out.append(moved_outside(code, { placement, old: $old_at }))
			$old_at = $old_at + 1
		}
		guard_place = $out.len()
		$out = $out.append(Jump(layout.fast - guard_place - 1))
		$guards = $guards.insert(
			guard_place,
			{
				checked: loop.checked.map(|slot| { from: slot, to: renamed_slot(loop, slot) }),
				copied: loop.renamed
					.keep_if(|(slot, _)| !loop.checked.contains(slot))
					.map(|(slot, to)| { from: slot, to }),
				fast: layout.fast,
			},
		)
		for old in loop.head..<(loop.back + 1) {
			$out = $out.append(moved_generic(code, { placement, loop, old }))
		}
		for old in loop.head..<(loop.back + 1) {
			$out = $out.append(moved_fast(code, { layout, old }))
		}
		for target in layout.leaves {
			exit_place = $out.len()
			landing = landing_place(placement, target)
			$out = $out.append(Jump(landing - exit_place - 1))
			$exits = $exits.insert(
				exit_place,
				loop.written.map(|slot| { from: renamed_slot(loop, slot), to: slot }),
			)
		}
		$old_at = loop.back + 1
	}
	while $old_at < code.ops.len() {
		$out = $out.append(moved_outside(code, { placement, old: $old_at }))
		$old_at = $old_at + 1
	}
	{ instructions: $out, versions: { guards: $guards, exits: $exits } }
}

## The fast copy's slot for one of the loop's.
renamed_slot : Chosen, U64 -> U64
renamed_slot = |loop, slot|
	match loop.renamed.find_first(|(from, _)| from == slot) {
		Ok((_, to)) => to
		Err(_) => slot
	}

## The old places past a loop that its jumps leave to, each once, in order.
exit_targets : Bytecode.Code, Chosen -> List(U64)
exit_targets = |code, loop| {
	var $out = []
	for old in loop.head..<(loop.back + 1) {
		instruction = code.ops.get(old) ?? crash "Versioning.exit_targets: a loop's place"
		match jump_target(instruction, old) {
			Ok(target) if target > loop.back and !$out.contains(target) => {
				$out = $out.append(target)
			}
			_ => {}
		}
	}
	$out.sort_with(place_order)
}

## An instruction outside every chosen loop, placed: its jump to a loop's
## head lands on the guard.
moved_outside : Bytecode.Code, { placement : Placement, old : U64 } -> Bytecode.Op
moved_outside = |code, { placement, old }| {
	instruction = code.ops.get(old) ?? crash "Versioning.moved_outside: a place"
	at = placement.placed_at.get(old) ?? crash "Versioning.moved_outside: a placed place"
	match jump_target(instruction, old) {
		Ok(target) => jump_with_target(instruction, { at, target: landing_place(placement, target) })
		Err(NoJump) => instruction
	}
}

## Where a jump to an old place lands, from outside its loop; the place past
## the last is the code's end.
landing_place : Placement, U64 -> U64
landing_place = |placement, target|
	match placement.landing_places.get(target) {
		Ok(place) => place
		Err(_) => {
			last = placement.placed_at.last() ?? crash "Versioning.landing_place: an instruction"
			last + 1 + target - placement.placed_at.len()
		}
	}

## An instruction of a chosen loop's generic copy: a jump inside the loop
## stays in the copy, one out of it lands where any jump from outside would.
moved_generic : Bytecode.Code,
{
	placement : Placement,
	loop : Chosen,
	old : U64,
} -> Bytecode.Op
moved_generic = |code, { placement, loop, old }| {
	instruction = code.ops.get(old) ?? crash "Versioning.moved_generic: a place"
	at = placement.placed_at.get(old) ?? crash "Versioning.moved_generic: a placed place"
	match jump_target(instruction, old) {
		Ok(target) if target >= loop.head and target <= loop.back => {
			inner = placement.placed_at.get(target) ?? crash "Versioning.moved_generic: a target"
			jump_with_target(instruction, { at, target: inner })
		}
		Ok(target) => jump_with_target(instruction, { at, target: landing_place(placement, target) })
		Err(NoJump) => instruction
	}
}

## An instruction of a chosen loop's fast copy: its slots renamed, a jump
## inside the loop kept in the copy, one out of it sent to its exit.
moved_fast : Bytecode.Code,
{
	layout : {
		loop : Chosen,
		guard : U64,
		fast : U64,
		exits_start : U64,
		leaves : List(U64),
	},
	old : U64,
} -> Bytecode.Op
moved_fast = |code, { layout, old }| {
	loop = layout.loop
	instruction = code.ops.get(old) ?? crash "Versioning.moved_fast: a place"
	at = layout.fast + old - loop.head
	renamed = slots_renamed(instruction, loop)
	match jump_target(instruction, old) {
		Ok(target) if target >= loop.head and target <= loop.back =>
			jump_with_target(renamed, { at, target: layout.fast + target - loop.head })
		Ok(target) => {
			exit =
				layout.leaves.find_first_index(|left| left == target)
					?? crash "Versioning.moved_fast: an exit"
			jump_with_target(renamed, { at, target: layout.exits_start + exit })
		}
		Err(NoJump) => renamed
	}
}

## The instruction with each slot it names that the loop renames renamed.
slots_renamed : Bytecode.Op, Chosen -> Bytecode.Op
slots_renamed = |instruction, loop| {
	to = |slot| renamed_slot(loop, slot)
	match instruction {
		LoadLocal(slot) => LoadLocal(to(slot))
		StoreLocal(slot) => StoreLocal(to(slot))
		SetLocal(slot) => SetLocal(to(slot))
		UpdateLocal({ slot, step }) => UpdateLocal({ slot: to(slot), step })
		AppendLocal({ slot, at }) => AppendLocal({ slot: to(slot), at })
		_ => instruction
	}
}

## The place a jump at `at` goes to (Bytecode's header: every jump is
## relative to the instruction after it), as Inlining reads it.
jump_target : Bytecode.Op, U64 -> Try(U64, [NoJump])
jump_target = |instruction, at|
	match instruction {
		Jump(skip) | JumpIfFalse(skip) | SkipIfFalsy(skip) | SkipIfTruthy(skip) => Ok(at + 1 + skip)
		SkipIfDefined(skip) | SkipIfNotUndefined(skip) => Ok(at + 1 + skip)
		JumpIfSame(skip) | ShortIfNullish(skip) => Ok(at + 1 + skip)
		IterNext({ slot: _, exit }) => Ok(at + 1 + exit)
		EnterTry({ handler, kind: _ }) => Ok(at + 1 + handler)
		Loop(back) => Ok(at + 1 - back)
		_ => Err(NoJump)
	}

## The jump at `at` aimed at `target`.
jump_with_target : Bytecode.Op, { at : U64, target : U64 } -> Bytecode.Op
jump_with_target = |instruction, { at, target }|
	match instruction {
		Loop(_) => Loop(at + 1 - target)
		Jump(_) => Jump(target - at - 1)
		JumpIfFalse(_) => JumpIfFalse(target - at - 1)
		SkipIfFalsy(_) => SkipIfFalsy(target - at - 1)
		SkipIfTruthy(_) => SkipIfTruthy(target - at - 1)
		SkipIfDefined(_) => SkipIfDefined(target - at - 1)
		SkipIfNotUndefined(_) => SkipIfNotUndefined(target - at - 1)
		JumpIfSame(_) => JumpIfSame(target - at - 1)
		ShortIfNullish(_) => ShortIfNullish(target - at - 1)
		IterNext({ slot, exit: _ }) => IterNext({ slot, exit: target - at - 1 })
		EnterTry({ handler: _, kind }) => EnterTry({ handler: target - at - 1, kind })
		_ => crash "Versioning.jump_with_target: an instruction that is no jump"
	}
