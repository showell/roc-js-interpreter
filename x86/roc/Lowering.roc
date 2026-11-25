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
## **A FUNCTION KNOWN BEFORE THE PROGRAM RUNS TAKES NO BYTES.** A function
## whose captures are all names of such functions (`statics_of`: fib, which
## captures only itself) is known by its code alone, as `Function(code)`,
## and called directly. Where it is used as a value (stored, passed,
## returned) it becomes its closure record in the read-only segment, boxed
## with `Boxing.function_tag`, and it is `escaped_codes`. Any other function is
## made as it runs: `MakeClosure` takes a record from the heap and fills it
## with the cells of the variables it captures (`Boxing.roc` has the
## layout). A variable a closure captures, and that holds a value, lives in a
## cell of 8 bytes on the heap, its slot holding the cell's address, as the
## VM's box; its kind is `Value`. A call of a function known by its code is a
## direct call, `rbx` holding the record when it has one; any other is a
## call through the value, which enters the code at its value entry with
## `rcx` the count of arguments. A function a value may hold takes `Value`
## parameters, since no call shows what reaches it that way.
import js.Ast
import js.Bytecode
import js.ValueRules
import Assembly
import Boxing
import Emit
import KnownFunctions
import LoweringBasics
import Runtime
import RuntimeCode
import X86

Lowering :: [].{

	## The program's machine code, its entry first, or what in it can't be
	## lowered yet.
	program_items : Bytecode.Program -> Try(List(Assembly.Statement), [Refused(Str)])
	program_items = |program| {
		makers = KnownFunctions.makers_of(program)?
		literals = literals_of(program)?
		statics = KnownFunctions.statics_of(program, makers)
		var $escaped_codes =
			makers
				.to_list()
				.keep_if(|(made, _)| !statics.contains(made))
				.map(|(made, _)| made)
		var $returns = Dict.empty()
		for index in 0..<program.codes.len() {
			$returns = $returns.insert(index, Number)
		}
		var $parameters = Dict.empty()
		for _ in 0..<8 {
			var $items = Runtime.start_items(LoweringBasics.code_label(program.main))
			var $found = $returns
			var $called = Dict.empty()
			var $escaped = $escaped_codes
			var $first_refusal = Ok({})
			for index in 0..<program.codes.len() {
				context = {
					program,
					makers,
					statics,
					escaped_codes: $escaped_codes,
					cells: KnownFunctions.celled_slots({ program, makers, statics }, index),
					returns: $returns,
					parameters: $parameters,
					literals,
					index,
				}
				match code_items(context) {
					Ok(lowered) => {
						$items = $items.concat(lowered.statements)
						$found = match lowered.result {
							Gives(kind) => $found.insert(index, kind)
							GivesNothing => $found
						}
						for call in lowered.calls {
							$called = with_call_kinds($called, call)
						}
						for made in lowered.escaped {
							if !$escaped.contains(made) {
								$escaped = $escaped.append(made)
							}
						}
					}
					Err({ refused, calls }) => {
						for call in calls {
							$called = with_call_kinds($called, call)
						}
						# A refusal may come of a kind not settled yet (a call's
						# result taken as a number on the first pass), so the
						# function's result is widened for the next pass to see
						# what follows it.
						$found = $found.insert(index, Value)
						if $first_refusal == Ok({}) {
							$first_refusal = Err(refused)
						}
					}
				}
			}
			settled = $found == $returns and $called == $parameters
			if settled and $escaped.len() == $escaped_codes.len() {
				return match $first_refusal {
					Ok({}) =>
						Ok(
							$items
								.concat(RuntimeCode.items)
								.concat(literal_statements(literals))
								.concat(
									KnownFunctions.closure_statements({
										makers,
										statics,
										escaped_codes: $escaped_codes,
									}),
								),
						)
					Err(refused) => Err(refused)
				}
			}
			$returns = $found
			$parameters = $called
			$escaped_codes = $escaped
		}
		Err(Refused("the kinds of the functions' parameters and results never settle"))
	}
}

## The parameters' kinds of every call so far, with one more call met in.
with_call_kinds : Dict(
	U64,
	List(LoweringBasics.Kind),
),
LoweringBasics.CallKinds -> Dict(U64, List(LoweringBasics.Kind))
with_call_kinds = |called, { code, kinds }|
	match called.get(code) {
		Ok(before) => {
			met = List.map2(
				before,
				kinds,
				|before_kind, call_kind|
					match LoweringBasics.met_kind(before_kind, call_kind) {
						Ok(kind) => kind
						Err(Apart) => crash "Lowering.with_call_kinds: arguments are values"
					},
			)
			called.insert(code, met)
		}
		Err(_) => called.insert(code, kinds)
	}

## The kind of a parameter of the function being lowered: what its calls
## pass, or `Value` for a function a value may hold, or that no lowered
## call reaches.
parameter_kind : LoweringBasics.Context, U64 -> LoweringBasics.Kind
parameter_kind = |lowering, slot|
	if lowering.escaped_codes.contains(lowering.index) {
		Value
	} else {
		match lowering.parameters.get(lowering.index) {
			Ok(kinds) => kinds.get(slot) ?? crash "Lowering.parameter_kind: a call passes each"
			Err(_) => Value
		}
	}

## Each text the program names (its strings, a template's pieces and the
## properties it reads and writes), numbered for its label. A text that
## isn't ASCII is refused: a string's length is its bytes here, and
## JavaScript's counts UTF-16's units.
literals_of : Bytecode.Program -> Try(Dict(Str, U64), [Refused(Str)])
literals_of = |program| {
	var $found = Dict.empty()
	for code in program.codes {
		for instruction in code.ops {
			named = match instruction {
				PushText(text) => [text]
				TemplatePart(text) => [text]
				GetProperty(key, _) => [key]
				MethodLookup(key, _) => [key]
				SetProperty(key, _) => [key]
				SetField(key) => [key]
				PropertiesLeft({ keys, at: _ }) => keys
				# The ReferenceError's message of a variable read or written
				# before its declaration has run.
				ThrowUnready({ name, at: _ }) => [ValueRules.unready_message(name)]
				LoadBoxed({ name, slot: _, at: _ }) => [ValueRules.unready_message(name)]
				StoreBoxed(
					{
						name,
						slot: _,
						kind: _,
						at: _,
					},
				) => [ValueRules.unready_message(name)]
				_ => []
			}
			for text in named {
				if !$found.contains(text) {
					if text.to_utf8().any(|byte| byte >= 0x80) {
						return Err(Refused("a string that is not ASCII is not compiled yet"))
					}
					$found = $found.insert(text, $found.len())
				}
			}
		}
	}
	Ok($found)
}

## Each text's bytes under its label, as the runtime's strings are laid out.
literal_statements : Dict(Str, U64) -> List(Assembly.Statement)
literal_statements = |literals| {
	var $out = []
	for (text, number) in literals.to_list() {
		$out = $out.concat([
			Mark(LoweringBasics.literal_label(number)),
			Data(Runtime.string_data(text)),
		])
	}
	$out
}

## The kinds when a function's code starts: its parameters hold their
## kinds, its declared functions known before the program runs and the
## functions it captures are ready, its other captures hold values, and the
## rest are unready.
start_state : LoweringBasics.Context, Bytecode.Code -> Try(LoweringBasics.State, [Refused(Str)])
start_state = |lowering, code| {
	parameters = match code.arguments {
		Each(count) => count
		Packed(_) => 0
	}
	known = {
		program: lowering.program,
		makers: lowering.makers,
		statics: lowering.statics,
	}
	var $slots = List.repeat(Unready, code.frame_size)
	for slot in 0..<parameters {
		$slots = $slots.set(
			slot,
			Ready(parameter_kind(lowering, slot)),
		) ?? crash "Lowering.start_state: a parameter has a slot"
	}
	match code.arguments {
		Packed(slot) => {
			$slots = $slots.set(slot, Ready(Array)) ?? crash "Lowering.start_state: a packed slot"
		}
		Each(_) => {}
	}
	for step in code.entry {
		match step {
			FreshBox(_) => {}
			FilledBox(slot) => {
				kind =
					if lowering.cells.contains(slot) {
						Value
					} else {
						parameter_kind(lowering, slot)
					}
				$slots = $slots.set(
					slot,
					Ready(kind),
				) ?? crash "Lowering.start_state: a boxed parameter has a slot"
			}
			CapturedBox({ slot, capture: _ }) => {
				kind = match KnownFunctions.held_function(known, { code: lowering.index, slot }) {
					Ok(made) => Function(made)
					Err(Unheld) => Value
				}
				$slots = $slots.set(
					slot,
					Ready(kind),
				) ?? crash "Lowering.start_state: a capture has a slot"
			}
		}
	}
	for (slot, made) in KnownFunctions.declared_functions(code).to_list() {
		if lowering.statics.contains(made) {
			$slots = $slots.set(
				slot,
				Ready(Function(made)),
			) ?? crash "Lowering.start_state: a declaration has a slot"
		}
	}
	Ok({ slots: $slots, stack_kinds: [] })
}

## The places of the instructions a code starts with that declare its
## functions known before the program runs: they make no code, since the
## name holds the function from the start.
skipped_places : LoweringBasics.Context, Bytecode.Code -> List(U64)
skipped_places = |lowering, code| {
	var $out = []
	for (slot, made) in KnownFunctions.declared_functions(code).to_list() {
		if lowering.statics.contains(made) {
			# Each declaration is a `MakeClosure` then its `SetBoxed`.
			at = code.ops.find_first_index(
				|instruction|
					match instruction {
						SetBoxed(set) => set == slot
						_ => False
					},
			) ?? crash "Lowering.skipped_places: a declaration's SetBoxed"
			$out = $out.concat([at - 1, at])
		}
	}
	$out
}

## What one function does that the lowering refuses, and where.
CodeFault : [
	LoopChangesKinds(U64),
	TwoResultKinds,
	TwoStacks(U64),
	TwoSlotKinds(U64),
	FrameTooLarge,
]

## The refusal of a function's fault, the function named.
code_refusal : LoweringBasics.Context, CodeFault -> [Refused(Str)]
code_refusal = |lowering, fault| {
	why = match fault {
		LoopChangesKinds(at) => "a loop's kinds never settle, at instruction ${at.to_str()}"
		TwoResultKinds => "it returns a value and a function"
		TwoStacks(at) => "two ways reach instruction ${at.to_str()} with different stacks"
		TwoSlotKinds(at) => "a variable holds values of two kinds at instruction ${at.to_str()}"
		FrameTooLarge => "its frame is over a megabyte"
	}
	Refused("${LoweringBasics.function_name(lowering)}: ${why}")
}

## What a function lowers to: its machine code, the kind of what it
## returns, and the kinds of the calls it makes.
CodeItems : {
	statements : List(Assembly.Statement),
	result : [Gives(LoweringBasics.Kind), GivesNothing],
	calls : List(LoweringBasics.CallKinds),
	# The functions known before the program runs that it uses as values.
	escaped : List(U64),
}

## One function's machine code: its entry, which makes its frame and
## copies its arguments to their slots, then each instruction's. A loop
## whose body gives a variable another kind than it had at the loop's head
## widens the head to `Value` and lowers the function again. A function
## refused still gives the calls it made before the refusal, so the
## functions it calls learn their parameters' kinds.
code_items : LoweringBasics.Context -> Try(
	CodeItems,
	{ refused : [Refused(Str)], calls : List(LoweringBasics.CallKinds) },
)
code_items = |lowering| {
	var $heads = Dict.empty()
	for _ in 0..<16 {
		match code_walk(lowering, $heads) {
			Ok(Walked(done)) => return Ok(done)
			Ok(Widened({ at, state })) => {
				$heads = $heads.insert(at, state)
			}
			Ok(Halted(halted)) => return Err(halted)
			Err(refused) => return Err({ refused, calls: [] })
		}
	}
	Err({ refused: code_refusal(lowering, LoopChangesKinds(0)), calls: [] })
}

