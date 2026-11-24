## This module lowers a compiled JavaScript program (`Bytecode`) to x86-64
## (`Assembly` statements), one instruction's machine code after another, as
## the VM would run them. It compiles a numeric subset: numbers, booleans and
## `undefined` in variables and on the stack, arithmetic and comparisons,
## `if`, the loops and the logical operators, function declarations called
## by name (recursion included), and `console.log`. Anything else is refused,
## by name, before a byte is written.
##
## **EVERY VALUE'S KIND IS KNOWN BEFORE THE PROGRAM RUNS.** The lowering
## walks each function's instructions in order and keeps, for each slot of
## the frame and each place on the stack, what kind of value it holds
## (`Kind`). Where two ways meet (a jump's target, a loop's head) the kinds
## must agree, so no value needs a tag at run time: a number is its 8 bytes
## of IEEE double, a boolean 0 or 1, `undefined` 0. A function is known by
## which code it runs, and `console` and its `log` take no bytes at all.
##
## **A FRAME IS FIXED WHEN THE FUNCTION IS LOWERED.** A function's frame,
## below `rbp`, holds its slots (slot s at `rbp - 8(s + 1)`), then the
## bytecode's stack, as deep as the function ever makes it, so a push or a
## pop is a store or a load at a place known here. A call pushes its
## arguments, the last first, and the callee copies each to its parameter's
## slot; the result comes back in `rax`.
##
## **ONLY THE START OF A SCOPE MAKES A FUNCTION.** A function's
## declarations are the first instructions of its code (a `MakeClosure` and a
## `SetBoxed` each), so its name holds that function from the start, and a
## closure may capture such names and nothing else. A variable a closure
## captures that holds a value is refused, as is a function made anywhere
## else (a function expression after the first statement), or a name a
## function is assigned to.
import js.Ast
import js.Bytecode
import Assembly
import Runtime
import X86

Lowering :: [].{

	## The program's machine code, its entry first, or what in it can't be
	## lowered yet.
	program_items : Bytecode.Program -> Try(List(Assembly.Statement), [Refused(Str)])
	program_items = |program| {
		makers = makers_of(program)?
		var $returns = Dict.empty()
		for index in 0..<program.codes.len() {
			$returns = $returns.insert(index, Number)
		}
		for _ in 0..<3 {
			var $items = [CallTo(code_label(program.main))]
			var $found = $returns
			for index in 0..<program.codes.len() {
				lowered = code_items({ program, makers, returns: $returns, index })?
				$items = $items.concat(lowered.statements)
				$found = match lowered.result {
					Gives(kind) => $found.insert(index, kind)
					GivesNothing => $found
				}
			}
			if $found == $returns {
				return Ok($items.concat(Runtime.items))
			}
			$returns = $found
		}
		Err(Refused("the kinds of the functions' results never settle"))
	}
}

## What a slot or a place on the stack holds, known before the program runs.
Kind : [
	Number,
	Boolean,
	Undefined,
	Function(U64),
	Console,
	Log,
]

## A slot holds a value of its kind once its declaration has run.
Slot : [Unready, Ready(Kind)]

## The kinds at one instruction: each slot's, and the stack's, bottom first.
State : { slots : List(Slot), stack_kinds : List(Kind) }

## Where each function's code is made: the code that makes it and the slots
## of that code's frame its closure captures, in order.
Maker : {
	parent : U64,
	captures : List(U64),
	name : Str,
}

## What lowering one function needs to know of the rest.
Context : {
	program : Bytecode.Program,
	makers : Dict(U64, Maker),
	returns : Dict(U64, Kind),
	index : U64,
}

## One instruction's place, for the code it lowers to and its messages.
Site : {
	lowering : Context,
	code : Bytecode.Code,
	at : U64,
	functions : Dict(U64, U64),
}

## What an instruction lowers to: its machine code, the state after it when
## the next instruction follows, and the state at a jump's target.
Lowered : {
	statements : List(Assembly.Statement),
	falls : [Falls(State), Ends],
	branch : [Branch({ target : U64, state : State }), NoBranch],
	result : [Gives(Kind), GivesNothing],
}

## Each code a `MakeClosure` makes, with where it is made: a code made at
## two places is refused, since its captures would differ.
makers_of : Bytecode.Program -> Try(Dict(U64, Maker), [Refused(Str)])
makers_of = |program| {
	var $makers = Dict.empty()
	for parent in 0..<program.codes.len() {
		code = program.codes.get(parent) ?? crash "Lowering.makers_of: a code's index"
		for instruction in code.ops {
			match instruction {
				MakeClosure({ code: made, captures, definition }) => {
					if $makers.contains(made) {
						name = definition.unbox().name
						return Err(Refused("the function `${name}` is made at two places"))
					}
					$makers = $makers.insert(
						made,
						{ parent, captures, name: definition.unbox().name },
					)
				}
				_ => {}
			}
		}
	}
	Ok($makers)
}

## The slots a code's declarations give their functions, and the code each
## runs: the `MakeClosure` and `SetBoxed` pairs its instructions start with.
declared_functions : Bytecode.Code -> Dict(U64, U64)
declared_functions = |code| {
	var $found = Dict.empty()
	var $at = 0
	var $going = True
	while $going {
		match (code.ops.get($at), code.ops.get($at + 1)) {
			(
				Ok(
					MakeClosure(
						{
							code: made,
							captures: _,
							definition: _,
						},
					),
				),
				Ok(SetBoxed(slot)),
			) => {
				$found = $found.insert(slot, made)
				$at = $at + 2
			}
			_ => {
				$going = False
			}
		}
	}
	$found
}

