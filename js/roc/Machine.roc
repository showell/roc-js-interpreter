## This module holds the machine the VM (`Vm`) runs a program on: its type
## and its parts (the frames, the handlers, the status, the boxed collector's
## schedule and budget), and the moves every instruction makes on it: its
## status set (`with_fault`, `with_error`) and its steps counted (`stepped`),
## the operand stack pushed and dropped (`pushed`, `dropped`, `with_result`),
## a frame's slots and boxes read and written (`slot_value`, `with_box`), a
## cell placed in the heap (`placed`), the cells lent to a value rule and
## taken back (`lent`, `shell`, `with_got`), and the collector's roots and
## its run between instructions (`roots`, `collected`).
##
## It stands apart from `Vm` because the instructions and the loop share it:
## every handler takes the machine and gives it back through these helpers,
## so they are the one home of how the machine changes. The machine stays a
## closed record (`Machine`, its 256-byte rule with it), so a record update
## is written where it is needed and no helper takes an open record.
import Ast
import Bytecode
import Canvas
import Collector
import Events
import Heap
import ValueRules

Machine :: [].{

	## **THE MACHINE STAYS AT MOST 256 BYTES INLINE.** Every instruction hands
	## it back, and a handler copies it on the way in. LLVM copies a record of
	## up to 256 bytes with eight vector moves, and calls `memcpy` for a bigger
	## one, which took a sixth of fib's time at 312 bytes. So a part an
	## instruction doesn't write sits in a box (the event queue, the turtle,
	## the builtins, the collector's schedule and count, the budget), and the
	## machine is 248 bytes.
	Machine : {
		cells : List(Heap.Cell),
		stack : List(Heap.Value),
		top : U64,
		frames : List(Machine.Frame),
		# How many of `frames` are callers waiting: the ones past it are spent.
		depth : U64,
		handlers : List(Machine.Handler),
		# How many of `handlers` wait: the ones past it are spent.
		handler_count : U64,
		# The timers and the click handler, boxed: an instruction hands the
		# machine back, and only a timer's or a click's touch the queue, so
		# the box keeps every other instruction from copying it.
		events : Box(Events.Queue),
		code : U64,
		pc : U64,
		base : U64,
		# Boxed, as the queue is: made once, at the start.
		builtins : Box(List(Heap.Value)),
		# The first free cell, which the next allocation takes.
		free : Heap.Free,
		# Boxed: only a collection writes it.
		collecting : Box(Machine.Collecting),
		status : Machine.Status,
		steps : U64,
		effects : U64,
		# Boxed: only the start of a run or a callback writes it.
		budget : Box(Machine.Budget),
		# Boxed, as the queue is: only a turtle's move touches it.
		turtle : Box(Canvas.Turtle),
	}

	## When the next collection is due, and how many have run.
	Collecting : { schedule : Machine.Schedule, collections : U64 }

	## When the next collection is due, asked before each instruction:
	## `Doubling(at)`, once no cell is free and the heap holds `at` cells,
	## twice what the last collection kept and never under
	## `Collector.least_threshold`, so a cell costs amortized O(1); or
	## `EveryAllocation`, once the heap's length or its first free cell
	## differs from what the last collection left.
	Schedule : [Doubling(U64), EveryAllocation({ length : U64, free : Heap.Free })]

	## The steps and the effects what is running may take, and what that is,
	## for the message that says one ran out: the program, or the callback the
	## queue runs.
	Budget : { step_limit : U64, effect_limit : U64, budgeted : Machine.Budgeted }

	Budgeted : [TheProgram, FrameCall, TimerCallback, ClickHandler, CollectHandler]

	## A caller's place, kept while its callee runs: its code, the
	## instruction after the call, its frame's base, and where on the stack
	## the callee's answer goes, the place of the function called (or of its
	## receiver, for a method).
	Frame : { code : U64, pc : U64, base : U64, result_at : U64 }

	## A `try`'s handler, waiting for a throw: the frame it is in (its depth,
	## code and base), where its code goes on, how high the stack stood, and
	## what it is for.
	Handler : {
		depth : U64,
		code : U64,
		pc : U64,
		base : U64,
		top : U64,
		kind : Bytecode.Handling,
	}

	Status : [Running, Finished, Faulted(Str), Thrown(Box(ValueRules.Throw))]

	# Whom a budget's message names as running past it.
	budgeted_text : Machine.Budgeted -> Str
	budgeted_text = |budgeted|
		match budgeted {
			TheProgram => "the program"
			FrameCall => "frame(t)"
			TimerCallback => "a timer's callback"
			ClickHandler => "the click handler"
			CollectHandler => "the collect handler"
		}

	code_of : Bytecode.Program, U64 -> Bytecode.Code
	code_of = |program, code| program.codes.get(code) ?? crash "Machine.code_of: a closure names code the program has"

	is_running : Machine.Machine -> Bool
	is_running = |machine| match machine.status {
		Running => True
		_ => False
	}

	with_fault : Machine.Machine, Str -> Machine.Machine
	with_fault = |machine, why| match machine.status {
		Running => { ..machine, status: Faulted(why) }
		_ => machine
	}

	# The machine unwinding with one of JavaScript's own errors.
	with_error : Machine.Machine, Heap.ErrorName, Str, Ast.Where -> Machine.Machine
	with_error = |machine, name, message, at| {
		{ machine: made, id } = Machine.placed(machine, Failure(name, message))
		{ ..made, status: Thrown(Box.box({ value: Reference(id), site: at })) }
	}

	# One more step counted, a call or a loop's pass, stopped past the budget.
	stepped : Machine.Machine -> Machine.Machine
	stepped = |machine| {
		budget = Box.unbox(machine.budget)
		if machine.steps >= budget.step_limit {
			Machine.with_fault(
				machine,
				"${Machine.budgeted_text(budget.budgeted)} ran past its budget of ${budget.step_limit.to_str()} steps",
			)
		} else {
			{ ..machine, steps: machine.steps + 1 }
		}
	}

	# ---- the stack -------------------------------------------------------------

	pushed : Machine.Machine, Heap.Value -> Machine.Machine
	pushed = |machine, value|
		if machine.top < machine.stack.len() {
			{
				..machine,
				stack: machine.stack.set(machine.top, value) ?? crash "Machine.pushed: below the stack's end",
				top: machine.top + 1,
			}
		} else {
			{ ..machine, stack: machine.stack.append(value), top: machine.top + 1 }
		}

	# The value `depth` places down from the top: 1 is the top.
	value_at : Machine.Machine, U64 -> Heap.Value
	value_at = |machine, depth| machine.stack.get(machine.top - depth) ?? crash "Machine.value_at: the compiler pushes what an instruction takes"

	# The machine with its top `count` values given up, their places cleared.
	dropped : Machine.Machine, U64 -> Machine.Machine
	dropped = |machine, count| {
		var $stack = machine.stack
		var $at = machine.top - count
		while $at < machine.top {
			$stack = $stack.set($at, Null) ?? crash "Machine.dropped: below the stack's end"
			$at = $at + 1
		}
		{ ..machine, stack: $stack, top: machine.top - count }
	}

	# The machine with everything from `place` up given up, and `value` there:
	# a call's answer in the place of the function called, a handler's in the
	# place of what it took.
	with_result : Machine.Machine, U64, Heap.Value -> Machine.Machine
	with_result = |machine, place, value| {
		cleared = Machine.dropped(machine, machine.top - place)
		Machine.pushed(cleared, value)
	}

	# The value `depth` places down from the top (1 is the top) set to
	# `value`, the rest kept.
	with_value_at : Machine.Machine, U64, Heap.Value -> Machine.Machine
	with_value_at = |machine, depth, value| {
		..machine,
		stack: machine.stack.set(machine.top - depth, value) ?? crash "Machine.with_value_at: a place on the stack",
	}

	# The top `count` values replaced by `value`.
	replaced : Machine.Machine, U64, Heap.Value -> Machine.Machine
	replaced = |machine, count, value| Machine.with_result(machine, machine.top - count, value)

	duplicated_pair : Machine.Machine -> Machine.Machine
	duplicated_pair = |machine| {
		under = Machine.value_at(machine, 2)
		over = Machine.value_at(machine, 1)
		Machine.pushed(Machine.pushed(machine, under), over)
	}

	nipped : Machine.Machine -> Machine.Machine
	nipped = |machine| Machine.replaced(machine, 2, Machine.value_at(machine, 1))

	swapped : Machine.Machine -> Machine.Machine
	swapped = |machine| {
		under = Machine.value_at(machine, 2)
		over = Machine.value_at(machine, 1)
		Machine.pushed(Machine.pushed(Machine.dropped(machine, 2), over), under)
	}

	rotated : Machine.Machine -> Machine.Machine
	rotated = |machine| {
		first = Machine.value_at(machine, 3)
		second = Machine.value_at(machine, 2)
		third = Machine.value_at(machine, 1)
		Machine.pushed(
			Machine.pushed(Machine.pushed(Machine.dropped(machine, 3), second), third),
			first,
		)
	}

	slot_value : Machine.Machine, U64 -> Heap.Value
	slot_value = |machine, slot| machine.stack.get(machine.base + slot) ?? crash "Machine.slot_value: a slot of the frame"

	with_slot : Machine.Machine, U64, Heap.Value -> Machine.Machine
	with_slot = |machine, slot, value| {
		..machine,
		stack: machine.stack.set(machine.base + slot, value) ?? crash "Machine.with_slot: a slot of the frame",
	}

	local_set : Machine.Machine, U64 -> Machine.Machine
	local_set = |machine, slot| Machine.dropped(
		Machine.with_slot(machine, slot, Machine.value_at(machine, 1)),
		1,
	)

	# The arguments of a call, the top `count` values, as a list of their own:
	# a sublist would share the stack's memory, and the stack's next write in
	# place would copy it.
	arguments_of : Machine.Machine, U64 -> List(Heap.Value)
	arguments_of = |machine, count| {
		var $values = List.with_capacity(count)
		var $at = machine.top - count
		while $at < machine.top {
			$values = $values.append(machine.stack.get($at) ?? crash "Machine.arguments_of: below the stack's end")
			$at = $at + 1
		}
		$values
	}

	# A new cell in the heap, its reference pushed.
	allocated : Machine.Machine, Heap.Cell -> Machine.Machine
	allocated = |machine, cell| {
		{ machine: made, id } = Machine.placed(machine, cell)
		Machine.pushed(made, Reference(id))
	}

	# The machine with `cell` in its heap, and the cell's place: a free cell's
	# when one is free, else a new one at the end.
	Placed : { machine : Machine.Machine, id : U64 }

	placed : Machine.Machine, Heap.Cell -> Machine.Placed
	placed = |machine, cell| {
		{ cells, machine: rest } = Machine.lent(machine)
		made = Heap.allocated(cells, rest.free, cell)
		{ machine: { ..rest, cells: made.cells, free: made.free }, id: made.id }
	}

	# ---- the collector ---------------------------------------------------------

	is_collection_due : Machine.Machine -> Bool
	is_collection_due = |machine|
		match Box.unbox(machine.collecting).schedule {
			Doubling(at) => machine.free == NoneFree and machine.cells.len() >= at
			EveryAllocation(left) => machine.cells.len() != left.length or machine.free != left.free
		}

	# The machine with a collection's event queued for the program's
	# `onCollect` handler, due now, so it runs between instructions as a timer
	# does, never inside the collection. With no handler, the machine as it is.
	with_collection_heard : Machine.Machine, { cells : U64, before : U64, live : U64 } -> Machine.Machine
	with_collection_heard = |machine, heard| {
		queue = Box.unbox(machine.events)
		match queue.on_collect {
			Handler({ handler: _, site }) => {
				held = Events.with_event(queue, { due: queue.clock, site: site, happening: Collected(heard) })
				{ ..machine, events: Box.box(held) }
			}
			NoHandler => machine
		}
	}

	# The machine after a collection, every cell its roots don't reach freed and
	# the next collection scheduled, and how many cells the roots reached.
	collected : Machine.Machine -> { machine : Machine.Machine, live : U64 }
	collected = |machine| {
		marks = Collector.marked(machine.cells, Machine.roots(machine))
		{ cells, machine: rest } = Machine.lent(machine)
		{ cells: swept, free, live } = Collector.swept(cells, marks)
		before = Box.unbox(rest.collecting)
		schedule = match before.schedule {
			Doubling(_) => Doubling(Collector.least_threshold.max(2 * live))
			EveryAllocation(_) => EveryAllocation({ length: swept.len(), free: free })
		}
		collecting = Box.box({ schedule: schedule, collections: before.collections + 1 })
		{
			machine: { ..rest, cells: swept, free: free, collecting: collecting },
			live: live,
		}
	}

	# Every cell the machine names: the live stack's (each frame's slots, its
	# boxes and the function it runs, the callers' values waiting, a `finally`'s
	# throw held), the builtins', a throw's on its way to a handler, and the
	# event queue's (each timer's callback, a frame's closure, the click handler).
	# A handler or a waiting frame names only places on the stack.
	roots : Machine.Machine -> List(U64)
	roots = |machine| {
		builtins = Box.unbox(machine.builtins)
		var $ids = List.with_capacity(machine.top + builtins.len())
		var $at = 0
		while $at < machine.top {
			$ids = Collector.with_value_root($ids, machine.stack.get($at) ?? crash "Machine.roots: below the stack's top")
			$at = $at + 1
		}
		for builtin in builtins {
			$ids = Collector.with_value_root($ids, builtin)
		}
		match machine.status {
			Thrown(boxed) => {
				$ids = Collector.with_value_root($ids, Box.unbox(boxed).value)
			}
			Running | Finished | Faulted(_) => {}
		}
		events = Box.unbox(machine.events)
		for event in events.pending_events {
			$ids = match event.happening {
				Timed({ timer: _, callback, every: _ }) => Collector.with_value_root($ids, callback)
				Framed(closure, _) => $ids.append(closure.scope)
				Clicked(_, _) | Collected(_) => $ids
			}
		}
		match events.on_click {
			Handler({ handler, site: _ }) => {
				$ids = Collector.with_value_root($ids, handler)
			}
			NoHandler => {}
		}
		match events.on_collect {
			Handler({ handler, site: _ }) => {
				$ids = Collector.with_value_root($ids, handler)
			}
			NoHandler => {}
		}
		$ids
	}

	# ---- the value rules, lent the cells ---------------------------------------

	# What a value rule reads and writes of the machine: the cells, the free
	# cells it allocates from, and a status the rule may set to a fault or a
	# throw.
	shell : List(Heap.Cell), Machine.Machine -> ValueRules.Machine
	shell = |cells, rest| { cells: cells, free: rest.free, status: Running }

	# The machine with a rule's cells and free cells put back.
	with_rules : Machine.Machine, ValueRules.Machine -> Machine.Machine
	with_rules = |machine, rules| { ..machine, cells: rules.cells, free: rules.free }

	# The machine without its cells, which a borrowed rule takes: kept apart,
	# the cells have one owner while the rule writes them.
	Lent : { cells : List(Heap.Cell), machine : Machine.Machine }

	lent : Machine.Machine -> Machine.Lent
	lent = |machine| {
		cells = machine.cells
		{ cells: cells, machine: { ..machine, cells: [] } }
	}

	# The machine after a borrowed rule: its cells back, and its value in
	# `place` on the stack, or its fault or throw taken on.
	with_got : Machine.Machine, ValueRules.Got, U64 -> Machine.Machine
	with_got = |machine, got, place| {
		{ machine: ruled, value } = got
		match ruled.status {
			Running => Machine.with_result(Machine.with_rules(machine, ruled), place, value)
			Faulted(why) => { ..Machine.with_rules(machine, ruled), status: Faulted(why) }
			Thrown(boxed) => { ..Machine.with_rules(machine, ruled), status: Thrown(boxed) }
		}
	}

	# ---- boxes -----------------------------------------------------------------

	box_of : Machine.Machine, U64 -> U64
	box_of = |machine, slot| match Machine.slot_value(machine, slot) {
		Reference(id) => id
		_ => crash "Machine.box_of: the compiler names a boxed variable's slot, which holds its box"
	}

	# The value in a box, or the box unready.
	box_content : Machine.Machine, U64 -> [Holding(Heap.Value), Unready]
	box_content = |machine, box| match Heap.cell_at(machine.cells, box) {
		Variable(value) => Holding(value)
		UnreadyVariable => Unready
		_ => crash "Machine.box_content: a boxed slot holds a box"
	}

	with_box : Machine.Machine, U64, Heap.Value -> Machine.Machine
	with_box = |machine, box, value| {
		..machine,
		cells: machine.cells.set(
			box,
			Variable(value),
		) ?? crash "Machine.with_box: a box the heap has",
	}
}