## One pass of `code_items` with the loop heads widened so far.
code_walk : LoweringBasics.Context,
Dict(U64, LoweringBasics.State) -> Try(
	[
		Walked(CodeItems),
		Widened({ at : U64, state : LoweringBasics.State }),
		Halted({ refused : [Refused(Str)], calls : List(LoweringBasics.CallKinds) }),
	],
	[Refused(Str)],
)
code_walk = |lowering, heads| {
	code = lowering.program.codes.get(lowering.index) ?? crash "Lowering.code_items: a code's index"
	match lowering.makers.get(lowering.index) {
		Ok({ form: MakesInstances, .. }) => {
			named = LoweringBasics.function_name(lowering)
			return Err(Refused("${named}: a class is not compiled yet"))
		}
		_ => {}
	}
	start = start_state(lowering, code)?
	skipped = skipped_places(lowering, code)
	var $escaped = []
	var $body = []
	var $pending = Dict.empty()
	var $seen = Dict.empty()
	var $flowing = Flowing(start)
	var $deepest = 0
	var $result = GivesNothing
	var $calls = []
	for at in 0..<code.ops.len() {
		arriving = match ($flowing, $pending.get(at)) {
			(Flowing(state), Ok(waiting)) => {
				# A function known by its code that falls to where a jump
				# brings a value is made a value first.
				made = values_met(lowering, { state, waiting })
				$body = $body.concat(made.statements)
				$escaped = $escaped.concat(made.escaped)
				Arrives(meeting_state(lowering, { at, one: made.state, other: waiting })?)
			}
			(Flowing(state), Err(_)) => Arrives(state)
			(Stopped, Ok(waiting)) => Arrives(waiting)
			(Stopped, Err(_)) => Unreached
		}
		$body = $body.append(Mark(LoweringBasics.place_label(lowering, at)))
		match arriving {
			Unreached => {
				$flowing = Stopped
			}
			Arrives(reached) => {
				state = match heads.get(at) {
					Ok(head) => meeting_state(lowering, { at, one: reached, other: head })?
					Err(_) => reached
				}
				$seen = $seen.insert(at, state)
				instruction = code.ops.get(at) ?? crash "Lowering.code_items: an instruction"
				site = { lowering, code, at, skipped }
				valued =
					if skipped.contains(at) {
						{ statements: [], state, escaped: [] }
					} else {
						values_made(site, { instruction, state })
					}
				$escaped = $escaped.concat(valued.escaped)
				$calls = match call_kinds(lowering, { instruction, state: valued.state }) {
					Ok(call) => $calls.append(call)
					Err(NoCall) => $calls
				}
				lowered = match instruction_items(site, { instruction, state: valued.state }) {
					Ok(done) => done
					Err(refused) => return Ok(Halted({ refused, calls: $calls }))
				}
				$body = $body.concat(valued.statements).concat(lowered.statements)
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
								return Ok(Widened({ at: target, state: again }))
							}
						}
				}
				$result = match (lowered.result, $result) {
					(GivesNothing, _) => $result
					(Gives(kind), GivesNothing) => Gives(kind)
					(Gives(kind), Gives(before)) =>
						match LoweringBasics.met_kind(kind, before) {
							Ok(met) => Gives(met)
							Err(Apart) => return Err(code_refusal(lowering, TwoResultKinds))
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
	Ok(
		Walked({
			statements,
			result: $result,
			calls: $calls,
			escaped: $escaped,
		}),
	)
}

## The kinds of a call's arguments, when the instruction calls a declared
## function with as many arguments as it has parameters, each a value.
call_kinds : LoweringBasics.Context,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
} -> Try(LoweringBasics.CallKinds, [NoCall])
call_kinds = |lowering, { instruction, state }|
	match instruction {
		Call({ count, written: _, at: _ }) =>
			match LoweringBasics.kind_below(state, count) {
				Function(made) | Closure(made) => {
					callee = lowering.program.codes.get(made) ?? crash "Lowering.call_kinds: a code"
					kinds = state.stack_kinds.take_last(count)
					if callee.arguments == Each(count) and kinds.all(LoweringBasics.is_value_kind) {
						Ok({ code: made, kinds })
					} else {
						Err(NoCall)
					}
				}
				_ => Err(NoCall)
			}
		_ => Err(NoCall)
	}

## A function's entries: `rbp` saved and set, its frame made below it,
## each cell it captures copied from its closure record (`rbx`) to its
## slot, and each parameter copied from where the caller pushed it to its
## slot. A function a value may hold has a second entry before it, for a
## call through the value, which takes as many arguments as `rcx` says: a
## parameter past them is `undefined`, an argument past the parameters
## unread. A function whose parameters have a pattern, a default or a rest
## takes its arguments as a call through a value passes them, by either
## entry, and packs them into an array in its slot. Both go on to make the
## cells of its own variables a closure captures.
entry_items : LoweringBasics.Context,
{
	code : Bytecode.Code,
	frame_bytes : U64,
} -> List(Assembly.Statement)
entry_items = |lowering, { code, frame_bytes }| {
	index = lowering.index
	parameters = match code.arguments {
		Each(count) => count
		Packed(_) => 0
	}
	prologue = [
		Instruction(Push(Rbp)),
		Instruction(MovRegReg({ to: Rbp, from: Rsp })),
		Instruction(
			AluImm({
				operation: Sub,
				to: Rsp,
				value: frame_bytes.to_i32_wrap(),
			}),
		),
		Emit.cmp(Rsp, R12),
		Emit.jcc(B, Runtime.stack_overflow),
	]
	argument = |slot| Emit.mem(Rbp, (16 + 8 * slot).to_i64_wrap())
	var $captured = []
	var $cells = []
	for step in code.entry {
		match step {
			CapturedBox({ slot, capture }) =>
				if lowering.cells.contains(slot) {
					$captured = $captured.concat([
						Emit.load(Rax, Emit.mem(Rbx, (24 + 8 * capture).to_i64_wrap())),
						Emit.store(LoweringBasics.slot_place(slot), Rax),
					])
				}
			FreshBox(slot) =>
				if lowering.cells.contains(slot) {
					$cells = $cells.concat([
						Emit.imm(Rsi, Boxing.undefined_bits),
						Emit.call(Runtime.new_cell),
						Emit.store(LoweringBasics.slot_place(slot), Rax),
					])
				}
			FilledBox(slot) =>
				if lowering.cells.contains(slot) {
					$cells = $cells.concat([
						Emit.load(Rsi, LoweringBasics.slot_place(slot)),
						Emit.call(Runtime.new_cell),
						Emit.store(LoweringBasics.slot_place(slot), Rax),
					])
				}
		}
	}
	packed = match code.arguments {
		Packed(slot) => [
			Emit.lea(Rdi, argument(0)),
			Emit.mov(Rsi, Rcx),
			Emit.call(Runtime.pack),
			Emit.store(LoweringBasics.slot_place(slot), Rax),
		]
		Each(_) => []
	}
	var $direct = packed
	var $counted = packed
	for slot in 0..<parameters {
		missing = "${LoweringBasics.value_label(index)}_missing_${slot.to_str()}"
		got = "${LoweringBasics.value_label(index)}_got_${slot.to_str()}"
		$direct = $direct.concat([
			Emit.load(Rax, argument(slot)),
			Emit.store(LoweringBasics.slot_place(slot), Rax),
		])
		$counted = $counted.concat([
			Emit.cmp_imm(Rcx, slot.to_i64_wrap()),
			Emit.jcc(Be, missing),
			Emit.load(Rax, argument(slot)),
			Emit.jmp(got),
			Emit.mark(missing),
			Emit.imm(Rax, Boxing.undefined_bits),
			Emit.mark(got),
			Emit.store(LoweringBasics.slot_place(slot), Rax),
		])
	}
	through_value =
		if lowering.escaped_codes.contains(index) {
			[Mark(LoweringBasics.value_label(index))]
				.concat(prologue)
				.concat($captured)
				.concat($counted)
				.append(Emit.jmp(LoweringBasics.start_label(index)))
		} else {
			[]
		}
	through_value
		.append(Mark(LoweringBasics.code_label(index)))
		.concat(prologue)
		.concat($captured)
		.concat($direct)
		.append(Mark(LoweringBasics.start_label(index)))
		.concat($cells)
}

## The functions known before the program runs among the values an
## instruction takes from the top of the stack, made values: each one's
## closure record, boxed, written in its place, which takes its kind.
values_made : LoweringBasics.Site,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
} -> Valued
values_made = |site, { instruction, state }| {
	depth = state.stack_kinds.len()
	taken = U64.min(taken_count(instruction), depth)
	var $items = []
	var $kinds = state.stack_kinds
	var $escaped = []
	for down in 0..<taken {
		place = depth - 1 - down
		match $kinds.get(place) {
			Ok(Function(made)) => {
				$items = $items.concat([
					Emit.address_of(Rax, LoweringBasics.closure_label(made)),
					Emit.imm(Rcx, Boxing.tag_bits(Boxing.function_tag)),
					Emit.plus(Rax, Rcx),
					Emit.store(LoweringBasics.stack_place(site.code, place), Rax),
				])
				$kinds = $kinds.set(
					place,
					Closure(made),
				) ?? crash "Lowering.values_made: a place on the stack"
				$escaped = $escaped.append(made)
			}
			_ => {}
		}
	}
	{
		statements: $items,
		state: { ..state, stack_kinds: $kinds },
		escaped: $escaped,
	}
}

## The state falling to a place a jump reaches with `waiting`, each place
## on its stack holding a function known by its code where the jump brings
## a value made that value: its closure record, boxed, as `values_made`
## makes one.
values_met : LoweringBasics.Context,
{
	state : LoweringBasics.State,
	waiting : LoweringBasics.State,
} -> Valued
values_met = |lowering, { state, waiting }| {
	code = lowering.program.codes.get(lowering.index) ?? crash "Lowering.values_met: a code's index"
	var $items = []
	var $kinds = state.stack_kinds
	var $escaped = []
	for (place, (kind, other)) in List.map2(
		state.stack_kinds,
		waiting.stack_kinds,
		|a, b| (a, b),
	).map_with_index(|pair, place| (place, pair)) {
		match kind {
			Function(made) if LoweringBasics.is_value_kind(other) => {
				$items = $items.concat([
					Emit.address_of(Rax, LoweringBasics.closure_label(made)),
					Emit.imm(Rcx, Boxing.tag_bits(Boxing.function_tag)),
					Emit.plus(Rax, Rcx),
					Emit.store(LoweringBasics.stack_place(code, place), Rax),
				])
				$kinds = $kinds.set(place, Closure(made)) ?? crash "Lowering.values_met: a place"
				$escaped = $escaped.append(made)
			}
			_ => {}
		}
	}
	{
		statements: $items,
		state: { ..state, stack_kinds: $kinds },
		escaped: $escaped,
	}
}

## An instruction's values made: the code that makes them, the state
## after, and the functions it made values of.
Valued : {
	statements : List(Assembly.Statement),
	state : LoweringBasics.State,
	escaped : List(U64),
}

## How many values on top of the stack an instruction takes as values (a
## call its arguments, not what it calls).
taken_count : Bytecode.Op -> U64
taken_count = |instruction|
	match instruction {
		StoreLocal(_) | SetLocal(_) | SetBoxed(_) | Return | SetField(_) | TemplatePart(_) => 1
		StoreBoxed(_) | SetProperty(_, _) | SetIndex(_) | Unary(_, _) | Throw(_) => 1
		JumpIfFalse(_) | SkipIfFalsy(_) | SkipIfTruthy(_) => 1
		AppendItem | AppendSpread(_) | SpreadFields(_) | CallMethodSpread(_) => 1
		Binary(_, _) | CallSpread(_) => 2
		MakeArray(count) => count
		Call({ count, written: _, at: _ }) => count
		CallMethod({ name: _, site: { count, written: _, at: _ } }) => count
		_ => 0
	}

## The state at a place two ways reach: the same stack, and each slot ready
## with one kind, or unready on either way.
meeting_state : LoweringBasics.Context,
{
	at : U64,
	one : LoweringBasics.State,
	other : LoweringBasics.State,
} -> Try(LoweringBasics.State, [Refused(Str)])
meeting_state = |lowering, { at, one, other }| {
	if one.stack_kinds.len() != other.stack_kinds.len() {
		return Err(code_refusal(lowering, TwoStacks(at)))
	}
	var $stack_kinds = []
	for (a, b) in List.map2(
		one.stack_kinds,
		other.stack_kinds,
		|a, b| (a, b),
	) {
		match LoweringBasics.met_kind(a, b) {
			Ok(kind) => {
				$stack_kinds = $stack_kinds.append(kind)
			}
			Err(Apart) => return Err(code_refusal(lowering, TwoStacks(at)))
		}
	}
	var $slots = []
	for (a, b) in List.map2(
		one.slots,
		other.slots,
		|a, b| (a, b),
	) {
		slot = match (a, b) {
			(Ready(left), Ready(right)) =>
				match LoweringBasics.met_kind(left, right) {
					Ok(kind) => Ready(kind)
					Err(Apart) => return Err(code_refusal(lowering, TwoSlotKinds(at)))
				}
			(Unready, Unready) => Unready
			_ => Unsure
		}
		$slots = $slots.append(slot)
	}
	Ok({ slots: $slots, stack_kinds: $stack_kinds })
}

