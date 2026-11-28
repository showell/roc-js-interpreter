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
	Param : {
		name : [Named(Str), Patterned],
		shape : [Typed(KavaTypes.Shape, Str), Untyped],
		hold : [Shared, Owned, Lent],
		line : U64,
	}

	## The local an `old(x)` reads, and the code that saves it at entry.
	Old : { local : Str, code : Str }

	Contract : {
		params : List(KavaChecks.Param),
		result : [Typed(KavaTypes.Shape, Str, U64), Untyped],
		required : List(KavaChecks.Clause),
		ensured : List(KavaChecks.Clause),
		invariants : List(KavaChecks.Clause),
		olds : List(KavaChecks.Old),
	}

	## A failure's message: what failed, then the file and the line.
	message : Str, Str, U64 -> Str
	message = |file, what, line| "kava: ${what} failed (${file}, line ${line.to_str()})"

	## A text as a JavaScript string literal, in double quotes.
	quoted : Str -> Str
	quoted = |text| {
		var $out = ['"']
		for byte in text.to_utf8() {
			$out = match byte {
				'"' => List.concat($out, ['\\', '"'])
				'\\' => List.concat($out, ['\\', '\\'])
				'\n' => List.concat($out, ['\\', 'n'])
				_ => $out.append(byte)
			}
		}
		Str.from_utf8($out.append('"')) ?? crash "KavaChecks.quoted: escapes keep whole characters"
	}

	## The statement that fails with `what`'s message unless `test` holds.
	guard : Str, Str, Str, U64 -> Str
	guard = |
		file,
		test,
		what,
		line,
	| "if (!(${test})) $kava_fail(${KavaChecks.quoted(KavaChecks.message(file, what, line))});"

	## The checks at a function's entry, on one line, or "" for none.
	entry_checks : Str, KavaChecks.Contract -> Str
	entry_checks = |file, contract| {
		var $parts = []
		for param in contract.params {
			match (param.name, param.shape) {
				(Named(name), Typed(shape, text)) => {
					$parts = $parts.append(
						KavaChecks.guard(
							file,
							KavaTypes.check_of(shape, name, 1),
							"type ${name}: ${text}",
							param.line,
						),
					)
				}
				_ => {}
			}
		}
		for clause in contract.required {
			$parts = $parts.append(
				KavaChecks.guard(file, clause.code, "requires ${clause.text}", clause.line),
			)
		}
		for old in contract.olds {
			$parts = $parts.append("const ${old.local} = (${old.code});")
		}
		for param in contract.params {
			match (param.name, param.hold) {
				(Named(name), Lent) => {
					said = KavaChecks.quoted("kava: lent ${name}: ${name} was written (${file}, line ${param.line.to_str()})")
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
					file,
					KavaTypes.check_of(shape, "result", 1),
					"type result: ${text}",
					line,
				),
			]
			Untyped => []
		}
		for clause in contract.ensured {
			$parts = $parts.append(
				KavaChecks.guard(file, clause.code, "ensures ${clause.text}", clause.line),
			)
		}
		for clause in contract.invariants {
			$parts = $parts.append(
				KavaChecks.guard(file, clause.code, "invariant ${clause.text}", clause.line),
			)
		}
		Str.join_with($parts, " ")
	}

	## The functions a checked build calls, declared after the program, where
	## they are hoisted, so no line of the program moves. A poisoned variable
	## holds a proxy whose every use throws; a lent value is a view whose
	## every write throws, reads lent in turn, and a Map's or a Set's reads
	## passed through.
	helpers : Str
	helpers = Str.join_with(
		[
			"function $kava_fail(message) { throw new Error(message); }",
			"function $kava_is_i32(v) { return Number.isInteger(v) && v >= -2147483648 && v <= 2147483647; }",
			"function $kava_is_i64(v) { return Number.isInteger(v) && v >= -9223372036854775808 && v < 9223372036854775808; }",
			"function $kava_is_record(v, keys) { return typeof v === \"object\" && v !== null && !Array.isArray(v) && Object.keys(v).length === keys.length && keys.every((k) => Object.prototype.hasOwnProperty.call(v, k)); }",
			"function $kava_poison(message) { const fail = () => $kava_fail(message); return new Proxy({}, { get: fail, set: fail, has: fail, deleteProperty: fail, ownKeys: fail, getOwnPropertyDescriptor: fail, defineProperty: fail, getPrototypeOf: fail }); }",
			"function $kava_live(v) { if (v !== null && v !== undefined) { v[\"$kava live\"]; } return v; }",
			"function $kava_lend(v, message) {",
			"  if (v === null || (typeof v !== \"object\" && typeof v !== \"function\")) { return v; }",
			"  const fail = () => $kava_fail(message);",
			"  const collection = v instanceof Map || v instanceof Set;",
			"  return new Proxy(v, {",
			"    get(target, key) {",
			"      const x = Reflect.get(target, key, target);",
			"      if (collection && typeof x === \"function\") {",
			"        if (key === \"set\" || key === \"add\" || key === \"delete\" || key === \"clear\") { return fail; }",
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

	expect KavaChecks.quoted("a \"b\" \\ c") == "\"a \\\"b\\\" \\\\ c\""

	expect KavaChecks.guard(
		"f.kava",
		"x > 0",
		"requires x > 0",
		3,
	) == "if (!(x > 0)) $kava_fail(\"kava: requires x > 0 failed (f.kava, line 3)\");"
}
