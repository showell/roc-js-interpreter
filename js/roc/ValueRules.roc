## This module holds the rules JavaScript's values follow, which the
## bytecode VM (`Vm`) calls where its own fast paths stop: what a property
## read gives and a property write does, what an operator makes of two
## values, what a pattern takes apart, and the errors those throw and the
## faults they stop at, each message in its words. None of them runs a
## function of the program or reaches the host, so a message has one home.
##
## Four modules build on it, each one kind of value's rules, read and
## audited apart: StringRules (the methods of strings), ArrayRules (of
## arrays), CollectionRules (the walks, and Maps and Sets) and
## BuiltinRules (the globals and the builtins). Each follows the rules
## below.
##
## **THE VM LENDS A RULE ITS CELLS.** A rule reads and writes the heap
## (`cells`) and the run's `status` (a fault, or a value thrown), and
## nothing else, so it takes a machine of those two (`ValueRules.Machine`):
## the VM takes its cells out of its own machine, hands them over with
## its status, and puts back what the rule gives, so the cells have one
## owner while the rule writes them. A rule generic over the rest of the
## VM's machine, an open record, would be shorter to call, but the dev
## build copies the cells a rule writes through one.
##
## **NOTHING HOLDS THE MACHINE BUT THE RULE.** A rule passes the cells straight from the record it
## updates, takes every `Got` apart where it is answered, and asks
## `ValueRules.kind_of` what a cell is rather than matching it out of the
## heap, so the heap stays unique and each write is made in place
## (js/README.md, "Why the heap is one value").
##
## **THE RULES TAKE SEVERAL ARGUMENTS, A NAMED EXCEPTION.** As the VM's
## handlers do, a rule takes the machine first, then the rest, where the
## style guide would take one record: a record holding the machine is a
## second reference to the heap. The methods by name follow it too.
import Ast
import Heap
import Inspect
import NumberText

