## This module holds what every part of the JavaScript parser shares: the
## parser's state (`State`, where it is in the tokens, the statements and
## the class around it), a parse's value (`Parsed`), the class records that
## state holds (`ClassInfo`, `Receiver`, `Parent`, `ClassCode`), the labels
## around the parser's place, the tokens read and their faults (`token`,
## `fault_here`, `fault_at`, `token_text`), the reserved and unsupported
## words, and the lookahead that only scans tokens (whether a loop, an arrow
## or a pattern assignment starts here, where a bracket closes).
##
## It stands apart from Parser because the parser is being split: the scope
## layout (ScopeLayout) and the class desugaring (ClassDesugaring) are to be
## modules of their own that Parser imports and that use these too. A module
## they all import, and that imports none of them, is the one place the
## basics can live without a cycle. The class records sit here only because
## `State` holds them; the class rules are Parser's and ClassDesugaring's.
import Ast
import Lexer
import NumberText

ParserBasics :: [].{
	# Where the parser is in the tokens, and how many function literals it has
	# passed, which tells a block whether one was written inside it.
	State : {
		tokens : List(Lexer.Token),
		at : U64,
		functions : U64,
		# The statements around the parser's place, innermost last, up to the
		# function it is in, which a `break` or a `continue` may leave.
		enclosing : List(ParserBasics.Enclosure),
		# Every class's name the program declares, found before the parse,
		# and the classes parsed so far.
		class_names : List(Str),
		classes : List(ParserBasics.ClassInfo),
		# What `this` and `super` mean where the parser is.
		receiver : ParserBasics.Receiver,
	}

	Enclosure : [
		Looping,
		Switching,
		LoopLabel(Str),
		BlockLabel(Str),
	]

	# The parser inside one more statement a `break` or a `continue` may
	# leave, and back out of it after, to where it was before.
	inside : ParserBasics.State, ParserBasics.Enclosure -> ParserBasics.State
	inside = |parser, enclosure| { ..parser, enclosing: parser.enclosing.append(enclosure) }

	outside : ParserBasics.State, ParserBasics.State -> ParserBasics.State
	outside = |after, before| { ..after, enclosing: before.enclosing }

	# The labels around the parser's place, outermost first.
	label_names : List(ParserBasics.Enclosure) -> List(Str)
	label_names = |enclosing| {
		var $names = []
		for each in enclosing {
			match each {
				LoopLabel(name) => {
					$names = $names.append(name)
				}
				BlockLabel(name) => {
					$names = $names.append(name)
				}
				_ => {}
			}
		}
		$names
	}

	# An enclosing label's number (`Ast.Label`): how many labels enclose it.
	label_number : List(ParserBasics.Enclosure), Str -> U64
	label_number = |enclosing, name| {
		var $at = 0
		var $found = 0
		for each in ParserBasics.label_names(enclosing) {
			if each == name {
				$found = $at
			}
			$at = $at + 1
		}
		$found
	}

	## A parse's value, and the parser after it.
	Parsed(a) : { parser : ParserBasics.State, value : a }

	# ---- tokens ----------------------------------------------------------------

	token : ParserBasics.State -> Lexer.Token
	token = |parser| parser.tokens.get(parser.at) ?? crash "ParserBasics.token: the parser never passes the end token"

	token_after : ParserBasics.State -> Lexer.Token
	token_after = |parser| parser.tokens.get(parser.at + 1) ?? ParserBasics.token(parser)

	advance : ParserBasics.State -> ParserBasics.State
	advance = |parser|
		if ParserBasics.is_end(parser) {
			parser
		} else {
			{ ..parser, at: parser.at + 1 }
		}

	is_end : ParserBasics.State -> Bool
	is_end = |parser| ParserBasics.token(parser).kind == End

	is_punct : ParserBasics.State, Str -> Bool
	is_punct = |parser, text| ParserBasics.token(parser).kind == Punct(text)

	is_word : ParserBasics.State, Str -> Bool
	is_word = |parser, text| ParserBasics.token(parser).kind == Name(text)

	where_of : Lexer.Token -> Ast.Where
	where_of = |current| { line: current.line, column: current.column }

	here : ParserBasics.State -> Ast.Where
	here = |parser| ParserBasics.where_of(ParserBasics.token(parser))

	fault_here : ParserBasics.State, Str -> Lexer.Fault
	fault_here = |parser, why| {
		current = ParserBasics.token(parser)
		{
			why: why,
			line: current.line,
			column: current.column,
		}
	}

	fault_at : Ast.Where, Str -> Lexer.Fault
	fault_at = |site, why| {
		why: why,
		line: site.line,
		column: site.column,
	}

	token_text : Lexer.TokenKind -> Str
	token_text = |kind| match kind {
		Number(number) => NumberText.text_for(number)
		Text(_) => "a string"
		Name(text) => "`${text}`"
		Punct(text) => "`${text}`"
		TemplateWhole(_) => "a template literal"
		TemplateHead(_) => "a template literal"
		TemplateMiddle(_) => "the middle of a template literal"
		TemplateTail(_) => "the end of a template literal"
		End => "the end of the program"
	}

	expect_punct : ParserBasics.State, Str -> Try(ParserBasics.State, Lexer.Fault)
	expect_punct = |parser, text|
		if ParserBasics.is_punct(parser, text) {
			Ok(ParserBasics.advance(parser))
		} else {
			Err(
				ParserBasics.fault_here(
					parser,
					"expected `${text}`, found ${ParserBasics.token_text(ParserBasics.token(parser).kind)}",
				),
			)
		}

	# A statement's end: a `;`, or at JavaScript would insert one.
	end_of_statement : ParserBasics.State -> Try(ParserBasics.State, Lexer.Fault)
	end_of_statement = |parser| {
		current = ParserBasics.token(parser)
		if ParserBasics.is_punct(parser, ";") {
			Ok(ParserBasics.advance(parser))
		} else if ParserBasics.is_punct(
			parser,
			"}",
		) or current.kind == End or current.before == NewLine {
			Ok(parser)
		} else {
			Err(
				ParserBasics.fault_here(
					parser,
					"expected `;` or a line break, found ${ParserBasics.token_text(current.kind)}",
				),
			)
		}
	}

	name_here : ParserBasics.State, Str -> Try(ParserBasics.Parsed(Str), Lexer.Fault)
	name_here = |parser, what|
		match ParserBasics.token(parser).kind {
			Name(text) => {
				if ParserBasics.is_reserved(text) {
					Err(
						ParserBasics.fault_here(
							parser,
							"`${text}` is a reserved word, not ${what}",
						),
					)
				} else if parser.class_names.contains(text) {
					Err(ParserBasics.fault_here(parser, ParserBasics.class_redeclared(text)))
				} else {
					Ok({ parser: ParserBasics.advance(parser), value: text })
				}
			}
			other => Err(
				ParserBasics.fault_here(
					parser,
					"expected ${what}, found ${ParserBasics.token_text(other)}",
				),
			)
		}

	reserved_words : List(Str)
	reserved_words = [
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
		"return",
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
		"undefined",
	]

	class_redeclared : Str -> Str
	class_redeclared = |name| "unsupported: `${name}` declared again, a class's name"

	is_reserved : Str -> Bool
	is_reserved = |text| ParserBasics.reserved_words.contains(text)

	# The words that begin a form the subset leaves out, and what to say.
	unsupported_word : Str -> Try(Str, [Supported])
	unsupported_word = |text| match text {
		"class" => Ok("unsupported: class expressions")
		"var" => Ok("unsupported: `var` (use `let` or `const`)")
		"delete" => Ok("unsupported: `delete`")
		"void" => Ok("unsupported: `void`")
		"import" => Ok("unsupported: modules (`import`)")
		"export" => Ok("unsupported: modules (`export`)")
		"async" => Ok("unsupported: async functions")
		"await" => Ok("unsupported: `await`")
		"yield" => Ok("unsupported: generators (`yield`)")
		"with" => Ok("unsupported: `with`")
		"eval" => Ok("unsupported: `eval`")
		"arguments" => Ok("unsupported: `arguments`")
		"debugger" => Ok("unsupported: `debugger`")
		_ => Err(Supported)
	}

	refuse_unsupported_word : ParserBasics.State -> Try({}, Lexer.Fault)
	refuse_unsupported_word = |parser|
		match ParserBasics.token(parser).kind {
			Name(text) => match ParserBasics.unsupported_word(text) {
				Ok(why) => Err(ParserBasics.fault_here(parser, why))
				Err(Supported) => Ok({})
			}
			_ => Ok({})
		}

	capture_since : ParserBasics.State, U64 -> Ast.Capture
	capture_since = |parser, before|
		if parser.functions > before {
			Captures
		} else {
			CapturesNothing
		}

	# Whether a loop starts here, after any labels of its own.
	is_loop_start : ParserBasics.State -> Bool
	is_loop_start = |parser|
		match ParserBasics.token(parser).kind {
			Name("for") | Name("while") | Name("do") => True
			Name(text) if ParserBasics.token_after(parser).kind == Punct(":") and !ParserBasics.is_reserved(text) => {
				ParserBasics.is_loop_start(ParserBasics.advance(ParserBasics.advance(parser)))
			}
			_ => False
		}

	# Past the `,` after a part of a list, or at its `close`.
	after_part : ParserBasics.State, Str, Str -> Try(ParserBasics.State, Lexer.Fault)
	after_part = |parser, close, what|
		if ParserBasics.is_punct(parser, ",") {
			Ok(ParserBasics.advance(parser))
		} else if ParserBasics.is_punct(parser, close) {
			Ok(parser)
		} else {
			Err(
				ParserBasics.fault_here(
					parser,
					"expected `,` or `${close}` in ${what}, found ${ParserBasics.token_text(ParserBasics.token(parser).kind)}",
				),
			)
		}

	# Whether an assignment to a pattern starts here: a `[` or a `{` whose
	# closing bracket is followed by `=`.
	is_pattern_assignment : ParserBasics.State -> Bool
	is_pattern_assignment = |parser|
		if ParserBasics.is_punct(parser, "[") or ParserBasics.is_punct(parser, "{") {
			match parser.tokens.get(ParserBasics.matching_close(parser) + 1) {
				Ok(current) => current.kind == Punct("=")
				Err(OutOfBounds) => False
			}
		} else {
			False
		}

	# The parser past the binding at its place: a name, or a pattern to its
	# closing bracket.
	after_binding : ParserBasics.State -> ParserBasics.State
	after_binding = |parser|
		if ParserBasics.is_punct(parser, "[") or ParserBasics.is_punct(parser, "{") {
			{
				..parser,
				at: U64.min(ParserBasics.matching_close(parser) + 1, parser.tokens.len() - 1),
			}
		} else {
			ParserBasics.advance(parser)
		}

	## A class parsed: its name, its own name and the names of the classes
	## it extends (nearest first), and its methods and static methods, its
	## own and those it inherits.
	ClassInfo : {
		name : Str,
		class_names : List(Str),
		methods : List(Str),
		statics : List(Str),
	}

	## What `this` and `super` mean where the parser is: nothing, outside a
	## class; the instance, in a constructor or a method and the arrows
	## inside them; refused, in a static method.
	Receiver : [
		NoReceiver,
		Constructing(ParserBasics.ClassCode),
		InMethod(ParserBasics.ClassCode),
		InStatic,
	]

	## What a class extends: nothing, or a class parsed above it.
	Parent : [Base, Extends(ParserBasics.ClassInfo)]

	## A constructor's or a method's class so far: what the class extends,
	## and, for the checks a constructor is held to, how often `this` and
	## `super(...)` were written, and the methods `super.m` named.
	ClassCode : {
		parent : ParserBasics.Parent,
		this_uses : U64,
		super_calls : U64,
		supers : List(Str),
	}

	ParsedExpression : Try(ParserBasics.Parsed(Ast.Expression), Lexer.Fault)

	# Whether an arrow function starts here: a name and `=>`, or a
	# parenthesized list whose `)` is followed by `=>`.
	is_arrow_start : ParserBasics.State -> Bool
	is_arrow_start = |parser|
		match ParserBasics.token(parser).kind {
			Name(_) => ParserBasics.token_after(parser).kind == Punct("=>")
			Punct("(") => {
				close = ParserBasics.matching_close(parser)
				match parser.tokens.get(close + 1) {
					Ok(current) => current.kind == Punct("=>")
					Err(OutOfBounds) => False
				}
			}
			_ => False
		}

	# The index of the `)` that closes the `(` at the parser's place.
	matching_close : ParserBasics.State -> U64
	matching_close = |parser| {
		var $i = parser.at
		var $depth = 0
		var $found = False
		while !$found and $i < parser.tokens.len() {
			current = parser.tokens.get($i) ?? crash "ParserBasics.matching_close: inside the tokens"
			opens = [
				Punct("("),
				Punct("["),
				Punct("{"),
			]
			if opens.contains(current.kind) {
				$depth = $depth + 1
				$i = $i + 1
			} else if current.kind == Punct(")") or current.kind == Punct("]") or current.kind == Punct("}") {
				$depth = $depth - 1
				if $depth == 0 {
					$found = True
				} else {
					$i = $i + 1
				}
			} else if current.kind == End {
				$found = True
			} else {
				$i = $i + 1
			}
		}
		$i
	}

	refuse_operator : ParserBasics.State, List(Str), Str -> Try({}, Lexer.Fault)
	refuse_operator = |parser, puncts, why|
		match ParserBasics.token(parser).kind {
			Punct(text) if puncts.contains(text) => Err(
				ParserBasics.fault_here(parser, "${why} (`${text}`)"),
			)
			_ => Ok({})
		}

	# A property's name after a `.`.
	name_after_dot : ParserBasics.State -> Try(ParserBasics.Parsed(Str), Lexer.Fault)
	name_after_dot = |parser|
		match ParserBasics.token(parser).kind {
			Name(text) => Ok({ parser: ParserBasics.advance(parser), value: text })
			Punct("#") => Err(ParserBasics.fault_here(parser, "unsupported: private names"))
			other => Err(
				ParserBasics.fault_here(
					parser,
					"expected a property's name after `.`, found ${ParserBasics.token_text(other)}",
				),
			)
		}
}
