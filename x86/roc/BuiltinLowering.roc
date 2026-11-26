## This module lowers what the x86-64 compiler knows of JavaScript's
## builtins: `console.log` of the stack's top values, a global builtin read
## (`console`, `NaN`, `Infinity`, the error classes, `Map` and `Set`, the
## timers, the static objects), node's throws for a constant assigned and
## for a variable used before its declaration has run, the methods of
## arrays, strings, iterators, `Map` and `Set` (`array_method_items`), a
## `+=` that isn't of numbers (`appended_items`), the static objects'
## properties and functions (`Math`, `Object`, `String`, `Array`), the
## timers' calls, and `new` of an error class.
##
## **`Math.floor`, `Math.ceil` AND `Math.trunc` ARE IN LINE.** Each is
## otherwise a call of its routine (LanguageRoutines' `truncated_items`).
## In line (`rounded_items`), the number is truncated to a 64-bit integer
## (`cvttsd2si`); an infinity, a NaN and a number of 2^63 or more in size
## give the integer -2^63, which `cmp` with 1 finds by its overflow, and
## those take the routine. A double below 2^63 in size truncates exactly,
## and one of 2^52 or more is whole already, so its truncation is itself.
## `floor` takes 1 from the truncation when the number is below it, and
## `ceil` adds 1 when the number is above it (`ucomisd` and `setb`, with no
## jump). The answer is made a double and the number's sign bit or-ed in: a
## negative number's floor, ceiling or truncation is negative or -0, and a
## positive one's is not negative, so the or changes only a 0 to the -0
## JavaScript gives (`Math.ceil(-0.5)`, `Math.trunc(-0)`).
## x86/tests/math-rounding.js holds the three to node.
##
## It stands apart from Lowering because each builtin is a family read
## whole beside the runtime routines it calls, and none of them needs the
## walk: Lowering's dispatch hands each its site and state, and takes back
## what it lowered.
import js.Ast
import js.ValueRules
import Assembly
import Boxing
import Emit
import LoweringBasics
import Runtime
import X86