## A binary operator on the two values on top of the stack, its answer in
## the place of the first.
binary_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	operator : Ast.BinaryOperator,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
binary_items = |site, { state, operator }| {
	left = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 2)
	right = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
	kinds = (LoweringBasics.kind_below(state, 1), LoweringBasics.kind_below(state, 0))
	loaded = [
		Instruction(MovsdLoad({ to: Xmm0, from: left })),
		Instruction(MovsdLoad({ to: Xmm1, from: right })),
	]
	arithmetic = |operation|
		LoweringBasics.falling(
			loaded.concat([
				Instruction(Sse({ operation, to: Xmm0, from: Xmm1 })),
				Instruction(MovsdStore({ to: left, from: Xmm0 })),
			]),
			LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
		)
	# The flags of a `ucomisd` leave CF and ZF clear only when the first is
	# the greater and neither is a NaN, so `a < b` is `b > a`.
	ordered = |{ first, second, condition }|
		LoweringBasics.falling(
			[
				Instruction(MovsdLoad({ to: Xmm0, from: first })),
				Instruction(MovsdLoad({ to: Xmm1, from: second })),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
				Instruction(Setcc({ condition, to: Al })),
			]
				.concat(LoweringBasics.boolean_items)
				.append(Instruction(MovMemReg({ to: left, from: Rax }))),
			LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
		)
	# Two doubles are equal when ZF is set and PF, the NaN's flag, is not.
	equality = |{ same, parity, joined }|
		LoweringBasics.falling(
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
				Emit.imm(Rcx, Boxing.false_bits),
				Emit.plus(Rax, Rcx),
				Instruction(MovMemReg({ to: left, from: Rax })),
			]),
			LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
		)
	booleans_compared = |condition|
		LoweringBasics.falling(
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
			]
				.concat(LoweringBasics.boolean_items)
				.append(Instruction(MovMemReg({ to: left, from: Rax }))),
			LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
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
		(StrictEqual, _) | (StrictNotEqual, _) =>
			dynamic_equality_items(site, { state, operator, kinds })
		(Add, _) =>
			match LoweringBasics.added_kind(kinds) {
				Ok(kind) =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, left),
								Emit.load(Rsi, right),
								Emit.call(Runtime.add),
								Emit.store(left, Rax),
							],
							LoweringBasics.with_top(LoweringBasics.without_top(state, 2), kind),
						),
					)
				Err(Unadded) => {
					first = LoweringBasics.kind_phrase(kinds.0)
					second = LoweringBasics.kind_phrase(kinds.1)
					LoweringBasics.refusal(site, "`+` of ${first} and ${second} isn't compiled")
				}
			}
		(Subtract, _)
		| (Multiply, _)
		| (
			Divide,
			_,
		) if LoweringBasics.is_numeric(kinds.0) and LoweringBasics.is_numeric(kinds.1) => {
			operation = match operator {
				Subtract => Subsd
				Multiply => Mulsd
				_ => Divsd
			}
			checked = LoweringBasics.number_check_items({ kind: kinds.0, place: left })
				.concat(LoweringBasics.number_check_items({ kind: kinds.1, place: right }))
			done = arithmetic(operation)
			Ok({ ..done, statements: checked.concat(done.statements) })
		}
		(Less, _)
		| (LessOrEqual, _)
		| (Greater, _)
		| (GreaterOrEqual, _) if LoweringBasics.is_ordered(kinds) => {
			mapped = match operator {
				Less => [Emit.cmp_imm(Rax, 0), Instruction(Setcc({ condition: E, to: Al }))]
				LessOrEqual => [Emit.cmp_imm(Rax, 1), Instruction(Setcc({ condition: Be, to: Al }))]
				Greater => [Emit.cmp_imm(Rax, 2), Instruction(Setcc({ condition: E, to: Al }))]
				_ => [
					Emit.minus_imm(Rax, 1),
					Emit.cmp_imm(Rax, 1),
					Instruction(Setcc({ condition: Be, to: Al })),
				]
			}
			Ok(
				LoweringBasics.falling(
					[
						Emit.load(Rdi, left),
						Emit.load(Rsi, right),
						Emit.call(Runtime.compare),
					]
						.concat(mapped)
						.concat(LoweringBasics.boolean_items)
						.append(Emit.store(left, Rax)),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
				),
			)
		}
		(
			Remainder,
			_,
		) if LoweringBasics.is_numeric(kinds.0) and LoweringBasics.is_numeric(kinds.1) =>
			Ok(
				LoweringBasics.falling(
					[
						Emit.load(Rdi, left),
						Emit.load(Rsi, right),
						Emit.call(Runtime.remainder),
						Emit.store(left, Rax),
					],
					LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
				),
			)
		(Power, _) if LoweringBasics.is_numeric(kinds.0) and LoweringBasics.is_numeric(kinds.1) => {
			checked = LoweringBasics.number_check_items({ kind: kinds.0, place: left })
				.concat(LoweringBasics.number_check_items({ kind: kinds.1, place: right }))
			Ok(
				LoweringBasics.falling(
					checked.concat([
						Emit.load(Rdi, left),
						Emit.load(Rsi, right),
						Emit.call(Runtime.power),
						Emit.store(left, Rax),
					]),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
				),
			)
		}
		_ => {
			named = Str.inspect(operator)
			first = LoweringBasics.kind_phrase(kinds.0)
			second = LoweringBasics.kind_phrase(kinds.1)
			LoweringBasics.refusal(site, "`${named}` of ${first} and ${second} is not compiled yet")
		}
	}
}

## `===` or `!==` of two values whose kinds aren't both numbers or both
## booleans: settled here when their kinds are known to differ, and by
## `runtime_strict_equal` otherwise.
dynamic_equality_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	operator : Ast.BinaryOperator,
	kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
dynamic_equality_items = |site, { state, operator, kinds }| {
	left = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 2)
	right = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
	(one, other) = kinds
	if !LoweringBasics.is_value_kind(one) or !LoweringBasics.is_value_kind(other) {
		return LoweringBasics.refusal(
			site,
			"`===` of ${LoweringBasics.kind_phrase(one)} and ${LoweringBasics.kind_phrase(other)}",
		)
	}
	flipped = match operator {
		StrictNotEqual => [
			Instruction(
				AluImm({
					operation: Xor,
					to: Rax,
					value: 1,
				}),
			),
		]
		_ => []
	}
	settled = one != other and one != Value and other != Value
	compared =
		if settled {
			[Emit.imm(Rax, Boxing.false_bits)]
		} else {
			[
				Emit.load(Rdi, left),
				Emit.load(Rsi, right),
				Emit.call(Runtime.strict_equal),
			]
		}
	Ok(
		LoweringBasics.falling(
			compared.concat(flipped).append(Emit.store(left, Rax)),
			LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
		),
	)
}

## A unary operator on the value on top of the stack.
unary_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	operator : Ast.UnaryOperator,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
unary_items = |site, { state, operator }| {
	top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
	match (operator, LoweringBasics.kind_below(state, 0)) {
		(Negate, Number) =>
			Ok(
				LoweringBasics.falling(
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
		(Plus, Number) => Ok(LoweringBasics.falling([], state))
		(Not, Boolean) =>
			Ok(
				LoweringBasics.falling(
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
			tested = LoweringBasics.truth_items(site, state)?
			Ok(
				LoweringBasics.falling(
					tested
						.append(Instruction(Setcc({ condition: E, to: Al })))
						.concat(LoweringBasics.boolean_items)
						.append(Instruction(MovMemReg({ to: top, from: Rax }))),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Boolean),
				),
			)
		}
		(Negate, Value) | (Plus, Value) => {
			negated = match operator {
				Negate => [
					Emit.imm(Rcx, (0x8000000000000000).to_i64_wrap()),
					Instruction(
						Alu({
							operation: Xor,
							to: Rax,
							from: Rcx,
						}),
					),
				]
				_ => []
			}
			Ok(
				LoweringBasics.falling(
					[Emit.load(Rax, top), Emit.call(Runtime.check_number)]
						.concat(negated)
						.append(Emit.store(top, Rax)),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Number),
				),
			)
		}
		(Not, kind) if LoweringBasics.is_value_kind(kind) => {
			tested = LoweringBasics.truth_items(site, state)?
			Ok(
				LoweringBasics.falling(
					tested
						.append(Instruction(Setcc({ condition: E, to: Al })))
						.concat(LoweringBasics.boolean_items)
						.append(Emit.store(top, Rax)),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Boolean),
				),
			)
		}
		(TypeOf, kind) => {
			named = match kind {
				Number => Named("runtime_text_type_number")
				String => Named("runtime_text_type_string")
				Boolean => Named("runtime_text_type_boolean")
				Undefined => Named("runtime_text_undefined")
				Null | Array | Object | Console => Named("runtime_text_type_object")
				Function(_) | Closure(_) | Log | Method(_) => Named("runtime_text_type_function")
				ErrorClass(_) | StaticMethod(_) => Named("runtime_text_type_function")
				CollectionClass(_) | TimerFunction(_) => Named("runtime_text_type_function")
				Static("Math") => Named("runtime_text_type_object")
				Static(_) => Named("runtime_text_type_function")
				Value => Unnamed
			}
			found = match named {
				Named(label) => [
					Emit.address_of(Rax, label),
					Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)),
					Emit.plus(Rax, Rcx),
				]
				Unnamed => [Emit.load(Rdi, top), Emit.call(Runtime.type_of)]
			}
			Ok(
				LoweringBasics.falling(
					found.append(Emit.store(top, Rax)),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), String),
				),
			)
		}
		(_, kind) => LoweringBasics.refusal(
			site,
			"`${Str.inspect(operator)}` of ${LoweringBasics.kind_phrase(kind)} is not compiled yet",
		)
	}
}

## A jump taken, the value on top kept, when it is not `null` or
## `undefined` (`??`'s) or not `undefined` (a default's); otherwise the
## value is dropped and the next instruction follows.
defined_jump_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	skip : U64,
	settles : [Defined, NotUndefined],
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
defined_jump_items = |site, { state, skip, settles }| {
	kind = LoweringBasics.kind_below(state, 0)
	if !LoweringBasics.is_value_kind(kind) {
		return LoweringBasics.refusal(
			site,
			"`??` or a default of ${LoweringBasics.kind_phrase(kind)}",
		)
	}
	top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
	# `undefined` and `null` differ in their lowest bit alone.
	tested = match settles {
		Defined => [
			Emit.load(Rax, top),
			Instruction(
				AluImm({
					operation: Or,
					to: Rax,
					value: 1,
				}),
			),
			Emit.imm(Rcx, Boxing.null_bits),
			Emit.cmp(Rax, Rcx),
		]
		NotUndefined => [
			Emit.load(Rax, top),
			Emit.imm(Rcx, Boxing.undefined_bits),
			Emit.cmp(Rax, Rcx),
		]
	}
	target = LoweringBasics.forward(site, skip)
	Ok({
		statements: tested.append(Emit.jcc(Ne, LoweringBasics.place_label(site.lowering, target))),
		falls: Falls(LoweringBasics.without_top(state, 1)),
		branch: Branch({ target, state }),
		result: GivesNothing,
	})
}

## A `switch`'s case: the two values on top compared by `===`, both
## dropped, and the jump taken when they are the same.
same_jump_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	skip : U64,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
same_jump_items = |site, { state, skip }| {
	compared = binary_items(site, { state, operator: StrictEqual })?
	after = match compared.falls {
		Falls(next) => next
		Ends => crash "Lowering.same_jump_items: a comparison falls through"
	}
	target = LoweringBasics.forward(site, skip)
	dropped = LoweringBasics.without_top(after, 1)
	Ok({
		statements: compared.statements.concat([
			Emit.load(Rax, LoweringBasics.stack_place(site.code, after.stack_kinds.len() - 1)),
			Emit.imm(Rcx, Boxing.true_bits),
			Emit.cmp(Rax, Rcx),
			Emit.jcc(E, LoweringBasics.place_label(site.lowering, target)),
		]),
		falls: Falls(dropped),
		branch: Branch({ target, state: dropped }),
		result: GivesNothing,
	})
}

## A call: of a function known by its code, directly, `rbx` holding its
## closure record when it has one; of any other value, through it.
call_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	count : U64,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
call_items = |site, { state, count }| {
	callee_place = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - count - 1)
	match LoweringBasics.kind_below(state, count) {
		Function(made) => direct_call_items(site, { state, count, made, record_statements: [] })
		Closure(made) => {
			codes = site.lowering.program.codes
			callee = codes.get(made) ?? crash "Lowering.call_items: a function's code"
			takes_count = match callee.arguments {
				Each(parameters) => parameters == count
				Packed(_) => True
			}
			if takes_count {
				record_statements = [
					Emit.load(Rbx, callee_place),
					Emit.shl(Rbx, 16),
					Emit.shr(Rbx, 16),
				]
				direct_call_items(site, { state, count, made, record_statements })
			} else {
				value_call_items(site, { state, count, taken: count + 1 })
			}
		}
		Value => value_call_items(site, { state, count, taken: count + 1 })
		TimerFunction(name) => timer_items(site, { state, count, name })
		# node's TypeError for `Map()` or `Set()` without `new`.
		CollectionClass(name) =>
			Ok({
				statements: [
					Emit.address_of(Rsi, Runtime.new_required_text(name)),
					Emit.address_of(Rdi, Runtime.error_name_label("TypeError")),
					Emit.call(Runtime.new_error),
					Emit.jmp(Runtime.throw),
				],
				falls: Ends,
				branch: NoBranch,
				result: GivesNothing,
			})
		Static("String") => {
			made =
				if count == 0 {
					[
						Emit.address_of(Rax, "runtime_text_empty"),
						Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)),
						Emit.plus(Rax, Rcx),
					]
				} else if LoweringBasics.is_value_kind(
					LoweringBasics.kind_below(state, count - 1),
				) {
					argument = LoweringBasics.stack_place(
						site.code,
						state.stack_kinds.len() - count,
					)
					[Emit.load(Rdi, argument), Emit.call(Runtime.text_of_boxed)]
				} else {
					phrase = LoweringBasics.kind_phrase(LoweringBasics.kind_below(state, count - 1))
					return LoweringBasics.refusal(site, "`String` of ${phrase}")
				}
			Ok(
				LoweringBasics.falling(
					made.append(Emit.store(callee_place, Rax)),
					LoweringBasics.with_top(LoweringBasics.without_top(state, count + 1), String),
				),
			)
		}
		kind => LoweringBasics.refusal(site, "a call of ${LoweringBasics.kind_phrase(kind)}")
	}
}