## The function a captured slot of code `index` holds: the one its maker's
## slot holds, declared there or captured there in turn.
captured_function : Context, { slot : U64, capture : U64 } -> Try(U64, [Refused(Str)])
captured_function = |lowering, { slot: _, capture }| {
	maker = lowering.makers.get(lowering.index) ?? crash "Lowering.captured_function: its maker"
	parent_slot = maker.captures.get(capture) ?? crash "Lowering.captured_function: a capture"
	parent = lowering.program.codes.get(maker.parent) ?? crash "Lowering.captured_function: a code"
	match declared_functions(parent).get(parent_slot) {
		Ok(made) => Ok(made)
		Err(_) => {
			entry_capture = parent.entry.find_first(
				|step|
					match step {
						CapturedBox({ slot, capture: _ }) => slot == parent_slot
						_ => False
					},
			)
			match entry_capture {
				Ok(CapturedBox(captured)) => captured_function(
					{ ..lowering, index: maker.parent },
					captured,
				)
				_ => Err(captured_value_refusal(maker.name))
			}
		}
	}
}

## The kinds when a function's code starts: its parameters hold numbers,
## its declared functions and the functions it captures are ready, and the
## rest are unready.
start_state : Context, Bytecode.Code -> Try(State, [Refused(Str)])
start_state = |lowering, code| {
	parameters = match code.arguments {
		Each(count) => count
		Packed(_) => return Err(code_refusal(lowering, PatternedParameters))
	}
	var $slots = List.repeat(Unready, code.frame_size)
	for slot in 0..<parameters {
		$slots = $slots.set(
			slot,
			Ready(Number),
		) ?? crash "Lowering.start_state: a parameter has a slot"
	}
	for step in code.entry {
		match step {
			FreshBox(_) => {}
			FilledBox(slot) => {
				$slots = $slots.set(
					slot,
					Ready(Number),
				) ?? crash "Lowering.start_state: a boxed parameter has a slot"
			}
			CapturedBox(captured) => {
				made = captured_function(lowering, captured)?
				$slots = $slots.set(
					captured.slot,
					Ready(Function(made)),
				) ?? crash "Lowering.start_state: a capture has a slot"
			}
		}
	}
	for (slot, made) in declared_functions(code).to_list() {
		$slots = $slots.set(
			slot,
			Ready(Function(made)),
		) ?? crash "Lowering.start_state: a declaration has a slot"
	}
	Ok({ slots: $slots, stack_kinds: [] })
}

## What one function does that the lowering refuses, and where.
CodeFault : [
	LoopChangesKinds(U64),
	TwoResultKinds,
	TwoStacks(U64),
	TwoSlotKinds(U64),
	FrameTooLarge,
	PatternedParameters,
]

## The refusal of a function's fault, the function named.
code_refusal : Context, CodeFault -> [Refused(Str)]
code_refusal = |lowering, fault| {
	why = match fault {
		LoopChangesKinds(at) => "a loop changes a kind it holds, at instruction ${at.to_str()}"
		TwoResultKinds => "it returns values of two kinds"
		TwoStacks(at) => "two ways reach instruction ${at.to_str()} with different stacks"
		TwoSlotKinds(at) => "a variable holds values of two kinds at instruction ${at.to_str()}"
		FrameTooLarge => "its frame is over a megabyte"
		PatternedParameters => "its parameters have a pattern, a default or a rest"
	}
	Refused("${function_name(lowering)}: ${why}")
}

## The refusal of a function that captures a variable holding a value.
captured_value_refusal : Str -> [Refused(Str)]
captured_value_refusal = |name| {
	what = "captures a variable that holds a value"
	Refused("the function `${name}` ${what}, not a function declared beside it")
}

function_name : Context -> Str
function_name = |lowering|
	if lowering.index == lowering.program.main {
		"the program"
	} else {
		match lowering.makers.get(lowering.index) {
			Ok(maker) => "the function `${maker.name}`"
			Err(_) => "a function made nowhere"
		}
	}

code_label : U64 -> Str
code_label = |index| "code_${index.to_str()}"

## The label of an instruction of the code being lowered.
place_label : Context, U64 -> Str
place_label = |lowering, at| "code_${lowering.index.to_str()}_${at.to_str()}"

