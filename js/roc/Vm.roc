## This module runs a compiled JavaScript program (`Bytecode`) on a stack
## machine: one loop reads an instruction and hands the machine to that
## instruction's handler, which gives it back.
##
## **EVERY VALUE THE PROGRAM HOLDS IS IN THE MACHINE.** A call's frame is a
## run of slots on the operand stack (`stack`, its live part the first
## `top` places), the values being worked on sit above it, and the callers'
## frames wait in `frames`. A captured variable's box and a closure's
## environment are heap cells. So what a collector would start from is data:
## the live stack, the frames and the heap's cells.
##
## **THE COLLECTOR RUNS BETWEEN INSTRUCTIONS.** Before each instruction the
## loop asks whether a collection is due (`is_collection_due`), and if so
## marks from the machine's roots and sweeps (`collected`, `Collector`). An
## instruction's handler holds values in Roc's own locals only while it
## runs, so between two instructions every value the program holds is in
## the machine. The one exception is a builtin that runs the loop again for
## a callback: what it needs after the callback returns waits on the stack
## (the item `filter` keeps, the items `sort` orders), so the collections
## inside the callback see it.
##
## **THE LOOP ONLY DISPATCHES.** `run!` fetches the next instruction and
## calls `dispatch!`, whose match calls one top-level handler an arm, so no
## single function grows with the language. A handler answers the machine
## and nothing else; a value it makes goes on the stack.
##
## **A PLACE THE STACK GIVES UP IS CLEARED.** The stack never shrinks: a pop
## lowers `top` and writes `Null` where the value was, and a push past the
## end appends. A value left above `top` would be a second reference to a
## string or a list, and the next write to it in place would copy it.
##
## **A CALL OF A BUILTIN THAT CALLS BACK RUNS THE LOOP AGAIN.** `forEach`,
## `map`, `sort` and their kin call a function for each item: the call
## pushes the function and its arguments, enters its frame and runs the loop
## until that frame returns (`call_function!`), then reads its answer off the
## stack. While it runs, the method's receiver and arguments wait on the
## stack beneath it, and the array `map` or `filter` builds is a cell the
## stack refers to.
##
## **THE VALUE RULES LIVE IN A MODULE OF THEIR OWN.** What JavaScript gives
## for a property read, an operator on mixed values, a string method, a
## builtin that calls nothing back, and every message those make, lives
## once, in `ValueRules`. Where the VM's own fast path doesn't settle an
## instruction (two numbers added, an object's own property read), it lends
## the cells to that rule (`lent`, `shell`) and takes the cells, the value
## and any fault or throw back (`with_got`). None of those rules calls a
## function of the program.
##
## **THE HANDLERS TAKE SEVERAL ARGUMENTS, A NAMED EXCEPTION.** A handler
## takes the host, then the program, then the machine, then the rest, where the style guide would take one record:
## a record holding the machine is a second reference to the heap.
##
## **A THROW LANDS AT A HANDLER THAT IS DATA.** A `try` pushes a handler
## (`Handler`): its frame, where its `catch` or `finally` code starts, and
## how high the stack stood. A throw, the program's or one of JavaScript's
## own errors, sets `status`, and the loop takes the innermost handler when
## its frame is one this run of the loop entered: the frames and the stack
## above it are given up, and its code goes on with the value thrown on top
## (`caught`). A throw a callback's own frames don't catch ends the
## callback's run, and the builtin that called it hands it to the loop
## beneath. One nothing catches ends the run as node ends it.
##
## **EVERY CALLBACK RUNS AFTER THE PROGRAM, ON ONE QUEUE.**
## `setTimeout` and `setInterval` queue their callbacks by `Events`' rules,
## on its virtual clock, and so do a click and the canvas's `frame(t)`. Once
## the program finishes, its own frame stays at the bottom of the stack
## (`start!`), and each callback runs as a call from it: all of them in turn
## on the command line (`drained!`), or those due by a frame's time on the
## page (`tick!`).
##
## **THE CANVAS'S EFFECTS GO TO THE HOST AS THEY ARE MADE** (`emitted!`),
## a log's among them, each counted against the budget of what is running.
import ArrayRules
import Ast
import BuiltinRules
import Bytecode
import Canvas
import CollectionRules
import Collector
import Events
import Heap
import Inspect
import Machine
import StringRules
import ValueRules

Vm :: [].{

	## How a run ended: at its end, stopped by a fault, or by a throw nothing
	## caught, written as the line node prints first.
	Ending : [Finished, Faulted(Str), Uncaught(Str)]

	## How a run goes: the library its builtins come from, the steps it may
	## take and the effects it may make before its end, and when it collects:
	## amortized, or at every allocation, which tests that no root is missed.
	Settings : {
		library : Ast.Library,
		steps : U64,
		effects : U64,
		collecting : [Doubling, EveryAllocation],
	}

	## How far one tick of a session may go: the steps and the effects of
	## every callback it runs.
	Limits : { steps : U64, effects : U64 }

	## A program that may go on after its end: its machine, with the
	## program's own frame kept at the bottom of the stack, as a page keeps a
	## script's, so a later callback sees the variables the program declared;
	## and its code.
	Session : { machine : Machine.Machine, program : Bytecode.Program }

	## How a session stands, as its host is told: running, stopped by a
	## fault, or stopped by a throw nothing caught, written as the line node
	## prints first.
	Standing : [Running, Faulted(Str), Uncaught(Str)]

	## How a run ended, with what it counted: its steps, the heap's length,
	## the cells its roots reach at the end, and the collections it ran.
	Outcome : { ending : Vm.Ending, steps : U64, cells : U64, live : U64, collections : U64 }

	## A program run to its end, then every timer it left, in the order of
	## their times (`drained!`), its effects handed to `host` as it runs.
	run! : Canvas.Host, Bytecode.Program, Vm.Settings => Vm.Outcome
	run! = |host, program, settings| {
		{ machine: begun, program: _ } = Vm.start!(host, program, settings)
		ended = drained!(host, program, begun)
		ending = match standing_of(ended) {
			Running => Finished
			Faulted(why) => Faulted(why)
			Uncaught(line) => Uncaught(line)
		}
		live = Collector.reached_count(Collector.marked(ended.cells, Machine.roots(ended)))
		collections = Box.unbox(ended.collecting).collections
		{ ending: ending, steps: ended.steps, cells: ended.cells.len(), live: live, collections: collections }
	}

	## A program run to its end, its own frame kept for the callbacks it
	## left. On the canvas library, a program that declares `frame` as a
	## function has its first frame queued, at time 0, and each frame queues
	## the next.
	start! : Canvas.Host, Bytecode.Program, Vm.Settings => Vm.Session
	start! = |host, program, settings| {
		{ cells, values: builtins } = BuiltinRules.globals([], settings.library)
		begun = {
			cells: cells,
			stack: [],
			top: 0,
			frames: [],
			depth: 0,
			handlers: [],
			handler_count: 0,
			events: Box.box(Events.at_start),
			code: program.main,
			pc: 0,
			base: 0,
			builtins: Box.box(builtins),
			free: NoneFree,
			collecting: Box.box({
				schedule: match settings.collecting {
					Doubling => Doubling(Collector.least_threshold)
					EveryAllocation => EveryAllocation({ length: cells.len(), free: NoneFree })
				},
				collections: 0,
			}),
			status: Running,
			steps: 0,
			effects: 0,
			budget: Box.box({ step_limit: settings.steps, effect_limit: settings.effects, budgeted: TheProgram }),
			turtle: Box.box(Canvas.turtle_start),
		}
		main = Machine.code_of(program, program.main)
		entered = frame_filled(begun, { code: main, given: 0, boxes: [] })
		finished = loop!(host, program, entered, 0)
		machine = match finished.status {
			Finished => {
				going = { ..finished, status: Running }
				match settings.library {
					Canvas => first_frame_queued(going, program)
					Core => going
				}
			}
			_ => finished
		}
		{ machine: machine, program: program }
	}

	## The session with its clock moved to `seconds`, every event due by
	## then run in its order: the clicks the page queued, the timers, and the
	## frame of that time. They share one budget, `limits`, afresh. A session
	## that has stopped is answered as it is.
	tick! : Canvas.Host, Vm.Session, F64, Vm.Limits => Vm.Session
	tick! = |host, session, seconds, limits| {
		{ machine: before, program } = session
		if !Machine.is_running(before) {
			{ machine: before, program: program }
		} else {
			until = seconds * 1000.0
			var $machine = {
				..before,
				steps: 0,
				effects: 0,
				budget: Box.box({ ..Box.unbox(before.budget), step_limit: limits.steps, effect_limit: limits.effects }),
			}
			var $going = True
			while $going {
				match Events.earliest(Box.unbox($machine.events).pending_events, until) {
					At(index) if Machine.is_running($machine) => {
						$machine = event_run!(host, program, $machine, index)
					}
					_ => {
						$going = False
					}
				}
			}
			clocked = { ..$machine, events: Box.box(Events.with_clock_at(Box.unbox($machine.events), until)) }
			{ machine: clocked, program: program }
		}
	}

	## The session with a click queued for its `onClick` handler, due now, so
	## the next `tick!` runs it. A session with no handler, or stopped, is
	## answered as it is.
	with_click : Vm.Session, F64, F64 -> Vm.Session
	with_click = |session, x, y| {
		{ machine, program } = session
		queue = Box.unbox(machine.events)
		match queue.on_click {
			Handler({ handler: _, site }) if Machine.is_running(machine) => {
				clicked = Events.with_event(queue, { due: queue.clock, site: site, happening: Clicked(x, y) })
				{ machine: { ..machine, events: Box.box(clicked) }, program: program }
			}
			_ => { machine: machine, program: program }
		}
	}

	## Whether the session has more to do: an event queued, or a click handler
	## that a click would call. A host ticks a session while it waits.
	waits : Vm.Session -> Bool
	waits = |session| {
		queue = Box.unbox(session.machine.events)
		Machine.is_running(session.machine) and (!queue.pending_events.is_empty() or queue.on_click != NoHandler)
	}

	standing : Vm.Session -> Vm.Standing
	standing = |session| standing_of(session.machine)

	## How many cells the session's heap holds, the freed ones among them.
	cell_count : Vm.Session -> U64
	cell_count = |session| session.machine.cells.len()

	## How many of the session's cells are in use, not on the free list.
	in_use_count : Vm.Session -> U64
	in_use_count = |session| Heap.in_use_count(session.machine.cells, session.machine.free)
}

