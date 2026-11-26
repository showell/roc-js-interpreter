## This module inlines small leaf functions into the loops that call them,
## in the bytecode, before anything is lowered. At a direct call it takes
## out the load of the function and puts in its place, at the call, the
## callee's own instructions: each argument set into a slot of its own,
## the callee's slots appended to the caller's frame, each `return` a jump
## to the instruction after the call, with the result on the stack where
## the call's result would be. The lowering then walks the inlined body as
## any of the caller's own code, so it sees this call's exact argument
## kinds (an inlined `step(run, op)` sees `op` as an `Integer` of 0 to 3),
## and the call's pushes, frame and saves are gone.
##
## **THE BUDGET.** A site is inlined only when every rule holds, so the
## code grows by little and never in a cascade:
##
## - the callee is a leaf: every instruction is one of a short list of
##   loads, stores, operators and jumps (`leaf_effect`), so it calls no
##   function of the program, has no loop, and recursion can't be inlined;
## - the callee has at most `most_leaf_instructions` instructions that some way
##   reaches;
## - the call is inside a loop of the caller;
## - the caller grows, from all of its inlined sites together, by at most
##   the larger of `most_growth_percent` of its own count of instructions
##   and `least_growth_instructions`, and never by more than
##   `most_growth_instructions`;
## - a callee of at most `always_leaf_instructions` is inlined past the
##   first of those two growth limits, though never past the second.
##
## The numbers are V8's inlining limits (`--max-inlined-bytecode-size` and
## its kin), scaled to our instructions: x86/fourteen/STEP_STUDY.md, section
## 3, finds fourteen's `step` 75 of V8's bytecode bytes and 44 of ours, so
## one of ours is about 1.7 of V8's bytes.
##
## **WHEN IN DOUBT, NO INLINING.** A program with a `try` anywhere is left
## as it is (a throw lands with every variable a value). So is a callee
## that captures anything but numbers held for good (`constant_numbers`,
## read here as the number), whose entry makes a cell, whose arguments are
## packed, whose count of parameters isn't the call's, or one of whose
## `return`s leaves more than the result on its stack. So is a call whose
## arguments are made by anything but a straight run of the instructions
## `window_effect` knows, or whose run another jump of the caller lands in.
## The callee's own code stays in the program, so its other calls and its
## uses as a value are as before. The lowering is handed the inlined
## program first, and the program as it was when that one is refused
## (`Lowering.program_items`), so inlining can only take code to the fast
## way, never refuse a program.
##
## Frames: an inlined body takes no frame, and only leaves are inlined, so
## how deep a recursion goes before node's `RangeError` is unchanged.
import js.Bytecode
import KnownFunctions
import LoweringBasics

Inlining :: [].{

	## A program with its sites inlined, how many sites, and how many
	## instructions their bodies placed (each body's, and a set a parameter).
	Inlined : {
		program : Bytecode.Program,
		sites : U64,
		instructions : U64,
	}

	## The program with each site the budget allows inlined.
	inlined_program : Bytecode.Program -> Inlining.Inlined
	inlined_program = |program| {
		unchanged = { program, sites: 0, instructions: 0 }
		if program.codes.any(has_try) {
			return unchanged
		}
		makers = match KnownFunctions.makers_of(program) {
			Ok(found) => found
			Err(_) => return unchanged
		}
		known = {
			program,
			makers,
			statics: KnownFunctions.statics_of(program, makers),
		}
		var $codes = []
		var $sites = 0
		var $instructions = 0
		for index in 0..<program.codes.len() {
			code = program.codes.get(index) ?? crash "Inlining.inlined_program: a code's index"
			done = code_inlined(known, { code, index })
			$codes = $codes.append(done.code)
			$sites = $sites + done.sites
			$instructions = $instructions + done.instructions
		}
		{
			program: { ..program, codes: $codes },
			sites: $sites,
			instructions: $instructions,
		}
	}

	## The most instructions a callee may have for its calls to be inlined:
	## V8's 460-byte callee is about 250 of ours; a quarter of it, since we
	## inline at every loop site with no count of how often it runs.
	most_leaf_instructions : U64
	most_leaf_instructions = 64

	## How much a caller may grow from its inlined sites, in hundredths of its
	## own count of instructions: a large caller's share, which V8's
	## absolute budgets don't scale.
	most_growth_percent : U64
	most_growth_percent = 25

	## The growth any caller may take whatever its size, one leaf of the
	## largest: V8's budgets are per function, not a ratio, so a small caller
	## may take a leaf about its own size.
	least_growth_instructions : U64
	least_growth_instructions = 64

	## The most a caller may grow, however large it is: V8's 920 bytes
	## inlined into one function are about 540 of ours; about half of it.
	most_growth_instructions : U64
	most_growth_instructions = 256

	## A callee this small is inlined past the caller's share, within
	## `most_growth_instructions`: V8's 27-byte small function, about 16 of ours.
	always_leaf_instructions : U64
	always_leaf_instructions = 16
}

