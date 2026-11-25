## This module holds what each instruction does to the machine (`Machine`)
## when it calls nothing back and reaches no host: an operator applied, a
## jump taken, a box or a property read and written, a pattern taken apart,
## a closure made and its frame entered and filled, a return, a throw and
## the handler that catches it (`caught`), a timer queued, a `for ... of`
## stepped. Each takes the machine and gives it back.
##
## It stands apart from `Vm` because none of it runs the loop: the loop in
## `Vm` fetches each instruction and its `dispatch!` calls one of these an
## arm, and the calls that run a callback (and so the loop again) stay there
## with it, since Roc allows no import cycle. What is here is pure, so it is
## read and changed without the effects in view.
import Ast
import BuiltinRules
import Bytecode
import CollectionRules
import Events
import Heap
import Machine
import ValueRules

Instructions :: [].{

	# The machine after a throw: at the innermost waiting handler, when that
	# handler's frame is one this run of the loop entered (at `floor` or
	# deeper), with the stack as it stood and what was thrown on top; else as
	# it is, for the loop that entered the handler's frame to catch.
	caught : Machine.Machine, Box(ValueRules.Throw), U64 -> Machine.Machine
	caught = |machine, boxed, floor|
		if machine.handler_count == 0 {
			machine
		} else {
			handler = machine.handlers.get(machine.handler_count - 1) ?? crash "Instructions.caught: a handler waits"
			if handler.depth < floor {
				machine
			} else {
				{ value, site } = Box.unbox(boxed)
				back = {
					..machine,
					status: Running,
					handler_count: machine.handler_count - 1,
					depth: handler.depth,
					code: handler.code,
					pc: handler.pc,
					base: handler.base,
				}
				cleared = Machine.dropped(back, back.top - handler.top)
				match handler.kind {
					Catching => Machine.pushed(cleared, value)
					Finishing => Machine.pushed(Machine.pushed(Machine.pushed(cleared, Number(site.line.to_f64())), Number(site.column.to_f64())), value)
				}
			}
		}

	# The value and the class under the top of the stack replaced by whether
	# the value is an instance of the class named, or of a class that extends
	# it: every instance is marked with them all.
	instance_tested : Machine.Machine, Str -> Machine.Machine
	instance_tested = |machine, name| {
		is_instance = match Machine.value_at(machine, 2) {
			Reference(id) => match Heap.cell_at(machine.cells, id) {
				Instance(classes, _) => classes.contains(name)
				_ => False
			}
			_ => False
		}
		Machine.replaced(machine, 2, Boolean(is_instance))
	}

	missing_name : Machine.Machine, Str, Ast.Where -> Machine.Machine
	missing_name = |machine, name, at| {
		{ cells, machine: rest } = Machine.lent(machine)
		Machine.with_got(rest, ValueRules.missing_name_got(Machine.shell(cells, rest), name, at), rest.top)
	}

	# ---- boxes -----------------------------------------------------------------

	boxed_loaded : Machine.Machine, Bytecode.Named -> Machine.Machine
	boxed_loaded = |machine, { slot, name, at }|
		match Machine.box_content(machine, Machine.box_of(machine, slot)) {
			Holding(value) => Machine.pushed(machine, value)
			Unready => Machine.with_error(
				machine,
				ReferenceError,
				ValueRules.unready_message(name),
				at,
			)
		}

	boxed_peeked : Machine.Machine, U64 -> Machine.Machine
	boxed_peeked = |machine, slot|
		match Machine.box_content(machine, Machine.box_of(machine, slot)) {
			Holding(value) => Machine.pushed(machine, value)
			Unready => Machine.pushed(machine, Undefined)
		}

	boxed_stored : Machine.Machine, Bytecode.Assigned -> Machine.Machine
	boxed_stored = |machine, { slot, name, kind, at }| {
		box = Machine.box_of(machine, slot)
		match (Machine.box_content(machine, box), kind) {
			(Unready, _) => Machine.with_error(
				machine,
				ReferenceError,
				ValueRules.unready_message(name),
				at,
			)
			(Holding(_), Fixed) => Machine.with_error(machine, TypeError, "Assignment to constant variable.", at)
			(Holding(_), Mutable) => Machine.with_box(machine, box, Machine.value_at(machine, 1))
		}
	}

	boxed_set : Machine.Machine, U64 -> Machine.Machine
	boxed_set = |machine, slot| Machine.dropped(Machine.with_box(machine, Machine.box_of(machine, slot), Machine.value_at(machine, 1)), 1)

	box_made : Machine.Machine, U64 -> Machine.Machine
	box_made = |machine, slot| {
		{ machine: made, id } = Machine.placed(machine, UnreadyVariable)
		Machine.with_slot(made, slot, Reference(id))
	}

	box_copied : Machine.Machine, U64 -> Machine.Machine
	box_copied = |machine, slot| {
		cell = match Machine.box_content(machine, Machine.box_of(machine, slot)) {
			Holding(value) => Variable(value)
			Unready => UnreadyVariable
		}
		{ machine: made, id } = Machine.placed(machine, cell)
		Machine.with_slot(made, slot, Reference(id))
	}

	# ---- operators -------------------------------------------------------------

	unary : Machine.Machine, Ast.UnaryOperator, Ast.Where -> Machine.Machine
	unary = |machine, operator, at| {
		operand = Machine.value_at(machine, 1)
		match (operator, operand) {
			(Not, _) => Machine.replaced(machine, 1, Boolean(!ValueRules.is_truthy(operand)))
			(TypeOf, _) => Machine.replaced(machine, 1, Text(ValueRules.type_of(machine.cells, operand)))
			(Negate, Number(number)) => Machine.replaced(machine, 1, Number(-number))
			(Plus, Number(number)) => Machine.replaced(machine, 1, Number(number))
			_ => {
				{ cells, machine: rest } = Machine.lent(machine)
				Machine.with_got(rest, ValueRules.unary(Machine.shell(cells, rest), operator, operand, at), rest.top - 1)
			}
		}
	}

	binary : Machine.Machine, Ast.BinaryOperator, Ast.Where -> Machine.Machine
	binary = |machine, operator, at| {
		right = Machine.value_at(machine, 1)
		left = Machine.value_at(machine, 2)
		match (left, right) {
			(Number(x), Number(y)) => Machine.replaced(machine, 2, ValueRules.arithmetic(operator, x, y))
			_ => Instructions.combined(machine, { operator: operator, left: left, right: right, at: at })
		}
	}

	# Two values that aren't both numbers, combined by the value rules, in place
	# of the top two.
	combined : Machine.Machine, { operator : Ast.BinaryOperator, left : Heap.Value, right : Heap.Value, at : Ast.Where } -> Machine.Machine
	combined = |machine, { operator, left, right, at }|
		match operator {
			StrictEqual => Machine.replaced(machine, 2, Boolean(ValueRules.is_strictly_equal(left, right)))
			StrictNotEqual => Machine.replaced(machine, 2, Boolean(!ValueRules.is_strictly_equal(left, right)))
			_ => {
				{ cells, machine: rest } = Machine.lent(machine)
				Machine.with_got(rest, ValueRules.binary(Machine.shell(cells, rest), operator, left, right, at), rest.top - 2)
			}
		}

	template_joined : Machine.Machine, Str -> Machine.Machine
	template_joined = |machine, piece| {
		part = Machine.value_at(machine, 1)
		match ValueRules.text_of(machine.cells, part) {
			Ok(phrase) => {
				taken = machine.stack.replace(machine.top - 2, Null) ?? crash "Instructions.template_joined: a template's text so far is on the stack"
				so_far = match taken.prev {
					Text(text) => text
					_ => crash "Instructions.template_joined: a template's text so far is text"
				}
				grown = { ..machine, stack: taken.list }
				Machine.replaced(grown, 2, Text(Str.concat(Str.concat(so_far, phrase), piece)))
			}
			# The value rules' message, which names no line here.
			Err(Unsupported(why)) => Machine.with_fault(machine, why)
		}
	}

	jumped_if_false : Machine.Machine, U64 -> Machine.Machine
	jumped_if_false = |machine, count| {
		test = Machine.value_at(machine, 1)
		popped = Machine.dropped(machine, 1)
		if ValueRules.is_truthy(test) {
			popped
		} else {
			{ ..popped, pc: popped.pc + count }
		}
	}

	skipped_if : Machine.Machine, U64, [Falsy, Truthy, Defined, NotUndefined] -> Machine.Machine
	skipped_if = |machine, count, settles| {
		subject = Machine.value_at(machine, 1)
		settled = match settles {
			Falsy => !ValueRules.is_truthy(subject)
			Truthy => ValueRules.is_truthy(subject)
			Defined => !ValueRules.is_nullish(subject)
			NotUndefined => subject != Undefined
		}
		if settled {
			{ ..machine, pc: machine.pc + count }
		} else {
			Machine.dropped(machine, 1)
		}
	}

	jumped_if_same : Machine.Machine, U64 -> Machine.Machine
	jumped_if_same = |machine, count| {
		same = ValueRules.is_strictly_equal(
			Machine.value_at(machine, 2),
			Machine.value_at(machine, 1),
		)
		popped = Machine.dropped(machine, 2)
		if same {
			{ ..popped, pc: popped.pc + count }
		} else {
			popped
		}
	}

	shorted_if_nullish : Machine.Machine, U64 -> Machine.Machine
	shorted_if_nullish = |machine, count|
		if ValueRules.is_nullish(Machine.value_at(machine, 1)) {
			shorted = Machine.replaced(machine, 1, Undefined)
			{ ..shorted, pc: shorted.pc + count }
		} else {
			machine
		}

	# ---- exceptions ------------------------------------------------------------

	try_entered : Machine.Machine, U64, Bytecode.Handling -> Machine.Machine
	try_entered = |machine, handler, kind| {
		waiting = {
			depth: machine.depth,
			code: machine.code,
			pc: machine.pc + handler,
			base: machine.base,
			top: machine.top,
			kind: kind,
		}
		handlers = if machine.handler_count < machine.handlers.len() {
			machine.handlers.set(machine.handler_count, waiting) ?? crash "Instructions.try_entered: below the handlers' end"
		} else {
			machine.handlers.append(waiting)
		}
		{ ..machine, handlers: handlers, handler_count: machine.handler_count + 1 }
	}

	# A throw a `finally` held, thrown again from where it was first thrown.
	rethrown : Machine.Machine -> Machine.Machine
	rethrown = |machine| {
		value = Machine.value_at(machine, 1)
		site = {
			line: Instructions.held_place(Machine.value_at(machine, 3)),
			column: Instructions.held_place(Machine.value_at(machine, 2)),
		}
		{ ..Machine.dropped(machine, 3), status: Thrown(Box.box({ value: value, site: site })) }
	}

	held_place : Heap.Value -> U64
	held_place = |held|
		match held {
			Number(number) => number.to_u64_try() ?? crash "Instructions.held_place: a throw's line and column are whole numbers"
			_ => crash
				"Instructions.held_place: a finally holds a throw's line and column as numbers"
		}

	# ---- patterns --------------------------------------------------------------

	# An array pattern's value as an array: an array as it is, read as the
	# pattern goes, anything else iterable as a new array of its values.
	items_destructured : Machine.Machine, ValueRules.Origin, Ast.Where -> Machine.Machine
	items_destructured = |machine, origin, at| {
		given = Machine.value_at(machine, 1)
		is_array = match given {
			Reference(id) => ValueRules.is_array_cell(machine.cells, id)
			_ => False
		}
		if is_array {
			machine
		} else {
			{ cells, machine: rest } = Machine.lent(machine)
			{ machine: rules, values } = CollectionRules.iterated(Machine.shell(cells, rest), given)
			back = Machine.with_rules(rest, rules)
			match values {
				Ok(items) => {
					{ machine: made, id } = Machine.placed(back, Array(items))
					Machine.replaced(made, 1, Reference(id))
				}
				Err(NotIterable) => {
					{ cells: held, machine: waiting } = Machine.lent(back)
					failed = ValueRules.with_not_iterable(Machine.shell(held, waiting), given, origin, at)
					Machine.with_got(waiting, { machine: failed, value: Undefined }, waiting.top - 1)
				}
			}
		}
	}

	items_from : Machine.Machine, U64 -> Machine.Machine
	items_from = |machine, position| {
		id = Instructions.reference_id(Machine.value_at(machine, 1))
		left = ValueRules.items_of(machine.cells, id).drop_first(position)
		{ machine: made, id: rest_id } = Machine.placed(machine, Array(left))
		Machine.replaced(made, 1, Reference(rest_id))
	}

	destructurable_checked : Machine.Machine, { properties : List(Ast.PropertyPattern), origin : ValueRules.Origin, at : Ast.Where } -> Machine.Machine
	destructurable_checked = |machine, { properties, origin, at }| {
		given = Machine.value_at(machine, 1)
		if ValueRules.is_nullish(given) {
			Machine.with_error(machine, TypeError, ValueRules.destructure_message(given, properties, origin), at)
		} else {
			machine
		}
	}

	properties_left : Machine.Machine, List(Str), Ast.Where -> Machine.Machine
	properties_left = |machine, keys, at|
		match ValueRules.properties_left(machine.cells, Machine.value_at(machine, 1), keys) {
			Ok(left) => {
				{ machine: made, id } = Machine.placed(machine, Object(left))
				Machine.replaced(made, 1, Reference(id))
			}
			Err(Unsupported(why)) => Machine.with_fault(
				machine,
				"${why}${ValueRules.line_note(at)}",
			)
		}

	# ---- assignments and updates -----------------------------------------------

	# `s += e`: the string grown where the slot holds it, while nothing else
	# refers to it, so building a string a piece at a time copies no piece.
	local_appended : Machine.Machine, U64, Ast.Where -> Machine.Machine
	local_appended = |machine, slot, at| {
		piece = Machine.value_at(machine, 1)
		match Machine.slot_value(machine, slot) {
			Text(_) => match ValueRules.text_of(machine.cells, piece) {
				Ok(tail) => {
					taken = machine.stack.replace(machine.base + slot, Null) ?? crash "Instructions.local_appended: a slot of the frame"
					grown = match taken.prev {
						Text(text) => Str.concat(text, tail)
						_ => crash "Instructions.local_appended: the slot held text a moment ago"
					}
					written = { ..machine, stack: taken.list.set(machine.base + slot, Text(grown)) ?? crash "Instructions.local_appended: a slot of the frame" }
					Machine.replaced(written, 1, Machine.slot_value(written, slot))
				}
				Err(Unsupported(why)) => Machine.with_fault(
					machine,
					"${why}${ValueRules.line_note(at)}",
				)
			}
			old => {
				added = Instructions.binary(Machine.pushed(Machine.replaced(machine, 1, old), piece), Add, at)
				if Machine.is_running(added) {
					Machine.with_slot(added, slot, Machine.value_at(added, 1))
				} else {
					added
				}
			}
		}
	}

	# What `++` or `--` answers: the new value before, the old after.
	update_answer : Bytecode.Update, F64 -> Heap.Value
	update_answer = |{ delta, fixity, at: _ }, old| match fixity {
		Prefix => Number(old + delta)
		Postfix => Number(old)
	}

	not_a_number_update : Machine.Machine, Heap.Value, Ast.Where -> Machine.Machine
	not_a_number_update = |machine, current, at| Machine.with_fault(machine, "unsupported: `++` or `--` on a ${ValueRules.type_of(machine.cells, current)}${ValueRules.line_note(at)}")

	local_updated : Machine.Machine, U64, Bytecode.Update -> Machine.Machine
	local_updated = |machine, slot, step|
		match Machine.slot_value(machine, slot) {
			Number(old) => Machine.pushed(Machine.with_slot(machine, slot, Number(old + step.delta)), Instructions.update_answer(step, old))
			current => Instructions.not_a_number_update(machine, current, step.at)
		}

	boxed_updated : Machine.Machine, { slot : U64, name : Str, kind : Bytecode.Kind, step : Bytecode.Update } -> Machine.Machine
	boxed_updated = |machine, { slot, name, kind, step }| {
		box = Machine.box_of(machine, slot)
		match Machine.box_content(machine, box) {
			Unready => Machine.with_error(
				machine,
				ReferenceError,
				ValueRules.unready_message(name),
				step.at,
			)
			Holding(Number(old)) => match kind {
				Fixed => Machine.with_error(
					machine,
					TypeError,
					"Assignment to constant variable.",
					step.at,
				)
				Mutable => Machine.pushed(Machine.with_box(machine, box, Number(old + step.delta)), Instructions.update_answer(step, old))
			}
			Holding(current) => Instructions.not_a_number_update(machine, current, step.at)
		}
	}

	fixed_updated : Machine.Machine, Ast.Where -> Machine.Machine
	fixed_updated = |machine, at|
		match Machine.value_at(machine, 1) {
			Number(_) => Machine.with_error(
				machine,
				TypeError,
				"Assignment to constant variable.",
				at,
			)
			current => Instructions.not_a_number_update(machine, current, at)
		}

	property_updated : Machine.Machine, Str, Bytecode.Update -> Machine.Machine
	property_updated = |machine, key, step| {
		holder = Machine.value_at(machine, 1)
		read = Instructions.property_read(machine, key, step.at)
		if !Machine.is_running(read) {
			read
		} else {
			match Machine.value_at(read, 1) {
				Number(old) => {
					back = Machine.pushed(Machine.dropped(read, 1), holder)
					written = Instructions.stored(Machine.pushed(back, Number(old + step.delta)), { key: Text(key), at: step.at })
					if Machine.is_running(written) {
						Machine.replaced(written, 1, Instructions.update_answer(step, old))
					} else {
						written
					}
				}
				current => Instructions.not_a_number_update(read, current, step.at)
			}
		}
	}

	index_updated : Machine.Machine, Bytecode.Update -> Machine.Machine
	index_updated = |machine, step| {
		holder = Machine.value_at(machine, 2)
		key = Machine.value_at(machine, 1)
		read = Instructions.index_read(
			Machine.pushed(Machine.pushed(machine, holder), key),
			step.at,
		)
		if !Machine.is_running(read) {
			read
		} else {
			match Machine.value_at(read, 1) {
				Number(old) => {
					written = Instructions.index_written(
						Machine.replaced(read, 1, Number(old + step.delta)),
						step.at,
					)
					if Machine.is_running(written) {
						Machine.replaced(written, 1, Instructions.update_answer(step, old))
					} else {
						written
					}
				}
				current => Instructions.not_a_number_update(read, current, step.at)
			}
		}
	}

	# ---- arrays and objects ----------------------------------------------------

	array_made : Machine.Machine, U64 -> Machine.Machine
	array_made = |machine, count| {
		items = Machine.arguments_of(machine, count)
		{ machine: made, id } = Machine.placed(machine, Array(items))
		Machine.replaced(made, count, Reference(id))
	}

	reference_id : Heap.Value -> U64
	reference_id = |value| match value {
		Reference(id) => id
		_ => crash "Instructions.reference_id: the compiler puts the array or object being built beneath its parts"
	}

	item_appended : Machine.Machine -> Machine.Machine
	item_appended = |machine| {
		id = Instructions.reference_id(Machine.value_at(machine, 2))
		item = Machine.value_at(machine, 1)
		Machine.dropped({ ..machine, cells: Heap.with_items_pushed(machine.cells, id, [item]) }, 1)
	}

	spread_appended : Machine.Machine, Ast.Expression, Ast.Where -> Machine.Machine
	spread_appended = |machine, source, at| {
		id = Instructions.reference_id(Machine.value_at(machine, 2))
		given = Machine.value_at(machine, 1)
		{ cells, machine: rest } = Machine.lent(machine)
		{ machine: ruled, values } = CollectionRules.iterated(Machine.shell(cells, rest), given)
		match values {
			Ok(items) => Machine.dropped({ ..rest, cells: Heap.with_items_pushed(ruled.cells, id, items), free: ruled.free }, 1)
			Err(NotIterable) => {
				failed = ValueRules.with_not_iterable(ruled, given, Written(source), at)
				Machine.with_got(rest, { machine: failed, value: Undefined }, rest.top - 1)
			}
		}
	}

	field_set : Machine.Machine, Str -> Machine.Machine
	field_set = |machine, key| {
		id = Instructions.reference_id(Machine.value_at(machine, 2))
		value = Machine.value_at(machine, 1)
		Machine.dropped({ ..machine, cells: Heap.with_property(machine.cells, id, key, value) }, 1)
	}

	fields_spread : Machine.Machine, Ast.Where -> Machine.Machine
	fields_spread = |machine, at| {
		id = Instructions.reference_id(Machine.value_at(machine, 2))
		given = Machine.value_at(machine, 1)
		match ValueRules.spread_properties(machine.cells, given) {
			Ok(properties) => {
				var $cells = machine.cells
				for property in properties {
					$cells = Heap.with_property($cells, id, property.key, property.value)
				}
				Machine.dropped({ ..machine, cells: $cells }, 1)
			}
			Err(Unsupported(why)) => Machine.with_fault(
				machine,
				"${why}${ValueRules.line_note(at)}",
			)
		}
	}

	# An object's own property, a builtin object's, or an array's length, read
	# here; everything else by the value rules.
	property_read : Machine.Machine, Str, Ast.Where -> Machine.Machine
	property_read = |machine, key, at| {
		holder = Machine.value_at(machine, 1)
		found = match holder {
			Reference(id) => match Heap.cell_at(machine.cells, id) {
				Object(properties) | Namespace(_, properties) => Instructions.own_property(
					properties,
					key,
				)
				Instance(_, properties) => Instructions.own_property(properties, key)
				Array(items) if key == "length" => Found(Number(items.len().to_f64()))
				_ => Elsewhere
			}
			_ => Elsewhere
		}
		match found {
			Found(value) => Machine.replaced(machine, 1, value)
			Elsewhere => {
				{ cells, machine: rest } = Machine.lent(machine)
				Machine.with_got(rest, ValueRules.property(Machine.shell(cells, rest), holder, key, at), rest.top - 1)
			}
		}
	}

	# An object's own property `key`, or where to look for it instead.
	own_property : List(Heap.Property), Str -> [Found(Heap.Value), Elsewhere]
	own_property = |properties, key|
		match properties.find_first(|property| property.key == key) {
			Ok(property) => Found(property.value)
			Err(NotFound) => Elsewhere
		}

	index_read : Machine.Machine, Ast.Where -> Machine.Machine
	index_read = |machine, at| {
		holder = Machine.value_at(machine, 2)
		key = Machine.value_at(machine, 1)
		found = match (holder, ValueRules.index_of(key)) {
			(Reference(id), Ok(position)) => match Heap.cell_at(machine.cells, id) {
				Array(items) => Found(items.get(position) ?? Undefined)
				_ => Elsewhere
			}
			_ => Elsewhere
		}
		match found {
			Found(value) => Machine.replaced(machine, 2, value)
			Elsewhere => {
				{ cells, machine: rest } = Machine.lent(machine)
				Machine.with_got(rest, ValueRules.indexed_value(Machine.shell(cells, rest), holder, key, at), rest.top - 2)
			}
		}
	}

	# The value on top stored at `key` of the holder beneath it, both replaced
	# by the value: an object's property or an array's item written here,
	# everything else by the value rules.
	stored : Machine.Machine, { key : Heap.Value, at : Ast.Where } -> Machine.Machine
	stored = |machine, { key, at }| {
		holder = Machine.value_at(machine, 2)
		value = Machine.value_at(machine, 1)
		place = match holder {
			Reference(id) => match ValueRules.kind_of(machine.cells, id) {
				ObjectKind => match key {
					Text(text) => Property(id, text)
					_ => Elsewhere
				}
				ArrayKind(length) => match ValueRules.index_of(key) {
					Ok(position) if position <= length => Item(id, position)
					_ => Elsewhere
				}
				_ => Elsewhere
			}
			_ => Elsewhere
		}
		match place {
			Property(id, text) => Machine.replaced({ ..machine, cells: Heap.with_property(machine.cells, id, text, value) }, 2, value)
			Item(id, position) => Machine.replaced({ ..machine, cells: Heap.with_item(machine.cells, id, position, value) }, 2, value)
			Elsewhere => {
				{ cells, machine: rest } = Machine.lent(machine)
				Machine.with_got(rest, ValueRules.with_stored(Machine.shell(cells, rest), holder, key, value, at), rest.top - 2)
			}
		}
	}

	property_written : Machine.Machine, Str, Ast.Where -> Machine.Machine
	property_written = |machine, key, at| Instructions.stored(machine, { key: Text(key), at: at })

	index_written : Machine.Machine, Ast.Where -> Machine.Machine
	index_written = |machine, at| {
		key = Machine.value_at(machine, 2)
		value = Machine.value_at(machine, 1)
		# holder, key, value -> holder, value: the store takes the key apart.
		Instructions.stored(
			Machine.pushed(Machine.dropped(machine, 2), value),
			{ key: key, at: at },
		)
	}

	# ---- closures and calls ----------------------------------------------------

	closure_made : Machine.Machine, { code : U64, captures : List(U64), definition : Box(Ast.FunctionDefinition) } -> Machine.Machine
	closure_made = |machine, { code, captures, definition }| {
		boxes = captures.map(|slot| Machine.box_of(machine, slot))
		{ machine: holding, id: environment } = Machine.placed(machine, Environment({ code: code, boxes: boxes }))
		Machine.allocated(holding, Fun({ fun: definition, scope: environment }))
	}

	# How a call that finds no function names what it called: as the program
	# wrote it (`o.f is not a function`), or, for a builtin's callback, by its
	# value.
	Naming : [Written(Str), Shown]

	Calling : { count : U64, result_at : U64, naming : Instructions.Naming, at : Ast.Where }

	# The deepest call the VM makes before it throws a RangeError.
	max_depth : U64
	max_depth = ValueRules.max_depth

	closure_entered : Bytecode.Program, Machine.Machine, { environment : U64, calling : Instructions.Calling } -> Machine.Machine
	closure_entered = |program, machine, { environment, calling }| {
		{ code, boxes } = match Heap.cell_at(machine.cells, environment) {
			Environment(held) => held
			_ => crash "Instructions.closure_entered: a VM closure's scope names its environment"
		}
		if machine.depth >= Instructions.max_depth {
			Machine.with_error(machine, RangeError, "Maximum call stack size exceeded", calling.at)
		} else {
			counted = Machine.stepped(machine)
			caller = { code: counted.code, pc: counted.pc, base: counted.base, result_at: calling.result_at }
			depth = counted.depth
			base = counted.top - calling.count
			inside = {
				..counted,
				frames: Instructions.frames_with(counted.frames, depth, caller),
				depth: depth + 1,
				code: code,
				pc: 0,
				base: base,
			}
			Instructions.frame_filled(inside, { code: Machine.code_of(program, code), given: calling.count, boxes: boxes })
		}
	}

	frames_with : List(Machine.Frame), U64, Machine.Frame -> List(Machine.Frame)
	frames_with = |frames, depth, caller|
		if depth < frames.len() {
			frames.set(depth, caller) ?? crash "Instructions.frames_with: below the frames' end"
		} else {
			frames.append(caller)
		}

	# The frame starting at `base`, `given` arguments on it, made ready to run:
	# as many arguments as parameters, the rest of the slots undefined, then
	# the boxes the code's entry makes.
	frame_filled : Machine.Machine, { code : Bytecode.Code, given : U64, boxes : List(U64) } -> Machine.Machine
	frame_filled = |machine, { code, given, boxes }| {
		var $machine = match code.arguments {
			Each(parameters) => {
				var $taken = if given > parameters {
					Machine.dropped(machine, given - parameters)
				} else {
					machine
				}
				var $count = parameters.min(given)
				while $count < code.frame_size {
					$taken = Machine.pushed($taken, Undefined)
					$count = $count + 1
				}
				$taken
			}
			Packed(slot) => {
				arguments = Machine.arguments_of(machine, given)
				{ machine: packed, id } = Machine.placed(
					Machine.dropped(machine, given),
					Array(arguments),
				)
				var $taken = packed
				var $count = 0
				while $count < code.frame_size {
					$taken = Machine.pushed($taken, Undefined)
					$count = $count + 1
				}
				Machine.with_slot($taken, slot, Reference(id))
			}
		}
		for entry in code.entry {
			$machine = match entry {
				FreshBox(slot) => Instructions.box_made($machine, slot)
				FilledBox(slot) => {
					{ machine: made, id } = Machine.placed(
						$machine,
						Variable(Machine.slot_value($machine, slot)),
					)
					Machine.with_slot(made, slot, Reference(id))
				}
				CapturedBox({ slot, capture }) => Machine.with_slot(
					$machine,
					slot,
					Reference(boxes.get(capture) ?? crash "Instructions.frame_filled: an environment holds every box its code captures"),
				)
			}
		}
		$machine
	}

	returned : Machine.Machine -> Machine.Machine
	returned = |machine|
		if machine.depth == 0 {
			# A `return` outside every function ends the program, as node's
			# module wrapper ends it.
			{ ..machine, status: Finished }
		} else {
			value = Machine.value_at(machine, 1)
			caller = machine.frames.get(
				machine.depth - 1,
			) ?? crash "Instructions.returned: a caller waits"
			back = Machine.with_result(machine, caller.result_at, value)
			{ ..back, depth: back.depth - 1, code: caller.code, pc: caller.pc, base: caller.base }
		}

	thrown : Machine.Machine, Ast.Where -> Machine.Machine
	thrown = |machine, at| {
		value = Machine.value_at(machine, 1)
		{ ..machine, status: Thrown(Box.box({ value: value, site: at })) }
	}

	# The arguments built as one array, with their spreads, put on the stack
	# in its place.
	spread_unpacked : Machine.Machine -> { machine : Machine.Machine, count : U64 }
	spread_unpacked = |machine| {
		items = match Machine.value_at(machine, 1) {
			Reference(id) => match Heap.cell_at(machine.cells, id) {
				Array(values) => values
				_ => crash "Instructions.spread_unpacked: the compiler builds spread arguments as an array"
			}
			_ => crash
				"Instructions.spread_unpacked: the compiler builds spread arguments as an array"
		}
		var $machine = Machine.dropped(machine, 1)
		for item in items {
			$machine = Machine.pushed($machine, item)
		}
		{ machine: $machine, count: items.len() }
	}

	# What a method call calls, on the stack above its receiver.
	method_looked_up : Machine.Machine, Str, Ast.Where -> Machine.Machine
	method_looked_up = |machine, name, at| {
		receiver = Machine.value_at(machine, 1)
		by_name = match receiver {
			Reference(id) => match ValueRules.kind_of(machine.cells, id) {
				ArrayKind(_) | MapKind | SetKind => True
				_ => False
			}
			Text(_) => True
			_ => False
		}
		if by_name {
			Machine.pushed(machine, receiver)
		} else {
			Instructions.property_read(Machine.pushed(machine, receiver), name, at)
		}
	}

	constructed : Machine.Machine, { count : U64, callee : Ast.Expression, at : Ast.Where } -> Machine.Machine
	constructed = |machine, { count, callee, at }| {
		maker = Machine.value_at(machine, count + 1)
		arguments = Machine.arguments_of(machine, count)
		{ cells, machine: rest } = Machine.lent(machine)
		Machine.with_got(rest, BuiltinRules.constructed(Machine.shell(cells, rest), maker, callee, arguments, at), rest.top - count - 1)
	}

	# ---- builtins --------------------------------------------------------------

	# `setTimeout` or `setInterval`: the timer's handle, its callback queued by
	# `Events.timer_requested`'s rules.
	timer_set : Machine.Machine, { repeats : [Once, Repeating], arguments : List(Heap.Value), calling : Instructions.Calling } -> Machine.Machine
	timer_set = |machine, { repeats, arguments, calling }| {
		{ cells, machine: rest } = Machine.lent(machine)
		asked = { repeats: repeats, arguments: arguments, at: calling.at, timer: Box.unbox(rest.events).made, clock: Box.unbox(rest.events).clock }
		{ machine: after, value, queued } = Events.timer_requested(
			Machine.shell(cells, rest),
			asked,
		)
		back = match queued {
			Queued(event) => { ..rest, events: Box.box(Events.with_event(Box.unbox(rest.events), event)) }
			Refused => rest
		}
		Machine.with_got(back, { machine: after, value: value }, calling.result_at)
	}

	# ---- array methods ---------------------------------------------------------

	item_count : Machine.Machine, U64 -> U64
	item_count = |machine, id| match ValueRules.kind_of(machine.cells, id) {
		ArrayKind(length) => length
		_ => crash "Instructions.item_count: asked only of an array"
	}

	item_at : Machine.Machine, U64, U64 -> Heap.Value
	item_at = |machine, id, position| match Heap.cell_at(machine.cells, id) {
		Array(items) => items.get(position) ?? Undefined
		_ => crash "Instructions.item_at: asked only of an array"
	}

	# ---- for ... of ------------------------------------------------------------

	iteration_started : Machine.Machine, Ast.Expression, Ast.Where -> Machine.Machine
	iteration_started = |machine, source, at| {
		given = Machine.value_at(machine, 1)
		match given {
			Reference(id) => match ValueRules.kind_of(machine.cells, id) {
				ArrayKind(_) | IteratorKind => machine
				MapKind => Machine.allocated(Machine.dropped(machine, 1), Iteration({ source: id, view: Entries, next: 0 }))
				SetKind => Machine.allocated(Machine.dropped(machine, 1), Iteration({ source: id, view: Values, next: 0 }))
				_ => Instructions.not_iterable(machine, source, at)
			}
			Text(text) => {
				characters = ValueRules.characters(text).map(|character| Text(character))
				{ machine: made, id } = Machine.placed(machine, Array(characters))
				Machine.replaced(made, 1, Reference(id))
			}
			_ => Instructions.not_iterable(machine, source, at)
		}
	}

	not_iterable : Machine.Machine, Ast.Expression, Ast.Where -> Machine.Machine
	not_iterable = |machine, source, at| Machine.with_error(machine, TypeError, "${ValueRules.source_text(source)} is not iterable", at)

	# The next item of a `for ... of`: an array's at its place in the slot after
	# its own, or the next entry of a Map's, a Set's or an iterator's walk, each
	# read from the heap as the loop comes to it, so an entry the body deletes
	# is skipped and one it adds is met. The walk keeps its place in its own
	# cell, so an iterator a loop leaves goes on from there.
	iterated : Machine.Machine, U64, U64 -> Machine.Machine
	iterated = |machine, slot, exit| {
		id = Instructions.reference_id(Machine.slot_value(machine, slot))
		match ValueRules.kind_of(machine.cells, id) {
			IteratorKind => Instructions.walk_stepped(machine, id, exit)
			_ => {
				position = match Machine.slot_value(machine, slot + 1) {
					Number(at) => at.to_u64_try() ?? crash "Instructions.iterated: a `for ... of`'s place is a whole number"
					_ => crash "Instructions.iterated: a `for ... of`'s place is a number"
				}
				if position < Instructions.item_count(machine, id) {
					Machine.pushed(Machine.with_slot(machine, slot + 1, Number((position + 1).to_f64())), Instructions.item_at(machine, id, position))
				} else {
					{ ..machine, pc: machine.pc + exit }
				}
			}
		}
	}

	walk_stepped : Machine.Machine, U64, U64 -> Machine.Machine
	walk_stepped = |machine, id, exit| {
		{ source, view, next } = CollectionRules.iteration_of(machine.cells, id)
		var $i = next
		var $step = Skip
		while $step == Skip {
			{ step, after } = CollectionRules.step_at(machine.cells, source, view, $i)
			$step = step
			$i = after
		}
		moved = { ..machine, cells: Heap.with_iterator_at(machine.cells, id, $i) }
		match $step {
			Yield(value) => Machine.pushed(moved, value)
			YieldPair(key, value) => Machine.allocated(moved, Array([key, value]))
			Skip | Ended => { ..moved, pc: moved.pc + exit }
		}
	}
}
