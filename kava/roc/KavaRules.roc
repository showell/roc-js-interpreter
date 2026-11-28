## This module holds KavaScript's static rules, judged once the program is
## read, from the names it met (`KavaState.Use`), each broken one a fault at
## its line and column:
##
## - **Non-interference:** ordinary code never names a ghost (a `ghost let`'s
##   or `ghost const`'s name, or a class's ghost field), and declares no name
##   a ghost has; and a ghost writes only ghosts. Deleting every ghost then
##   can't change what the program does. A ghost's name is one name in the
##   whole file, so the rule needs no scopes. A ghost's calls are trusted:
##   a ghost that calls a method that writes ordinary state isn't seen.
## - **Hand-overs:** after `own a`, `a` is not used again in the block it
##   was handed over in (a plain `a = ...` there gives it a new value), and
##   a hand-over inside a loop gives `a` a new value before the next pass or
##   declares `a` inside the loop. A use these miss (in another block, or
##   through a closure) meets a checked build's poison.
## - `own` hands over a `let` or a parameter: a `const` can't be poisoned.
##
## It also writes the checked build's reads of a handed-over name, each
## through `$kava_live`, which throws when the name holds the poison.
import js.Lexer
import Edits
import KavaState

KavaRules :: [].{
	fault_at : KavaState.Use, Str -> Lexer.Fault
	fault_at = |met, why| {
		why: why,
		line: met.line,
		column: met.column,
	}

	ghosts_kept_apart : KavaState.State -> Try({}, Lexer.Fault)
	ghosts_kept_apart = |reader| {
		names = reader.ghost_names
		fields = reader.ghost_fields
		for met in reader.uses {
			is_ghost = names.contains(met.name)
			is_ghost_field = fields.contains(met.name)
			broken = match (met.code, met.role) {
				(Ordinary, Bound) if is_ghost => Err("`${met.name}` is a ghost's name, and ordinary code may not declare it")
				(Ordinary, Field) if is_ghost_field => Err("ordinary code may not read the ghost field `${met.name}`")
				(Ordinary, FieldWritten) if is_ghost_field => Err("ordinary code may not write the ghost field `${met.name}`")
				(Ordinary, Bound) => Ok({})
				(Ordinary, Field) => Ok({})
				(Ordinary, FieldWritten) => Ok({})
				(
					Ordinary,
					_,
				) if is_ghost => Err("ordinary code may not read or write the ghost `${met.name}`")
				(
					Ghostly,
					Assigned,
				) if !is_ghost => Err("a ghost may not write `${met.name}`, which is no ghost")
				(
					Ghostly,
					Updated,
				) if !is_ghost => Err("a ghost may not write `${met.name}`, which is no ghost")
				(Ghostly, FieldWritten) if !is_ghost_field => Err("a ghost may not write the field `${met.name}`, which is no ghost field")
				_ => Ok({})
			}
			match broken {
				Ok({}) => {}
				Err(why) => {
					return Err(KavaRules.fault_at(met, why))
				}
			}
		}
		Ok({})
	}

	## The name met at a token, when one was.
	use_at : KavaState.State, U64 -> Try(KavaState.Use, [NotFound])
	use_at = |reader, index| reader.uses.find_first(|met| met.index == index)

	handovers_held : KavaState.State -> Try({}, Lexer.Fault)
	handovers_held = |reader| {
		for met in reader.uses {
			if met.role == Handed {
				if reader.constants.contains(met.name) {
					return Err(
						KavaRules.fault_at(
							met,
							"`own` hands over a variable it can then poison, and `${met.name}` is a `const`",
						),
					)
				}
				KavaRules.unused_after(reader, met)?
				KavaRules.renewed_in_loop(reader, met)?
			}
		}
		Ok({})
	}

	## Nothing, or a fault at the first use of the handed-over name later in
	## its block, before a plain assignment in that block gives it a new value.
	unused_after : KavaState.State, KavaState.Use -> Try({}, Lexer.Fault)
	unused_after = |reader, handed| {
		var $at = handed.index + 1
		var $braces = 0
		var $open = True
		while $open {
			kind = KavaState.token_at(reader, $at).kind
			match kind {
				End => {
					$open = False
				}
				Punct("{") => {
					$braces = $braces + 1
				}
				Punct("}") => if $braces == 0 {
					$open = False
				} else {
					$braces = $braces - 1
				}
				Name(word) if word == handed.name => {
					match KavaRules.use_at(reader, $at) {
						Ok(met) => match met.role {
							Assigned if $braces == 0 => {
								$open = False
							}
							Read => {
								return Err(KavaRules.used_after(met, handed))
							}
							Updated => {
								return Err(KavaRules.used_after(met, handed))
							}
							Shorthand => {
								return Err(KavaRules.used_after(met, handed))
							}
							Handed => {
								return Err(KavaRules.used_after(met, handed))
							}
							_ => {}
						}
						Err(NotFound) => {}
					}
				}
				_ => {}
			}
			$at = $at + 1
		}
		Ok({})
	}

	used_after : KavaState.Use, KavaState.Use -> Lexer.Fault
	used_after = |met, handed| KavaRules.fault_at(
		met,
		"`${met.name}` is used after it was handed over at line ${handed.line.to_str()}",
	)

	## Nothing, or a fault when the name is handed over inside a loop that
	## neither declares it nor gives it a new value after the hand-over.
	renewed_in_loop : KavaState.State, KavaState.Use -> Try({}, Lexer.Fault)
	renewed_in_loop = |reader, handed| {
		at = handed.index
		around = reader.loops.keep_if(|loop| loop.first < at and at < loop.past)
		innermost = around.sort_with(
			|left, right| if left.first > right.first {
				Before
			} else if left.first < right.first {
				After
			} else {
				Same
			},
		).first()
		match innermost {
			Ok(loop) => {
				in_function = reader.bodies.any(|body| body.first > loop.first and body.first <= at and at < body.past)
				declared = reader.uses.any(|met| met.role == Bound and met.name == handed.name and met.index > loop.first and met.index < loop.past)
				renewed = reader.uses.any(|met| met.role == Assigned and met.name == handed.name and met.index > at and met.index < loop.past)
				if in_function or declared or renewed {
					Ok({})
				} else {
					line = KavaState.token_at(reader, loop.first).line
					Err(
						KavaRules.fault_at(
							handed,
							"`${handed.name}` is handed over on every pass of the loop at line ${line.to_str()}, and nothing in it gives `${handed.name}` a new value",
						),
					)
				}
			}
			Err(ListWasEmpty) => Ok({})
		}
	}

	## A checked build's reads of each handed-over name, each through
	## `$kava_live`.
	live_reads : KavaState.State -> List(Edits.Edit)
	live_reads = |reader| {
		handed = reader.uses.keep_if(|met| met.role == Handed).map(|met| met.name)
		var $edits = []
		for met in reader.uses {
			if handed.contains(met.name) and met.code != Clausal {
				here = KavaState.token_at(reader, met.index)
				match met.role {
					Read => {
						$edits = $edits.append(
							Edits.replacement(here.start, here.end, "$kava_live(${met.name})"),
						)
					}
					Shorthand => {
						$edits = $edits.append(
							Edits.replacement(
								here.start,
								here.end,
								"${met.name}: $kava_live(${met.name})",
							),
						)
					}
					_ => {}
				}
			}
		}
		$edits
	}
}