## A direct call of the function `made`: its arguments pushed, the last
## first, the call, and its result in the callee's place.
direct_call_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	count : U64,
	made : U64,
	record_statements : List(Assembly.Statement),
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
direct_call_items = |site, { state, count, made, record_statements }| {
	callee = site.lowering.program.codes.get(made) ?? crash "Lowering.call_items: a function's code"
	counted = match callee.arguments {
		Each(parameters) =>
			if parameters != count {
				given = LoweringBasics.count_text(count, "argument")
				taken = LoweringBasics.count_text(parameters, "parameter")
				return LoweringBasics.refusal(site, "a call with ${given} to ${taken}")
			} else {
				[]
			}
		Packed(_) => [Emit.imm(Rcx, count.to_i64_wrap())]
	}
	base = state.stack_kinds.len() - count - 1
	pushed = arguments_pushed(site, { state, count })?
	call = CallTo(LoweringBasics.code_label(made))
	var $items = record_statements.concat(pushed).concat(counted).append(call)
	if count > 0 {
		$items = $items.append(Emit.plus_imm(Rsp, (8 * count).to_i64_wrap()))
	}
	result = site.lowering.returns.get(made) ?? crash "Lowering.call_items: a result"
	Ok(
		LoweringBasics.falling(
			$items.append(
				Instruction(
					MovMemReg({ to: LoweringBasics.stack_place(site.code, base), from: Rax }),
				),
			),
			LoweringBasics.with_top(LoweringBasics.without_top(state, count + 1), result),
		),
	)
}

## The `count` arguments on top of the stack pushed, the last first.
arguments_pushed : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	count : U64,
} -> Try(List(Assembly.Statement), [Refused(Str)])
arguments_pushed = |site, { state, count }| {
	base = state.stack_kinds.len() - count
	var $items = []
	for back in 0..<count {
		argument = count - 1 - back
		if !LoweringBasics.is_value_kind(LoweringBasics.kind_below(state, back)) {
			return LoweringBasics.refusal(
				site,
				"a call with a function, `console` or a method as an argument",
			)
		}
		$items = $items.concat([
			Emit.load(Rax, LoweringBasics.stack_place(site.code, base + argument)),
			Emit.save(Rax),
		])
	}
	Ok($items)
}

## A call through the value below the `count` arguments on top of the
## stack: stopped unless it is a function, else its record in `rbx`, the
## arguments pushed, their count in `rcx`, and a call of its value entry.
## The result, a `Value`, takes the place of the `taken` values on top (the
## callee and the arguments, and a method call's receiver).
value_call_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	count : U64,
	taken : U64,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
value_call_items = |site, { state, count, taken }| {
	depth = state.stack_kinds.len()
	pushed = arguments_pushed(site, { state, count })?
	var $items = [
		Emit.load(Rax, LoweringBasics.stack_place(site.code, depth - count - 1)),
		Emit.call(Runtime.check_function),
		Emit.shl(Rax, 16),
		Emit.shr(Rax, 16),
		Emit.mov(Rbx, Rax),
	]
		.concat(pushed)
		.concat([
			Emit.load(Rax, Emit.mem(Rbx, 0)),
			Emit.plus(Rax, Rbx),
			Emit.imm(Rcx, count.to_i64_wrap()),
			Instruction(CallReg(Rax)),
		])
	if count > 0 {
		$items = $items.append(Emit.plus_imm(Rsp, (8 * count).to_i64_wrap()))
	}
	result_place = LoweringBasics.stack_place(site.code, depth - taken)
	Ok(
		LoweringBasics.falling(
			$items.append(Emit.store(result_place, Rax)),
			LoweringBasics.with_top(LoweringBasics.without_top(state, taken), Value),
		),
	)
}

## A closure made as the program runs: its record taken from the heap, the
## distances to its value entry and its text, and the address of each cell
## it captures (0 for a function known before the program runs), boxed at
## `place`.
record_items : LoweringBasics.Site,
{
	made : U64,
	captures : List(U64),
	place : X86.Mem,
} -> List(Assembly.Statement)
record_items = |site, { made, captures, place }| {
	count = captures.len()
	var $items = [
		Emit.imm(Rdi, (24 + 8 * count).to_i64_wrap()),
		Emit.call(Runtime.allocate),
		Emit.address_of(Rcx, LoweringBasics.value_label(made)),
		Emit.minus(Rcx, Rax),
		Emit.store(Emit.mem(Rax, 0), Rcx),
		Emit.address_of(Rcx, LoweringBasics.function_text_label(made)),
		Emit.minus(Rcx, Rax),
		Emit.minus_imm(Rcx, 8),
		Emit.store(Emit.mem(Rax, 8), Rcx),
		Emit.imm(Rcx, count.to_i64_wrap()),
		Emit.store(Emit.mem(Rax, 16), Rcx),
	]
	for (capture, from) in captures.map_with_index(|from, capture| (capture, from)) {
		held =
			if site.lowering.cells.contains(from) {
				Emit.load(Rcx, LoweringBasics.slot_place(from))
			} else {
				Emit.zero(Rcx)
			}
		field = Emit.mem(Rax, (24 + 8 * capture).to_i64_wrap())
		$items = $items.concat([held, Emit.store(field, Rcx)])
	}
	$items.concat([
		Emit.imm(Rcx, Boxing.tag_bits(Boxing.function_tag)),
		Emit.plus(Rax, Rcx),
		Emit.store(place, Rax),
	])
}

## A cell's value pushed, or a plain slot's.
boxed_load_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	slot : U64,
} -> List(Assembly.Statement)
boxed_load_items = |site, { state, slot }|
	if site.lowering.cells.contains(slot) {
		[
			Emit.load(Rax, LoweringBasics.slot_place(slot)),
			Emit.load(Rax, Emit.mem(Rax, 0)),
			Emit.store(LoweringBasics.stack_place(site.code, state.stack_kinds.len()), Rax),
		]
	} else {
		LoweringBasics.load_items(site, { state, slot })
	}

## The value on top of the stack stored in a cell, or in a plain slot.
boxed_store_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	slot : U64,
} -> List(Assembly.Statement)
boxed_store_items = |site, { state, slot }|
	if site.lowering.cells.contains(slot) {
		[
			Emit.load(Rcx, LoweringBasics.slot_place(slot)),
			Emit.load(Rax, LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)),
			Emit.store(Emit.mem(Rcx, 0), Rax),
		]
	} else {
		LoweringBasics.store_items(site, { state, slot })
	}

## `++` or `--` of a cell's value, checked a number: the cell stepped, and
## the old value (postfix) or the new (prefix) pushed.
cell_update_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	slot : U64,
	step : Bytecode.Update,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
cell_update_items = |site, { state, slot, step }| {
	_ = LoweringBasics.slot_kind(site, { state, slot, name: "a variable" })?
	top = LoweringBasics.stack_place(site.code, state.stack_kinds.len())
	old = [
		Emit.load(Rax, LoweringBasics.slot_place(slot)),
		Emit.load(Rax, Emit.mem(Rax, 0)),
		Emit.call(Runtime.check_number),
	]
	stepped = [
		Emit.to_xmm(Xmm0, Rax),
		Emit.imm(Rax, step.delta.to_bits().to_i64_wrap()),
		Emit.to_xmm(Xmm1, Rax),
		Instruction(
			Sse({
				operation: Addsd,
				to: Xmm0,
				from: Xmm1,
			}),
		),
		Emit.load(Rcx, LoweringBasics.slot_place(slot)),
		Instruction(MovsdStore({ to: Emit.mem(Rcx, 0), from: Xmm0 })),
	]
	items = match step.fixity {
		Postfix => old.append(Emit.store(top, Rax)).concat(stepped)
		Prefix => old.concat(stepped).append(Instruction(MovsdStore({ to: top, from: Xmm0 })))
	}
	Ok(LoweringBasics.falling(items, LoweringBasics.with_top(state, Number)))
}

## `console.log` of the values on top of the stack: each written as node
## writes it, a space between, then a newline.
log_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	count : U64,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
log_items = |site, { state, count }| {
	base = state.stack_kinds.len() - count
	var $items = []
	for argument in 0..<count {
		if argument > 0 {
			$items = $items.concat(Runtime.text_items(Space))
		}
		place = LoweringBasics.stack_place(site.code, base + argument)
		written = match LoweringBasics.kind_below(state, count - 1 - argument) {
			Number => [
				Instruction(MovRegMem({ to: Rax, from: place })),
				CallTo(Runtime.print_number),
			]
			kind if LoweringBasics.is_value_kind(kind) => [
				Instruction(MovRegMem({ to: Rdi, from: place })),
				CallTo(Runtime.write_value),
			]
			kind => return LoweringBasics.refusal(
				site,
				"console.log of ${LoweringBasics.kind_phrase(kind)} is not compiled yet",
			)
		}
		$items = $items.concat(written)
	}
	$items = $items.concat(Runtime.text_items(Newline))
	Ok(
		LoweringBasics.falling(
			$items,
			LoweringBasics.with_top(LoweringBasics.without_top(state, count + 2), Undefined),
		),
	)
}

## A builtin read: `console`, `NaN` and `Infinity`, and no other yet.
builtin_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	place : U64,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
builtin_items = |site, { state, place }| {
	top = LoweringBasics.stack_place(site.code, state.stack_kinds.len())
	match Ast.global_names_of(Core).get(place) {
		Ok("console") => Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Console)))
		Ok("NaN") => Ok(
			LoweringBasics.falling(
				LoweringBasics.constant_items({ bits: 0x7FF8000000000000, to: top }),
				LoweringBasics.with_top(state, Number),
			),
		)
		Ok("Infinity") => Ok(
			LoweringBasics.falling(
				LoweringBasics.constant_items({ bits: 0x7FF0000000000000, to: top }),
				LoweringBasics.with_top(state, Number),
			),
		)
		Ok(name) if error_names.contains(name) => Ok(
			LoweringBasics.falling([], LoweringBasics.with_top(state, ErrorClass(name))),
		)
		Ok(name) if name == "Map" or name == "Set" =>
			Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, CollectionClass(name))))
		Ok(name) if timer_names.contains(name) => Ok(
			LoweringBasics.falling([], LoweringBasics.with_top(state, TimerFunction(name))),
		)
		Ok(name) if static_names.contains(name) => Ok(
			LoweringBasics.falling([], LoweringBasics.with_top(state, Static(name))),
		)
		Ok(name) => LoweringBasics.refusal(site, "the builtin `${name}` is not compiled yet")
		Err(_) => crash "Lowering.builtin_items: a builtin's place"
	}
}

## node's TypeError for a constant assigned or stepped, thrown.
constant_assigned_items : LoweringBasics.Lowered
constant_assigned_items = {
	statements: [
		Emit.address_of(Rsi, Runtime.constant_assigned_text),
		Emit.address_of(Rdi, Runtime.error_name_label("TypeError")),
		Emit.call(Runtime.new_error),
		Emit.jmp(Runtime.throw),
	],
	falls: Ends,
	branch: NoBranch,
	result: GivesNothing,
}

## node's ReferenceError for a variable read or written before its
## declaration has run, thrown.
unready_items : LoweringBasics.Site, Str -> LoweringBasics.Lowered
unready_items = |site, name| {
	statements: [
		Emit.address_of(Rsi, LoweringBasics.text_label(site, ValueRules.unready_message(name))),
		Emit.address_of(Rdi, Runtime.error_name_label("ReferenceError")),
		Emit.call(Runtime.new_error),
		Emit.jmp(Runtime.throw),
	],
	falls: Ends,
	branch: NoBranch,
	result: GivesNothing,
}

## An optional link: `undefined` or `null` on top ends the chain, its
## answer `undefined`, by a jump to the chain's end. A kind known to be
## neither makes no code, and one known to be either only the jump.
nullish_jump_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	skip : U64,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
nullish_jump_items = |site, { state, skip }| {
	target = LoweringBasics.forward(site, skip)
	top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
	shorted = LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Undefined)
	short_label = "${LoweringBasics.place_label(site.lowering, site.at)}_short"
	going_label = "${LoweringBasics.place_label(site.lowering, site.at)}_going"
	jumped = LoweringBasics.constant_items({ bits: Boxing.undefined_bits.to_u64_wrap(), to: top })
		.append(JmpTo(LoweringBasics.place_label(site.lowering, target)))
	match LoweringBasics.kind_below(state, 0) {
		Undefined | Null =>
			Ok({
				statements: jumped,
				falls: Ends,
				branch: Branch({ target, state: shorted }),
				result: GivesNothing,
			})
		Value => {
			tested = [
				Emit.load(Rax, top),
				Emit.imm(Rcx, Boxing.undefined_bits),
				Emit.cmp(Rax, Rcx),
				Emit.jcc(E, short_label),
				Emit.imm(Rcx, Boxing.null_bits),
				Emit.cmp(Rax, Rcx),
				Emit.jcc(Ne, going_label),
				Emit.mark(short_label),
			]
			Ok({
				statements: tested.concat(jumped).append(Emit.mark(going_label)),
				falls: Falls(state),
				branch: Branch({ target, state: shorted }),
				result: GivesNothing,
			})
		}
		kind if LoweringBasics.is_value_kind(kind) => Ok(LoweringBasics.falling([], state))
		kind => LoweringBasics.refusal(
			site,
			"an optional link of ${LoweringBasics.kind_phrase(kind)}",
		)
	}
}