standing_of : Machine.Machine -> Vm.Standing
standing_of = |machine|
	match machine.status {
		Running | Finished => Running
		Faulted(why) => Faulted(why)
		Thrown(boxed) => {
			{ value, site } = Box.unbox(boxed)
			match ValueRules.uncaught_ending(machine.cells, value, site) {
				Uncaught(line) => Uncaught(line)
				Faulted(why) => Faulted(why)
			}
		}
	}

# The machine with the program's first `frame(t)` queued, at time 0, when
# the program's own frame holds a function named `frame`.
first_frame_queued : Machine.Machine, Bytecode.Program -> Machine.Machine
first_frame_queued = |machine, program| {
	held = match program.frame {
		Declared(Slot(slot)) => Holding(Machine.slot_value(machine, slot))
		Declared(Boxed(slot)) => Machine.box_content(machine, Machine.box_of(machine, slot))
		Undeclared => Unready
	}
	closure = match held {
		Holding(Reference(id)) => match Heap.cell_at(machine.cells, id) {
			Fun(found) => Frame(found)
			_ => NoFrame
		}
		_ => NoFrame
	}
	match closure {
		Frame(found) => {
			event = { due: Events.frame_due(0), site: found.fun.unbox().at, happening: Framed(found, 0) }
			{ ..machine, events: Box.box(Events.with_event(Box.unbox(machine.events), event)) }
		}
		NoFrame => machine
	}
}

# ---- the loop --------------------------------------------------------------

# The machine run on until it stops, or until fewer than `floor` callers
# wait: a callback's run ends when the frame it entered returns.
loop! : Canvas.Host, Bytecode.Program, Machine.Machine, U64 => Machine.Machine
loop! = |host, program, machine, floor| {
	var $machine = machine
	var $code = machine.code
	var $ops = Machine.code_of(program, $code).ops
	while Machine.is_running($machine) and $machine.depth >= floor {
		if Machine.is_collection_due($machine) {
			before = Heap.in_use_count($machine.cells, $machine.free)
			{ machine: swept, live } = Machine.collected($machine)
			heard = { cells: swept.cells.len(), before: before, live: live }
			told! = host.collected!
			told!(heard)
			$machine = Machine.with_collection_heard(swept, heard)
		}
		if $machine.code != $code {
			$code = $machine.code
			$ops = Machine.code_of(program, $code).ops
		}
		op = $ops.get($machine.pc) ?? crash "Vm.loop!: every code ends in a return or a finish"
		$machine = dispatch!(host, program, { ..$machine, pc: $machine.pc + 1 }, op)
		match $machine.status {
			Thrown(boxed) => {
				$machine = caught($machine, boxed, floor)
			}
			_ => {}
		}
	}
	$machine
}

