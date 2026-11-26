## This module holds the field-slot analysis of the x86-64 lowering: for
## each key a class's constructor sets, the places among an instance's
## entries where it is expected (`field_slots`), and the code that tests
## one of those places in line before a property read or write calls the
## runtime (`slot_read_items`, `slot_write_items`, for Lowering's
## `GetProperty` and `SetProperty`).
##
## An instance's entries are laid out by its making (Lowering's
## `NewInstance`): its mark at place 0, then a key for its class and each
## class that class extends, then its fields in the order its constructor
## sets them. A derived constructor's `super(...)` is a statement of its
## own before any `this` (ClassDesugaring), so the parent's fields come
## first. So a field set in that order has one place in every instance of
## the class.
##
## **The guess never needs to be right.** The test in line is exact: the
## object has more entries than the place, and the entry there holds the
## key's own text, by address. Every key the program writes (`o.k = v`, a
## literal's `k: v`) is stored as its literal's address, and each text sits
## once in the read-only segment, so the same address is the same key. A
## guess that misses (a constructor that branches or calls a method that
## sets fields, a field set later, an object that is no instance, a key
## stored from a string made as the program runs) fails the test and takes
## the runtime's call, which does what it always did. Nothing is ever
## deleted from an object (the subset has no `delete`), and an index key
## that moves the entries up moves the key with its value, so a hit_items is
## always the object's own property, which JavaScript reads before any
## class's method.
import js.Bytecode
import js.Compile
import js.Parser
import Assembly
import Boxing
import Emit
import KnownFunctions
import LoweringBasics
import RuntimeBuilders
import X86

