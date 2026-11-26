## This module holds the closure analysis of the x86-64 lowering: which
## code each `MakeClosure` makes and where (`makers_of`), the functions a
## code's start declares (`declared_functions`), the function known before
## the program runs that a slot holds (`held_function`), the codes known so
## (`statics_of`), the slots that hold a cell (`celled_slots`), the captured
## cells that hold one number for good (`constant_numbers`), and the
## read-only closure records and console.log texts of the functions a value
## may hold (`closure_statements`).
##
## It stands apart from Lowering because it is an analysis of the whole
## program, run before any instruction is lowered, and reads only the
## bytecode: what it decides (a function known by its code alone, a
## variable in a cell) every lowered instruction then takes as given.
import js.Bytecode
import js.Compile
import js.Parser
import Assembly
import LoweringBasics
import Runtime

KnownFunctions :: [].{

	## Each code a `MakeClosure` makes, with where it is made: a code made at
	## two places is refused, since its captures would differ.
	makers_of : Bytecode.Program -> Try(Dict(U64, LoweringBasics.Maker), [Refused(Str)])
	makers_of = |program| {
		var $makers = Dict.empty()
		for parent in 0..<program.codes.len() {
			code = program.codes.get(parent) ?? crash "KnownFunctions.makers_of: a code's index"
			for instruction in code.ops {
				match instruction {
					MakeClosure({ code: made, captures, definition }) => {
						if $makers.contains(made) {
							name = definition.unbox().name
							return Err(Refused("the function `${name}` is made at two places"))
						}
						$makers = $makers.insert(
							made,
							{
								parent,
								captures,
								name: definition.unbox().name,
								form: definition.unbox().form,
							},
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

	## The function known before the program runs that a slot of `code`'s
	## frame holds: one declared at the code's start, or one its maker's slot
	## holds, for a captured slot, in turn.
	held_function : LoweringBasics.Known, { code : U64, slot : U64 } -> Try(U64, [Unheld])
	held_function = |known, { code, slot }| {
		frame = known.program.codes.get(code) ?? crash "KnownFunctions.held_function: a code"
		match declared_functions(frame).get(slot) {
			Ok(made) =>
				if known.statics.contains(made) {
					Ok(made)
				} else {
					Err(Unheld)
				}
			Err(_) => {
				captured = frame.entry.find_first(
					|step|
						match step {
							CapturedBox({ slot: held, capture: _ }) => held == slot
							_ => False
						},
				)
				match (captured, known.makers.get(code)) {
					(Ok(CapturedBox({ slot: _, capture })), Ok(maker)) => {
						from =
							maker.captures.get(capture)
								?? crash "KnownFunctions.held_function: a capture"
						held_function(known, { code: maker.parent, slot: from })
					}
					_ => Err(Unheld)
				}
			}
		}
	}

	## The codes known before the program runs: every function that is no
	## class and whose captures are all functions known so, or numbers held
	## for good (`constant_numbers`) that it passes on to no closure of its
	## own, the most that hold together (fib, which captures only itself, is
	## one; the fib race's addInto, which captures `BASE`, another). A read of
	## such a number is the number, so the function needs no cell of it, and
	## so no closure record of its own.
	statics_of : Bytecode.Program, Dict(U64, LoweringBasics.Maker) -> List(U64)
	statics_of = |program, makers| {
		var $statics =
			makers
				.to_list()
				.keep_if(|(_, maker)| maker.form == Ordinary)
				.map(|(made, _)| made)
		var $going = True
		while $going {
			known = { program, makers, statics: $statics }
			kept = $statics.keep_if(
				|made| {
					maker = makers.get(made) ?? crash "KnownFunctions.statics_of: a maker"
					numbers = KnownFunctions.constant_numbers(known, made)
					code = program.codes.get(made) ?? crash "KnownFunctions.statics_of: a code"
					maker.captures.map_with_index(|from, capture| (from, capture)).all(
						|(from, capture)|
							match held_function(known, { code: maker.parent, slot: from }) {
								Ok(_) => True
								Err(Unheld) =>
									match captured_slot(code, capture) {
										Ok(slot) =>
											numbers.contains(slot) and !passes_on(code, slot)
										Err(_) => False
									}
							},
					)
				},
			)
			$going = kept.len() != $statics.len()
			$statics = kept
		}
		$statics
	}

	## The slots of code `index`'s frame that hold a cell: each a closure made
	## there captures, and each it captures itself, that holds no function
	## known before the program runs.
	celled_slots : LoweringBasics.Known, U64 -> List(U64)
	celled_slots = |known, index| {
		code = known.program.codes.get(index) ?? crash "KnownFunctions.celled_slots: a code"
		unheld = |slot|
			match held_function(known, { code: index, slot }) {
				Ok(_) => False
				Err(Unheld) => True
			}
		var $cells = []
		for instruction in code.ops {
			match instruction {
				MakeClosure({ code: _, captures, definition: _ }) =>
					for from in captures {
						if unheld(from) and !$cells.contains(from) {
							$cells = $cells.append(from)
						}
					}
				_ => {}
			}
		}
		for step in code.entry {
			match step {
				CapturedBox({ slot, capture: _ }) =>
					if unheld(slot) and !$cells.contains(slot) {
						$cells = $cells.append(slot)
					}
				_ => {}
			}
		}
		$cells
	}

	## The captured slots of code `index`'s frame whose cell holds one number
	## for as long as the code can run, with the number: a variable of the
	## maker's frame (`const BASE = 10000000;` at a program's top) that the
	## maker sets from a number literal in the straight run of declarations its
	## code starts with, before anything that can run code (a call, a read, an
	## operator), and that nothing else writes: not the maker again, not any
	## code it makes that captures it, and no code those make in turn (a code
	## that passes the cell on to a closure of its own keeps it a cell). A
	## closure made by the maker can run only once the maker runs code, so
	## every read of the cell comes after it is set: the number is the read's
	## value, with no tag to test and no ReferenceError to throw.
	constant_numbers : LoweringBasics.Known, U64 -> Dict(U64, F64)
	constant_numbers = |known, index| {
		code = known.program.codes.get(index) ?? crash "KnownFunctions.constant_numbers: a code"
		var $found = Dict.empty()
		match known.makers.get(index) {
			Ok(maker) =>
				for step in code.entry {
					match step {
						CapturedBox({ slot, capture }) => {
							from =
								maker.captures.get(capture)
									?? crash "KnownFunctions.constant_numbers: a capture"
							match held_number(known, { parent: maker.parent, slot: from }) {
								Ok(number) => {
									$found = $found.insert(slot, number)
								}
								Err(Unset) => {}
							}
						}
						_ => {}
					}
				}
			Err(_) => {}
		}
		$found
	}

	## Whether `key` names some class's method in the program (a code whose
	## form is `Method`, or a parent's method kept for `super`), so that a
	## read of it looks in an instance's class's table first (ObjectTable's
	## header).
	is_method_name : Dict(U64, LoweringBasics.Maker), Str -> Bool
	is_method_name = |makers, key|
		key.starts_with("þsuper ")
			or makers.to_list().any(|(_, maker)| maker.form == Method and maker.name == key)

	## The text console.log writes for each function a value may hold, and the
	## closure record, in the read-only segment, of each known before the
	## program runs (`Boxing.function_tag`'s layout, with no captures).
	## A class's is node's `[class C]`, or `[class C extends P]`, P read
	## from its instances' keys (`NewInstance`, its own class first).
	closure_statements : {
		program : Bytecode.Program,
		makers : Dict(U64, LoweringBasics.Maker),
		statics : List(U64),
		escaped_codes : List(U64),
	} -> List(Assembly.Statement)
	closure_statements = |{ program, makers, statics, escaped_codes }| {
		var $out = []
		for (made, maker) in makers.to_list() {
			if escaped_codes.contains(made) {
				text =
					if maker.form == MakesInstances {
						instructions = program.codes.get(made).map_ok(|code| code.ops) ?? []
						var $parents = []
						for instruction in instructions {
							match instruction {
								NewInstance(classes) => {
									$parents = classes.drop_first(1)
								}
								_ => {}
							}
						}
						match $parents.first() {
							Ok(parent) => "[class ${maker.name} extends ${parent}]"
							Err(_) => "[class ${maker.name}]"
						}
					} else if maker.name == "" {
						"[Function (anonymous)]"
					} else {
						"[Function: ${maker.name}]"
					}
				$out = $out.concat([
					Mark(LoweringBasics.function_text_label(made)),
					Data(Runtime.string_data(text)),
				])
				if statics.contains(made) {
					$out = $out.concat([
						Mark(LoweringBasics.closure_label(made)),
						Distance(LoweringBasics.value_label(made)),
						Distance(LoweringBasics.function_text_label(made)),
						Data(List.repeat(0, 8)),
					])
				}
			}
		}
		$out
	}
}

## The slot of a code's frame that holds its closure's capture `capture`.
captured_slot : Bytecode.Code, U64 -> Try(U64, [NotCaptured])
captured_slot = |code, capture| {
	for step in code.entry {
		match step {
			CapturedBox({ slot, capture: at }) if at == capture => return Ok(slot)
			_ => {}
		}
	}
	Err(NotCaptured)
}

## Whether a code passes the cell in a slot on to a closure it makes.
passes_on : Bytecode.Code, U64 -> Bool
passes_on = |code, slot|
	code.ops.any(
		|instruction|
			match instruction {
				MakeClosure({ code: _, captures, definition: _ }) => captures.contains(slot)
				_ => False
			},
	)

## The number a slot of code `parent`'s frame holds for good, as
## `constant_numbers` says: its box fresh at the code's entry, set once,
## from a number literal, in the declarations the code starts with, and
## written by nothing else.
held_number : LoweringBasics.Known, { parent : U64, slot : U64 } -> Try(F64, [Unset])
held_number = |known, { parent, slot }| {
	code = known.program.codes.get(parent) ?? crash "KnownFunctions.held_number: a code"
	if !code.entry.contains(FreshBox(slot)) {
		return Err(Unset)
	}
	if code.ops.count_if(|instruction| writes_slot(instruction, slot)) != 1 {
		return Err(Unset)
	}
	var $number = Err(Unset)
	var $at = 0
	var $going = True
	while $going {
		match (code.ops.get($at), code.ops.get($at + 1)) {
			(Ok(PushNumber(number)), Ok(SetBoxed(set))) => {
				if set == slot {
					$number = Ok(number)
				}
				$at = $at + 2
			}
			(Ok(instruction), _) if is_declaring(instruction) => {
				$at = $at + 1
			}
			_ => {
				$going = False
			}
		}
	}
	if $number.is_err() {
		return Err(Unset)
	}
	for (made, maker) in known.makers.to_list() {
		if maker.parent == parent {
			for (from, capture) in maker.captures.map_with_index(|from, capture| (from, capture)) {
				if from == slot and is_written_where_captured(known, { made, capture }) {
					return Err(Unset)
				}
			}
		}
	}
	$number
}

## Whether code `made` writes the slot its capture `capture` lands in, or
## captures that slot in a closure of its own.
is_written_where_captured : LoweringBasics.Known, { made : U64, capture : U64 } -> Bool
is_written_where_captured = |known, { made, capture }| {
	code = known.program.codes.get(made) ?? crash "KnownFunctions.is_written_where_captured: a code"
	code.entry.any(
		|step|
			match step {
				CapturedBox({ slot, capture: at }) if at == capture =>
					code.ops.any(
						|instruction|
							match instruction {
								MakeClosure(
									{ code: _, captures, definition: _ },
								) => captures.contains(slot)
								_ => writes_slot(instruction, slot)
							},
					)
				_ => False
			},
	)
}

## Whether an instruction may run nothing but declarations, so none of the
## program's code: a closure made, a literal pushed, a declaration set.
is_declaring : Bytecode.Op -> Bool
is_declaring = |instruction|
	match instruction {
		MakeClosure(_) | SetBoxed(_) | SetLocal(_) => True
		PushNumber(_) | PushText(_) | PushBoolean(_) | PushNull | PushUndefined => True
		_ => False
	}

## Whether an instruction writes a slot of its frame, or makes a fresh box
## there: an assignment to a `const` only throws, so it writes nothing.
writes_slot : Bytecode.Op, U64 -> Bool
writes_slot = |instruction, slot|
	match instruction {
		StoreLocal(written) | SetLocal(written) | SetBoxed(written) => written == slot
		NewBox(written) | CopyBox(written) => written == slot
		StoreBoxed(
			{
				slot: written,
				name: _,
				kind: Mutable,
				at: _,
			},
		) => written == slot
		UpdateBoxed(
			{
				slot: written,
				name: _,
				kind: Mutable,
				step: _,
			},
		) => written == slot
		AppendLocal({ slot: written, at: _ }) => written == slot
		UpdateLocal({ slot: written, step: _ }) => written == slot
		IterNext({ slot: written, exit: _ }) => written == slot
		_ => False
	}

## The captured numbers `constant_numbers` finds for the program's first
## function, each number as its bits, for the expects.
first_function_numbers : List(Str) -> List((U64, U64))
first_function_numbers = |source_lines| {
	src = Str.join_with(source_lines, "\n")
	tree = Parser.program_of(
		src,
		Core,
	) ?? crash "KnownFunctions.first_function_numbers: a program that parses"
	program = match Compile.program(tree) {
		Ok(compiled) => compiled
		Err(_) => crash "KnownFunctions.first_function_numbers: a program that compiles"
	}
	makers =
		KnownFunctions.makers_of(program)
			?? crash "KnownFunctions.first_function_numbers: its makers"
	known = {
		program,
		makers,
		statics: KnownFunctions.statics_of(program, makers),
	}
	KnownFunctions.constant_numbers(known, 0).to_list().map(
		|(slot, number)| (slot, number.to_bits()),
	)
}

# A top-level `const` set from a number literal, before any call: its number.
expect {
	found = first_function_numbers(
		["const BASE = 7;", "function f() { return BASE; }", "console.log(f());"],
	)
	seven : F64
	seven = 7
	found.map(|(_, bits)| bits) == [seven.to_bits()]
}

# A `let` assigned again later holds no number for good.
expect first_function_numbers(
	["let BASE = 7;", "function f() { return BASE; }", "BASE = 8;", "console.log(f());"],
) == []

# Nor one the function itself assigns.
expect first_function_numbers(
	["let BASE = 7;", "function f() { BASE = 2; return BASE; }", "console.log(f());"],
) == []

# Nor one declared after a call, which may read it before it is set (node's
# ReferenceError).
expect first_function_numbers(
	["console.log(f());", "const BASE = 7;", "function f() { return BASE; }"],
) == []

# Nor one set from anything but a number literal.
expect first_function_numbers(
	["const BASE = 7 / 2;", "function f() { return BASE; }", "console.log(f());"],
) == []

# Nor one the function passes on to a closure of its own.
expect first_function_numbers(
	["const BASE = 7;", "function f() { return () => BASE; }", "console.log(f()());"],
) == []
