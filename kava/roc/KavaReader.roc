## This module reads a KavaScript program: JavaScript, as the subset writes
## it, with KavaScript's additions. It reads statements by recursive descent
## and expressions only as far as it must, by their brackets: what it needs
## of them is where they end, the functions written inside them, and every
## name each one meets (`KavaState.Use`). Everything else about the
## JavaScript is the subset's own parser's to judge, which Kava.roc runs on
## the program once its additions are taken out.
##
## Each addition stands where today's JavaScript has a syntax error, or
## where TypeScript writes a type, so no JavaScript program changes meaning:
##
## - **Contracts,** between a function's parameters (and its result's type)
##   and its body: `requires e`, `ensures e` (which reads `result` and
##   `old(x)`, `x` as it was at entry), and `cost O(...) [where n = e, ...]`.
## - **Loops:** `invariant e` and `cost O(...)` after a `while`'s or a
##   `for`'s head, its expression on the keyword's line and not starting
##   with `(`, `+` or `-` (or JavaScript would read a call or an operator).
## - **Classes:** `invariant e;` among the members, holding after the
##   constructor and every method that isn't static.
## - **Ghosts:** `ghost let x = e;`, `ghost <statement>`, `ghost { ... }`
##   and, in a class, `ghost f = e;`, the next token on the keyword's line.
## - **Types,** after a `:`: a parameter's, a result's (after the
##   parameters), and a `let`'s or a `const`'s (KavaTypes has their grammar).
## - **`own` and `lent`,** before a parameter, and before a call's argument
##   (`push(own a, 4)`, `total(lent xs)`).
## - **Laws:** `law name(...) { ... }`, carried whole.
##
## The reader writes the edits of both output modes as it reads (KavaState),
## and KavaChecks writes each function's checks once its body is read.
import js.Lexer
import Edits
import KavaChecks
import KavaState
import KavaTokens
import KavaTypes

