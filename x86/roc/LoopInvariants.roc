## This module keeps what a loop can't change out of its trips. The
## lowering reloads an array from the frame and untags it (`shl`, `shr`) at
## each `.length` and each item read or write, and loads its length and its
## items' address again each time; it tests an object's shape (FieldSlots'
## guard, 14 instructions) at each field read and write. A loop that never
## writes the array's or the object's variable, and changes no array's
## length or items and adds no key to an object, finds the same answers
## every trip.
##
## **THE PLAN** (`plans`, from the bytecode, before a function is lowered).
## Each loop (a `Loop` and its head, the outer ones of a nest first) is
## planned when:
##
## - every instruction from its head to its `Loop` is one `keeps_facts`
##   names: reads, arithmetic, the slots' loads and stores, the jumps, new
##   arrays and objects (which no older name reaches), and item and
##   property writes, whose ways in line change no length, no items'
##   address and no key, and whose slow ways find every fact again
##   (`refresh_items`, below); no call, no method, no `++` of an item or a
##   property, no `for ... of`, no spread, no closure, no `try`;
## - no jump enters it but at its head, and none leaves it backwards
##   (Versioning's rule);
## - no place of it is a versioned loop's generic copy (`excluded`), which a
##   side exit enters mid-loop, past anything placed before its head.
##
## Its **arrays** are the slots a `LoadLocal` in it pushes as an item read's
## or write's receiver or a `.length`'s; its **fields** are each slot and
## key `o.k` reads, for a key FieldSlots expects at some place. A slot the
## loop writes is neither, and so is one a planned loop around it keeps
## already. Each array gets three slots past the frame's (`frame_size`), for
## its untagged record's address, its length and its items' address; each
## field one, for the address of its value in the object's entries, or 0.
##
## **THE LOWERING** (Lowering's `code_walk`). At a planned loop's head that
## only the instruction before falls to (no jump from before it lands
## there), the walk places the facts' loads before the head's label
## (`preheader_items`), for each planned slot whose kind there is an array
## (`is_array_kind`) or may be an object, so only the way in runs them and
## every jump back passes them by. A field's load is FieldSlots' guard: the
## value an object, its entries more than an expected place, and the entry
## there holding the key's literal; the value's address when it holds, 0
## when every guess misses. The loop never writes the slot, so it holds the
## same array or object all through the loop, and no instruction's way in
## line changes a length, an items' address or a key, so each fact holds at
## every instruction of the loop; an instruction's slow way that may (an
## item written past the end, a key added) runs `refresh_items`, the loads
## again, right after the runtime's call. The walk follows which stack
## place came from which slot (`origins_after`, forgotten where two ways
## meet), and a `.length`, an item read or write, and a field read or write
## of a place holding a kept array or field use the kept places
## (LoweringBasics' `kept`): no reload, untag or load of the record, and a
## field's value through its kept address after one `test`, its guard run
## in line only when the address is 0. A planned slot whose kind at the way
## in is neither, and a loop whose head a jump from before reaches, keep the
## code as it was.
##
## Registers renames the facts' places like any other (they are plain
## moves), and FrameValues drops the stack places' stores nothing loads any
## longer.
import js.Bytecode
import Assembly
import Boxing
import Emit
import LoweringBasics
import RuntimeBuilders
import Versioning
import X86