## A jump taken when the value on top is falsy (`E`) or truthy (`Ne`):
## `JumpIfFalse` drops the value either way, the logical operators' skips
## keep it where they jump.
test_jump_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	skip : U64,
	condition : X86.Condition,
	kept : [Kept, Dropped],
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
test_jump_items = |site, { state, skip, condition, kept }| {
	tested = LoweringBasics.truth_items(site, state)?
	target = LoweringBasics.forward(site, skip)
	sent = match kept {
		Kept => state
		Dropped => LoweringBasics.without_top(state, 1)
	}
	jump = JccTo({ condition, label: LoweringBasics.place_label(site.lowering, target) })
	Ok({
		statements: tested.append(jump),
		falls: Falls(LoweringBasics.without_top(state, 1)),
		branch: Branch({ target, state: sent }),
		result: GivesNothing,
	})
}

## The methods of an array compiled here.
array_methods : List(Str)
array_methods = [
	"push",
	"pop",
	"map",
	"filter",
	"forEach",
	"reduce",
	"join",
	"slice",
	"concat",
	"some",
	"every",
	"find",
	"findIndex",
	"indexOf",
	"includes",
	"sort",
	"reverse",
	"splice",
	"lastIndexOf",
	"shift",
	"unshift",
]

## The methods of a Map or a Set compiled here, by their numbers in
## `Runtime.collection_method`: those that walk it last, an array's too.
collection_methods : List(Str)
collection_methods = ["get", "set", "has", "delete", "clear", "add"].concat(iterator_methods)

## The methods that give an iterator, of an array, a Map or a Set.
iterator_methods : List(Str)
iterator_methods = ["keys", "values", "entries"]

## The methods of a string compiled here.
string_methods : List(Str)
string_methods = ["charAt", "charCodeAt", "indexOf", "includes", "split", "slice", "lastIndexOf"]

## An array's `push` of each argument in turn, its answer the length
## after the last, its `pop`, its `map`, `filter`, `forEach` and `reduce`
## of a function, its `join` and `slice`, or a string's `charAt`: the
## receiver lies below the method looked up, and the answer takes its
## place.
array_method_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	name : Str,
	count : U64,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
array_method_items = |site, { state, name, count }| {
	receiver = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - count - 2)
	base = state.stack_kinds.len() - count
	argument = |at| LoweringBasics.stack_place(site.code, base + at)
	after = |kind| LoweringBasics.with_top(LoweringBasics.without_top(state, count + 2), kind)
	match (name, count) {
		("push", given) if given > 0 => {
			var $pushed = []
			for item in 0..<given {
				$pushed = $pushed.concat([
					Emit.load(Rdi, receiver),
					Emit.load(Rsi, LoweringBasics.stack_place(site.code, base + item)),
					Emit.call(Runtime.push),
				])
			}
			Ok(LoweringBasics.falling($pushed.append(Emit.store(receiver, Rax)), after(Number)))
		}
		("pop", 0) =>
			Ok(
				LoweringBasics.falling(
					[
						Emit.load(Rdi, receiver),
						Emit.call(Runtime.pop),
						Emit.store(receiver, Rax),
					],
					after(Value),
				),
			)
		("map", 1) | ("filter", 1) | ("forEach", 1) => {
			(routine, kind) = match name {
				"map" => (Runtime.map, Array)
				"filter" => (Runtime.filter, Array)
				_ => (Runtime.for_each, Undefined)
			}
			called = [
				Emit.load(Rdi, receiver),
				Emit.load(Rsi, argument(0)),
				Emit.call(routine),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(kind)))
		}
		("reduce", 1) | ("reduce", 2) | ("slice", 0) | ("slice", 1) | ("slice", 2) => {
			var $loaded = []
			for (at, reg) in [(0, Rsi), (1, Rdx)].take_first(count) {
				$loaded = $loaded.append(Emit.load(reg, argument(at)))
			}
			# A slice of a string is a string, of an array an array.
			(routine, kind) = match (name, LoweringBasics.kind_below(state, count + 1)) {
				("reduce", _) => (Runtime.reduce, Value)
				(_, String) => (Runtime.slice, String)
				(_, Array) => (Runtime.slice, Array)
				_ => (Runtime.slice, Value)
			}
			called = [Emit.load(Rdi, receiver)]
				.concat($loaded)
				.concat([
					Emit.imm(Rcx, count.to_i64_wrap()),
					Emit.call(routine),
					Emit.store(receiver, Rax),
				])
			Ok(LoweringBasics.falling(called, after(kind)))
		}
		("join", 0) | ("join", 1) => {
			separator =
				if count == 0 {
					[Emit.address_of(Rsi, Runtime.comma_text)]
				} else if LoweringBasics.kind_below(state, 0) == String {
					[
						Emit.load(Rsi, argument(0)),
						Emit.shl(Rsi, 16),
						Emit.shr(Rsi, 16),
					]
				} else {
					return LoweringBasics.refusal(
						site,
						"`join` with a separator that is not a string",
					)
				}
			called = [Emit.load(Rdi, receiver)]
				.concat(separator)
				.concat([Emit.call(Runtime.join), Emit.store(receiver, Rax)])
			Ok(LoweringBasics.falling(called, after(String)))
		}
		("some", 1) | ("every", 1) | ("find", 1) | ("findIndex", 1) => {
			(searched, kind) = match name {
				"some" => (0, Boolean)
				"every" => (1, Boolean)
				"find" => (2, Value)
				_ => (3, Number)
			}
			called = [
				Emit.load(Rdi, receiver),
				Emit.load(Rsi, argument(0)),
				Emit.imm(Rdx, searched),
				Emit.call(Runtime.search),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(kind)))
		}
		("indexOf", 1) | ("indexOf", 2) | ("includes", 1) | ("includes", 2) => {
			(sought, kind) = if name == "indexOf" {
				(0, Number)
			} else {
				(1, Boolean)
			}
			from = if count == 2 {
				[Emit.load(Rdx, argument(1))]
			} else {
				[]
			}
			called = [Emit.load(Rdi, receiver), Emit.load(Rsi, argument(0))]
				.concat(from)
				.concat([
					Emit.imm(Rcx, count.to_i64_wrap()),
					Emit.imm(R8, sought),
					Emit.call(Runtime.index_of),
					Emit.store(receiver, Rax),
				])
			Ok(LoweringBasics.falling(called, after(kind)))
		}
		("concat", _) => {
			var $made = [
				Emit.load(Rdi, receiver),
				Emit.zero(Rcx),
				Emit.call(Runtime.slice),
				Emit.store(receiver, Rax),
			]
			for at in 0..<count {
				$made = $made.concat([
					Emit.load(Rdi, receiver),
					Emit.shl(Rdi, 16),
					Emit.shr(Rdi, 16),
					Emit.load(Rsi, argument(at)),
					Emit.call(Runtime.concat_item),
				])
			}
			Ok(LoweringBasics.falling($made, after(Array)))
		}
		("sort", 0) | ("sort", 1) | ("reverse", 0) => {
			(routine, compared) =
				if name == "reverse" {
					(Runtime.reverse, [])
				} else if count == 1 {
					(Runtime.sort, [Emit.load(Rsi, argument(0))])
				} else {
					(Runtime.sort, [Emit.imm(Rsi, Boxing.undefined_bits)])
				}
			called = [Emit.load(Rdi, receiver)]
				.concat(compared)
				.concat([Emit.call(routine), Emit.store(receiver, Rax)])
			Ok(LoweringBasics.falling(called, after(Array)))
		}
		("charCodeAt", 0) | ("charCodeAt", 1) => {
			place = if count == 1 {
				Emit.load(Rsi, argument(0))
			} else {
				Emit.zero(Rsi)
			}
			called = [
				Emit.load(Rdi, receiver),
				place,
				Emit.call(Runtime.char_code_at),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(Number)))
		}
		("split", 1) => {
			called = [
				Emit.load(Rdi, receiver),
				Emit.load(Rsi, argument(0)),
				Emit.call(Runtime.split),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(Array)))
		}
		(_, _) if collection_methods.contains(name) => {
			numbered = collection_methods.find_first_index(|known| known == name)
			number = numbered ?? crash "Lowering.array_method_items: a method's number"
			called = LoweringBasics.arguments_array_items(site, { base, count })
				.concat([
					Emit.mov(Rdx, Rax),
					Emit.load(Rdi, receiver),
					Emit.address_of(Rsi, LoweringBasics.text_label(site, name)),
					Emit.imm(Rcx, number.to_i64_wrap()),
					Emit.call(Runtime.collection_method),
					Emit.store(receiver, Rax),
				])
			Ok(LoweringBasics.falling(called, after(Value)))
		}
		("splice", _) => {
			called = LoweringBasics.arguments_array_items(site, { base, count })
				.concat([
					Emit.mov(Rsi, Rax),
					Emit.load(Rdi, receiver),
					Emit.call(Runtime.splice),
					Emit.store(receiver, Rax),
				])
			Ok(LoweringBasics.falling(called, after(Array)))
		}
		# `shift` and `unshift` as splices at the start: `splice(0, 1)`'s
		# item, and `splice(0, 0, ...items)` then the length.
		("shift", 0) => {
			called = [
				Emit.imm(Rdi, 2),
				Emit.call(Runtime.new_array),
				Emit.zero(Rcx),
				Emit.store(Emit.mem(Rdx, 0), Rcx),
				Emit.imm(Rcx, 0x3FF0000000000000),
				Emit.store(Emit.mem(Rdx, 8), Rcx),
				Emit.mov(Rsi, Rax),
				Emit.load(Rdi, receiver),
				Emit.call(Runtime.splice),
				Emit.mov(Rdi, Rax),
				Emit.zero(Rsi),
				Emit.call(Runtime.get_index),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(Value)))
		}
		("unshift", _) => {
			var $filled = [
				Emit.imm(Rdi, (count + 2).to_i64_wrap()),
				Emit.call(Runtime.new_array),
				Emit.zero(Rcx),
				Emit.store(Emit.mem(Rdx, 0), Rcx),
				Emit.store(Emit.mem(Rdx, 8), Rcx),
			]
			for item in 0..<count {
				$filled = $filled.concat([
					Emit.load(Rcx, argument(item)),
					Emit.store(Emit.mem(Rdx, (16 + 8 * item).to_i64_wrap()), Rcx),
				])
			}
			called = $filled.concat([
				Emit.mov(Rsi, Rax),
				Emit.load(Rdi, receiver),
				Emit.call(Runtime.splice),
				Emit.load(Rdi, receiver),
				Emit.shl(Rdi, 16),
				Emit.shr(Rdi, 16),
				Emit.load(Rax, Emit.mem(Rdi, 0)),
				Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
				Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
				Emit.store(receiver, Rax),
			])
			Ok(LoweringBasics.falling(called, after(Number)))
		}
		("lastIndexOf", 1) => {
			called = [
				Emit.load(Rdi, receiver),
				Emit.load(Rsi, argument(0)),
				Emit.call(Runtime.last_index_of),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(Number)))
		}
		("charAt", 1) => {
			called = [
				Emit.load(Rdi, receiver),
				Emit.load(Rsi, argument(0)),
				Emit.call(Runtime.char_at),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(String)))
		}
		_ => LoweringBasics.refusal(
			site,
			"`${name}` with ${LoweringBasics.count_text(count, "argument")} is not compiled yet",
		)
	}
}

## `s += e` where either isn't a number: `runtime_add` of the two, stored
## in the slot and left on the stack.
appended_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	slot : U64,
	held : LoweringBasics.Kind,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
appended_items = |site, { state, slot, held }| {
	top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
	kind = match LoweringBasics.added_kind((held, LoweringBasics.kind_below(state, 0))) {
		Ok(added) => added
		Err(Unadded) => {
			first = LoweringBasics.kind_phrase(held)
			second = LoweringBasics.kind_phrase(LoweringBasics.kind_below(state, 0))
			return LoweringBasics.refusal(site, "`+=` of ${first} and ${second}")
		}
	}
	slots = state.slots.set(
		slot,
		Ready(kind),
	) ?? crash "Lowering.appended_items: a slot of the frame"
	Ok(
		LoweringBasics.falling(
			[
				Emit.load(Rdi, LoweringBasics.slot_place(slot)),
				Emit.load(Rsi, top),
				Emit.call(Runtime.add),
				Emit.store(LoweringBasics.slot_place(slot), Rax),
				Emit.store(top, Rax),
			],
			LoweringBasics.with_top(LoweringBasics.without_top({ ..state, slots }, 1), kind),
		),
	)
}

