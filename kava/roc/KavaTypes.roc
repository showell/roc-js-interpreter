## This module reads KavaScript's optional types and writes the check a
## checked build makes of one. A type is written where TypeScript writes its
## annotations, after a `:`, and JavaScript has none there, so a type never
## changes what a program means:
##
##   type    := [own | lent] primary ("[" "]")*
##   primary := number | i32 | i64 | string | boolean | bigint
##            | Name                     (a class: an instance of it)
##            | "{" [field ("," field)* [","]] "}"   (a record of that shape)
##            | "(" type ")"
##   field   := Name ":" type
##
## `i32` and `i64` are numbers that are whole and in their range. A record
## holds exactly its fields, each of its type. `own` and `lent` on a type
## are carried, never checked, so `): own number[]` reads as the sketch
## writes it.
import js.Lexer
import KavaTokens

KavaTypes :: [].{
	Shape := [
		Number,
		Whole32,
		Whole64,
		Text,
		Boolean,
		Big,
		Items(KavaTypes.Shape),
		Record(List((Str, KavaTypes.Shape))),
		Instance(Str),
	]

	## A type read from the tokens, and the index of the token after it.
	Reading : { shape : KavaTypes.Shape, next : U64 }

	kind_at : List(KavaTokens.Spanned), U64 -> Lexer.TokenKind
	kind_at = |tokens, index| match tokens.get(index) {
		Ok(found) => found.kind
		Err(OutOfBounds) => End
	}

	fault_at : List(KavaTokens.Spanned), U64, Str -> Lexer.Fault
	fault_at = |tokens, index, why| match tokens.get(index) {
		Ok(found) => {
			why: why,
			line: found.line,
			column: found.column,
		}
		Err(OutOfBounds) => {
			why: why,
			line: 0,
			column: 0,
		}
	}

	## The type that starts at `index`.
	shape_at : List(KavaTokens.Spanned), U64 -> Try(KavaTypes.Reading, Lexer.Fault)
	shape_at = |tokens, index| {
		after_word = match KavaTypes.kind_at(tokens, index) {
			Name("own") => index + 1
			Name("lent") => index + 1
			_ => index
		}
		primary = KavaTypes.primary_at(tokens, after_word)?
		var $shape = primary.shape
		var $next = primary.next
		while KavaTypes.kind_at(tokens, $next) == Punct("[") and KavaTypes.kind_at(
			tokens,
			$next + 1,
		) == Punct("]") {
			$shape = Items($shape)
			$next = $next + 2
		}
		Ok({ shape: $shape, next: $next })
	}

	primary_at : List(KavaTokens.Spanned), U64 -> Try(KavaTypes.Reading, Lexer.Fault)
	primary_at = |tokens, index| match KavaTypes.kind_at(tokens, index) {
		Name(word) => Ok({ shape: KavaTypes.named_shape(word), next: index + 1 })
		Punct("(") => {
			inner = KavaTypes.shape_at(tokens, index + 1)?
			if KavaTypes.kind_at(tokens, inner.next) == Punct(")") {
				Ok({ shape: inner.shape, next: inner.next + 1 })
			} else {
				Err(KavaTypes.fault_at(tokens, inner.next, "expected `)` to close a type"))
			}
		}
		Punct("{") => KavaTypes.record_at(tokens, index + 1)
		_ => Err(KavaTypes.fault_at(tokens, index, "expected a type"))
	}

	named_shape : Str -> KavaTypes.Shape
	named_shape = |word| match word {
		"number" => Number
		"i32" => Whole32
		"i64" => Whole64
		"string" => Text
		"boolean" => Boolean
		"bigint" => Big
		_ => Instance(word)
	}

	# A record's fields, from the token after its `{`.
	record_at : List(KavaTokens.Spanned), U64 -> Try(KavaTypes.Reading, Lexer.Fault)
	record_at = |tokens, index| {
		var $fields = []
		var $at = index
		while KavaTypes.kind_at(tokens, $at) != Punct("}") {
			field_name = match KavaTypes.kind_at(tokens, $at) {
				Name(word) => Ok(word)
				_ => Err(
					KavaTypes.fault_at(tokens, $at, "expected a field's name in a record type"),
				)
			}?
			if KavaTypes.kind_at(tokens, $at + 1) != Punct(":") {
				return Err(
					KavaTypes.fault_at(
						tokens,
						$at + 1,
						"expected `:` after a field's name in a record type",
					),
				)
			}
			field = KavaTypes.shape_at(tokens, $at + 2)?
			$fields = $fields.append((field_name, field.shape))
			$at = if KavaTypes.kind_at(tokens, field.next) == Punct(",") {
				field.next + 1
			} else if KavaTypes.kind_at(tokens, field.next) == Punct("}") {
				field.next
			} else {
				return Err(
					KavaTypes.fault_at(tokens, field.next, "expected `,` or `}` in a record type"),
				)
			}
		}
		Ok({ shape: Record($fields), next: $at + 1 })
	}

	## The JavaScript that is true when `subject` holds a value of the type,
	## `depth` naming an array's items apart from those of an array around
	## it. The `$kava_is_*` functions are the checked build's own
	## (KavaChecks.helpers).
	check_of : KavaTypes.Shape, Str -> Str
	check_of = |shape, subject| KavaTypes.check_at_depth(shape, subject, 1)

	## The check of a value `depth` arrays deep, its items named apart from
	## those of the arrays around it.
	check_at_depth : KavaTypes.Shape, Str, U64 -> Str
	check_at_depth = |shape, subject, depth| match shape {
		Number => "typeof ${subject} === \"number\""
		Whole32 => "$kava_is_i32(${subject})"
		Whole64 => "$kava_is_i64(${subject})"
		Text => "typeof ${subject} === \"string\""
		Boolean => "typeof ${subject} === \"boolean\""
		Big => "typeof ${subject} === \"bigint\""
		Items(inner) => {
			item = "$kava_item_${depth.to_str()}"
			"(Array.isArray(${subject}) && ${subject}.every((${item}) => ${KavaTypes.check_at_depth(inner, item, depth + 1)}))"
		}
		Record(fields) => {
			names = fields.map(|(field_name, _)| "\"${field_name}\"")
			checks = fields.map(
				|(field_name, field)| KavaTypes.check_at_depth(
					field,
					"${subject}.${field_name}",
					depth,
				),
			)
			whole = ["$kava_is_record(${subject}, [${Str.join_with(names, ", ")}])"]
			"(${Str.join_with(List.concat(whole, checks), " && ")})"
		}
		Instance(class_name) => "${subject} instanceof ${class_name}"
	}

	expect KavaTypes.check_of(Whole32, "x") == "$kava_is_i32(x)"

	expect KavaTypes.check_of(
		Items(Number),
		"xs",
	) == "(Array.isArray(xs) && xs.every(($kava_item_1) => typeof $kava_item_1 === \"number\"))"

	expect KavaTypes.check_of(
		Record([("a", Text)]),
		"r",
	) == "($kava_is_record(r, [\"a\"]) && typeof r.a === \"string\")"
}