LoopInvariants :: [].{

	## A planned loop: its head's place, its `Loop`'s, and what it keeps.
	LoopPlan : {
		head : U64,
		back : U64,
		kept : LoweringBasics.Kept,
	}

	## The code's planned loops (the header's rules), and its frame's size
	## with their slots. `field_slots` is FieldSlots' places for each key.
	plans : Bytecode.Code,
	{ excluded : List(U64), field_slots : Dict(Str, List(U64)) } -> {
		plans : List(LoopInvariants.LoopPlan),
		frame_size : U64,
	}
	plans = |code, { excluded, field_slots }| {
		var $plans = []
		var $frame = code.frame_size
		for (head, back) in Versioning.loop_ranges(code) {
			if is_planned(code, { head, back, excluded }) {
				body = code.ops.sublist({ start: head, len: back - head + 1 })
				written = Versioning.slots_written(body)
				around = $plans.keep_if(|plan| plan.head <= head and plan.back >= back)
				var $arrays = []
				var $fields = []
				for (instruction, at) in body.map_with_index(|instruction, at| (instruction, at)) {
					match instruction {
						LoadLocal(slot) if !written.contains(slot) => {
							array_kept = |kept| kept.arrays.any(|array| array.slot == slot)
							new_array = !$arrays.any(|array| array.slot == slot)
							if new_array and is_array_use(
								body,
								at,
							) and !around.any(|plan| array_kept(plan.kept)) {
								$arrays = $arrays.append({
									slot,
									record: $frame,
									length: $frame + 1,
									items: $frame + 2,
								})
								$frame = $frame + 3
							}
							match body.get(at + 1) {
								Ok(GetProperty(key, _)) if key != "length" =>
									match field_slots.get(key) {
										Ok(guesses) => {
											named = { slot, key }
											kept_around = around.any(
												|plan| holds_field(plan.kept.fields, named),
											)
											if !holds_field($fields, named) and !kept_around {
												$fields = $fields.append({
													slot,
													key,
													guesses,
													value_address: $frame,
												})
												$frame = $frame + 1
											}
										}
										Err(_) => {}
									}
								_ => {}
							}
						}
						_ => {}
					}
				}
				if !$arrays.is_empty() or !$fields.is_empty() {
					$plans = $plans.append({
						head,
						back,
						kept: { arrays: $arrays, fields: $fields },
					})
				}
			}
		}
		{ plans: $plans, frame_size: $frame }
	}

	## What of a plan the way into its loop keeps, given the kinds there: its
	## arrays whose slot holds an array, and its fields whose slot may hold
	## an object.
	kept_at_entry : LoweringBasics.Kept, LoweringBasics.State -> LoweringBasics.Kept
	kept_at_entry = |kept, state| {
		kind_of = |slot|
			match state.slots.get(slot) {
				Ok(Ready(kind)) => Ok(kind)
				_ => Err(NotReady)
			}
		{
			arrays: kept.arrays.keep_if(
				|array|
					match kind_of(array.slot) {
						Ok(kind) => LoopInvariants.is_array_kind(kind)
						Err(_) => False
					},
			),
			fields: kept.fields.keep_if(
				|field|
					match kind_of(field.slot) {
						Ok(Object) | Ok(Value) => True
						_ => False
					},
			),
		}
	}

	## The loads of the facts kept, before a loop's head (`piece` "in") or
	## after a slow way that may have changed them (`piece` "again"): each
	## array's record untagged, its length and its items' address, and each
	## field's guard. Their labels are the site's. They change `rax`, `rcx`,
	## `rdx` and `rdi`, which hold nothing between two instructions or after
	## the runtime's call of a slow way.
	preheader_items : LoweringBasics.Site,
	{
		kept : LoweringBasics.Kept,
		piece : Str,
	} -> List(Assembly.Statement)
	preheader_items = |site, { kept, piece }| {
		arrays = kept.arrays.join_map(
			|array|
				[Emit.load(Rdi, LoweringBasics.slot_place(array.slot))]
					.concat(RuntimeBuilders.unboxed_items(Rdi))
					.concat([
						Emit.store(LoweringBasics.slot_place(array.record), Rdi),
						Emit.load(Rax, Emit.mem(Rdi, 0)),
						Emit.store(LoweringBasics.slot_place(array.length), Rax),
						Emit.load(Rax, Emit.mem(Rdi, 16)),
						Emit.store(LoweringBasics.slot_place(array.items), Rax),
					]),
		)
		fields = kept.fields.map_with_index(|field, at| (field, at)).join_map(
			|(field, at)| field_guard_items(site, { field, label: "kept_${piece}_${at.to_str()}" }),
		)
		arrays.concat(fields)
	}

	## The loads again of every fact the loops around a site keep, for a slow
	## way whose runtime's call may have changed them; nothing outside them.
	refresh_items : LoweringBasics.Site -> List(Assembly.Statement)
	refresh_items = |site| LoopInvariants.preheader_items(site, { kept: site.kept, piece: "again" })

	## Whether a slot's kind says it holds an array, whose record has a
	## length and an items' address.
	is_array_kind : LoweringBasics.Kind -> Bool
	is_array_kind = |kind|
		match kind {
			Array | Numbers | Integers(_) | Int32Items => True
			_ => False
		}

	## What the planned loops `plans` that hold `at` keep there, those the
	## walk loaded at their way in (`active`, each its plan's head and what
	## it kept).
	kept_at : List(LoopInvariants.LoopPlan), U64 -> LoweringBasics.Kept
	kept_at = |active_plans, at| {
		holding = active_plans.keep_if(|plan| plan.head <= at and at <= plan.back)
		{
			arrays: holding.join_map(|plan| plan.kept.arrays),
			fields: holding.join_map(|plan| plan.kept.fields),
		}
	}

	## Whether anything is kept.
	is_kept : LoweringBasics.Kept -> Bool
	is_kept = |kept| !kept.arrays.is_empty() or !kept.fields.is_empty()

	## A field read in line through its kept address (`value`), into
	## `receiver`, when it isn't 0; else `guarded`, FieldSlots' read as it
	## was, which ends at the label `done`.
	field_read_items : LoweringBasics.Site,
	{
		value_address : X86.Mem,
		receiver : X86.Mem,
		done : Str,
		guarded : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	field_read_items = |site, { value_address, receiver, done, guarded }| {
		full = LoweringBasics.inner_label(site, "kept_full")
		[
			Emit.load(Rdi, value_address),
			Emit.test(Rdi, Rdi),
			Emit.jcc(E, full),
			Emit.load(Rax, Emit.mem(Rdi, 0)),
			Emit.store(receiver, Rax),
			Emit.jmp(done),
			Emit.mark(full),
		]
			.concat(guarded)
	}

	## A field written in line through its kept address (`value`), from
	## `value_place`, when it isn't 0; else `guarded`, FieldSlots' write as
	## it was, which ends at the label `done`.
	field_write_items : LoweringBasics.Site,
	{
		value_address : X86.Mem,
		value_place : X86.Mem,
		done : Str,
		guarded : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	field_write_items = |site, { value_address, value_place, done, guarded }| {
		full = LoweringBasics.inner_label(site, "kept_full")
		[
			Emit.load(Rdi, value_address),
			Emit.test(Rdi, Rdi),
			Emit.jcc(E, full),
			Emit.load(Rax, value_place),
			Emit.store(Emit.mem(Rdi, 0), Rax),
			Emit.jmp(done),
			Emit.mark(full),
		]
			.concat(guarded)
	}

	## Where each stack place came from after `instruction`, `after` places
	## deep after it, given where they came from before it. An instruction
	## whose effect on the stack isn't one of those below, or doesn't leave
	## it `after` deep, leaves every place unknown.
	origins_after : List(LoweringBasics.StackOrigin),
	{
		instruction : Bytecode.Op,
		after : U64,
	} -> List(LoweringBasics.StackOrigin)
	origins_after = |origins, { instruction, after }| {
		depth = origins.len()
		top = |down| origins.get(depth - 1 - down) ?? Unknown
		replaced = |taken, given|
			if depth < taken {
				Err(Unsure)
			} else {
				Ok(origins.take_first(depth - taken).concat(List.repeat(Unknown, given)))
			}
		stale = |slot|
			origins.map(
				|origin|
					match origin {
						Slot(held) if held == slot => Unknown
						_ => origin
					},
			)
		made = match instruction {
			LoadLocal(slot) => Ok(origins.append(Slot(slot)))
			Duplicate if depth >= 1 => Ok(origins.append(top(0)))
			DuplicatePair if depth >= 2 => Ok(origins.append(top(1)).append(top(0)))
			Swap if depth >= 2 => Ok(origins.take_first(depth - 2).append(top(0)).append(top(1)))
			Nip if depth >= 2 => Ok(origins.take_first(depth - 2).append(top(0)))
			Rotate if depth >= 3 => {
				below = origins.take_first(depth - 3)
				Ok(below.append(top(1)).append(top(0)).append(top(2)))
			}
			StoreLocal(slot) => Ok(stale(slot))
			SetLocal(slot) if depth >= 1 => Ok(stale(slot).take_first(depth - 1))
			Pop | JumpIfFalse(_) => replaced(1, 0)
			PushNumber(_) | PushText(_) | PushBoolean(_) | PushNull | PushUndefined => replaced(
				0,
				1,
			)
			LoadBoxed(_) | LoadBuiltin(_) => replaced(0, 1)
			Unary(_, _) | GetProperty(_, _) => replaced(1, 1)
			Binary(_, _) | GetIndex(_) | SetProperty(_, _) => replaced(2, 1)
			SetIndex(_) => replaced(3, 1)
			_ => Err(Unsure)
		}
		match made {
			Ok(list) if list.len() == after => list
			_ => List.repeat(Unknown, after)
		}
	}
}

## FieldSlots' guard of a kept field, from its slot: the address of the
## key's value at the first expected place whose entry holds the key's
## literal, or 0, stored in the field's slot. `label` starts its labels.
field_guard_items : LoweringBasics.Site,
{
	field : LoweringBasics.KeptField,
	label : Str,
} -> List(Assembly.Statement)
field_guard_items = |site, { field, label }| {
	missed = LoweringBasics.inner_label(site, "${label}_missed")
	found = LoweringBasics.inner_label(site, "${label}_found")
	tests = field.guesses.join_map(
		|guess| {
			next = LoweringBasics.inner_label(site, "${label}_next_${guess.to_str()}")
			entry = 16 * guess.to_i64_wrap()
			[
				Emit.cmp_imm(Rcx, guess.to_i64_wrap()),
				Emit.jcc(Be, next),
				Emit.load(Rax, Emit.mem(Rdi, entry)),
				Emit.cmp(Rax, Rdx),
				Emit.jcc(Ne, next),
				Emit.lea(Rax, Emit.mem(Rdi, entry + 8)),
				Emit.jmp(found),
				Emit.mark(next),
			]
		},
	)
	[Emit.load(Rdi, LoweringBasics.slot_place(field.slot))]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.object_tag), Emit.jcc(Ne, missed)])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.load(Rcx, Emit.mem(Rdi, 0)),
			Emit.load(Rdi, Emit.mem(Rdi, 16)),
			Emit.address_of(Rdx, LoweringBasics.text_label(site, field.key)),
		])
		.concat(tests)
		.concat([
			Emit.mark(missed),
			Emit.zero(Rax),
			Emit.mark(found),
			Emit.store(LoweringBasics.slot_place(field.value_address), Rax),
		])
}