FieldSlots :: [].{

	## Each key a class's constructor sets, with the places an instance's
	## entries are expected to hold it at, the classes' in program order and
	## each place once, at most `most_guesses` of them.
	field_slots : Bytecode.Program, Dict(U64, LoweringBasics.Maker) -> Dict(Str, List(U64))
	field_slots = |program, makers| {
		constructors = constructor_codes(program, makers)
		var $slots = Dict.empty()
		for (made, maker) in makers.to_list() {
			if maker.form == MakesInstances {
				code = program.codes.get(made) ?? crash "FieldSlots.field_slots: a maker's code"
				classes = instance_classes(code)
				first_field = 1 + classes.len()
				fields = class_fields(
					program,
					{ constructors, constructor_name: "#construct ${maker.name}", depth: 0 },
				)
				for (key, place) in fields.map_with_index(|key, place| (key, place)) {
					slot = first_field + place
					guesses = $slots.get(key) ?? []
					if !guesses.contains(slot) and guesses.len() < FieldSlots.most_guesses {
						$slots = $slots.insert(key, guesses.append(slot))
					}
				}
			}
		}
		$slots
	}

	## `receiver.key` read into the receiver's place: the value at an
	## expected place when the entry there holds the key, else `slow_items`,
	## the runtime's call. `receiver_kind` is `Object` or `Value`; a `Value`
	## that isn't an object takes the slow way.
	slot_read_items : LoweringBasics.Site,
	{
		slots : List(U64),
		receiver : X86.Mem,
		receiver_kind : LoweringBasics.Kind,
		key : Str,
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	slot_read_items = |site, { slots, receiver, receiver_kind, key, slow_items }| {
		done_label = LoweringBasics.inner_label(site, "field_done")
		hit_items = |slot| [
			Emit.load(Rax, entry_value_place(slot)),
			Emit.store(receiver, Rax),
			Emit.jmp(done_label),
		]
		guarded_items(site, { slots, receiver, receiver_kind, key, hit_items })
			.concat(slow_items)
			.append(Emit.mark(done_label))
	}

	## `receiver.key = ` the value at `value_place`, written at an expected
	## place when the entry there holds the key, else `slow_items`, the
	## runtime's call.
	slot_write_items : LoweringBasics.Site,
	{
		slots : List(U64),
		receiver : X86.Mem,
		receiver_kind : LoweringBasics.Kind,
		key : Str,
		value_place : X86.Mem,
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	slot_write_items = |
		site,
		{
			slots,
			receiver,
			receiver_kind,
			key,
			value_place,
			slow_items,
		},
	| {
		done_label = LoweringBasics.inner_label(site, "field_done")
		hit_items = |slot| [
			Emit.load(Rax, value_place),
			Emit.store(entry_value_place(slot), Rax),
			Emit.jmp(done_label),
		]
		guarded_items(site, { slots, receiver, receiver_kind, key, hit_items })
			.concat(slow_items)
			.append(Emit.mark(done_label))
	}

	## The test of each expected place of an object's entries, `rcx` their
	## count, `rdi` their address and `rdx` the key's literal: the entries
	## more than the place and the entry's key the literal, then `hit_items`
	## of the place; past every place, the statements after them. They
	## change `rax`.
	entry_tests_items : LoweringBasics.Site,
	{
		slots : List(U64),
		hit_items : U64 -> List(Assembly.Statement),
	} -> List(Assembly.Statement)
	entry_tests_items = |site, { slots, hit_items }|
		slots
			.map(
				|slot| {
					missed = LoweringBasics.inner_label(site, "entry_miss_${slot.to_str()}")
					[
						Emit.cmp_imm(Rcx, slot.to_i64_wrap()),
						Emit.jcc(Be, missed),
						Emit.load(Rax, Emit.mem(Rdi, 16 * slot.to_i64_wrap())),
						Emit.cmp(Rax, Rdx),
						Emit.jcc(Ne, missed),
					]
						.concat(hit_items(slot))
						.append(Emit.mark(missed))
				},
			)
			.join()

	## The most places guessed for one key: each costs a compare and a jump
	## at every read and write of it.
	most_guesses : U64
	most_guesses = 3
}

## How many classes deep `class_fields` follows `super(...)`: a class
## extends only a class declared above it, so a chain never loops, and this
## bounds the walk if a program's codes ever said otherwise.
most_depth : U64
most_depth = 64

## The value of entry `slot` of the entries at `rdi`.
entry_value_place : U64 -> X86.Mem
entry_value_place = |slot| Emit.mem(Rdi, 16 * slot.to_i64_wrap() + 8)

## The tests in line, falling to the statements after them when every
## guess misses: the receiver an object (when its kind is `Value`), its
## entries more than the place, and the entry's key the key's literal; on a
## hit_items, `hit_items` of the place. They change `rax`, `rcx`, `rdx` and `rdi`.
guarded_items : LoweringBasics.Site,
{
	slots : List(U64),
	receiver : X86.Mem,
	receiver_kind : LoweringBasics.Kind,
	key : Str,
	hit_items : U64 -> List(Assembly.Statement),
} -> List(Assembly.Statement)
guarded_items = |site, { slots, receiver, receiver_kind, key, hit_items }| {
	slow_label = LoweringBasics.inner_label(site, "field_slow")
	tag_test =
		if receiver_kind == Value {
			RuntimeBuilders.tag_load_items(Rdi).concat([
				Emit.cmp_imm(Rcx, Boxing.object_tag),
				Emit.jcc(Ne, slow_label),
			])
		} else {
			[]
		}
	opened =
		[Emit.load(Rdi, receiver)]
			.concat(tag_test)
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.load(Rcx, Emit.mem(Rdi, 0)),
				Emit.load(Rdi, Emit.mem(Rdi, 16)),
				Emit.address_of(Rdx, LoweringBasics.text_label(site, key)),
			])
	tests = FieldSlots.entry_tests_items(site, { slots, hit_items })
	opened.concat(tests).append(Emit.mark(slow_label))
}

## The classes an instance of a class-making code is marked with, its own
## first (its `NewInstance`'s).
instance_classes : Bytecode.Code -> List(Str)
instance_classes = |code| {
	for instruction in code.ops {
		match instruction {
			NewInstance(classes) => return classes
			_ => {}
		}
	}
	[]
}

## The code each class's constructor runs, by the name its maker calls it
## by (`#construct C`): the code that makes an instance loads it from a
## cell it captures, and the maker's own code sets that cell from the
## constructor's `MakeClosure`.
constructor_codes : Bytecode.Program, Dict(U64, LoweringBasics.Maker) -> Dict(Str, U64)
constructor_codes = |program, makers| {
	var $found = Dict.empty()
	for (made, maker) in makers.to_list() {
		if maker.form == MakesInstances {
			code = program.codes.get(made) ?? crash "FieldSlots.constructor_codes: a maker's code"
			match constructor_of(program, { code, maker }) {
				Ok(constructor) => {
					$found = $found.insert("#construct ${maker.name}", constructor)
				}
				Err(Unfound) => {}
			}
		}
	}
	$found
}