## One function's machine code: its entry, which makes its frame and
## copies its arguments to their slots, then each instruction's.
code_items : Context -> Try(
	{ statements : List(Assembly.Statement), result : [Gives(Kind), GivesNothing] },
	[Refused(Str)],
)
code_items = |lowering| {
	code = lowering.program.codes.get(lowering.index) ?? crash "Lowering.code_items: a code's index"
	start = start_state(lowering, code)?
	functions = declared_functions(code)
	for instruction in code.ops {
		match instruction {
			MakeClosure({ code: _, captures, definition }) =>
				for slot in captures {
					match start.slots.get(slot) {
						Ok(Ready(Function(_))) => {}
						_ => return Err(captured_value_refusal(definition.unbox().name))
					}
				}
			_ => {}
		}
	}
	var $body = []
	var $pending = Dict.empty()
	var $seen = Dict.empty()
	var $flowing = Flowing(start)
	var $deepest = 0
	var $result = GivesNothing
	for at in 0..<code.ops.len() {
		$body = $body.append(Mark(place_label(lowering, at)))
		arriving = match ($flowing, $pending.get(at)) {
			(Flowing(state), Ok(waiting)) => Arrives(
				meeting_state(lowering, { at, one: state, other: waiting })?,
			)
			(Flowing(state), Err(_)) => Arrives(state)
			(Stopped, Ok(waiting)) => Arrives(waiting)
			(Stopped, Err(_)) => Unreached
		}
		match arriving {
			Unreached => {
				$flowing = Stopped
			}
			Arrives(state) => {
				$seen = $seen.insert(at, state)
				instruction = code.ops.get(at) ?? crash "Lowering.code_items: an instruction"
				lowered = instruction_items(
					{ lowering, code, at, functions },
					{ instruction, state },
				)?
				$body = $body.concat(lowered.statements)
				$flowing = match lowered.falls {
					Falls(next) => {
						$deepest = U64.max($deepest, next.stack_kinds.len())
						Flowing(next)
					}
					Ends => Stopped
				}
				match lowered.branch {
					NoBranch => {}
					Branch({ target, state: sent }) =>
						if target > at {
							$deepest = U64.max($deepest, sent.stack_kinds.len())
							$pending = match $pending.get(target) {
								Ok(waiting) => $pending.insert(
									target,
									meeting_state(
										lowering,
										{
											at: target,
											one: waiting,
											other: sent,
										},
									)?,
								)
								Err(_) => $pending.insert(target, sent)
							}
						} else {
							head = $seen.get(target) ?? crash "Lowering.code_items: a loop's head"
							again = meeting_state(
								lowering,
								{
									at: target,
									one: head,
									other: sent,
								},
							)?
							if again != head {
								return Err(code_refusal(lowering, LoopChangesKinds(target)))
							}
						}
				}
				$result = match (lowered.result, $result) {
					(GivesNothing, _) => $result
					(Gives(kind), GivesNothing) => Gives(kind)
					(Gives(kind), Gives(before)) =>
						if kind == before {
							$result
						} else {
							return Err(code_refusal(lowering, TwoResultKinds))
						}
				}
			}
		}
	}
	frame_bytes = 8 * (code.frame_size + $deepest)
	if frame_bytes > 1048576 {
		return Err(code_refusal(lowering, FrameTooLarge))
	}
	statements = entry_items(lowering, { code, frame_bytes }).concat($body)
	Ok({ statements, result: $result })
}

## A function's entry: `rbp` saved and set, its frame made below it, and
## each parameter copied from where the caller pushed it to its slot.
entry_items : Context, { code : Bytecode.Code, frame_bytes : U64 } -> List(Assembly.Statement)
entry_items = |lowering, { code, frame_bytes }| {
	parameters = match code.arguments {
		Each(count) => count
		Packed(_) => 0
	}
	var $items = [
		Mark(code_label(lowering.index)),
		Instruction(Push(Rbp)),
		Instruction(MovRegReg({ to: Rbp, from: Rsp })),
		Instruction(
			AluImm({
				operation: Sub,
				to: Rsp,
				value: frame_bytes.to_i32_wrap(),
			}),
		),
	]
	for slot in 0..<parameters {
		with_top = Based({
			base: Rbp,
			index: NoIndex,
			displacement: (16 + 8 * slot).to_i32_wrap(),
		})
		$items = $items.concat([
			Instruction(MovRegMem({ to: Rax, from: with_top })),
			Instruction(MovMemReg({ to: slot_place(slot), from: Rax })),
		])
	}
	$items
}

## The state at a place two ways reach: the same stack, and each slot ready
## with one kind, or unready on either way.
meeting_state : Context,
{
	at : U64,
	one : State,
	other : State,
} -> Try(State, [Refused(Str)])
meeting_state = |lowering, { at, one, other }| {
	if one.stack_kinds != other.stack_kinds {
		return Err(code_refusal(lowering, TwoStacks(at)))
	}
	var $slots = []
	for (a, b) in List.map2(
		one.slots,
		other.slots,
		|a, b| (a, b),
	) {
		slot = match (a, b) {
			(Ready(left), Ready(right)) =>
				if left == right {
					Ready(left)
				} else {
					return Err(code_refusal(lowering, TwoSlotKinds(at)))
				}
			_ => Unready
		}
		$slots = $slots.append(slot)
	}
	Ok({ slots: $slots, stack_kinds: one.stack_kinds })
}

slot_place : U64 -> X86.Mem
slot_place = |slot| Based({
	base: Rbp,
	index: NoIndex,
	displacement: (0 - 8 * (slot.to_i64_wrap() + 1)).to_i32_wrap(),
})

## The place of the value `depth` places up the stack of a code.
stack_place : Bytecode.Code, U64 -> X86.Mem
stack_place = |code, depth| slot_place(code.frame_size + depth)

## The instruction's refusal, naming its function and place.
refusal : Site, Str -> Try(a, [Refused(Str)])
refusal = |
	site,
	why,
| Err(Refused("${function_name(site.lowering)}, instruction ${site.at.to_str()}: ${why}"))