## The machine code of one instruction, and the kinds after it.
instruction_items : LoweringBasics.Site,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
instruction_items = |site, { instruction, state }| {
	depth = state.stack_kinds.len()
	top_place = |down| LoweringBasics.stack_place(site.code, depth - 1 - down)
	next_place = LoweringBasics.stack_place(site.code, depth)
	if site.skipped.contains(site.at) {
		return Ok(LoweringBasics.falling([], state))
	}
	match instruction {
		PushNumber(number) => Ok(
			LoweringBasics.falling(
				LoweringBasics.constant_items({ bits: number.to_bits(), to: next_place }),
				LoweringBasics.with_top(state, Number),
			),
		)
		PushBoolean(value) => {
			bits = match value {
				True => Boxing.true_bits.to_u64_wrap()
				False => Boxing.false_bits.to_u64_wrap()
			}
			Ok(
				LoweringBasics.falling(
					LoweringBasics.constant_items({ bits, to: next_place }),
					LoweringBasics.with_top(state, Boolean),
				),
			)
		}
		PushText(text) => Ok(
			LoweringBasics.falling(
				[
					Emit.address_of(Rax, LoweringBasics.text_label(site, text)),
					Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)),
					Emit.plus(Rax, Rcx),
					Emit.store(next_place, Rax),
				],
				LoweringBasics.with_top(state, String),
			),
		)
		PushNull => Ok(
			LoweringBasics.falling(
				LoweringBasics.constant_items({
					bits: Boxing.null_bits.to_u64_wrap(),
					to: next_place,
				}),
				LoweringBasics.with_top(state, Null),
			),
		)
		TemplatePart(piece) =>
			if LoweringBasics.kind_below(
				state,
				1,
			) == String and LoweringBasics.is_value_kind(LoweringBasics.kind_below(state, 0)) {
				Ok(
					LoweringBasics.falling(
						[
							Emit.load(Rdi, top_place(1)),
							Emit.load(Rsi, top_place(0)),
							Emit.address_of(Rdx, LoweringBasics.text_label(site, piece)),
							Emit.call(Runtime.template),
							Emit.store(top_place(1), Rax),
						],
						LoweringBasics.with_top(LoweringBasics.without_top(state, 2), String),
					),
				)
			} else {
				phrase = LoweringBasics.kind_phrase(LoweringBasics.kind_below(state, 0))
				LoweringBasics.refusal(site, "a template's substitution of ${phrase}")
			}
		GetProperty("log", _) if LoweringBasics.kind_below(state, 0) == Console =>
			Ok(
				LoweringBasics.falling(
					[],
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Log),
				),
			)
		GetProperty(key, _) => {
			kind = LoweringBasics.kind_below(state, 0)
			given = match (kind, key) {
				(String, "length") | (Array, "length") => Number
				_ => Value
			}
			# Of `undefined` or `null`, the runtime throws node's TypeError.
			match kind {
				String | Array | Object | Value | Null | Undefined =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(0)),
								Emit.address_of(Rsi, LoweringBasics.text_label(site, key)),
								Emit.call(Runtime.get_property),
								Emit.store(top_place(0), Rax),
							],
							LoweringBasics.with_top(LoweringBasics.without_top(state, 1), given),
						),
					)
				Static(owner) => static_property_items(site, { state, owner, key })
				_ => LoweringBasics.refusal(
					site,
					"the property `${key}` of ${LoweringBasics.kind_phrase(kind)}",
				)
			}
		}
		MakeArray(count) => {
			base = depth - count
			made = LoweringBasics.arguments_array_items(site, { base, count })
				.append(Emit.store(LoweringBasics.stack_place(site.code, base), Rax))
			Ok(
				LoweringBasics.falling(
					made,
					LoweringBasics.with_top(LoweringBasics.without_top(state, count), Array),
				),
			)
		}
		NewObject => Ok(
			LoweringBasics.falling(
				[Emit.call(Runtime.new_object), Emit.store(next_place, Rax)],
				LoweringBasics.with_top(state, Object),
			),
		)
		NewArray => Ok(
			LoweringBasics.falling(
				[
					Emit.zero(Rdi),
					Emit.call(Runtime.new_array),
					Emit.store(next_place, Rax),
				],
				LoweringBasics.with_top(state, Array),
			),
		)
		AppendItem | AppendSpread(_) => spread_items(site, { state, instruction })
		SpreadFields(_) | PropertiesLeft(_) => spread_items(site, { state, instruction })
		CallSpread(_) | CallMethodSpread(_) => spread_items(site, { state, instruction })
		SetField(key) => Ok(
			LoweringBasics.falling(
				[
					Emit.load(Rdi, top_place(1)),
					Emit.address_of(Rsi, LoweringBasics.text_label(site, key)),
					Emit.load(Rdx, top_place(0)),
					Emit.call(Runtime.set_property),
				],
				LoweringBasics.without_top(state, 1),
			),
		)
		SetProperty(key, _) =>
			match LoweringBasics.kind_below(state, 1) {
				Object | Value | Null | Undefined => {
					value = LoweringBasics.kind_below(state, 0)
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(1)),
								Emit.address_of(Rsi, LoweringBasics.text_label(site, key)),
								Emit.load(Rdx, top_place(0)),
								Emit.call(Runtime.set_property),
							].concat(
								LoweringBasics.copy_items({ from: top_place(0), to: top_place(1) }),
							),
							LoweringBasics.with_top(LoweringBasics.without_top(state, 2), value),
						),
					)
				}
				kind => LoweringBasics.refusal(
					site,
					"the property `${key}` of ${LoweringBasics.kind_phrase(kind)} written",
				)
			}
		GetIndex(_) =>
			match LoweringBasics.kind_below(state, 1) {
				Array | String | Object | Value | Null | Undefined =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(1)),
								Emit.load(Rsi, top_place(0)),
								Emit.call(Runtime.get_index),
								Emit.store(top_place(1), Rax),
							],
							LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Value),
						),
					)
				kind => LoweringBasics.refusal(
					site,
					"an index of ${LoweringBasics.kind_phrase(kind)}",
				)
			}
		SetIndex(_) =>
			match LoweringBasics.kind_below(state, 2) {
				Array | Object | Value | Null | Undefined => {
					value = LoweringBasics.kind_below(state, 0)
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(2)),
								Emit.load(Rsi, top_place(1)),
								Emit.load(Rdx, top_place(0)),
								Emit.call(Runtime.set_index),
							].concat(
								LoweringBasics.copy_items({ from: top_place(0), to: top_place(2) }),
							),
							LoweringBasics.with_top(LoweringBasics.without_top(state, 3), value),
						),
					)
				}
				kind => LoweringBasics.refusal(
					site,
					"an index of ${LoweringBasics.kind_phrase(kind)} written",
				)
			}
		# A walk of a Map, a Set or an iterator is live, so only a string is
		# made an array.
		IterStart(_) =>
			match LoweringBasics.kind_below(state, 0) {
				Array => Ok(LoweringBasics.falling([], state))
				String =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(0)),
								Emit.call(Runtime.items_of),
								Emit.store(top_place(0), Rax),
							],
							LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Array),
						),
					)
				Value =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(0)),
								Emit.call(Runtime.iter_start),
								Emit.store(top_place(0), Rax),
							],
							state,
						),
					)
				kind => {
					phrase = LoweringBasics.kind_phrase(kind)
					LoweringBasics.refusal(site, "a `for ... of` over ${phrase}")
				}
			}
		DestructureItems(_) =>
			match LoweringBasics.kind_below(state, 0) {
				Array => Ok(LoweringBasics.falling([], state))
				String | Value =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(0)),
								Emit.call(Runtime.items_of),
								Emit.store(top_place(0), Rax),
							],
							LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Array),
						),
					)
				kind => {
					phrase = LoweringBasics.kind_phrase(kind)
					LoweringBasics.refusal(
						site,
						"a `for ... of` or an array pattern over ${phrase}",
					)
				}
			}
		ItemOf(position) =>
			Ok(
				LoweringBasics.falling(
					[
						Emit.load(Rdi, top_place(0)),
						Emit.imm(Rsi, position.to_f64().to_bits().to_i64_wrap()),
						Emit.call(Runtime.get_index),
						Emit.store(top_place(0), Rax),
					],
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Value),
				),
			)
		ItemsFrom(position) =>
			Ok(
				LoweringBasics.falling(
					[
						Emit.load(Rdi, top_place(0)),
						Emit.imm(Rsi, position.to_f64().to_bits().to_i64_wrap()),
						Emit.imm(Rcx, 1),
						Emit.call(Runtime.slice),
						Emit.store(top_place(0), Rax),
					],
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Array),
				),
			)
		CheckDestructurable(_) =>
			match LoweringBasics.kind_below(state, 0) {
				Object | Array | String | Number | Boolean => Ok(LoweringBasics.falling([], state))
				Value =>
					Ok(
						LoweringBasics.falling(
							[Emit.load(Rax, top_place(0)), Emit.call(Runtime.check_destructurable)],
							state,
						),
					)
				kind => {
					phrase = LoweringBasics.kind_phrase(kind)
					LoweringBasics.refusal(
						site,
						"an object pattern of ${phrase}, which throws in node",
					)
				}
			}
		SkipIfDefined(skip) => defined_jump_items(site, { state, skip, settles: Defined })
		SkipIfNotUndefined(skip) => defined_jump_items(site, { state, skip, settles: NotUndefined })
		JumpIfSame(skip) => same_jump_items(site, { state, skip })
		ShortIfNullish(skip) => nullish_jump_items(site, { state, skip })
		IterNext({ slot, exit }) => {
			target = LoweringBasics.forward(site, exit)
			stepped = [
				Emit.load(Rdi, LoweringBasics.slot_place(slot)),
				Emit.load(Rsi, LoweringBasics.slot_place(slot + 1)),
				Emit.call(Runtime.next_item),
				Emit.test(Rdx, Rdx),
				Emit.jcc(E, LoweringBasics.place_label(site.lowering, target)),
				Emit.store(next_place, Rax),
				Emit.store(LoweringBasics.slot_place(slot + 1), Rcx),
			]
			Ok({
				statements: stepped,
				falls: Falls(LoweringBasics.with_top(state, Value)),
				branch: Branch({ target, state }),
				result: GivesNothing,
			})
		}
		PushUndefined => Ok(
			LoweringBasics.falling(
				LoweringBasics.constant_items({
					bits: Boxing.undefined_bits.to_u64_wrap(),
					to: next_place,
				}),
				LoweringBasics.with_top(state, Undefined),
			),
		)
		Pop => Ok(LoweringBasics.falling([], LoweringBasics.without_top(state, 1)))
		Duplicate => Ok(
			LoweringBasics.falling(
				LoweringBasics.copy_items({ from: top_place(0), to: next_place }),
				LoweringBasics.with_top(state, LoweringBasics.kind_below(state, 0)),
			),
		)
		DuplicatePair => {
			items = LoweringBasics.copy_items({ from: top_place(1), to: next_place }).concat(
				LoweringBasics.copy_items({
					from: top_place(0),
					to: LoweringBasics.stack_place(site.code, depth + 1),
				}),
			)
			second = LoweringBasics.with_top(state, LoweringBasics.kind_below(state, 1))
			Ok(
				LoweringBasics.falling(
					items,
					LoweringBasics.with_top(second, LoweringBasics.kind_below(state, 0)),
				),
			)
		}
		Nip => Ok(
			LoweringBasics.falling(
				LoweringBasics.copy_items({ from: top_place(0), to: top_place(1) }),
				LoweringBasics.with_top(
					LoweringBasics.without_top(state, 2),
					LoweringBasics.kind_below(state, 0),
				),
			),
		)
		Swap => {
			items = [
				Instruction(MovRegMem({ to: Rax, from: top_place(1) })),
				Instruction(MovRegMem({ to: Rcx, from: top_place(0) })),
				Instruction(MovMemReg({ to: top_place(1), from: Rcx })),
				Instruction(MovMemReg({ to: top_place(0), from: Rax })),
			]
			first = LoweringBasics.with_top(
				LoweringBasics.without_top(state, 2),
				LoweringBasics.kind_below(state, 0),
			)
			Ok(
				LoweringBasics.falling(
					items,
					LoweringBasics.with_top(first, LoweringBasics.kind_below(state, 1)),
				),
			)
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
				LoweringBasics.kind_below(state, 1),
				LoweringBasics.kind_below(state, 0),
				LoweringBasics.kind_below(state, 2),
			]
			Ok(
				LoweringBasics.falling(
					items,
					{
						..state,
						stack_kinds: LoweringBasics.without_top(state, 3).stack_kinds.concat(moved),
					},
				),
			)
		}
		LoadLocal(slot) => {
			kind = LoweringBasics.slot_kind(site, { state, slot, name: "a variable" })?
			Ok(
				LoweringBasics.falling(
					LoweringBasics.load_items(site, { state, slot }),
					LoweringBasics.with_top(state, kind),
				),
			)
		}
		LoadBoxed({ slot, name, at: _ }) if state.slots.get(slot) == Ok(Unready) =>
			Ok(unready_items(site, name))
		LoadBoxed({ slot, name, at: _ }) => {
			kind = LoweringBasics.slot_kind(site, { state, slot, name: "`${name}`" })?
			Ok(
				LoweringBasics.falling(
					boxed_load_items(site, { state, slot }),
					LoweringBasics.with_top(state, kind),
				),
			)
		}
		# An unready box's value is `undefined`, read before its check.
		PeekBoxed(slot) if state.slots.get(slot) == Ok(Unready) =>
			Ok(
				LoweringBasics.falling(
					LoweringBasics.constant_items({
						bits: Boxing.undefined_bits.to_u64_wrap(),
						to: next_place,
					}),
					LoweringBasics.with_top(state, Undefined),
				),
			)
		PeekBoxed(slot) => {
			kind = LoweringBasics.slot_kind(site, { state, slot, name: "a variable" })?
			Ok(
				LoweringBasics.falling(
					boxed_load_items(site, { state, slot }),
					LoweringBasics.with_top(state, kind),
				),
			)
		}
		StoreLocal(slot) => {
			after = LoweringBasics.written_slot(site, { state, slot })?
			Ok(LoweringBasics.falling(LoweringBasics.store_items(site, { state, slot }), after))
		}
		SetLocal(slot) | SetBoxed(slot) => {
			after = LoweringBasics.written_slot(site, { state, slot })?
			Ok(
				LoweringBasics.falling(
					boxed_store_items(site, { state, slot }),
					LoweringBasics.without_top(after, 1),
				),
			)
		}
		StoreBoxed({ slot, name, kind, at: _ }) => {
			throws = "which throws in node"
			unready = "may be assigned before its declaration has run"
			match kind {
				Fixed => Ok(constant_assigned_items)
				Mutable if state.slots.get(slot) == Ok(Unready) =>
					Ok(unready_items(site, name))
				Mutable if state.slots.get(slot) == Ok(Unsure) =>
					LoweringBasics.refusal(site, "`${name}` ${unready}, ${throws}")
				Mutable => {
					after = LoweringBasics.written_slot(site, { state, slot })?
					Ok(LoweringBasics.falling(boxed_store_items(site, { state, slot }), after))
				}
			}
		}
		NewBox(slot) =>
			match state.slots.get(slot) {
				Ok(Ready(Function(_))) => LoweringBasics.refusal(
					site,
					"a function's name is declared again",
				)
				_ => {
					slots = state.slots.set(
						slot,
						Unready,
					) ?? crash "Lowering.instruction_items: a slot of the frame"
					made =
						if site.lowering.cells.contains(slot) {
							[
								Emit.imm(Rsi, Boxing.undefined_bits),
								Emit.call(Runtime.new_cell),
								Emit.store(LoweringBasics.slot_place(slot), Rax),
							]
						} else {
							[]
						}
					Ok(LoweringBasics.falling(made, { ..state, slots }))
				}
			}
		CopyBox(slot) =>
			if site.lowering.cells.contains(slot) {
				copied = [
					Emit.load(Rax, LoweringBasics.slot_place(slot)),
					Emit.load(Rsi, Emit.mem(Rax, 0)),
					Emit.call(Runtime.new_cell),
					Emit.store(LoweringBasics.slot_place(slot), Rax),
				]
				Ok(LoweringBasics.falling(copied, state))
			} else {
				Ok(LoweringBasics.falling([], state))
			}
		LoadBuiltin(place) => builtin_items(site, { state, place })
		UpdateLocal({ slot, step }) => LoweringBasics.update_items(site, { state, slot, step })
		UpdateBoxed({ slot, name: _, kind, step }) =>
			match kind {
				Fixed => Ok(constant_assigned_items)
				Mutable =>
					if site.lowering.cells.contains(slot) {
						cell_update_items(site, { state, slot, step })
					} else {
						LoweringBasics.update_items(site, { state, slot, step })
					}
			}
		AppendLocal({ slot, at: _ }) => {
			held = LoweringBasics.slot_kind(site, { state, slot, name: "a variable" })?
			if held != Number or LoweringBasics.kind_below(state, 0) != Number {
				return appended_items(site, { state, slot, held })
			}
			items = [
				Instruction(MovsdLoad({ to: Xmm0, from: LoweringBasics.slot_place(slot) })),
				Instruction(MovsdLoad({ to: Xmm1, from: top_place(0) })),
				Instruction(
					Sse({
						operation: Addsd,
						to: Xmm0,
						from: Xmm1,
					}),
				),
				Instruction(MovsdStore({ to: LoweringBasics.slot_place(slot), from: Xmm0 })),
				Instruction(MovsdStore({ to: top_place(0), from: Xmm0 })),
			]
			Ok(LoweringBasics.falling(items, state))
		}
		Unary(operator, _) => unary_items(site, { state, operator })
		Binary(operator, _) => binary_items(site, { state, operator })
		Jump(skip) => {
			target = LoweringBasics.forward(site, skip)
			Ok({
				statements: [JmpTo(LoweringBasics.place_label(site.lowering, target))],
				falls: Ends,
				branch: Branch({ target, state }),
				result: GivesNothing,
			})
		}
		Loop(back) => {
			target = site.at + 1 - back
			Ok({
				statements: [JmpTo(LoweringBasics.place_label(site.lowering, target))],
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
			match (LoweringBasics.kind_below(state, 0), name) {
				(Console, "log") => Ok(
					LoweringBasics.falling([], LoweringBasics.with_top(state, Log)),
				)
				(Array, _) | (Value, _) if array_methods.contains(name) =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
				(Array, _) if iterator_methods.contains(name) =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
				(Value, _) if collection_methods.contains(name) =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
				(String, _) | (Value, _) if string_methods.contains(name) =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
				(Static(owner), _) if static_members(owner).contains(name) =>
					Ok(
						LoweringBasics.falling(
							[],
							LoweringBasics.with_top(state, StaticMethod({ owner, name })),
						),
					)
				(Object, _) | (Value, _) | (Null, _) | (Undefined, _) =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(0)),
								Emit.address_of(Rsi, LoweringBasics.text_label(site, name)),
								Emit.call(Runtime.get_property),
								Emit.store(next_place, Rax),
							],
							LoweringBasics.with_top(state, Value),
						),
					)
				(kind, _) => {
					phrase = LoweringBasics.kind_phrase(kind)
					LoweringBasics.refusal(
						site,
						"the method `${name}` of ${phrase} is not compiled yet",
					)
				}
			}
		CallMethod({ name: _, site: { count, written: _, at: _ } }) =>
			match LoweringBasics.kind_below(state, count) {
				Log => log_items(site, { state, count })
				Method(name) => array_method_items(site, { state, name, count })
				StaticMethod({ owner, name }) =>
					static_call_items(site, { state, count, owner, name })
				Value => value_call_items(site, { state, count, taken: count + 2 })
				kind => LoweringBasics.refusal(
					site,
					"a method call of ${LoweringBasics.kind_phrase(kind)} is not compiled yet",
				)
			}
		Call({ count, written: _, at: _ }) => call_items(site, { state, count })
		Return => {
			kind = LoweringBasics.kind_below(state, 0)
			if !LoweringBasics.is_value_kind(kind) {
				return LoweringBasics.refusal(
					site,
					"a function returns ${LoweringBasics.kind_phrase(kind)}",
				)
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
		# The timers run once the program's own code is done.
		Finish => {
			items = [Emit.jmp(Runtime.run_timers)]
			Ok({
				statements: items,
				falls: Ends,
				branch: NoBranch,
				result: GivesNothing,
			})
		}
		MakeClosure({ code: made, captures, definition }) =>
			if definition.unbox().form == MakesInstances {
				LoweringBasics.refusal(site, "a class is not compiled yet")
			} else if site.lowering.statics.contains(made) {
				Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Function(made))))
			} else {
				Ok(
					LoweringBasics.falling(
						record_items(site, { made, captures, place: next_place }),
						LoweringBasics.with_top(state, Closure(made)),
					),
				)
			}
		MissingName({ name, at: _ }) => LoweringBasics.refusal(
			site,
			"`${name}` is declared nowhere, which throws in node",
		)
		ThrowUnready({ name, at: _ }) => Ok(unready_items(site, name))
		ThrowConstant(_) | UpdateFixed(_) => Ok(constant_assigned_items)
		Refuse(why) => LoweringBasics.refusal(site, why)
		EnterTry({ handler, kind }) => try_items(site, { state, skip: handler, handling: kind })
		LeaveTry =>
			Ok(
				LoweringBasics.falling(
					[
						Emit.load(Rcx, Emit.mem(Rsp, 0)),
						Emit.store(Runtime.handler_place, Rcx),
						Emit.plus_imm(Rsp, 24),
					],
					state,
				),
			)
		Throw(_) | Rethrow => {
			kind = LoweringBasics.kind_below(state, 0)
			if !LoweringBasics.is_value_kind(kind) {
				return LoweringBasics.refusal(
					site,
					"a throw of ${LoweringBasics.kind_phrase(kind)}",
				)
			}
			Ok({
				statements: [Emit.load(Rax, top_place(0)), Emit.jmp(Runtime.throw)],
				falls: Ends,
				branch: NoBranch,
				result: GivesNothing,
			})
		}
		Construct({ count, callee: _, at: _ }) =>
			match LoweringBasics.kind_below(state, count) {
				ErrorClass(name) if count <= 1 => error_items(site, { state, count, name })
				CollectionClass(name) if count <= 1 => {
					given =
						if count == 0 {
							[Emit.imm(Rsi, Boxing.undefined_bits)]
						} else if LoweringBasics.is_value_kind(
							LoweringBasics.kind_below(state, 0),
						) {
							[Emit.load(Rsi, LoweringBasics.stack_place(site.code, depth - 1))]
						} else {
							phrase = LoweringBasics.kind_phrase(LoweringBasics.kind_below(state, 0))
							return LoweringBasics.refusal(site, "`new ${name}` of ${phrase}")
						}
					kind = if name == "Map" {
						0
					} else {
						1
					}
					made = given.concat([
						Emit.imm(Rdi, kind),
						Emit.call(Runtime.new_collection),
						Emit.store(LoweringBasics.stack_place(site.code, depth - count - 1), Rax),
					])
					Ok(
						LoweringBasics.falling(
							made,
							LoweringBasics.with_top(
								LoweringBasics.without_top(state, count + 1),
								Value,
							),
						),
					)
				}
				kind => LoweringBasics.refusal(
					site,
					"`new` of ${LoweringBasics.kind_phrase(kind)} is not compiled yet",
				)
			}
		_ => LoweringBasics.refusal(site, "${instruction_name(instruction)} is not compiled yet")
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

