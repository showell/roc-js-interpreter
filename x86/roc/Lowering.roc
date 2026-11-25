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
import js.Bytecode
import js.ValueRules
import Assembly
import Boxing
import BuiltinLowering
import Emit
import KnownFunctions
import LoweringBasics
import OperatorLowering
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
		TimerFunction(name) => BuiltinLowering.timer_items(site, { state, count, name })
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
				Static(owner) => BuiltinLowering.static_property_items(site, { state, owner, key })
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
		SkipIfDefined(skip) => OperatorLowering.defined_jump_items(
			site,
			{ state, skip, settles: Defined },
		)
		SkipIfNotUndefined(skip) => OperatorLowering.defined_jump_items(
			site,
			{ state, skip, settles: NotUndefined },
		)
		JumpIfSame(skip) => OperatorLowering.same_jump_items(site, { state, skip })
		ShortIfNullish(skip) => OperatorLowering.nullish_jump_items(site, { state, skip })
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
			Ok(BuiltinLowering.unready_items(site, name))
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
				Fixed => Ok(BuiltinLowering.constant_assigned_items)
				Mutable if state.slots.get(slot) == Ok(Unready) =>
					Ok(BuiltinLowering.unready_items(site, name))
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
		LoadBuiltin(place) => BuiltinLowering.builtin_items(site, { state, place })
		UpdateLocal({ slot, step }) => LoweringBasics.update_items(site, { state, slot, step })
		UpdateBoxed({ slot, name: _, kind, step }) =>
			match kind {
				Fixed => Ok(BuiltinLowering.constant_assigned_items)
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
				return BuiltinLowering.appended_items(site, { state, slot, held })
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
		Unary(operator, _) => OperatorLowering.unary_items(site, { state, operator })
		Binary(operator, _) => OperatorLowering.binary_items(site, { state, operator })
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
		JumpIfFalse(skip) => OperatorLowering.test_jump_items(
			site,
			{
				state,
				skip,
				condition: E,
				kept: Dropped,
			},
		)
		SkipIfFalsy(skip) => OperatorLowering.test_jump_items(
			site,
			{
				state,
				skip,
				condition: E,
				kept: Kept,
			},
		)
		SkipIfTruthy(skip) => OperatorLowering.test_jump_items(
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
				(Array, _) | (Value, _) if BuiltinLowering.array_methods.contains(name) =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
				(Array, _) if BuiltinLowering.iterator_methods.contains(name) =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
				(Value, _) if BuiltinLowering.collection_methods.contains(name) =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
				(String, _) | (Value, _) if BuiltinLowering.string_methods.contains(name) =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
				(Static(owner), _) if BuiltinLowering.static_members(owner).contains(name) =>
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
				Log => BuiltinLowering.log_items(site, { state, count })
				Method(name) => BuiltinLowering.array_method_items(site, { state, name, count })
				StaticMethod({ owner, name }) =>
					BuiltinLowering.static_call_items(site, { state, count, owner, name })
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
		ThrowUnready({ name, at: _ }) => Ok(BuiltinLowering.unready_items(site, name))
		ThrowConstant(_) | UpdateFixed(_) => Ok(BuiltinLowering.constant_assigned_items)
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
				ErrorClass(name) if count <= 1 => BuiltinLowering.error_items(
					site,
					{ state, count, name },
				)
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