## The constructor's code that a class-making code calls, or `Unfound`.
constructor_of : Bytecode.Program,
{
	code : Bytecode.Code,
	maker : LoweringBasics.Maker,
} -> Try(U64, [Unfound])
constructor_of = |program, { code, maker }| {
	loaded = code.ops.find_first(
		|instruction|
			match instruction {
				LoadBoxed({ slot: _, name, at: _ }) => name == "#construct ${maker.name}"
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
	parent = program.codes.get(maker.parent) ?? crash "FieldSlots.constructor_of: a maker's parent"
	for at in 0..<parent.ops.len() {
		match (parent.ops.get(at), parent.ops.get(at + 1)) {
			(
				Ok(
					MakeClosure(
						{
							code: made,
							captures: _,
							definition: _,
						},
					),
				),
				Ok(SetBoxed(set)),
			) if set == from =>
				return Ok(made)
			_ => {}
		}
	}
	Err(Unfound)
}

## The fields a class's constructor sets, in order, each once: its parent's
## first, where its `super(...)` calls the parent's constructor, then each
## key it sets a property of.
class_fields : Bytecode.Program,
{
	constructors : Dict(Str, U64),
	constructor_name : Str,
	depth : U64,
} -> List(Str)
class_fields = |program, { constructors, constructor_name, depth }| {
	made = match constructors.get(constructor_name) {
		Ok(found) => found
		Err(_) => return []
	}
	if depth >= most_depth {
		return []
	}
	code = program.codes.get(made) ?? crash "FieldSlots.class_fields: a constructor's code"
	var $fields = []
	for instruction in code.ops {
		named = match instruction {
			SetProperty(key, _) => [key]
			Call({ count: _, written, at: _ }) if written.starts_with("#construct ") =>
				class_fields(
					program,
					{
						constructors,
						constructor_name: written,
						depth: depth + 1,
					},
				)
			_ => []
		}
		for key in named {
			if !$fields.contains(key) {
				$fields = $fields.append(key)
			}
		}
	}
	$fields
}

## Whether `field_slots` gives a program's classes these keys, each with
## these places in any order, and no other key, for the expects.
has_program_slots : List(Str), List((Str, List(U64))) -> Bool
has_program_slots = |source_lines, expected| {
	src = Str.join_with(source_lines, "\n")
	tree = Parser.program_of(src, Core) ?? crash "FieldSlots.has_program_slots: a program"
	program = match Compile.program(tree) {
		Ok(compiled) => compiled
		Err(_) => crash "FieldSlots.has_program_slots: a program that compiles"
	}
	makers = KnownFunctions.makers_of(program) ?? crash "FieldSlots.has_program_slots: its makers"
	slots = FieldSlots.field_slots(program, makers)
	slots.len() == expected.len()
		and expected.all(
			|(key, places)| {
				found = slots.get(key) ?? []
				found.len() == places.len() and places.all(|place| found.contains(place))
			},
		)
}

# A class's fields take the places after its mark and its class's key, in
# the order its constructor sets them, a key set twice at its first.
expect has_program_slots(
	["class A { constructor(v) { this.x = v; this.y = 2; this.x = 3; } }", "new A(1);"],
	[("x", [2]), ("y", [3])],
)

# A subclass's instances hold a key for each class, then its parent's
# fields, set by `super(...)`, before its own: a key two classes set has
# two places.
expect has_program_slots(
	[
		"class A { constructor() { this.x = 1; this.y = 2; } }",
		"class B extends A { constructor() { super(); this.z = 3; } }",
		"new B();",
	],
	[
		("x", [2, 3]),
		("y", [3, 4]),
		("z", [5]),
	],
)

# A near miss of the rule above: a place it doesn't give fails the test.
expect !has_program_slots(["class A { constructor() { this.x = 1; } }", "new A();"], [("x", [3])])
