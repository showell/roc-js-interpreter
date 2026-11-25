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
import Assembly
import Boxing
import Emit
import LoweringBasics
import RuntimeBuilders
import X86

IndexLowering :: [].{

	## `length` of the value at `place`, in its place: an array's or a
	## string's length (the first 8 bytes of either) made a double, or
	## `slow`, the routine's call, for any other value.
	length_items : LoweringBasics.Site,
	{
		kind : LoweringBasics.Kind,
		place : X86.Mem,
		slow : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	length_items = |site, { kind, place, slow }| {
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
					.concat(slow)
					.append(Emit.mark(done_label))
			Err(Untested) => slow
		}
	}

	## `receiver[index]`, in the receiver's place: the item, when the
	## receiver is an array and the index a whole number below its length,
	## else `slow`, the routine's call.
	item_read_items : LoweringBasics.Site,
	{
		kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
		receiver : X86.Mem,
		index : X86.Mem,
		slow : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	item_read_items = |site, { kinds, receiver, index, slow }| {
		slow_label = LoweringBasics.inner_label(site, "slow")
		done_label = LoweringBasics.inner_label(site, "done")
		match item_address_items({ kinds, receiver, index, label: slow_label }) {
			Ok(addressed) =>
				addressed
					.concat([
						Emit.load(Rax, item_place),
						Emit.store(receiver, Rax),
						Emit.jmp(done_label),
						Emit.mark(slow_label),
					])
					.concat(slow)
					.append(Emit.mark(done_label))
			Err(Untested) => slow
		}
	}

	## `receiver[index] = item`, the array changed in place, when the
	## receiver is an array and the index a whole number below its length,
	## else `slow`, the routine's call (an append among what it does).
	item_write_items : LoweringBasics.Site,
	{
		kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
		receiver : X86.Mem,
		index : X86.Mem,
		item : X86.Mem,
		slow : List(Assembly.Statement),
	} -> List(Assembly.Statement)
	item_write_items = |site, { kinds, receiver, index, item, slow }| {
		slow_label = LoweringBasics.inner_label(site, "slow")
		done_label = LoweringBasics.inner_label(site, "done")
		match item_address_items({ kinds, receiver, index, label: slow_label }) {
			Ok(addressed) =>
				addressed
					.concat([
						Emit.load(Rax, item),
						Emit.store(item_place, Rax),
						Emit.jmp(done_label),
						Emit.mark(slow_label),
					])
					.concat(slow)
					.append(Emit.mark(done_label))
			Err(Untested) => slow
		}
	}
}

## The item `rcx` of the items whose address is in `r8`.
item_place : X86.Mem
item_place = RuntimeBuilders.listed_item(Rcx)

## The statements that leave the items' address in `r8` and the index in
## `rcx`, for `item_place`, or jump to `label` when the receiver is no array
## or the index no whole number below its length; `Untested` when the kinds
## say the fast way can't be taken. They change `rax`, `rcx`, `rdx`, `rdi`,
## `r8`, `xmm0` and `xmm1`.
item_address_items : {
	kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
	receiver : X86.Mem,
	index : X86.Mem,
	label : Str,
} -> Try(List(Assembly.Statement), [Untested])
item_address_items = |{ kinds, receiver, index, label }| {
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
		Number | Value => Ok(LoweringBasics.unless_number_items({ kind: kinds.1, place: index, label }))
		_ => Err(Untested)
	}?
	# A whole number survives the round trip through an integer; a negative
	# one is a huge unsigned, past every length.
	Ok(
		receiver_tested
			.concat(index_tested)
			.concat([
				Instruction(MovsdLoad({ to: Xmm0, from: index })),
				Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
				Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
				Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
				Emit.jcc(P, label),
				Emit.jcc(Ne, label),
				Emit.load(Rdi, receiver),
			])
			.concat(RuntimeBuilders.unboxed_items(Rdi))
			.concat([
				Emit.load(Rdx, Emit.mem(Rdi, 0)),
				Emit.cmp(Rcx, Rdx),
				Emit.jcc(Ae, label),
				Emit.load(R8, Emit.mem(Rdi, 16)),
			]),
	)
}