KavaReader :: [].{
	Parsed(a) : { reader : KavaState.State, value : a }

	## Where an expression stops: at what its enclosing statement or bracket
	## ends with. Every stop is at a closing bracket, a `;` or the end.
	Stop : [
		AtStatementEnd,
		AtDeclaratorEnd,
		AtElementEnd,
		AtClose,
		AtColon,
		AtClauseEnd,
		AtWhereEnd,
	]

	## The whole program, read.
	program : List(U8), List(KavaTokens.Spanned), Str -> Try(KavaState.State, Lexer.Fault)
	program = |src, tokens, file| {
		var $reader = KavaState.started(src, tokens, file)
		while KavaState.token($reader).kind != End {
			if KavaState.is_punct($reader, "}") {
				return Err(KavaState.fault_here($reader, "a `}` that closes nothing"))
			}
			$reader = KavaReader.statement($reader)?
		}
		Ok($reader)
	}

	# ---- words -----------------------------------------------------------------

	keywords : List(Str)
	keywords = [
		"break",
		"case",
		"catch",
		"class",
		"const",
		"continue",
		"debugger",
		"default",
		"delete",
		"do",
		"else",
		"export",
		"extends",
		"false",
		"finally",
		"for",
		"function",
		"if",
		"import",
		"in",
		"instanceof",
		"let",
		"new",
		"null",
		"of",
		"return",
		"static",
		"super",
		"switch",
		"this",
		"throw",
		"true",
		"try",
		"typeof",
		"var",
		"void",
		"while",
		"with",
		"yield",
	]

	is_keyword : Str -> Bool
	is_keyword = |word| KavaReader.keywords.contains(word)

	is_clause_word : Lexer.TokenKind -> Bool
	is_clause_word = |kind| match kind {
		Name("requires") => True
		Name("ensures") => True
		Name("cost") => True
		_ => False
	}

	## Whether a token can start the expression after a loop's `invariant`,
	## or a stray clause's word, on its line: where JavaScript reads two
	## names, a name and a literal, or a name and `!` side by side as an
	## error.
	is_clause_start : Lexer.TokenKind -> Bool
	is_clause_start = |kind| match kind {
		Name(word) => !["in", "of", "instanceof"].contains(word)
		Number(_) => True
		Text(_) => True
		TemplateWhole(_) => True
		TemplateHead(_) => True
		Punct("!") => True
		Punct("~") => True
		_ => False
	}

	assignments : List(Str)
	assignments = [
		"+=",
		"-=",
		"*=",
		"/=",
		"%=",
		"**=",
		"<<=",
		">>=",
		">>>=",
		"&=",
		"|=",
		"^=",
		"&&=",
		"||=",
		"??=",
	]

	## Whether an expression goes on past a line break between `previous`
	## and `next`, where JavaScript inserts no `;`.
	is_continued : Lexer.TokenKind, Lexer.TokenKind -> Bool
	is_continued = |previous, next|
		match next {
			Punct("++") => False
			Punct("--") => False
			Punct("{") => False
			Punct("!") => False
			Punct("~") => False
			Punct(_) => True
			TemplateWhole(_) => True
			TemplateHead(_) => True
			_ => match previous {
				Punct(")") => False
				Punct("]") => False
				Punct("}") => False
				Punct("++") => False
				Punct("--") => False
				Punct(_) => True
				Name(word) => [
					"typeof",
					"new",
					"in",
					"of",
					"instanceof",
					"void",
					"delete",
				].contains(word)
				_ => False
			}
		}

	# ---- statements ------------------------------------------------------------

	statements : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	statements = |reader| {
		var $reader = reader
		while !KavaState.is_punct($reader, "}") and KavaState.token($reader).kind != End {
			$reader = KavaReader.statement($reader)?
		}
		Ok($reader)
	}

	block : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	block = |reader| {
		opened = KavaState.expect_punct(reader, "{")?
		inside = KavaReader.statements(opened)?
		KavaState.expect_punct(inside, "}")
	}

	statement : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	statement = |reader| {
		current = KavaState.token(reader)
		on_line = KavaState.is_next_on_line(reader)
		next_kind = KavaState.next_token(reader).kind
		match current.kind {
			Punct("{") => KavaReader.block(reader)
			Punct(";") => Ok(KavaState.advance(reader))
			Name("let") => KavaReader.declaration_statement(reader, Let)
			Name("const") => KavaReader.declaration_statement(reader, Const)
			Name("function") => KavaReader.function_rest(KavaState.advance(reader))
			Name("class") => KavaReader.class_rest(KavaState.advance(reader))
			Name("if") => {
				tested = KavaReader.parenthesized(KavaState.advance(reader))?
				yes = KavaReader.statement(tested)?
				if KavaState.is_word(yes, "else") {
					KavaReader.statement(KavaState.advance(yes))
				} else {
					Ok(yes)
				}
			}
			Name("while") => {
				tested = KavaReader.parenthesized(KavaState.advance(reader))?
				KavaReader.loop_rest(tested, reader.at)
			}
			Name("for") => KavaReader.loop_rest(
				KavaReader.for_head(KavaState.advance(reader))?,
				reader.at,
			)
			Name("do") => KavaReader.do_loop(reader)
			Name("return") => KavaReader.return_statement(reader)
			Name("try") => KavaReader.try_statement(reader)
			Name("switch") => KavaReader.switch_statement(reader)
			Name("throw") => {
				thrown = KavaReader.expression(KavaState.advance(reader), AtStatementEnd)?
				KavaReader.statement_end(thrown)
			}
			Name("break") => KavaReader.jump(reader)
			Name("continue") => KavaReader.jump(reader)
			Name("ghost") if on_line and KavaReader.is_ghost_start(next_kind) => KavaReader.ghost_statement(reader)
			Name("law") if on_line => KavaReader.law(reader)
			Name("requires") if on_line and KavaReader.is_clause_start(next_kind) => {
				Err(
					KavaState.fault_here(
						reader,
						"`requires` goes between a function's parameters and its body",
					),
				)
			}
			Name("ensures") if on_line and KavaReader.is_clause_start(next_kind) => {
				Err(
					KavaState.fault_here(
						reader,
						"`ensures` goes between a function's parameters and its body",
					),
				)
			}
			Name("invariant") if on_line and KavaReader.is_clause_start(next_kind) => {
				Err(
					KavaState.fault_here(
						reader,
						"`invariant` goes after a loop's head, or among a class's members",
					),
				)
			}
			Name("cost") if on_line and next_kind == Name("O") => {
				Err(
					KavaState.fault_here(
						reader,
						"`cost` goes after a function's parameters or a loop's head",
					),
				)
			}
			Name(word) if next_kind == Punct(":") and !KavaReader.is_keyword(word) => {
				KavaReader.statement(KavaState.advance(KavaState.advance(reader)))
			}
			_ => {
				done = KavaReader.expression(reader, AtStatementEnd)?
				KavaReader.statement_end(done)
			}
		}
	}

	## A statement's end: a `;`, or where JavaScript would insert one.
	statement_end : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	statement_end = |reader| {
		current = KavaState.token(reader)
		if KavaState.is_punct(reader, ";") {
			Ok(KavaState.advance(reader))
		} else if KavaState.is_closer(current.kind) or current.before == NewLine {
			Ok(reader)
		} else {
			Err(
				KavaState.fault_here(
					reader,
					"expected `;` or a line break, found ${KavaState.spelled(reader, reader.at)}",
				),
			)
		}
	}

	## The byte after a statement that ended before the reader's place, and
	## whether a `;` ended it.
	ended_at : KavaState.State -> [Semicolon(U64), NoSemicolon(U64)]
	ended_at = |reader| {
		last = KavaState.previous_token(reader)
		if last.kind == Punct(";") {
			Semicolon(last.end)
		} else {
			NoSemicolon(last.end)
		}
	}

	parenthesized : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	parenthesized = |reader| {
		opened = KavaState.expect_punct(reader, "(")?
		inside = KavaReader.expression(opened, AtClose)?
		KavaState.expect_punct(inside, ")")
	}

	jump : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	jump = |reader| {
		past = KavaState.advance(reader)
		labelled = match KavaState.token(past).kind {
			Name(_) if KavaState.token(past).before == SameLine => KavaState.advance(past)
			_ => past
		}
		KavaReader.statement_end(labelled)
	}

	try_statement : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	try_statement = |reader| {
		tried = KavaReader.block(KavaState.advance(reader))?
		caught = if KavaState.is_word(tried, "catch") {
			past = KavaState.advance(tried)
			bound = if KavaState.is_punct(past, "(") {
				named = KavaReader.binding(KavaState.advance(past))?
				KavaState.expect_punct(named, ")")?
			} else {
				past
			}
			KavaReader.block(bound)?
		} else {
			tried
		}
		if KavaState.is_word(caught, "finally") {
			KavaReader.block(KavaState.advance(caught))
		} else {
			Ok(caught)
		}
	}

	switch_statement : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	switch_statement = |reader| {
		tested = KavaReader.parenthesized(KavaState.advance(reader))?
		var $reader = KavaState.expect_punct(tested, "{")?
		while !KavaState.is_punct($reader, "}") and KavaState.token($reader).kind != End {
			$reader = if KavaState.is_word($reader, "case") {
				labelled = KavaReader.expression(KavaState.advance($reader), AtColon)?
				KavaState.expect_punct(labelled, ":")?
			} else if KavaState.is_word(
				$reader,
				"default",
			) and KavaState.next_token($reader).kind == Punct(":") {
				KavaState.advance(KavaState.advance($reader))
			} else {
				KavaReader.statement($reader)?
			}
		}
		KavaState.expect_punct($reader, "}")
	}

	## A `let` or `const` statement; a checked build checks each typed name
	## after it.
	declaration_statement : KavaState.State, [Let, Const] -> Try(KavaState.State, Lexer.Fault)
	declaration_statement = |reader, kind| {
		declared = KavaReader.declaration(reader, kind)?
		ended = KavaReader.statement_end(declared.reader)?
		checks = declared.value.map(
			|typed| KavaChecks.guard(
				ended.file,
				KavaTypes.check_of(typed.shape, typed.name, 1),
				"type ${typed.name}: ${typed.text}",
				typed.line,
			),
		)
		if checks.is_empty() {
			Ok(ended)
		} else {
			line = Str.join_with(checks, " ")
			inserted = match KavaReader.ended_at(ended) {
				Semicolon(at) => Edits.insertion(at, " ${line}")
				NoSemicolon(at) => Edits.insertion(at, "; ${line}")
			}
			Ok(KavaState.edited(ended, [], [inserted]))
		}
	}

	## A declaration's names, each typed one with its type (for a check).
	Declared : {
		name : Str,
		shape : KavaTypes.Shape,
		text : Str,
		line : U64,
	}

	declaration : KavaState.State,
	[Let, Const] -> Try(
		KavaReader.Parsed(List(KavaReader.Declared)),
		Lexer.Fault,
	)
	declaration = |reader, kind| {
		var $reader = KavaState.advance(reader)
		var $typed = []
		var $more = True
		while $more {
			first = KavaState.token($reader)
			name = match first.kind {
				Name(word) => Named(word)
				_ => Patterned
			}
			uses_before = $reader.uses.len()
			bound = KavaReader.binding($reader)?
			$reader = match kind {
				Const => {
					names = bound.uses.drop_first(uses_before).keep_if(|met| met.role == Bound).map(|met| met.name)
					{ ..bound, constants: List.concat(bound.constants, names) }
				}
				Let => bound
			}
			if KavaState.is_punct($reader, ":") {
				typed = KavaReader.annotation($reader)?
				$reader = typed.reader
				match name {
					Named(word) => {
						$typed = $typed.append({
							name: word,
							shape: typed.value.shape,
							text: typed.value.text,
							line: first.line,
						})
					}
					Patterned => {}
				}
			}
			if KavaState.is_punct($reader, "=") {
				$reader = KavaReader.expression(KavaState.advance($reader), AtDeclaratorEnd)?
			}
			if KavaState.is_punct($reader, ",") {
				$reader = KavaState.advance($reader)
			} else {
				$more = False
			}
		}
		Ok({ reader: $reader, value: $typed })
	}

	## A type after the `:` here, deleted in both modes: its shape and its
	## text as written.
	annotation : KavaState.State -> Try(
		KavaReader.Parsed({ shape : KavaTypes.Shape, text : Str }),
		Lexer.Fault,
	)
	annotation = |reader| {
		read = KavaTypes.shape_at(reader.tokens, reader.at + 1)?
		text = KavaState.rendered(reader, reader.at + 1, read.next)
		cut = KavaState.deleted_in_both(reader, reader.at, read.next, SpacesBefore)
		Ok({ reader: { ..cut, at: read.next }, value: { shape: read.shape, text: text } })
	}

	# ---- bindings --------------------------------------------------------------

	## A name or a pattern that binds names, each a `Bound` use.
	binding : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	binding = |reader| match KavaState.token(reader).kind {
		Name(word) if !KavaReader.is_keyword(word) => Ok(
			KavaState.advance(KavaState.used(reader, reader.at, word, Bound)),
		)
		Punct("[") => KavaReader.array_pattern(KavaState.advance(reader))
		Punct("{") => KavaReader.object_pattern(KavaState.advance(reader))
		_ => Err(
			KavaState.fault_here(
				reader,
				"expected a name or a pattern, found ${KavaState.spelled(reader, reader.at)}",
			),
		)
	}

	array_pattern : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	array_pattern = |reader| {
		var $reader = reader
		while !KavaState.is_punct($reader, "]") and KavaState.token($reader).kind != End {
			if KavaState.is_punct($reader, ",") {
				$reader = KavaState.advance($reader)
			} else {
				spread = if KavaState.is_punct($reader, "...") {
					KavaState.advance($reader)
				} else {
					$reader
				}
				$reader = KavaReader.defaulted(KavaReader.binding(spread)?)?
				$reader = KavaReader.listed($reader, "]")?
			}
		}
		KavaState.expect_punct($reader, "]")
	}

	object_pattern : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	object_pattern = |reader| {
		var $reader = reader
		while !KavaState.is_punct($reader, "}") and KavaState.token($reader).kind != End {
			$reader = if KavaState.is_punct($reader, "...") {
				KavaReader.binding(KavaState.advance($reader))?
			} else if KavaState.next_token($reader).kind == Punct(":") {
				KavaReader.binding(KavaState.advance(KavaState.advance($reader)))?
			} else if KavaState.is_punct($reader, "[") {
				keyed = KavaReader.bracketed($reader)?
				KavaReader.binding(KavaState.expect_punct(keyed, ":")?)?
			} else {
				KavaReader.binding($reader)?
			}
			$reader = KavaReader.defaulted($reader)?
			$reader = KavaReader.listed($reader, "}")?
		}
		KavaState.expect_punct($reader, "}")
	}

	## Past a binding's default, `= e`, when it has one.
	defaulted : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	defaulted = |reader|
		if KavaState.is_punct(reader, "=") {
			KavaReader.expression(KavaState.advance(reader), AtElementEnd)
		} else {
			Ok(reader)
		}

	## Past the `,` after an item of a list closed by `closer`; the list's
	## end leaves the reader there.
	listed : KavaState.State, Str -> Try(KavaState.State, Lexer.Fault)
	listed = |reader, closer|
		if KavaState.is_punct(reader, ",") {
			Ok(KavaState.advance(reader))
		} else if KavaState.is_punct(reader, closer) {
			Ok(reader)
		} else {
			Err(
				KavaState.fault_here(
					reader,
					"expected `,` or `${closer}`, found ${KavaState.spelled(reader, reader.at)}",
				),
			)
		}

	# ---- expressions -----------------------------------------------------------

	## Past an expression, as far as `stop` says it goes.
	expression : KavaState.State, KavaReader.Stop -> Try(KavaState.State, Lexer.Fault)
	expression = |reader, stop| {
		var $reader = reader
		var $first = reader.at
		while !KavaReader.is_stopped($reader, stop, $first) {
			$reader = KavaReader.term($reader, stop)?
		}
		Ok($reader)
	}

	is_stopped : KavaState.State, KavaReader.Stop, U64 -> Bool
	is_stopped = |reader, stop, first| {
		current = KavaState.token(reader)
		line_ends = reader.at > first and current.before == NewLine and !KavaReader.is_continued(
			KavaState.previous_token(reader).kind,
			current.kind,
		)
		comma = current.kind == Punct(",")
		clause_ends = KavaReader.is_clause_word(current.kind) or current.kind == Punct("{") or current.kind == Punct("=>")
		if KavaState.is_closer(current.kind) or current.kind == Punct(";") {
			True
		} else {
			match stop {
				AtStatementEnd => line_ends
				AtDeclaratorEnd => comma or line_ends
				AtElementEnd => comma
				AtClose => False
				AtColon => current.kind == Punct(":")
				AtClauseEnd => clause_ends
				AtWhereEnd => clause_ends or comma
			}
		}
	}

	## Past one piece of an expression: a token, or a bracket and all it
	## holds, or a function.
	term : KavaState.State, KavaReader.Stop -> Try(KavaState.State, Lexer.Fault)
	term = |reader, stop| {
		current = KavaState.token(reader)
		next = KavaState.next_token(reader)
		match current.kind {
			Punct("(") => KavaReader.parenthesis(reader, stop)
			Punct("[") => KavaReader.bracketed(reader)
			Punct("{") => KavaReader.object_literal(reader)
			TemplateHead(_) => KavaReader.template(reader)
			Name("function") => KavaReader.function_rest(KavaState.advance(reader))
			Name("class") => KavaReader.class_rest(KavaState.advance(reader))
			Name(word) if next.kind == Punct("=>") and !KavaReader.is_keyword(word) => {
				param = {
					name: Named(word),
					shape: Untyped,
					hold: Shared,
					line: current.line,
				}
				bound = KavaState.used(reader, reader.at, word, Bound)
				KavaReader.arrow_rest(
					{ ..bound, at: reader.at + 1 },
					[param],
					stop,
				)
			}
			Name("own") if KavaState.is_next_on_line(reader) and KavaReader.is_clause_start(next.kind) => {
				Err(
					KavaState.fault_here(
						reader,
						"`own` goes before a parameter or a call's argument",
					),
				)
			}
			Name("lent") if KavaState.is_next_on_line(reader) and KavaReader.is_clause_start(next.kind) => {
				Err(
					KavaState.fault_here(
						reader,
						"`lent` goes before a parameter or a call's argument",
					),
				)
			}
			Name(word) if KavaReader.is_keyword(word) => Ok(KavaState.advance(reader))
			Name(word) => Ok(KavaState.advance(KavaReader.name_met(reader, word)))
			_ => Ok(KavaState.advance(reader))
		}
	}

	## The reader having met the name here, its role read from the tokens on
	## either side.
	name_met : KavaState.State, Str -> KavaState.State
	name_met = |reader, word| {
		before = KavaState.previous_token(reader).kind
		after = KavaState.next_token(reader)
		is_field = reader.at > 0 and (before == Punct(".") or before == Punct("?."))
		is_postfix = after.before == SameLine and (after.kind == Punct("++") or after.kind == Punct("--"))
		is_compound = match after.kind {
			Punct(text) => KavaReader.assignments.contains(text)
			_ => False
		}
		is_prefixed = reader.at > 0 and (before == Punct("++") or before == Punct("--"))
		is_assigned = after.kind == Punct("=")
		role = if is_field and (is_assigned or is_compound or is_postfix) {
			FieldWritten
		} else if is_field {
			Field
		} else if is_assigned {
			Assigned
		} else if is_compound or is_postfix or is_prefixed {
			Updated
		} else {
			Read
		}
		KavaState.used(reader, reader.at, word, role)
	}

	## A `(`: an arrow function's parameters, a call's arguments, or a
	## parenthesized expression.
	parenthesis : KavaState.State, KavaReader.Stop -> Try(KavaState.State, Lexer.Fault)
	parenthesis = |reader, stop| {
		before = KavaState.previous_token(reader).kind
		is_callee = reader.at > 0 and match before {
			Name(word) => !KavaReader.is_keyword(word) or word == "this" or word == "super"
			Punct(")") => True
			Punct("]") => True
			TemplateWhole(_) => True
			TemplateTail(_) => True
			_ => False
		}
		if KavaReader.is_arrow(reader) {
			params = KavaReader.parameters(reader)?
			KavaReader.arrow_rest(params.reader, params.value, stop)
		} else if is_callee {
			KavaReader.arguments(reader)
		} else {
			KavaReader.parenthesized(reader)
		}
	}

	## Whether the `(` here opens an arrow function's parameters: its `)` is
	## followed by `=>`, by a contract, or by a type and then one of them.
	is_arrow : KavaState.State -> Bool
	is_arrow = |reader| {
		past = KavaState.past_closing(reader, reader.at)
		after = KavaState.token_at(reader, past).kind
		is_arrow_head = |kind| kind == Punct("=>") or KavaReader.is_clause_word(kind)
		if is_arrow_head(after) {
			True
		} else if after == Punct(":") {
			match KavaTypes.shape_at(reader.tokens, past + 1) {
				Ok(read) => is_arrow_head(KavaState.token_at(reader, read.next).kind)
				Err(_) => False
			}
		} else {
			False
		}
	}

	## A call's arguments, from its `(`; an argument may be handed over
	## (`own a`) or lent (`lent e`).
	arguments : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	arguments = |reader| {
		var $reader = KavaState.advance(reader)
		while !KavaState.is_punct($reader, ")") and KavaState.token($reader).kind != End {
			next = KavaState.next_token($reader)
			on_line = KavaState.is_next_on_line($reader)
			$reader = if KavaState.is_word(
				$reader,
				"own",
			) and on_line and KavaReader.is_clause_start(next.kind) {
				KavaReader.handover($reader)?
			} else if KavaState.is_word(
				$reader,
				"lent",
			) and on_line and KavaReader.is_clause_start(next.kind) {
				KavaReader.lending($reader)?
			} else if KavaState.is_punct($reader, "...") {
				KavaReader.expression(KavaState.advance($reader), AtElementEnd)?
			} else {
				KavaReader.expression($reader, AtElementEnd)?
			}
			$reader = KavaReader.listed($reader, ")")?
		}
		KavaState.expect_punct($reader, ")")
	}

	## `own a` among a call's arguments: strip mode deletes `own`; a checked
	## build hands `a`'s value over and leaves a poison in `a`, which throws
	## at any use (KavaChecks.helpers' `$kava_poison`).
	handover : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	handover = |reader| {
		keyword = KavaState.token(reader)
		named = KavaState.next_token(reader)
		after = KavaState.token_at(reader, reader.at + 2).kind
		name = match named.kind {
			Name(word) if after == Punct(",") or after == Punct(")") => Ok(word)
			_ => Err(
				KavaState.fault_here(reader, "`own` hands over a variable: write `own <name>`"),
			)
		}?
		if reader.code != Ordinary {
			return Err(KavaState.fault_here(reader, "a ghost or a clause can't hand a value over"))
		}
		said = KavaChecks.quoted("kava: own ${name}: ${name} was used after it was handed over (${reader.file}, line ${keyword.line.to_str()})")
		poisoned = Edits.replacement(
			keyword.start,
			named.end,
			"((v) => (${name} = $kava_poison(${said}), v))($kava_live(${name}))",
		)
		cut = Edits.deletion(reader.src, keyword.start, keyword.end, SpacesAfter)
		handed = KavaState.used(
			KavaState.edited(reader, [cut], [poisoned]),
			reader.at + 1,
			name,
			Handed,
		)
		Ok({ ..handed, at: reader.at + 2 })
	}

	## `lent e` among a call's arguments: strip mode deletes `lent`; a
	## checked build passes a view of `e` that throws at any write.
	lending : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	lending = |reader| {
		keyword = KavaState.token(reader)
		first = reader.at + 1
		lent = KavaReader.expression(KavaState.advance(reader), AtElementEnd)?
		text = KavaState.rendered(lent, first, lent.at)
		said = KavaChecks.quoted("kava: lent ${text}: ${text} was written (${reader.file}, line ${keyword.line.to_str()})")
		opened = Edits.replacement(
			keyword.start,
			KavaState.token_at(reader, first).start,
			"$kava_lend(",
		)
		closed = Edits.insertion(KavaState.previous_token(lent).end, ", ${said})")
		cut = Edits.deletion(reader.src, keyword.start, keyword.end, SpacesAfter)
		Ok(KavaState.edited(lent, [cut], [opened, closed]))
	}

	bracketed : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	bracketed = |reader| {
		var $reader = KavaState.advance(reader)
		while !KavaState.is_punct($reader, "]") and KavaState.token($reader).kind != End {
			$reader = if KavaState.is_punct($reader, ",") {
				KavaState.advance($reader)
			} else if KavaState.is_punct($reader, "...") {
				KavaReader.expression(KavaState.advance($reader), AtElementEnd)?
			} else {
				KavaReader.listed(KavaReader.expression($reader, AtElementEnd)?, "]")?
			}
		}
		KavaState.expect_punct($reader, "]")
	}

	template : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	template = |reader| {
		var $reader = KavaState.advance(reader)
		var $open = True
		while $open {
			$reader = KavaReader.expression($reader, AtClose)?
			match KavaState.token($reader).kind {
				TemplateMiddle(_) => {
					$reader = KavaState.advance($reader)
				}
				TemplateTail(_) => {
					$reader = KavaState.advance($reader)
					$open = False
				}
				_ => {
					return Err(
						KavaState.fault_here(
							$reader,
							"a template's substitution that never closes",
						),
					)
				}
			}
		}
		Ok($reader)
	}

	## An object literal, from its `{`: its keys are no names read, a
	## shorthand `{ a }` reads `a`, and a method is a function.
	object_literal : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	object_literal = |reader| {
		var $reader = KavaState.advance(reader)
		while !KavaState.is_punct($reader, "}") and KavaState.token($reader).kind != End {
			current = KavaState.token($reader)
			after = KavaState.next_token($reader).kind
			$reader = if KavaState.is_punct($reader, "...") {
				KavaReader.expression(KavaState.advance($reader), AtElementEnd)?
			} else if after == Punct(":") {
				KavaReader.expression(KavaState.advance(KavaState.advance($reader)), AtElementEnd)?
			} else if after == Punct("(") {
				KavaReader.method(
					KavaState.advance($reader),
					{ contract_of: Plain, invariants: [] },
				)?
			} else if KavaState.is_punct($reader, "[") {
				keyed = KavaReader.bracketed($reader)?
				if KavaState.is_punct(keyed, "(") {
					KavaReader.method(keyed, { contract_of: Plain, invariants: [] })?
				} else {
					KavaReader.expression(KavaState.expect_punct(keyed, ":")?, AtElementEnd)?
				}
			} else {
				match current.kind {
					Name(word) => KavaReader.defaulted(
						KavaState.advance(KavaState.used($reader, $reader.at, word, Shorthand)),
					)?
					_ => {
						return Err(
							KavaState.fault_here(
								$reader,
								"expected a property, found ${KavaState.spelled($reader, $reader.at)}",
							),
						)
					}
				}
			}
			$reader = KavaReader.listed($reader, "}")?
		}
		KavaState.expect_punct($reader, "}")
	}

	# ---- functions -------------------------------------------------------------

	## What a function is, for its checks: a plain function, a class's
	## constructor, or a method its class's invariants hold after.
	Member : [Plain, Constructor, Method]

	Placing : { contract_of : KavaReader.Member, invariants : List(KavaChecks.Clause) }

	## A function after its `function` keyword: an optional name, then the
	## rest as every function has it.
	function_rest : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	function_rest = |reader| {
		named = match KavaState.token(reader).kind {
			Name(word) if !KavaReader.is_keyword(word) => KavaState.advance(
				KavaState.used(reader, reader.at, word, Bound),
			)
			_ => reader
		}
		KavaReader.method(named, { contract_of: Plain, invariants: [] })
	}

	## A function from its parameters' `(` to its body's `}`.
	method : KavaState.State, KavaReader.Placing -> Try(KavaState.State, Lexer.Fault)
	method = |reader, placing| {
		params = KavaReader.parameters(reader)?
		result = KavaReader.result_type(params.reader)?
		clauses = KavaReader.function_clauses(result.reader)?
		invariants = match placing.contract_of {
			Plain => []
			_ => placing.invariants
		}
		contract = KavaReader.contract_of(clauses.value, params.value, result.value, invariants)
		KavaReader.function_body(clauses.reader, contract)
	}

	## The rest of an arrow function, after its parameters: its result's
	## type and contract, `=>`, and its body.
	arrow_rest : KavaState.State,
	List(KavaChecks.Param),
	KavaReader.Stop -> Try(
		KavaState.State,
		Lexer.Fault,
	)
	arrow_rest = |reader, params, stop| {
		result = KavaReader.result_type(reader)?
		clauses = KavaReader.function_clauses(result.reader)?
		contract = KavaReader.contract_of(clauses.value, params, result.value, [])
		arrow = KavaState.expect_punct(clauses.reader, "=>")?
		if KavaState.is_punct(arrow, "{") {
			KavaReader.function_body(arrow, contract)
		} else {
			first = arrow.at
			framed = { ..arrow, frames: arrow.frames.append([]) }
			body = KavaReader.expression(framed, stop)?
			stretch = { first: first, past: body.at }
			start = KavaState.token_at(body, first).start
			end = KavaState.previous_token(body).end
			closed = {
				..body,
				frames: body.frames.drop_last(1),
				bodies: body.bodies.append(stretch),
			}
			entry = KavaChecks.entry_checks(closed.file, contract)
			exits = KavaChecks.exit_checks(closed.file, contract)
			if entry == "" and exits == "" {
				Ok(closed)
			} else {
				KavaReader.result_kept_apart(closed, stretch)?
				opened = Edits.insertion(start, "{ ${entry} const result = (")
				ended = Edits.insertion(end, "); ${exits} return result; }")
				Ok(KavaState.edited(closed, [], [opened, ended]))
			}
		}
	}

	## A function's parameters, from their `(`, each with its type and
	## whether it is handed over or lent.
	parameters : KavaState.State -> Try(KavaReader.Parsed(List(KavaChecks.Param)), Lexer.Fault)
	parameters = |reader| {
		var $reader = KavaState.expect_punct(reader, "(")?
		var $params = []
		while !KavaState.is_punct($reader, ")") and KavaState.token($reader).kind != End {
			first = KavaState.token($reader)
			is_hold_word = KavaState.is_word($reader, "own") or KavaState.is_word($reader, "lent")
			held_kind = KavaState.next_token($reader).kind
			is_held = is_hold_word and KavaState.is_next_on_line($reader) and (KavaReader.is_clause_start(held_kind) or held_kind == Punct("{") or held_kind == Punct("[") or held_kind == Punct("..."))
			hold = if !is_held {
				Shared
			} else if KavaState.is_word($reader, "own") {
				Owned
			} else {
				Lent
			}
			if is_held {
				cut = Edits.deletion($reader.src, first.start, first.end, SpacesAfter)
				$reader = KavaState.advance(KavaState.edited($reader, [cut], [cut]))
			}
			if KavaState.is_punct($reader, "...") {
				$reader = KavaState.advance($reader)
			}
			name = match KavaState.token($reader).kind {
				Name(word) => Named(word)
				_ => Patterned
			}
			if hold == Lent and name == Patterned {
				return Err(
					KavaState.fault_here(
						$reader,
						"`lent` goes before a parameter's name, not a pattern",
					),
				)
			}
			line = KavaState.token($reader).line
			$reader = KavaReader.binding($reader)?
			shape = if KavaState.is_punct($reader, ":") {
				typed = KavaReader.annotation($reader)?
				$reader = typed.reader
				Typed(typed.value.shape, typed.value.text)
			} else {
				Untyped
			}
			$reader = KavaReader.defaulted($reader)?
			$reader = KavaReader.listed($reader, ")")?
			$params = $params.append({
				name: name,
				shape: shape,
				hold: hold,
				line: line,
			})
		}
		Ok({ reader: KavaState.expect_punct($reader, ")")?, value: $params })
	}

	## A function's result's type, after its parameters, when it has one.
	result_type : KavaState.State -> Try(
		KavaReader.Parsed([Typed(KavaTypes.Shape, Str, U64), Untyped]),
		Lexer.Fault,
	)
	result_type = |reader|
		if KavaState.is_punct(reader, ":") {
			line = KavaState.token(reader).line
			typed = KavaReader.annotation(reader)?
			Ok({ reader: typed.reader, value: Typed(typed.value.shape, typed.value.text, line) })
		} else {
			Ok({ reader: reader, value: Untyped })
		}

	Clauses : {
		required : List(KavaChecks.Clause),
		ensured : List(KavaChecks.Clause),
		olds : List(KavaChecks.Old),
	}

	contract_of : KavaReader.Clauses,
	List(KavaChecks.Param),
	[
		Typed(KavaTypes.Shape, Str, U64),
		Untyped,
	],
	List(KavaChecks.Clause) -> KavaChecks.Contract
	contract_of = |clauses, params, result, invariants| {
		params: params,
		result: result,
		required: clauses.required,
		ensured: clauses.ensured,
		invariants: invariants,
		olds: clauses.olds,
	}

	## A function's contract: its `requires`, `ensures` and `cost` clauses,
	## each deleted from both modes' text.
	function_clauses : KavaState.State -> Try(KavaReader.Parsed(KavaReader.Clauses), Lexer.Fault)
	function_clauses = |reader| {
		var $reader = reader
		var $clauses = { required: [], ensured: [], olds: [] }
		while KavaReader.is_clause_word(KavaState.token($reader).kind) {
			if KavaState.is_word($reader, "cost") {
				$reader = KavaReader.cost_clause($reader)?
			} else {
				is_ensures = KavaState.is_word($reader, "ensures")
				read = KavaReader.clause($reader, AtClauseEnd)?
				$reader = KavaState.deleted_in_both(
					read.reader,
					$reader.at,
					read.reader.at,
					SpacesBefore,
				)
				$clauses = if is_ensures {
					{
						..$clauses,
						ensured: $clauses.ensured.append(read.value.clause),
						olds: List.concat($clauses.olds, read.value.olds),
					}
				} else {
					{ ..$clauses, required: $clauses.required.append(read.value.clause) }
				}
			}
		}
		Ok({ reader: $reader, value: $clauses })
	}

	## A clause's keyword and its expression: the clause as written, and as a
	## check runs it, each `old(x)` read from a local saved at entry. The
	## caller deletes it, with what else ends it.
	clause : KavaState.State,
	KavaReader.Stop -> Try(
		KavaReader.Parsed({ clause : KavaChecks.Clause, olds : List(KavaChecks.Old) }),
		Lexer.Fault,
	)
	clause = |reader, stop| {
		keyword = KavaState.token(reader)
		first = reader.at + 1
		code = reader.code
		read = KavaReader.expression(KavaState.in_code(KavaState.advance(reader), Clausal), stop)?
		if read.at == first {
			return Err(KavaState.fault_here(reader, "a clause with no expression"))
		}
		olds = KavaReader.olds_in(read, first, read.at)
		value = {
			clause: {
				text: KavaState.rendered(read, first, read.at),
				code: olds.code,
				line: keyword.line,
			},
			olds: olds.olds,
		}
		Ok({ reader: { ..read, code: code, olds: olds.count }, value: value })
	}

	## The tokens `first` up to `past` as a check runs them: each `old(x)`
	## the local that saves `x` at entry, numbered from the reader's count.
	olds_in : KavaState.State,
	U64,
	U64 -> {
		code : Str,
		olds : List(KavaChecks.Old),
		count : U64,
	}
	olds_in = |reader, first, past| {
		var $pieces = []
		var $olds = []
		var $count = reader.olds
		var $at = first
		var $last_end = KavaState.token_at(reader, first).start
		while $at < past {
			here = KavaState.token_at(reader, $at)
			space = if here.start > $last_end and $at > first {
				" "
			} else {
				""
			}
			is_old = here.kind == Name("old") and KavaState.token_at(reader, $at + 1).kind == Punct("(") and KavaState.token_at(reader, $at.minus_saturated(1)).kind != Punct(".")
			if is_old {
				closing = KavaState.past_closing(reader, $at + 1)
				$count = $count + 1
				local = "$kava_old_${$count.to_str()}"
				$olds = $olds.append({
					local: local,
					code: KavaState.rendered(reader, $at + 2, closing - 1),
				})
				$pieces = $pieces.append("${space}${local}")
				$last_end = KavaState.token_at(reader, closing - 1).end
				$at = closing
			} else {
				$pieces = $pieces.append("${space}${KavaState.rendered(reader, $at, $at + 1)}")
				$last_end = here.end
				$at = $at + 1
			}
		}
		{
			code: Str.join_with($pieces, ""),
			olds: $olds,
			count: $count,
		}
	}

	## `cost O(...) [where n = e, ...]`, read and carried, never checked
	## here: strip mode deletes it, and a checked build keeps it as a
	## comment.
	cost_clause : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	cost_clause = |reader| {
		if KavaState.next_token(reader).kind != Name("O") or KavaState.token_at(
			reader,
			reader.at + 2,
		).kind != Punct("(") {
			return Err(KavaState.fault_here(reader, "expected `O(...)` after `cost`"))
		}
		var $reader = { ..reader, at: KavaState.past_closing(reader, reader.at + 2) }
		code = reader.code
		if KavaState.is_word($reader, "where") {
			$reader = KavaState.in_code(KavaState.advance($reader), Clausal)
			var $more = True
			while $more {
				$reader = match KavaState.token($reader).kind {
					Name(_) => KavaState.advance($reader)
					_ => {
						return Err(KavaState.fault_here($reader, "expected a name after `where`"))
					}
				}
				$reader = KavaReader.expression(KavaState.expect_punct($reader, "=")?, AtWhereEnd)?
				if KavaState.is_punct($reader, ",") {
					$reader = KavaState.advance($reader)
				} else {
					$more = False
				}
			}
			$reader = KavaState.in_code($reader, code)
		}
		KavaReader.carried($reader, reader.at, $reader.at, SpacesBefore)
	}

	## The reader having carried the addition `first` up to `past`: deleted
	## in strip mode, a comment in a checked build, and kept as written.
	carried : KavaState.State, U64, U64, Edits.Side -> Try(KavaState.State, Lexer.Fault)
	carried = |reader, first, past, side| {
		start = KavaState.token_at(reader, first).start
		end = KavaState.token_at(reader, past - 1).end
		text = Str.from_utf8(
			reader.src.sublist({ start: start, len: end - start }),
		) ?? crash "KavaReader.carried: tokens hold whole characters"
		if text.contains("*/") {
			return Err(
				KavaState.fault_here({ ..reader, at: first }, "a carried addition can't hold `*/`"),
			)
		}
		cut = Edits.deletion(reader.src, start, end, side)
		kept = {
			..reader,
			carried: reader.carried.append({
				text: text,
				line: KavaState.token_at(reader, first).line,
			}),
		}
		Ok(
			KavaState.edited(
				kept,
				[cut],
				[Edits.insertion(start, "/* "), Edits.insertion(end, " */")],
			),
		)
	}

	## A function's body, from its `{`, then its checks: those at its entry
	## after the `{`, and those at its ways out at each `return` and before
	## the `}`.
	function_body : KavaState.State, KavaChecks.Contract -> Try(KavaState.State, Lexer.Fault)
	function_body = |reader, contract| {
		opened = KavaState.expect_punct({ ..reader, frames: reader.frames.append([]) }, "{")?
		open = KavaState.previous_token(opened).end
		first = opened.at
		inside = KavaReader.statements(opened)?
		closing = KavaState.token(inside)
		closed = KavaState.expect_punct(inside, "}")?
		returns = closed.frames.last() ?? []
		stretch = { first: first, past: inside.at }
		framed = {
			..closed,
			frames: closed.frames.drop_last(1),
			bodies: closed.bodies.append(stretch),
		}
		entry = KavaChecks.entry_checks(framed.file, contract)
		exits = KavaChecks.exit_checks(framed.file, contract)
		entered = if entry == "" {
			[]
		} else {
			[Edits.insertion(open, " ${entry}")]
		}
		if exits == "" {
			Ok(KavaState.edited(framed, [], entered))
		} else {
			KavaReader.result_kept_apart(framed, stretch)?
			var $edits = entered
			for site in returns {
				value = match site.value {
					Valued => ""
					Bare => " undefined"
				}
				$edits = $edits.append(
					Edits.replacement(
						site.keyword_start,
						site.keyword_end,
						"{ const result =${value}",
					),
				)
				$edits = match site.ending {
					Semicolon(at) => $edits.append(
						Edits.insertion(at, " ${exits} return result; }"),
					)
					NoSemicolon(at) => $edits.append(
						Edits.insertion(at, "; ${exits} return result; }"),
					)
				}
			}
			ends_in_return = match returns.last() {
				Ok(site) => site.next_token == inside.at
				Err(ListWasEmpty) => False
			}
			if !ends_in_return {
				$edits = $edits.append(
					Edits.insertion(closing.start, "{ const result = undefined; ${exits} } "),
				)
			}
			Ok(KavaState.edited(framed, [], $edits))
		}
	}

	## Nothing, or a fault when ordinary code in a body whose ways out are
	## checked names `result`, which the checks name the value returned.
	result_kept_apart : KavaState.State, KavaState.Stretch -> Try({}, Lexer.Fault)
	result_kept_apart = |reader, stretch| {
		named = reader.uses.find_first(|met| met.name == "result" and met.code != Clausal and met.index >= stretch.first and met.index < stretch.past and met.role != Field and met.role != FieldWritten)
		match named {
			Ok(met) => Err({
				why: "`result` names the value an `ensures` or a result's type checks: rename this variable",
				line: met.line,
				column: met.column,
			})
			Err(NotFound) => Ok({})
		}
	}

	## A `return` and its value, recorded for the function it is in.
	return_statement : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	return_statement = |reader| {
		keyword = KavaState.token(reader)
		if reader.code != Ordinary {
			return Err(KavaState.fault_here(reader, "a ghost or a clause can't return"))
		}
		if reader.frames.is_empty() {
			return Err(KavaState.fault_here(reader, "a `return` outside a function"))
		}
		past = KavaState.advance(reader)
		after = KavaState.token(past)
		is_bare = KavaState.is_punct(
			past,
			";",
		) or KavaState.is_closer(after.kind) or after.before == NewLine
		valued = if is_bare {
			past
		} else {
			KavaReader.expression(past, AtStatementEnd)?
		}
		ended = KavaReader.statement_end(valued)?
		site = {
			keyword_start: keyword.start,
			keyword_end: keyword.end,
			value: if is_bare {
				Bare
			} else {
				Valued
			},
			ending: KavaReader.ended_at(ended),
			next_token: ended.at,
		}
		frames = ended.frames.drop_last(1).append((ended.frames.last() ?? []).append(site))
		Ok({ ..ended, frames: frames })
	}

	# ---- loops -----------------------------------------------------------------

	## A `for`'s head, from its `(`.
	for_head : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	for_head = |reader| {
		opened = KavaState.expect_punct(reader, "(")?
		started = if KavaState.is_word(opened, "let") {
			KavaReader.declaration(opened, Let)?.reader
		} else if KavaState.is_word(opened, "const") {
			KavaReader.declaration(opened, Const)?.reader
		} else if KavaState.is_punct(opened, ";") {
			opened
		} else {
			KavaReader.expression(opened, AtClose)?
		}
		if KavaState.is_word(started, "of") or KavaState.is_word(started, "in") {
			KavaState.expect_punct(KavaReader.expression(KavaState.advance(started), AtClose)?, ")")
		} else if KavaState.is_punct(started, ")") {
			Ok(KavaState.advance(started))
		} else {
			tested_from = KavaState.expect_punct(started, ";")?
			tested = KavaReader.expression(tested_from, AtClose)?
			updated_from = KavaState.expect_punct(tested, ";")?
			updated = KavaReader.expression(updated_from, AtClose)?
			KavaState.expect_punct(updated, ")")
		}
	}

	## A loop after its head: its invariants and its cost, then its body; a
	## checked build checks each invariant at the head of every pass.
	loop_rest : KavaState.State, U64 -> Try(KavaState.State, Lexer.Fault)
	loop_rest = |reader, first| {
		var $reader = reader
		var $invariants = []
		var $reading = True
		while $reading {
			on_line = KavaState.is_next_on_line($reader)
			next_kind = KavaState.next_token($reader).kind
			if KavaState.is_word(
				$reader,
				"invariant",
			) and on_line and KavaReader.is_clause_start(next_kind) {
				read = KavaReader.clause($reader, AtClauseEnd)?
				$reader = KavaState.deleted_in_both(
					read.reader,
					$reader.at,
					read.reader.at,
					SpacesBefore,
				)
				$invariants = $invariants.append(read.value.clause)
			} else if KavaState.is_word($reader, "cost") and on_line and next_kind == Name("O") {
				$reader = KavaReader.cost_clause($reader)?
			} else {
				$reading = False
			}
		}
		if !$invariants.is_empty() {
			if !KavaState.is_punct($reader, "{") {
				return Err(
					KavaState.fault_here(
						$reader,
						"a loop with an invariant takes a block as its body",
					),
				)
			}
			checks = $invariants.map(
				|each| KavaChecks.guard(
					$reader.file,
					each.code,
					"invariant ${each.text}",
					each.line,
				),
			)
			$reader = KavaState.edited(
				$reader,
				[],
				[Edits.insertion(KavaState.token($reader).end, " ${Str.join_with(checks, " ")}")],
			)
		}
		looped = KavaReader.statement($reader)?
		Ok({ ..looped, loops: looped.loops.append({ first: first, past: looped.at }) })
	}

	do_loop : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	do_loop = |reader| {
		body = KavaReader.statement(KavaState.advance(reader))?
		if !KavaState.is_word(body, "while") {
			return Err(KavaState.fault_here(body, "expected `while` after a `do` loop's body"))
		}
		tested = KavaReader.parenthesized(KavaState.advance(body))?
		ended = if KavaState.is_punct(tested, ";") {
			KavaState.advance(tested)
		} else {
			tested
		}
		Ok({ ..ended, loops: ended.loops.append({ first: reader.at, past: ended.at }) })
	}

	# ---- classes ---------------------------------------------------------------

	## A class after its `class` keyword: its name, its parent, then its
	## members, its invariants read first so each method's checks hold them.
	class_rest : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	class_rest = |reader| {
		named = match KavaState.token(reader).kind {
			Name(word) if !KavaReader.is_keyword(word) => KavaState.advance(
				KavaState.used(reader, reader.at, word, Bound),
			)
			_ => reader
		}
		var $reader = named
		if KavaState.is_word($reader, "extends") {
			$reader = KavaState.advance($reader)
			while !KavaState.is_punct($reader, "{") and KavaState.token($reader).kind != End {
				$reader = KavaReader.term($reader, AtClose)?
			}
		}
		opened = KavaState.expect_punct($reader, "{")?
		invariants = KavaReader.class_invariants(opened)?
		$reader = invariants.reader
		while !KavaState.is_punct($reader, "}") and KavaState.token($reader).kind != End {
			at = $reader.at
			skipped = invariants.value.find_first(|each| each.first == at)
			$reader = match skipped {
				Ok(each) => { ..$reader, at: each.past }
				Err(NotFound) => KavaReader.member(
					$reader,
					invariants.value.map(|each| each.clause),
				)?
			}
		}
		KavaState.expect_punct($reader, "}")
	}

	## A class's invariants, read ahead of its members from the token after
	## its `{`, each with the span its members' reading skips: a member that
	## starts with `invariant` and, on its line, no `(`, `=`, `;` or `}`.
	class_invariants : KavaState.State -> Try(
		KavaReader.Parsed(
			List(
				{
					clause : KavaChecks.Clause,
					first : U64,
					past : U64,
				},
			),
		),
		Lexer.Fault,
	)
	class_invariants = |reader| {
		var $reader = reader
		var $found = []
		var $at = reader.at
		var $depth = 0
		var $starts_member = True
		while $depth > 0 or (
			KavaState.token_at(
				reader,
				$at,
			).kind != Punct("}") and KavaState.token_at(reader, $at).kind != End
		) {
			here = KavaState.token_at(reader, $at)
			next = KavaState.token_at(reader, $at + 1)
			is_invariant = $depth == 0 and $starts_member and here.kind == Name("invariant") and next.before == SameLine and !(next.kind == Punct("(") or next.kind == Punct("=") or next.kind == Punct(";") or next.kind == Punct("}"))
			if is_invariant {
				read = KavaReader.clause({ ..$reader, at: $at }, AtStatementEnd)?
				past = if KavaState.is_punct(read.reader, ";") {
					read.reader.at + 1
				} else {
					read.reader.at
				}
				cut = KavaState.deleted_in_both(read.reader, $at, past, SpacesBefore)
				$reader = { ..cut, at: reader.at }
				$found = $found.append({
					clause: read.value.clause,
					first: $at,
					past: past,
				})
				$at = past
				$starts_member = True
			} else {
				$depth = match here.kind {
					Punct("{") => $depth + 1
					Punct("(") => $depth + 1
					Punct("[") => $depth + 1
					TemplateHead(_) => $depth + 1
					Punct("}") => $depth.minus_saturated(1)
					Punct(")") => $depth.minus_saturated(1)
					Punct("]") => $depth.minus_saturated(1)
					TemplateTail(_) => $depth.minus_saturated(1)
					_ => $depth
				}
				$starts_member = $depth == 0 and (here.kind == Punct("}") or here.kind == Punct(";"))
				$at = $at + 1
			}
		}
		Ok({ reader: $reader, value: $found })
	}

	## One member of a class: a method, a constructor, a ghost field, or a
	## field (which the subset refuses, and its parser says so).
	member : KavaState.State, List(KavaChecks.Clause) -> Try(KavaState.State, Lexer.Fault)
	member = |reader, invariants| {
		if KavaState.is_punct(reader, ";") {
			return Ok(KavaState.advance(reader))
		}
		if KavaState.is_word(reader, "ghost") and KavaState.is_next_on_line(reader) and KavaState.next_token(reader).kind != Punct("(") and KavaState.next_token(reader).kind != Punct("=") {
			return KavaReader.ghost_field(reader)
		}
		is_static = KavaState.is_word(
			reader,
			"static",
		) and KavaState.next_token(reader).kind != Punct("(")
		keyed = if is_static {
			KavaState.advance(reader)
		} else {
			reader
		}
		is_accessor = (
			KavaState.is_word(
				keyed,
				"get",
			) or KavaState.is_word(keyed, "set")
		) and KavaState.next_token(keyed).kind != Punct("(")
		key = if is_accessor {
			KavaState.advance(keyed)
		} else {
			keyed
		}
		named = if KavaState.is_punct(key, "[") {
			KavaReader.bracketed(key)?
		} else {
			KavaState.advance(key)
		}
		if KavaState.is_punct(named, "(") {
			placing = if is_static {
				Plain
			} else if KavaState.is_word(key, "constructor") {
				Constructor
			} else {
				Method
			}
			KavaReader.method(named, { contract_of: placing, invariants: invariants })
		} else {
			typed = if KavaState.is_punct(named, ":") {
				KavaReader.annotation(named)?.reader
			} else {
				named
			}
			valued = if KavaState.is_punct(typed, "=") {
				KavaReader.expression(KavaState.advance(typed), AtStatementEnd)?
			} else {
				typed
			}
			KavaReader.statement_end(valued)
		}
	}

	# ---- ghosts and laws -------------------------------------------------------

	## Whether a `ghost` followed on its line by this token starts a ghost.
	is_ghost_start : Lexer.TokenKind -> Bool
	is_ghost_start = |kind| match kind {
		Name(word) => !["in", "of", "instanceof"].contains(word)
		Punct("{") => True
		_ => False
	}

	## `ghost let x = e;`, `ghost { ... }` or `ghost <statement>`: strip mode
	## deletes it whole, and a checked build deletes `ghost` alone.
	ghost_statement : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	ghost_statement = |reader| {
		keyword = KavaState.token(reader)
		code = reader.code
		inside = KavaState.in_code(KavaState.advance(reader), Ghostly)
		uses_before = inside.uses.len()
		ended = if KavaState.is_word(inside, "let") {
			KavaReader.declaration_statement(inside, Let)?
		} else if KavaState.is_word(inside, "const") {
			KavaReader.declaration_statement(inside, Const)?
		} else {
			KavaReader.statement(inside)?
		}
		named = if KavaState.is_word(inside, "let") or KavaState.is_word(inside, "const") {
			bound = ended.uses.drop_first(uses_before).keep_if(|met| met.role == Bound).map(|met| met.name)
			{ ..ended, ghost_names: List.concat(ended.ghost_names, bound) }
		} else {
			ended
		}
		KavaReader.ghost_deleted(KavaState.in_code(named, code), keyword)
	}

	## The reader with the ghost from `keyword` to the reader's place deleted
	## whole in strip mode, and its `ghost` alone in a checked build.
	ghost_deleted : KavaState.State, KavaTokens.Spanned -> Try(KavaState.State, Lexer.Fault)
	ghost_deleted = |reader, keyword| {
		whole = Edits.deletion(
			reader.src,
			keyword.start,
			KavaState.previous_token(reader).end,
			SpacesAfter,
		)
		word = Edits.deletion(reader.src, keyword.start, keyword.end, SpacesAfter)
		Ok(KavaState.edited(reader, [whole], [word]))
	}

	## A class's `ghost f = e;`: a field only checks read.
	ghost_field : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	ghost_field = |reader| {
		keyword = KavaState.token(reader)
		code = reader.code
		named = KavaState.advance(KavaState.in_code(reader, Ghostly))
		field = match KavaState.token(named).kind {
			Name(word) => Ok(word)
			_ => Err(KavaState.fault_here(named, "expected a ghost field's name"))
		}?
		past_name = KavaState.advance({ ..named, ghost_fields: named.ghost_fields.append(field) })
		typed = if KavaState.is_punct(past_name, ":") {
			KavaReader.annotation(past_name)?.reader
		} else {
			past_name
		}
		valued = if KavaState.is_punct(typed, "=") {
			KavaReader.expression(KavaState.advance(typed), AtStatementEnd)?
		} else {
			typed
		}
		ended = KavaReader.statement_end(valued)?
		KavaReader.ghost_deleted(KavaState.in_code(ended, code), keyword)
	}

	## `law name(...) { ... }`, carried whole: no part of it is read.
	law : KavaState.State -> Try(KavaState.State, Lexer.Fault)
	law = |reader| {
		named = KavaState.advance(reader)
		match KavaState.token(named).kind {
			Name(_) => {}
			_ => {
				return Err(KavaState.fault_here(named, "expected a law's name"))
			}
		}
		if KavaState.next_token(named).kind != Punct("(") {
			return Err(KavaState.fault_here(named, "expected `(` after a law's name"))
		}
		past_params = KavaState.past_closing(named, named.at + 1)
		if KavaState.token_at(named, past_params).kind != Punct("{") {
			return Err(KavaState.fault_here({ ..named, at: past_params }, "expected a law's body"))
		}
		past = KavaState.past_closing(named, past_params)
		KavaReader.carried(
			{ ..named, at: past },
			reader.at,
			past,
			SpacesAfter,
		)
	}
}