# The machine after a throw: at the innermost waiting handler, when that
# handler's frame is one this run of the loop entered (at `floor` or
# deeper), with the stack as it stood and what was thrown on top; else as
# it is, for the loop that entered the handler's frame to catch.
caught : Machine.Machine, Box(ValueRules.Throw), U64 -> Machine.Machine
caught = |machine, boxed, floor|
	if machine.handler_count == 0 {
		machine
	} else {
		handler = machine.handlers.get(machine.handler_count - 1) ?? crash "Vm.caught: a handler waits"
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

dispatch! : Canvas.Host, Bytecode.Program, Machine.Machine, Bytecode.Op => Machine.Machine
dispatch! = |host, program, machine, op|
	match op {
		PushNumber(number) => Machine.pushed(machine, Number(number))
		PushText(text) => Machine.pushed(machine, Text(text))
		PushBoolean(truth) => Machine.pushed(machine, Boolean(truth))
		PushNull => Machine.pushed(machine, Null)
		PushUndefined => Machine.pushed(machine, Undefined)
		Pop => Machine.dropped(machine, 1)
		Duplicate => Machine.pushed(machine, Machine.value_at(machine, 1))
		DuplicatePair => Machine.duplicated_pair(machine)
		Nip => Machine.nipped(machine)
		Swap => Machine.swapped(machine)
		Rotate => Machine.rotated(machine)
		LoadLocal(slot) => Machine.pushed(machine, Machine.slot_value(machine, slot))
		StoreLocal(slot) => Machine.with_slot(machine, slot, Machine.value_at(machine, 1))
		SetLocal(slot) => Machine.local_set(machine, slot)
		LoadBoxed(named) => boxed_loaded(machine, named)
		PeekBoxed(slot) => boxed_peeked(machine, slot)
		StoreBoxed(assigned) => boxed_stored(machine, assigned)
		SetBoxed(slot) => boxed_set(machine, slot)
		NewBox(slot) => box_made(machine, slot)
		CopyBox(slot) => box_copied(machine, slot)
		LoadBuiltin(index) => Machine.pushed(machine, Box.unbox(machine.builtins).get(index) ?? crash "Vm.dispatch!: Resolve places a builtin the library has")
		MissingName({ name, at }) => missing_name(machine, name, at)
		ThrowUnready({ name, at }) => Machine.with_error(machine, ReferenceError, ValueRules.unready_message(name), at)
		ThrowConstant(at) => Machine.with_error(machine, TypeError, "Assignment to constant variable.", at)
		Refuse(why) => Machine.with_fault(machine, why)
		AppendLocal({ slot, at }) => local_appended(machine, slot, at)
		UpdateLocal({ slot, step }) => local_updated(machine, slot, step)
		UpdateBoxed(boxed) => boxed_updated(machine, boxed)
		UpdateFixed(at) => fixed_updated(machine, at)
		UpdateProperty({ key, step }) => property_updated(machine, key, step)
		UpdateIndex(step) => index_updated(machine, step)
		Unary(operator, at) => unary(machine, operator, at)
		Binary(operator, at) => binary(machine, operator, at)
		TemplatePart(piece) => template_joined(machine, piece)
		Jump(count) => { ..machine, pc: machine.pc + count }
		Loop(count) => Machine.stepped({ ..machine, pc: machine.pc - count })
		JumpIfFalse(count) => jumped_if_false(machine, count)
		SkipIfFalsy(count) => skipped_if(machine, count, Falsy)
		SkipIfTruthy(count) => skipped_if(machine, count, Truthy)
		SkipIfDefined(count) => skipped_if(machine, count, Defined)
		SkipIfNotUndefined(count) => skipped_if(machine, count, NotUndefined)
		JumpIfSame(count) => jumped_if_same(machine, count)
		ShortIfNullish(count) => shorted_if_nullish(machine, count)
		MakeArray(count) => array_made(machine, count)
		NewArray => Machine.allocated(machine, Array([]))
		AppendItem => item_appended(machine)
		AppendSpread({ source, at }) => spread_appended(machine, source, at)
		NewObject => Machine.allocated(machine, Object([]))
		NewInstance(classes) => Machine.allocated(machine, Instance(classes, []))
		InstanceOf(name) => instance_tested(machine, name)
		SetField(key) => field_set(machine, key)
		SpreadFields(at) => fields_spread(machine, at)
		GetProperty(key, at) => property_read(machine, key, at)
		GetIndex(at) => index_read(machine, at)
		SetProperty(key, at) => property_written(machine, key, at)
		SetIndex(at) => index_written(machine, at)
		MakeClosure(made) => closure_made(machine, made)
		Call(site) => plain_called!(host, program, machine, site)
		CallSpread({ written, at }) => spread_called!(host, program, machine, { written: written, at: at })
		MethodLookup(name, at) => method_looked_up(machine, name, at)
		CallMethod({ name, site }) => method_called!(host, program, machine, { name: name, site: site })
		CallMethodSpread({ name, written, at }) => spread_method_called!(host, program, machine, { name: name, written: written, at: at })
		Construct({ count, callee, at }) => constructed(machine, { count: count, callee: callee, at: at })
		IterStart({ source, at }) => iteration_started(machine, source, at)
		IterNext({ slot, exit }) => iterated(machine, slot, exit)
		DestructureItems({ origin, at }) => items_destructured(machine, origin, at)
		ItemOf(position) => Machine.replaced(machine, 1, item_at(machine, reference_id(Machine.value_at(machine, 1)), position))
		ItemsFrom(position) => items_from(machine, position)
		CheckDestructurable(checked) => destructurable_checked(machine, checked)
		PropertiesLeft({ keys, at }) => properties_left(machine, keys, at)
		EnterTry({ handler, kind }) => try_entered(machine, handler, kind)
		LeaveTry => { ..machine, handler_count: machine.handler_count - 1 }
		Rethrow => rethrown(machine)
		Return => returned(machine)
		Throw(at) => thrown(machine, at)
		Finish => { ..machine, status: Finished }
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
		Unready => Machine.with_error(machine, ReferenceError, ValueRules.unready_message(name), at)
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
		(Unready, _) => Machine.with_error(machine, ReferenceError, ValueRules.unready_message(name), at)
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
		_ => combined(machine, { operator: operator, left: left, right: right, at: at })
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
			taken = machine.stack.replace(machine.top - 2, Null) ?? crash "Vm.template_joined: a template's text so far is on the stack"
			so_far = match taken.prev {
				Text(text) => text
				_ => crash "Vm.template_joined: a template's text so far is text"
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
	same = ValueRules.is_strictly_equal(Machine.value_at(machine, 2), Machine.value_at(machine, 1))
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
		machine.handlers.set(machine.handler_count, waiting) ?? crash "Vm.try_entered: below the handlers' end"
	} else {
		machine.handlers.append(waiting)
	}
	{ ..machine, handlers: handlers, handler_count: machine.handler_count + 1 }
}

# A throw a `finally` held, thrown again from where it was first thrown.
rethrown : Machine.Machine -> Machine.Machine
rethrown = |machine| {
	value = Machine.value_at(machine, 1)
	site = { line: held_place(Machine.value_at(machine, 3)), column: held_place(Machine.value_at(machine, 2)) }
	{ ..Machine.dropped(machine, 3), status: Thrown(Box.box({ value: value, site: site })) }
}

held_place : Heap.Value -> U64
held_place = |held|
	match held {
		Number(number) => number.to_u64_try() ?? crash "Vm.held_place: a throw's line and column are whole numbers"
		_ => crash "Vm.held_place: a finally holds a throw's line and column as numbers"
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
	id = reference_id(Machine.value_at(machine, 1))
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
		Err(Unsupported(why)) => Machine.with_fault(machine, "${why}${ValueRules.line_note(at)}")
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
				taken = machine.stack.replace(machine.base + slot, Null) ?? crash "Vm.local_appended: a slot of the frame"
				grown = match taken.prev {
					Text(text) => Str.concat(text, tail)
					_ => crash "Vm.local_appended: the slot held text a moment ago"
				}
				written = { ..machine, stack: taken.list.set(machine.base + slot, Text(grown)) ?? crash "Vm.local_appended: a slot of the frame" }
				Machine.replaced(written, 1, Machine.slot_value(written, slot))
			}
			Err(Unsupported(why)) => Machine.with_fault(machine, "${why}${ValueRules.line_note(at)}")
		}
		old => {
			added = binary(Machine.pushed(Machine.replaced(machine, 1, old), piece), Add, at)
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
		Number(old) => Machine.pushed(Machine.with_slot(machine, slot, Number(old + step.delta)), update_answer(step, old))
		current => not_a_number_update(machine, current, step.at)
	}

boxed_updated : Machine.Machine, { slot : U64, name : Str, kind : Bytecode.Kind, step : Bytecode.Update } -> Machine.Machine
boxed_updated = |machine, { slot, name, kind, step }| {
	box = Machine.box_of(machine, slot)
	match Machine.box_content(machine, box) {
		Unready => Machine.with_error(machine, ReferenceError, ValueRules.unready_message(name), step.at)
		Holding(Number(old)) => match kind {
			Fixed => Machine.with_error(machine, TypeError, "Assignment to constant variable.", step.at)
			Mutable => Machine.pushed(Machine.with_box(machine, box, Number(old + step.delta)), update_answer(step, old))
		}
		Holding(current) => not_a_number_update(machine, current, step.at)
	}
}

fixed_updated : Machine.Machine, Ast.Where -> Machine.Machine
fixed_updated = |machine, at|
	match Machine.value_at(machine, 1) {
		Number(_) => Machine.with_error(machine, TypeError, "Assignment to constant variable.", at)
		current => not_a_number_update(machine, current, at)
	}

