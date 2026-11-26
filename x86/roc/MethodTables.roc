## This module holds the method-table analysis of the x86-64 lowering: for
## each key a class's table holds, the places among the table's entries
## where it is expected and the codes of the methods it may hold
## (`method_tables`), and the code that reads a method from an instance's
## table in line before a method's lookup calls the runtime
## (`table_read_items`, for Lowering's `MethodLookup`).
##
## A class's table (ClassDesugaring's `#methods C`) is an object literal
## made once, where the class is declared: its parent's table spread, then
## each of the class's own methods, a closure set under its name, which
## replaces a parent's of that name in its place, then each parent's method
## its methods call through `super`, under its `super` key. Nothing else
## writes a table, and no program can name one, so a key has one place in
## every table of a class, and holds one code.
##
## **The guess never needs to be right.** The read in line is exact: the
## receiver an instance (its first entry the instance's mark, whose value
## is its class's table), no method ever shadowed (`Runtime.shadowed_place`),
## the table more entries than the place and the entry there the key's
## literal, by address. That is what `runtime_get_method_hashed` reads
## then, the table's entry of the key, so the value is the same. A miss
## anywhere takes the runtime's call, which does what it always did. A call
## of what the read found is tested apart (CallLowering's
## `method_call_items`), by the code its closure enters.
import js.Bytecode
import Assembly
import Boxing
import Emit
import FieldSlots
import KnownFunctions
import LoweringBasics
import Runtime
import RuntimeBuilders
import X86