ValueRules :: [].{

	## The part of the VM's machine a rule reads and writes: the heap, its
	## free cells, which an allocation takes first, and whether the run goes
	## on.
	Machine : { cells : List(Heap.Cell), free : Heap.Free, status : ValueRules.Status }

	## A rule's value, and the machine after it.
	Got : { machine : ValueRules.Machine, value : Heap.Value }

	Evaluations : { machine : ValueRules.Machine, values : List(Heap.Value) }

	## Whether the machine runs on: a fault stops the run for good; a value
	## thrown, and not yet caught, unwinds it to the nearest `try`, which runs
	## it on. The value thrown and where it was thrown wait in a box, so a
	## status is no bigger than a fault's message: the machine holding it is
	## handed back from every evaluation.
	Status : [Running, Faulted(Str), Thrown(Box(ValueRules.Throw))]

	Throw : { value : Heap.Value, site : Ast.Where }

	# The deepest JavaScript call the interpreter makes before it reports a
	# stack overflow, as node does near the same depth. A call is a frame of
	# the VM's own stack, data, so it costs Roc's stack nothing.
	max_depth : U64
	max_depth = 10000

	# What a throw nothing caught says: `Uncaught `, the first line node
	# prints for the value (an error's name and message, or the value as
	# console.log shows it), and the line of the throw.
	uncaught_ending : List(Heap.Cell), Heap.Value, Ast.Where -> [Uncaught(Str), Faulted(Str)]
	uncaught_ending = |cells, value, site| {
		shown = match value {
			Reference(id) => match Heap.cell_at(cells, id) {
				Failure(_, _) => ValueRules.text_of(cells, value)
				_ => Inspect.line_of(cells, [value])
			}
			_ => Inspect.line_of(cells, [value])
		}
		match shown {
			Ok(text) => {
				first = text.split_on("\n").first() ?? crash "ValueRules.uncaught_ending: a split has a first piece"
				Uncaught("Uncaught ${first}${ValueRules.line_note(site)}")
			}
			Err(Unsupported(why)) => Faulted("${why}, thrown and not caught${ValueRules.line_note(site)}")
		}
	}

	# ---- the machine's status --------------------------------------------------

	alloc : ValueRules.Machine, Heap.Cell -> ValueRules.Got
	alloc = |machine, cell| {
		{ cells, free, status } = machine
		made = Heap.allocated(cells, free, cell)
		{ machine: { cells: made.cells, free: made.free, status: status }, value: Reference(made.id) }
	}

	is_running : ValueRules.Machine -> Bool
	is_running = |machine|
		match machine.status {
			Running => True
			_ => False
		}

	# The machine stopped with `why`, unless it had already stopped.
	with_fault : ValueRules.Machine, Str -> ValueRules.Machine
	with_fault = |machine, why|
		match machine.status {
			Running => { ..machine, status: Faulted(why) }
			_ => machine
		}

	# The machine unwinding with `value` thrown at `site`, unless it had
	# already stopped.
	with_thrown : ValueRules.Machine, Heap.Value, Ast.Where -> ValueRules.Machine
	with_thrown = |machine, value, site|
		match machine.status {
			Running => { ..machine, status: Thrown(Box.box({ value, site })) }
			_ => machine
		}

	fault_got : ValueRules.Machine, Str -> ValueRules.Got
	fault_got = |machine, why| { machine: ValueRules.with_fault(machine, why), value: Undefined }

	line_note : Ast.Where -> Str
	line_note = |site| " (line ${site.line.to_str()})"

	# The machine unwinding with one of JavaScript's own errors, `name`,
	# saying `message` as node words it, thrown at `site`: a program may
	# catch it as it catches its own.
	with_error : ValueRules.Machine, Heap.ErrorName, Str, Ast.Where -> ValueRules.Machine
	with_error = |machine, name, message, site|
		if !ValueRules.is_running(machine) {
			machine
		} else {
			{ machine: made, value: error } = ValueRules.alloc(machine, Failure(name, message))
			ValueRules.with_thrown(made, error, site)
		}

	error_got : ValueRules.Machine, Heap.ErrorName, Str, Ast.Where -> ValueRules.Got
	error_got = |machine, name, message, site| {
		machine: ValueRules.with_error(machine, name, message, site),
		value: Undefined,
	}

	# An expression as V8 writes it in a message (`o.f is not a function`):
	# names, properties, indices, calls and literals, and `(intermediate
	# value)` for the rest.
	source_text : Ast.Expression -> Str
	source_text = |expression| match expression {
		Name(name, _, _) => name
		Member(object, key, _) => "${ValueRules.source_text(object)}.${key}"
		Index(object, key, _) => "${ValueRules.source_text(object)}[${ValueRules.source_text(key)}]"
		Call(callee, _, _) => "${ValueRules.source_text(callee)}(...)"
		OptionalMember(object, key, _) => "${ValueRules.source_text(object)}?.${key}"
		OptionalIndex(object, key, _) => "${ValueRules.source_text(object)}?.[${ValueRules.source_text(key)}]"
		OptionalCall(callee, _, _) => "${ValueRules.source_text(callee)}?.(...)"
		Chain(chain) => ValueRules.source_text(chain)
		Number(number) => NumberText.text_for(number)
		Text(text) => "\"${text}\""
		Boolean(truth) => if truth {
			"true"
		} else {
			"false"
		}
		Null => "null"
		Undefined => "undefined"
		ObjectLit([]) => "{}"
		ObjectLit(_) => "{(intermediate value)}"
		ArrayLit(items) => {
			shown = items.map(
				|item| match item {
					Single(single) => ValueRules.source_text(single)
					Spread(_, _) => "(intermediate value)"
				},
			)
			"[${Str.join_with(shown, ",")}]"
		}
		_ => "(intermediate value)"
	}

	# ---- values ----------------------------------------------------------------

	# A string's characters, each its UTF-8 bytes, as `for ... of` takes them.
	characters : Str -> List(Str)
	characters = |text| {
		bytes = text.to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			lead = bytes.get($i) ?? crash "ValueRules.characters: inside the text"
			width = if lead >= 0xF0 {
				4
			} else if lead >= 0xE0 {
				3
			} else if lead >= 0xC0 {
				2
			} else {
				1
			}
			$out = $out.append(
				Str.from_utf8(
					bytes.sublist({ start: $i, len: width }),
				) ?? crash "ValueRules.characters: a whole character",
			)
			$i = $i + width
		}
		$out
	}

	is_truthy : Heap.Value -> Bool
	is_truthy = |subject| match subject {
		Number(number) => !(number == 0.0 or number.is_nan())
		Text(text) => !text.is_empty()
		Boolean(truth) => truth
		Null => False
		Undefined => False
		Reference(_) => True
	}

	type_of : List(Heap.Cell), Heap.Value -> Str
	type_of = |cells, subject| match subject {
		Number(_) => "number"
		Text(_) => "string"
		Boolean(_) => "boolean"
		Null => "object"
		Undefined => "undefined"
		Reference(id) => match Heap.cell_at(cells, id) {
			Fun(_) => "function"
			Builtin(_, _) => "function"
			_ => "object"
		}
	}

	is_strictly_equal : Heap.Value, Heap.Value -> Bool
	is_strictly_equal = |left, right| match (left, right) {
		(Number(x), Number(y)) => x == y
		(Text(x), Text(y)) => x == y
		(Boolean(x), Boolean(y)) => x == y
		(Null, Null) => True
		(Undefined, Undefined) => True
		(Reference(x), Reference(y)) => x == y
		_ => False
	}

	# SameValueZero, as `includes` compares: NaN finds NaN.
	is_same_value_zero : Heap.Value, Heap.Value -> Bool
	is_same_value_zero = |left, right| match (left, right) {
		(Number(x), Number(y)) => x == y or (x.is_nan() and y.is_nan())
		_ => ValueRules.is_strictly_equal(left, right)
	}

	# What `String(v)` gives, for the values whose text the subset has.
	text_of : List(Heap.Cell), Heap.Value -> Try(Str, [Unsupported(Str)])
	text_of = |cells, subject| ValueRules.text_of_seen(cells, subject, [])

	text_of_seen : List(Heap.Cell), Heap.Value, List(U64) -> Try(Str, [Unsupported(Str)])
	text_of_seen = |cells, subject, seen| match subject {
		Number(number) => Ok(NumberText.text_for(number))
		Text(text) => Ok(text)
		Boolean(truth) => Ok(
			if truth {
				"true"
			} else {
				"false"
			},
		)
		Null => Ok("null")
		Undefined => Ok("undefined")
		Reference(id) => match Heap.cell_at(cells, id) {
			Array(items) => {
				if seen.contains(id) {
					Err(Unsupported("unsupported: turning a circular array into text"))
				} else {
					var $parts = []
					for item in items {
						part = match item {
							Null => ""
							Undefined => ""
							_ => ValueRules.text_of_seen(cells, item, seen.append(id))?
						}
						$parts = $parts.append(part)
					}
					Ok(Str.join_with($parts, ","))
				}
			}
			Object(_) => Ok("[object Object]")
			Instance(_, _) => Ok("[object Object]")
			MapOf(_) => Ok("[object Map]")
			SetOf(_) => Ok("[object Set]")
			Failure(name, "") => Ok(Heap.error_name_text(name))
			Failure(name, message) => Ok("${Heap.error_name_text(name)}: ${message}")
			_ => Err(Unsupported("unsupported: turning a function or a builtin object into text"))
		}
	}

	# The property key a value names, as `o[k]` reads it.
	key_of : Heap.Value -> Try(Str, [Unsupported(Str)])
	key_of = |subject| match subject {
		Number(number) => Ok(NumberText.text_for(number))
		Text(text) => Ok(text)
		Boolean(truth) => Ok(
			if truth {
				"true"
			} else {
				"false"
			},
		)
		Null => Ok("null")
		Undefined => Ok("undefined")
		Reference(_) => Err(Unsupported("unsupported: an object or array as a property key"))
	}

	# The array index a value names, if it names one.
	index_of : Heap.Value -> Try(U64, [NotIndex])
	index_of = |subject| match subject {
		Number(number) => {
			if number >= 0.0 and number < 4294967295.0 and number.div_trunc_by(1.0) == number {
				number.to_u64_try().map_err(|_| NotIndex)
			} else {
				Err(NotIndex)
			}
		}
		Text(text) => Inspect.index_of_key(text)
		_ => Err(NotIndex)
	}

	ordering_of_text : Str, Str -> [Before, Same, After]
	ordering_of_text = |left, right| {
		x = left.to_utf8()
		y = right.to_utf8()
		var $i = 0
		var $answer = Same
		var $deciding = True
		while $deciding {
			match (x.get($i), y.get($i)) {
				(Ok(left_byte), Ok(right_byte)) => {
					if left_byte < right_byte {
						$answer = Before
						$deciding = False
					} else if left_byte > right_byte {
						$answer = After
						$deciding = False
					} else {
						$i = $i + 1
					}
				}
				(Err(_), Ok(_)) => {
					$answer = Before
					$deciding = False
				}
				(Ok(_), Err(_)) => {
					$answer = After
					$deciding = False
				}
				(Err(_), Err(_)) => {
					$deciding = False
				}
			}
		}
		$answer
	}

	shown_value : List(Heap.Cell), Heap.Value -> Str
	shown_value = |cells, subject| match subject {
		Text(text) => Inspect.escaped_text(text)
		_ => Inspect.inspect(cells, subject) ?? ValueRules.type_of(cells, subject)
	}

	is_nullish : Heap.Value -> Bool
	is_nullish = |subject| subject == Null or subject == Undefined

	# The own properties `{...value}` spreads: an object's, in key order, an
	# array's items by their indices, an ASCII string's characters; a value
	# with none (`null`, a number, a function) spreads nothing.
	spread_properties : List(Heap.Cell), Heap.Value -> Try(List(Heap.Property), [Unsupported(Str)])
	spread_properties = |cells, subject|
		match subject {
			Reference(id) => match Heap.cell_at(cells, id) {
				Object(properties) => Ok(Inspect.properties_in_key_order(properties))
				Array(items) => Ok(ValueRules.indexed_properties(items))
				Instance(_, _) => Err(Unsupported(Inspect.instance_listed))
				_ => Ok([])
			}
			Text(text) => {
				if ValueRules.is_ascii(text) {
					Ok(ValueRules.indexed_properties(ValueRules.characters(text).map(|character| Text(character))))
				} else {
					Err(Unsupported("unsupported: spreading a string with non-ASCII text into an object"))
				}
			}
			_ => Ok([])
		}

	indexed_properties : List(Heap.Value) -> List(Heap.Property)
	indexed_properties = |items| items.map_with_index(|item, position| { key: position.to_str(), value: item })

	items_of : List(Heap.Cell), U64 -> List(Heap.Value)
	items_of = |cells, id|
		match Heap.cell_at(cells, id) {
			Array(items) => items
			_ => crash "ValueRules.items_of: the interpreter asks only an array for its items"
		}

	# A relative index (`slice`'s, negative from the end) as an index in 0..n.
	relative_index : Heap.Value, U64, U64 -> U64
	relative_index = |subject, length, otherwise|
		match subject {
			Number(x) => {
				truncated = if x.is_nan() {
					0.0
				} else {
					x.div_trunc_by(1.0)
				}
				if truncated < 0.0 {
					from_end = length.to_f64() + truncated
					if from_end < 0.0 {
						0
					} else {
						from_end.to_u64_try() ?? 0
					}
				} else if truncated >= length.to_f64() {
					length
				} else {
					truncated.to_u64_try() ?? 0
				}
			}
			_ => otherwise
		}

	# `at`'s index: from the end when negative, or none past either end.
	at_index : Heap.Value, U64 -> Try(U64, [OutOfRange])
	at_index = |subject, length| {
		wanted = match subject {
			Number(number) if !number.is_nan() => number.div_trunc_by(1.0)
			_ => 0.0
		}
		place = if wanted < 0.0 {
			length.to_f64() + wanted
		} else {
			wanted
		}
		if place >= 0.0 and place < length.to_f64() {
			place.to_u64_try().map_err(|_| OutOfRange)
		} else {
			Err(OutOfRange)
		}
	}

	is_callable : List(Heap.Cell), Heap.Value -> Bool
	is_callable = |cells, value|
		match value {
			Reference(id) => match Heap.cell_at(cells, id) {
				Fun(_) => True
				Builtin(_, _) => True
				_ => False
			}
			_ => False
		}

	# ---- names and operators ---------------------------------------------------

	unready_message : Str -> Str
	unready_message = |name| "Cannot access '${name}' before initialization"

	# A name declared nowhere: a builtin JavaScript has and the subset
	# doesn't, refused, or else node's ReferenceError.
	missing_name_got : ValueRules.Machine, Str, Ast.Where -> ValueRules.Got
	missing_name_got = |machine, name, site|
		if [
			"globalThis",
			"window",
			"require",
			"process",
			"JSON",
			"Symbol",
			"Promise",
			"Date",
			"RegExp",
			"parseInt",
			"parseFloat",
			"BigInt",
			"Reflect",
			"Proxy",
		].contains(name) {
			ValueRules.fault_got(machine, "unsupported: the builtin `${name}`${ValueRules.line_note(site)}")
		} else {
			ValueRules.error_got(machine, ReferenceError, "${name} is not defined", site)
		}

	unary : ValueRules.Machine, Ast.UnaryOperator, Heap.Value, Ast.Where -> ValueRules.Got
	unary = |machine, operator, subject, site|
		match operator {
			Not => { machine: machine, value: Boolean(!ValueRules.is_truthy(subject)) }
			TypeOf => { machine: machine, value: Text(ValueRules.type_of(machine.cells, subject)) }
			Negate => match subject {
				Number(number) => { machine: machine, value: Number(-number) }
				_ => ValueRules.fault_got(
					machine,
					"unsupported: `-` on a ${ValueRules.type_of(machine.cells, subject)} (a coercion)${ValueRules.line_note(site)}",
				)
			}
			Plus => match subject {
				Number(number) => { machine: machine, value: Number(number) }
				_ => ValueRules.fault_got(
					machine,
					"unsupported: `+` on a ${ValueRules.type_of(machine.cells, subject)} (a coercion)${ValueRules.line_note(site)}",
				)
			}
		}

	binary : ValueRules.Machine, Ast.BinaryOperator, Heap.Value, Heap.Value, Ast.Where -> ValueRules.Got
	binary = |machine, operator, left, right, site|
		match operator {
			StrictEqual => {
				machine: machine,
				value: Boolean(ValueRules.is_strictly_equal(left, right)),
			}
			StrictNotEqual => {
				machine: machine,
				value: Boolean(!ValueRules.is_strictly_equal(left, right)),
			}
			Add => ValueRules.add(machine, left, right, site)
			_ => match (left, right) {
				(Number(x), Number(y)) => {
					machine: machine,
					value: ValueRules.arithmetic(operator, x, y),
				}
				(Text(x), Text(y)) => match operator {
					Less => {
						machine: machine,
						value: Boolean(ValueRules.ordering_of_text(x, y) == Before),
					}
					LessOrEqual => {
						machine: machine,
						value: Boolean(ValueRules.ordering_of_text(x, y) != After),
					}
					Greater => {
						machine: machine,
						value: Boolean(ValueRules.ordering_of_text(x, y) == After),
					}
					GreaterOrEqual => {
						machine: machine,
						value: Boolean(ValueRules.ordering_of_text(x, y) != Before),
					}
					_ => ValueRules.fault_got(
						machine,
						"unsupported: arithmetic on strings (a coercion)${ValueRules.line_note(site)}",
					)
				}
				_ => ValueRules.fault_got(
					machine,
					"unsupported: an operator on a ${ValueRules.type_of(machine.cells, left)} and a ${ValueRules.type_of(machine.cells, right)} (a coercion)${ValueRules.line_note(site)}",
				)
			}
		}

	arithmetic : Ast.BinaryOperator, F64, F64 -> Heap.Value
	arithmetic = |operator, x, y| match operator {
		Subtract => Number(x - y)
		Multiply => Number(x * y)
		Divide => Number(x / y)
		Remainder => Number(ValueRules.remainder(x, y))
		Power => Number(ValueRules.power(x, y))
		Less => Boolean(x < y)
		LessOrEqual => Boolean(x <= y)
		Greater => Boolean(x > y)
		GreaterOrEqual => Boolean(x >= y)
		Add => Number(x + y)
		StrictEqual => Boolean(x == y)
		StrictNotEqual => Boolean(x != y)
	}

	# JavaScript's `%`: the sign of the dividend, NaN for a zero divisor or an
	# infinite dividend, the dividend itself for an infinite divisor.
	remainder : F64, F64 -> F64
	remainder = |x, y|
		if y == 0.0 or x.is_nan() or y.is_nan() or x.is_infinite() {
			0.0 / 0.0
		} else if y.is_infinite() {
			x
		} else {
			x.rem_by(y)
		}

	power : F64, F64 -> F64
	power = |x, y|
		if y.is_nan() or ((x == 1.0 or x == -1.0) and y.is_infinite()) {
			0.0 / 0.0
		} else {
			x.pow(y)
		}

	# `+`: numbers add; a string, an array or an object on either side makes
	# both sides text, which join.
	add : ValueRules.Machine, Heap.Value, Heap.Value, Ast.Where -> ValueRules.Got
	add = |machine, left, right, site|
		match (left, right) {
			(Number(x), Number(y)) => { machine: machine, value: Number(x + y) }
			_ => {
				is_texty = |subject| match subject {
					Text(_) => True
					Reference(_) => True
					_ => False
				}
				if is_texty(left) or is_texty(right) {
					match (
						ValueRules.text_of(machine.cells, left),
						ValueRules.text_of(machine.cells, right),
					) {
						(Ok(x), Ok(y)) => { machine: machine, value: Text(Str.concat(x, y)) }
						(Err(Unsupported(why)), _) => ValueRules.fault_got(
							machine,
							"${why}${ValueRules.line_note(site)}",
						)
						(_, Err(Unsupported(why))) => ValueRules.fault_got(
							machine,
							"${why}${ValueRules.line_note(site)}",
						)
					}
				} else {
					ValueRules.fault_got(
						machine,
						"unsupported: `+` on a ${ValueRules.type_of(machine.cells, left)} and a ${ValueRules.type_of(machine.cells, right)} (a coercion)${ValueRules.line_note(site)}",
					)
				}
			}
		}

	# ---- patterns --------------------------------------------------------------

	## Where a value being taken apart came from, which node's messages name
	## when it can't be: the expression written beside the pattern, a call's
	## argument, or a part of a bigger value.
	Origin : [Written(Ast.Expression), Argument, Nested]

	is_array_cell : List(Heap.Cell), U64 -> Bool
	is_array_cell = |cells, id|
		match ValueRules.kind_of(cells, id) {
			ArrayKind(_) => True
			_ => False
		}

	# An object's own properties but those `taken`, in key order, as `...rest`
	# takes them.
	properties_left : List(Heap.Cell), Heap.Value, List(Str) -> Try(List(Heap.Property), [Unsupported(Str)])
	properties_left = |cells, subject, taken| {
		refused = Err(Unsupported("unsupported: `...rest` of anything but a plain object"))
		match subject {
			Reference(id) => match Heap.cell_at(cells, id) {
				Object(properties) => Ok(
					Inspect.properties_in_key_order(properties).keep_if(|p| !taken.contains(p.key)),
				)
				Instance(_, _) => Err(Unsupported(Inspect.instance_listed))
				_ => refused
			}
			_ => refused
		}
	}

	# node's words for a pattern of properties given `null` or `undefined`.
	destructure_message : Heap.Value, List(Ast.PropertyPattern), ValueRules.Origin -> Str
	destructure_message = |subject, properties, origin| {
		nothing = match subject {
			Null => "null"
			_ => "undefined"
		}
		source = match origin {
			Written(expression) => ValueRules.source_text(expression)
			Argument => match subject {
				Null => "object null"
				_ => "undefined"
			}
			Nested => nothing
		}
		match (origin, properties.first()) {
			(Nested, Ok(first)) => "Cannot read properties of ${nothing} (reading '${first.key}')"
			(_, Ok(first)) => "Cannot destructure property '${first.key}' of '${source}' as it is ${nothing}."
			(_, Err(ListWasEmpty)) => "Cannot destructure '${source}' as it is ${nothing}."
		}
	}

	# The machine stopped by the TypeError node gives for taking apart, or
	# walking, what isn't iterable: the expression written, where there is one,
	# else the value's type and value.
	with_not_iterable : ValueRules.Machine, Heap.Value, ValueRules.Origin, Ast.Where -> ValueRules.Machine
	with_not_iterable = |machine, subject, origin, site| {
		message = match origin {
			Written(expression) => "${ValueRules.source_text(expression)} is not iterable"
			_ => {
				shown = match subject {
					Number(number) => "number ${NumberText.text_for(number)}"
					Boolean(truth) => if truth {
						"boolean true"
					} else {
						"boolean false"
					}
					Null => "object null"
					_ => ValueRules.type_of(machine.cells, subject)
				}
				"${shown} is not iterable (cannot read property Symbol(Symbol.iterator))"
			}
		}
		ValueRules.with_error(machine, TypeError, message, site)
	}

	# ---- properties ------------------------------------------------------------

	property : ValueRules.Machine, Heap.Value, Str, Ast.Where -> ValueRules.Got
	property = |machine, object, key, site|
		match object {
			Reference(id) => match Heap.cell_at(machine.cells, id) {
				Object(properties) | Instance(_, properties) => {
					if Heap.has_property(properties, key) {
						{ machine: machine, value: Heap.property_value(properties, key) }
					} else if ValueRules.is_prototype_name(key) {
						ValueRules.fault_got(
							machine,
							"unsupported: Object.prototype's `${key}`${ValueRules.line_note(site)}",
						)
					} else {
						{ machine: machine, value: Undefined }
					}
				}
				Array(items) => {
					if key == "length" {
						{ machine: machine, value: Number(items.len().to_f64()) }
					} else {
						match Inspect.index_of_key(key) {
							Ok(position) => {
								machine: machine,
								value: items.get(position) ?? Undefined,
							}
							Err(NotIndex) => ValueRules.fault_got(
								machine,
								"unsupported: the array property `${key}` outside a call${ValueRules.line_note(site)}",
							)
						}
					}
				}
				Namespace(name, properties) => {
					if Heap.has_property(properties, key) {
						{ machine: machine, value: Heap.property_value(properties, key) }
					} else {
						ValueRules.fault_got(
							machine,
							"unsupported: `${name}.${key}`${ValueRules.line_note(site)}",
						)
					}
				}
				Builtin(number, properties) => {
					if Heap.has_property(properties, key) {
						{ machine: machine, value: Heap.property_value(properties, key) }
					} else {
						ValueRules.fault_got(
							machine,
							"unsupported: `${Heap.native_name(number)}.${key}`${ValueRules.line_note(site)}",
						)
					}
				}
				Fun(_) => ValueRules.fault_got(
					machine,
					"unsupported: a function's properties (`${key}`)${ValueRules.line_note(site)}",
				)
				TimerHandle(_) => ValueRules.fault_got(
					machine,
					"unsupported: a timer's properties (`${key}`)${ValueRules.line_note(site)}",
				)
				MapOf(_) as cell => ValueRules.collection_property(machine, IsMap, Heap.table_of(cell), key, site)
				SetOf(_) as cell => ValueRules.collection_property(machine, IsSet, Heap.table_of(cell), key, site)
				Iteration(_) => ValueRules.fault_got(
					machine,
					"unsupported: an iterator's properties and methods (`${key}`)${ValueRules.line_note(site)}",
				)
				UnreadyVariable | Variable(_) | Environment(_) | Freed(_) => crash "ValueRules.property: no JavaScript value refers to a VM box, an environment or a freed cell"
				Failure(name, message) => match key {
					"name" => { machine: machine, value: Text(Heap.error_name_text(name)) }
					"message" => { machine: machine, value: Text(message) }
					_ => {
						if key == "stack" or ValueRules.is_prototype_name(key) {
							ValueRules.fault_got(
								machine,
								"unsupported: an error's `${key}`${ValueRules.line_note(site)}",
							)
						} else {
							{ machine: machine, value: Undefined }
						}
					}
				}
			}
			Text(text) => {
				if key == "length" {
					if ValueRules.is_ascii(text) {
						{ machine: machine, value: Number(text.count_utf8_bytes().to_f64()) }
					} else {
						ValueRules.fault_got(
							machine,
							"unsupported: the length of a string with non-ASCII text${ValueRules.line_note(site)}",
						)
					}
				} else {
					match Inspect.index_of_key(key) {
						Ok(position) => ValueRules.char_at(machine, text, position, site)
						Err(NotIndex) => ValueRules.fault_got(
							machine,
							"unsupported: the string property `${key}` outside a call${ValueRules.line_note(site)}",
						)
					}
				}
			}
			Null => ValueRules.error_got(
				machine,
				TypeError,
				"Cannot read properties of null (reading '${key}')",
				site,
			)
			Undefined => ValueRules.error_got(
				machine,
				TypeError,
				"Cannot read properties of undefined (reading '${key}')",
				site,
			)
			_ => ValueRules.fault_got(
				machine,
				"unsupported: the property `${key}` of a ${ValueRules.type_of(machine.cells, object)}${ValueRules.line_note(site)}",
			)
		}

	# A Map's or a Set's property: its `size`; a method's name outside a call
	# is refused, since the subset calls a collection's methods by name.
	collection_property : ValueRules.Machine, ValueRules.Collection, Heap.Table, Str, Ast.Where -> ValueRules.Got
	collection_property = |machine, collection, table, key, site|
		if key == "size" {
			{ machine: machine, value: Number(table.size.to_f64()) }
		} else if ValueRules.is_prototype_name(key) or ["get", "set", "add", "has", "delete", "clear", "forEach", "keys", "values", "entries"].contains(key) {
			ValueRules.fault_got(
				machine,
				"unsupported: the ${ValueRules.collection_name(collection)} method `${key}` outside a call${ValueRules.line_note(site)}",
			)
		} else {
			{ machine: machine, value: Undefined }
		}

	is_prototype_name : Str -> Bool
	is_prototype_name = |key| [
		"toString",
		"hasOwnProperty",
		"valueOf",
		"constructor",
		"isPrototypeOf",
		"propertyIsEnumerable",
		"toLocaleString",
		"__proto__",
	].contains(key)

	is_ascii : Str -> Bool
	is_ascii = |text| text.to_utf8().all(|byte| byte < 128)

	char_at : ValueRules.Machine, Str, U64, Ast.Where -> ValueRules.Got
	char_at = |machine, text, position, site|
		if !ValueRules.is_ascii(text) {
			ValueRules.fault_got(
				machine,
				"unsupported: indexing a string with non-ASCII text${ValueRules.line_note(site)}",
			)
		} else {
			match text.to_utf8().get(position) {
				Ok(byte) => {
					machine: machine,
					value: Text(Str.from_utf8([byte]) ?? crash "ValueRules.char_at: an ASCII byte"),
				}
				Err(OutOfBounds) => { machine: machine, value: Undefined }
			}
		}

	indexed_value : ValueRules.Machine, Heap.Value, Heap.Value, Ast.Where -> ValueRules.Got
	indexed_value = |machine, object, key, site|
		match (object, ValueRules.index_of(key)) {
			(Reference(id), Ok(position)) => match Heap.cell_at(machine.cells, id) {
				Array(items) => { machine: machine, value: items.get(position) ?? Undefined }
				_ => ValueRules.property_by_value(machine, object, key, site)
			}
			(Text(text), Ok(position)) => ValueRules.char_at(machine, text, position, site)
			_ => ValueRules.property_by_value(machine, object, key, site)
		}

	property_by_value : ValueRules.Machine, Heap.Value, Heap.Value, Ast.Where -> ValueRules.Got
	property_by_value = |machine, object, key, site|
		match ValueRules.key_of(key) {
			Ok(key_value) => ValueRules.property(machine, object, key_value, site)
			Err(Unsupported(why)) => ValueRules.fault_got(machine, "${why}${ValueRules.line_note(site)}")
		}

	# What a cell is, and an array's length, with nothing of the cell kept.
	#
	# **A WRITER ASKS THIS, NEVER `Heap.cell_at`.** A cell matched out of the
	# heap is a second reference to its props or items for as long as the
	# match's arm runs, so a write made inside that arm copies them: every
	# store into an array of N items copied the N items. These answers hold
	# nothing of the heap.
	Kind : [ObjectKind, ArrayKind(U64), FunctionKind, BuiltinKind, ErrorKind, MapKind, SetKind, IteratorKind]

	kind_of : List(Heap.Cell), U64 -> ValueRules.Kind
	kind_of = |cells, id|
		match Heap.cell_at(cells, id) {
			Object(_) | Instance(_, _) => ObjectKind
			Array(items) => ArrayKind(items.len())
			Fun(_) => FunctionKind
			Builtin(_, _) => BuiltinKind
			Namespace(_, _) => BuiltinKind
			TimerHandle(_) => BuiltinKind
			Failure(_, _) => ErrorKind
			MapOf(_) => MapKind
			SetOf(_) => SetKind
			Iteration(_) => IteratorKind
			UnreadyVariable | Variable(_) | Environment(_) | Freed(_) => crash "ValueRules.kind_of: no JavaScript value refers to a VM box, an environment or a freed cell"
		}

	## A Map or a Set, for what their methods share.
	Collection : [IsMap, IsSet]

	collection_name : ValueRules.Collection -> Str
	collection_name = |collection| match collection {
		IsMap => "Map"
		IsSet => "Set"
	}

	# A property or an item written: an object's property, an array's item
	# inside it or at its end.
	with_stored : ValueRules.Machine, Heap.Value, Heap.Value, Heap.Value, Ast.Where -> ValueRules.Got
	with_stored = |machine, object, key, value, site|
		if !ValueRules.is_running(machine) {
			{ machine: machine, value: value }
		} else {
			match object {
				Reference(id) => match ValueRules.kind_of(machine.cells, id) {
					ObjectKind => match ValueRules.key_of(key) {
						Ok(key_value) => {
							machine: {
								..machine,
								cells: Heap.with_property(machine.cells, id, key_value, value),
							},
							value: value,
						}
						Err(Unsupported(why)) => ValueRules.fault_got(
							machine,
							"${why}${ValueRules.line_note(site)}",
						)
					}
					ArrayKind(length) => {
						match ValueRules.index_of(key) {
							Ok(position) if position <= length => {
								machine: {
									..machine,
									cells: Heap.with_item(machine.cells, id, position, value),
								},
								value: value,
							}
							Ok(_) => ValueRules.fault_got(
								machine,
								"unsupported: an array with holes (a write past its end)${ValueRules.line_note(site)}",
							)
							Err(NotIndex) => ValueRules.fault_got(
								machine,
								"unsupported: writing an array's `length` or a named property${ValueRules.line_note(site)}",
							)
						}
					}
					ErrorKind => ValueRules.fault_got(
						machine,
						"unsupported: writing a property of an error${ValueRules.line_note(site)}",
					)
					MapKind | SetKind => ValueRules.fault_got(
						machine,
						"unsupported: writing a property of a Map or a Set (use its methods)${ValueRules.line_note(site)}",
					)
					_ => ValueRules.fault_got(
						machine,
						"unsupported: writing a property of a function or a builtin${ValueRules.line_note(site)}",
					)
				}
				Null | Undefined => {
					nothing = if object == Null {
						"null"
					} else {
						"undefined"
					}
					setting = match ValueRules.key_of(key) {
						Ok(text) => " (setting '${text}')"
						Err(_) => ""
					}
					ValueRules.error_got(
						machine,
						TypeError,
						"Cannot set properties of ${nothing}${setting}",
						site,
					)
				}
				_ => ValueRules.fault_got(
					machine,
					"unsupported: writing a property of a ${ValueRules.type_of(machine.cells, object)}${ValueRules.line_note(site)}",
				)
			}
		}
}