BuiltinLowering :: [].{

	## `console.log` of the values on top of the stack: each written as node
	## writes it, a space between, then a newline.
	log_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		count : U64,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	log_items = |site, { state, count }| {
		base = state.stack_kinds.len() - count
		var $items = []
		for argument in 0..<count {
			if argument > 0 {
				$items = $items.concat(Runtime.text_items(Space))
			}
			place = LoweringBasics.stack_place(site.code, base + argument)
			written = match LoweringBasics.kind_below(state, count - 1 - argument) {
				Number => [
					Instruction(MovRegMem({ to: Rax, from: place })),
					CallTo(Runtime.print_number),
				]
				kind if LoweringBasics.is_value_kind(kind) => [
					Instruction(MovRegMem({ to: Rdi, from: place })),
					CallTo(Runtime.write_value),
				]
				kind => return LoweringBasics.refusal(
					site,
					"console.log of ${LoweringBasics.kind_phrase(kind)} is not compiled yet",
				)
			}
			$items = $items.concat(written)
		}
		$items = $items.concat(Runtime.text_items(Newline))
		Ok(
			LoweringBasics.falling(
				$items,
				LoweringBasics.with_top(LoweringBasics.without_top(state, count + 2), Undefined),
			),
		)
	}

	## A builtin read: `console`, `NaN` and `Infinity`, and no other yet.
	builtin_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		place : U64,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	builtin_items = |site, { state, place }| {
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len())
		match Ast.global_names_of(Core).get(place) {
			Ok("console") => Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Console)))
			Ok("NaN") => Ok(
				LoweringBasics.falling(
					LoweringBasics.constant_items({ bits: 0x7FF8000000000000, to: top }),
					LoweringBasics.with_top(state, Number),
				),
			)
			Ok("Infinity") => Ok(
				LoweringBasics.falling(
					LoweringBasics.constant_items({ bits: 0x7FF0000000000000, to: top }),
					LoweringBasics.with_top(state, Number),
				),
			)
			Ok(name) if error_names.contains(name) => Ok(
				LoweringBasics.falling([], LoweringBasics.with_top(state, ErrorClass(name))),
			)
			Ok(name) if name == "Map" or name == "Set" =>
				Ok(
					LoweringBasics.falling(
						[],
						LoweringBasics.with_top(state, CollectionClass(name)),
					),
				)
			Ok(name) if timer_names.contains(name) => Ok(
				LoweringBasics.falling([], LoweringBasics.with_top(state, TimerFunction(name))),
			)
			Ok(name) if static_names.contains(name) => Ok(
				LoweringBasics.falling([], LoweringBasics.with_top(state, Static(name))),
			)
			Ok(name) => LoweringBasics.refusal(site, "the builtin `${name}` is not compiled yet")
			Err(_) => crash "BuiltinLowering.builtin_items: a builtin's place"
		}
	}

	## node's TypeError for a constant assigned or stepped, thrown.
	constant_assigned_items : LoweringBasics.Lowered
	constant_assigned_items = {
		statements: [
			Emit.address_of(Rsi, Runtime.constant_assigned_text),
			Emit.address_of(Rdi, Runtime.error_name_label("TypeError")),
			Emit.call(Runtime.new_error),
			Emit.jmp(Runtime.throw),
		],
		falls: Ends,
		branch: NoBranch,
		result: GivesNothing,
	}

	## node's ReferenceError for a variable read or written before its
	## declaration has run, thrown.
	unready_items : LoweringBasics.Site, Str -> LoweringBasics.Lowered
	unready_items = |site, name| {
		statements: [
			Emit.address_of(Rsi, LoweringBasics.text_label(site, ValueRules.unready_message(name))),
			Emit.address_of(Rdi, Runtime.error_name_label("ReferenceError")),
			Emit.call(Runtime.new_error),
			Emit.jmp(Runtime.throw),
		],
		falls: Ends,
		branch: NoBranch,
		result: GivesNothing,
	}

	## The methods of an array compiled here.
	array_methods : List(Str)
	array_methods = [
		"push",
		"pop",
		"map",
		"filter",
		"forEach",
		"reduce",
		"join",
		"slice",
		"concat",
		"some",
		"every",
		"find",
		"findIndex",
		"indexOf",
		"includes",
		"sort",
		"reverse",
		"splice",
		"lastIndexOf",
		"shift",
		"unshift",
	]

	## The methods of a Map or a Set compiled here, by their numbers in
	## `Runtime.collection_method`: those that walk it last, an array's too.
	collection_methods : List(Str)
	collection_methods = ["get", "set", "has", "delete", "clear", "add"].concat(iterator_methods)

	## The methods that give an iterator, of an array, a Map or a Set.
	iterator_methods : List(Str)
	iterator_methods = ["keys", "values", "entries"]

	## The methods of a string compiled here.
	string_methods : List(Str)
	string_methods = [
		"charAt",
		"charCodeAt",
		"indexOf",
		"includes",
		"split",
		"slice",
		"lastIndexOf",
	]

	## An array's `push` of each argument in turn, its answer the length
	## after the last, its `pop`, its `map`, `filter`, `forEach` and `reduce`
	## of a function, its `join` and `slice`, or a string's `charAt`: the
	## receiver lies below the method looked up, and the answer takes its
	## place.
	array_method_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		name : Str,
		count : U64,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	array_method_items = |site, { state, name, count }| {
		receiver = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - count - 2)
		base = state.stack_kinds.len() - count
		argument = |at| LoweringBasics.stack_place(site.code, base + at)
		after = |kind| LoweringBasics.with_top(LoweringBasics.without_top(state, count + 2), kind)
		match (name, count) {
			("push", given) if given > 0 => {
				var $pushed = []
				for item in 0..<given {
					$pushed = $pushed.concat([
						Emit.load(Rdi, receiver),
						Emit.load(Rsi, LoweringBasics.stack_place(site.code, base + item)),
						Emit.call(Runtime.push),
					])
				}
				Ok(LoweringBasics.falling($pushed.append(Emit.store(receiver, Rax)), after(Number)))
			}
			("pop", 0) =>
				Ok(
					LoweringBasics.falling(
						[
							Emit.load(Rdi, receiver),
							Emit.call(Runtime.pop),
							Emit.store(receiver, Rax),
						],
						after(Value),
					),
				)
			("map", 1) | ("filter", 1) | ("forEach", 1) => {
				(routine, kind) = match name {
					"map" => (Runtime.map, Array)
					"filter" => (Runtime.filter, Array)
					_ => (Runtime.for_each, Undefined)
				}
				called = [
					Emit.load(Rdi, receiver),
					Emit.load(Rsi, argument(0)),
					Emit.call(routine),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(kind)))
			}
			("reduce", 1) | ("reduce", 2) | ("slice", 0) | ("slice", 1) | ("slice", 2) => {
				var $loaded = []
				for (at, reg) in [(0, Rsi), (1, Rdx)].take_first(count) {
					$loaded = $loaded.append(Emit.load(reg, argument(at)))
				}
				# A slice of a string is a string, of an array an array.
				(routine, kind) = match (name, LoweringBasics.kind_below(state, count + 1)) {
					("reduce", _) => (Runtime.reduce, Value)
					(_, String) => (Runtime.slice, String)
					(_, Array) => (Runtime.slice, Array)
					_ => (Runtime.slice, Value)
				}
				called = [Emit.load(Rdi, receiver)]
					.concat($loaded)
					.concat([
						Emit.imm(Rcx, count.to_i64_wrap()),
						Emit.call(routine),
						Emit.store(receiver, Rax),
					])
				Ok(LoweringBasics.falling(called, after(kind)))
			}
			("join", 0) | ("join", 1) => {
				separator =
					if count == 0 {
						[Emit.address_of(Rsi, Runtime.comma_text)]
					} else if LoweringBasics.kind_below(state, 0) == String {
						[
							Emit.load(Rsi, argument(0)),
							Emit.shl(Rsi, 16),
							Emit.shr(Rsi, 16),
						]
					} else {
						return LoweringBasics.refusal(
							site,
							"`join` with a separator that is not a string",
						)
					}
				called = [Emit.load(Rdi, receiver)]
					.concat(separator)
					.concat([Emit.call(Runtime.join), Emit.store(receiver, Rax)])
				Ok(LoweringBasics.falling(called, after(String)))
			}
			("some", 1) | ("every", 1) | ("find", 1) | ("findIndex", 1) => {
				(searched, kind) = match name {
					"some" => (0, Boolean)
					"every" => (1, Boolean)
					"find" => (2, Value)
					_ => (3, Number)
				}
				called = [
					Emit.load(Rdi, receiver),
					Emit.load(Rsi, argument(0)),
					Emit.imm(Rdx, searched),
					Emit.call(Runtime.search),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(kind)))
			}
			("indexOf", 1) | ("indexOf", 2) | ("includes", 1) | ("includes", 2) => {
				(sought, kind) = if name == "indexOf" {
					(0, Number)
				} else {
					(1, Boolean)
				}
				from = if count == 2 {
					[Emit.load(Rdx, argument(1))]
				} else {
					[]
				}
				called = [Emit.load(Rdi, receiver), Emit.load(Rsi, argument(0))]
					.concat(from)
					.concat([
						Emit.imm(Rcx, count.to_i64_wrap()),
						Emit.imm(R8, sought),
						Emit.call(Runtime.index_of),
						Emit.store(receiver, Rax),
					])
				Ok(LoweringBasics.falling(called, after(kind)))
			}
			("concat", _) => {
				var $made = [
					Emit.load(Rdi, receiver),
					Emit.zero(Rcx),
					Emit.call(Runtime.slice),
					Emit.store(receiver, Rax),
				]
				for at in 0..<count {
					$made = $made.concat([
						Emit.load(Rdi, receiver),
						Emit.shl(Rdi, 16),
						Emit.shr(Rdi, 16),
						Emit.load(Rsi, argument(at)),
						Emit.call(Runtime.concat_item),
					])
				}
				Ok(LoweringBasics.falling($made, after(Array)))
			}
			("sort", 0) | ("sort", 1) | ("reverse", 0) => {
				(routine, compared) =
					if name == "reverse" {
						(Runtime.reverse, [])
					} else if count == 1 {
						(Runtime.sort, [Emit.load(Rsi, argument(0))])
					} else {
						(Runtime.sort, [Emit.imm(Rsi, Boxing.undefined_bits)])
					}
				called = [Emit.load(Rdi, receiver)]
					.concat(compared)
					.concat([Emit.call(routine), Emit.store(receiver, Rax)])
				Ok(LoweringBasics.falling(called, after(Array)))
			}
			("charCodeAt", 0) | ("charCodeAt", 1) => {
				place = if count == 1 {
					Emit.load(Rsi, argument(0))
				} else {
					Emit.zero(Rsi)
				}
				called = [
					Emit.load(Rdi, receiver),
					place,
					Emit.call(Runtime.char_code_at),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(Number)))
			}
			("split", 1) => {
				called = [
					Emit.load(Rdi, receiver),
					Emit.load(Rsi, argument(0)),
					Emit.call(Runtime.split),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(Array)))
			}
			(_, _) if collection_methods.contains(name) => {
				numbered = collection_methods.find_first_index(|known| known == name)
				number = numbered ?? crash "BuiltinLowering.array_method_items: a method's number"
				called = LoweringBasics.arguments_array_items(site, { base, count })
					.concat([
						Emit.mov(Rdx, Rax),
						Emit.load(Rdi, receiver),
						Emit.address_of(Rsi, LoweringBasics.text_label(site, name)),
						Emit.imm(Rcx, number.to_i64_wrap()),
						Emit.call(Runtime.collection_method),
						Emit.store(receiver, Rax),
					])
				Ok(LoweringBasics.falling(called, after(Value)))
			}
			("splice", _) => {
				called = LoweringBasics.arguments_array_items(site, { base, count })
					.concat([
						Emit.mov(Rsi, Rax),
						Emit.load(Rdi, receiver),
						Emit.call(Runtime.splice),
						Emit.store(receiver, Rax),
					])
				Ok(LoweringBasics.falling(called, after(Array)))
			}
			# `shift` and `unshift` as splices at the start: `splice(0, 1)`'s
			# item, and `splice(0, 0, ...items)` then the length.
			("shift", 0) => {
				called = [
					Emit.imm(Rdi, 2),
					Emit.call(Runtime.new_array),
					Emit.zero(Rcx),
					Emit.store(Emit.mem(Rdx, 0), Rcx),
					Emit.imm(Rcx, 0x3FF0000000000000),
					Emit.store(Emit.mem(Rdx, 8), Rcx),
					Emit.mov(Rsi, Rax),
					Emit.load(Rdi, receiver),
					Emit.call(Runtime.splice),
					Emit.mov(Rdi, Rax),
					Emit.zero(Rsi),
					Emit.call(Runtime.get_index),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(Value)))
			}
			("unshift", _) => {
				var $filled = [
					Emit.imm(Rdi, (count + 2).to_i64_wrap()),
					Emit.call(Runtime.new_array),
					Emit.zero(Rcx),
					Emit.store(Emit.mem(Rdx, 0), Rcx),
					Emit.store(Emit.mem(Rdx, 8), Rcx),
				]
				for item in 0..<count {
					$filled = $filled.concat([
						Emit.load(Rcx, argument(item)),
						Emit.store(Emit.mem(Rdx, (16 + 8 * item).to_i64_wrap()), Rcx),
					])
				}
				called = $filled.concat([
					Emit.mov(Rsi, Rax),
					Emit.load(Rdi, receiver),
					Emit.call(Runtime.splice),
					Emit.load(Rdi, receiver),
					Emit.shl(Rdi, 16),
					Emit.shr(Rdi, 16),
					Emit.load(Rax, Emit.mem(Rdi, 0)),
					Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
					Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
					Emit.store(receiver, Rax),
				])
				Ok(LoweringBasics.falling(called, after(Number)))
			}
			("lastIndexOf", 1) => {
				called = [
					Emit.load(Rdi, receiver),
					Emit.load(Rsi, argument(0)),
					Emit.call(Runtime.last_index_of),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(Number)))
			}
			("charAt", 1) => {
				called = [
					Emit.load(Rdi, receiver),
					Emit.load(Rsi, argument(0)),
					Emit.call(Runtime.char_at),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(String)))
			}
			_ => {
				given = LoweringBasics.count_text(count, "argument")
				LoweringBasics.refusal(site, "`${name}` with ${given} is not compiled yet")
			}
		}
	}

	## `s += e` where either isn't a number: `runtime_add` of the two, stored
	## in the slot and left on the stack.
	appended_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
		held : LoweringBasics.Kind,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	appended_items = |site, { state, slot, held }| {
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		kind = match LoweringBasics.added_kind((held, LoweringBasics.kind_below(state, 0))) {
			Ok(added) => added
			Err(Unadded) => {
				first = LoweringBasics.kind_phrase(held)
				second = LoweringBasics.kind_phrase(LoweringBasics.kind_below(state, 0))
				return LoweringBasics.refusal(site, "`+=` of ${first} and ${second}")
			}
		}
		slots = state.slots.set(
			slot,
			Ready(kind),
		) ?? crash "BuiltinLowering.appended_items: a slot of the frame"
		Ok(
			LoweringBasics.falling(
				[
					Emit.load(Rdi, LoweringBasics.slot_place(slot)),
					Emit.load(Rsi, top),
					Emit.call(Runtime.add),
					Emit.store(LoweringBasics.slot_place(slot), Rax),
					Emit.store(top, Rax),
				],
				LoweringBasics.with_top(LoweringBasics.without_top({ ..state, slots }, 1), kind),
			),
		)
	}

	## The builtins that are objects of functions: `Math`, `Object`, and
	## `String`, which is a function too.
	static_names : List(Str)
	static_names = ["Math", "Object", "String", "Array"]

	## `Date`, which the front end declares nowhere (the VM has none), read
	## where its property follows: `Date.now()` is compiled, and every other
	## use of it refused, so a program that runs here runs alike in node.
	date_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	date_items = |site, { state }|
		match site.code.ops.get(site.at + 1) {
			Ok(MethodLookup(_, _)) | Ok(GetProperty(_, _)) =>
				Ok(LoweringBasics.falling([], LoweringBasics.with_top(state, Static("Date"))))
			_ => LoweringBasics.refusal(site, "`Date` is compiled only as `Date.now()`")
		}

	## The functions a builtin object holds, compiled or refused by name when
	## called.
	static_members : Str -> List(Str)
	static_members = |owner|
		match owner {
			"Math" => Runtime.math_functions.concat(["pow", "sin", "cos", "tan", "atan"])
			"Object" => ["keys", "values", "entries"]
			"String" => ["fromCharCode"]
			"Array" => ["isArray", "from", "of"]
			"Date" => ["now"]
			_ => []
		}

	## A property of a builtin object read: `Math.PI` and `Math.E`, or one of
	## its functions, which takes no bytes (`typeof Math.floor`).
	static_property_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		owner : Str,
		key : Str,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	static_property_items = |site, { state, owner, key }| {
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		numbered = LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Number)
		constant = |bits| Ok(
			LoweringBasics.falling(LoweringBasics.constant_items({ bits, to: top }), numbered),
		)
		match (owner, key) {
			# The doubles nearest pi and e.
			("Math", "PI") => constant(0x400921FB54442D18)
			("Math", "E") => constant(0x4005BF0A8B145769)
			("Date", _) if key != "now" => LoweringBasics.refusal(
				site,
				"`Date.${key}` is not compiled yet: of `Date`, only `Date.now()` is",
			)
			_ if static_members(owner).contains(key) =>
				Ok(
					LoweringBasics.falling(
						[],
						LoweringBasics.with_top(
							LoweringBasics.without_top(state, 1),
							StaticMethod({ owner, name: key }),
						),
					),
				)
			_ => LoweringBasics.refusal(
				site,
				"the property `${key}` of `${owner}` is not compiled yet",
			)
		}
	}

	## A call of a builtin object's function: `Math`'s of numbers, `max` and
	## `min` of any count of them, `pow` as `**`; `Object.keys`, `values` and
	## `entries`. The answer takes the place of the builtin below the function.
	static_call_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		count : U64,
		owner : Str,
		name : Str,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	static_call_items = |site, { state, count, owner, name }| {
		receiver = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - count - 2)
		base = state.stack_kinds.len() - count
		after = |kind| LoweringBasics.with_top(LoweringBasics.without_top(state, count + 2), kind)
		# Argument `at` checked a number, in `reg`.
		number_in = |{ at, reg }| {
			kind = LoweringBasics.kind_below(state, count - 1 - at)
			place = LoweringBasics.stack_place(site.code, base + at)
			if LoweringBasics.is_value_kind(kind) {
				Ok(LoweringBasics.number_check_items({ kind, place }).append(Emit.load(reg, place)))
			} else {
				LoweringBasics.refusal(
					site,
					"`${owner}.${name}` of ${LoweringBasics.kind_phrase(kind)}",
				)
			}
		}
		match (owner, name) {
			("Math", "max") | ("Math", "min") => {
				start = if name == "max" {
					0xFFF0000000000000
				} else {
					0x7FF0000000000000
				}
				var $items = LoweringBasics.constant_items({ bits: start, to: receiver })
				for at in 0..<count {
					$items = $items
						.concat(number_in({ at, reg: Rsi })?)
						.concat([
							Emit.load(Rdi, receiver),
							Emit.call(Runtime.math_routine(name)),
							Emit.store(receiver, Rax),
						])
				}
				Ok(LoweringBasics.falling($items, after(Number)))
			}
			("Math", "pow") if count >= 2 => {
				base_loaded = number_in({ at: 0, reg: Rdi })?
				loaded = base_loaded.concat(number_in({ at: 1, reg: Rsi })?)
				called = [Emit.call(Runtime.power), Emit.store(receiver, Rax)]
				Ok(LoweringBasics.falling(loaded.concat(called), after(Number)))
			}
			("Math", "floor") | ("Math", "ceil") | ("Math", "trunc") if count >= 1 => {
				loaded = number_in({ at: 0, reg: Rdi })?
				called = [Emit.call(Runtime.math_routine(name)), Emit.store(receiver, Rax)]
				rounded = rounded_items(site, { name, receiver, slow_items: called })
				Ok(LoweringBasics.falling(loaded.concat(rounded), after(Number)))
			}
			("Math", _) if Runtime.math_functions.contains(name) =>
				if count == 0 {
					not_a_number = LoweringBasics.constant_items({
						bits: 0x7FF8000000000000,
						to: receiver,
					})
					Ok(LoweringBasics.falling(not_a_number, after(Number)))
				} else {
					loaded = number_in({ at: 0, reg: Rdi })?
					called = [Emit.call(Runtime.math_routine(name)), Emit.store(receiver, Rax)]
					Ok(LoweringBasics.falling(loaded.concat(called), after(Number)))
				}
			("Array", "isArray") => {
				tested =
					if count == 0 {
						[Emit.imm(Rax, Boxing.false_bits)]
					} else {
						[
							Emit.load(Rax, LoweringBasics.stack_place(site.code, base)),
							Emit.shr(Rax, Boxing.tag_shift),
							Emit.cmp_imm(Rax, Boxing.array_tag),
							Instruction(Setcc({ condition: E, to: Al })),
						].concat(LoweringBasics.boolean_items)
					}
				Ok(LoweringBasics.falling(tested.append(Emit.store(receiver, Rax)), after(Boolean)))
			}
			("Array", "of") => {
				made = LoweringBasics.arguments_array_items(
					site,
					{ base, count },
				).append(Emit.store(receiver, Rax))
				Ok(LoweringBasics.falling(made, after(Array)))
			}
			("Array", "from") if count == 1 or count == 2 => {
				mapper =
					if count == 2 {
						Emit.load(Rsi, LoweringBasics.stack_place(site.code, base + 1))
					} else {
						Emit.imm(Rsi, Boxing.undefined_bits)
					}
				called = [
					Emit.load(Rdi, LoweringBasics.stack_place(site.code, base)),
					mapper,
					Emit.call(Runtime.array_from),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(Array)))
			}
			# The milliseconds since the epoch, whole; any argument is unread,
			# as in node.
			("Date", "now") => {
				called = [Emit.call(Runtime.date_now), Emit.store(receiver, Rax)]
				Ok(LoweringBasics.falling(called, after(Number)))
			}
			("String", "fromCharCode") => {
				called = LoweringBasics.arguments_array_items(site, { base, count })
					.concat([
						Emit.mov(Rdi, Rax),
						Emit.call(Runtime.from_char_codes),
						Emit.store(receiver, Rax),
					])
				Ok(LoweringBasics.falling(called, after(String)))
			}
			("Math", "sin") | ("Math", "cos") | ("Math", "tan") | ("Math", "atan") => {
				why = "node's last digits are V8's port of fdlibm's"
				LoweringBasics.refusal(site, "`Math.${name}` is not compiled yet: ${why}")
			}
			("Object", _) if count >= 1 and LoweringBasics.is_value_kind(
				LoweringBasics.kind_below(state, count - 1),
			) => {
				listed = match name {
					"keys" => 0
					"values" => 1
					_ => 2
				}
				called = [
					Emit.load(Rdi, LoweringBasics.stack_place(site.code, base)),
					Emit.imm(Rsi, listed),
					Emit.call(Runtime.object_listing),
					Emit.store(receiver, Rax),
				]
				Ok(LoweringBasics.falling(called, after(Array)))
			}
			_ => {
				given = LoweringBasics.count_text(count, "argument")
				LoweringBasics.refusal(site, "`${owner}.${name}` with ${given} is not compiled yet")
			}
		}
	}

	## The timers' builtins.
	timer_names : List(Str)
	timer_names = ["setTimeout", "setInterval", "clearTimeout", "clearInterval"]

	## A call of a timer's builtin: `setTimeout(f, ms)` and `setInterval(f,
	## ms)` give the timer, `clearTimeout(t)` and `clearInterval(t)` clear it;
	## the answer takes the builtin's place.
	timer_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		count : U64,
		name : Str,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	timer_items = |site, { state, count, name }| {
		base = state.stack_kinds.len() - count
		callee = LoweringBasics.stack_place(site.code, base - 1)
		argument = |at| LoweringBasics.stack_place(site.code, base + at)
		if !state.stack_kinds.take_last(count).all(LoweringBasics.is_value_kind) {
			return LoweringBasics.refusal(site, "`${name}` of a value that is not one")
		}
		match (name, count) {
			("setTimeout", 1) | ("setTimeout", 2) | ("setInterval", 1) | ("setInterval", 2) => {
				delay =
					if count == 2 {
						Emit.load(Rsi, argument(1))
					} else {
						Emit.imm(Rsi, Boxing.undefined_bits)
					}
				repeated = if name == "setInterval" {
					1
				} else {
					0
				}
				called = [
					Emit.load(Rdi, argument(0)),
					delay,
					Emit.imm(Rdx, repeated),
					Emit.call(Runtime.set_timer),
					Emit.store(callee, Rax),
				]
				Ok(
					LoweringBasics.falling(
						called,
						LoweringBasics.with_top(
							LoweringBasics.without_top(state, count + 1),
							Value,
						),
					),
				)
			}
			("clearTimeout", _) | ("clearInterval", _) => {
				cleared =
					if count == 0 {
						[]
					} else {
						[Emit.load(Rdi, argument(0)), Emit.call(Runtime.clear_timer)]
					}
				undefined = LoweringBasics.constant_items({
					bits: Boxing.undefined_bits.to_u64_wrap(),
					to: callee,
				})
				Ok(
					LoweringBasics.falling(
						cleared.concat(undefined),
						LoweringBasics.with_top(
							LoweringBasics.without_top(state, count + 1),
							Undefined,
						),
					),
				)
			}
			_ => {
				given = LoweringBasics.count_text(count, "argument")
				counted = "${given} (a timer's arguments past its delay)"
				LoweringBasics.refusal(site, "`${name}` with ${counted} is not compiled yet")
			}
		}
	}

	## The builtins that make errors with `new`.
	error_names : List(Str)
	error_names = ["Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError"]

	## `new Error(message)` and its kin: an error made with the class's name
	## and the message, which takes the class's place.
	error_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		count : U64,
		name : Str,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	error_items = |site, { state, count, name }| {
		depth = state.stack_kinds.len()
		message =
			if count == 0 {
				[Emit.address_of(Rsi, "runtime_text_empty")]
			} else {
				given = LoweringBasics.stack_place(site.code, depth - 1)
				match LoweringBasics.kind_below(state, 0) {
					String => [
						Emit.load(Rsi, given),
						Emit.shl(Rsi, 16),
						Emit.shr(Rsi, 16),
					]
					kind if LoweringBasics.is_value_kind(kind) => [
						Emit.load(Rdi, given),
						Emit.call(Runtime.error_message),
						Emit.mov(Rsi, Rax),
					]
					kind => return LoweringBasics.refusal(
						site,
						"an error's message of ${LoweringBasics.kind_phrase(kind)}",
					)
				}
			}
		made = message.concat([
			Emit.address_of(Rdi, Runtime.error_name_label(name)),
			Emit.call(Runtime.new_error),
			Emit.store(LoweringBasics.stack_place(site.code, depth - count - 1), Rax),
		])
		Ok(
			LoweringBasics.falling(
				made,
				LoweringBasics.with_top(LoweringBasics.without_top(state, count + 1), Object),
			),
		)
	}
}

