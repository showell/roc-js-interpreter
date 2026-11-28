## This module lowers an array's commonest reads and writes in line: its
## `length` (`length_items`), an item read (`item_read_items`) and an item
## written in place (`item_write_items`). Each tests in line what isn't
## known before the program runs (the receiver an array, the index a whole
## number inside the array) and does the work with a load or a store; when a
## test fails it calls the runtime's routine, which does everything else
## (a string, an object, an append, `undefined` past the end, node's
## TypeError of `undefined` or `null`), so the answer is the routine's
## either way.
##
## It stands apart from Lowering because the three share their tests and
## none of them needs the walk: Lowering's dispatch hands each its site, the
## places and the kinds, and the routine's call for the slow way.
##
## **AN INDEX CHECKED ONCE IN A STRAIGHT RUN IS NOT CHECKED AGAIN.** The
## walk carries a `Checked` along a straight run of instructions
## (`checked_after`): where each place of the bytecode's stack came from (a
## variable's slot, by `LoadLocal`, or anything else), and what an item read
## of an array of numbers (`Numbers`) has proved, whose slow way stops the
## program, so after it the fast way's tests held: the index's slot holds a
## whole number, and it is below the length of the array in the receiver's
## slot. A later read or write of an array of numbers whose receiver and
## index came from those same slots (`checks_for`) skips the tests already
## proved. The rule is kept conservative: what was proved is forgotten
## wholly at any place two ways reach (a jump's target that another jump or
## the instruction before also reaches, a loop's head); at a place one jump
## alone reaches, nothing falling to it, what that jump's way proved of the
## slots holds (`proofs_at_target`), as the `else` of an `if` keeps what was
## proved before the test,
## at every instruction but a few that change no variable but the one they
## name and no array's length but by growing it (a push of a number, text, a
## boxed variable's value or a copy; a load of a slot; a store or set of a
## slot, which forgets that slot; `Pop` and `JumpIfFalse`; `+ - * /` and the
## orderings of two known numbers; and an item read or write of an array of
## numbers, whose slow way stops or appends), so a call, a method (`push`,
## `pop`, `splice`) and any instruction that makes code run are among those
## that forget it. A length only grows between, so an index below it stays
## below it.
##
## **A LOOP'S COUNTER IS KNOWN TO HOLD NO FRACTION.** A slot's whole-number
## proof means it holds no fraction: a whole number, or an infinity or a
## NaN, which the range test still sends to the slow way (`cvttsd2si` makes
## either `0x8000000000000000`, at or past any length), so the whole-number
## test can be skipped where it holds and the range test kept. Besides an
## item read, a store or set of a slot proves it from what is stored: a
## whole number literal, a slot already proved, or `+`, `-` or `*` of two
## such known numbers, which overflow to an infinity or a NaN but never to
## a fraction. At a loop's head that only the instruction before falls to
## (no jump comes to it from ahead), the walk takes the slots proved there
## to hold no fraction on every way round (`at_loop_head`) and checks the
## guess at each jump back: a slot one doesn't prove (`unkept_at_back`) is
## doubted, and the function is lowered again without it, as a loop's kinds
## are widened. Nothing but those proofs passes the head. So `let i = 0`
## then `i = i + 1` in a loop proves `i` all through the loop, and `a[i]`
## skips the whole-number test, overflow included, with no guard.
##
## **A `for ... of` OVER AN ARRAY STEPS IN LINE.** A walk's step
## (`IterNext`) is otherwise `runtime_next_item`'s, which tells an array from
## a Map, a Set and an iterator as the program runs. When the walk's slot
## holds a known array (`walk_step_items`), the step is in line: the place,
## a whole number the walk keeps in the slot after the array's, made an
## integer; the walk's end when it is not below the array's length, read
## anew at each step, so items pushed during the walk are walked, as in
## node; else the item loaded, and the place one more. The item of an array
## of numbers is a known number, and the walk only reads it, so walking one
## keeps it an array of numbers (Lowering's `numbers_escaping`).
## x86/tests/array-walks.js holds walks of both kinds of array, empty ones
## and one that grows as it is walked to node.
import js.Ast
import js.Bytecode
import Assembly
import Boxing
import Emit
import Heap
import LoweringBasics
import RuntimeBuilders
import X86

