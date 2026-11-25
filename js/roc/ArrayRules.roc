## This module holds the methods of JavaScript's arrays that call nothing
## back, which the VM (`Vm`) calls by name (`array_method`): what each
## gives and writes, and each refusal and its text, read and audited here
## as the array methods' one home. The methods that call a function of the
## program (`map`, `filter`, `sort` and the rest) run the VM's loop, so the
## VM runs them itself.
##
## A method follows ValueRules' rules (its module doc): it takes the machine
## the VM lends it first, then the rest, and answers a `ValueRules.Got`.
## A method that writes (`push`, `pop`, `splice` ...) writes the array's
## cell in place, so the cells stay unique while it does.
import Ast
import Heap
import ValueRules

ArrayRules :: [].{
	item_count : List(Heap.Cell), U64 -> U64
	item_count = |cells, id|
		match Heap.cell_at(cells, id) {
			Array(items) => items.len()
			_ => crash "ArrayRules.item_count: the interpreter asks only an array for its length"
		}

	item_at : List(Heap.Cell), U64, U64 -> Heap.Value
	item_at = |cells, id, position|
		match Heap.cell_at(cells, id) {
			Array(items) => items.get(position) ?? Undefined
			_ => crash "ArrayRules.item_at: the interpreter asks only an array for an item"
		}

	# Where in `items` from `from` on an item first passes `test`, or none.
	first_place : List(Heap.Value), U64, (Heap.Value -> Bool) -> [Place(U64), NoPlace]
	first_place = |items, from, test| {
		var $found = NoPlace
		var $i = 0
		for item in items {
			if $found == NoPlace and $i >= from and test(item) {
				$found = Place($i)
			}
			$i = $i + 1
		}
		$found
	}

	place_number : [Place(U64), NoPlace] -> F64
	place_number = |found| match found {
		Place(position) => position.to_f64()
		NoPlace => -1.0
	}

	# An array's items with the arrays among them put in their place, to
	# `depth` levels, as `flat` puts them.
	flattened : List(Heap.Cell), List(Heap.Value), U64 -> List(Heap.Value)
	flattened = |cells, items, depth| {
		var $out = []
		for item in items {
			inner = match item {
				Reference(id) if depth > 0 => match Heap.cell_at(cells, id) {
					Array(nested) => Nested(nested)
					_ => Lone
				}
				_ => Lone
			}
			$out = match inner {
				Nested(nested) => List.concat($out, ArrayRules.flattened(cells, nested, depth - 1))
				Lone => $out.append(item)
			}
		}
		$out
	}

	## An array's method, for the methods that call nothing back; the VM runs
	## the others itself.
	array_method : ValueRules.Machine, U64, Str, List(Heap.Value), Ast.Where -> ValueRules.Got
	array_method = |
		machine,
		id,
		name,
		arguments,
		site,
	|
		match name {
			"push" => {
				pushed = { ..machine, cells: Heap.with_items_pushed(machine.cells, id, arguments) }
				{ machine: pushed, value: Number(ArrayRules.item_count(pushed.cells, id).to_f64()) }
			}
			"pop" => {
				count = ArrayRules.item_count(machine.cells, id)
				if count == 0 {
					{ machine: machine, value: Undefined }
				} else {
					last = ArrayRules.item_at(machine.cells, id, count - 1)
					{
						machine: { ..machine, cells: Heap.with_last_dropped(machine.cells, id) },
						value: last,
					}
				}
			}
			"join" => {
				separator = match arguments.first() {
					Ok(Text(text)) => Ok(text)
					Ok(Undefined) => Ok(",")
					Err(ListWasEmpty) => Ok(",")
					_ => Err(NotText)
				}
				match separator {
					Ok(text) => {
						var $parts = []
						var $why = ""
						for item in ValueRules.items_of(machine.cells, id) {
							part = match item {
								Null => Ok("")
								Undefined => Ok("")
								_ => ValueRules.text_of(machine.cells, item)
							}
							match part {
								Ok(phrase) => {
									$parts = $parts.append(phrase)
								}
								Err(Unsupported(why)) => {
									$why = why
								}
							}
						}
						if $why == "" {
							{ machine: machine, value: Text(Str.join_with($parts, text)) }
						} else {
							ValueRules.fault_got(machine, "${$why}${ValueRules.line_note(site)}")
						}
					}
					Err(NotText) => ValueRules.fault_got(
						machine,
						"unsupported: `join` with a separator that is not a string${ValueRules.line_note(site)}",
					)
				}
			}
			"indexOf" => {
				target = arguments.first() ?? Undefined
				items = ValueRules.items_of(machine.cells, id)
				from = ValueRules.relative_index(arguments.get(1) ?? Undefined, items.len(), 0)
				found = ArrayRules.first_place(items, from, |item| ValueRules.is_strictly_equal(item, target))
				{ machine: machine, value: Number(ArrayRules.place_number(found)) }
			}
			"includes" => {
				target = arguments.first() ?? Undefined
				items = ValueRules.items_of(machine.cells, id)
				from = ValueRules.relative_index(arguments.get(1) ?? Undefined, items.len(), 0)
				found = ArrayRules.first_place(items, from, |item| ValueRules.is_same_value_zero(item, target))
				{ machine: machine, value: Boolean(found != NoPlace) }
			}
			"lastIndexOf" => {
				if arguments.len() > 1 {
					ValueRules.fault_got(
						machine,
						"unsupported: `lastIndexOf` from a position${ValueRules.line_note(site)}",
					)
				} else {
					target = arguments.first() ?? Undefined
					items = ValueRules.items_of(machine.cells, id)
					var $found = -1.0
					var $i = 0
					for item in items {
						if ValueRules.is_strictly_equal(item, target) {
							$found = $i.to_f64()
						}
						$i = $i + 1
					}
					{ machine: machine, value: Number($found) }
				}
			}
			"at" => {
				items = ValueRules.items_of(machine.cells, id)
				found = match ValueRules.at_index(arguments.first() ?? Undefined, items.len()) {
					Ok(position) => items.get(position) ?? Undefined
					Err(OutOfRange) => Undefined
				}
				{ machine: machine, value: found }
			}
			"shift" => {
				items = ValueRules.items_of(machine.cells, id)
				match items.first() {
					Ok(head) => {
						machine: { ..machine, cells: Heap.with_items(machine.cells, id, items.drop_first(1)) },
						value: head,
					}
					Err(ListWasEmpty) => { machine: machine, value: Undefined }
				}
			}
			"unshift" => {
				grown = List.concat(arguments, ValueRules.items_of(machine.cells, id))
				count = grown.len()
				{
					machine: { ..machine, cells: Heap.with_items(machine.cells, id, grown) },
					value: Number(count.to_f64()),
				}
			}
			"splice" => {
				items = ValueRules.items_of(machine.cells, id)
				count = items.len()
				start = ValueRules.relative_index(arguments.get(0) ?? Undefined, count, 0)
				removing = match arguments.get(1) {
					Err(OutOfBounds) => if arguments.is_empty() {
						0
					} else {
						count - start
					}
					Ok(Number(wanted)) => {
						if wanted.is_nan() or wanted <= 0.0 {
							0
						} else if wanted >= (count - start).to_f64() {
							count - start
						} else {
							wanted.div_trunc_by(1.0).to_u64_try() ?? 0
						}
					}
					Ok(_) => 0
				}
				removed = items.sublist({ start: start, len: removing })
				kept = List.concat(
					List.concat(items.sublist({ start: 0, len: start }), arguments.drop_first(2)),
					items.drop_first(start + removing),
				)
				ValueRules.alloc({ ..machine, cells: Heap.with_items(machine.cells, id, kept) }, Array(removed))
			}
			"fill" => {
				items = ValueRules.items_of(machine.cells, id)
				count = items.len()
				value = arguments.first() ?? Undefined
				from = ValueRules.relative_index(arguments.get(1) ?? Undefined, count, 0)
				to = ValueRules.relative_index(arguments.get(2) ?? Undefined, count, count)
				filled = items.map_with_index(
					|item, position|
						if position >= from and position < to {
							value
						} else {
							item
						},
				)
				{
					machine: { ..machine, cells: Heap.with_items(machine.cells, id, filled) },
					value: Reference(id),
				}
			}
			"flat" => {
				depth = match arguments.first() {
					Ok(Number(levels)) if levels >= 1.0 => if levels.is_infinite() or levels > 1000.0 {
						1000
					} else {
						levels.div_trunc_by(1.0).to_u64_try() ?? 0
					}
					Ok(Number(_)) => 0
					_ => 1
				}
				ValueRules.alloc(machine, Array(ArrayRules.flattened(machine.cells, ValueRules.items_of(machine.cells, id), depth)))
			}
			"slice" => {
				items = ValueRules.items_of(machine.cells, id)
				count = items.len()
				from = ValueRules.relative_index(arguments.get(0) ?? Undefined, count, 0)
				to = ValueRules.relative_index(arguments.get(1) ?? Undefined, count, count)
				cut = if to > from {
					items.sublist({ start: from, len: to - from })
				} else {
					[]
				}
				ValueRules.alloc(machine, Array(cut))
			}
			"concat" => {
				var $out = ValueRules.items_of(machine.cells, id)
				for argument in arguments {
					$out = match argument {
						Reference(other) => match Heap.cell_at(machine.cells, other) {
							Array(more) => List.concat($out, more)
							_ => $out.append(argument)
						}
						_ => $out.append(argument)
					}
				}
				ValueRules.alloc(machine, Array($out))
			}
			"reverse" => {
				items = ValueRules.items_of(machine.cells, id)
				var $reversed = []
				var $k = items.len()
				while $k > 0 {
					$reversed = $reversed.append(items.get($k - 1) ?? crash "ArrayRules.array_method: inside the items")
					$k = $k - 1
				}
				reversed = $reversed
				{
					machine: { ..machine, cells: Heap.with_items(machine.cells, id, reversed) },
					value: Reference(id),
				}
			}
			"keys" => ValueRules.alloc(machine, Iteration({ source: id, view: Keys, next: 0 }))
			"values" => ValueRules.alloc(machine, Iteration({ source: id, view: Values, next: 0 }))
			"entries" => ValueRules.alloc(machine, Iteration({ source: id, view: Entries, next: 0 }))
			"forEach" | "map" | "filter" | "some" | "every" | "find" | "findIndex" | "flatMap" | "findLast" | "findLastIndex" | "reduce" | "reduceRight" | "sort" => crash "ArrayRules.array_method: the VM runs the methods that call back itself"
			_ => ValueRules.fault_got(
				machine,
				"unsupported: the array method `${name}`${ValueRules.line_note(site)}",
			)
		}
}