property_updated : Machine.Machine, Str, Bytecode.Update -> Machine.Machine
property_updated = |machine, key, step| {
	holder = Machine.value_at(machine, 1)
	read = property_read(machine, key, step.at)
	if !Machine.is_running(read) {
		read
	} else {
		match Machine.value_at(read, 1) {
			Number(old) => {
				back = Machine.pushed(Machine.dropped(read, 1), holder)
				written = stored(Machine.pushed(back, Number(old + step.delta)), { key: Text(key), at: step.at })
				if Machine.is_running(written) {
					Machine.replaced(written, 1, update_answer(step, old))
				} else {
					written
				}
			}
			current => not_a_number_update(read, current, step.at)
		}
	}
}

index_updated : Machine.Machine, Bytecode.Update -> Machine.Machine
index_updated = |machine, step| {
	holder = Machine.value_at(machine, 2)
	key = Machine.value_at(machine, 1)
	read = index_read(Machine.pushed(Machine.pushed(machine, holder), key), step.at)
	if !Machine.is_running(read) {
		read
	} else {
		match Machine.value_at(read, 1) {
			Number(old) => {
				written = index_written(Machine.replaced(read, 1, Number(old + step.delta)), step.at)
				if Machine.is_running(written) {
					Machine.replaced(written, 1, update_answer(step, old))
				} else {
					written
				}
			}
			current => not_a_number_update(read, current, step.at)
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
	_ => crash "Vm.reference_id: the compiler puts the array or object being built beneath its parts"
}

item_appended : Machine.Machine -> Machine.Machine
item_appended = |machine| {
	id = reference_id(Machine.value_at(machine, 2))
	item = Machine.value_at(machine, 1)
	Machine.dropped({ ..machine, cells: Heap.with_items_pushed(machine.cells, id, [item]) }, 1)
}

spread_appended : Machine.Machine, Ast.Expression, Ast.Where -> Machine.Machine
spread_appended = |machine, source, at| {
	id = reference_id(Machine.value_at(machine, 2))
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
	id = reference_id(Machine.value_at(machine, 2))
	value = Machine.value_at(machine, 1)
	Machine.dropped({ ..machine, cells: Heap.with_property(machine.cells, id, key, value) }, 1)
}

fields_spread : Machine.Machine, Ast.Where -> Machine.Machine
fields_spread = |machine, at| {
	id = reference_id(Machine.value_at(machine, 2))
	given = Machine.value_at(machine, 1)
	match ValueRules.spread_properties(machine.cells, given) {
		Ok(properties) => {
			var $cells = machine.cells
			for property in properties {
				$cells = Heap.with_property($cells, id, property.key, property.value)
			}
			Machine.dropped({ ..machine, cells: $cells }, 1)
		}
		Err(Unsupported(why)) => Machine.with_fault(machine, "${why}${ValueRules.line_note(at)}")
	}
}

# An object's own property, a builtin object's, or an array's length, read
# here; everything else by the value rules.
property_read : Machine.Machine, Str, Ast.Where -> Machine.Machine
property_read = |machine, key, at| {
	holder = Machine.value_at(machine, 1)
	found = match holder {
		Reference(id) => match Heap.cell_at(machine.cells, id) {
			Object(properties) | Namespace(_, properties) => own_property(properties, key)
			Instance(_, properties) => own_property(properties, key)
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
property_written = |machine, key, at| stored(machine, { key: Text(key), at: at })

index_written : Machine.Machine, Ast.Where -> Machine.Machine
index_written = |machine, at| {
	key = Machine.value_at(machine, 2)
	value = Machine.value_at(machine, 1)
	# holder, key, value -> holder, value: the store takes the key apart.
	stored(Machine.pushed(Machine.dropped(machine, 2), value), { key: key, at: at })
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

Calling : { count : U64, result_at : U64, naming : Naming, at : Ast.Where }

# The deepest call the VM makes before it throws a RangeError.
max_depth : U64
max_depth = ValueRules.max_depth

# The deepest call from which a builtin runs a callback; past it the
# callback's call throws the same RangeError. A callback's run is the loop
# run again, a Roc call deeper (`call_function!`), and each such run stands
# on at least one JavaScript call, so this bounds Roc's own stack. The dev
# build's overflows at about 700 callbacks nested through `sort`, the
# deepest of the builtins that call back.
max_callback_depth : U64
max_callback_depth = 400

# A call of the value beneath the top `count`: a closure's frame entered, a
# builtin's answer made, or a TypeError.
called! : Canvas.Host, Bytecode.Program, Machine.Machine, Calling => Machine.Machine
called! = |host, program, machine, calling| {
	callee = Machine.value_at(machine, calling.count + 1)
	target = match callee {
		Reference(id) => match Heap.cell_at(machine.cells, id) {
			Fun(closure) => Closure(closure.scope)
			Builtin(native, _) => Native(native)
			_ => NoFunction
		}
		_ => NoFunction
	}
	match target {
		Closure(environment) => closure_entered(program, machine, { environment: environment, calling: calling })
		Native(native) => native_called!(host, program, machine, { native: native, calling: calling })
		NoFunction => {
			shown = match calling.naming {
				Written(written) => written
				Shown => ValueRules.shown_value(machine.cells, callee)
			}
			Machine.with_error(machine, TypeError, "${shown} is not a function", calling.at)
		}
	}
}

plain_called! : Canvas.Host, Bytecode.Program, Machine.Machine, Bytecode.CallSite => Machine.Machine
plain_called! = |host, program, machine, site| {
	result_at = machine.top - site.count - 1
	called!(host, program, machine, { count: site.count, result_at: result_at, naming: Written(site.written), at: site.at })
}

closure_entered : Bytecode.Program, Machine.Machine, { environment : U64, calling : Calling } -> Machine.Machine
closure_entered = |program, machine, { environment, calling }| {
	{ code, boxes } = match Heap.cell_at(machine.cells, environment) {
		Environment(held) => held
		_ => crash "Vm.closure_entered: a VM closure's scope names its environment"
	}
	if machine.depth >= max_depth {
		Machine.with_error(machine, RangeError, "Maximum call stack size exceeded", calling.at)
	} else {
		counted = Machine.stepped(machine)
		caller = { code: counted.code, pc: counted.pc, base: counted.base, result_at: calling.result_at }
		depth = counted.depth
		base = counted.top - calling.count
		inside = {
			..counted,
			frames: frames_with(counted.frames, depth, caller),
			depth: depth + 1,
			code: code,
			pc: 0,
			base: base,
		}
		frame_filled(inside, { code: Machine.code_of(program, code), given: calling.count, boxes: boxes })
	}
}

frames_with : List(Machine.Frame), U64, Machine.Frame -> List(Machine.Frame)
frames_with = |frames, depth, caller|
	if depth < frames.len() {
		frames.set(depth, caller) ?? crash "Vm.frames_with: below the frames' end"
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
			{ machine: packed, id } = Machine.placed(Machine.dropped(machine, given), Array(arguments))
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
			FreshBox(slot) => box_made($machine, slot)
			FilledBox(slot) => {
				{ machine: made, id } = Machine.placed($machine, Variable(Machine.slot_value($machine, slot)))
				Machine.with_slot(made, slot, Reference(id))
			}
			CapturedBox({ slot, capture }) => Machine.with_slot(
				$machine,
				slot,
				Reference(boxes.get(capture) ?? crash "Vm.frame_filled: an environment holds every box its code captures"),
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
		caller = machine.frames.get(machine.depth - 1) ?? crash "Vm.returned: a caller waits"
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
			_ => crash "Vm.spread_unpacked: the compiler builds a call's spread arguments as an array"
		}
		_ => crash "Vm.spread_unpacked: the compiler builds a call's spread arguments as an array"
	}
	var $machine = Machine.dropped(machine, 1)
	for item in items {
		$machine = Machine.pushed($machine, item)
	}
	{ machine: $machine, count: items.len() }
}

spread_called! : Canvas.Host, Bytecode.Program, Machine.Machine, { written : Str, at : Ast.Where } => Machine.Machine
spread_called! = |host, program, machine, { written, at }| {
	{ machine: unpacked, count } = spread_unpacked(machine)
	called!(host, program, unpacked, { count: count, result_at: unpacked.top - count - 1, naming: Written(written), at: at })
}

spread_method_called! : Canvas.Host, Bytecode.Program, Machine.Machine, { name : Str, written : Str, at : Ast.Where } => Machine.Machine
spread_method_called! = |host, program, machine, { name, written, at }| {
	{ machine: unpacked, count } = spread_unpacked(machine)
	method_called!(host, program, unpacked, { name: name, site: { count: count, written: written, at: at } })
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
		property_read(Machine.pushed(machine, receiver), name, at)
	}
}

method_called! : Canvas.Host, Bytecode.Program, Machine.Machine, { name : Str, site : Bytecode.CallSite } => Machine.Machine
method_called! = |host, program, machine, { name, site }| {
	count = site.count
	result_at = machine.top - count - 2
	receiver = Machine.value_at(machine, count + 2)
	method = match receiver {
		Reference(id) => match ValueRules.kind_of(machine.cells, id) {
			ArrayKind(_) => ArrayMethod(id)
			MapKind => CollectionMethod({ id: id, collection: IsMap })
			SetKind => CollectionMethod({ id: id, collection: IsSet })
			_ => Held
		}
		Text(text) => TextMethod(text)
		_ => Held
	}
	match method {
		ArrayMethod(id) => array_method!(host, program, machine, { id: id, name: name, count: count, result_at: result_at, at: site.at })
		TextMethod(text) => {
			arguments = Machine.arguments_of(machine, count)
			{ cells, machine: rest } = Machine.lent(machine)
			Machine.with_got(rest, StringRules.text_method(Machine.shell(cells, rest), text, name, arguments, site.at), result_at)
		}
		CollectionMethod(place) if name == "forEach" => collection_walk!(host, program, machine, { id: place.id, count: count, result_at: result_at, at: site.at })
		CollectionMethod(place) => {
			arguments = Machine.arguments_of(machine, count)
			{ cells, machine: rest } = Machine.lent(machine)
			Machine.with_got(rest, CollectionRules.collection_method(Machine.shell(cells, rest), place, name, arguments, site.at), result_at)
		}
		Held => called!(host, program, machine, { count: count, result_at: result_at, naming: Written(site.written), at: site.at })
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

native_called! : Canvas.Host, Bytecode.Program, Machine.Machine, { native : Heap.Native, calling : Calling } => Machine.Machine
native_called! = |host, program, machine, { native, calling }| {
	arguments = Machine.arguments_of(machine, calling.count)
	at = calling.at
	match native {
		Log => match Inspect.line_of(machine.cells, arguments) {
			Ok(line) => emitted!(host, machine, { effect: Log(line), result_at: calling.result_at })
			Err(Unsupported(why)) => Machine.with_fault(machine, "${why}${ValueRules.line_note(at)}")
		}
		Paint(paint) => match Canvas.effect_of(paint, { arguments: arguments, cells: machine.cells }) {
			Ok(effect) => emitted!(host, machine, { effect: effect, result_at: calling.result_at })
			Err(Unsupported(why)) => Machine.with_fault(machine, "${why}${ValueRules.line_note(at)}")
		}
		Move(move) => match Canvas.moved(Box.unbox(machine.turtle), { move: move, arguments: arguments }) {
			Ok({ turtle, drawn }) => {
				moved = { ..machine, turtle: Box.box(turtle) }
				match drawn {
					Drew(effect) => emitted!(host, moved, { effect: effect, result_at: calling.result_at })
					Nothing => Machine.with_result(moved, calling.result_at, Undefined)
				}
			}
			Err(Unsupported(why)) => Machine.with_fault(machine, "${why}${ValueRules.line_note(at)}")
		}
		Sense(MouseX) => {
			pointer! = host.pointer!
			Machine.with_result(machine, calling.result_at, Number(pointer!(X)))
		}
		Sense(MouseY) => {
			pointer! = host.pointer!
			Machine.with_result(machine, calling.result_at, Number(pointer!(Y)))
		}
		Sense(KeyIsDown) => match arguments.first() {
			Ok(Text(key)) => {
				key! = host.key!
				down = match key!(key) {
					Down => True
					Up => False
				}
				Machine.with_result(machine, calling.result_at, Boolean(down))
			}
			_ => Machine.with_fault(machine, "unsupported: keyIsDown of anything but a key's name${ValueRules.line_note(at)}")
		}
		OnClick => match arguments.first() {
			Ok(handler) if ValueRules.is_callable(machine.cells, handler) => {
				handled = Events.with_click_handler(Box.unbox(machine.events), { handler: handler, site: at })
				Machine.with_result({ ..machine, events: Box.box(handled) }, calling.result_at, Undefined)
			}
			_ => Machine.with_fault(machine, "unsupported: onClick of anything but a function${ValueRules.line_note(at)}")
		}
		OnCollect => match arguments.first() {
			Ok(handler) if ValueRules.is_callable(machine.cells, handler) => {
				handled = Events.with_collect_handler(Box.unbox(machine.events), { handler: handler, site: at })
				Machine.with_result({ ..machine, events: Box.box(handled) }, calling.result_at, Undefined)
			}
			_ => Machine.with_fault(machine, "unsupported: onCollect of anything but a function${ValueRules.line_note(at)}")
		}
		ArrayFrom if BuiltinRules.is_mapped(arguments) => array_from!(host, program, machine, { arguments: arguments, calling: calling })
		Timing(SetTimeout) => timer_set(machine, { repeats: Once, arguments: arguments, calling: calling })
		Timing(SetInterval) => timer_set(machine, { repeats: Repeating, arguments: arguments, calling: calling })
		Timing(ClearTimeout) | Timing(ClearInterval) => {
			cleared = match Events.timer_named(machine.cells, arguments) {
				Timer(number) => { ..machine, events: Box.box(Events.without_timer(Box.unbox(machine.events), number)) }
				NoTimer => machine
			}
			Machine.with_result(cleared, calling.result_at, Undefined)
		}
		_ => {
			{ cells, machine: rest } = Machine.lent(machine)
			Machine.with_got(rest, BuiltinRules.native_called(Machine.shell(cells, rest), native, arguments, at), calling.result_at)
		}
	}
}

# The machine after one effect handed to the host, the call's answer
# `undefined`, or stopped when the effect would pass its budget.
emitted! : Canvas.Host, Machine.Machine, { effect : Canvas.Effect, result_at : U64 } => Machine.Machine
emitted! = |host, machine, { effect, result_at }| {
	budget = Box.unbox(machine.budget)
	if machine.effects >= budget.effect_limit {
		Machine.with_fault(machine, "${Machine.budgeted_text(budget.budgeted)} ran past its budget of ${budget.effect_limit.to_str()} effects")
	} else {
		emit! = host.emit!
		emit!(effect)
		Machine.with_result({ ..machine, effects: machine.effects + 1 }, result_at, Undefined)
	}
}

# `setTimeout` or `setInterval`: the timer's handle, its callback queued by
# `Events.timer_requested`'s rules.
timer_set : Machine.Machine, { repeats : [Once, Repeating], arguments : List(Heap.Value), calling : Calling } -> Machine.Machine
timer_set = |machine, { repeats, arguments, calling }| {
	{ cells, machine: rest } = Machine.lent(machine)
	asked = { repeats: repeats, arguments: arguments, at: calling.at, timer: Box.unbox(rest.events).made, clock: Box.unbox(rest.events).clock }
	{ machine: after, value, queued } = Events.timer_requested(Machine.shell(cells, rest), asked)
	back = match queued {
		Queued(event) => { ..rest, events: Box.box(Events.with_event(Box.unbox(rest.events), event)) }
		Refused => rest
	}
	Machine.with_got(back, { machine: after, value: value }, calling.result_at)
}

# ---- the queue -------------------------------------------------------------

# The machine after every event left in its queue, earliest first, the clock
# moved to each in turn, until none is left, the program stops, or
# `Events.callback_limit` callbacks have run with more to come (a fault that
# says so): the command line's run, after the program.
drained! : Canvas.Host, Bytecode.Program, Machine.Machine => Machine.Machine
drained! = |host, program, machine| {
	var $machine = machine
	var $ran = 0
	var $going = True
	while $going {
		match Events.earliest(Box.unbox($machine.events).pending_events, 1.0 / 0.0) {
			At(index) if Machine.is_running($machine) => {
				if $ran >= Events.callback_limit {
					$machine = Machine.with_fault($machine, "the program ran past its budget of ${Events.callback_limit.to_str()} timer callbacks")
					$going = False
				} else {
					$machine = event_run!(host, program, $machine, index)
					$ran = $ran + 1
				}
			}
			_ => {
				$going = False
			}
		}
	}
	$machine
}

# The machine after one event's callback, taken off the queue with the
# clock moved to its time: a timer's, queued again later when it is an
# interval that didn't clear itself; a frame's, the next frame queued; a
# click's, handed to the handler.
event_run! : Canvas.Host, Bytecode.Program, Machine.Machine, U64 => Machine.Machine
event_run! = |host, program, machine, index| {
	event = Box.unbox(machine.events).pending_events.get(index) ?? crash "Vm.event_run!: Events.earliest names an event the queue has"
	taken = { ..machine, events: Box.box(Events.with_event_taken(Box.unbox(machine.events), index, event.due)) }
	match event.happening {
		Timed({ timer, callback, every }) => {
			firing = {
				..budgeted_for(taken, TimerCallback),
				events: Box.box(Events.with_firing(Box.unbox(taken.events), Firing(timer))),
			}
			after = answer_dropped(call_function!(host, program, firing, { callee: callback, arguments: [], at: event.site }))
			again = Box.unbox(after.events).firing == Firing(timer)
			idle = { ..after, events: Box.box(Events.with_firing(Box.unbox(after.events), Idle)) }
			match every {
				Every(period) if again => {
					..idle,
					events: Box.box(
						Events.with_event(
							Box.unbox(idle.events),
							{
								due: event.due + period,
								site: event.site,
								happening: Timed({ timer: timer, callback: callback, every: every }),
							},
						),
					),
				}
				_ => idle
			}
		}
		Framed(closure, number) => {
			framing = budgeted_for(taken, FrameCall)
			after = answer_dropped(
				closure_called!(
					host,
					program,
					framing,
					{ environment: closure.scope, arguments: [Number(Events.frame_time(number))], at: event.site },
				),
			)
			next = { due: Events.frame_due(number + 1), site: event.site, happening: Framed(closure, number + 1) }
			{ ..after, events: Box.box(Events.with_event(Box.unbox(after.events), next)) }
		}
		Clicked(x, y) => match Box.unbox(taken.events).on_click {
			Handler({ handler, site }) => {
				clicking = budgeted_for(taken, ClickHandler)
				answer_dropped(call_function!(host, program, clicking, { callee: handler, arguments: [Number(x), Number(y)], at: site }))
			}
			NoHandler => taken
		}
		Collected({ cells, before, live }) => match Box.unbox(taken.events).on_collect {
			Handler({ handler, site }) => {
				counts = [
					{ key: "cells", value: Number(U64.to_f64(cells)) },
					{ key: "live", value: Number(U64.to_f64(live)) },
					{ key: "before", value: Number(U64.to_f64(before)) },
				]
				{ machine: made, id } = Machine.placed(budgeted_for(taken, CollectHandler), Object(counts))
				answer_dropped(call_function!(host, program, made, { callee: handler, arguments: [Reference(id)], at: site }))
			}
			NoHandler => taken
		}
	}
}

# The machine with its budgets counted for `budgeted`.
budgeted_for : Machine.Machine, Machine.Budgeted -> Machine.Machine
budgeted_for = |machine, budgeted|
	{ ..machine, budget: Box.box({ ..Box.unbox(machine.budget), budgeted: budgeted }) }

# A callback's machine with its answer taken off the stack, unless it
# stopped, leaving none.
answer_dropped : Machine.Machine -> Machine.Machine
answer_dropped = |machine|
	if Machine.is_running(machine) {
		Machine.dropped(machine, 1)
	} else {
		machine
	}

# The queue's `frame(t)`, called with `arguments`, its answer left on the
# stack as `call_function!` leaves one. The queue holds the closure's
# environment, not its cell, so the environment stands in the callee's place,
# where the collector sees it while the frame runs.
closure_called! : Canvas.Host, Bytecode.Program, Machine.Machine, { environment : U64, arguments : List(Heap.Value), at : Ast.Where } => Machine.Machine
closure_called! = |host, program, machine, { environment, arguments, at }| {
	result_at = machine.top
	var $machine = Machine.pushed(machine, Reference(environment))
	for argument in arguments {
		$machine = Machine.pushed($machine, argument)
	}
	floor = $machine.depth + 1
	calling = { count: arguments.len(), result_at: result_at, naming: Shown, at: at }
	if $machine.depth >= max_callback_depth {
		Machine.with_error($machine, RangeError, "Maximum call stack size exceeded", at)
	} else {
		entered = closure_entered(program, $machine, { environment: environment, calling: calling })
		if entered.depth >= floor {
			loop!(host, program, entered, floor)
		} else {
			entered
		}
	}
}

# A function called with `arguments`, by a builtin, its answer left on the
# stack: a closure's frame is entered and run until it returns.
call_function! : Canvas.Host, Bytecode.Program, Machine.Machine, { callee : Heap.Value, arguments : List(Heap.Value), at : Ast.Where } => Machine.Machine
call_function! = |host, program, machine, { callee, arguments, at }| {
	result_at = machine.top
	var $machine = Machine.pushed(machine, callee)
	for argument in arguments {
		$machine = Machine.pushed($machine, argument)
	}
	floor = $machine.depth + 1
	if $machine.depth >= max_callback_depth {
		Machine.with_error($machine, RangeError, "Maximum call stack size exceeded", at)
	} else {
		entered = called!(host, program, $machine, { count: arguments.len(), result_at: result_at, naming: Shown, at: at })
		if entered.depth >= floor {
			loop!(host, program, entered, floor)
		} else {
			entered
		}
	}
}

# The answer `call_function!` left, taken off the stack.
Answered : { machine : Machine.Machine, value : Heap.Value }

answered : Machine.Machine -> Answered
answered = |machine| {
	value = Machine.value_at(machine, 1)
	{ machine: Machine.dropped(machine, 1), value: value }
}

array_from! : Canvas.Host, Bytecode.Program, Machine.Machine, { arguments : List(Heap.Value), calling : Calling } => Machine.Machine
array_from! = |host, program, machine, { arguments, calling }| {
	mapper = arguments.get(1) ?? Undefined
	{ cells, machine: rest } = Machine.lent(machine)
	{ machine: rules, listed } = BuiltinRules.array_from_values(Machine.shell(cells, rest), arguments.first() ?? Undefined)
	back = Machine.with_rules(rest, rules)
	match listed {
		Err(Unsupported(why)) => Machine.with_fault(back, "${why}${ValueRules.line_note(calling.at)}")
		Ok(values) => {
			# The values wait on the stack as an array of their own while the
			# mapper runs: an iterable's entries are new pairs nothing else
			# holds.
			pinned = Machine.allocated(back, Array(values))
			{ machine: building, id: out } = Machine.placed(pinned, Array([]))
			var $machine = Machine.pushed(building, Reference(out))
			var $i = 0
			for value in values {
				if Machine.is_running($machine) {
					{ machine: after, value: mapped } = answered(call_function!(host, program, $machine, { callee: mapper, arguments: [value, Number($i.to_f64())], at: calling.at }))
					$machine = if Machine.is_running(after) {
						{ ..after, cells: Heap.with_items_pushed(after.cells, out, [mapped]) }
					} else {
						after
					}
				}
				$i = $i + 1
			}
			if Machine.is_running($machine) {
				Machine.with_result($machine, calling.result_at, Reference(out))
			} else {
				$machine
			}
		}
	}
}

# ---- array methods ---------------------------------------------------------

ArrayCall : { id : U64, name : Str, count : U64, result_at : U64, at : Ast.Where }

item_count : Machine.Machine, U64 -> U64
item_count = |machine, id| match ValueRules.kind_of(machine.cells, id) {
	ArrayKind(length) => length
	_ => crash "Vm.item_count: asked only of an array"
}

item_at : Machine.Machine, U64, U64 -> Heap.Value
item_at = |machine, id, position| match Heap.cell_at(machine.cells, id) {
	Array(items) => items.get(position) ?? Undefined
	_ => crash "Vm.item_at: asked only of an array"
}

# An array's method: those that call a function back run here, the rest by
# the value rules.
array_method! : Canvas.Host, Bytecode.Program, Machine.Machine, ArrayCall => Machine.Machine
array_method! = |host, program, machine, call|
	match call.name {
		"forEach" => array_walk!(host, program, machine, call, ForEach)
		"map" => array_walk!(host, program, machine, call, Map)
		"filter" => array_walk!(host, program, machine, call, Filter)
		"some" => array_walk!(host, program, machine, call, Some)
		"every" => array_walk!(host, program, machine, call, Every)
		"find" => array_walk!(host, program, machine, call, Find)
		"findIndex" => array_walk!(host, program, machine, call, FindIndex)
		"flatMap" => array_walk!(host, program, machine, call, FlatMap)
		"findLast" => array_walk_back!(host, program, machine, call, FindLast)
		"findLastIndex" => array_walk_back!(host, program, machine, call, FindLastIndex)
		"reduce" => array_reduce!(host, program, machine, call, Forward)
		"reduceRight" => array_reduce!(host, program, machine, call, Backward)
		"sort" => array_sort!(host, program, machine, call)
		_ => {
			arguments = Machine.arguments_of(machine, call.count)
			{ cells, machine: rest } = Machine.lent(machine)
			Machine.with_got(rest, ArrayRules.array_method(Machine.shell(cells, rest), call.id, call.name, arguments, call.at), call.result_at)
		}
	}

# A method's first argument, its callback.
callback_of : Machine.Machine, ArrayCall -> Heap.Value
callback_of = |machine, call|
	if call.count == 0 {
		Undefined
	} else {
		Machine.value_at(machine, call.count)
	}

Walk : [ForEach, Map, Filter, Some, Every, Find, FindIndex, FlatMap]

# An array method that calls a function on each item in turn, the items
# read from the heap as it goes, since the function may change the array.
array_walk! : Canvas.Host, Bytecode.Program, Machine.Machine, ArrayCall, Walk => Machine.Machine
array_walk! = |host, program, machine, call, walk| {
	callback = callback_of(machine, call)
	count = item_count(machine, call.id)
	{ machine: started, building } = if walk == Map or walk == Filter or walk == FlatMap {
		{ machine: made, id } = Machine.placed(machine, Array([]))
		{ machine: Machine.pushed(made, Reference(id)), building: Into(id) }
	} else {
		{ machine: machine, building: Answering }
	}
	var $machine = started
	var $answer = match walk {
		Some => Boolean(False)
		Every => Boolean(True)
		FindIndex => Number(-1.0)
		_ => Undefined
	}
	var $i = 0
	var $going = True
	while $going and $i < count and $i < item_count($machine, call.id) {
		item = item_at($machine, call.id, $i)
		{ machine: after, value } = answered(call_function!(host, program, Machine.pushed($machine, item), { callee: callback, arguments: [item, Number($i.to_f64()), Reference(call.id)], at: call.at }))
		if !Machine.is_running(after) {
			$machine = after
			$going = False
		} else {
			# The item waited on the stack beneath the call, since the callback
			# may take it out of the array; `filter` and `find` keep it.
			$machine = Machine.dropped(after, 1)
			match walk {
				ForEach => {}
				Map => {
					$machine = with_built($machine, building, [value])
				}
				Filter => {
					if ValueRules.is_truthy(value) {
						$machine = with_built($machine, building, [item])
					}
				}
				Some => {
					if ValueRules.is_truthy(value) {
						$answer = Boolean(True)
						$going = False
					}
				}
				Every => {
					if !ValueRules.is_truthy(value) {
						$answer = Boolean(False)
						$going = False
					}
				}
				Find => {
					if ValueRules.is_truthy(value) {
						$answer = item
						$going = False
					}
				}
				FindIndex => {
					if ValueRules.is_truthy(value) {
						$answer = Number($i.to_f64())
						$going = False
					}
				}
				FlatMap => {
					more = match value {
						Reference(made) => match Heap.cell_at($machine.cells, made) {
							Array(items) => items
							_ => [value]
						}
						_ => [value]
					}
					$machine = with_built($machine, building, more)
				}
			}
		}
		$i = $i + 1
	}
	answer = match building {
		Into(out) => Reference(out)
		Answering => $answer
	}
	if Machine.is_running($machine) {
		Machine.with_result($machine, call.result_at, answer)
	} else {
		$machine
	}
}

# The array `map`, `filter` or `flatMap` builds, with `values` pushed.
with_built : Machine.Machine, [Into(U64), Answering], List(Heap.Value) -> Machine.Machine
with_built = |machine, building, values|
	match building {
		Into(out) => { ..machine, cells: Heap.with_items_pushed(machine.cells, out, values) }
		Answering => crash "Vm.with_built: only map, filter and flatMap build an array"
	}

# `findLast` and `findLastIndex`: the callback on each item from the last
# back, until one passes.
array_walk_back! : Canvas.Host, Bytecode.Program, Machine.Machine, ArrayCall, [FindLast, FindLastIndex] => Machine.Machine
array_walk_back! = |host, program, machine, call, walk| {
	callback = callback_of(machine, call)
	var $machine = machine
	var $k = item_count(machine, call.id)
	var $answer = match walk {
		FindLast => Undefined
		FindLastIndex => Number(-1.0)
	}
	var $going = True
	while $going and $k > 0 {
		$k = $k - 1
		item = item_at($machine, call.id, $k)
		# The item waits on the stack beneath the call, as in `array_walk!`.
		{ machine: after, value } = answered(call_function!(host, program, Machine.pushed($machine, item), { callee: callback, arguments: [item, Number($k.to_f64()), Reference(call.id)], at: call.at }))
		$machine = if Machine.is_running(after) {
			Machine.dropped(after, 1)
		} else {
			after
		}
		if Machine.is_running($machine) and ValueRules.is_truthy(value) {
			$answer = match walk {
				FindLast => item
				FindLastIndex => Number($k.to_f64())
			}
			$going = False
		}
		$going = $going and Machine.is_running($machine)
	}
	if Machine.is_running($machine) {
		Machine.with_result($machine, call.result_at, $answer)
	} else {
		$machine
	}
}

# `reduce`, from the first item on, and `reduceRight`, from the last back.
array_reduce! : Canvas.Host, Bytecode.Program, Machine.Machine, ArrayCall, [Forward, Backward] => Machine.Machine
array_reduce! = |host, program, machine, call, direction| {
	callback = callback_of(machine, call)
	count = item_count(machine, call.id)
	start = if call.count > 1 {
		Ok({ accumulated: Machine.value_at(machine, call.count - 1), taken: 0 })
	} else if count == 0 {
		Err(Empty)
	} else {
		first = match direction {
			Forward => 0
			Backward => count - 1
		}
		Ok({ accumulated: item_at(machine, call.id, first), taken: 1 })
	}
	match start {
		Err(Empty) => Machine.with_error(machine, TypeError, "Reduce of empty array with no initial value", call.at)
		Ok({ accumulated, taken }) => {
			var $machine = machine
			var $accumulated = accumulated
			var $done = taken
			while $done < count and Machine.is_running($machine) and (direction == Backward or $done < item_count($machine, call.id)) {
				position = match direction {
					Forward => $done
					Backward => count - 1 - $done
				}
				item = item_at($machine, call.id, position)
				{ machine: after, value } = answered(call_function!(host, program, $machine, { callee: callback, arguments: [$accumulated, item, Number(position.to_f64()), Reference(call.id)], at: call.at }))
				$machine = after
				$accumulated = value
				$done = $done + 1
			}
			if Machine.is_running($machine) {
				Machine.with_result($machine, call.result_at, $accumulated)
			} else {
				$machine
			}
		}
	}
}

# `sort`, stable as JavaScript's is: a merge sort, the comparison a
# function's answer or, with none, the items' text. The items being sorted
# are all the array's, which the stack refers to, so the lists the sort
# holds keep nothing alive the machine doesn't.
array_sort! : Canvas.Host, Bytecode.Program, Machine.Machine, ArrayCall => Machine.Machine
array_sort! = |host, program, machine, call| {
	items = match Heap.cell_at(machine.cells, call.id) {
		Array(values) => values
		_ => crash "Vm.array_sort!: asked only of an array"
	}
	compare = callback_of(machine, call)
	# The items wait on the stack as an array of their own while the
	# comparison runs, since it may change the array being sorted.
	pinned = Machine.allocated(machine, Array(items))
	{ machine: after, values } = merge_sorted!(host, program, pinned, { items: items, compare: compare, at: call.at })
	if Machine.is_running(after) {
		Machine.with_result({ ..after, cells: Heap.with_items(after.cells, call.id, values) }, call.result_at, Reference(call.id))
	} else {
		after
	}
}

merge_sorted! : Canvas.Host, Bytecode.Program, Machine.Machine, { items : List(Heap.Value), compare : Heap.Value, at : Ast.Where } => { machine : Machine.Machine, values : List(Heap.Value) }
merge_sorted! = |host, program, machine, { items, compare, at }| {
	count = items.len()
	if count <= 1 {
		{ machine: machine, values: items }
	} else {
		half = count // 2
		{ machine: first, values: lower } = merge_sorted!(host, program, machine, { items: items.sublist({ start: 0, len: half }), compare: compare, at: at })
		{ machine: second, values: upper } = merge_sorted!(host, program, first, { items: items.drop_first(half), compare: compare, at: at })
		var $machine = second
		var $out = []
		var $i = 0
		var $j = 0
		while $i < lower.len() or $j < upper.len() {
			take_left = if $i >= lower.len() {
				False
			} else if $j >= upper.len() {
				True
			} else {
				left = lower.get($i) ?? crash "Vm.merge_sorted!: inside the lower half"
				right = upper.get($j) ?? crash "Vm.merge_sorted!: inside the upper half"
				{ machine: after, order } = ordering_of!(host, program, $machine, { compare: compare, left: left, right: right, at: at })
				$machine = after
				order != After
			}
			if take_left {
				$out = $out.append(lower.get($i) ?? crash "Vm.merge_sorted!: inside the lower half")
				$i = $i + 1
			} else {
				$out = $out.append(upper.get($j) ?? crash "Vm.merge_sorted!: inside the upper half")
				$j = $j + 1
			}
		}
		{ machine: $machine, values: $out }
	}
}

ordering_of! : Canvas.Host, Bytecode.Program, Machine.Machine, { compare : Heap.Value, left : Heap.Value, right : Heap.Value, at : Ast.Where } => { machine : Machine.Machine, order : [Before, Same, After] }
ordering_of! = |host, program, machine, { compare, left, right, at }|
	match compare {
		Undefined => {
			order = match (left, right) {
				(Undefined, Undefined) => Same
				(Undefined, _) => After
				(_, Undefined) => Before
				_ => match (ValueRules.text_of(machine.cells, left), ValueRules.text_of(machine.cells, right)) {
					(Ok(x), Ok(y)) => ValueRules.ordering_of_text(x, y)
					_ => Same
				}
			}
			{ machine: machine, order: order }
		}
		_ => {
			if !Machine.is_running(machine) {
				{ machine: machine, order: Same }
			} else {
				{ machine: after, value } = answered(call_function!(host, program, machine, { callee: compare, arguments: [left, right], at: at }))
				order = match value {
					Number(x) => if x > 0.0 {
						After
					} else if x < 0.0 {
						Before
					} else {
						Same
					}
					_ => Same
				}
				{ machine: after, order: order }
			}
		}
	}

# `forEach` on a Map or a Set: the callback given each entry's value, its key
# (a Set's value again) and the collection, each entry read from the heap as
# the walk comes to it.
collection_walk! : Canvas.Host, Bytecode.Program, Machine.Machine, { id : U64, count : U64, result_at : U64, at : Ast.Where } => Machine.Machine
collection_walk! = |host, program, machine, { id, count, result_at, at }| {
	callback = if count == 0 {
		Undefined
	} else {
		Machine.value_at(machine, count)
	}
	var $machine = machine
	var $i = 0
	var $going = True
	while $going and Machine.is_running($machine) {
		{ step, after: place } = CollectionRules.step_at($machine.cells, id, Entries, $i)
		$i = place
		match step {
			YieldPair(key, value) => {
				{ machine: after, value: _ } = answered(call_function!(host, program, $machine, { callee: callback, arguments: [value, key, Reference(id)], at: at }))
				$machine = after
			}
			Skip => {}
			Yield(_) | Ended => {
				$going = False
			}
		}
	}
	if Machine.is_running($machine) {
		Machine.with_result($machine, result_at, Undefined)
	} else {
		$machine
	}
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
			_ => not_iterable(machine, source, at)
		}
		Text(text) => {
			characters = ValueRules.characters(text).map(|character| Text(character))
			{ machine: made, id } = Machine.placed(machine, Array(characters))
			Machine.replaced(made, 1, Reference(id))
		}
		_ => not_iterable(machine, source, at)
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
	id = reference_id(Machine.slot_value(machine, slot))
	match ValueRules.kind_of(machine.cells, id) {
		IteratorKind => walk_stepped(machine, id, exit)
		_ => {
			position = match Machine.slot_value(machine, slot + 1) {
				Number(at) => at.to_u64_try() ?? crash "Vm.iterated: a `for ... of`'s place is a whole number"
				_ => crash "Vm.iterated: a `for ... of`'s place is a number"
			}
			if position < item_count(machine, id) {
				Machine.pushed(Machine.with_slot(machine, slot + 1, Number((position + 1).to_f64())), item_at(machine, id, position))
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