IndexLowering :: [].{

	## What a straight run has proved of its index checks, the header's rule:
	## each stack place's origin, bottom first, the slots proved to hold whole
	## numbers, and the (array, index) slots proved in range.
	Checked : {
		origins : List(IndexLowering.Origin),
		whole_slots : List(U64),
		slots_in_range : List((U64, U64)),
	}

	## Where a stack place came from: a variable's slot (`LoadLocal`), a
	## number literal (`PushNumber`), a boxed variable (`LoadBoxed`, which
	## holds a known number for good when `KnownFunctions.constant_numbers`
	## says so), an arithmetic step that keeps whole numbers whole, or
	## anything else.
	Origin : [
		Local(U64),
		Literal(F64),
		Boxed(U64),
		Whole,
		Other,
	]

	## What an index's checks may skip.
	Checks : { whole : Bool, in_range : Bool }

	## A `for ... of` step over the known array in `slot` (the header's
	## rule): the next item stored at `stored` and the place in `slot + 1`
	## moved on, or a jump to `exit` past the last item.
	walk_step_items : {
		slot : U64,
		stored : X86.Mem,
		exit : Str,
	} -> List(Assembly.Statement)
	walk_step_items = |{ slot, stored, exit }| {
		place = LoweringBasics.slot_place(slot + 1)
		[Emit.load(Rdi, LoweringBasics.slot_place(slot))]
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Instruction(MovsdLoad({ to: Xmm0, from: place })),
				Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
				Emit.load(Rdx, Emit.mem(Rdi, 0)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, exit),
				Emit.lea(Rsi, Emit.mem(Rcx, 1)),
				Instruction(Cvtsi2sd({ to: Xmm0, from: Rsi })),
				Instruction(MovsdStore({ to: place, from: Xmm0 })),
				Emit.load(R8, Emit.mem(Rdi, 16)),
				Emit.shl(Rcx, 3),
				Emit.plus(R8, Rcx),
				Emit.load(Rax, Emit.mem(R8, 0)),
				Emit.store(stored, Rax),
			])
	}

	## Nothing proved, the stack `depth` places deep.
	nothing_proved : U64 -> IndexLowering.Checked
	nothing_proved = |depth| {
		origins: List.repeat(Other, depth),
		whole_slots: [],
		slots_in_range: [],
	}

	## What one jump's way proved, at its target with the stack `depth`
	## places deep: the slots' proofs, not the stack places' origins.
	proofs_at_target : IndexLowering.Checked, U64 -> IndexLowering.Checked
	proofs_at_target = |proved, depth| {
		..IndexLowering.nothing_proved(depth),
		whole_slots: proved.whole_slots,
		slots_in_range: proved.slots_in_range,
	}

	## What a loop's head starts with, given what falls to it: the slots
	## proved to hold no fraction, less those `doubted` (some way back to the
	## head didn't keep them so); nothing else.
	at_loop_head : IndexLowering.Checked,
	{
		doubted : List(U64),
		depth : U64,
	} -> IndexLowering.Checked
	at_loop_head = |arriving, { doubted, depth }| {
		..IndexLowering.nothing_proved(depth),
		whole_slots: arriving.whole_slots.drop_if(|slot| doubted.contains(slot)),
	}

	## The slots a loop's head took to hold no fraction (`assumed`) that a
	## way back to it, with `checked` proved, doesn't prove so.
	unkept_at_back : List(U64), IndexLowering.Checked -> List(U64)
	unkept_at_back = |assumed, checked| assumed.drop_if(|slot| checked.whole_slots.contains(slot))

	## Nothing skipped.
	all_checks : IndexLowering.Checks
	all_checks = { whole: False, in_range: False }

	## What an item read or write (`GetIndex`, `SetIndex`) of the stack's
	## places may skip, from what the run has proved.
	checks_for : IndexLowering.Checked, Bytecode.Op -> IndexLowering.Checks
	checks_for = |checked, instruction| {
		depth = checked.origins.len()
		below = match instruction {
			GetIndex(_) => 2
			SetIndex(_) => 3
			_ => return all_checks
		}
		if depth < below {
			return all_checks
		}
		match (checked.origins.get(depth - below), checked.origins.get(depth - below + 1)) {
			(Ok(Local(array)), Ok(Local(index))) => {
				whole: checked.whole_slots.contains(index),
				in_range: checked.slots_in_range.contains((array, index)),
			}
			_ => all_checks
		}
	}

	## What is proved after `instruction`, lowered from `before`, falls to the
	## next with the stack `depth` places deep (the header's rule).
	checked_after : IndexLowering.Checked,
	{
		instruction : Bytecode.Op,
		before : LoweringBasics.State,
		depth : U64,
	} -> IndexLowering.Checked
	checked_after = |checked, { instruction, before, depth }| {
		is_numbers = |down| {
			deep = before.stack_kinds.len() > down
			deep and LoweringBasics.holds_numbers(LoweringBasics.kind_below(before, down))
		}
		# The places below the `count` the instruction pushed keep their
		# origins. An ordering lowered with its `JumpIfFalse` leaves nothing
		# it pushed, so a count past the depth is the depth.
		pushed = |count, origin| {
			made = U64.min(count, depth)
			if checked.origins.len() < depth - made {
				IndexLowering.nothing_proved(depth)
			} else {
				kept = checked.origins.take_first(depth - made)
				{ ..checked, origins: kept.concat(List.repeat(origin, made)) }
			}
		}
		# Whether the stack's place `down` from the top holds no fraction:
		# made whole, or loaded from a slot proved so.
		is_whole = |down| {
			count = checked.origins.len()
			if count <= down {
				False
			} else if LoweringBasics.is_integer(LoweringBasics.kind_below(before, down)) {
				True
			} else {
				match checked.origins.get(count - 1 - down) {
					Ok(Whole) => True
					Ok(Literal(number)) => is_whole_number(number)
					Ok(Local(slot)) => checked.whole_slots.contains(slot)
					_ => False
				}
			}
		}
		both_whole = numbers_on_top(before) and is_whole(0) and is_whole(1)
		# A slot set from a place that holds no fraction holds none.
		stored = |slot, kept| {
			forgotten = without_slot(kept, slot)
			if is_whole(0) {
				{ ..forgotten, whole_slots: forgotten.whole_slots.append(slot) }
			} else {
				forgotten
			}
		}
		match instruction {
			PushNumber(number) => pushed(1, Literal(number))
			LoadBoxed({ slot, name: _, at: _ }) => pushed(1, Boxed(slot))
			PushText(_) | Duplicate => pushed(1, Other)
			LoadLocal(slot) => pushed(1, Local(slot))
			StoreLocal(slot) => stored(slot, pushed(1, Other))
			SetLocal(slot) => stored(slot, pushed(0, Other))
			Pop | JumpIfFalse(_) => pushed(0, Other)
			Binary(operator, _) if is_whole_step(operator) and both_whole => pushed(1, Whole)
			# A bitwise operator's answer is a 32-bit integer, whatever it
			# was given.
			Binary(operator, _) if LoweringBasics.is_bitwise(operator) => pushed(1, Whole)
			Binary(
				operator,
				_,
			) if is_arithmetic(operator) and numbers_on_top(before) => pushed(1, Other)
			GetIndex(_) if is_numbers(1) => {
				read = pushed(1, Other)
				count = checked.origins.len()
				if count < 2 {
					read
				} else {
					match (checked.origins.get(count - 2), checked.origins.get(count - 1)) {
						(Ok(Local(array)), Ok(Local(index))) => {
							..read,
							whole_slots: read.whole_slots.append(index),
							slots_in_range: read.slots_in_range.append((array, index)),
						}
						_ => read
					}
				}
			}
			SetIndex(_) if is_numbers(2) => pushed(1, Other)
			_ => IndexLowering.nothing_proved(depth)
		}
	}

	## `length` of the value at `place`, in its place: an array's or a
	## string's length (the first 8 bytes of either), kept as an integer
	## (`integer`) or made a double, or `slow_items`, the routine's call, for
	## any other value.
	length_items : LoweringBasics.Site,
	{
		kind : LoweringBasics.Kind,
		place : X86.Mem,
		integer : Bool,
		hoisted : Try(LoweringBasics.HoistedArray, [NotHoisted]),
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	length_items = |site, { kind, place, integer, hoisted, slow_items }| {
		# The length kept as an `Integer` (a known array's or string's,
		# whose slow way is never taken), or made a double.
		stored =
			if integer {
				[Emit.store(place, Rax)]
			} else {
				[
					Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
					Instruction(MovsdStore({ to: place, from: Xmm0 })),
				]
			}
		# A loop that keeps the array's facts hoisted holds its length.
		match (kind, hoisted) {
			(Array, Ok(facts)) => return [Emit.load(Rax, facts.length)].concat(stored)
			_ => {}
		}
		slow_label = LoweringBasics.inner_label(site, "slow")
		done_label = LoweringBasics.inner_label(site, "done")
		array_label = LoweringBasics.inner_label(site, "array")
		tested = match kind {
			Array | String => Ok([Emit.load(Rdi, place)])
			Value => Ok([
				Emit.load(Rdi, place),
				Emit.mov(Rcx, Rdi),
				Emit.shr(Rcx, Boxing.tag_shift),
				Emit.cmp_imm(Rcx, Boxing.array_tag),
				Emit.jcc(E, array_label),
				Emit.cmp_imm(Rcx, Boxing.string_tag),
				Emit.jcc(Ne, slow_label),
				Emit.mark(array_label),
			])
			_ => Err(Untested)
		}
		match tested {
			Ok(statements) =>
				statements
					.concat(RuntimeBuilders.unboxed_items(Rdi))
					.concat([Emit.load(Rax, Emit.mem(Rdi, 0))])
					.concat(stored)
					.concat([Emit.jmp(done_label), Emit.mark(slow_label)])
					.concat(slow_items)
					.append(Emit.mark(done_label))
			Err(Untested) => slow_items
		}
	}

	## `receiver[index]`, in the receiver's place: the item, when the
	## receiver is an array and the index a whole number below its length,
	## else `slow_items`, the routine's call.
	item_read_items : LoweringBasics.Site,
	{
		kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
		receiver : X86.Mem,
		index : X86.Mem,
		checks : IndexLowering.Checks,
		hoisted : Try(LoweringBasics.HoistedArray, [NotHoisted]),
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	item_read_items = |
		site,
		{
			kinds,
			receiver,
			index,
			checks,
			hoisted,
			slow_items,
		},
	| {
		slow_label = LoweringBasics.inner_label(site, "slow")
		done_label = LoweringBasics.inner_label(site, "done")
		match item_address_items({
			kinds,
			receiver,
			index,
			checks,
			hoisted,
			label: slow_label,
		}) {
			Ok(addressed) =>
				addressed
					.concat([
						Emit.load(Rax, item_place),
						Emit.store(receiver, Rax),
						Emit.jmp(done_label),
						Emit.mark(slow_label),
					])
					.concat(slow_items)
					.append(Emit.mark(done_label))
			Err(Untested) => slow_items
		}
	}

	## `receiver[index]` of an array whose header says Int32 (the kind
	## `Int32Items`, in a versioned loop's fast copy), in the receiver's
	## place: the item made the `Integer` it is, or a jump to `exit`, the
	## side exit, when the index is no whole number below the length.
	int32_read_items : {
		index_kind : LoweringBasics.Kind,
		receiver : X86.Mem,
		index : X86.Mem,
		hoisted : Try(LoweringBasics.HoistedArray, [NotHoisted]),
		exit : Str,
	} -> List(Assembly.Statement)
	int32_read_items = |{ index_kind, receiver, index, hoisted, exit }|
		match item_address_items({
			kinds: (Array, index_kind),
			receiver,
			index,
			checks: IndexLowering.all_checks,
			hoisted,
			label: exit,
		}) {
			Ok(addressed) =>
				addressed.concat([
					Instruction(MovsdLoad({ to: Xmm0, from: item_place })),
					Instruction(Cvttsd2si({ to: Rax, from: Xmm0 })),
					Emit.store(receiver, Rax),
				])
			Err(Untested) => [Emit.jmp(exit)]
		}

	## `receiver[index] = ` the value at `value_place`, of an array whose
	## header says Int32 (`Int32Items`): the item written in place, or a jump
	## to `exit`, the side exit, when the index is no whole number below the
	## length or the value no whole number of 32 bits, which would lower the
	## kind. `int32` says the value is known to be one, so it isn't tested.
	int32_write_items : {
		index_kind : LoweringBasics.Kind,
		receiver : X86.Mem,
		index : X86.Mem,
		value_place : X86.Mem,
		int32 : Bool,
		exit : Str,
	} -> List(Assembly.Statement)
	int32_write_items = |
		{
			index_kind,
			receiver,
			index,
			value_place,
			int32,
			exit,
		},
	| {
		# A whole number of 32 bits, not -0: the round trip through a 32-bit
		# integer gives back its bits (`Heap.kind_kept_items`).
		value_tested =
			if int32 {
				[]
			} else {
				[
					Emit.load(Rax, value_place),
					Emit.to_xmm(Xmm0, Rax),
					Instruction(Cvttsd2si32({ to: Rcx, from: Xmm0 })),
					Instruction(Cvtsi2sd32({ to: Xmm1, from: Rcx })),
					Instruction(MovqFromXmm({ to: Rdx, from: Xmm1 })),
					Emit.cmp(Rdx, Rax),
					Emit.jcc(Ne, exit),
				]
			}
		match item_address_items({
			kinds: (Array, index_kind),
			receiver,
			index,
			checks: IndexLowering.all_checks,
			hoisted: Err(NotHoisted),
			label: exit,
		}) {
			Ok(addressed) =>
				value_tested
					.concat(addressed)
					.concat([Emit.load(Rax, value_place), Emit.store(item_place, Rax)])
			Err(Untested) => [Emit.jmp(exit)]
		}
	}

	## `receiver[index] = ` the value at `value_place`, the array changed in place, when the
	## receiver is an array and the index a whole number below its length,
	## else `slow_items`, the routine's call (an append among what it does).
	## The array's element kind is kept true of the item by what it is known
	## to be (`stored`, `Heap.kind_kept_items`).
	item_write_items : LoweringBasics.Site,
	{
		kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
		receiver : X86.Mem,
		index : X86.Mem,
		value_place : X86.Mem,
		stored : Heap.ItemStored,
		checks : IndexLowering.Checks,
		hoisted : Try(LoweringBasics.HoistedArray, [NotHoisted]),
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	item_write_items = |
		site,
		{
			kinds,
			receiver,
			index,
			value_place,
			stored,
			checks,
			hoisted,
			slow_items,
		},
	| {
		slow_label = LoweringBasics.inner_label(site, "slow")
		done_label = LoweringBasics.inner_label(site, "done")
		# The kind's upkeep takes the record in `rdi`, which a loop's kept
		# facts hold untagged.
		record = match (kinds.0, hoisted) {
			(Array, Ok(facts)) => [Emit.load(Rdi, facts.record)]
			_ => []
		}
		match item_address_items({
			kinds,
			receiver,
			index,
			checks,
			hoisted,
			label: slow_label,
		}) {
			Ok(addressed) =>
				addressed
					.concat(record)
					.concat([Emit.load(Rax, value_place), Emit.store(item_place, Rax)])
					.concat(
						Heap.kind_kept_items({
							bits: Rax,
							stored,
							label: LoweringBasics.inner_label(site, "item"),
						}),
					)
					.concat([Emit.jmp(done_label), Emit.mark(slow_label)])
					.concat(slow_items)
					.append(Emit.mark(done_label))
			Err(Untested) => slow_items
		}
	}
}

## `checked` with what it proved of `slot` forgotten: the slot was written,
## so a stack place loaded from it before holds its old value.
without_slot : IndexLowering.Checked, U64 -> IndexLowering.Checked
without_slot = |checked, slot| {
	origins: checked.origins.map(
		|origin|
			match origin {
				Local(held) if held == slot => Other
				_ => origin
			},
	),
	whole_slots: checked.whole_slots.drop_if(|held| held == slot),
	slots_in_range: checked.slots_in_range.drop_if(|(array, index)| array == slot or index == slot),
}

## Whether an operator keeps two numbers with no fraction free of one: `+`,
## `-` and `*` of two whole numbers give a whole number, or an infinity or
## a NaN when they overflow, never a fraction.
is_whole_step : Ast.BinaryOperator -> Bool
is_whole_step = |operator|
	match operator {
		Add | Subtract | Multiply => True
		_ => False
	}

## Whether a literal is a whole number.
is_whole_number : F64 -> Bool
is_whole_number = |number|
	if number.is_nan() or number.is_infinite() {
		False
	} else {
		number.div_trunc_by(1.0) == number
	}

## Whether an operator is one of `+ - * /` or the four orderings, which on
## two known numbers run no code but their own.
is_arithmetic : Ast.BinaryOperator -> Bool
is_arithmetic = |operator|
	match operator {
		Add | Subtract | Multiply | Divide => True
		Less | LessOrEqual | Greater | GreaterOrEqual => True
		_ => False
	}

## Whether the stack's two top places hold known numbers, both doubles or
## both `Integer`s.
numbers_on_top : LoweringBasics.State -> Bool
numbers_on_top = |state| {
	kinds = state.stack_kinds
	if kinds.len() < 2 {
		False
	} else {
		top = (LoweringBasics.kind_below(state, 1), LoweringBasics.kind_below(state, 0))
		top == (
			Number,
			Number,
		) or (LoweringBasics.is_integer(top.0) and LoweringBasics.is_integer(top.1))
	}
}

## The item `rcx` of the items whose address is in `r8`.
item_place : X86.Mem
item_place = RuntimeBuilders.listed_item(Rcx)

## The statements that leave the items' address in `r8` and the index in
## `rcx`, for `item_place`, or jump to `label` when the receiver is no array
## or the index no whole number below its length; `Untested` when the kinds
## say the fast way can't be taken. They change `rax`, `rcx`, `rdx`, `rdi`,
## `r8`, `xmm0` and `xmm1`. A test `checks` says was proved before is left
## out (the header's rule).
item_address_items : {
	kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
	receiver : X86.Mem,
	index : X86.Mem,
	checks : IndexLowering.Checks,
	hoisted : Try(LoweringBasics.HoistedArray, [NotHoisted]),
	label : Str,
} -> Try(List(Assembly.Statement), [Untested])
item_address_items = |
	{
		kinds,
		receiver,
		index,
		checks,
		hoisted,
		label,
	},
| {
	receiver_tested = match kinds.0 {
		Array => Ok([])
		Value => Ok([
			Emit.load(Rax, receiver),
			Emit.mov(Rcx, Rax),
			Emit.shr(Rcx, Boxing.tag_shift),
			Emit.cmp_imm(Rcx, Boxing.array_tag),
			Emit.jcc(Ne, label),
		])
		_ => Err(Untested)
	}?
	index_tested = match kinds.1 {
		Number | Value => Ok(
			LoweringBasics.unless_number_items({ kind: kinds.1, place: index, label }),
		)
		Integer(_) => Ok([])
		_ => Err(Untested)
	}?
	# An `Integer` index is a whole number already, its bits the integer: a
	# negative one is a huge unsigned, past every length, as below.
	integer_index = LoweringBasics.is_integer(kinds.1)
	loaded =
		if integer_index {
			[Emit.load(Rcx, index)]
		} else {
			[
				Instruction(MovsdLoad({ to: Xmm0, from: index })),
				Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
			]
		}
	# A whole number survives the round trip through an integer; a negative
	# one is a huge unsigned, past every length.
	whole_tested =
		if checks.whole or integer_index {
			[]
		} else {
			[
				Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
				Emit.jcc(P, label),
				Emit.jcc(Ne, label),
			]
		}
	# A loop that keeps the array's facts hoisted holds its length and its
	# items' address, so the record isn't loaded or untagged.
	kept = match (kinds.0, hoisted) {
		(Array, Ok(facts)) => Ok(facts)
		_ => Err(NotHoisted)
	}
	length_place = match kept {
		Ok(facts) => facts.length
		Err(_) => Emit.mem(Rdi, 0)
	}
	range_tested =
		if checks.in_range {
			[]
		} else {
			[
				Emit.load(Rdx, length_place),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, label),
			]
		}
	opened = match kept {
		Ok(facts) => range_tested.append(Emit.load(R8, facts.items_address))
		Err(_) =>
			[Emit.load(Rdi, receiver)]
				.concat(RuntimeBuilders.unboxed_items(Rdi))
				.concat(range_tested)
				.append(Emit.load(R8, Emit.mem(Rdi, 16)))
	}
	Ok(
		receiver_tested
			.concat(
				if checks.whole {
					[]
				} else {
					index_tested
				},
			)
			.concat(loaded)
			.concat(whole_tested)
			.concat(opened),
	)
}

## A run of instructions walked as Lowering walks one with no meeting of
## ways, each with the stack's kinds before it; what it proved after.
walked_checks : List((Bytecode.Op, List(LoweringBasics.Kind), U64)) -> IndexLowering.Checked
walked_checks = |instructions| {
	var $checked = IndexLowering.nothing_proved(0)
	for (instruction, stack_kinds, depth) in instructions {
		$checked = IndexLowering.checked_after(
			$checked,
			{ instruction, before: { slots: [], stack_kinds }, depth },
		)
	}
	$checked
}

expect {
	# `a[i]` read, then `a[i] = a[i]` after it: the write's index is
	# proved whole and in range, and so is the second read's.
	at = { line: 1, column: 1 }
	checked = walked_checks([
		(LoadLocal(0), [], 1),
		(LoadLocal(1), [Numbers], 2),
		(GetIndex(at), [Numbers, Number], 1),
		(Pop, [Number], 0),
		(LoadLocal(0), [], 1),
		(LoadLocal(1), [Numbers], 2),
		(PushNumber(7), [Numbers, Number], 3),
	])
	IndexLowering.checks_for(checked, SetIndex(at)) == { whole: True, in_range: True }
}

expect {
	# The same with `i` stored between (from a fraction, or from a whole
	# number), or a call, or with another array: the write proves nothing it
	# needs, or only that `i` is whole.
	at = { line: 1, column: 1 }
	read = [
		(LoadLocal(0), [], 1),
		(LoadLocal(1), [Numbers], 2),
		(GetIndex(at), [Numbers, Number], 1),
		(Pop, [Number], 0),
	]
	write_of = |array| [
		(LoadLocal(array), [], 1),
		(LoadLocal(1), [Numbers], 2),
		(PushNumber(7), [Numbers, Number], 3),
	]
	stored_of = |number| [
		(PushNumber(number), [], 1),
		(StoreLocal(1), [Number], 1),
		(Pop, [Number], 0),
	]
	called = [
		(
			Call({ count: 0, written: "f", at }),
			[],
			0,
		),
	]
	checks = |run| IndexLowering.checks_for(walked_checks(run), SetIndex(at))
	checks(read.concat(stored_of(2.5)).concat(write_of(0))) == IndexLowering.all_checks
		and checks(read.concat(stored_of(2)).concat(write_of(0))) == {
			whole: True,
			in_range: False,
		}
		and checks(read.concat(called).concat(write_of(0))) == IndexLowering.all_checks
		and checks(read.concat(write_of(2))) == { whole: True, in_range: False }
}