## An instruction that falls through to the next with `state`.
falling : List(Assembly.Statement), State -> Lowered
falling = |items, state| {
	statements: items,
	falls: Falls(state),
	branch: NoBranch,
	result: GivesNothing,
}

## The value `down` places down from the top of the stack (0 is the top).
kind_below : State, U64 -> Kind
kind_below = |state, down| {
	kinds = state.stack_kinds
	kinds.get(kinds.len() - 1 - down) ?? crash "Lowering.kind_below: a value the stack holds"
}

## The stack with its top `count` values gone.
without_top : State, U64 -> State
without_top = |state, count| {
	..state,
	stack_kinds: state.stack_kinds.take_first(state.stack_kinds.len() - count),
}

with_top : State, Kind -> State
with_top = |state, kind| { ..state, stack_kinds: state.stack_kinds.append(kind) }

## A copy of 8 bytes from one place to another, through `rax`.
copy_items : { from : X86.Mem, to : X86.Mem } -> List(Assembly.Statement)
copy_items = |{ from, to }| [
	Instruction(MovRegMem({ to: Rax, from })),
	Instruction(MovMemReg({ to, from: Rax })),
]

## The bits of a constant stored at a place.
constant_items : { bits : U64, to : X86.Mem } -> List(Assembly.Statement)
constant_items = |{ bits, to }| [
	Instruction(MovRegImm({ to: Rax, value: bits.to_i64_wrap() })),
	Instruction(MovMemReg({ to, from: Rax })),
]

## A slot read: refused while it is unready, or when it is no slot.
slot_kind : Site,
{
	state : State,
	slot : U64,
	name : Str,
} -> Try(Kind, [Refused(Str)])
slot_kind = |site, { state, slot, name }|
	match state.slots.get(slot) {
		Ok(Ready(kind)) => Ok(kind)
		Ok(Unready) => refusal(
			site,
			"${name} is read before its declaration has run, which throws in node",
		)
		Err(_) => crash "Lowering.slot_kind: a slot of the frame"
	}

## A slot written with the value on top of the stack: refused for a
## function's name, and for a value that isn't a number, a boolean or
## `undefined`.
written_slot : Site, { state : State, slot : U64 } -> Try(State, [Refused(Str)])
written_slot = |site, { state, slot }| {
	match state.slots.get(slot) {
		Ok(Ready(Function(_))) => return refusal(site, "a function's name is assigned")
		_ => {}
	}
	kind = kind_below(state, 0)
	match kind {
		Number | Boolean | Undefined => {}
		_ => return refusal(site, "a variable is given a function, `console` or a method")
	}
	slots = state.slots.set(slot, Ready(kind)) ?? crash "Lowering.written_slot: a slot of the frame"
	Ok({ ..state, slots })
}

## The value on top of the stack stored in its slot.
store_items : Site, { state : State, slot : U64 } -> List(Assembly.Statement)
store_items = |site, { state, slot }| copy_items({
	from: stack_place(site.code, state.stack_kinds.len() - 1),
	to: slot_place(slot),
})

## A slot's value pushed.
load_items : Site, { state : State, slot : U64 } -> List(Assembly.Statement)
load_items = |site, { state, slot }| copy_items({
	from: slot_place(slot),
	to: stack_place(site.code, state.stack_kinds.len()),
})

## A truth test of the value on top of the stack: the flags set so that
## `E` holds when it is falsy (false, 0, -0 or NaN).
truth_items : Site, State -> Try(List(Assembly.Statement), [Refused(Str)])
truth_items = |site, state| {
	top = stack_place(site.code, state.stack_kinds.len() - 1)
	match kind_below(state, 0) {
		Boolean => Ok([
			Instruction(MovRegMem({ to: Rax, from: top })),
			Instruction(Test({ left: Rax, right: Rax })),
		])
		Number =>
			Ok([
				Instruction(MovsdLoad({ to: Xmm0, from: top })),
				Instruction(
					Alu({
						operation: Xor,
						to: Rcx,
						from: Rcx,
					}),
				),
				Instruction(MovqToXmm({ to: Xmm1, from: Rcx })),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			])
		_ => refusal(site, "a test of a value that is neither a number nor a boolean")
	}
}

## A jump's target: `skip` instructions on from the next, or back.
forward : Site, U64 -> U64
forward = |site, skip| site.at + 1 + skip

## `++` or `--` of a slot holding a number: the slot stepped, and the old
## value (postfix) or the new (prefix) pushed.
update_items : Site,
{
	state : State,
	slot : U64,
	step : Bytecode.Update,
} -> Try(Lowered, [Refused(Str)])
update_items = |site, { state, slot, step }| {
	kind = slot_kind(site, { state, slot, name: "a variable" })?
	if kind != Number {
		return refusal(site, "`++` or `--` of a value that is not a number")
	}
	top = stack_place(site.code, state.stack_kinds.len())
	stepped = [
		Instruction(MovsdLoad({ to: Xmm0, from: slot_place(slot) })),
		Instruction(MovRegImm({ to: Rax, value: step.delta.to_bits().to_i64_wrap() })),
		Instruction(MovqToXmm({ to: Xmm1, from: Rax })),
		Instruction(
			Sse({
				operation: Addsd,
				to: Xmm0,
				from: Xmm1,
			}),
		),
		Instruction(MovsdStore({ to: slot_place(slot), from: Xmm0 })),
	]
	items = match step.fixity {
		Postfix => copy_items({ from: slot_place(slot), to: top }).concat(stepped)
		Prefix => stepped.append(Instruction(MovsdStore({ to: top, from: Xmm0 })))
	}
	Ok(falling(items, with_top(state, Number)))
}

