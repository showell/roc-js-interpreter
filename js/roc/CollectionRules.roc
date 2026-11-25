## This module holds the walks over JavaScript's arrays, strings, Maps and
## Sets and the methods of Maps and Sets, which the VM (`Vm`) and the
## builtins (`BuiltinRules`) call: what a spread, a pattern or `for ... of`
## takes from a value (`iterated`), where a walk of entries is and what its
## next step gives (`step_at`), and what `new Map`, `new Set` and their
## methods give and write (`collection_made`, `collection_method`), each
## refusal in its words. It is the one home of a walk's order over a
## `Heap.Table`, so a Map's entries are met in the order JavaScript gives.
##
## A rule follows ValueRules' rules (its module doc): it takes the machine
## the VM lends it first, then the rest, and answers a `ValueRules.Got` (or
## an `Iterated`, the machine handed back in every arm).
import Ast
import Heap
import ValueRules

CollectionRules :: [].{
	# The values a spread, a pattern or a collection's constructor takes from
	# what it is given, as `for ... of` takes them: an array's items, a
	# string's characters, a Map's entries as pairs, a Set's values, or what
	# an iterator has left, which then has nothing more.
	#
	# The machine comes back whether or not the value is iterable, so no
	# caller keeps its own while this one writes.
	iterated : ValueRules.Machine, Heap.Value -> CollectionRules.Iterated
	iterated = |machine, subject|
		match subject {
			Reference(id) => match ValueRules.kind_of(machine.cells, id) {
				ArrayKind(_) => {
					items = ValueRules.items_of(machine.cells, id)
					{ machine: machine, values: Ok(items) }
				}
				MapKind => CollectionRules.iterated_ok(CollectionRules.stepped(machine, { source: id, view: Entries, next: 0 }))
				SetKind => CollectionRules.iterated_ok(CollectionRules.stepped(machine, { source: id, view: Values, next: 0 }))
				IteratorKind => {
					walk = CollectionRules.iteration_of(machine.cells, id)
					{ machine: after, values } = CollectionRules.stepped(machine, walk)
					end = CollectionRules.walk_length(after.cells, walk.source)
					{
						machine: { ..after, cells: Heap.with_iterator_at(after.cells, id, end) },
						values: Ok(values),
					}
				}
				_ => { machine: machine, values: Err(NotIterable) }
			}
			Text(text) => {
				machine: machine,
				values: Ok(ValueRules.characters(text).map(|character| Text(character))),
			}
			_ => { machine: machine, values: Err(NotIterable) }
		}

	Iterated : { machine : ValueRules.Machine, values : Try(List(Heap.Value), [NotIterable]) }

	iterated_ok : ValueRules.Evaluations -> CollectionRules.Iterated
	iterated_ok = |{ machine, values }| { machine: machine, values: Ok(values) }

	## Where a walk of entries is: the array, Map or Set walked, what it gives
	## of each entry, and the next entry's place.
	EntryWalk : { source : U64, view : Heap.View, next : U64 }

	## One entry of a walk: a value given, a pair given (an entry's key and
	## value, made into an array where it is used), a deleted entry passed
	## over, or the end.
	Step : [Yield(Heap.Value), YieldPair(Heap.Value, Heap.Value), Skip, Ended]

	## A walk's step and the place after it, where the walk goes on: an
	## array's next index, or the ordinal after the table's entry met
	## (`Heap.Table`).
	Stepped : { step : CollectionRules.Step, after : U64 }

	step_at : List(Heap.Cell), U64, Heap.View, U64 -> CollectionRules.Stepped
	step_at = |cells, source, view, position| {
		cell = Heap.cell_at(cells, source)
		match cell {
			Array(items) => {
				step = match items.get(position) {
					Ok(item) => match view {
						Keys => Yield(Number(position.to_f64()))
						Values => Yield(item)
						Entries => YieldPair(Number(position.to_f64()), item)
					}
					Err(OutOfBounds) => Ended
				}
				{ step: step, after: position + 1 }
			}
			MapOf(_) | SetOf(_) => match Heap.entry_from(Heap.table_of(cell), position) {
				Met({ ordinal, held }) => {
					step = match held {
						Standing({ key, value }) => CollectionRules.entry_step(cell, view, key, value)
						Gone => Skip
					}
					{ step: step, after: ordinal + 1 }
				}
				NoneLeft => { step: Ended, after: position }
			}
			_ => crash "CollectionRules.step_at: a walk's source is an array, a Map or a Set"
		}
	}

	# What a walk gives of a standing entry. A Set's value is its key, as it
	# was first added.
	entry_step : Heap.Cell, Heap.View, Heap.Value, Heap.Value -> CollectionRules.Step
	entry_step = |cell, view, key, value|
		match cell {
			SetOf(_) => match view {
				Entries => YieldPair(key, key)
				_ => Yield(key)
			}
			_ => match view {
				Keys => Yield(key)
				Values => Yield(value)
				Entries => YieldPair(key, value)
			}
		}

	# The place a walk of its source ends at: an array's length, or the
	# ordinal its table's next entry will take.
	walk_length : List(Heap.Cell), U64 -> U64
	walk_length = |cells, source| {
		cell = Heap.cell_at(cells, source)
		match cell {
			Array(items) => items.len()
			_ => Heap.table_of(cell).next_ordinal
		}
	}

	iteration_of : List(Heap.Cell), U64 -> CollectionRules.EntryWalk
	iteration_of = |cells, id|
		match Heap.cell_at(cells, id) {
			Iteration(walk) => walk
			_ => crash "CollectionRules.iteration_of: the interpreter asks only an iterator where it walks"
		}

	# The values a walk gives from its place to its source's end, each pair
	# made into an array.
	stepped : ValueRules.Machine, CollectionRules.EntryWalk -> ValueRules.Evaluations
	stepped = |machine, { source, view, next }| {
		var $s = machine
		var $values = []
		var $i = next
		var $going = True
		while $going {
			{ step, after } = CollectionRules.step_at($s.cells, source, view, $i)
			$i = after
			match step {
				Yield(value) => {
					$values = $values.append(value)
				}
				YieldPair(key, value) => {
					{ machine: made, value: pair } = ValueRules.alloc($s, Array([key, value]))
					$s = made
					$values = $values.append(pair)
				}
				Skip => {}
				Ended => {
					$going = False
				}
			}
		}
		{ machine: $s, values: $values }
	}

	# `new Map(entries)` or `new Set(values)`: the collection, filled from
	# what is given in its order, or empty for nothing, `null` or `undefined`.
	collection_made : ValueRules.Machine, ValueRules.Collection, List(Heap.Value), Ast.Where -> ValueRules.Got
	collection_made = |machine, collection, arguments, site| {
		{ machine: made, value: collection_value } = ValueRules.alloc(
			machine,
			match collection {
				IsMap => MapOf([Heap.empty_table])
				IsSet => SetOf([Heap.empty_table])
			},
		)
		id = match collection_value {
			Reference(placed) => placed
			_ => crash "CollectionRules.collection_made: an allocation answers a reference"
		}
		given = arguments.first() ?? Undefined
		if ValueRules.is_nullish(given) {
			{ machine: made, value: collection_value }
		} else {
			{ machine: walked, values: given_values } = CollectionRules.iterated(made, given)
			match given_values {
				Err(NotIterable) => {
					machine: ValueRules.with_not_iterable(walked, given, Argument, site),
					value: Undefined,
				}
				Ok(values) => {
					var $s = walked
					for each in values {
						if ValueRules.is_running($s) {
							$s = match collection {
								IsSet => { ..$s, cells: Heap.with_entry($s.cells, id, each, each) }
								IsMap => match CollectionRules.entry_of($s.cells, each) {
									Ok({ key, value }) => { ..$s, cells: Heap.with_entry($s.cells, id, key, value) }
									Err(NotEntry) => {
										shown = ValueRules.text_of($s.cells, each) ?? ValueRules.type_of($s.cells, each)
										ValueRules.with_error(
											$s,
											TypeError,
											"Iterator value ${shown} is not an entry object",
											site,
										)
									}
								}
							}
						}
					}
					{ machine: $s, value: Reference(id) }
				}
			}
		}
	}

	# A Map's entry as `new Map` reads one: an array's first two items, or an
	# object's properties "0" and "1".
	entry_of : List(Heap.Cell), Heap.Value -> Try({ key : Heap.Value, value : Heap.Value }, [NotEntry])
	entry_of = |cells, subject|
		match subject {
			Reference(id) => match Heap.cell_at(cells, id) {
				Array(items) => Ok({ key: items.get(0) ?? Undefined, value: items.get(1) ?? Undefined })
				Object(properties) | Instance(_, properties) => Ok({
					key: Heap.property_value(properties, "0"),
					value: Heap.property_value(properties, "1"),
				})
				_ => Ok({ key: Undefined, value: Undefined })
			}
			_ => Err(NotEntry)
		}

	# A Map's or a Set's method: a Map's `get` and `set`, a Set's `add`, and
	# what both have, `has`, `delete`, `clear`, `forEach`, `keys`, `values`
	# and `entries`; the VM runs `forEach` itself.
	collection_method : ValueRules.Machine, { id : U64, collection : ValueRules.Collection }, Str, List(Heap.Value), Ast.Where -> ValueRules.Got
	collection_method = |machine, { id, collection }, name, arguments, site| {
		key = arguments.first() ?? Undefined
		match (collection, name) {
			(IsMap, "get") => {
				table = Heap.table_of(Heap.cell_at(machine.cells, id))
				found = match Heap.entry_value(table, key) {
					Ok(value) => value
					Err(Missing) => Undefined
				}
				{ machine: machine, value: found }
			}
			(IsMap, "set") => {
				value = arguments.get(1) ?? Undefined
				{
					machine: { ..machine, cells: Heap.with_entry(machine.cells, id, key, value) },
					value: Reference(id),
				}
			}
			(IsSet, "add") => {
				machine: { ..machine, cells: Heap.with_entry(machine.cells, id, key, key) },
				value: Reference(id),
			}
			(_, "has") => {
				table = Heap.table_of(Heap.cell_at(machine.cells, id))
				{ machine: machine, value: Boolean(Heap.entry_value(table, key).is_ok()) }
			}
			(_, "delete") => {
				table = Heap.table_of(Heap.cell_at(machine.cells, id))
				stood = Heap.entry_value(table, key).is_ok()
				if stood {
					{
						machine: { ..machine, cells: Heap.without_entry(machine.cells, id, key) },
						value: Boolean(True),
					}
				} else {
					{ machine: machine, value: Boolean(False) }
				}
			}
			(_, "clear") => { machine: { ..machine, cells: Heap.cleared(machine.cells, id) }, value: Undefined }
			(_, "forEach") => crash "CollectionRules.collection_method: the VM runs `forEach` itself"
			(_, "keys") => ValueRules.alloc(machine, Iteration({ source: id, view: Keys, next: 0 }))
			(_, "values") => ValueRules.alloc(machine, Iteration({ source: id, view: Values, next: 0 }))
			(_, "entries") => ValueRules.alloc(machine, Iteration({ source: id, view: Entries, next: 0 }))
			_ => ValueRules.fault_got(
				machine,
				"unsupported: the ${ValueRules.collection_name(collection)} method `${name}`${ValueRules.line_note(site)}",
			)
		}
	}
}