## `Math.floor`, `Math.ceil` or `Math.trunc` (`name`) of the number in `rdi`,
## its answer stored at `receiver`: in line when the number truncates to a
## 64-bit integer, else `slow_items`, the routine's call (the header's
## rule).
rounded_items : LoweringBasics.Site,
{
	name : Str,
	receiver : X86.Mem,
	slow_items : List(Assembly.Statement),
} -> List(Assembly.Statement)
rounded_items = |site, { name, receiver, slow_items }| {
	slow_label = LoweringBasics.inner_label(site, "slow")
	done_label = LoweringBasics.inner_label(site, "done")
	truncated = [
		Emit.to_xmm(Xmm0, Rdi),
		Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
		Emit.cmp_imm(Rcx, 1),
		Emit.jcc(O, slow_label),
	]
	# 1 in `rax` when the number is below its truncation (floor) or above it
	# (ceil), taken from or added to it.
	stepped = |{ left, right, operation }| [
		Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
		Instruction(Ucomisd({ left, right })),
		Instruction(Setcc({ condition: B, to: Al })),
		Instruction(MovzxByte({ to: Rax, from: Al })),
		Instruction(Alu({ operation, to: Rcx, from: Rax })),
	]
	moved = match name {
		"floor" => stepped({
			left: Xmm0,
			right: Xmm1,
			operation: Sub,
		})
		"ceil" => stepped({
			left: Xmm1,
			right: Xmm0,
			operation: Add,
		})
		_ => []
	}
	signed = [
		Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
		Instruction(MovqFromXmm({ to: Rax, from: Xmm1 })),
		Emit.mov(Rdx, Rdi),
		Emit.shr(Rdx, 63),
		Emit.shl(Rdx, 63),
		Instruction(
			Alu({
				operation: Or,
				to: Rax,
				from: Rdx,
			}),
		),
		Emit.store(receiver, Rax),
		Emit.jmp(done_label),
		Emit.mark(slow_label),
	]
	truncated
		.concat(moved)
		.concat(signed)
		.concat(slow_items)
		.append(Emit.mark(done_label))
}