## Whether the fields hold one of `slot` and `key`.
holds_field : List(LoweringBasics.KeptField), { slot : U64, key : Str } -> Bool
holds_field = |fields, { slot, key }| fields.any(|field| field.slot == slot and field.key == key)

## Whether a loop may be planned: at least one instruction besides its
## `Loop`, each one `keeps_facts` names, no jump into it but at its head and
## none out backwards, and no place excluded.
is_planned : Bytecode.Code,
{
	head : U64,
	back : U64,
	excluded : List(U64),
} -> Bool
is_planned = |code, { head, back, excluded }| {
	if back < head + 1 {
		return False
	}
	inside = |place| place >= head and place <= back
	if excluded.any(inside) {
		return False
	}
	for (instruction, at) in code.ops.map_with_index(|instruction, at| (instruction, at)) {
		if inside(at) and !keeps_facts(instruction) {
			return False
		}
		crossing = match Versioning.target_of(instruction, at) {
			Ok(target) => {
				leaves_backwards = inside(at) and target < head
				enters_inside = !inside(at) and inside(target) and target != head
				leaves_backwards or enters_inside
			}
			Err(NoJump) => False
		}
		if crossing {
			return False
		}
	}
	True
}

## Whether the value the `LoadLocal` at `at` pushes is next an item read's
## or write's receiver, or the receiver of a `.length`.
is_array_use : List(Bytecode.Op), U64 -> Bool
is_array_use = |body_instructions, at|
	match body_instructions.get(at + 1) {
		Ok(GetProperty("length", _)) => True
		_ => Versioning.receiver_use(body_instructions, at)
	}