## A binary operator on the two values on top of the stack, its answer in
## the place of the first.
binary_items : Site,
{
	state : State,
	operator : Ast.BinaryOperator,
} -> Try(Lowered, [Refused(Str)])
binary_items = |site, { state, operator }| {
	left = stack_place(site.code, state.stack_kinds.len() - 2)
	right = stack_place(site.code, state.stack_kinds.len() - 1)
	kinds = (kind_below(state, 1), kind_below(state, 0))
	loaded = [
		Instruction(MovsdLoad({ to: Xmm0, from: left })),
		Instruction(MovsdLoad({ to: Xmm1, from: right })),
	]
	arithmetic = |operation|
		falling(
			loaded.concat([
				Instruction(Sse({ operation, to: Xmm0, from: Xmm1 })),
				Instruction(MovsdStore({ to: left, from: Xmm0 })),
			]),
			with_top(without_top(state, 2), Number),
		)
	# The flags of a `ucomisd` leave CF and ZF clear only when the first is
	# the greater and neither is a NaN, so `a < b` is `b > a`.
	ordered = |{ first, second, condition }|
		falling(
			[
				Instruction(MovsdLoad({ to: Xmm0, from: first })),
				Instruction(MovsdLoad({ to: Xmm1, from: second })),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
				Instruction(Setcc({ condition, to: Al })),
				Instruction(MovzxByte({ to: Rax, from: Al })),
				Instruction(MovMemReg({ to: left, from: Rax })),
			],
			with_top(without_top(state, 2), Boolean),
		)
	# Two doubles are equal when ZF is set and PF, the NaN's flag, is not.
	equality = |{ same, parity, joined }|
		falling(
			loaded.concat([
				Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
				Instruction(Setcc({ condition: same, to: Al })),
				Instruction(Setcc({ condition: parity, to: Cl })),
				Instruction(MovzxByte({ to: Rax, from: Al })),
				Instruction(MovzxByte({ to: Rcx, from: Cl })),
				Instruction(
					Alu({
						operation: joined,
						to: Rax,
						from: Rcx,
					}),
				),
				Instruction(MovMemReg({ to: left, from: Rax })),
			]),
			with_top(without_top(state, 2), Boolean),
		)
	booleans_compared = |condition|
		falling(
			[
				Instruction(MovRegMem({ to: Rax, from: left })),
				Instruction(MovRegMem({ to: Rcx, from: right })),
				Instruction(
					Alu({
						operation: Cmp,
						to: Rax,
						from: Rcx,
					}),
				),
				Instruction(Setcc({ condition, to: Al })),
				Instruction(MovzxByte({ to: Rax, from: Al })),
				Instruction(MovMemReg({ to: left, from: Rax })),
			],
			with_top(without_top(state, 2), Boolean),
		)
	match (operator, kinds) {
		(Add, (Number, Number)) => Ok(arithmetic(Addsd))
		(Subtract, (Number, Number)) => Ok(arithmetic(Subsd))
		(Multiply, (Number, Number)) => Ok(arithmetic(Mulsd))
		(Divide, (Number, Number)) => Ok(arithmetic(Divsd))
		(Less, (Number, Number)) => Ok(
			ordered({
				first: right,
				second: left,
				condition: A,
			}),
		)
		(LessOrEqual, (Number, Number)) => Ok(
			ordered({
				first: right,
				second: left,
				condition: Ae,
			}),
		)
		(Greater, (Number, Number)) => Ok(
			ordered({
				first: left,
				second: right,
				condition: A,
			}),
		)
		(GreaterOrEqual, (Number, Number)) => Ok(
			ordered({
				first: left,
				second: right,
				condition: Ae,
			}),
		)
		(StrictEqual, (Number, Number)) => Ok(
			equality({
				same: E,
				parity: Np,
				joined: And,
			}),
		)
		(StrictNotEqual, (Number, Number)) => Ok(
			equality({
				same: Ne,
				parity: P,
				joined: Or,
			}),
		)
		(StrictEqual, (Boolean, Boolean)) => Ok(booleans_compared(E))
		(StrictNotEqual, (Boolean, Boolean)) => Ok(booleans_compared(Ne))
		(Remainder, _) => refusal(site, "`%` is not compiled yet")
		(Power, _) => refusal(site, "`**` is not compiled yet")
		_ => {
			named = Str.inspect(operator)
			operands = "a ${kind_text(kinds.0)} and a ${kind_text(kinds.1)}"
			refusal(site, "`${named}` of ${operands} is not compiled yet")
		}
	}
}

## A count and its noun, singular for one: `1 argument`, `2 arguments`.
count_text : U64, Str -> Str
count_text = |count, noun|
	if count == 1 {
		"1 ${noun}"
	} else {
		"${count.to_str()} ${noun}s"
	}

kind_text : Kind -> Str
kind_text = |kind|
	match kind {
		Number => "number"
		Boolean => "boolean"
		Undefined => "undefined"
		Function(_) => "function"
		Console => "console"
		Log => "console.log"
	}

