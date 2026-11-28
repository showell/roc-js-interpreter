## This module writes the JavaScript a checked build adds to a function: the
## checks at its entry (each typed parameter's type, each `requires`, each
## `old(x)` saved, each `lent` parameter made a view no write gets through)
## and those at each way out (the result's type, each `ensures`, and its
## class's invariants), and the functions every checked build carries
## (`helpers`), which those checks call.
##
## **EVERY CHECK IS WRITTEN ON ONE LINE,** beside the code it guards, so a
## checked build keeps the program's lines, and each failure's message names
## the clause, the file and the line it was written on.
import KavaTypes

KavaChecks :: [].{

	## A clause as written (its text on one line) and as the check runs it
	## (`code`: an `ensures`' `old(x)` read from the local saved at entry).
	Clause : {
		text : Str,
		code : Str,
		line : U64,
	}

	## A parameter: its name, or a pattern, which no check names; its type;
	## and whether it is handed over (`own`) or lent (`lent`).
	Parameter : {
		name : [Named(Str), Patterned],
		shape : [Typed(KavaTypes.Shape, Str), Untyped],
		hold : [Shared, Owned, Lent],
		line : U64,
	}

	## The local an `old(x)` reads, and the code that saves it at entry.
	Old : { local : Str, code : Str }

	Contract : {
		parameters : List(KavaChecks.Parameter),
		result : [Typed(KavaTypes.Shape, Str, U64), Untyped],
		required : List(KavaChecks.Clause),
		ensured : List(KavaChecks.Clause),
		invariants : List(KavaChecks.Clause),
		olds : List(KavaChecks.Old),
	}

	## What failed, in which file, at which line.
	Failure : {
		file : Str,
		what : Str,
		line : U64,
	}

	## A failure's message: what failed, then the file and the line.
	message : KavaChecks.Failure -> Str
	message = |failure| {
		place = "${failure.file}, line ${failure.line.to_str()}"
		"kava: ${failure.what} failed (${place})"
	}

	## A text as a JavaScript string literal, in double quotes.
	string_literal : Str -> Str
	string_literal = |text| {
		var $out = ['"']
		for byte in text.to_utf8() {
			$out = match byte {
				'"' => List.concat($out, ['\\', '"'])
				'\\' => List.concat($out, ['\\', '\\'])
				'\n' => List.concat($out, ['\\', 'n'])
				_ => $out.append(byte)
			}
		}
		why = "KavaChecks.string_literal: escapes keep whole characters"
		Str.from_utf8($out.append('"')) ?? crash why
	}

	## The statement that fails with the failure's message unless `test`
	## holds.
	guard : Str, KavaChecks.Failure -> Str
	guard = |test, failure| {
		said = KavaChecks.string_literal(KavaChecks.message(failure))
		"if (!(${test})) $kava_fail(${said});"
	}

	## The checks at a function's entry, on one line, or "" for none.
	entry_checks : Str, KavaChecks.Contract -> Str
	entry_checks = |file, contract| {
		var $parts = []
		for parameter in contract.parameters {
			match (parameter.name, parameter.shape) {
				(Named(name), Typed(shape, text)) => {
					$parts = $parts.append(
						KavaChecks.guard(
							KavaTypes.check_of(shape, name),
							{
								file: file,
								what: "type ${name}: ${text}",
								line: parameter.line,
							},
						),
					)
				}
				_ => {}
			}
		}
		for clause in contract.required {
			$parts = $parts.append(
				KavaChecks.guard(
					clause.code,
					{
						file: file,
						what: "requires ${clause.text}",
						line: clause.line,
					},
				),
			)
		}
		for old in contract.olds {
			$parts = $parts.append("const ${old.local} = (${old.code});")
		}
		for parameter in contract.parameters {
			match (parameter.name, parameter.hold) {
				(Named(name), Lent) => {
					written = "lent ${name} failed: it was written"
					place = "${file}, line ${parameter.line.to_str()}"
					said = KavaChecks.string_literal("kava: ${written} (${place})")
					$parts = $parts.append("${name} = $kava_lend(${name}, ${said});")
				}
				_ => {}
			}
		}
		Str.join_with($parts, " ")
	}

	## The checks at each of a function's ways out, `result` its value, on
	## one line, or "" for none.
	exit_checks : Str, KavaChecks.Contract -> Str
	exit_checks = |file, contract| {
		var $parts = match contract.result {
			Typed(shape, text, line) => [
				KavaChecks.guard(
					KavaTypes.check_of(shape, "result"),
					{
						file: file,
						what: "type result: ${text}",
						line: line,
					},
				),
			]
			Untyped => []
		}
		for clause in contract.ensured {
			$parts = $parts.append(
				KavaChecks.guard(
					clause.code,
					{
						file: file,
						what: "ensures ${clause.text}",
						line: clause.line,
					},
				),
			)
		}
		for clause in contract.invariants {
			$parts = $parts.append(
				KavaChecks.guard(
					clause.code,
					{
						file: file,
						what: "invariant ${clause.text}",
						line: clause.line,
					},
				),
			)
		}
		Str.join_with($parts, " ")
	}

	## The functions a checked build calls, declared after the program, where
	## they are hoisted, so no line of the program moves. A poisoned variable
	## holds a proxy whose every use throws; a lent value is a view whose
	## every write throws, reads lent in turn, and a Map's or a Set's reads
	## passed through, a counted build's call by its site's key (KavaCost) as
	## the call by its method's name.
	helpers : Str
	helpers = Str.join_with(
		[
			"function $kava_fail(message) {",
			"  throw new Error(message);",
			"}",
			"function $kava_is_i32(v) {",
			"  return Number.isInteger(v) && v >= -2147483648 && v <= 2147483647;",
			"}",
			"function $kava_is_i64(v) {",
			"  return Number.isInteger(v)",
			"    && v >= -9223372036854775808 && v < 9223372036854775808;",
			"}",
			"function $kava_is_record(v, keys) {",
			"  return typeof v === \"object\" && v !== null && !Array.isArray(v)",
			"    && Object.keys(v).length === keys.length",
			"    && keys.every((k) => Object.prototype.hasOwnProperty.call(v, k));",
			"}",
			"function $kava_poison(message) {",
			"  const fail = () => $kava_fail(message);",
			"  return new Proxy({}, {",
			"    get: fail, set: fail, has: fail, deleteProperty: fail, ownKeys: fail,",
			"    getOwnPropertyDescriptor: fail, defineProperty: fail, getPrototypeOf: fail,",
			"  });",
			"}",
			"function $kava_live(v) {",
			"  if (v !== null && v !== undefined) { v[\"$kava live\"]; }",
			"  return v;",
			"}",
			"function $kava_lend(v, message) {",
			"  if (v === null || (typeof v !== \"object\" && typeof v !== \"function\")) {",
			"    return v;",
			"  }",
			"  const fail = () => $kava_fail(message);",
			"  const collection = v instanceof Map || v instanceof Set;",
			"  const writes = [\"set\", \"add\", \"delete\", \"clear\"];",
			"  // A counted build calls a method by its site's key, a Symbol.",
			"  const names = globalThis.$kava_key_names;",
			"  const name_of = (key) => (names && names.has(key) ? names.get(key) : key);",
			"  return new Proxy(v, {",
			"    get(target, key) {",
			"      const x = Reflect.get(target, key, target);",
			"      if (collection && typeof x === \"function\") {",
			"        if (writes.includes(name_of(key))) { return fail; }",
			"        return (...args) => $kava_lend(x.apply(target, args), message);",
			"      }",
			"      return typeof x === \"function\" ? x : $kava_lend(x, message);",
			"    },",
			"    set: fail, defineProperty: fail, deleteProperty: fail, setPrototypeOf: fail,",
			"  });",
			"}",
			"",
		],
		"\n",
	)

	expect KavaChecks.string_literal("a \"b\" \\ c") == "\"a \\\"b\\\" \\\\ c\""

	expect {
		failure = {
			file: "f.kava",
			what: "requires x > 0",
			line: 3,
		}
		said = "kava: requires x > 0 failed (f.kava, line 3)"
		KavaChecks.guard("x > 0", failure) == "if (!(x > 0)) $kava_fail(\"${said}\");"
	}
}
