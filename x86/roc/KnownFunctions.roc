## This module holds the closure analysis of the x86-64 lowering: which
## code each `MakeClosure` makes and where (`makers_of`), the functions a
## code's start declares (`declared_functions`), the function known before
## the program runs that a slot holds (`held_function`), the codes known so
## (`statics_of`), the slots that hold a cell (`celled_slots`), and the
## read-only closure records and console.log texts of the functions a value
## may hold (`closure_statements`).
##
## It stands apart from Lowering because it is an analysis of the whole
## program, run before any instruction is lowered, and reads only the
## bytecode: what it decides (a function known by its code alone, a
## variable in a cell) every lowered instruction then takes as given.
import js.Bytecode
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
	## class and whose captures are all functions known so, the most that
	## hold together (fib, which captures only itself, is one).
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
					maker.captures.all(
						|from|
							match held_function(known, { code: maker.parent, slot: from }) {
								Ok(_) => True
								Err(Unheld) => False
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
						ops = program.codes.get(made).map_ok(|code| code.ops) ?? []
						var $parents = []
						for op in ops {
							match op {
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