## A unary operator on the value on top of the stack.
unary_items : Site, { state : State, operator : Ast.UnaryOperator } -> Try(Lowered, [Refused(Str)])
unary_items = |site, { state, operator }| {
	top = stack_place(site.code, state.stack_kinds.len() - 1)
	match (operator, kind_below(state, 0)) {
		(Negate, Number) =>
			Ok(
				falling(
					[
						Instruction(MovRegMem({ to: Rax, from: top })),
						Instruction(
							MovRegImm({ to: Rcx, value: (0x8000000000000000).to_i64_wrap() }),
						),
						Instruction(
							Alu({
								operation: Xor,
								to: Rax,
								from: Rcx,
							}),
						),
						Instruction(MovMemReg({ to: top, from: Rax })),
					],
					state,
				),
			)
		(Plus, Number) => Ok(falling([], state))
		(Not, Boolean) =>
			Ok(
				falling(
					[
						Instruction(MovRegMem({ to: Rax, from: top })),
						Instruction(
							AluImm({
								operation: Xor,
								to: Rax,
								value: 1,
							}),
						),
						Instruction(MovMemReg({ to: top, from: Rax })),
					],
					state,
				),
			)
		(Not, Number) => {
			tested = truth_items(site, state)?
			Ok(
				falling(
					tested.concat([
						Instruction(Setcc({ condition: E, to: Al })),
						Instruction(MovzxByte({ to: Rax, from: Al })),
						Instruction(MovMemReg({ to: top, from: Rax })),
					]),
					with_top(without_top(state, 1), Boolean),
				),
			)
		}
		(_, kind) => refusal(
			site,
			"`${Str.inspect(operator)}` of a ${kind_text(kind)} is not compiled yet",
		)
	}
}

## A call of a declared function: its arguments pushed, the last first, the
## call, and its result in the callee's place.
call_items : Site, { state : State, count : U64 } -> Try(Lowered, [Refused(Str)])
call_items = |site, { state, count }| {
	made = match kind_below(state, count) {
		Function(index) => index
		kind => return refusal(site, "a call of a ${kind_text(kind)}")
	}
	callee = site.lowering.program.codes.get(made) ?? crash "Lowering.call_items: a function's code"
	parameters = match callee.arguments {
		Each(given) => given
		Packed(_) => return refusal(
			site,
			"a call of a function whose parameters have a pattern, a default or a rest",
		)
	}
	if parameters != count {
		given = count_text(count, "argument")
		taken = count_text(parameters, "parameter")
		return refusal(site, "a call with ${given} to ${taken}")
	}
	base = state.stack_kinds.len() - count - 1
	var $items = []
	for back in 0..<count {
		argument = count - 1 - back
		if kind_below(state, back) != Number {
			return refusal(site, "a call with an argument that is not a number")
		}
		$items = $items.concat([
			Instruction(MovRegMem({ to: Rax, from: stack_place(site.code, base + 1 + argument) })),
			Instruction(Push(Rax)),
		])
	}
	$items = $items.append(CallTo(code_label(made)))
	if count > 0 {
		$items = $items.append(
			Instruction(
				AluImm({
					operation: Add,
					to: Rsp,
					value: (8 * count).to_i32_wrap(),
				}),
			),
		)
	}
	result = site.lowering.returns.get(made) ?? crash "Lowering.call_items: a result"
	Ok(
		falling(
			$items.append(Instruction(MovMemReg({ to: stack_place(site.code, base), from: Rax }))),
			with_top(without_top(state, count + 1), result),
		),
	)
}

## `console.log` of the values on top of the stack: each written as node
## writes it, a space between, then a newline.
log_items : Site, { state : State, count : U64 } -> Try(Lowered, [Refused(Str)])
log_items = |site, { state, count }| {
	base = state.stack_kinds.len() - count
	var $items = []
	for argument in 0..<count {
		if argument > 0 {
			$items = $items.concat(Runtime.text_items(Space))
		}
		place = stack_place(site.code, base + argument)
		written = match kind_below(state, count - 1 - argument) {
			Number => [
				Instruction(MovRegMem({ to: Rax, from: place })),
				CallTo(Runtime.print_number),
			]
			Boolean => {
				label = "${place_label(site.lowering, site.at)}_${argument.to_str()}"
				[
					Instruction(MovRegMem({ to: Rax, from: place })),
					Instruction(Test({ left: Rax, right: Rax })),
					JccTo({ condition: E, label: "${label}_false" }),
				]
					.concat(Runtime.text_items(True))
					.append(JmpTo("${label}_written"))
					.append(Mark("${label}_false"))
					.concat(Runtime.text_items(False))
					.append(Mark("${label}_written"))
			}
			Undefined => Runtime.text_items(Undefined)
			kind => return refusal(site, "console.log of a ${kind_text(kind)} is not compiled yet")
		}
		$items = $items.concat(written)
	}
	$items = $items.concat(Runtime.text_items(Newline))
	Ok(falling($items, with_top(without_top(state, count + 2), Undefined)))
}

