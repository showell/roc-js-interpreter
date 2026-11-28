## This module holds what every part of KavaScript's reader shares: the
## reader's state (`State`: where it is in the tokens, the edits each output
## mode makes, and the facts the static rules judge), the names it meets and
## the part of the program each stands in (`Use`), and the small readings
## over tokens: the token here, a fault here, a span's text on one line.
##
## **THE READER WRITES TWO LISTS OF EDITS AS IT GOES,** one a mode: `strip`
## takes every addition out, and `checked` writes the checks in. Each is
## applied to the program's own text (Edits), so the bytes no addition
## touches are copied as they were.
import js.Lexer
import Edits
import KavaTokens

KavaState :: [].{

	## Which code a name stands in: ordinary code, a ghost's code, or a
	## clause (a contract, an invariant, a cost), which may read ghosts and
	## whose text moves in a checked build.
	Code : [Ordinary, Ghostly, Clausal]

	## What the code does with a name where it stands.
	Role : [
		Read,
		# `a = ...`
		Assigned,
		# `a += ...`, `a++`, `--a`
		Updated,
		Bound,
		# `x.a`, read
		Field,
		# `x.a = ...`, `x.a += ...`
		FieldWritten,
		# `{ a }`, which reads `a`
		Shorthand,
		# `own a`, handed over
		Handed,
	]

	Use : {
		name : Str,
		index : U64,
		line : U64,
		column : U64,
		role : KavaState.Role,
		code : KavaState.Code,
	}

	## A span of tokens, by index: a loop from its keyword past its body,
	## or a function's body.
	Stretch : { first : U64, past : U64 }

	## A `return` of the function being read: its keyword's bytes, the end
	## of its value (the keyword's end for none), where the statement ends
	## (past its `;`, when it has one) and the token after it.
	ReturnSite : {
		keyword_start : U64,
		keyword_end : U64,
		returned : [Valued, Bare],
		ending : [Semicolon(U64), NoSemicolon(U64)],
		next_token : U64,
	}

	State : {
		src : List(U8),
		tokens : List(KavaTokens.Spanned),
		at : U64,
		file : Str,
		code : KavaState.Code,
		strip_edits : List(Edits.Edit),
		checked_edits : List(Edits.Edit),
		uses : List(KavaState.Use),
		constants : List(Str),
		# The names `ghost let` and `ghost const` bind.
		ghost_names : List(Str),
		ghost_fields : List(Str),
		loops : List(KavaState.Stretch),
		bodies : List(KavaState.Stretch),
		# The returns of each function being read, innermost last.
		frames : List(List(KavaState.ReturnSite)),
		olds : U64,
		# Each `cost` clause and `law`, as written.
		carried : List({ text : Str, line : U64 }),
		# What counted mode counts (KavaCost): each loop of ordinary code, by
		# its body, and each call, spread and string growth it charges.
		loop_bodies : List(KavaState.LoopBody),
		sites : List(KavaState.Site),
		# Each function's `cost` claim, with where its body opens and closes,
		# and the line of each loop's, which isn't checked yet.
		cost_claims : List(KavaState.Costed),
		loop_claims : List(U64),
		# The `size name(n) { ... }` generators, by the function each sizes.
		sizes : List(Str),
	}

	## A loop's body, by its tokens, and the line of the loop's keyword.
	LoopBody : {
		line : U64,
		first : U64,
		past : U64,
	}

	## A place counted mode charges, by its token: a call of a method the cost
	## table names, a `...` spread, or a string grown by name, `s += e` as a
	## statement (`Grown`) or `s = s + e` (`GrownBy`, at the second `s`).
	Site : {
		index : U64,
		kind : [
			Called(Str),
			Spread,
			Grown(Str),
			GrownBy(Str),
		],
	}

	## A cost clause, `cost O(claim) where name = code, ...`, and its line.
	Claim : {
		claim : Str,
		wheres : List({ name : Str, code : Str }),
		line : U64,
	}

	## A function's cost claim: its name ("" for none), and the bytes just
	## inside its body's `{` and at its `}`; an arrow whose body is an
	## expression has none (`Unframed`).
	Costed : {
		name : Str,
		claim : KavaState.Claim,
		body : [Framed({ open : U64, close : U64 }), Unframed],
	}

	## A program to read: its bytes, its tokens, and the file it came from,
	## as its messages name it.
	Source : {
		src : List(U8),
		tokens : List(KavaTokens.Spanned),
		file : Str,
	}

	start_of : KavaState.Source -> KavaState.State
	start_of = |source| {
		src: source.src,
		tokens: source.tokens,
		at: 0,
		file: source.file,
		code: Ordinary,
		strip_edits: [],
		checked_edits: [],
		uses: [],
		constants: [],
		ghost_names: [],
		ghost_fields: [],
		loops: [],
		bodies: [],
		frames: [],
		olds: 0,
		carried: [],
		loop_bodies: [],
		sites: [],
		cost_claims: [],
		loop_claims: [],
		sizes: [],
	}

	# ---- tokens ----------------------------------------------------------------

	token_at : KavaState.State, U64 -> KavaTokens.Spanned
	token_at = |reader, index| match reader.tokens.get(index) {
		Ok(found) => found
		Err(OutOfBounds) => {
			why = "KavaState.token_at: the tokens end with an end token"
			reader.tokens.last() ?? crash why
		}
	}

	token : KavaState.State -> KavaTokens.Spanned
	token = |reader| KavaState.token_at(reader, reader.at)

	next_token : KavaState.State -> KavaTokens.Spanned
	next_token = |reader| KavaState.token_at(reader, reader.at + 1)

	## The token before the reader's place, or the first token at the start.
	previous_token : KavaState.State -> KavaTokens.Spanned
	previous_token = |reader| KavaState.token_at(reader, reader.at.minus_saturated(1))

	advance : KavaState.State -> KavaState.State
	advance = |reader|
		if KavaState.token(reader).kind == End {
			reader
		} else {
			{ ..reader, at: reader.at + 1 }
		}

	is_punct : KavaState.State, Str -> Bool
	is_punct = |reader, text| KavaState.token(reader).kind == Punct(text)

	is_word : KavaState.State, Str -> Bool
	is_word = |reader, text| KavaState.token(reader).kind == Name(text)

	is_closer : Lexer.TokenKind -> Bool
	is_closer = |kind| match kind {
		Punct(")") => True
		Punct("]") => True
		Punct("}") => True
		End => True
		TemplateMiddle(_) => True
		TemplateTail(_) => True
		_ => False
	}

	## Whether the next token stands on the same line as the reader's.
	is_next_on_line : KavaState.State -> Bool
	is_next_on_line = |reader| {
		next = KavaState.next_token(reader)
		next.before == SameLine and next.kind != End
	}

	fault_here : KavaState.State, Str -> Lexer.Fault
	fault_here = |reader, why| {
		current = KavaState.token(reader)
		{
			why: why,
			line: current.line,
			column: current.column,
		}
	}

	expect_punct : KavaState.State, Str -> Try(KavaState.State, Lexer.Fault)
	expect_punct = |reader, text|
		if KavaState.is_punct(reader, text) {
			Ok(KavaState.advance(reader))
		} else {
			Err(
				KavaState.fault_here(
					reader,
					"expected `${text}`, found ${KavaState.spelling(reader, reader.at)}",
				),
			)
		}

	## A token as a message names it.
	spelling : KavaState.State, U64 -> Str
	spelling = |reader, index| match KavaState.token_at(reader, index).kind {
		End => "the end of the program"
		_ => "`${KavaState.one_line(reader, { first: index, past: index + 1 })}`"
	}

	## The index past the bracket that closes the one at `index`.
	past_closing : KavaState.State, U64 -> U64
	past_closing = |reader, index| {
		var $depth = 0
		var $at = index
		var $done = False
		while !$done {
			kind = KavaState.token_at(reader, $at).kind
			$depth = match kind {
				Punct("(") => $depth + 1
				Punct("[") => $depth + 1
				Punct("{") => $depth + 1
				TemplateHead(_) => $depth + 1
				Punct(")") => $depth.minus_saturated(1)
				Punct("]") => $depth.minus_saturated(1)
				Punct("}") => $depth.minus_saturated(1)
				TemplateTail(_) => $depth.minus_saturated(1)
				_ => $depth
			}
			$at = $at + 1
			if $depth == 0 or kind == End {
				$done = True
			}
		}
		$at
	}

	# ---- text ------------------------------------------------------------------

	## The tokens `first` up to `past` as one line: each token's own text, a
	## space between two that had space or a line between them.
	one_line : KavaState.State, KavaState.Stretch -> Str
	one_line = |reader, stretch| {
		first = stretch.first
		past = stretch.past
		var $out = []
		var $at = first
		while $at < past {
			here = KavaState.token_at(reader, $at)
			if $at > first and here.start > KavaState.token_at(reader, $at - 1).end {
				$out = $out.append(' ')
			}
			$out = List.concat(
				$out,
				reader.src.sublist({ start: here.start, len: here.end - here.start }),
			)
			$at = $at + 1
		}
		Str.from_utf8($out) ?? crash "KavaState.one_line: tokens hold whole characters"
	}

	# ---- recording -------------------------------------------------------------

	## The reader with edits for each mode. Inside a ghost, strip mode's edits
	## are left out, since the ghost's own deletion covers them; inside a
	## clause both are, since a clause's text is deleted and written again
	## whole.
	with_edits : KavaState.State,
	{
		strip_edits : List(Edits.Edit),
		checked_edits : List(Edits.Edit),
	} -> KavaState.State
	with_edits = |reader, edits| match reader.code {
		Ordinary => {
			..reader,
			strip_edits: List.concat(reader.strip_edits, edits.strip_edits),
			checked_edits: List.concat(reader.checked_edits, edits.checked_edits),
		}
		Ghostly => {
			..reader,
			checked_edits: List.concat(reader.checked_edits, edits.checked_edits),
		}
		Clausal => reader
	}

	## The reader with the tokens `first` up to `past` deleted in both modes,
	## with the spaces before them.
	deleted_in_both : KavaState.State, KavaState.Stretch -> KavaState.State
	deleted_in_both = |reader, stretch| {
		start = KavaState.token_at(reader, stretch.first).start
		end = KavaState.token_at(reader, stretch.past - 1).end
		cut = Edits.deletion(
			reader.src,
			{
				start: start,
				end: end,
				side: SpacesBefore,
			},
		)
		KavaState.with_edits(reader, { strip_edits: [cut], checked_edits: [cut] })
	}

	## The reader having met the name at a token, doing `role` with it.
	with_use : KavaState.State,
	{
		index : U64,
		name : Str,
		role : KavaState.Role,
	} -> KavaState.State
	with_use = |reader, meeting| {
		here = KavaState.token_at(reader, meeting.index)
		met = {
			name: meeting.name,
			index: meeting.index,
			line: here.line,
			column: here.column,
			role: meeting.role,
			code: reader.code,
		}
		{ ..reader, uses: reader.uses.append(met) }
	}

	## The reader reading `code`'s code from `reader`'s and back.
	with_code : KavaState.State, KavaState.Code -> KavaState.State
	with_code = |reader, code| { ..reader, code: code }
}