MethodTables :: [].{

	## Each key a class's table holds, with the places a table's entries are
	## expected to hold it at and the codes it may hold, each once, at most
	## `FieldSlots.most_guesses` of each.
	method_tables : LoweringBasics.Known -> LoweringBasics.MethodGuesses
	method_tables = |known| {
		parts_by_class = class_table_parts(known.program, known.makers)
		var $places = Dict.empty()
		var $codes = Dict.empty()
		for (name, _) in parts_by_class.to_list() {
			match table_entries(parts_by_class, { name, depth: 0 }) {
				Ok(entries) =>
					for (entry, place) in entries.map_with_index(|entry, place| (entry, place)) {
						places = with_guess($places.get(entry.key) ?? [], place)
						$places = $places.insert(entry.key, places)
						match entry.held {
							Code(made) => {
								codes = with_guess($codes.get(entry.key) ?? [], made)
								$codes = $codes.insert(entry.key, codes)
							}
							Unknown => {}
						}
					}
				Err(Unfound) => {}
			}
		}
		{ places: $places, codes: $codes }
	}

	## `receiver.key`'s method read into `result`: the value at an expected
	## place of the receiver's class's table when the test in line holds
	## (the header), else `slow_items`, the runtime's call. `receiver_kind`
	## is `Object` or `Value`; a `Value` that isn't an object takes the slow
	## way.
	table_read_items : LoweringBasics.Site,
	{
		places : List(U64),
		receiver : X86.Mem,
		receiver_kind : LoweringBasics.Kind,
		key : Str,
		result : X86.Mem,
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	table_read_items = |
		site,
		{
			places,
			receiver,
			receiver_kind,
			key,
			result,
			slow_items,
		},
	| {
		slow_label = LoweringBasics.inner_label(site, "method_slow")
		done_label = LoweringBasics.inner_label(site, "method_done")
		tag_test =
			if receiver_kind == Value {
				RuntimeBuilders.tag_load_items(Rdi).concat([
					Emit.cmp_imm(Rcx, Boxing.object_tag),
					Emit.jcc(Ne, slow_label),
				])
			} else {
				[]
			}
		# The instance's mark, its first entry, holds its class's table.
		opened =
			[Emit.load(Rdi, receiver)]
				.concat(tag_test)
				.concat([
					Emit.load(Rcx, Runtime.shadowed_place),
					Emit.test(Rcx, Rcx),
					Emit.jcc(Ne, slow_label),
				])
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat([
					Emit.load(Rcx, Emit.mem(Rdi, 0)),
					Emit.test(Rcx, Rcx),
					Emit.jcc(E, slow_label),
					Emit.load(Rdi, Emit.mem(Rdi, 16)),
					Emit.load(Rax, Emit.mem(Rdi, 0)),
					Emit.address_of(Rdx, RuntimeBuilders.instance_mark),
					Emit.cmp(Rax, Rdx),
					Emit.jcc(Ne, slow_label),
					Emit.load(Rdi, Emit.mem(Rdi, 8)),
				])
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat([
					Emit.load(Rcx, Emit.mem(Rdi, 0)),
					Emit.load(Rdi, Emit.mem(Rdi, 16)),
					Emit.address_of(Rdx, LoweringBasics.text_label(site, key)),
				])
		hit_items = |place| [
			Emit.load(Rax, Emit.mem(Rdi, 16 * place.to_i64_wrap() + 8)),
			Emit.store(result, Rax),
			Emit.jmp(done_label),
		]
		opened
			.concat(FieldSlots.entry_tests_items(site, { slots: places, hit_items }))
			.append(Emit.mark(slow_label))
			.concat(slow_items)
			.append(Emit.mark(done_label))
	}
}

## How many tables deep `table_entries` follows a spread or a `super` key:
## a class extends only a class declared above it, so a chain never loops,
## and this bounds the walk if a program's codes ever said otherwise.
most_depth : U64
most_depth = 64

## A piece of a class's table literal, in its order: the parent's table
## spread, a method of the class's own under its key, or a parent's method
## under a `super` key.
TablePart : [
	Spread(Str),
	Own({ key : Str, made : U64 }),
	Inherited(
		{
			key : Str,
			parent : Str,
			name : Str,
		},
	),
]

## The pieces of each class's table literal, by the class's name.
PartsByClass : Dict(Str, List(TablePart))

## A key of a table, in its place, and the code its closure runs, where the
## table's literal says.
TableEntry : { key : Str, held : [Code(U64), Unknown] }

## A list of guesses with one more, kept once, at most
## `FieldSlots.most_guesses` of them.
with_guess : List(U64), U64 -> List(U64)
with_guess = |guesses, guess|
	if guesses.contains(guess) or guesses.len() >= FieldSlots.most_guesses {
		guesses
	} else {
		guesses.append(guess)
	}

## The pieces of each class's table literal, by the class's name, for each
## class whose table the bytecode makes as `table_parts` reads one.
class_table_parts : Bytecode.Program, Dict(U64, LoweringBasics.Maker) -> PartsByClass
class_table_parts = |program, makers| {
	var $found = Dict.empty()
	for (made, maker) in makers.to_list() {
		if maker.form == MakesInstances {
			code = program.codes.get(made) ?? crash "MethodTables.class_table_parts: a maker's code"
			match table_set_place(program, { code, maker }) {
				Ok({ parent, at }) =>
					match table_parts(parent, at) {
						Ok(parts) => {
							$found = $found.insert(maker.name, parts)
						}
						Err(Unfound) => {}
					}
				Err(Unfound) => {}
			}
		}
	}
	$found
}

## Where the class's table is set: the code that declares the class, and
## the place of its `SetBoxed` of the table's cell. The code that makes an
## instance loads the table from a cell it captures (`#methods C`).
table_set_place : Bytecode.Program,
{
	code : Bytecode.Code,
	maker : LoweringBasics.Maker,
} -> Try({ parent : Bytecode.Code, at : U64 }, [Unfound])
table_set_place = |program, { code, maker }| {
	loaded = code.ops.find_first(
		|instruction|
			match instruction {
				LoadBoxed({ slot: _, name, at: _ }) => name == "#methods ${maker.name}"
				_ => False
			},
	)
	slot = match loaded {
		Ok(
			LoadBoxed(
				{
					slot: held,
					name: _,
					at: _,
				},
			),
		) => held
		_ => return Err(Unfound)
	}
	capture = KnownFunctions.capture_holding(code, slot)?
	from = match maker.captures.get(capture) {
		Ok(held) => held
		Err(_) => return Err(Unfound)
	}
	parent = program.codes.get(maker.parent) ?? crash "MethodTables.table_set_place: a parent"
	for at in 0..<parent.ops.len() {
		match parent.ops.get(at) {
			Ok(SetBoxed(set)) if set == from => return Ok({ parent, at })
			_ => {}
		}
	}
	Err(Unfound)
}

## The pieces of the table literal that ends just before the instruction at
## `at`, read back to its `NewObject`, or `Unfound` for anything else there.
table_parts : Bytecode.Code, U64 -> Try(List(TablePart), [Unfound])
table_parts = |code, at| {
	before = |back|
		if back > at {
			Err(Unfound)
		} else {
			code.ops.get(at - back).map_err(|_| Unfound)
		}
	var $back = 1
	var $parts = []
	while True {
		match before($back)? {
			NewObject => return Ok($parts)
			SpreadFields(_) =>
				match before($back + 1)? {
					LoadBoxed({ slot: _, name, at: _ }) => {
						$parts = [Spread(class_of_table(name)?)].concat($parts)
						$back = $back + 2
					}
					_ => return Err(Unfound)
				}
			SetField(key) =>
				match before($back + 1)? {
					MakeClosure(
						{
							code: made,
							captures: _,
							definition: _,
						},
					) => {
						$parts = [Own({ key, made })].concat($parts)
						$back = $back + 2
					}
					GetProperty(name, _) =>
						match before($back + 2)? {
							LoadBoxed(
								{
									slot: _,
									name: table,
									at: _,
								},
							) => {
								parent = class_of_table(table)?
								$parts = [Inherited({ key, parent, name })].concat($parts)
								$back = $back + 3
							}
							_ => return Err(Unfound)
						}
					_ => return Err(Unfound)
				}
			_ => return Err(Unfound)
		}
	}
}

## The class whose table a cell's name (`#methods C`) names.
class_of_table : Str -> Try(Str, [Unfound])
class_of_table = |name| {
	prefix = "#methods "
	if !name.starts_with(prefix) {
		return Err(Unfound)
	}
	bytes = name.to_utf8().drop_first(prefix.count_utf8_bytes())
	Str.from_utf8(bytes).map_err(|_| Unfound)
}

## The entries of class `name`'s table, in order, as its literal makes
## them: a key set again keeps its place and takes the new value.
table_entries : PartsByClass, { name : Str, depth : U64 } -> Try(List(TableEntry), [Unfound])
table_entries = |parts_by_class, { name, depth }| {
	if depth >= most_depth {
		return Err(Unfound)
	}
	parts = match parts_by_class.get(name) {
		Ok(found) => found
		Err(_) => return Err(Unfound)
	}
	var $entries = []
	for part in parts {
		match part {
			Spread(parent) =>
				for entry in table_entries(parts_by_class, { name: parent, depth: depth + 1 })? {
					$entries = entries_with($entries, entry)
				}
			Own({ key, made }) => {
				$entries = entries_with($entries, { key, held: Code(made) })
			}
			Inherited({ key, parent, name: method }) => {
				inherited = table_entries(parts_by_class, { name: parent, depth: depth + 1 })?
				held = match inherited.find_first(|entry| entry.key == method) {
					Ok(entry) => entry.held
					Err(_) => Unknown
				}
				$entries = entries_with($entries, { key, held })
			}
		}
	}
	Ok($entries)
}

## The entries with one set: in the place of the entry of its key, or
## after them all.
entries_with : List(TableEntry), TableEntry -> List(TableEntry)
entries_with = |entries, entry|
	match entries.find_first_index(|old| old.key == entry.key) {
		Ok(place) => entries.set(place, entry) ?? crash "MethodTables.entries_with: a place found"
		Err(_) => entries.append(entry)
	}