## A builtin read: `console`, `NaN` and `Infinity`, and no other yet.
builtin_items : Site, { state : State, place : U64 } -> Try(Lowered, [Refused(Str)])
builtin_items = |site, { state, place }| {
	top = stack_place(site.code, state.stack_kinds.len())
	match Ast.global_names_of(Core).get(place) {
		Ok("console") => Ok(falling([], with_top(state, Console)))
		Ok("NaN") => Ok(
			falling(constant_items({ bits: 0x7FF8000000000000, to: top }), with_top(state, Number)),
		)
		Ok("Infinity") => Ok(
			falling(constant_items({ bits: 0x7FF0000000000000, to: top }), with_top(state, Number)),
		)
		Ok(name) => refusal(site, "the builtin `${name}` is not compiled yet")
		Err(_) => crash "Lowering.builtin_items: a builtin's place"
	}
}

## A jump taken when the value on top is falsy (`E`) or truthy (`Ne`):
## `JumpIfFalse` drops the value either way, the logical operators' skips
## keep it where they jump.
test_jump_items : Site,
{
	state : State,
	skip : U64,
	condition : X86.Condition,
	kept : [Kept, Dropped],
} -> Try(Lowered, [Refused(Str)])
test_jump_items = |site, { state, skip, condition, kept }| {
	tested = truth_items(site, state)?
	target = forward(site, skip)
	sent = match kept {
		Kept => state
		Dropped => without_top(state, 1)
	}
	jump = JccTo({ condition, label: place_label(site.lowering, target) })
	Ok({
		statements: tested.append(jump),
		falls: Falls(without_top(state, 1)),
		branch: Branch({ target, state: sent }),
		result: GivesNothing,
	})
}