## How an instruction moves the stack: what it takes from the top, and what
## it leaves there.
Effect : { taken : U64, given : U64 }

## A leaf's body, ready to be placed: its instructions, each jump's target a
## place in the body (its length the place after its last), how many of the
## leaf's own instructions some way reaches, and its frame.
Body : {
	instructions : List(Placed),
	reached : U64,
	parameters : U64,
	frame_size : U64,
}

## An instruction and, for a jump, the place it goes to, in the coordinates
## of the list it sits in.
Placed : { instruction : Bytecode.Op, target : [Toward(U64), Nowhere] }

## A site chosen: the place of the instruction that loads the callee, the
## call's place, the slot of the caller's frame where the callee's start,
## and the callee's body.
InlineSite : {
	load : U64,
	call : U64,
	base : U64,
	body : Body,
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

## One code with the sites the budget allows inlined, and how many.
code_inlined : LoweringBasics.Known,
{ code : Bytecode.Code, index : U64 } -> {
	code : Bytecode.Code,
	sites : U64,
	instructions : U64,
}
code_inlined = |known, { code, index }| {
	quarter = code.ops.len() * Inlining.most_growth_percent // 100
	floored = U64.max(quarter, Inlining.least_growth_instructions)
	share = U64.min(floored, Inlining.most_growth_instructions)
	var $chosen = []
	var $grown = 0
	var $frame = code.frame_size
	for (instruction, at) in code.ops.map_with_index(|instruction, at| (instruction, at)) {
		match instruction {
			Call({ count, written: _, at: _ }) =>
				match site_at(known, { code, index, call: at, count }) {
					Ok({ load, made }) =>
						match leaf_body(known, made) {
							Ok(body) => {
								growth = body.instructions.len() + body.parameters
								limit = if body.reached <= Inlining.always_leaf_instructions {
									Inlining.most_growth_instructions
								} else {
									share
								}
								if $grown + growth <= limit {
									$chosen = $chosen.append({
										load,
										call: at,
										base: $frame,
										body,
									})
									$frame = $frame + body.frame_size
									$grown = $grown + growth
								}
							}
							Err(NotLeaf) => {}
						}
					Err(NoSite) => {}
				}
			_ => {}
		}
	}
	if $chosen.is_empty() {
		return { code, sites: 0, instructions: 0 }
	}
	{
		code: {
			..code,
			ops: placed_instructions(code, $chosen),
			frame_size: $frame,
		},
		sites: $chosen.len(),
		instructions: $grown,
	}
}

## The caller's instructions with each chosen site's load taken out and its
## call made the callee's body, its slots from the site's `base` on.
placed_instructions : Bytecode.Code, List(InlineSite) -> List(Bytecode.Op)
placed_instructions = |code, sites| {
	# Each instruction placed, a caller's jump's target still its old place,
	# and where each of the caller's old places starts.
	var $out = []
	var $starts = []
	for (instruction, at) in code.ops.map_with_index(|instruction, at| (instruction, at)) {
		$starts = $starts.append($out.len())
		match sites.find_first(|site| site.load == at) {
			Ok(_) => {}
			Err(_) =>
				match sites.find_first(|site| site.call == at) {
					Ok(site) => {
						# The arguments are on the stack, the last on top.
						var $parameter = site.body.parameters
						while $parameter > 0 {
							$parameter = $parameter - 1
							$out = $out.append({
								instruction: SetLocal(site.base + $parameter),
								target: Nowhere,
							})
						}
						first = $out.len()
						for placed in site.body.instructions {
							moved = slots_moved(placed.instruction, site.base)
							target = match placed.target {
								Toward(place) => New(first + place)
								Nowhere => Nowhere
							}
							$out = $out.append({ instruction: moved, target })
						}
					}
					Err(_) => {
						target = match jump_target(instruction, at) {
							Ok(old) => Old(old)
							Err(NoJump) => Nowhere
						}
						$out = $out.append({ instruction, target })
					}
				}
		}
	}
	$starts = $starts.append($out.len())
	$out.map_with_index(
		|placed, at|
			match placed.target {
				Old(old) => {
					target =
						$starts.get(old)
							?? crash "Inlining.placed_instructions: a jump's old target"
					jump_with_target(placed.instruction, { at, target })
				}
				New(target) => jump_with_target(placed.instruction, { at, target })
				Nowhere => placed.instruction
			},
	)
}

## The instruction with each slot it names moved up by `base`.
slots_moved : Bytecode.Op, U64 -> Bytecode.Op
slots_moved = |instruction, base|
	match instruction {
		LoadLocal(slot) => LoadLocal(base + slot)
		StoreLocal(slot) => StoreLocal(base + slot)
		SetLocal(slot) => SetLocal(base + slot)
		UpdateLocal({ slot, step }) => UpdateLocal({ slot: base + slot, step })
		_ => instruction
	}

## The instruction that loads the function a direct call at `call` calls,
## and that function's code: a load of a slot holding a function known
## before the program runs, then a straight run of instructions that leaves
## the call's `count` arguments on top of it, which no other jump lands in,
## inside a loop.
site_at : LoweringBasics.Known,
{
	code : Bytecode.Code,
	index : U64,
	call : U64,
	count : U64,
} -> Try({ load : U64, made : U64 }, [NoSite])
site_at = |known, { code, index, call, count }| {
	# Walk back from the call until the run from here on leaves `count`
	# values: the first such place is where the arguments start, since the
	# instruction before them pushes, and a run that started later would
	# take from below its start.
	var $at = call
	var $left = 0
	var $looking = True
	while $looking {
		if $at == 0 {
			return Err(NoSite)
		}
		$at = $at - 1
		instruction = code.ops.get($at) ?? crash "Inlining.site_at: a place before the call"
		effect = match window_effect(instruction) {
			Ok(known_effect) => known_effect
			Err(Unknown) => return Err(NoSite)
		}
		$left = $left + effect.given.to_i64_wrap() - effect.taken.to_i64_wrap()
		if $left == count.to_i64_wrap() {
			$looking = False
		}
	}
	if $at == 0 {
		return Err(NoSite)
	}
	load = $at - 1
	# Each instruction of the run must find what it takes above the load.
	var $depth = 0
	for place in $at..<call {
		instruction = code.ops.get(place) ?? crash "Inlining.site_at: a place in the run"
		effect = window_effect(instruction) ?? crash "Inlining.site_at: a known effect"
		if effect.taken > $depth {
			return Err(NoSite)
		}
		$depth = $depth - effect.taken + effect.given
	}
	if $depth != count {
		return Err(NoSite)
	}
	landed = code.ops.map_with_index(|instruction, at| (instruction, at)).any(
		|(instruction, at)|
			match jump_target(instruction, at) {
				Ok(target) => target > load and target <= call
				Err(NoJump) => False
			},
	)
	looped = code.ops.map_with_index(|instruction, at| (instruction, at)).any(
		|(instruction, at)|
			match instruction {
				Loop(back) => at > call and at + 1 - back <= load
				_ => False
			},
	)
	if landed or !looped {
		return Err(NoSite)
	}
	slot = match code.ops.get(load) {
		Ok(LoadLocal(held)) => held
		Ok(
			LoadBoxed(
				{
					slot: held,
					name: _,
					at: _,
				},
			),
		) => held
		_ => return Err(NoSite)
	}
	match KnownFunctions.held_function(known, { code: index, slot }) {
		Ok(made) if made != index => Ok({ load, made })
		_ => Err(NoSite)
	}
}

## A leaf's body, placed from its own place 0: each instruction some way
## reaches, each captured number read as the number, each `return` a jump
## to the place after the body (and the last, which falls there, left out).
leaf_body : LoweringBasics.Known, U64 -> Try(Body, [NotLeaf])
leaf_body = |known, made| {
	code = known.program.codes.get(made) ?? crash "Inlining.leaf_body: a code"
	parameters = match code.arguments {
		Each(count) => count
		Packed(_) => return Err(NotLeaf)
	}
	numbers = KnownFunctions.constant_numbers(known, made)
	if code.entry.any(
		|step| match step {
			CapturedBox(_) => False
			_ => True
		},
	) {
		return Err(NotLeaf)
	}
	depths = reached_depths(code)?
	kept = depths.map_with_index(
		|
			depth,
			at,
		| (depth, at),
	).keep_if(|(depth, _)| depth != Unreached).map(|(_, at)| at)
	if kept.len() > Inlining.most_leaf_instructions {
		return Err(NotLeaf)
	}
	# Each kept place's place in the body; the last `return` falls to the end.
	last_return = match kept.last() {
		Ok(at) =>
			match code.ops.get(at) {
				Ok(Return) => Ok(at)
				_ => Err(NoReturn)
			}
		Err(_) => Err(NoReturn)
	}
	placed_at = |old|
		match kept.find_first_index(|at| at == old) {
			Ok(place) => place
			Err(_) => crash "Inlining.leaf_body: a jump to a place no way reaches"
		}
	var $instructions = []
	end = match last_return {
		Ok(_) => kept.len() - 1
		Err(NoReturn) => kept.len()
	}
	for at in kept {
		instruction = code.ops.get(at) ?? crash "Inlining.leaf_body: a kept place"
		if last_return != Ok(at) {
			placed = match instruction {
				Return => { instruction: Jump(0), target: Toward(end) }
				LoadBoxed({ slot, name: _, at: _ }) =>
					match numbers.get(slot) {
						Ok(number) => { instruction: PushNumber(number), target: Nowhere }
						Err(_) => return Err(NotLeaf)
					}
				_ =>
					match jump_target(instruction, at) {
						Ok(target) => {
							instruction: instruction,
							target: Toward(placed_at(target)),
						}
						Err(NoJump) => { instruction: instruction, target: Nowhere }
					}
			}
			$instructions = $instructions.append(placed)
		}
	}
	Ok({
		instructions: $instructions,
		reached: kept.len(),
		parameters,
		frame_size: code.frame_size,
	})
}

## The stack's depth at each instruction of a leaf, from its entry, or
## `Unreached`; not a leaf when an instruction isn't one `leaf_effect`
## knows, takes what isn't there, two ways bring two depths, or a `return`
## leaves more than its result.
reached_depths : Bytecode.Code -> Try(List([Reached(U64), Unreached]), [NotLeaf])
reached_depths = |code| {
	var $depths = List.repeat(Unreached, code.ops.len())
	var $waiting = [(0, 0)]
	while !$waiting.is_empty() {
		(at, depth) = $waiting.last() ?? crash "Inlining.reached_depths: a place waiting"
		$waiting = $waiting.drop_last(1)
		match $depths.get(at) {
			Ok(Reached(before)) =>
				if before != depth {
					return Err(NotLeaf)
				}
			Ok(Unreached) => {
				$depths = $depths.set(
					at,
					Reached(depth),
				) ?? crash "Inlining.reached_depths: a place"
				instruction = code.ops.get(at) ?? crash "Inlining.reached_depths: an instruction"
				effect = leaf_effect(instruction)?
				if effect.taken > depth {
					return Err(NotLeaf)
				}
				after = depth - effect.taken + effect.given
				match instruction {
					Return =>
						if depth != 1 {
							return Err(NotLeaf)
						}
					Jump(skip) => {
						$waiting = $waiting.append((at + 1 + skip, depth))
					}
					JumpIfFalse(skip) => {
						$waiting = $waiting.append((at + 1 + skip, after))
						$waiting = $waiting.append((at + 1, after))
					}
					SkipIfFalsy(skip) | SkipIfTruthy(skip) => {
						$waiting = $waiting.append((at + 1 + skip, depth))
						$waiting = $waiting.append((at + 1, after))
					}
					_ => {
						$waiting = $waiting.append((at + 1, after))
					}
				}
			}
			Err(_) => return Err(NotLeaf)
		}
	}
	Ok($depths)
}

## How a leaf's instruction moves the stack, for the instructions a leaf
## may hold: loads, stores, literals, operators, forward jumps and
## `return`. A jump's is its way on; a skip's kept value is the walk's.
leaf_effect : Bytecode.Op -> Try(Effect, [NotLeaf])
leaf_effect = |instruction|
	match instruction {
		PushNumber(_) | PushText(_) | PushBoolean(_) | PushNull | PushUndefined => Ok({
			taken: 0,
			given: 1,
		})
		LoadLocal(_) | LoadBoxed(_) | UpdateLocal(_) => Ok({ taken: 0, given: 1 })
		StoreLocal(_) | Unary(_, _) => Ok({ taken: 1, given: 1 })
		SetLocal(_) | Pop | JumpIfFalse(_) | SkipIfFalsy(_) | SkipIfTruthy(_) | Return => Ok({
			taken: 1,
			given: 0,
		})
		Duplicate => Ok({ taken: 1, given: 2 })
		Swap => Ok({ taken: 2, given: 2 })
		Nip | Binary(_, _) => Ok({ taken: 2, given: 1 })
		Jump(_) => Ok({ taken: 0, given: 0 })
		_ => Err(NotLeaf)
	}

## How an instruction that may make a call's arguments moves the stack:
## a leaf's straight instructions, and the builtins, methods, calls,
## properties and array literals an argument is made of.
window_effect : Bytecode.Op -> Try(Effect, [Unknown])
window_effect = |instruction|
	match instruction {
		JumpIfFalse(_) | SkipIfFalsy(_) | SkipIfTruthy(_) | Return | Jump(_) => Err(Unknown)
		LoadBuiltin(_) => Ok({ taken: 0, given: 1 })
		MethodLookup(_, _) => Ok({ taken: 1, given: 2 })
		CallMethod(
			{ name: _, site: { count, written: _, at: _ } },
		) => Ok({ taken: count + 2, given: 1 })
		Call({ count, written: _, at: _ }) => Ok({ taken: count + 1, given: 1 })
		GetProperty(_, _) => Ok({ taken: 1, given: 1 })
		GetIndex(_) => Ok({ taken: 2, given: 1 })
		MakeArray(count) => Ok({ taken: count, given: 1 })
		_ =>
			match leaf_effect(instruction) {
				Ok(effect) => Ok(effect)
				Err(NotLeaf) => Err(Unknown)
			}
	}

## The place a jump at `at` goes to (Bytecode's header: every jump is
## relative to the instruction after it).
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
jump_with_target = |instruction, { at, target }| {
	match instruction {
		Loop(_) => Loop(at + 1 - target)
		_ => forward_jump_with_skip(instruction, target - (at + 1))
	}
}

## The forward jump made a skip of `ahead` instructions.
forward_jump_with_skip : Bytecode.Op, U64 -> Bytecode.Op
forward_jump_with_skip = |instruction, ahead|
	match instruction {
		Jump(_) => Jump(ahead)
		JumpIfFalse(_) => JumpIfFalse(ahead)
		SkipIfFalsy(_) => SkipIfFalsy(ahead)
		SkipIfTruthy(_) => SkipIfTruthy(ahead)
		SkipIfDefined(_) => SkipIfDefined(ahead)
		SkipIfNotUndefined(_) => SkipIfNotUndefined(ahead)
		JumpIfSame(_) => JumpIfSame(ahead)
		ShortIfNullish(_) => ShortIfNullish(ahead)
		IterNext({ slot, exit: _ }) => IterNext({ slot, exit: ahead })
		EnterTry({ handler: _, kind }) => EnterTry({ handler: ahead, kind })
		_ => crash "Inlining.forward_jump_with_skip: an instruction that is no forward jump"
	}
