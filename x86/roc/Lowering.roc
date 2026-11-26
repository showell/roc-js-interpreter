## This module lowers a compiled JavaScript program (`Bytecode`) to x86-64
## (`Assembly` statements), one instruction's machine code after another, as
## the VM would run them. It holds the passes over the program's functions
## until their kinds settle (`items_with_numbers`), the walk over one function's
## instructions, and the match that hands each instruction to the module
## that lowers its family: `OperatorLowering`, `BuiltinLowering` and
## `CallLowering`, beside `KnownFunctions`, which finds the functions known
## before the program runs, and `LoweringBasics`, the types and basics they
## all share. What it can't lower yet, a class for one, is refused by name
## before a byte is written.
##
## **EVERY VALUE'S KIND IS KNOWN BEFORE THE PROGRAM RUNS.** The lowering
## walks each function's instructions in order and keeps, for each slot of
## the frame and each place on the stack, what kind of value it holds
## (`Kind`). Where two ways meet (a jump's target, a loop's head) the kinds
## must agree, so no value needs a tag at run time: a number is its 8 bytes
## of IEEE double, a boolean 0 or 1, `undefined` 0. A function is known by
## which code it runs, and `console` and its `log` take no bytes at all.
##
## **KINDS ONLY RISE.** A function's parameters take the kinds its calls
## pass, and a call's result the kind its function returns, so the lowering
## passes over every function until those kinds settle: each pass lowers
## with the last pass's kinds. The first pass guesses each result and each
## parameter a number, so a function whose result comes back to it as its
## own argument (`run = step(run, op)`, the result of numbers) starts where
## it settles; a parameter guessed a value would make the result a value,
## which the call passes back while the parameter is found a number, and
## the two would swap for good. A guess may fall as well as rise (a
## parameter guessed a number, then found a string), so the passes take
## each pass's kinds as they come. A result that flows back into its own
## function's parameter (`x = t(x)`) can go round that way for good: the
## parameter a number gives a number, which the call takes as a value, which
## gives a value, which the call takes as a number. So once the kinds a pass
## begins with are ones an earlier pass began with, or `most_passes` have
## run, each pass's kinds are met with the last pass's (`met_kind`, as two
## ways meet at a loop's head), and only rise: a parameter from none to a
## kind to `Value`, a result from a kind to `Value`. Each pass that doesn't
## settle raises one, so the passes end within `most_rises`. A program
## that settles before then lowers as the passes found it. Every
## value has the same bits whatever its kind (`Boxing.roc`), so a call
## that passes a number to a parameter that holds a value, or a function
## that returns one where its calls take a value, needs no conversion.
##
## **A FRAME IS FIXED WHEN THE FUNCTION IS LOWERED.** A function's frame,
## below `rbp`, holds its slots (slot s at `rbp - 8(s + 1)`), then the
## bytecode's stack, as deep as the function ever makes it, so a push or a
## pop is a store or a load at a place known here. A call pushes its
## arguments, the last first, and the callee copies each to its parameter's
## slot; the result comes back in `rax`.
##
## **A FUNCTION KNOWN BEFORE THE PROGRAM RUNS TAKES NO BYTES.** A function
## whose captures are all names of such functions, or numbers held for good
## (`KnownFunctions.statics_of`: fib, which captures only itself) is known
## by its code alone, as
## `Function(code)`, and called directly. Where it is used as a value
## (stored, passed, returned) it becomes its closure record in the read-only
## segment, boxed with `Boxing.function_tag`, and it is `escaped_codes`.
## Any other function is made as it runs: `MakeClosure` takes a record from
## the heap and fills it with the cells of the variables it captures
## (`Boxing.roc` has the layout). A variable a closure captures, and that
## holds a value, lives in a cell of 8 bytes on the heap, its slot holding
## the cell's address, as the VM's box; its kind is `Value`. A call of a
## function known by its code is a direct call, `rbx` holding the record
## when it has one; any other is a call through the value, which enters the
## code at its value entry with `rcx` the count of arguments. A function a
## value may hold takes `Value` parameters, since no call shows what reaches
## it that way.
##
## **NUMBER-ONLY ARRAYS.** An array literal whose items are all known
## numbers, or that is empty, is made `Numbers`: an array that holds only
## numbers for good, so an item read of it is a known `Number`, with no tag
## to test where it is used. The rule that keeps that true is conservative,
## and every instruction is held to it as it is lowered
## (`numbers_escaping`): a `Numbers` value may be read for its `length`,
## walked by `for ... of`, read by a number index, written at a number index with a known number,
## given `push` of known numbers, printed by console.log, moved between the
## frame's own slots (never a cell, which a closure may write through) and
## the stack, dropped, and passed to a function called directly, by its
## code, whose parameter then holds it. Any other instruction that reaches
## one (stores it in an object, an array or a cell, returns it, calls a
## method or an operator on it, passes it through a value), a meeting of
## two ways where only one holds it, and a call that passes it to a
## parameter whose settled kind is not `Numbers` or of a function a value
## may hold (`numbers_escape`) is a refusal. Any refusal at all lowers the
## whole program again with no `Numbers` (`program_items`), so the rule
## can only take code to the fast way, never refuse a program. An item read
## that finds no item (past the end, or an index that is no whole number)
## would be `undefined` in node, which is no number: the executable stops
## there with a line saying so, as for the other things only the value
## decides.
import js.Ast
import js.Bytecode
import js.Compile
import js.Parser
import js.ValueRules
import Assembly
import Boxing
import BuiltinLowering
import Emit
import Forwarding
import KnownFunctions
import Jumps
import LoweringBasics
import Moves
import ObjectTable
import CallLowering
import IndexLowering
import OperatorLowering
import Registers
import Runtime
import RuntimeBuilders
import RuntimeCode

Lowering :: [].{

	## The program's machine code, its entry first, or what in it can't be
	## lowered yet.
	program_items : Bytecode.Program -> Try(List(Assembly.Statement), [Refused(Str)])
	program_items = |compiled| {
		program = { ..compiled, codes: compiled.codes.map(threaded_skips) }
		match items_with_numbers(program, True) {
			Ok(items) => Ok(items)
			# Any refusal with arrays of numbers on may be one of an array of
			# numbers escaping, so the program is lowered again without them,
			# and that answer, a refusal or the code, is the program's.
			Err(_) => items_with_numbers(program, False)
		}
	}
}

## A code with each `SkipIfFalsy` that comes to a `JumpIfFalse` made that
## jump (the header's `A && THAT AN if TESTS JUMPS ONCE`).
threaded_skips : Bytecode.Code -> Bytecode.Code
threaded_skips = |code| {
	# Where a falsy value skipped from `at` past `skip` instructions ends
	# up: the `JumpIfFalse`'s target, through any `SkipIfFalsy` between.
	falsy_target = |at, skip| {
		var $place = at + 1 + skip
		var $found = Err(NoJump)
		var $looking = True
		while $looking {
			match code.ops.get($place) {
				Ok(SkipIfFalsy(next)) => {
					$place = $place + 1 + next
				}
				Ok(JumpIfFalse(next)) => {
					$found = Ok($place + 1 + next)
					$looking = False
				}
				_ => {
					$looking = False
				}
			}
		}
		$found
	}
	threaded = code.ops.map_with_index(
		|instruction, at|
			match instruction {
				SkipIfFalsy(skip) =>
					match falsy_target(at, skip) {
						Ok(target) => JumpIfFalse(target - at - 1)
						Err(NoJump) => instruction
					}
				_ => instruction
			},
	)
	{ ..code, ops: threaded }
}

## The program's machine code, with array literals of numbers made
## `Numbers` (`numbers_arrays`) or not.
items_with_numbers : Bytecode.Program, Bool -> Try(List(Assembly.Statement), [Refused(Str)])
items_with_numbers = |program, numbers_arrays| {
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
	for (code, index) in program.codes.map_with_index(|code, index| (code, index)) {
		$parameters = $parameters.insert(index, List.repeat(Number, parameter_count(code)))
	}
	known = { program, makers, statics }
	trying = program.codes.any(
		|code|
			code.ops.any(
				|instruction|
					match instruction {
						EnterTry(_) => True
						_ => False
					},
			),
	)
	# Whether each pass's kinds are met with the last pass's (`KINDS ONLY
	# RISE` above), and the kinds each pass began with before then.
	var $rising = False
	var $begun = []
	for pass in 0..<(most_passes + most_rises(program)) {
		var $items = Runtime.start_items(LoweringBasics.code_label(program.main))
		var $found = $returns
		var $called =
			if $rising {
				$parameters
			} else {
				Dict.empty()
			}
		$begun = $begun.append({
			returns: $returns,
			parameters: $parameters,
			escaped: $escaped_codes,
		})
		var $escaped = $escaped_codes
		var $first_refusal = Ok({})
		var $calls = []
		var $refused = []
		for index in 0..<program.codes.len() {
			context = {
				program,
				makers,
				statics,
				escaped_codes: $escaped_codes,
				cells: KnownFunctions.celled_slots(known, index),
				numbers: KnownFunctions.constant_numbers(known, index),
				trying,
				numbers_arrays,
				returns: $returns,
				parameters: $parameters,
				literals,
				index,
			}
			match code_items(context) {
				Ok(lowered) => {
					$items = $items.concat(lowered.statements)
					$found = match lowered.result {
						Gives(kind) =>
							if $rising {
								$found.insert(index, met_result($found.get(index), kind))
							} else {
								$found.insert(index, kind)
							}
						GivesNothing => $found
					}
					for call in lowered.calls {
						$called = with_call_kinds($called, call)
					}
					$calls = $calls.concat(lowered.calls)
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
					$refused = $refused.append(index)
					if $first_refusal == Ok({}) {
						$first_refusal = Err(refused)
					}
				}
			}
		}
		# A function no call reached this pass (its caller refused, say)
		# keeps the kinds its parameters had, unless it refused with them.
		for (index, kinds) in $parameters.to_list() {
			if !$called.contains(index) and !$refused.contains(index) {
				$called = $called.insert(index, kinds)
			}
		}
		$called = parameters_widened({ before: $parameters, called: $called })
		settled = $found == $returns and $called == $parameters
		if settled and $escaped.len() == $escaped_codes.len() {
			escaping = numbers_escape({
				calls: $calls,
				parameters: $parameters,
				escaped: $escaped_codes,
			})
			if escaping {
				return Err(Refused(numbers_escape_text))
			}
			return match $first_refusal {
				Ok({}) => {
					closures = KnownFunctions.closure_statements({
						program,
						makers,
						statics,
						escaped_codes: $escaped_codes,
					})
					statements =
						$items
							.concat(RuntimeCode.items)
							.concat(literal_statements(literals))
							.concat(closures)
					# Jumps first, so that the labels its threading leaves unnamed
					# (an item read's `done`) no longer end Forwarding's and Moves'
					# straight runs; then again, for the jumps Moves leaves next to
					# their labels.
					threaded = Jumps.thread_jumps(statements)
					Ok(Jumps.thread_jumps(Moves.trim_moves(Forwarding.forward_loads(threaded))))
				}
				Err(refused) => Err(refused)
			}
		}
		# Kinds that go round would go round for good, and so would kinds
		# still moving after `most_passes`: from here on they only rise.
		next = {
			returns: $found,
			parameters: $called,
			escaped: $escaped,
		}
		$rising = $rising or $begun.contains(next) or pass + 1 >= most_passes
		$returns = $found
		$parameters = $called
		$escaped_codes = $escaped
	}
	crash "Lowering.items_with_numbers: kinds that only rise settle within `most_rises`"
}

