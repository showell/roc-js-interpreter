## This module lowers JavaScript's operators and the conditional jumps
## that test a value: a binary operator on the stack's top two values
## (`binary_items`, the arithmetic, the comparisons, `+` of what isn't numbers), `===`
## and `!==` of values whose kinds may differ (`dynamic_equality_items`), a
## unary operator on the top value (`unary_items`), and the jumps of `??`
## and a default, a `switch`'s case, an optional link, and `if`, the loops
## and the logical operators.
##
## It stands apart from Lowering because the operators are a family read
## whole beside the runtime routines they call, and none of them needs the
## walk: Lowering's dispatch hands each its site and state, and takes back
## what it lowered.
import js.Ast
import Boxing
import Emit
import LoweringBasics
import Runtime
import X86

OperatorLowering :: [].{

	## A binary operator on the two values on top of the stack, its answer in
	## the place of the first.
	binary_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.BinaryOperator,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	binary_items = |site, { state, operator }| {
		left = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 2)
		right = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		kinds = (LoweringBasics.kind_below(state, 1), LoweringBasics.kind_below(state, 0))
		loaded = [
			Instruction(MovsdLoad({ to: Xmm0, from: left })),
			Instruction(MovsdLoad({ to: Xmm1, from: right })),
		]
		arithmetic = |operation|
			LoweringBasics.falling(
				loaded.concat([
					Instruction(Sse({ operation, to: Xmm0, from: Xmm1 })),
					Instruction(MovsdStore({ to: left, from: Xmm0 })),
				]),
				LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
			)
		# The flags of a `ucomisd` leave CF and ZF clear only when the first is
		# the greater and neither is a NaN, so `a < b` is `b > a`.
		ordered = |{ first, second, condition }|
			LoweringBasics.falling(
				[
					Instruction(MovsdLoad({ to: Xmm0, from: first })),
					Instruction(MovsdLoad({ to: Xmm1, from: second })),
					Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
					Instruction(Setcc({ condition, to: Al })),
				]
					.concat(LoweringBasics.boolean_items)
					.append(Instruction(MovMemReg({ to: left, from: Rax }))),
				LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
			)
		# Two doubles are equal when ZF is set and PF, the NaN's flag, is not.
		equality = |{ same, parity, joined }|
			LoweringBasics.falling(
				loaded.concat([
					Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
					Instruction(Setcc({ condition: same, to: Al })),
					Instruction(Setcc({ condition: parity, to: Cl })),
					Instruction(MovzxByte({ to: Rax, from: Al })),
					Instruction(MovzxByte({ to: Rcx, from: Cl })),
					Instruction(
						Alu({
							operation: joined,
							to: Rax,
							from: Rcx,
						}),
					),
					Emit.imm(Rcx, Boxing.false_bits),
					Emit.plus(Rax, Rcx),
					Instruction(MovMemReg({ to: left, from: Rax })),
				]),
				LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
			)
		booleans_compared = |condition|
			LoweringBasics.falling(
				[
					Instruction(MovRegMem({ to: Rax, from: left })),
					Instruction(MovRegMem({ to: Rcx, from: right })),
					Instruction(
						Alu({
							operation: Cmp,
							to: Rax,
							from: Rcx,
						}),
					),
					Instruction(Setcc({ condition, to: Al })),
				]
					.concat(LoweringBasics.boolean_items)
					.append(Instruction(MovMemReg({ to: left, from: Rax }))),
				LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
			)
		match (operator, kinds) {
			(Add, (Number, Number)) => Ok(arithmetic(Addsd))
			(Subtract, (Number, Number)) => Ok(arithmetic(Subsd))
			(Multiply, (Number, Number)) => Ok(arithmetic(Mulsd))
			(Divide, (Number, Number)) => Ok(arithmetic(Divsd))
			(Less, (Number, Number)) => Ok(
				ordered({
					first: right,
					second: left,
					condition: A,
				}),
			)
			(LessOrEqual, (Number, Number)) => Ok(
				ordered({
					first: right,
					second: left,
					condition: Ae,
				}),
			)
			(Greater, (Number, Number)) => Ok(
				ordered({
					first: left,
					second: right,
					condition: A,
				}),
			)
			(GreaterOrEqual, (Number, Number)) => Ok(
				ordered({
					first: left,
					second: right,
					condition: Ae,
				}),
			)
			(StrictEqual, (Number, Number)) => Ok(
				equality({
					same: E,
					parity: Np,
					joined: And,
				}),
			)
			(StrictNotEqual, (Number, Number)) => Ok(
				equality({
					same: Ne,
					parity: P,
					joined: Or,
				}),
			)
			(StrictEqual, (Boolean, Boolean)) => Ok(booleans_compared(E))
			(StrictNotEqual, (Boolean, Boolean)) => Ok(booleans_compared(Ne))
			(StrictEqual, _) | (StrictNotEqual, _) =>
				dynamic_equality_items(site, { state, operator, kinds })
			(Add, _) =>
				match LoweringBasics.added_kind(kinds) {
					Ok(kind) =>
						Ok(
							LoweringBasics.falling(
								[
									Emit.load(Rdi, left),
									Emit.load(Rsi, right),
									Emit.call(Runtime.add),
									Emit.store(left, Rax),
								],
								LoweringBasics.with_top(LoweringBasics.without_top(state, 2), kind),
							),
						)
					Err(Unadded) => {
						first = LoweringBasics.kind_phrase(kinds.0)
						second = LoweringBasics.kind_phrase(kinds.1)
						LoweringBasics.refusal(site, "`+` of ${first} and ${second} isn't compiled")
					}
				}
			(Subtract, _)
			| (Multiply, _)
			| (
				Divide,
				_,
			) if LoweringBasics.is_numeric(kinds.0) and LoweringBasics.is_numeric(kinds.1) => {
				operation = match operator {
					Subtract => Subsd
					Multiply => Mulsd
					_ => Divsd
				}
				checked = LoweringBasics.number_check_items({ kind: kinds.0, place: left })
					.concat(LoweringBasics.number_check_items({ kind: kinds.1, place: right }))
				done = arithmetic(operation)
				Ok({ ..done, statements: checked.concat(done.statements) })
			}
			(Less, _)
			| (LessOrEqual, _)
			| (Greater, _)
			| (GreaterOrEqual, _) if LoweringBasics.is_ordered(kinds) => {
				mapped = match operator {
					Less => [Emit.cmp_imm(Rax, 0), Instruction(Setcc({ condition: E, to: Al }))]
					LessOrEqual => [
						Emit.cmp_imm(Rax, 1),
						Instruction(Setcc({ condition: Be, to: Al })),
					]
					Greater => [Emit.cmp_imm(Rax, 2), Instruction(Setcc({ condition: E, to: Al }))]
					_ => [
						Emit.minus_imm(Rax, 1),
						Emit.cmp_imm(Rax, 1),
						Instruction(Setcc({ condition: Be, to: Al })),
					]
				}
				Ok(
					LoweringBasics.falling(
						[
							Emit.load(Rdi, left),
							Emit.load(Rsi, right),
							Emit.call(Runtime.compare),
						]
							.concat(mapped)
							.concat(LoweringBasics.boolean_items)
							.append(Emit.store(left, Rax)),
						LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
					),
				)
			}
			(
				Remainder,
				_,
			) if LoweringBasics.is_numeric(kinds.0) and LoweringBasics.is_numeric(kinds.1) =>
				Ok(
					LoweringBasics.falling(
						[
							Emit.load(Rdi, left),
							Emit.load(Rsi, right),
							Emit.call(Runtime.remainder),
							Emit.store(left, Rax),
						],
						LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
					),
				)
			(
				Power,
				_,
			) if LoweringBasics.is_numeric(kinds.0) and LoweringBasics.is_numeric(kinds.1) => {
				checked = LoweringBasics.number_check_items({ kind: kinds.0, place: left })
					.concat(LoweringBasics.number_check_items({ kind: kinds.1, place: right }))
				Ok(
					LoweringBasics.falling(
						checked.concat([
							Emit.load(Rdi, left),
							Emit.load(Rsi, right),
							Emit.call(Runtime.power),
							Emit.store(left, Rax),
						]),
						LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
					),
				)
			}
			_ => {
				named = Str.inspect(operator)
				first = LoweringBasics.kind_phrase(kinds.0)
				second = LoweringBasics.kind_phrase(kinds.1)
				LoweringBasics.refusal(
					site,
					"`${named}` of ${first} and ${second} is not compiled yet",
				)
			}
		}
	}

	## `===` or `!==` of two values whose kinds aren't both numbers or both
	## booleans: settled here when their kinds are known to differ, and by
	## `runtime_strict_equal` otherwise.
	dynamic_equality_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.BinaryOperator,
		kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	dynamic_equality_items = |site, { state, operator, kinds }| {
		left = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 2)
		right = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		(one, other) = kinds
		if !LoweringBasics.is_value_kind(one) or !LoweringBasics.is_value_kind(other) {
			one_phrase = LoweringBasics.kind_phrase(one)
			other_phrase = LoweringBasics.kind_phrase(other)
			return LoweringBasics.refusal(site, "`===` of ${one_phrase} and ${other_phrase}")
		}
		flipped = match operator {
			StrictNotEqual => [
				Instruction(
					AluImm({
						operation: Xor,
						to: Rax,
						value: 1,
					}),
				),
			]
			_ => []
		}
		settled = one != other and one != Value and other != Value
		compared =
			if settled {
				[Emit.imm(Rax, Boxing.false_bits)]
			} else {
				[
					Emit.load(Rdi, left),
					Emit.load(Rsi, right),
					Emit.call(Runtime.strict_equal),
				]
			}
		Ok(
			LoweringBasics.falling(
				compared.concat(flipped).append(Emit.store(left, Rax)),
				LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
			),
		)
	}

	## A unary operator on the value on top of the stack.
	unary_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.UnaryOperator,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	unary_items = |site, { state, operator }| {
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		match (operator, LoweringBasics.kind_below(state, 0)) {
			(Negate, Number) =>
				Ok(
					LoweringBasics.falling(
						[
							Instruction(MovRegMem({ to: Rax, from: top })),
							Instruction(
								MovRegImm({ to: Rcx, value: (0x8000000000000000).to_i64_wrap() }),
							),
							Instruction(
								Alu({
									operation: Xor,
									to: Rax,
									from: Rcx,
								}),
							),
							Instruction(MovMemReg({ to: top, from: Rax })),
						],
						state,
					),
				)
			(Plus, Number) => Ok(LoweringBasics.falling([], state))
			(Not, Boolean) =>
				Ok(
					LoweringBasics.falling(
						[
							Instruction(MovRegMem({ to: Rax, from: top })),
							Instruction(
								AluImm({
									operation: Xor,
									to: Rax,
									value: 1,
								}),
							),
							Instruction(MovMemReg({ to: top, from: Rax })),
						],
						state,
					),
				)
			(Not, Number) => {
				tested = LoweringBasics.truth_items(site, state)?
				Ok(
					LoweringBasics.falling(
						tested
							.append(Instruction(Setcc({ condition: E, to: Al })))
							.concat(LoweringBasics.boolean_items)
							.append(Instruction(MovMemReg({ to: top, from: Rax }))),
						LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Boolean),
					),
				)
			}
			(Negate, Value) | (Plus, Value) => {
				negated = match operator {
					Negate => [
						Emit.imm(Rcx, (0x8000000000000000).to_i64_wrap()),
						Instruction(
							Alu({
								operation: Xor,
								to: Rax,
								from: Rcx,
							}),
						),
					]
					_ => []
				}
				Ok(
					LoweringBasics.falling(
						[Emit.load(Rax, top), Emit.call(Runtime.check_number)]
							.concat(negated)
							.append(Emit.store(top, Rax)),
						LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Number),
					),
				)
			}
			(Not, kind) if LoweringBasics.is_value_kind(kind) => {
				tested = LoweringBasics.truth_items(site, state)?
				Ok(
					LoweringBasics.falling(
						tested
							.append(Instruction(Setcc({ condition: E, to: Al })))
							.concat(LoweringBasics.boolean_items)
							.append(Emit.store(top, Rax)),
						LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Boolean),
					),
				)
			}
			(TypeOf, kind) => {
				named = match kind {
					Number => Named("runtime_text_type_number")
					String => Named("runtime_text_type_string")
					Boolean => Named("runtime_text_type_boolean")
					Undefined => Named("runtime_text_undefined")
					Null | Array | Object | Console => Named("runtime_text_type_object")
					Function(_) | Closure(_) => Named("runtime_text_type_function")
					Log | Method(_) => Named("runtime_text_type_function")
					ErrorClass(_) | StaticMethod(_) => Named("runtime_text_type_function")
					CollectionClass(_) | TimerFunction(_) => Named("runtime_text_type_function")
					Static("Math") => Named("runtime_text_type_object")
					Static(_) => Named("runtime_text_type_function")
					Value => Unnamed
				}
				found = match named {
					Named(label) => [
						Emit.address_of(Rax, label),
						Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)),
						Emit.plus(Rax, Rcx),
					]
					Unnamed => [Emit.load(Rdi, top), Emit.call(Runtime.type_of)]
				}
				Ok(
					LoweringBasics.falling(
						found.append(Emit.store(top, Rax)),
						LoweringBasics.with_top(LoweringBasics.without_top(state, 1), String),
					),
				)
			}
			(_, kind) => {
				phrase = LoweringBasics.kind_phrase(kind)
				named = Str.inspect(operator)
				LoweringBasics.refusal(site, "`${named}` of ${phrase} is not compiled yet")
			}
		}
	}

	## A jump taken, the value on top kept, when it is not `null` or
	## `undefined` (`??`'s) or not `undefined` (a default's); otherwise the
	## value is dropped and the next instruction follows.
	defined_jump_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		skip : U64,
		settles : [Defined, NotUndefined],
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	defined_jump_items = |site, { state, skip, settles }| {
		kind = LoweringBasics.kind_below(state, 0)
		if !LoweringBasics.is_value_kind(kind) {
			return LoweringBasics.refusal(
				site,
				"`??` or a default of ${LoweringBasics.kind_phrase(kind)}",
			)
		}
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		# `undefined` and `null` differ in their lowest bit alone.
		tested = match settles {
			Defined => [
				Emit.load(Rax, top),
				Instruction(
					AluImm({
						operation: Or,
						to: Rax,
						value: 1,
					}),
				),
				Emit.imm(Rcx, Boxing.null_bits),
				Emit.cmp(Rax, Rcx),
			]
			NotUndefined => [
				Emit.load(Rax, top),
				Emit.imm(Rcx, Boxing.undefined_bits),
				Emit.cmp(Rax, Rcx),
			]
		}
		target = LoweringBasics.forward(site, skip)
		Ok({
			statements: tested.append(
				Emit.jcc(Ne, LoweringBasics.place_label(site.lowering, target)),
			),
			falls: Falls(LoweringBasics.without_top(state, 1)),
			branch: Branch({ target, state }),
			result: GivesNothing,
		})
	}

	## A `switch`'s case: the two values on top compared by `===`, both
	## dropped, and the jump taken when they are the same.
	same_jump_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		skip : U64,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	same_jump_items = |site, { state, skip }| {
		compared = binary_items(site, { state, operator: StrictEqual })?
		after = match compared.falls {
			Falls(next) => next
			Ends => crash "OperatorLowering.same_jump_items: a comparison falls through"
		}
		target = LoweringBasics.forward(site, skip)
		dropped = LoweringBasics.without_top(after, 1)
		Ok({
			statements: compared.statements.concat([
				Emit.load(Rax, LoweringBasics.stack_place(site.code, after.stack_kinds.len() - 1)),
				Emit.imm(Rcx, Boxing.true_bits),
				Emit.cmp(Rax, Rcx),
				Emit.jcc(E, LoweringBasics.place_label(site.lowering, target)),
			]),
			falls: Falls(dropped),
			branch: Branch({ target, state: dropped }),
			result: GivesNothing,
		})
	}

	## An optional link: `undefined` or `null` on top ends the chain, its
	## answer `undefined`, by a jump to the chain's end. A kind known to be
	## neither makes no code, and one known to be either only the jump.
	nullish_jump_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		skip : U64,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	nullish_jump_items = |site, { state, skip }| {
		target = LoweringBasics.forward(site, skip)
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		shorted = LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Undefined)
		short_label = "${LoweringBasics.place_label(site.lowering, site.at)}_short"
		going_label = "${LoweringBasics.place_label(site.lowering, site.at)}_going"
		jumped = LoweringBasics.constant_items({
			bits: Boxing.undefined_bits.to_u64_wrap(),
			to: top,
		})
			.append(JmpTo(LoweringBasics.place_label(site.lowering, target)))
		match LoweringBasics.kind_below(state, 0) {
			Undefined | Null =>
				Ok({
					statements: jumped,
					falls: Ends,
					branch: Branch({ target, state: shorted }),
					result: GivesNothing,
				})
			Value => {
				tested = [
					Emit.load(Rax, top),
					Emit.imm(Rcx, Boxing.undefined_bits),
					Emit.cmp(Rax, Rcx),
					Emit.jcc(E, short_label),
					Emit.imm(Rcx, Boxing.null_bits),
					Emit.cmp(Rax, Rcx),
					Emit.jcc(Ne, going_label),
					Emit.mark(short_label),
				]
				Ok({
					statements: tested.concat(jumped).append(Emit.mark(going_label)),
					falls: Falls(state),
					branch: Branch({ target, state: shorted }),
					result: GivesNothing,
				})
			}
			kind if LoweringBasics.is_value_kind(kind) => Ok(LoweringBasics.falling([], state))
			kind => LoweringBasics.refusal(
				site,
				"an optional link of ${LoweringBasics.kind_phrase(kind)}",
			)
		}
	}

	## A jump taken when the value on top is falsy (`E`) or truthy (`Ne`):
	## `JumpIfFalse` drops the value either way, the logical operators' skips
	## keep it where they jump.
	test_jump_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		skip : U64,
		condition : X86.Condition,
		kept : [Kept, Dropped],
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	test_jump_items = |site, { state, skip, condition, kept }| {
		tested = LoweringBasics.truth_items(site, state)?
		target = LoweringBasics.forward(site, skip)
		sent = match kept {
			Kept => state
			Dropped => LoweringBasics.without_top(state, 1)
		}
		jump = JccTo({ condition, label: LoweringBasics.place_label(site.lowering, target) })
		Ok({
			statements: tested.append(jump),
			falls: Falls(LoweringBasics.without_top(state, 1)),
			branch: Branch({ target, state: sent }),
			result: GivesNothing,
		})
	}
}