## The machine code of one instruction, and the kinds after it.
instruction_items : Site,
{
	instruction : Bytecode.Op,
	state : State,
} -> Try(Lowered, [Refused(Str)])
instruction_items = |site, { instruction, state }| {
	depth = state.stack_kinds.len()
	top_place = |down| stack_place(site.code, depth - 1 - down)
	next_place = stack_place(site.code, depth)
	if site.at < 2 * site.functions.len() {
		return Ok(falling([], state))
	}
	match instruction {
		PushNumber(number) => Ok(
			falling(
				constant_items({ bits: number.to_bits(), to: next_place }),
				with_top(state, Number),
			),
		)
		PushBoolean(value) => {
			bits = match value {
				True => 1
				False => 0
			}
			Ok(falling(constant_items({ bits, to: next_place }), with_top(state, Boolean)))
		}
		PushUndefined => Ok(
			falling(constant_items({ bits: 0, to: next_place }), with_top(state, Undefined)),
		)
		Pop => Ok(falling([], without_top(state, 1)))
		Duplicate => Ok(
			falling(
				copy_items({ from: top_place(0), to: next_place }),
				with_top(state, kind_below(state, 0)),
			),
		)
		DuplicatePair => {
			items = copy_items({ from: top_place(1), to: next_place }).concat(
				copy_items({ from: top_place(0), to: stack_place(site.code, depth + 1) }),
			)
			second = with_top(state, kind_below(state, 1))
			Ok(falling(items, with_top(second, kind_below(state, 0))))
		}
		Nip => Ok(
			falling(
				copy_items({ from: top_place(0), to: top_place(1) }),
				with_top(without_top(state, 2), kind_below(state, 0)),
			),
		)
		Swap => {
			items = [
				Instruction(MovRegMem({ to: Rax, from: top_place(1) })),
				Instruction(MovRegMem({ to: Rcx, from: top_place(0) })),
				Instruction(MovMemReg({ to: top_place(1), from: Rcx })),
				Instruction(MovMemReg({ to: top_place(0), from: Rax })),
			]
			first = with_top(without_top(state, 2), kind_below(state, 0))
			Ok(falling(items, with_top(first, kind_below(state, 1))))
		}
		Rotate => {
			items = [
				Instruction(MovRegMem({ to: Rax, from: top_place(2) })),
				Instruction(MovRegMem({ to: Rcx, from: top_place(1) })),
				Instruction(MovRegMem({ to: Rdx, from: top_place(0) })),
				Instruction(MovMemReg({ to: top_place(2), from: Rcx })),
				Instruction(MovMemReg({ to: top_place(1), from: Rdx })),
				Instruction(MovMemReg({ to: top_place(0), from: Rax })),
			]
			moved = [
				kind_below(state, 1),
				kind_below(state, 0),
				kind_below(state, 2),
			]
			Ok(
				falling(
					items,
					{ ..state, stack_kinds: without_top(state, 3).stack_kinds.concat(moved) },
				),
			)
		}
		LoadLocal(slot) => {
			kind = slot_kind(site, { state, slot, name: "a variable" })?
			Ok(falling(load_items(site, { state, slot }), with_top(state, kind)))
		}
		LoadBoxed({ slot, name, at: _ }) => {
			kind = slot_kind(site, { state, slot, name: "`${name}`" })?
			Ok(falling(load_items(site, { state, slot }), with_top(state, kind)))
		}
		PeekBoxed(slot) => {
			kind = slot_kind(site, { state, slot, name: "a variable" })?
			Ok(falling(load_items(site, { state, slot }), with_top(state, kind)))
		}
		StoreLocal(slot) => {
			after = written_slot(site, { state, slot })?
			Ok(falling(store_items(site, { state, slot }), after))
		}
		SetLocal(slot) | SetBoxed(slot) => {
			after = written_slot(site, { state, slot })?
			Ok(falling(store_items(site, { state, slot }), without_top(after, 1)))
		}
		StoreBoxed({ slot, name, kind, at: _ }) =>
			match kind {
				Fixed => refusal(site, "the constant `${name}` is assigned, which throws in node")
				Mutable => {
					after = written_slot(site, { state, slot })?
					Ok(falling(store_items(site, { state, slot }), after))
				}
			}
		NewBox(slot) =>
			match state.slots.get(slot) {
				Ok(Ready(Function(_))) => refusal(site, "a function's name is declared again")
				_ => {
					slots = state.slots.set(
						slot,
						Unready,
					) ?? crash "Lowering.instruction_items: a slot of the frame"
					Ok(falling([], { ..state, slots }))
				}
			}
		CopyBox(_) => Ok(falling([], state))
		LoadBuiltin(place) => builtin_items(site, { state, place })
		UpdateLocal({ slot, step }) => update_items(site, { state, slot, step })
		UpdateBoxed({ slot, name, kind, step }) =>
			match kind {
				Fixed => refusal(site, "the constant `${name}` is stepped, which throws in node")
				Mutable => update_items(site, { state, slot, step })
			}
		AppendLocal({ slot, at: _ }) => {
			held = slot_kind(site, { state, slot, name: "a variable" })?
			if held != Number or kind_below(state, 0) != Number {
				return refusal(site, "`+=` of a value that is not a number")
			}
			items = [
				Instruction(MovsdLoad({ to: Xmm0, from: slot_place(slot) })),
				Instruction(MovsdLoad({ to: Xmm1, from: top_place(0) })),
				Instruction(
					Sse({
						operation: Addsd,
						to: Xmm0,
						from: Xmm1,
					}),
				),
				Instruction(MovsdStore({ to: slot_place(slot), from: Xmm0 })),
				Instruction(MovsdStore({ to: top_place(0), from: Xmm0 })),
			]
			Ok(falling(items, state))
		}
		Unary(operator, _) => unary_items(site, { state, operator })
		Binary(operator, _) => binary_items(site, { state, operator })
		Jump(skip) => {
			target = forward(site, skip)
			Ok({
				statements: [JmpTo(place_label(site.lowering, target))],
				falls: Ends,
				branch: Branch({ target, state }),
				result: GivesNothing,
			})
		}
		Loop(back) => {
			target = site.at + 1 - back
			Ok({
				statements: [JmpTo(place_label(site.lowering, target))],
				falls: Ends,
				branch: Branch({ target, state }),
				result: GivesNothing,
			})
		}
		JumpIfFalse(skip) => test_jump_items(
			site,
			{
				state,
				skip,
				condition: E,
				kept: Dropped,
			},
		)
		SkipIfFalsy(skip) => test_jump_items(
			site,
			{
				state,
				skip,
				condition: E,
				kept: Kept,
			},
		)
		SkipIfTruthy(skip) => test_jump_items(
			site,
			{
				state,
				skip,
				condition: Ne,
				kept: Kept,
			},
		)
		MethodLookup(name, _) =>
			match (kind_below(state, 0), name) {
				(Console, "log") => Ok(falling([], with_top(state, Log)))
				(kind, _) => refusal(
					site,
					"the method `${name}` of a ${kind_text(kind)} is not compiled yet",
				)
			}
		CallMethod({ name: _, site: { count, written: _, at: _ } }) =>
			match kind_below(state, count) {
				Log => log_items(site, { state, count })
				kind => refusal(site, "a method call of a ${kind_text(kind)} is not compiled yet")
			}
		Call({ count, written: _, at: _ }) => call_items(site, { state, count })
		Return => {
			kind = kind_below(state, 0)
			match kind {
				Number | Boolean | Undefined => {}
				_ => return refusal(site, "a function returns a ${kind_text(kind)}")
			}
			items = [
				Instruction(MovRegMem({ to: Rax, from: top_place(0) })),
				Instruction(MovRegReg({ to: Rsp, from: Rbp })),
				Instruction(Pop(Rbp)),
				Instruction(Ret),
			]
			Ok({
				statements: items,
				falls: Ends,
				branch: NoBranch,
				result: Gives(kind),
			})
		}
		Finish => {
			items = [
				Instruction(MovRegImm({ to: Rax, value: 231 })),
				Instruction(
					Alu({
						operation: Xor,
						to: Rdi,
						from: Rdi,
					}),
				),
				Instruction(Syscall),
			]
			Ok({
				statements: items,
				falls: Ends,
				branch: NoBranch,
				result: GivesNothing,
			})
		}
		MakeClosure({ code: _, captures: _, definition }) => refusal(
			site,
			"the function `${definition.unbox().name}` is not declared at the start of its scope",
		)
		MissingName({ name, at: _ }) => refusal(
			site,
			"`${name}` is declared nowhere, which throws in node",
		)
		ThrowUnready({ name, at: _ }) => refusal(
			site,
			"`${name}` is read before its declaration has run, which throws in node",
		)
		ThrowConstant(_) => refusal(site, "a constant is assigned, which throws in node")
		Refuse(why) => refusal(site, why)
		_ => refusal(site, "${instruction_name(instruction)} is not compiled yet")
	}
}

## An instruction's tag, for a refusal.
instruction_name : Bytecode.Op -> Str
instruction_name = |instruction| {
	text = Str.inspect(instruction)
	match text.split_first("(") {
		Ok({ before, after: _ }) => before
		Err(_) => text
	}
}
