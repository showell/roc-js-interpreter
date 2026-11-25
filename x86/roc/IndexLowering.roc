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
## wholly at any place another way reaches (a jump's target, a loop's head),
## at every instruction but a few that change no variable but the one they
## name and no array's length but by growing it (a push of a number, text, a
## boxed variable's value or a copy; a load of a slot; a store or set of a
## slot, which forgets that slot; `Pop` and `JumpIfFalse`; `+ - * /` and the
## orderings of two known numbers; and an item read or write of an array of
## numbers, whose slow way stops or appends), so a call, a method (`push`,
## `pop`, `splice`) and any instruction that makes code run are among those
## that forget it. A length only grows between, so an index below it stays
## below it.
import js.Ast
import js.Bytecode
import Assembly
import Boxing
import Emit
import LoweringBasics
import RuntimeBuilders
import X86

IndexLowering :: [].{

	## What a straight run has proved of its index checks, the header's rule:
	## each stack place's origin, bottom first, the slots proved to hold whole
	## numbers, and the (array, index) slots proved in range.
	Checked : {
		origins : List([Local(U64), Other]),
		whole : List(U64),
		in_range : List((U64, U64)),
	}

	## What an index's checks may skip.
	Checks : { whole : Bool, in_range : Bool }

	## Nothing proved, the stack `depth` places deep.
	unchecked : U64 -> IndexLowering.Checked
	unchecked = |depth| { origins: List.repeat(Other, depth), whole: [], in_range: [] }

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
				whole: checked.whole.contains(index),
				in_range: checked.in_range.contains((array, index)),
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
		is_numbers = |down|
			before.stack_kinds.len() > down and LoweringBasics.kind_below(before, down) == Numbers
		# The places below the `count` the instruction pushed keep their
		# origins. An ordering lowered with its `JumpIfFalse` leaves nothing
		# it pushed, so a count past the depth is the depth.
		pushed = |count, origin| {
			made = U64.min(count, depth)
			if checked.origins.len() < depth - made {
				IndexLowering.unchecked(depth)
			} else {
				kept = checked.origins.take_first(depth - made)
				{ ..checked, origins: kept.concat(List.repeat(origin, made)) }
			}
		}
		match instruction {
			PushNumber(_) | PushText(_) | LoadBoxed(_) | Duplicate => pushed(1, Other)
			LoadLocal(slot) => pushed(1, Local(slot))
			StoreLocal(slot) => forgotten(pushed(1, Other), slot)
			SetLocal(slot) => forgotten(pushed(0, Other), slot)
			Pop | JumpIfFalse(_) => pushed(0, Other)
			Binary(operator, _) if is_arithmetic(operator) and numbers_on_top(before) => pushed(1, Other)
			GetIndex(_) if is_numbers(1) => {
				read = pushed(1, Other)
				count = checked.origins.len()
				if count < 2 {
					read
				} else {
					match (checked.origins.get(count - 2), checked.origins.get(count - 1)) {
						(Ok(Local(array)), Ok(Local(index))) => {
							..read,
							whole: read.whole.append(index),
							in_range: read.in_range.append((array, index)),
						}
						_ => read
					}
				}
			}
			SetIndex(_) if is_numbers(2) => pushed(1, Other)
			_ => IndexLowering.unchecked(depth)
		}
	}

	## `length` of the value at `place`, in its place: an array's or a
	## string's length (the first 8 bytes of either) made a double, or
	## `slow_items`, the routine's call, for any other value.
	length_items : LoweringBasics.Site,
	{
		kind : LoweringBasics.Kind,
		place : X86.Mem,
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	length_items = |site, { kind, place, slow_items }| {
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
					.concat([
						Emit.load(Rax, Emit.mem(Rdi, 0)),
						Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
						Instruction(MovsdStore({ to: place, from: Xmm0 })),
						Emit.jmp(done_label),
						Emit.mark(slow_label),
					])
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
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	item_read_items = |site, { kinds, receiver, index, checks, slow_items }| {
		slow_label = LoweringBasics.inner_label(site, "slow")
		done_label = LoweringBasics.inner_label(site, "done")
		match item_address_items({ kinds, receiver, index, checks, label: slow_label }) {
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

	## `receiver[index] = ` the value at `value_place`, the array changed in place, when the
	## receiver is an array and the index a whole number below its length,
	## else `slow_items`, the routine's call (an append among what it does).
	item_write_items : LoweringBasics.Site,
	{
		kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
		receiver : X86.Mem,
		index : X86.Mem,
		value_place : X86.Mem,
		checks : IndexLowering.Checks,
		slow_items : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	item_write_items = |site, { kinds, receiver, index, value_place, checks, slow_items }| {
		slow_label = LoweringBasics.inner_label(site, "slow")
		done_label = LoweringBasics.inner_label(site, "done")
		match item_address_items({ kinds, receiver, index, checks, label: slow_label }) {
			Ok(addressed) =>
				addressed
					.concat([
						Emit.load(Rax, value_place),
						Emit.store(item_place, Rax),
						Emit.jmp(done_label),
						Emit.mark(slow_label),
					])
					.concat(slow_items)
					.append(Emit.mark(done_label))
			Err(Untested) => slow_items
		}
	}
}

## `checked` with what it proved of `slot` forgotten: the slot was written,
## so a stack place loaded from it before holds its old value.
forgotten : IndexLowering.Checked, U64 -> IndexLowering.Checked
forgotten = |checked, slot| {
	origins: checked.origins.map(
		|origin|
			match origin {
				Local(held) if held == slot => Other
				_ => origin
			},
	),
	whole: checked.whole.drop_if(|held| held == slot),
	in_range: checked.in_range.drop_if(|(array, index)| array == slot or index == slot),
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

## Whether the stack's two top places hold known numbers.
numbers_on_top : LoweringBasics.State -> Bool
numbers_on_top = |state|
	state.stack_kinds.len() >= 2
		and LoweringBasics.kind_below(state, 0) == Number
		and LoweringBasics.kind_below(state, 1) == Number

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
	label : Str,
} -> Try(List(Assembly.Statement), [Untested])
item_address_items = |{ kinds, receiver, index, checks, label }| {
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
		_ => Err(Untested)
	}?
	# A whole number survives the round trip through an integer; a negative
	# one is a huge unsigned, past every length.
	whole_tested =
		if checks.whole {
			[]
		} else {
			[
				Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
				Emit.jcc(P, label),
				Emit.jcc(Ne, label),
			]
		}
	range_tested =
		if checks.in_range {
			[]
		} else {
			[
				Emit.load(Rdx, Emit.mem(Rdi, 0)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, label),
			]
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
			.concat([
				Instruction(MovsdLoad({ to: Xmm0, from: index })),
				Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
			])
			.concat(whole_tested)
			.append(Emit.load(Rdi, receiver))
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat(range_tested)
			.append(Emit.load(R8, Emit.mem(Rdi, 16))),
	)
}

## A run of instructions walked as Lowering walks one with no meeting of
## ways, each with the stack's kinds before it; what it proved after.
walked_checks : List((Bytecode.Op, List(LoweringBasics.Kind), U64)) -> IndexLowering.Checked
walked_checks = |run| {
	var $checked = IndexLowering.unchecked(0)
	for (instruction, stack_kinds, depth) in run {
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
	# The same with `i` stored between, or a call, or with another array: the
	# write proves nothing it needs, or only that `i` is whole.
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
	stored = [(PushNumber(2), [], 1), (StoreLocal(1), [Number], 1), (Pop, [Number], 0)]
	called = [(Call({ count: 0, written: "f", at }), [], 0)]
	checks = |run| IndexLowering.checks_for(walked_checks(run), SetIndex(at))
	checks(read.concat(stored).concat(write_of(0))) == IndexLowering.all_checks
		and checks(read.concat(called).concat(write_of(0))) == IndexLowering.all_checks
		and checks(read.concat(write_of(2))) == { whole: True, in_range: False }
}
