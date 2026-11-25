## This module holds JavaScript's builtins as the subset has them, which
## the VM (`Vm`) calls by name: the globals a program starts with and their
## cells (`globals`), what `new` makes (`constructed`), and what each builtin
## that makes no effect and calls nothing back gives (`native_called`), each
## refusal in its words, read and audited here as the builtins' one home.
## The builtins that make an effect or call back (`console.log`, the
## canvas's, the timers, `Array.from` with a mapper) the VM runs itself.
##
## A builtin follows ValueRules' rules (its module doc): it takes the machine
## the VM lends it first, then the rest, and answers a `ValueRules.Got`.
import Ast
import CollectionRules
import Heap
import Inspect
import ValueRules

BuiltinRules :: [].{
	# What `new` makes: an error, from `Error` and its kin, or a Map or a
	# Set, the subset's constructors. `new` on a function of the program would need its
	# prototype, which the subset leaves out.
	constructed : ValueRules.Machine, Heap.Value, Ast.Expression, List(Heap.Value), Ast.Where -> ValueRules.Got
	constructed = |machine, maker, callee, arguments, site|
		if !ValueRules.is_running(machine) {
			{ machine: machine, value: Undefined }
		} else {
			made = match maker {
				Reference(id) => match Heap.cell_at(machine.cells, id) {
					Builtin(MakeError(name), _) => Errors(name)
					Builtin(MakeMap, _) => Collected(IsMap)
					Builtin(MakeSet, _) => Collected(IsSet)
					Fun(_) => Program
					_ => Nothing
				}
				_ => Nothing
			}
			match made {
				Errors(name) => BuiltinRules.error_made(machine, name, arguments, site)
				Collected(collection) => CollectionRules.collection_made(machine, collection, arguments, site)
				Program => ValueRules.fault_got(
					machine,
					"unsupported: `new` on a function of the program (constructors and prototypes)${ValueRules.line_note(site)}",
				)
				Nothing => ValueRules.error_got(
					machine,
					TypeError,
					"${ValueRules.source_text(callee)} is not a constructor",
					site,
				)
			}
		}

	# `new Error(message)` and its kin: the message the text of what is given,
	# or none.
	error_made : ValueRules.Machine, Heap.ErrorName, List(Heap.Value), Ast.Where -> ValueRules.Got
	error_made = |machine, name, arguments, site| {
		message = match arguments.first() {
			Ok(Undefined) | Err(ListWasEmpty) => Ok("")
			Ok(given) => ValueRules.text_of(machine.cells, given)
		}
		match message {
			Ok(text) => ValueRules.alloc(machine, Failure(name, text))
			Err(Unsupported(why)) => ValueRules.fault_got(machine, "${why}${ValueRules.line_note(site)}")
		}
	}

	number_argument : List(Heap.Value), U64 -> Try(F64, [NotNumber])
	number_argument = |arguments, position|
		match arguments.get(position) {
			Ok(Number(number)) => Ok(number)
			_ => Err(NotNumber)
		}

	math : ValueRules.Machine, Str, List(Heap.Value), (F64 -> F64), Ast.Where -> ValueRules.Got
	math = |machine, name, arguments, function, site|
		match BuiltinRules.number_argument(arguments, 0) {
			Ok(number) => { machine: machine, value: Number(function(number)) }
			Err(NotNumber) => ValueRules.fault_got(
				machine,
				"unsupported: Math.${name} of anything but a number${ValueRules.line_note(site)}",
			)
		}

	floor : F64 -> F64
	floor = |number|
		if number.is_nan() or number.is_infinite() or number == 0.0 {
			number
		} else {
			number.div_floor_by(1.0)
		}

	# The values of an object with a whole `length`, as `Array.from` reads
	# them; a number or a boolean has none.
	array_like : List(Heap.Cell), Heap.Value -> Try(List(Heap.Value), [Unsupported(Str)])
	array_like = |cells, source|
		match source {
			Reference(id) => {
				# Any other cell has no `length` to read, so it gives none.
				properties = match Heap.cell_at(cells, id) {
					Object(held) | Instance(_, held) => held
					_ => []
				}
				match Heap.property_value(properties, "length") {
					Number(length) if length >= 0.0 and length.div_trunc_by(1.0) == length and length <= 10000000.0 => {
						count = length.to_u64_try() ?? 0
						var $values = List.with_capacity(count)
						var $i = 0
						while $i < count {
							$values = $values.append(Heap.property_value(properties, $i.to_str()))
							$i = $i + 1
						}
						Ok($values)
					}
					Undefined => Ok([])
					_ => Err(Unsupported("unsupported: `Array.from` of an object whose `length` is not a whole number up to 10,000,000"))
				}
			}
			Number(_) | Boolean(_) => Ok([])
			_ => Err(Unsupported("unsupported: `Array.from` of null or undefined"))
		}

	min_max : ValueRules.Machine, List(Heap.Value), [Min, Max], Ast.Where -> ValueRules.Got
	min_max = |machine, arguments, which, site| {
		var $best = match which {
			Min => 1.0 / 0.0
			Max => -1.0 / 0.0
		}
		var $ok = True
		for argument in arguments {
			match argument {
				Number(x) => {
					$best = if x.is_nan() or $best.is_nan() {
						0.0 / 0.0
					} else {
						match which {
							Min => if x < $best or (x == 0.0 and 1.0 / x < 0.0) {
								x
							} else {
								$best
							}
							Max => if x > $best or (x == 0.0 and 1.0 / x > 0.0 and $best == 0.0) {
								x
							} else {
								$best
							}
						}
					}
				}
				_ => {
					$ok = False
				}
			}
		}
		if $ok {
			{ machine: machine, value: Number($best) }
		} else {
			ValueRules.fault_got(
				machine,
				"unsupported: Math.min or Math.max of anything but numbers${ValueRules.line_note(site)}",
			)
		}
	}

	# Object.keys, Object.values or Object.entries, of an object or an array.
	Listing : [Keys, Values, Entries]

	object_listing : ValueRules.Machine, List(Heap.Value), BuiltinRules.Listing, Ast.Where -> ValueRules.Got
	object_listing = |machine, arguments, which, site| {
		properties = match arguments.first() {
			Ok(Reference(id)) => match Heap.cell_at(machine.cells, id) {
				Object(listed) => Ok(Inspect.properties_in_key_order(listed))
				Instance(_, _) => Err(Unsupported(Inspect.instance_listed))
				Array(items) => {
					var $listed = []
					var $i = 0
					for item in items {
						$listed = $listed.append({ key: $i.to_str(), value: item })
						$i = $i + 1
					}
					Ok($listed)
				}
				_ => Err(NotListed)
			}
			_ => Err(NotListed)
		}
		match properties {
			Ok(listed) => {
				var $s = machine
				var $values = []
				for parent in listed {
					subject = match which {
						Keys => Text(parent.key)
						Values => parent.value
						Entries => {
							{ machine: made, value: pair } = ValueRules.alloc(
								$s,
								Array([Text(parent.key), parent.value]),
							)
							$s = made
							pair
						}
					}
					$values = $values.append(subject)
				}
				ValueRules.alloc($s, Array($values))
			}
			Err(Unsupported(why)) => {
				note = ValueRules.line_note(site)
				ValueRules.fault_got(machine, "${why}${note}")
			}
			Err(NotListed) => ValueRules.fault_got(
				machine,
				"unsupported: Object.keys, values or entries of anything but an object or an array${ValueRules.line_note(site)}",
			)
		}
	}

	## A builtin's answer, for the builtins that make no effect and call
	## nothing back. The VM runs the others itself: `console.log`, the
	## canvas's, the timers, `onClick`, `onCollect`, and `Array.from` with a mapper.
	native_called : ValueRules.Machine, Heap.Native, List(Heap.Value), Ast.Where -> ValueRules.Got
	native_called = |machine, native, arguments, site|
		match native {
			Floor => BuiltinRules.math(machine, "floor", arguments, BuiltinRules.floor, site)
			Ceil => BuiltinRules.math(
				machine,
				"ceil",
				arguments,
				|x| -BuiltinRules.floor(-x),
				site,
			)
			Round => BuiltinRules.math(
				machine,
				"round",
				arguments,
				|x| {
					floored = BuiltinRules.floor(x)
					if x - floored >= 0.5 {
						# Rounding up from (-0.5, 0) gives -0, as JavaScript's does.
						if x < 0.0 and floored == -1.0 {
							-0.0
						} else {
							floored + 1.0
						}
					} else {
						floored
					}
				},
				site,
			)
			Trunc => BuiltinRules.math(
				machine,
				"trunc",
				arguments,
				|x|
					if x.is_nan() or x.is_infinite() {
						x
					} else {
						x.div_trunc_by(1.0)
					},
				site,
			)
			Abs => BuiltinRules.math(
				machine,
				"abs",
				arguments,
				|x| x.abs(),
				site,
			)
			Sign => BuiltinRules.math(
				machine,
				"sign",
				arguments,
				|x|
					if x > 0.0 {
						1.0
					} else if x < 0.0 {
						-1.0
					} else {
						x
					},
				site,
			)
			Sqrt => BuiltinRules.math(
				machine,
				"sqrt",
				arguments,
				|x| x.sqrt(),
				site,
			)
			Sin => BuiltinRules.math(
				machine,
				"sin",
				arguments,
				|x| x.sin(),
				site,
			)
			Cos => BuiltinRules.math(
				machine,
				"cos",
				arguments,
				|x| x.cos(),
				site,
			)
			Tan => BuiltinRules.math(
				machine,
				"tan",
				arguments,
				|x| x.tan(),
				site,
			)
			Atan => BuiltinRules.math(
				machine,
				"atan",
				arguments,
				|x| x.atan(),
				site,
			)
			Pow => match (
				BuiltinRules.number_argument(arguments, 0),
				BuiltinRules.number_argument(arguments, 1),
			) {
				(Ok(x), Ok(y)) => { machine: machine, value: Number(ValueRules.power(x, y)) }
				_ => ValueRules.fault_got(
					machine,
					"unsupported: Math.pow of anything but two numbers${ValueRules.line_note(site)}",
				)
			}
			Min => BuiltinRules.min_max(machine, arguments, Min, site)
			Max => BuiltinRules.min_max(machine, arguments, Max, site)
			Keys => BuiltinRules.object_listing(machine, arguments, Keys, site)
			Values => BuiltinRules.object_listing(machine, arguments, Values, site)
			Entries => BuiltinRules.object_listing(machine, arguments, Entries, site)
			StringOf => match arguments.first() {
				Ok(subject) => match ValueRules.text_of(machine.cells, subject) {
					Ok(phrase) => { machine: machine, value: Text(phrase) }
					Err(Unsupported(why)) => ValueRules.fault_got(
						machine,
						"${why}${ValueRules.line_note(site)}",
					)
				}
				Err(ListWasEmpty) => { machine: machine, value: Text("") }
			}
			FromCharCode => {
				var $bytes = []
				var $ok = True
				for argument in arguments {
					match argument {
						Number(code) if code >= 0.0 and code < 128.0 and code.div_trunc_by(1.0) == code => {
							$bytes = $bytes.append(code.to_u8_try() ?? 0)
						}
						_ => {
							$ok = False
						}
					}
				}
				if $ok {
					{
						machine: machine,
						value: Text(Str.from_utf8($bytes) ?? crash "BuiltinRules.native_called: ASCII bytes"),
					}
				} else {
					ValueRules.fault_got(
						machine,
						"unsupported: String.fromCharCode of anything but ASCII codes${ValueRules.line_note(site)}",
					)
				}
			}
			IsArray => match arguments.first() {
				Ok(Reference(id)) => match Heap.cell_at(machine.cells, id) {
					Array(_) => { machine: machine, value: Boolean(True) }
					_ => { machine: machine, value: Boolean(False) }
				}
				_ => { machine: machine, value: Boolean(False) }
			}
			IsInteger => match arguments.first() {
				Ok(Number(x)) => {
					machine: machine,
					value: Boolean(!x.is_nan() and !x.is_infinite() and x.div_trunc_by(1.0) == x),
				}
				_ => { machine: machine, value: Boolean(False) }
			}
			MakeError(name) => ValueRules.fault_got(
				machine,
				"unsupported: calling `${Heap.error_name_text(name)}` without `new`${ValueRules.line_note(site)}",
			)
			ArrayFrom if !BuiltinRules.is_mapped(arguments) => {
				{ machine: walked, listed } = BuiltinRules.array_from_values(machine, arguments.first() ?? Undefined)
				match listed {
					Ok(values) => ValueRules.alloc(walked, Array(values))
					Err(Unsupported(why)) => ValueRules.fault_got(walked, "${why}${ValueRules.line_note(site)}")
				}
			}
			ArrayOf => ValueRules.alloc(machine, Array(arguments))
			MakeMap | MakeSet => ValueRules.error_got(
				machine,
				TypeError,
				"Constructor ${Heap.native_name(native)} requires 'new'",
				site,
			)
			ArrayFrom | Log | Paint(_) | Move(_) | Sense(_) | Timing(_) | OnClick | OnCollect => crash "BuiltinRules.native_called: the VM runs a builtin that makes an effect or calls back itself"
		}

	# Whether `Array.from` is given a mapper, which the VM calls back.
	is_mapped : List(Heap.Value) -> Bool
	is_mapped = |arguments| match arguments.get(1) {
		Ok(Undefined) | Err(OutOfBounds) => False
		Ok(_) => True
	}

	# `Array.from(source)`'s values: an iterable's, or those of an object with
	# a `length` (`{ length: 3 }`, its properties "0" to "2").
	array_from_values : ValueRules.Machine, Heap.Value -> { machine : ValueRules.Machine, listed : Try(List(Heap.Value), [Unsupported(Str)]) }
	array_from_values = |machine, source| {
		{ machine: walked, values: found } = CollectionRules.iterated(machine, source)
		listed = match found {
			Ok(values) => Ok(values)
			Err(NotIterable) => BuiltinRules.array_like(walked.cells, source)
		}
		{ machine: walked, listed: listed }
	}

	# ---- the builtins --------------------------------------------------------

	## The builtins of `library`, made in `cells`: the cells after, and each
	## builtin's value in the order `Resolve` places them
	## (`Ast.global_names_of`), which the VM's outermost frame holds.
	globals : List(Heap.Cell), Ast.Library -> { cells : List(Heap.Cell), values : List(Heap.Value) }
	globals = |cells, library| {
		var $s = { cells: cells, free: NoneFree, status: Running }
		log = ValueRules.alloc($s, Builtin(Log, []))
		$s = log.machine
		console = ValueRules.alloc($s, Namespace("console", [{ key: "log", value: log.value }]))
		$s = console.machine
		var $math_properties = [
			{ key: "PI", value: Number(3.141592653589793) },
			{ key: "E", value: Number(2.718281828459045) },
		]
		for native in [
			Floor,
			Ceil,
			Round,
			Trunc,
			Abs,
			Sign,
			Sqrt,
			Pow,
			Min,
			Max,
			Sin,
			Cos,
			Tan,
			Atan,
		] {
			made = ValueRules.alloc($s, Builtin(native, []))
			$s = made.machine
			$math_properties = $math_properties.append({
				key: Heap.native_name(native),
				value: made.value,
			})
		}
		math_object = ValueRules.alloc($s, Namespace("Math", $math_properties))
		$s = math_object.machine
		var $object_properties = []
		for native in [Keys, Values, Entries] {
			made = ValueRules.alloc($s, Builtin(native, []))
			$s = made.machine
			$object_properties = $object_properties.append({
				key: Heap.native_name(native),
				value: made.value,
			})
		}
		object = ValueRules.alloc($s, Namespace("Object", $object_properties))
		$s = object.machine
		from_char_code = ValueRules.alloc($s, Builtin(FromCharCode, []))
		$s = from_char_code.machine
		string = ValueRules.alloc(
			$s,
			Builtin(StringOf, [{ key: "fromCharCode", value: from_char_code.value }]),
		)
		$s = string.machine
		var $array_properties = []
		for native in [IsArray, ArrayFrom, ArrayOf] {
			made = ValueRules.alloc($s, Builtin(native, []))
			$s = made.machine
			$array_properties = $array_properties.append({
				key: Heap.native_name(native),
				value: made.value,
			})
		}
		array = ValueRules.alloc($s, Namespace("Array", $array_properties))
		$s = array.machine
		is_integer = ValueRules.alloc($s, Builtin(IsInteger, []))
		$s = is_integer.machine
		number = ValueRules.alloc(
			$s,
			Namespace(
				"Number",
				[
					{ key: "isInteger", value: is_integer.value },
					{ key: "MAX_SAFE_INTEGER", value: Number(9007199254740991.0) },
				],
			),
		)
		$s = number.machine
		var $made = [
			{ name: "console", value: console.value },
			{ name: "Math", value: math_object.value },
			{ name: "Object", value: object.value },
			{ name: "String", value: string.value },
			{ name: "Array", value: array.value },
			{ name: "Number", value: number.value },
			{ name: "NaN", value: Number(0.0 / 0.0) },
			{ name: "Infinity", value: Number(1.0 / 0.0) },
		]
		for native in [
			Timing(SetTimeout),
			Timing(SetInterval),
			Timing(ClearTimeout),
			Timing(ClearInterval),
		] {
			timer_builtin = ValueRules.alloc($s, Builtin(native, []))
			$s = timer_builtin.machine
			$made = $made.append({ name: Heap.native_name(native), value: timer_builtin.value })
		}
		for name in [Error, TypeError, RangeError, ReferenceError, SyntaxError] {
			maker = ValueRules.alloc($s, Builtin(MakeError(name), []))
			$s = maker.machine
			$made = $made.append({ name: Heap.error_name_text(name), value: maker.value })
		}
		for native in [MakeMap, MakeSet] {
			maker = ValueRules.alloc($s, Builtin(native, []))
			$s = maker.machine
			$made = $made.append({ name: Heap.native_name(native), value: maker.value })
		}
		match library {
			Core => {}
			Canvas => {
				for native in BuiltinRules.canvas_natives {
					canvas_builtin = ValueRules.alloc($s, Builtin(native, []))
					$s = canvas_builtin.machine
					$made = $made.append({
						name: Heap.native_name(native),
						value: canvas_builtin.value,
					})
				}
			}
		}
		made = $made
		values = Ast.global_names_of(library).map(
			|name| (made.find_first(|g| g.name == name) ?? crash "BuiltinRules.globals: a builtin Ast.global_names_of names").value,
		)
		{ cells: $s.cells, values: values }
	}

	# The canvas library's builtins.
	canvas_natives : List(Heap.Native)
	canvas_natives = [
		Paint(Background),
		Paint(Fill),
		Paint(NoFill),
		Paint(Stroke),
		Paint(NoStroke),
		Paint(Line),
		Paint(Rect),
		Paint(Circle),
		Paint(Ellipse),
		Paint(Polygon),
		Paint(Words),
		Move(Forward),
		Move(Back),
		Move(Turn),
		Move(PenUp),
		Move(PenDown),
		Move(Goto),
		Sense(MouseX),
		Sense(MouseY),
		Sense(KeyIsDown),
		OnClick,
		OnCollect,
	]
}