## A function's result, as the passes that only rise keep it: met with what
## the last pass found.
met_result : Try(LoweringBasics.Kind, _), LoweringBasics.Kind -> LoweringBasics.Kind
met_result = |before, kind|
	match before {
		Ok(known) =>
			match LoweringBasics.met_kind(known, kind) {
				Ok(met) => met
				Err(Apart) => crash "Lowering.met_result: results are values"
			}
		Err(_) => kind
	}

## The most passes whose kinds only rise before they must have settled:
## each pass that doesn't settle raises a kind or escapes a function, a
## result rises once (a kind, then `Value`), a parameter five times (none,
## an `Integer`, widened on one side and on the other, a number, then
## `Value`) and a function escapes once.
most_rises : Bytecode.Program -> U64
most_rises = |program| {
	var $rises = 1
	for code in program.codes {
		$rises = $rises + 2 + 5 * parameter_count(code)
	}
	$rises
}

## The parameters' kinds a pass found (`called`), each `Integer` whose range
## grew since the pass before (`before`) widened on the side it grew, to
## ±2^53 there, as a loop's head widens a slot's: a function that passes
## its own parameter stepped (`f(n - 1)`) settles in a pass or two.
parameters_widened : {
	before : Dict(U64, List(LoweringBasics.Kind)),
	called : Dict(U64, List(LoweringBasics.Kind)),
} -> Dict(U64, List(LoweringBasics.Kind))
parameters_widened = |{ before, called }| {
	limit = LoweringBasics.integer_limit
	widened = |was, now|
		match (was, now) {
			(Integer(old), Integer(grown)) if was != now => {
				low = if grown.low < old.low {
					0 - limit
				} else {
					grown.low
				}
				high = if grown.high > old.high {
					limit
				} else {
					grown.high
				}
				Integer({ low, high })
			}
			_ => now
		}
	called.map(
		|index, kinds|
			match before.get(index) {
				Ok(earlier) if earlier.len() == kinds.len() => List.map2(earlier, kinds, widened)
				_ => kinds
			},
	)
}

## Whether a call passes an array of numbers where its function's parameter
## may hold another value: its settled kind isn't `Numbers`, or a value may
## hold the function, so calls no walk sees reach it.
numbers_escape : {
	calls : List(LoweringBasics.CallKinds),
	parameters : Dict(U64, List(LoweringBasics.Kind)),
	escaped : List(U64),
} -> Bool
numbers_escape = |{ calls, parameters, escaped }|
	calls.any(
		|{ code, kinds }| {
			settled = parameters.get(code) ?? []
			kept = |at| !escaped.contains(code) and settled.get(at) == Ok(Numbers)
			kinds
				.map_with_index(|kind, at| (kind, at))
				.any(|(kind, at)| kind == Numbers and !kept(at))
		},
	)

## The most passes over every function that take each pass's kinds as they
## come, before they only rise (`KINDS ONLY RISE` above).
most_passes : U64
most_passes = 8

## The most times one function's walk widens a loop's head to `Value` before
## the loop's kinds must have settled: a loop that keeps changing them is
## refused, so the walks end.
most_widenings : U64
most_widenings = 16

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
## pass (a function no call reaches keeps the first pass's guess, a number,
## until it refuses with it), or `Value` for a function a value may hold, or
## one that refused with the kinds it had.
parameter_kind : LoweringBasics.Context, U64 -> LoweringBasics.Kind
parameter_kind = |context, slot|
	if context.escaped_codes.contains(context.index) {
		Value
	} else {
		match context.parameters.get(context.index) {
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
			# The keys that mark a class's instances, which no program's
			# text can be.
			marks = match instruction {
				NewInstance(classes) => classes.map(class_key)
				InstanceOf(name) => [class_key(name)]
				_ => []
			}
			for text in marks {
				if !$found.contains(text) {
					$found = $found.insert(text, $found.len())
				}
			}
			for text in named {
				if !$found.contains(text) {
					# A key the class desugaring writes (`super_key`) starts with
					# `þ`, as the class keys do, and no program's text does.
					if text.to_utf8().any(|byte| byte >= 0x80) and !text.starts_with("þsuper ") {
						return Err(Refused("a string that is not ASCII is not compiled yet"))
					}
					$found = $found.insert(text, $found.len())
				}
			}
		}
	}
	Ok($found)
}

## The routine that reads the property `key`, written in the program: a
## method's name of an instance's class's table first, any other own keys
## first (ObjectTable's header).
property_reader : LoweringBasics.Site, Str -> Str
property_reader = |site, key|
	if KnownFunctions.is_method_name(site.context.makers, key) {
		ObjectTable.get_method_hashed
	} else {
		ObjectTable.get_property_hashed
	}

## The key that marks an instance of the class `name`: `þ` (bytes 0xC3
## 0xBE) and the name. A program's strings are ASCII, so none is one.
class_key : Str -> Str
class_key = |name| "þ${name}"

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

## The parameters whose calls pass an `Integer` that the entry makes a
## double (`entry_items`): each one a closure captures, whose cell holds a
## value, or that the walk demoted (`Demoted`).
entry_doubles : LoweringBasics.Context, { code : Bytecode.Code, demoted : List(U64) } -> List(U64)
entry_doubles = |context, { code, demoted }| {
	var $out = []
	for slot in 0..<parameter_count(code) {
		held = demoted.contains(slot) or context.cells.contains(slot)
		if held and LoweringBasics.is_integer(parameter_kind(context, slot)) {
			$out = $out.append(slot)
		}
	}
	$out
}

