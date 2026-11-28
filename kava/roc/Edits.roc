## This module holds the changes KavaScript makes to a program's text, each
## a span of bytes replaced by a text (`Edit`), and applies them. Every byte
## no edit covers is copied as it was written, so a program with no
## additions comes out byte for byte the same.
##
## **A LINE BREAK IS NEVER REMOVED.** An edit's span may cross lines (a
## `law`, a ghost block), and the line breaks inside it are written after
## its text, so every line of the output is the line of the program it came
## from, and node's own messages point at the program's lines. Inserted text
## is written on one line for the same reason.
##
## A deletion takes the spaces beside it as well (`deletion`), so `f(a)
## requires a > 0 {` becomes `f(a) {`, not `f(a)  {`, and an addition on a
## line of its own leaves the line empty.
Edits :: [].{
	Edit : {
		start : U64,
		end : U64,
		text : Str,
	}

	## Which spaces a deletion takes: those before it (`x: T` loses ` : T`'s
	## space before), those after it (`own a` loses `own `), or, for a
	## statement, those after it unless it is alone on its line.
	Side : [SpacesBefore, SpacesAfter]

	insertion : U64, Str -> Edits.Edit
	insertion = |at, text| {
		start: at,
		end: at,
		text: text,
	}

	## The span `start` to `end` replaced by `text`, which takes no spaces.
	replacement : U64, U64, Str -> Edits.Edit
	replacement = |start, end, text| {
		start: start,
		end: end,
		text: text,
	}

	## The deletion of `start` to `end`, with the spaces on `side`; the whole
	## line's spaces when nothing else stands on the line.
	deletion : List(U8), U64, U64, Edits.Side -> Edits.Edit
	deletion = |src, start, end, side| {
		var $before = start
		while $before > 0 and Edits.is_space(src.get($before - 1) ?? 0) {
			$before = $before - 1
		}
		var $after = end
		while Edits.is_space(src.get($after) ?? 0) {
			$after = $after + 1
		}
		starts_line = $before == 0 or src.get($before - 1) == Ok('\n')
		ends_line = $after >= src.len() or src.get($after) == Ok('\n')
		if starts_line and ends_line {
			{
				start: $before,
				end: $after,
				text: "",
			}
		} else {
			match side {
				SpacesBefore => {
					start: $before,
					end: end,
					text: "",
				}
				SpacesAfter => {
					start: start,
					end: $after,
					text: "",
				}
			}
		}
	}

	is_space : U8 -> Bool
	is_space = |byte| byte == ' ' or byte == '\t' or byte == '\r'

	## The text with every edit made, the edits taken in the order of their
	## starts and, at one start, in the order given. Two edits that overlap
	## are a fault of KavaScript's own, named by the place of the second.
	applied : List(U8), List(Edits.Edit) -> Try(Str, [Overlapping(U64)])
	applied = |src, edits| {
		var $numbered = []
		var $count = 0
		for each in edits {
			$numbered = $numbered.append({ edit: each, order: $count })
			$count = $count + 1
		}
		ordered = $numbered.sort_with(
			|left, right| if left.edit.start < right.edit.start {
				Before
			} else if left.edit.start > right.edit.start {
				After
			} else if left.order < right.order {
				Before
			} else if left.order > right.order {
				After
			} else {
				Same
			},
		)
		var $out = []
		var $at = 0
		for each in ordered {
			change = each.edit
			if change.start < $at {
				return Err(Overlapping(change.start))
			}
			$out = List.concat($out, src.sublist({ start: $at, len: change.start - $at }))
			$out = List.concat($out, change.text.to_utf8())
			removed = src.sublist({ start: change.start, len: change.end - change.start })
			$out = List.concat($out, removed.keep_if(|byte| byte == '\n'))
			$at = change.end
		}
		$out = List.concat($out, src.sublist({ start: $at, len: src.len() - $at }))
		Ok(Str.from_utf8($out) ?? crash "Edits.applied: edits cut only between characters")
	}

	expect {
		src = "function f(a) requires a > 0 {\n".to_utf8()
		cut = Edits.deletion(src, 14, 28, SpacesBefore)
		Edits.applied(src, [cut]) == Ok("function f(a) {\n")
	}

	expect {
		src = "  ghost total += 1;\nx\n".to_utf8()
		cut = Edits.deletion(src, 2, 19, SpacesAfter)
		Edits.applied(src, [cut]) == Ok("\nx\n")
	}

	expect {
		src = "f(own a)".to_utf8()
		cut = Edits.deletion(src, 2, 5, SpacesAfter)
		Edits.applied(src, [cut]) == Ok("f(a)")
	}

	expect {
		src = "law l() {\n  a\n}\nb".to_utf8()
		cut = Edits.deletion(src, 0, 15, SpacesAfter)
		Edits.applied(src, [cut]) == Ok("\n\n\nb")
	}

	expect {
		src = "ab".to_utf8()
		Edits.applied(
			src,
			[
				Edits.insertion(1, "y"),
				Edits.insertion(1, "z"),
				Edits.insertion(0, "x"),
			],
		) == Ok("xayzb")
	}
}