## Whether an instruction's way in line changes no array's length or items'
## address and adds no key to an object, whatever it is given, and runs no
## code of the program: what changes them is a slow way's runtime call,
## after which the facts are loaded again (the header's list).
keeps_facts : Bytecode.Op -> Bool
keeps_facts = |instruction|
	match instruction {
		PushNumber(_) | PushText(_) | PushBoolean(_) | PushNull | PushUndefined => True
		Pop | Duplicate | DuplicatePair | Nip | Swap | Rotate => True
		LoadLocal(_) | StoreLocal(_) | SetLocal(_) => True
		LoadBoxed(_) | PeekBoxed(_) | StoreBoxed(_) | LoadBuiltin(_) => True
		MissingName(_) | ThrowUnready(_) | ThrowConstant(_) | Refuse(_) => True
		AppendLocal(_) | UpdateLocal(_) => True
		Unary(_, _) | Binary(_, _) | TemplatePart(_) => True
		Jump(_) | Loop(_) | JumpIfFalse(_) | JumpIfSame(_) | ShortIfNullish(_) => True
		SkipIfFalsy(_) | SkipIfTruthy(_) | SkipIfDefined(_) | SkipIfNotUndefined(_) => True
		MakeArray(_) | NewObject | SetField(_) | InstanceOf(_) => True
		GetProperty(_, _) | GetIndex(_) | SetProperty(_, _) | SetIndex(_) => True
		Return | Throw(_) | Finish => True
		_ => False
	}