## The kinds when a function's code starts: its parameters hold their
## kinds (a number for those `entered` makes doubles), its declared
## functions known before the program runs and the functions it captures
## are ready, its other captures hold values, and the rest are unready.
start_state : LoweringBasics.Context,
{
	code : Bytecode.Code,
	entered : List(U64),
} -> Try(LoweringBasics.State, [Refused(Str)])
start_state = |context, { code, entered }| {
	known = known_functions(context)
	var $slots = List.repeat(Unready, code.frame_size)
	for slot in 0..<parameter_count(code) {
		kind =
			if entered.contains(slot) {
				Number
			} else {
				parameter_kind(context, slot)
			}
		$slots = $slots.set(
			slot,
			Ready(kind),
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
					if context.cells.contains(slot) {
						Value
					} else if entered.contains(slot) {
						Number
					} else {
						parameter_kind(context, slot)
					}
				$slots = $slots.set(
					slot,
					Ready(kind),
				) ?? crash "Lowering.start_state: a boxed parameter has a slot"
			}
			CapturedBox({ slot, capture: _ }) => {
				kind = match KnownFunctions.held_function(known, { code: context.index, slot }) {
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
		if context.statics.contains(made) {
			$slots = $slots.set(
				slot,
				Ready(Function(made)),
			) ?? crash "Lowering.start_state: a declaration has a slot"
		}
	}
	Ok({ slots: $slots, stack_kinds: [] })
}

## The count of parameters a code copies to their own slots: none for one
## that packs its arguments into an array.
parameter_count : Bytecode.Code -> U64
parameter_count = |code|
	match code.arguments {
		Each(count) => count
		Packed(_) => 0
	}

## What `KnownFunctions` reads of a function's context (`Known`).
known_functions : LoweringBasics.Context -> LoweringBasics.Known
known_functions = |context| {
	program: context.program,
	makers: context.makers,
	statics: context.statics,
}

## The places of the instructions a code starts with that declare its
## functions known before the program runs: they make no code, since the
## name holds the function from the start.
skipped_places : LoweringBasics.Context, Bytecode.Code -> List(U64)
skipped_places = |context, code| {
	var $out = []
	for (slot, made) in KnownFunctions.declared_functions(code).to_list() {
		if context.statics.contains(made) {
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
code_refusal = |context, fault| {
	why = match fault {
		LoopChangesKinds(at) => "a loop's kinds never settle, at instruction ${at.to_str()}"
		TwoResultKinds => "it returns a value and a function"
		TwoStacks(at) => "two ways reach instruction ${at.to_str()} with different stacks"
		TwoSlotKinds(at) => "a variable holds values of two kinds at instruction ${at.to_str()}"
		FrameTooLarge => "its frame is over a megabyte"
	}
	Refused("${LoweringBasics.function_name(context)}: ${why}")
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
code_items = |context| {
	var $heads = Dict.empty()
	# The slots each loop's head may not take to hold no fraction
	# (IndexLowering's header).
	var $doubted = Dict.empty()
	# The slots that may never hold an `Integer` (x86/README.md, "An integer
	# kind"): each met an `Integer` on one way and another kind on another.
	var $demoted = []
	# Every walk that doesn't return widens a loop's head, so after the last
	# one this is the head of the loop whose kinds never settle.
	var $widened_head = 0
	# A demotion is no widening: each slot is demoted at most once, so those
	# walks end too.
	var $walks = 0
	while $walks < most_widenings {
		$walks = $walks + 1
		walk = code_walk(
			context,
			{
				heads: $heads,
				doubted: $doubted,
				demoted: $demoted,
			},
		)
		match walk {
			Ok(Walked(done)) => return Ok(done)
			Ok(Demoted(slots)) => {
				if slots.all(|slot| $demoted.contains(slot)) {
					crash "Lowering.code_items: a demoted slot holds no Integer"
				}
				$demoted = $demoted.concat(slots)
				# A loop's head widened before holds the slots' `Integer`s,
				# which are doubles from now on.
				$heads = $heads.map(|_, head| without_integers(head, slots))
				$walks = $walks - 1
			}
			Ok(Widened({ at, state, integers_only })) => {
				# A head whose `Integer`s alone widened widens each at most once,
				# to the whole range, so those walks end too, as a demotion's.
				if integers_only {
					$walks = $walks - 1
				}
				$heads = $heads.insert(at, state)
				$widened_head = at
			}
			Ok(Doubted({ at, slots })) => {
				before = match $doubted.get(at) {
					Ok(known) => known
					Err(_) => []
				}
				$doubted = $doubted.insert(at, before.concat(slots))
			}
			Ok(Halted(halted)) => return Err(halted)
			Err(refused) => return Err({ refused, calls: [] })
		}
	}
	Err({ refused: code_refusal(context, LoopChangesKinds($widened_head)), calls: [] })
}

## Whether a loop's head widened to `after` from `head` differs only in its
## slots' `Integer` ranges, each side kept or now at ±2^53.
only_integers_widened : LoweringBasics.State, LoweringBasics.State -> Bool
only_integers_widened = |head, after| {
	limit = LoweringBasics.integer_limit
	kept = |one, other|
		match (one, other) {
			(Ready(Integer(was)), Ready(Integer(now))) =>
				(now.low == was.low or now.low == 0 - limit)
					and (now.high == was.high or now.high == limit)
			_ => one == other
		}
	head.stack_kinds == after.stack_kinds and List.map2(
		head.slots,
		after.slots,
		kept,
	).all(|same| same)
}

## A state with each of `slots` that holds an `Integer` holding a number.
without_integers : LoweringBasics.State, List(U64) -> LoweringBasics.State
without_integers = |state, slots| {
	..state,
	slots: state.slots.map_with_index(
		|held, slot|
			match held {
				Ready(Integer(_)) if slots.contains(slot) => Ready(Number)
				_ => held
			},
	),
}

## One pass of `code_items` with the loop heads widened so far.
code_walk : LoweringBasics.Context,
{
	heads : Dict(U64, LoweringBasics.State),
	doubted : Dict(U64, List(U64)),
	demoted : List(U64),
} -> Try(
	[
		Walked(CodeItems),
		Widened(
			{
				at : U64,
				state : LoweringBasics.State,
				integers_only : Bool,
			},
		),
		Doubted({ at : U64, slots : List(U64) }),
		Demoted(List(U64)),
		Halted({ refused : [Refused(Str)], calls : List(LoweringBasics.CallKinds) }),
	],
	[Refused(Str)],
)
code_walk = |context, { heads, doubted, demoted }| {
	code = context.program.codes.get(context.index) ?? crash "Lowering.code_walk: a code's index"
	entered = entry_doubles(context, { code, demoted })
	start = start_state(context, { code, entered })?
	skipped = skipped_places(context, code)
	looped_to = loop_targets(code)
	# The places of the `JumpIfFalse`s an ordering before took as its own.
	var $fused = []
	var $escaped = []
	var $body = []
	var $pending = Dict.empty()
	var $seen = Dict.empty()
	var $flowing = Flowing(start)
	var $deepest = 0
	var $result = GivesNothing
	var $calls = []
	# What the straight run so far has proved of its index checks
	# (IndexLowering's header).
	var $checked = IndexLowering.nothing_proved(0)
	# How many jumps go to each place ahead, and what the first one's way
	# proved (IndexLowering's header).
	var $arrivals = Dict.empty()
	# The slots each loop's head took to hold no fraction.
	var $assumed = Dict.empty()
	for at in 0..<code.ops.len() {
		fell = match $flowing {
			Stopped => False
			Flowing(_) => True
		}
		meets =
			looped_to.contains(at)
				or $pending.contains(at)
				or (
					match $flowing {
						Stopped => True
						Flowing(_) => False
					}
				)
		# No `Integer` on the stack crosses a meeting: the way that falls to one
		# converts its own, and every jump converts before it goes.
		$flowing = match $flowing {
			Flowing(state) if meets => {
				converted = integers_met(code, { state, kept: [] })
				$body = $body.concat(converted.statements)
				Flowing(converted.state)
			}
			_ => $flowing
		}
		arriving = match ($flowing, $pending.get(at)) {
			(Flowing(state), Ok(waiting)) => {
				# A function known by its code that falls to where a jump
				# brings a value is made a value first.
				made = values_met(context, { state, waiting })
				$body = $body.concat(made.statements)
				$escaped = $escaped.concat(made.escaped)
				clashing = integer_clashes(made.state, waiting)
				if !clashing.is_empty() {
					return Ok(Demoted(clashing))
				}
				Arrives(meeting_state(context, { at, one: made.state, other: waiting })?)
			}
			(Flowing(state), Err(_)) => Arrives(state)
			(Stopped, Ok(waiting)) => Arrives(waiting)
			(Stopped, Err(_)) => Unreached
		}
		$body = $body.append(Mark(LoweringBasics.place_label(context, at)))
		match arriving {
			Unreached => {
				$flowing = Stopped
			}
			Arrives(reached) => {
				state = match heads.get(at) {
					Ok(head) => {
						clashing = integer_clashes(reached, head)
						if !clashing.is_empty() {
							return Ok(Demoted(clashing))
						}
						meeting_state(context, { at, one: reached, other: head })?
					}
					Err(_) => reached
				}
				$seen = $seen.insert(at, state)
				instruction = code.ops.get(at) ?? crash "Lowering.code_walk: an instruction"
				site = { context, code, at, skipped }
				depth_here = state.stack_kinds.len()
				head_alone = looped_to.contains(at) and fell and !$pending.contains(at)
				checked =
					if !meets {
						$checked
					} else if head_alone {
						doubts = match doubted.get(at) {
							Ok(slots) => slots
							Err(_) => []
						}
						started = IndexLowering.at_loop_head(
							$checked,
							{ doubted: doubts, depth: depth_here },
						)
						$assumed = $assumed.insert(at, started.whole_slots)
						started
					} else if fell or looped_to.contains(at) {
						IndexLowering.nothing_proved(depth_here)
					} else {
						match $arrivals.get(at) {
							Ok(
								{ count: 1, proved },
							) => IndexLowering.proofs_at_target(proved, depth_here)
							_ => IndexLowering.nothing_proved(depth_here)
						}
					}
				joined_at = |place| $pending.contains(place) or looped_to.contains(place)
				joined = joined_at(at + 1)
				# What an instruction's `Integer`s are made doubles by changes no
				# value, so what the run proved holds past it; a function made a
				# value (`values_made`) forgets it.
				valued =
					if skipped.contains(at) or $fused.contains(at) {
						{ statements: [], state, escaped: [], converted: [] }
					} else {
						converted = integers_made(site, { instruction, state, demoted, joined })
						made = values_made(site, { instruction, state: converted.state })
						{
							statements: made.statements,
							state: made.state,
							escaped: made.escaped,
							converted: converted.statements,
						}
					}
				$escaped = $escaped.concat(valued.escaped)
				# A call's kinds are its arguments' before any was made a double.
				integers_before = List.map2(
					state.stack_kinds,
					valued.state.stack_kinds,
					|before, after|
						if LoweringBasics.is_integer(before) {
							before
						} else {
							after
						},
				)
				called_state = { ..valued.state, stack_kinds: integers_before }
				$calls = match call_kinds(context, { instruction, state: called_state }) {
					Ok(call) => $calls.append(call)
					Err(NoCall) => $calls
				}
				ahead = [1, 2, 3, 4, 5].any(|step| joined_at(at + step))
				fused = fused_jump(
					site,
					{
						instruction,
						joined,
						ahead,
						state: valued.state,
						origins: checked.origins,
					},
				)
				literal =
					if joined {
						Err(NotInteger)
					} else {
						integer_literal(
							site,
							{
								instruction,
								state: valued.state,
								demoted,
								jump_joined: joined_at(at + 2),
							},
						)
					}
				lowered =
					if $fused.contains(at) {
						LoweringBasics.falling([], valued.state)
					} else {
						match (fused, literal) {
							(Fused({ done, through }), _) => {
								for step in 0..<through {
									$fused = $fused.append(at + 1 + step)
								}
								done
							}
							(Unfused, Ok({ whole, kind })) => {
								place = LoweringBasics.stack_place(
									code,
									valued.state.stack_kinds.len(),
								)
								LoweringBasics.falling(
									[Emit.imm(Rax, whole), Emit.store(place, Rax)],
									LoweringBasics.with_top(valued.state, kind),
								)
							}
							(Unfused, Err(NotInteger)) =>
								match instruction_items(
									site,
									{ instruction, state: valued.state, checked },
								) {
									Ok(done) => done
									Err(refused) => return Ok(Halted({ refused, calls: $calls }))
								}
						}
					}
				$body = $body.concat(valued.converted)
				$body = $body.concat(valued.statements).concat(lowered.statements)
				$checked = match lowered.falls {
					Falls(next) => {
						depth = next.stack_kinds.len()
						if $fused.contains(at) and depth == checked.origins.len() {
							checked
						} else if skipped.contains(at) or !valued.statements.is_empty() {
							IndexLowering.nothing_proved(depth)
						} else {
							IndexLowering.checked_after(
								checked,
								{ instruction, before: valued.state, depth },
							)
						}
					}
					Ends => IndexLowering.nothing_proved(0)
				}
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
							proved = match lowered.falls {
								Falls(_) => $checked
								Ends => checked
							}
							$arrivals = $arrivals.insert(
								target,
								match $arrivals.get(target) {
									Ok(before) => { count: before.count + 1, proved: before.proved }
									Err(_) => { count: 1, proved }
								},
							)
							$deepest = U64.max($deepest, sent.stack_kinds.len())
							if sent.stack_kinds.any(LoweringBasics.is_integer) {
								crash "Lowering.code_walk: a jump's stack holds no Integer"
							}
							$pending = match $pending.get(target) {
								Ok(waiting) => {
									clashing = integer_clashes(waiting, sent)
									if !clashing.is_empty() {
										return Ok(Demoted(clashing))
									}
									$pending.insert(
										target,
										meeting_state(
											context,
											{
												at: target,
												one: waiting,
												other: sent,
											},
										)?,
									)
								}
								Err(_) => $pending.insert(target, sent)
							}
						} else {
							assumed = match $assumed.get(target) {
								Ok(slots) => slots
								Err(_) => []
							}
							unkept = IndexLowering.unkept_at_back(assumed, checked)
							if !unkept.is_empty() {
								return Ok(Doubted({ at: target, slots: unkept }))
							}
							head = $seen.get(target) ?? crash "Lowering.code_walk: a loop's head"
							if sent.stack_kinds.any(LoweringBasics.is_integer) {
								crash "Lowering.code_walk: a jump's stack holds no Integer"
							}
							clashing = integer_clashes(head, sent)
							if !clashing.is_empty() {
								return Ok(Demoted(clashing))
							}
							met = meeting_state(
								context,
								{
									at: target,
									one: head,
									other: sent,
								},
							)?
							again = integers_widened(head, met)
							if again != head {
								integers_only = only_integers_widened(head, again)
								return Ok(Widened({ at: target, state: again, integers_only }))
							}
						}
				}
				$result = match (lowered.result, $result) {
					(GivesNothing, _) => $result
					(Gives(kind), GivesNothing) => Gives(kind)
					(Gives(kind), Gives(before)) =>
						match LoweringBasics.met_kind(kind, before) {
							Ok(met) => Gives(met)
							Err(Apart) => return Err(code_refusal(context, TwoResultKinds))
						}
				}
			}
		}
	}
	frame_bytes = 8 * (code.frame_size + $deepest)
	if frame_bytes > 1048576 {
		return Err(code_refusal(context, FrameTooLarge))
	}
	made = entry_items(context, { code, frame_bytes, entered }).concat($body)
	statements =
		if context.trying {
			made
		} else {
			Registers.promote_statements({
				statements: made,
				frame_bytes,
				worth_renaming: !looped_to.is_empty() or !code.ops.any(calls_code),
			})
		}
	Ok(
		Walked({
			statements,
			result: $result,
			calls: $calls,
			escaped: $escaped,
		}),
	)
}

## Whether an instruction may call a function of the program.
calls_code : Bytecode.Op -> Bool
calls_code = |instruction|
	match instruction {
		Call(_) | CallSpread(_) | CallIndexed(_) | Construct(_) => True
		CallMethod(_) | CallMethodSpread(_) => True
		_ => False
	}

## The places a `Loop` of the code goes back to.
loop_targets : Bytecode.Code -> List(U64)
loop_targets = |code| {
	var $out = []
	for (instruction, at) in code.ops.map_with_index(|instruction, at| (instruction, at)) {
		match instruction {
			Loop(back) => {
				$out = $out.append(at + 1 - back)
			}
			_ => {}
		}
	}
	$out
}

## An ordering of two values that may be numbers and the `JumpIfFalse` after
## it, lowered as one (`OperatorLowering.ordered_jump_items`), when no other
## way reaches the `JumpIfFalse` (`joined` says whether one does): then the
## walk passes the `JumpIfFalse` by.
##
## **A SELECT OF TWO KNOWN NUMBERS HAS NO JUMP.** An ordering of two known
## numbers that a conditional of two arms follows (`JumpIfFalse(2)`, one
## arm, `Jump(1)`, the other), each arm a number literal or a variable of
## the frame holding a known number, with no other way reaching any of the
## five places from the `JumpIfFalse` to the instruction after the second
## arm (`ahead` says whether one does), is lowered as one
## (`OperatorLowering.selected_items`): both arms loaded, the `ucomisd`, and
## a `cmov` that keeps the first arm's bits when the ordering holds. The
## walk passes the four instructions after the ordering by, and the
## conditional's value is a known number. `c ? 1 : 0` is such a select.
##
## **A `&&` THAT AN `if` TESTS JUMPS ONCE.** `if (a && b)` compiles to
## `a`, a `SkipIfFalsy` that keeps a falsy `a` as the `&&`'s value and
## skips to the `JumpIfFalse` after `b`, which then drops it and jumps. Each
## code is lowered with every `SkipIfFalsy` whose skip comes to a
## `JumpIfFalse` (through any other `SkipIfFalsy`, as `a && b && c` does)
## made a `JumpIfFalse` to that one's target (`threaded_skips`): the same
## value dropped, the same place reached. The `JumpIfFalse` after `b` is
## then reached by `b` alone, so a test before each jump is fused with it.
## x86/tests/equal-jumps.js holds `&&`s of one, two and three tests to node.
##
## An ordering, a `===` or a `!==` of two `Integer`s and its `JumpIfFalse`
## are a `cmp` and a jump (`OperatorLowering.integer_jump_items`).
##
## **AN EQUALITY OF TWO KNOWN NUMBERS AND ITS `JumpIfFalse` ARE ONE.** A
## `===` or `!==` of two known numbers that a `JumpIfFalse` follows, with no
## other way reaching the `JumpIfFalse`, is lowered as one
## (`OperatorLowering.equal_jump_items`): a `ucomisd` and the jumps on its
## flags, with no boolean made and tested. x86/tests/equal-jumps.js holds
## both operators, NaNs, -0 and a near miss (a `JumpIfFalse` that another
## way reaches) to node.
##
## **`Math.floor(a / b)` OF TWO `Integer`S IS ONE INTEGER DIVISION.** A `/`
## of two `Integer`s that a call of `Math.floor` of one argument follows,
## with no other way reaching the call and the divisor at least 1
## (`integer_binary`), is lowered with the call as one
## (`OperatorLowering.integer_floor_items`): its floored quotient, an
## `Integer`, in the place of `Math`, and the walk passes the call by.
fused_jump : LoweringBasics.Site,
{
	instruction : Bytecode.Op,
	joined : Bool,
	ahead : Bool,
	state : LoweringBasics.State,
	origins : List(IndexLowering.Origin),
} -> [Fused({ done : LoweringBasics.Lowered, through : U64 }), Unfused]
fused_jump = |site, { instruction, joined, ahead, state, origins }| {
	following = |step| site.code.ops.get(site.at + step)
	match (instruction, following(1)) {
		(
			Binary(operator, _),
			Ok(JumpIfFalse(skip)),
		) if !joined and is_integer_test(operator) and integers_on_top(state) => {
			done = OperatorLowering.integer_jump_items(site, { state, operator, skip, origins })
			Fused({ done, through: 1 })
		}
		(Binary(operator, _), Ok(JumpIfFalse(skip))) if !joined and is_ordering(operator) => {
			kinds = (LoweringBasics.kind_below(state, 1), LoweringBasics.kind_below(state, 0))
			arms = match (
				following(2),
				following(3),
				following(4),
			) {
				(
					Ok(chosen),
					Ok(Jump(1)),
					Ok(other),
				) if skip == 2 and !ahead and kinds == (Number, Number) =>
					match (
						number_arm(site, { arm: chosen, state }),
						number_arm(site, { arm: other, state }),
					) {
						(Ok(held), Ok(otherwise)) => Ok({ held, otherwise })
						_ => Err(NoSelect)
					}
				_ => Err(NoSelect)
			}
			match arms {
				Ok({ held, otherwise }) => {
					done = OperatorLowering.selected_items(
						site,
						{ state, operator, held, otherwise },
					)
					Fused({ done, through: 4 })
				}
				Err(NoSelect) =>
					if LoweringBasics.are_numeric(kinds) {
						done = OperatorLowering.ordered_jump_items(site, { state, operator, skip })
						Fused({ done, through: 1 })
					} else {
						Unfused
					}
			}
		}
		(Binary(Divide, _), Ok(CallMethod(_))) if !joined and integers_on_top(state) => {
			floored = integer_binary(
				site,
				{
					operator: Divide,
					left: LoweringBasics.kind_below(state, 1),
					right: LoweringBasics.kind_below(state, 0),
					callee: kind_under(state, 2),
					step: 1,
					joined,
				},
			)
			match floored {
				Ok(kind) => {
					done = OperatorLowering.integer_floor_items(site, { state, kind })
					Fused({ done, through: 1 })
				}
				Err(NotInteger) => Unfused
			}
		}
		(Binary(operator, _), Ok(JumpIfFalse(skip))) if !joined and is_equality(operator) =>
			if (
				LoweringBasics.kind_below(state, 1),
				LoweringBasics.kind_below(state, 0),
			) == (Number, Number) {
				done = OperatorLowering.equal_jump_items(site, { state, operator, skip })
				Fused({ done, through: 1 })
			} else {
				Unfused
			}
		_ => Unfused
	}
}

## Where a select's arm (`fused_jump`) finds its known number: a literal's
## bits, or a variable's slot of the frame that holds a known number and no
## cell.
number_arm : LoweringBasics.Site,
{
	arm : Bytecode.Op,
	state : LoweringBasics.State,
} -> Try(OperatorLowering.Arm, [NoArm])
number_arm = |site, { arm, state }|
	match arm {
		PushNumber(number) => Ok(Bits(number.to_bits().to_i64_wrap()))
		LoadLocal(slot) =>
			if state.slots.get(slot) == Ok(Ready(Number)) and !site.context.cells.contains(slot) {
				Ok(Place(LoweringBasics.slot_place(slot)))
			} else {
				Err(NoArm)
			}
		_ => Err(NoArm)
	}

## Whether an operator is `===` or `!==`.
is_equality : Ast.BinaryOperator -> Bool
is_equality = |operator|
	match operator {
		StrictEqual | StrictNotEqual => True
		_ => False
	}

## Whether an operator of two `Integer`s fuses with the `JumpIfFalse` after
## it as a `cmp` and a jump (`OperatorLowering.integer_jump_items`): an
## ordering, `===` or `!==`.
is_integer_test : Ast.BinaryOperator -> Bool
is_integer_test = |operator| is_ordering(operator) or is_equality(operator)

## Whether an operator is one of the four orderings.
is_ordering : Ast.BinaryOperator -> Bool
is_ordering = |operator|
	match operator {
		Less | LessOrEqual | Greater | GreaterOrEqual => True
		_ => False
	}

## The kinds of a call's arguments, when the instruction calls a declared
## function with as many arguments as it has parameters, each a value or an
## `Integer`. An `Integer` is the kind its parameter takes once every call
## passes one (x86/README.md, "An integer kind"), whether or not this pass
## passed it as one (`integer_arguments`).
call_kinds : LoweringBasics.Context,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
} -> Try(LoweringBasics.CallKinds, [NoCall])
call_kinds = |context, { instruction, state }|
	match instruction {
		Call({ count, written: _, at: _ }) =>
			match LoweringBasics.kind_below(state, count) {
				Function(made) | Closure(made) => {
					callee = context.program.codes.get(made) ?? crash "Lowering.call_kinds: a code"
					kinds = state.stack_kinds.take_last(count)
					pushed = kinds.all(LoweringBasics.is_argument_kind)
					if callee.arguments == Each(count) and pushed {
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
##
## A class's method (`Bytecode.Code`'s `form`, `Method`) takes its first
## parameter, `this`, from `rdx` at the entry through a value, and each
## argument the caller pushed in the parameter after its own: every call
## through a value sets `rdx`, to a method call's receiver, or else to
## `undefined` (ClassDesugaring's doc). Its direct entry takes `this` as its
## first argument, as any function's first.
##
## A parameter `entered` lists takes an `Integer` from its calls, which the
## direct entry makes a double in its slot before the cells are made.
entry_items : LoweringBasics.Context,
{
	code : Bytecode.Code,
	frame_bytes : U64,
	entered : List(U64),
} -> List(Assembly.Statement)
entry_items = |context, { code, frame_bytes, entered }| {
	index = context.index
	parameters = parameter_count(code)
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
			# A number held for good is read as the number, so its cell is
			# never copied: a function known before the program runs has no
			# record to copy it from.
			CapturedBox({ slot, capture }) =>
				if context.cells.contains(slot) and !context.numbers.contains(slot) {
					$captured = $captured.concat([
						Emit.load(Rax, Emit.mem(Rbx, (24 + 8 * capture).to_i64_wrap())),
						Emit.store(LoweringBasics.slot_place(slot), Rax),
					])
				}
			FreshBox(slot) =>
				if context.cells.contains(slot) {
					$cells = $cells.concat([
						Emit.imm(Rsi, Boxing.undefined_bits),
						Emit.call(Runtime.new_cell),
						Emit.store(LoweringBasics.slot_place(slot), Rax),
					])
				}
			FilledBox(slot) =>
				if context.cells.contains(slot) {
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
	received = code.form == Method
	var $direct = packed
	var $counted = match code.arguments {
		Packed(slot) if received => [
			Emit.lea(Rdi, argument(0)),
			Emit.mov(Rsi, Rcx),
			Emit.mov(R8, Rdx),
			Emit.call(Runtime.pack_received),
			Emit.store(LoweringBasics.slot_place(slot), Rax),
		]
		_ => packed
	}
	for slot in 0..<parameters {
		missing = "${LoweringBasics.value_label(index)}_missing_${slot.to_str()}"
		got = "${LoweringBasics.value_label(index)}_got_${slot.to_str()}"
		$direct = $direct.concat([
			Emit.load(Rax, argument(slot)),
			Emit.store(LoweringBasics.slot_place(slot), Rax),
		])
		if entered.contains(slot) {
			place = LoweringBasics.slot_place(slot)
			$direct = $direct.concat(LoweringBasics.integer_converted_items(place))
		}
		# A method's arguments start at its second parameter.
		pushed = if received and slot > 0 {
			slot - 1
		} else {
			slot
		}
		$counted =
			if received and slot == 0 {
				$counted.append(Emit.store(LoweringBasics.slot_place(slot), Rdx))
			} else {
				$counted.concat([
					Emit.cmp_imm(Rcx, pushed.to_i64_wrap()),
					Emit.jcc(Be, missing),
					Emit.load(Rax, argument(pushed)),
					Emit.jmp(got),
					Emit.mark(missing),
					Emit.imm(Rax, Boxing.undefined_bits),
					Emit.mark(got),
					Emit.store(LoweringBasics.slot_place(slot), Rax),
				])
			}
	}
	through_value =
		if context.escaped_codes.contains(index) {
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
values_met = |context, { state, waiting }| {
	code = context.program.codes.get(context.index) ?? crash "Lowering.values_met: a code's index"
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

## Whether the stack's two top places hold `Integer`s.
integers_on_top : LoweringBasics.State -> Bool
integers_on_top = |state|
	state.stack_kinds.len() >= 2
		and LoweringBasics.is_integer(LoweringBasics.kind_below(state, 1))
		and LoweringBasics.is_integer(LoweringBasics.kind_below(state, 0))

## The `Integer` a whole number literal pushes, and its integer, when the
## instruction after it takes one as it is (x86/README.md, "Where an
## `Integer` comes from"): a store or set of a slot that may hold one,
## `+ - * %` or a floored `/` with an `Integer` below that stays one
## (`integer_binary`), an ordering, `===` or `!==` with an `Integer` below
## that its `JumpIfFalse` follows, no other way reaching that jump or that
## call (`jump_joined` says whether one does), or an index of an array. A
## literal is `PushNumber`, or a captured number held for good
## (`KnownFunctions.constant_numbers`). Lowering asks only where no other
## way reaches the place after it, and a program with a `try` makes none (a
## throw lands with every variable a value).
integer_literal : LoweringBasics.Site,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
	demoted : List(U64),
	jump_joined : Bool,
} -> Try({ whole : I64, kind : LoweringBasics.Kind }, [NotInteger])
integer_literal = |site, { instruction, state, demoted, jump_joined }| {
	if site.context.trying {
		return Err(NotInteger)
	}
	number = match instruction {
		PushNumber(pushed) => pushed
		LoadBoxed(
			{ slot, name: _, at: _ },
		) => site.context.numbers.get(slot) ?? return Err(NotInteger)
		_ => return Err(NotInteger)
	}
	kind = LoweringBasics.integer_of_literal(number)?
	beneath =
		if state.stack_kinds.is_empty() {
			Undefined
		} else {
			LoweringBasics.kind_below(state, 0)
		}
	following = |step| site.code.ops.get(site.at + step)
	taken = match following(1) {
		Ok(StoreLocal(slot)) | Ok(SetLocal(slot)) => integer_storable(site, { slot, demoted })
		Ok(Binary(operator, _)) if is_integer_test(operator) =>
			LoweringBasics.is_integer(beneath)
				and !jump_joined
				and (
					match following(2) {
						Ok(JumpIfFalse(_)) => True
						_ => False
					}
				)
		Ok(Binary(operator, _)) =>
			integer_binary(
				site,
				{
					operator,
					left: beneath,
					right: kind,
					callee: kind_under(state, 1),
					step: 2,
					joined: jump_joined,
				},
			).is_ok()
		Ok(GetIndex(_)) => takes_integer_index(beneath)
		Ok(Call(_)) | Ok(PushNumber(_)) | Ok(LoadLocal(_)) => integer_argument(site, state)
		_ => False
	}
	if taken {
		Ok({ whole: LoweringBasics.whole_of_literal(number), kind })
	} else {
		Err(NotInteger)
	}
}

## Whether a literal pushed at the site, on `state`, is an argument of a
## direct call whose parameters may take `Integer`s (`integer_arguments`):
## each instruction after it up to the call pushes one more argument, a
## literal or a slot's value, and below the arguments is a function known
## by its code that no value may hold, with a parameter for each. Whether
## the call passes it as one is the parameter's settled kind's to say; the
## call's kinds name it an `Integer` either way, so the parameter can become
## one.
integer_argument : LoweringBasics.Site, LoweringBasics.State -> Bool
integer_argument = |site, state| {
	context = site.context
	pushes_one = |step|
		match site.code.ops.get(site.at + step) {
			Ok(PushNumber(_)) | Ok(LoadLocal(_)) => True
			_ => False
		}
	var $step = 1
	while pushes_one($step) {
		$step = $step + 1
	}
	after = $step - 1
	match site.code.ops.get(site.at + $step) {
		Ok(Call({ count, written: _, at: _ })) if after < count =>
			match kind_under(state, count - 1 - after) {
				Function(made) | Closure(made) if !context.escaped_codes.contains(made) =>
					match context.program.codes.get(made) {
						Ok(callee) => callee.arguments == Each(count)
						Err(_) => False
					}
				_ => False
			}
		_ => False
	}
}

## The `Integer` a binary operator of two kinds gives where the walk lowers
## it as integers: `+ - * %` (`LoweringBasics.integer_arithmetic`), and a
## `/` whose quotient the instruction `step` past the site, a call of
## `Math.floor` (`callee` the kind of what it calls), takes at once, with no
## other way reaching that call (`joined` says whether one does), as
## `Math.floor(a / b)` (`LoweringBasics.integer_floor_quotient`). `fused_jump`
## lowers that `/` and the call as one.
integer_binary : LoweringBasics.Site,
{
	operator : Ast.BinaryOperator,
	left : LoweringBasics.Kind,
	right : LoweringBasics.Kind,
	callee : LoweringBasics.Kind,
	step : U64,
	joined : Bool,
} -> Try(LoweringBasics.Kind, [NotInteger])
integer_binary = |
	site,
	{
		operator,
		left,
		right,
		callee,
		step,
		joined,
	},
|
	match operator {
		Divide if !joined and floor_call_at(site, { step, callee }) =>
			LoweringBasics.integer_floor_quotient(left, right)
		_ => LoweringBasics.integer_arithmetic({ operator, left, right })
	}

## Whether the instruction `step` past the site is a call of one argument
## of `Math.floor`, `callee` the kind of what it calls.
floor_call_at : LoweringBasics.Site, { step : U64, callee : LoweringBasics.Kind } -> Bool
floor_call_at = |site, { step, callee }|
	match site.code.ops.get(site.at + step) {
		Ok(CallMethod({ name: _, site: { count, written: _, at: _ } })) =>
			count == 1 and callee == StaticMethod({ owner: "Math", name: "floor" })
		_ => False
	}

## The kind `down` places below the stack's top, or `Undefined` where the
## stack isn't that deep.
kind_under : LoweringBasics.State, U64 -> LoweringBasics.Kind
kind_under = |state, down|
	if state.stack_kinds.len() > down {
		LoweringBasics.kind_below(state, down)
	} else {
		Undefined
	}

## Whether a slot may hold an `Integer`: not demoted (`Demoted`), and no
## cell, which closures share as a value.
integer_storable : LoweringBasics.Site, { slot : U64, demoted : List(U64) } -> Bool
integer_storable = |site, { slot, demoted }|
	!demoted.contains(slot) and !site.context.cells.contains(slot)

## Whether an item read or write of a receiver of this kind takes an
## `Integer` index as it is: the in-line way of an array's, whose slow way
## makes it a double first.
takes_integer_index : LoweringBasics.Kind -> Bool
takes_integer_index = |receiver|
	match receiver {
		Array | Numbers | Value => True
		_ => False
	}

## Each `Integer` an instruction can't take made a double first (x86/README.md,
## "Where an `Integer` becomes a double"): the stack's places it doesn't
## keep (`integers_kept`), and the slot it steps in place (`UpdateLocal`,
## `AppendLocal`) when that slot holds one it can't step as one.
integers_made : LoweringBasics.Site,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
	demoted : List(U64),
	joined : Bool,
} -> { statements : List(Assembly.Statement), state : LoweringBasics.State }
integers_made = |site, { instruction, state, demoted, joined }| {
	kept = integers_kept(site, { instruction, state, demoted, joined })
	stacked = integers_met(site.code, { state, kept })
	stepped = match instruction {
		UpdateLocal({ slot, step }) => Ok({ slot, steps: integers_stepped(state, { slot, step }) })
		AppendLocal({ slot, at: _ }) => Ok({ slot, steps: False })
		_ => Err(NoSlot)
	}
	match stepped {
		Ok({ slot, steps }) =>
			match stacked.state.slots.get(slot) {
				Ok(Ready(Integer(_))) if !steps => {
					slots = stacked.state.slots.set(slot, Ready(Number))
						?? crash "Lowering.integers_made: a slot"
					{
						statements: stacked.statements.concat(
							LoweringBasics.integer_converted_items(LoweringBasics.slot_place(slot)),
						),
						state: { ..stacked.state, slots },
					}
				}
				_ => stacked
			}
		Err(NoSlot) => stacked
	}
}

## Whether `++` or `--` of a slot keeps its `Integer` one: its range stepped
## stays within ±2^53.
integers_stepped : LoweringBasics.State, { slot : U64, step : Bytecode.Update } -> Bool
integers_stepped = |state, { slot, step }|
	match state.slots.get(slot) {
		Ok(Ready(kind)) => LoweringBasics.integer_stepped(kind, step.delta).is_ok()
		_ => False
	}

## Which of the stack's places, bottom first, an instruction keeps as
## `Integer`s; the rest are made doubles. An instruction that reads none of
## the stack (a push, a load, a step of a slot) keeps them all, and `Pop`
## drops its own. Of those that read the top, each keeps the places below
## what it reads, and keeps what it reads only where it takes an `Integer`:
## a store or set of a slot that may hold one, `+ - * %` of two whose result
## stays one and the `/` of `Math.floor(a / b)` (`integer_binary`), the
## argument of `Math.floor`, `ceil`, `round` or `trunc`, an item read's or
## write's index (its value written is made a double). An ordering, `===`
## or `!==` of two `Integer`s fused with its `JumpIfFalse` (`joined` says
## whether another way reaches the jump, which fuses none) keeps those two,
## and any ordering or equality a `JumpIfFalse` follows
## keeps nothing below them, since a jump carries no `Integer`. Any other
## instruction keeps none.
integers_kept : LoweringBasics.Site,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
	demoted : List(U64),
	joined : Bool,
} -> List(Bool)
integers_kept = |site, { instruction, state, demoted, joined }| {
	depth = state.stack_kinds.len()
	# The places below the `read` on top kept, and of those read, the ones
	# `taken` says, bottom first.
	keeping = |read, taken|
		if depth < read {
			List.repeat(False, depth)
		} else {
			List.repeat(True, depth - read).concat(taken)
		}
	below = |down| LoweringBasics.kind_below(state, down)
	jumps_next = match site.code.ops.get(site.at + 1) {
		Ok(JumpIfFalse(_)) => True
		_ => False
	}
	match instruction {
		LoadLocal(_) | PushNumber(_) | PushText(_) | PushBoolean(_) => keeping(0, [])
		PushNull | PushUndefined | LoadBoxed(_) | UpdateLocal(_) => keeping(0, [])
		Pop | Duplicate => keeping(0, [])
		StoreLocal(slot) | SetLocal(slot) => keeping(1, [integer_storable(site, { slot, demoted })])
		Binary(operator, _) if jumps_next and !joined =>
			if is_integer_test(operator) and integers_on_top(state) {
				List.repeat(False, depth - 2).concat([True, True])
			} else {
				List.repeat(False, depth)
			}
		Binary(operator, _) if depth >= 2 => {
			takes = integer_binary(
				site,
				{
					operator,
					left: below(1),
					right: below(0),
					callee: kind_under(state, 2),
					step: 1,
					joined,
				},
			).is_ok()
			keeping(2, [takes, takes])
		}
		CallMethod(
			{ name: _, site: { count, written: _, at: _ } },
		) if count == 1 and depth >= 3 and BuiltinLowering.keeps_integer(below(1)) =>
			keeping(3, [False, False, True])
		Call({ count, written: _, at: _ }) if depth > count =>
			keeping(count + 1, [False].concat(integer_arguments(site, { state, count })))
		GetIndex(_) if depth >= 2 => keeping(2, [False, takes_integer_index(below(1))])
		SetIndex(_) if depth >= 3 => keeping(3, [False, takes_integer_index(below(2)), False])
		GetProperty(_, _) => keeping(1, [False])
		_ => List.repeat(False, depth)
	}
}

## Which of a direct call's `count` arguments, the first first, it passes as
## the `Integer`s they are: each where the callee's parameter settled at an
## `Integer` whose range holds the argument's (x86/README.md, "An integer
## kind"). A function a value may hold takes values, and one that packs its
## arguments takes them as an array's items, so neither takes one.
integer_arguments : LoweringBasics.Site, { state : LoweringBasics.State, count : U64 } -> List(Bool)
integer_arguments = |site, { state, count }| {
	context = site.context
	covers = |range, given| range.low <= given.low and given.high <= range.high
	taken = match LoweringBasics.kind_below(state, count) {
		Function(made) | Closure(made) if !context.escaped_codes.contains(made) =>
			match context.program.codes.get(made) {
				Ok(callee) if callee.arguments == Each(count) => context.parameters.get(made) ?? []
				_ => []
			}
		_ => []
	}
	state.stack_kinds.take_last(count).map_with_index(
		|kind, at|
			match (kind, taken.get(at)) {
				(Integer(given), Ok(Integer(range))) => covers(range, given)
				_ => False
			},
	)
}

## Each `Integer` on the stack made a double, in its place, but those
## `kept`.
integers_met : Bytecode.Code,
{ state : LoweringBasics.State, kept : List(Bool) } -> {
	statements : List(Assembly.Statement),
	state : LoweringBasics.State,
}
integers_met = |code, { state, kept }| {
	var $items = []
	var $kinds = state.stack_kinds
	for (kind, place) in state.stack_kinds.map_with_index(|kind, place| (kind, place)) {
		if LoweringBasics.is_integer(kind) and kept.get(place) != Ok(True) {
			at = LoweringBasics.stack_place(code, place)
			$items = $items.concat(LoweringBasics.integer_converted_items(at))
			$kinds = $kinds.set(place, Number) ?? crash "Lowering.integers_met: a place"
		}
	}
	{ statements: $items, state: { ..state, stack_kinds: $kinds } }
}

## The slots that hold an `Integer` on one of two ways that meet and anything
## else on the other, which the function is lowered again without
## (`Demoted`).
integer_clashes : LoweringBasics.State, LoweringBasics.State -> List(U64)
integer_clashes = |one, other| {
	var $out = []
	pairs = List.map2(
		one.slots,
		other.slots,
		|one_slot, other_slot| (one_slot, other_slot),
	)
	for (pair, slot) in pairs.map_with_index(|pair, slot| (pair, slot)) {
		clash = match pair {
			(Ready(Integer(_)), Ready(Integer(_))) => False
			(Ready(Integer(_)), Ready(_)) | (Ready(_), Ready(Integer(_))) => True
			_ => False
		}
		if clash {
			$out = $out.append(slot)
		}
	}
	$out
}

## A loop's head met with a way back (`met`), each `Integer` slot's range
## widened on the side it grew, to ±2^53 there, so a counter's head settles
## at once and a counter that only climbs keeps its least (`i = 0`, `i++`
## stays at least 0).
integers_widened : LoweringBasics.State, LoweringBasics.State -> LoweringBasics.State
integers_widened = |head, met| {
	limit = LoweringBasics.integer_limit
	slots = List.map2(
		head.slots,
		met.slots,
		|before, after|
			match (before, after) {
				(Ready(Integer(was)), Ready(Integer(grown))) if before != after => {
					low = if grown.low < was.low {
						0 - limit
					} else {
						grown.low
					}
					high = if grown.high > was.high {
						limit
					} else {
						grown.high
					}
					Ready(Integer({ low, high }))
				}
				_ => after
			},
	)
	{ ..met, slots }
}

## An instruction's values made: the code that makes them, the state
## after, and the functions it made values of.
Valued : {
	statements : List(Assembly.Statement),
	state : LoweringBasics.State,
	escaped : List(U64),
}

## Whether the instruction may let an array of numbers (`Numbers`) reach
## code that could store something else in it, or read it as another kind:
## the rule of `NUMBER-ONLY ARRAYS`, in the module's header. An instruction
## that reaches no `Numbers` is never one.
numbers_escaping : LoweringBasics.Site,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
} -> Bool
numbers_escaping = |site, { instruction, state }| {
	kinds = state.stack_kinds
	below = |down| LoweringBasics.kind_below(state, down)
	within = |reach| kinds.drop_first(kinds.len() - U64.min(reach, kinds.len())).contains(Numbers)
	held = |slot| state.slots.get(slot) == Ok(Ready(Numbers))
	all_numbers = |count| kinds.drop_first(kinds.len() - count).all(|kind| kind == Number)
	takes_each = |made, count|
		match site.context.program.codes.get(made) {
			Ok(callee) => callee.arguments == Each(count)
			Err(_) => False
		}
	match instruction {
		LoadLocal(_) | Pop | PushNumber(_) | PushText(_) | PushBoolean(_) => False
		PushNull | PushUndefined | LoadBoxed(_) | PeekBoxed(_) | LoadBuiltin(_) => False
		Jump(_) | Loop(_) => False
		StoreLocal(slot) | SetLocal(slot) =>
			below(0) == Numbers and site.context.cells.contains(slot)
		Binary(_, _) => within(2)
		Unary(_, _) | JumpIfFalse(_) => within(1)
		GetProperty(key, _) => below(0) == Numbers and key != "length"
		MethodLookup(name, _) => below(0) == Numbers and name != "push"
		GetIndex(_) => below(0) == Numbers or (below(1) == Numbers and !is_number_index(below(0)))
		SetIndex(_) =>
			if below(2) == Numbers {
				!is_number_index(below(1)) or below(0) != Number
			} else {
				within(2)
			}
		# console.log only reads what it prints.
		CallMethod({ name: _, site: { count, written: _, at: _ } }) if below(count) == Log => False
		CallIndexed({ count, written: _, at: _ }) => within(count + 2)
		CallMethod({ name: _, site: { count, written: _, at: _ } }) =>
			if below(count) == Method("push") and below(count + 1) == Numbers {
				!all_numbers(count)
			} else {
				within(count + 2)
			}
		# A direct call's arguments meet its parameters' kinds, which
		# `numbers_escape` holds once they settle.
		Call({ count, written: _, at: _ }) =>
			match below(count) {
				Function(made) | Closure(made) if takes_each(made, count) => False
				_ => within(count + 1)
			}
		UpdateLocal({ slot, step: _ }) | AppendLocal({ slot, at: _ }) => held(slot)
		# A walk only reads the items.
		IterStart(_) | IterNext(_) => False
		_ => within(kinds.len())
	}
}

## An array's kind as the inline reads and writes take it: an array of
## numbers is an array there.
array_kind : LoweringBasics.Kind -> LoweringBasics.Kind
array_kind = |kind|
	if kind == Numbers {
		Array
	} else {
		kind
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
		CallIndexed({ count, written: _, at: _ }) => count
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
meeting_state = |context, { at, one, other }| {
	if one.stack_kinds.len() != other.stack_kinds.len() {
		return Err(code_refusal(context, TwoStacks(at)))
	}
	var $stack_kinds = []
	for (a, b) in List.map2(
		one.stack_kinds,
		other.stack_kinds,
		|a, b| (a, b),
	) {
		if (a == Numbers or b == Numbers) and a != b {
			return Err(code_refusal(context, TwoStacks(at)))
		}
		match LoweringBasics.met_kind(a, b) {
			Ok(kind) => {
				$stack_kinds = $stack_kinds.append(kind)
			}
			Err(Apart) => return Err(code_refusal(context, TwoStacks(at)))
		}
	}
	var $slots = []
	for (a, b) in List.map2(
		one.slots,
		other.slots,
		|a, b| (a, b),
	) {
		slot = match (a, b) {
			(Ready(left), Ready(right)) if left != right and [left, right].contains(Numbers) =>
				return Err(code_refusal(context, TwoSlotKinds(at)))
			(Ready(left), Ready(right)) =>
				match LoweringBasics.met_kind(left, right) {
					Ok(kind) => Ready(kind)
					Err(Apart) => return Err(code_refusal(context, TwoSlotKinds(at)))
				}
			(Unready, Unready) => Unready
			_ => Unsure
		}
		$slots = $slots.append(slot)
	}
	Ok({ slots: $slots, stack_kinds: $stack_kinds })
}

## A known array's or string's length (`GetProperty` of `length`), as an
## `Integer`: at most 2^32, since the heap is 1 GiB.
length_integer : LoweringBasics.Kind
length_integer = Integer({ low: 0, high: 4294967296 })

## Whether an index is a known number, a double or an `Integer`.
is_number_index : LoweringBasics.Kind -> Bool
is_number_index = |kind| kind == Number or LoweringBasics.is_integer(kind)

## The index `down` places from the top made a double where it is an
## `Integer`, as an item read's or write's slow way begins: the runtime's
## routine takes values.
index_double_items : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	down : U64,
} -> List(Assembly.Statement)
index_double_items = |site, { state, down }|
	if LoweringBasics.is_integer(LoweringBasics.kind_below(state, down)) {
		place = state.stack_kinds.len() - 1 - down
		LoweringBasics.integer_converted_items(LoweringBasics.stack_place(site.code, place))
	} else {
		[]
	}

## The machine code of one instruction, and the kinds after it.
instruction_items : LoweringBasics.Site,
{
	instruction : Bytecode.Op,
	state : LoweringBasics.State,
	checked : IndexLowering.Checked,
} -> Try(LoweringBasics.Lowered, [Refused(Str)])
instruction_items = |site, { instruction, state, checked }| {
	depth = state.stack_kinds.len()
	top_place = |down| LoweringBasics.stack_place(site.code, depth - 1 - down)
	next_place = LoweringBasics.stack_place(site.code, depth)
	if site.skipped.contains(site.at) {
		return Ok(LoweringBasics.falling([], state))
	}
	if numbers_escaping(site, { instruction, state }) {
		return LoweringBasics.refusal(site, "an array of numbers may escape here")
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
			# A known array's or string's length is an `Integer`: it can't pass
			# 2^32 in a heap of 1 GiB.
			given = match (kind, key) {
				(String, "length") | (Array, "length") | (Numbers, "length") =>
					if site.context.trying {
						Number
					} else {
						length_integer
					}
				_ => Value
			}
			# The key's hash, worked out here, saves hashing it as it runs
			# (ObjectTable's header); so do the write's and the method's below.
			called = [
				Emit.load(Rdi, top_place(0)),
				Emit.address_of(Rsi, LoweringBasics.text_label(site, key)),
				Emit.imm(R8, ObjectTable.key_hash(key)),
				Emit.call(property_reader(site, key)),
				Emit.store(top_place(0), Rax),
			]
			# Of `undefined` or `null`, the runtime throws node's TypeError.
			match kind {
				String | Array | Numbers | Object | Value | Null | Undefined =>
					Ok(
						LoweringBasics.falling(
							if key == "length" {
								IndexLowering.length_items(
									site,
									{
										kind: array_kind(kind),
										place: top_place(0),
										integer: LoweringBasics.is_integer(given),
										slow_items: called,
									},
								)
							} else {
								called
							},
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
			items = state.stack_kinds.drop_first(base)
			numbers = site.context.numbers_arrays and items.all(|kind| kind == Number)
			Ok(
				LoweringBasics.falling(
					made,
					LoweringBasics.with_top(
						LoweringBasics.without_top(state, count),
						if numbers {
							Numbers
						} else {
							Array
						},
					),
				),
			)
		}
		NewObject => Ok(
			LoweringBasics.falling(
				[Emit.call(Runtime.new_object), Emit.store(next_place, Rax)],
				LoweringBasics.with_top(state, Object),
			),
		)
		# A class's instance, made from its class's table on top: an object
		# whose first key is the instance's mark, holding the table, where a
		# property the instance lacks is read (ObjectTable's
		# `runtime_get_inherited`), then a key for its class and each class
		# that class extends.
		NewInstance(classes) => {
			marked = |{ key, value }| [
				Emit.load(Rdi, next_place),
				Emit.address_of(Rsi, key),
				value,
				Emit.call(Runtime.set_property),
			]
			keys = List.concat(
				[{ key: RuntimeBuilders.instance_mark, value: Emit.load(Rdx, top_place(0)) }],
				classes.map(
					|name| {
						key: LoweringBasics.text_label(site, class_key(name)),
						value: Emit.imm(Rdx, Boxing.true_bits),
					},
				),
			)
			Ok(
				LoweringBasics.falling(
					[Emit.call(Runtime.new_object), Emit.store(next_place, Rax)]
						.concat(keys.map(marked).join())
						.concat([Emit.load(Rax, next_place), Emit.store(top_place(0), Rax)]),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Object),
				),
			)
		}
		# The value, then the class read (which takes no bytes or is a value
		# left unread): a boolean in the value's place.
		InstanceOf(name) =>
			if !LoweringBasics.is_value_kind(LoweringBasics.kind_below(state, 1)) {
				phrase = LoweringBasics.kind_phrase(LoweringBasics.kind_below(state, 1))
				LoweringBasics.refusal(site, "`instanceof` of ${phrase}")
			} else {
				Ok(
					LoweringBasics.falling(
						[
							Emit.load(Rdi, top_place(1)),
							Emit.address_of(Rsi, LoweringBasics.text_label(site, class_key(name))),
							Emit.call(Runtime.instance_of),
							Emit.store(top_place(1), Rax),
						],
						LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
					),
				)
			}
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
		AppendItem | AppendSpread(_) => CallLowering.spread_items(site, { state, instruction })
		SpreadFields(_) | PropertiesLeft(_) => CallLowering.spread_items(
			site,
			{ state, instruction },
		)
		CallSpread(_) | CallMethodSpread(_) => CallLowering.spread_items(
			site,
			{ state, instruction },
		)
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
								Emit.imm(R8, ObjectTable.key_hash(key)),
								Emit.call(ObjectTable.set_property_hashed),
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
		GetIndex(_) if LoweringBasics.kind_below(state, 1) == Numbers =>
			Ok(
				LoweringBasics.falling(
					IndexLowering.item_read_items(
						site,
						{
							kinds: (Array, LoweringBasics.kind_below(state, 0)),
							receiver: top_place(1),
							index: top_place(0),
							checks: IndexLowering.checks_for(checked, instruction),
							slow_items: [Emit.jmp(Runtime.numbers_read_not_compiled)],
						},
					),
					LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
				),
			)
		GetIndex(_) =>
			match LoweringBasics.kind_below(state, 1) {
				Array | String | Object | Value | Null | Undefined => {
					called = index_double_items(site, { state, down: 0 }).concat([
						Emit.load(Rdi, top_place(1)),
						Emit.load(Rsi, top_place(0)),
						Emit.call(Runtime.get_index),
						Emit.store(top_place(1), Rax),
					])
					Ok(
						LoweringBasics.falling(
							IndexLowering.item_read_items(
								site,
								{
									kinds: (
										LoweringBasics.kind_below(state, 1),
										LoweringBasics.kind_below(state, 0),
									),
									receiver: top_place(1),
									index: top_place(0),
									checks: IndexLowering.all_checks,
									slow_items: called,
								},
							),
							LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Value),
						),
					)
				}
				kind => LoweringBasics.refusal(
					site,
					"an index of ${LoweringBasics.kind_phrase(kind)}",
				)
			}
		SetIndex(_) =>
			match LoweringBasics.kind_below(state, 2) {
				Array | Numbers | Object | Value | Null | Undefined => {
					value = LoweringBasics.kind_below(state, 0)
					called = index_double_items(site, { state, down: 1 }).concat([
						Emit.load(Rdi, top_place(2)),
						Emit.load(Rsi, top_place(1)),
						Emit.load(Rdx, top_place(0)),
						Emit.call(Runtime.set_index),
					])
					Ok(
						LoweringBasics.falling(
							IndexLowering.item_write_items(
								site,
								{
									kinds: (
										array_kind(LoweringBasics.kind_below(state, 2)),
										LoweringBasics.kind_below(state, 1),
									),
									receiver: top_place(2),
									index: top_place(1),
									value_place: top_place(0),
									checks: if LoweringBasics.kind_below(state, 2) == Numbers {
										IndexLowering.checks_for(checked, instruction)
									} else {
										IndexLowering.all_checks
									},
									slow_items: called,
								},
							).concat(
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
				Array | Numbers => Ok(LoweringBasics.falling([], state))
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
			exit_label = LoweringBasics.place_label(site.context, target)
			walked = LoweringBasics.slot_kind(site, { state, slot, name: "a walk" })?
			{ stepped, item } = match walked {
				Array | Numbers => {
					item_kind =
						if walked == Numbers {
							Number
						} else {
							Value
						}
					{
						stepped: IndexLowering.walk_step_items({
							slot,
							stored: next_place,
							exit: exit_label,
						}),
						item: item_kind,
					}
				}
				_ => {
					called = [
						Emit.load(Rdi, LoweringBasics.slot_place(slot)),
						Emit.load(Rsi, LoweringBasics.slot_place(slot + 1)),
						Emit.call(Runtime.next_item),
						Emit.test(Rdx, Rdx),
						Emit.jcc(E, exit_label),
						Emit.store(next_place, Rax),
						Emit.store(LoweringBasics.slot_place(slot + 1), Rcx),
					]
					{ stepped: called, item: Value }
				}
			}
			Ok({
				statements: stepped,
				falls: Falls(LoweringBasics.with_top(state, item)),
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
			match site.context.numbers.get(slot) {
				Ok(number) =>
					return Ok(
						LoweringBasics.falling(
							LoweringBasics.constant_items({
								bits: number.to_bits(),
								to: next_place,
							}),
							LoweringBasics.with_top(state, Number),
						),
					)
				Err(_) => {}
			}
			Ok(
				LoweringBasics.falling(
					CallLowering.boxed_load_items(site, { state, slot }),
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
					CallLowering.boxed_load_items(site, { state, slot }),
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
					CallLowering.boxed_store_items(site, { state, slot }),
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
					Ok(
						LoweringBasics.falling(
							CallLowering.boxed_store_items(site, { state, slot }),
							after,
						),
					)
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
						if site.context.cells.contains(slot) {
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
			if site.context.cells.contains(slot) {
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
		UpdateLocal({ slot, step }) =>
			match state.slots.get(slot) {
				Ok(Ready(Integer(range))) => {
					stepped = LoweringBasics.integer_stepped(Integer(range), step.delta)
						?? crash "Lowering.instruction_items: integers_made keeps it an Integer"
					Ok(OperatorLowering.integer_update_items(site, { state, slot, step, stepped }))
				}
				_ => LoweringBasics.update_items(site, { state, slot, step })
			}
		UpdateBoxed({ slot, name: _, kind, step }) =>
			match kind {
				Fixed => Ok(BuiltinLowering.constant_assigned_items)
				Mutable =>
					if site.context.cells.contains(slot) {
						CallLowering.cell_update_items(site, { state, slot, step })
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
		Binary(operator, _) =>
			match LoweringBasics.integer_arithmetic({
				operator,
				left: LoweringBasics.kind_below(state, 1),
				right: LoweringBasics.kind_below(state, 0),
			}) {
				Ok(kind) => Ok(
					OperatorLowering.integer_arithmetic_items(
						site,
						{ state, operator, kind, checked },
					),
				)
				Err(NotInteger) => OperatorLowering.binary_items(site, { state, operator, checked })
			}
		Jump(skip) => {
			target = LoweringBasics.forward(site, skip)
			Ok({
				statements: [JmpTo(LoweringBasics.place_label(site.context, target))],
				falls: Ends,
				branch: Branch({ target, state }),
				result: GivesNothing,
			})
		}
		Loop(back) => {
			target = site.at + 1 - back
			Ok({
				statements: [JmpTo(LoweringBasics.place_label(site.context, target))],
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
				(Numbers, "push") =>
					Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Method(name))))
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
								Emit.imm(R8, ObjectTable.key_hash(name)),
								Emit.call(property_reader(site, name)),
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
				Value => CallLowering.value_call_items(site, { state, count, taken: count + 2 })
				kind => LoweringBasics.refusal(
					site,
					"a method call of ${LoweringBasics.kind_phrase(kind)} is not compiled yet",
				)
			}
		Call({ count, written: _, at: _ }) => CallLowering.call_items(site, { state, count })
		# `o[k](...)`: what the key reads, called with `o` as the receiver.
		CallIndexed({ count, written: _, at: _ }) => {
			call = { state, count, taken: count + 2 }
			CallLowering.value_call_items(site, call)
		}
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
		MakeClosure({ code: made, captures, definition: _ }) =>
			if site.context.statics.contains(made) {
				Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Function(made))))
			} else {
				Ok(
					LoweringBasics.falling(
						CallLowering.record_items(site, { made, captures, place: next_place }),
						LoweringBasics.with_top(state, Closure(made)),
					),
				)
			}
		MissingName({ name: "Date", at: _ }) => BuiltinLowering.date_items(site, { state: state })
		MissingName({ name, at: _ }) => LoweringBasics.refusal(
			site,
			"`${name}` is declared nowhere, which throws in node",
		)
		ThrowUnready({ name, at: _ }) => Ok(BuiltinLowering.unready_items(site, name))
		ThrowConstant(_) | UpdateFixed(_) => Ok(BuiltinLowering.constant_assigned_items)
		Refuse(why) => LoweringBasics.refusal(site, why)
		EnterTry({ handler, kind }) => CallLowering.try_items(
			site,
			{ state, skip: handler, handling: kind },
		)
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

## Whether lowering a program keeps an array of numbers as `Numbers`: its
## code with them is longer or shorter than its code without, for the
## expects.
keeps_numbers : List(Str) -> Bool
keeps_numbers = |source_lines| {
	src = Str.join_with(source_lines, "\n")
	tree = Parser.program_of(src, Core) ?? crash "Lowering.keeps_numbers: a program that parses"
	program = match Compile.program(tree) {
		Ok(compiled) => compiled
		Err(_) => crash "Lowering.keeps_numbers: a program that compiles"
	}
	plain = items_with_numbers(program, False) ?? crash "Lowering.keeps_numbers: it lowers"
	match items_with_numbers(program, True) {
		Ok(items) => items.len() != plain.len()
		Err(_) => False
	}
}

# An array of number literals, pushed and written with numbers, passed to a
# function called directly and read there: kept.
expect keeps_numbers([
	"function sum(a) {",
	"  let t = 0; let i = 0;",
	"  while (i < a.length) { t = t + a[i]; i = i + 1; }",
	"  return t;",
	"}",
	"function main() {",
	"  const a = [1, 2]; a.push(3); a[0] = 5;",
	"  console.log(sum(a), a);",
	"}",
	"main();",
])

# An empty array grown by a function's pushes: kept.
expect keeps_numbers([
	"function grow(a) { a.push(1); a.push(2); }",
	"function main() { const a = []; grow(a); console.log(a[0] + a[1]); }",
	"main();",
])

# A string pushed: not kept.
expect !keeps_numbers(
	["function main() { const a = [1, 2]; a.push(\"x\"); console.log(a[0]); }", "main();"],
)

# A write of a value of unknown kind: not kept.
expect !keeps_numbers([
	"function main() {",
	"  const o = { k: 1 }; const a = [1]; a[0] = o.k;",
	"  console.log(a[0]);",
	"}",
	"main();",
])

# Stored in an object, where code could store anything in it: not kept.
expect !keeps_numbers([
	"function main() {",
	"  const a = [1]; const o = { a }; o.a.push(\"x\");",
	"  console.log(a[0]);",
	"}",
	"main();",
])

# Passed to a function that is also given an array of strings: not kept.
expect !keeps_numbers([
	"function first(a) { return a[0]; }",
	"function main() { console.log(first([1]), first([\"x\"])); }",
	"main();",
])

# Captured by a closure, which could write through its cell: not kept.
expect !keeps_numbers([
	"function main() {",
	"  const a = [1]; const f = () => a.push(\"x\"); f();",
	"  console.log(a[0]);",
	"}",
	"main();",
])

## How many conversions between a double and an integer (`cvttsd2si`,
## `cvtsi2sd`) a program's own code holds, the runtime's routines left out,
## for the expects: a place's label, and every label of an instruction's
## pieces, starts with `code_`.
conversions_in_code : List(Str) -> U64
conversions_in_code = |source_lines| {
	src = Str.join_with(source_lines, "\n")
	tree = Parser.program_of(
		src,
		Core,
	) ?? crash "Lowering.conversions_in_code: a program that parses"
	program = match Compile.program(tree) {
		Ok(compiled) => compiled
		Err(_) => crash "Lowering.conversions_in_code: a program that compiles"
	}
	statements = Lowering.program_items(program) ?? crash "Lowering.conversions_in_code: it lowers"
	var $in_code = False
	var $count = 0
	for statement in statements {
		match statement {
			Mark(label) => {
				$in_code = label.starts_with("code_")
			}
			Instruction(Cvttsd2si(_)) | Instruction(Cvtsi2sd(_)) if $in_code => {
				$count = $count + 1
			}
			_ => {}
		}
	}
	$count
}

# A counter that a length bounds, stepped by 1, indexes an array of numbers
# with no conversion at all: the counter, the length and the index are
# integers, and the sum is a double.
expect conversions_in_code([
	"function sum(a) {",
	"  const n = a.length; let t = 0; let i = 0;",
	"  while (i < n) { t = t + a[i]; i = i + 1; }",
	"  return t;",
	"}",
	"function main() { const a = [1, 2]; console.log(sum(a)); }",
	"main();",
]) == 0

# The same counter stepped by a half takes a fraction: it is demoted to a
# double, so the length is made one to be compared, and the index made an
# integer again.
expect conversions_in_code([
	"function sum(a) {",
	"  const n = a.length; let t = 0; let i = 0;",
	"  while (i < n) { t = t + a[i]; i = i + 0.5; }",
	"  return t;",
	"}",
	"function main() { const a = [1, 2]; console.log(sum(a)); }",
	"main();",
]) >= 2

## The conversions of a function that counts to its parameter `k`, called
## with `k` from each of the `calls`.
counted_to : Str -> U64
counted_to = |calls|
	conversions_in_code([
		"function steps(k) {",
		"  let t = 0;",
		"  for (let j = 0; j < k; j++) t = t + j % 3;",
		"  return t;",
		"}",
		"function main() { console.log(${calls}); }",
		"main();",
	])

# A parameter every call passes an `Integer` is one, so the counter tested
# against it stays one: fewer conversions than when a call passes a fraction,
# which leaves `k` a double and demotes the counter.
expect counted_to("steps(4), steps(9)") < counted_to("steps(4), steps(9.5)")

# A recursion that steps its parameter settles, its range widened.
expect conversions_in_code([
	"function down(n) { if (n === 0) return 0; return 1 + down(n - 1); }",
	"console.log(down(10));",
]) < 10

## A refusal's words when an array of numbers reaches a parameter that
## may hold another value.
numbers_escape_text : Str
numbers_escape_text = "an array of numbers is passed where a parameter may hold another value"