## The instructions of spreads and rests: an array literal's items and
## spreads appended (`[...xs, 1]`), a call's arguments spread (`f(...xs)`,
## `console.log(...xs)`, `Math.max(...xs)`), an object's properties spread
## (`{ ...o }`), and an object pattern's rest.
spread_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	instruction : Bytecode.Op,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
spread_items = |site, { state, instruction }| {
	depth = state.stack_kinds.len()
	top_place = |down| LoweringBasics.stack_place(site.code, depth - 1 - down)
	top_kind = LoweringBasics.kind_below(state, 0)
	if !LoweringBasics.is_value_kind(top_kind) {
		return LoweringBasics.refusal(
			site,
			"a spread or a rest of ${LoweringBasics.kind_phrase(top_kind)}",
		)
	}
	unboxed = |reg| [Emit.shl(reg, 16), Emit.shr(reg, 16)]
	match instruction {
		AppendItem =>
			Ok(
				LoweringBasics.falling(
					[Emit.load(Rdi, top_place(1))]
						.concat(unboxed(Rdi))
						.concat([Emit.load(Rsi, top_place(0)), Emit.call("runtime_push_item")]),
					LoweringBasics.without_top(state, 1),
				),
			)
		AppendSpread(_) =>
			Ok(
				LoweringBasics.falling(
					[
						Emit.load(Rdi, top_place(0)),
						Emit.call(Runtime.items_of),
						Emit.mov(Rsi, Rax),
						Emit.load(Rdi, top_place(1)),
					]
						.concat(unboxed(Rdi))
						.append(Emit.call(Runtime.concat_item)),
					LoweringBasics.without_top(state, 1),
				),
			)
		SpreadFields(_) =>
			Ok(
				LoweringBasics.falling(
					[
						Emit.load(Rdi, top_place(1)),
						Emit.load(Rsi, top_place(0)),
						Emit.call(Runtime.spread_fields),
					],
					LoweringBasics.without_top(state, 1),
				),
			)
		PropertiesLeft({ keys, at: _ }) => {
			var $listed = [Emit.imm(Rdi, keys.len().to_i64_wrap()), Emit.call(Runtime.new_array)]
			for (at, key) in keys.map_with_index(|key, at| (at, key)) {
				$listed = $listed.concat([
					Emit.address_of(Rcx, LoweringBasics.text_label(site, key)),
					Emit.imm(R8, Boxing.tag_bits(Boxing.string_tag)),
					Emit.plus(Rcx, R8),
					Emit.store(Emit.mem(Rdx, (8 * at).to_i64_wrap()), Rcx),
				])
			}
			called = [
				Emit.mov(Rsi, Rax),
				Emit.load(Rdi, top_place(0)),
				Emit.call(Runtime.properties_left),
				Emit.store(top_place(0), Rax),
			]
			Ok(
				LoweringBasics.falling(
					$listed.concat(called),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Object),
				),
			)
		}
		CallSpread(_) =>
			match LoweringBasics.kind_below(state, 1) {
				Closure(_) | Value =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(1)),
								Emit.load(Rsi, top_place(0)),
								Emit.call(Runtime.call_spread),
								Emit.store(top_place(1), Rax),
							],
							LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Value),
						),
					)
				kind => LoweringBasics.refusal(
					site,
					"a call with a spread of ${LoweringBasics.kind_phrase(kind)}",
				)
			}
		CallMethodSpread(_) => {
			receiver = top_place(2)
			after = |kind| LoweringBasics.with_top(LoweringBasics.without_top(state, 3), kind)
			match LoweringBasics.kind_below(state, 1) {
				Log =>
					Ok(
						LoweringBasics.falling(
							[Emit.load(Rdi, top_place(0)), Emit.call(Runtime.log_spread)],
							after(Undefined),
						),
					)
				StaticMethod({ owner: "Math", name }) if name == "max" or name == "min" => {
					extreme = if name == "max" {
						0
					} else {
						1
					}
					called = [
						Emit.load(Rdi, top_place(0)),
						Emit.imm(Rsi, extreme),
						Emit.call(Runtime.extreme_of),
						Emit.store(receiver, Rax),
					]
					Ok(LoweringBasics.falling(called, after(Number)))
				}
				Value =>
					Ok(
						LoweringBasics.falling(
							[
								Emit.load(Rdi, top_place(1)),
								Emit.load(Rsi, top_place(0)),
								Emit.call(Runtime.call_spread),
								Emit.store(receiver, Rax),
							],
							after(Value),
						),
					)
				kind => LoweringBasics.refusal(
					site,
					"a method call with a spread of ${LoweringBasics.kind_phrase(kind)}",
				)
			}
		}
		_ => crash "Lowering.spread_items: a spread's or a rest's instruction"
	}
}

## The builtins that are objects of functions: `Math`, `Object`, and
## `String`, which is a function too.
static_names : List(Str)
static_names = ["Math", "Object", "String", "Array"]

## The functions a builtin object holds, compiled or refused by name when
## called.
static_members : Str -> List(Str)
static_members = |owner|
	match owner {
		"Math" => Runtime.math_functions.concat(["pow", "sin", "cos", "tan", "atan"])
		"Object" => ["keys", "values", "entries"]
		"String" => ["fromCharCode"]
		"Array" => ["isArray", "from", "of"]
		_ => []
	}

## A property of a builtin object read: `Math.PI` and `Math.E`, or one of
## its functions, which takes no bytes (`typeof Math.floor`).
static_property_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	owner : Str,
	key : Str,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
static_property_items = |site, { state, owner, key }| {
	top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
	numbered = LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Number)
	constant = |bits| Ok(
		LoweringBasics.falling(LoweringBasics.constant_items({ bits, to: top }), numbered),
	)
	match (owner, key) {
		# The doubles nearest pi and e.
		("Math", "PI") => constant(0x400921FB54442D18)
		("Math", "E") => constant(0x4005BF0A8B145769)
		_ if static_members(owner).contains(key) =>
			Ok(
				LoweringBasics.falling(
					[],
					LoweringBasics.with_top(
						LoweringBasics.without_top(state, 1),
						StaticMethod({ owner, name: key }),
					),
				),
			)
		_ => LoweringBasics.refusal(site, "the property `${key}` of `${owner}` is not compiled yet")
	}
}

## A call of a builtin object's function: `Math`'s of numbers, `max` and
## `min` of any count of them, `pow` as `**`; `Object.keys`, `values` and
## `entries`. The answer takes the place of the builtin below the function.
static_call_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	count : U64,
	owner : Str,
	name : Str,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
static_call_items = |site, { state, count, owner, name }| {
	receiver = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - count - 2)
	base = state.stack_kinds.len() - count
	after = |kind| LoweringBasics.with_top(LoweringBasics.without_top(state, count + 2), kind)
	# Argument `at` checked a number, in `reg`.
	number_in = |{ at, reg }| {
		kind = LoweringBasics.kind_below(state, count - 1 - at)
		place = LoweringBasics.stack_place(site.code, base + at)
		if LoweringBasics.is_value_kind(kind) {
			Ok(LoweringBasics.number_check_items({ kind, place }).append(Emit.load(reg, place)))
		} else {
			LoweringBasics.refusal(
				site,
				"`${owner}.${name}` of ${LoweringBasics.kind_phrase(kind)}",
			)
		}
	}
	match (owner, name) {
		("Math", "max") | ("Math", "min") => {
			start = if name == "max" {
				0xFFF0000000000000
			} else {
				0x7FF0000000000000
			}
			var $items = LoweringBasics.constant_items({ bits: start, to: receiver })
			for at in 0..<count {
				$items = $items
					.concat(number_in({ at, reg: Rsi })?)
					.concat([
						Emit.load(Rdi, receiver),
						Emit.call(Runtime.math_routine(name)),
						Emit.store(receiver, Rax),
					])
			}
			Ok(LoweringBasics.falling($items, after(Number)))
		}
		("Math", "pow") if count >= 2 => {
			base_loaded = number_in({ at: 0, reg: Rdi })?
			loaded = base_loaded.concat(number_in({ at: 1, reg: Rsi })?)
			called = [Emit.call(Runtime.power), Emit.store(receiver, Rax)]
			Ok(LoweringBasics.falling(loaded.concat(called), after(Number)))
		}
		("Math", _) if Runtime.math_functions.contains(name) =>
			if count == 0 {
				not_a_number = LoweringBasics.constant_items({
					bits: 0x7FF8000000000000,
					to: receiver,
				})
				Ok(LoweringBasics.falling(not_a_number, after(Number)))
			} else {
				loaded = number_in({ at: 0, reg: Rdi })?
				called = [Emit.call(Runtime.math_routine(name)), Emit.store(receiver, Rax)]
				Ok(LoweringBasics.falling(loaded.concat(called), after(Number)))
			}
		("Array", "isArray") => {
			tested =
				if count == 0 {
					[Emit.imm(Rax, Boxing.false_bits)]
				} else {
					[
						Emit.load(Rax, LoweringBasics.stack_place(site.code, base)),
						Emit.shr(Rax, Boxing.tag_shift),
						Emit.cmp_imm(Rax, Boxing.array_tag),
						Instruction(Setcc({ condition: E, to: Al })),
					].concat(LoweringBasics.boolean_items)
				}
			Ok(LoweringBasics.falling(tested.append(Emit.store(receiver, Rax)), after(Boolean)))
		}
		("Array", "of") => {
			made = LoweringBasics.arguments_array_items(
				site,
				{ base, count },
			).append(Emit.store(receiver, Rax))
			Ok(LoweringBasics.falling(made, after(Array)))
		}
		("Array", "from") if count == 1 or count == 2 => {
			mapper =
				if count == 2 {
					Emit.load(Rsi, LoweringBasics.stack_place(site.code, base + 1))
				} else {
					Emit.imm(Rsi, Boxing.undefined_bits)
				}
			called = [
				Emit.load(Rdi, LoweringBasics.stack_place(site.code, base)),
				mapper,
				Emit.call(Runtime.array_from),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(Array)))
		}
		("String", "fromCharCode") => {
			called = LoweringBasics.arguments_array_items(site, { base, count })
				.concat([
					Emit.mov(Rdi, Rax),
					Emit.call(Runtime.from_char_codes),
					Emit.store(receiver, Rax),
				])
			Ok(LoweringBasics.falling(called, after(String)))
		}
		("Math", "sin") | ("Math", "cos") | ("Math", "tan") | ("Math", "atan") =>
			LoweringBasics.refusal(
				site,
				"`Math.${name}` is not compiled yet: node's last digits are V8's port of fdlibm's",
			)
		("Object", _) if count >= 1 and LoweringBasics.is_value_kind(
			LoweringBasics.kind_below(state, count - 1),
		) => {
			listed = match name {
				"keys" => 0
				"values" => 1
				_ => 2
			}
			called = [
				Emit.load(Rdi, LoweringBasics.stack_place(site.code, base)),
				Emit.imm(Rsi, listed),
				Emit.call(Runtime.object_listing),
				Emit.store(receiver, Rax),
			]
			Ok(LoweringBasics.falling(called, after(Array)))
		}
		_ => {
			given = LoweringBasics.count_text(count, "argument")
			LoweringBasics.refusal(site, "`${owner}.${name}` with ${given} is not compiled yet")
		}
	}
}

## The timers' builtins.
timer_names : List(Str)
timer_names = ["setTimeout", "setInterval", "clearTimeout", "clearInterval"]

## A call of a timer's builtin: `setTimeout(f, ms)` and `setInterval(f,
## ms)` give the timer, `clearTimeout(t)` and `clearInterval(t)` clear it;
## the answer takes the builtin's place.
timer_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	count : U64,
	name : Str,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
timer_items = |site, { state, count, name }| {
	base = state.stack_kinds.len() - count
	callee = LoweringBasics.stack_place(site.code, base - 1)
	argument = |at| LoweringBasics.stack_place(site.code, base + at)
	if !state.stack_kinds.take_last(count).all(LoweringBasics.is_value_kind) {
		return LoweringBasics.refusal(site, "`${name}` of a value that is not one")
	}
	match (name, count) {
		("setTimeout", 1) | ("setTimeout", 2) | ("setInterval", 1) | ("setInterval", 2) => {
			delay =
				if count == 2 {
					Emit.load(Rsi, argument(1))
				} else {
					Emit.imm(Rsi, Boxing.undefined_bits)
				}
			repeated = if name == "setInterval" {
				1
			} else {
				0
			}
			called = [
				Emit.load(Rdi, argument(0)),
				delay,
				Emit.imm(Rdx, repeated),
				Emit.call(Runtime.set_timer),
				Emit.store(callee, Rax),
			]
			Ok(
				LoweringBasics.falling(
					called,
					LoweringBasics.with_top(LoweringBasics.without_top(state, count + 1), Value),
				),
			)
		}
		("clearTimeout", _) | ("clearInterval", _) => {
			cleared =
				if count == 0 {
					[]
				} else {
					[Emit.load(Rdi, argument(0)), Emit.call(Runtime.clear_timer)]
				}
			undefined = LoweringBasics.constant_items({
				bits: Boxing.undefined_bits.to_u64_wrap(),
				to: callee,
			})
			Ok(
				LoweringBasics.falling(
					cleared.concat(undefined),
					LoweringBasics.with_top(
						LoweringBasics.without_top(state, count + 1),
						Undefined,
					),
				),
			)
		}
		_ => {
			given = LoweringBasics.count_text(count, "argument")
			LoweringBasics.refusal(
				site,
				"`${name}` with ${given} (a timer's arguments past its delay) is not compiled yet",
			)
		}
	}
}

## The builtins that make errors with `new`.
error_names : List(Str)
error_names = ["Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError"]

## `new Error(message)` and its kin: an error made with the class's name
## and the message, which takes the class's place.
error_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	count : U64,
	name : Str,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
error_items = |site, { state, count, name }| {
	depth = state.stack_kinds.len()
	message =
		if count == 0 {
			[Emit.address_of(Rsi, "runtime_text_empty")]
		} else {
			given = LoweringBasics.stack_place(site.code, depth - 1)
			match LoweringBasics.kind_below(state, 0) {
				String => [
					Emit.load(Rsi, given),
					Emit.shl(Rsi, 16),
					Emit.shr(Rsi, 16),
				]
				kind if LoweringBasics.is_value_kind(kind) => [
					Emit.load(Rdi, given),
					Emit.call(Runtime.error_message),
					Emit.mov(Rsi, Rax),
				]
				kind => return LoweringBasics.refusal(
					site,
					"an error's message of ${LoweringBasics.kind_phrase(kind)}",
				)
			}
		}
	made = message.concat([
		Emit.address_of(Rdi, Runtime.error_name_label(name)),
		Emit.call(Runtime.new_error),
		Emit.store(LoweringBasics.stack_place(site.code, depth - count - 1), Rax),
	])
	Ok(
		LoweringBasics.falling(
			made,
			LoweringBasics.with_top(LoweringBasics.without_top(state, count + 1), Object),
		),
	)
}

## A `try`'s handler pushed: its record on the machine's stack (the code
## a throw enters, the frame's `rbp`, the handler before it), the innermost
## handler made it. The code a throw enters puts the value thrown where the
## stack's top was, with a `finally`'s line and column under it (0 and 0,
## which only node's report of an uncaught throw would read), and jumps to
## the handler's instruction. A throw may come from anywhere in the `try`,
## after its variables took other kinds, so there each holds a `Value`.
try_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	skip : U64,
	handling : Bytecode.Handling,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
try_items = |site, { state, skip, handling }| {
	target = LoweringBasics.forward(site, skip)
	depth = state.stack_kinds.len()
	landing = "${LoweringBasics.place_label(site.lowering, site.at)}_thrown"
	after = "${LoweringBasics.place_label(site.lowering, site.at)}_tried"
	widened = {
		..state,
		slots: state.slots.map(
			|slot|
				match slot {
					Ready(kind) if LoweringBasics.is_value_kind(kind) => Ready(Value)
					# A throw may come after its declaration ran.
					Unready => Unsure
					_ => slot
				},
		),
	}
	(placed, sent) = match handling {
		Catching => (
			[Emit.store(LoweringBasics.stack_place(site.code, depth), Rax)],
			LoweringBasics.with_top(widened, Value),
		)
		Finishing => (
			[
				Emit.zero(Rcx),
				Emit.store(LoweringBasics.stack_place(site.code, depth), Rcx),
				Emit.store(LoweringBasics.stack_place(site.code, depth + 1), Rcx),
				Emit.store(LoweringBasics.stack_place(site.code, depth + 2), Rax),
			],
			LoweringBasics.with_top(
				LoweringBasics.with_top(LoweringBasics.with_top(widened, Number), Number),
				Value,
			),
		)
	}
	statements = [
		Emit.address_of(Rax, landing),
		Emit.save(Rax),
		Emit.save(Rbp),
		Emit.load(Rcx, Runtime.handler_place),
		Emit.save(Rcx),
		Emit.store(Runtime.handler_place, Rsp),
		Emit.jmp(after),
		Emit.mark(landing),
	]
		.concat(placed)
		.concat([Emit.jmp(LoweringBasics.place_label(site.lowering, target)), Emit.mark(after)])
	Ok({
		statements,
		falls: Falls(state),
		branch: Branch({ target, state: sent }),
		result: GivesNothing,
	})
}
