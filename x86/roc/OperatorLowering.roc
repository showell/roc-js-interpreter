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
##
## **`%` BY A KNOWN WHOLE NUMBER IS A MULTIPLY, NOT A CALL.** `%` of two
## values that may be numbers is otherwise `runtime_remainder`'s: both
## tags tested, both numbers made whole numbers of at most 2^53 in size (or
## the program stopped), and an `idiv`. When the divisor is known before
## the program runs (`known_divisor`), the work is in line instead. The
## divisor is known when the straight run says where the stack's top came
## from (IndexLowering's `Checked`, whose origins are forgotten wherever two
## ways meet, so a divisor two ways bring, `n % (c ? 3 : 4)`, is never taken
## for either): a number literal, or a boxed variable that holds one number
## for good (`KnownFunctions.constant_numbers`, a `const` set from a literal
## and captured by the function). The number must be whole, not 0, and at
## most 2^53 in size; its sign is dropped, as JavaScript's `n % -d` is
## `n % d`. A `const` of the code's own frame that no closure captures is a
## slot, not a box, and takes the routine. In line
## (`constant_remainder_items`):
## - the dividend's tag is tested when its kind may not be a number, and it
##   is made a 64-bit integer (`cvttsd2si`), held to it by the round trip
##   back (`cvtsi2sd`, `ucomisd`): a fraction, an infinity, a NaN or a
##   number of 2^63 or more in size fails it and takes the routine, which
##   gives NaN for an infinity or a NaN. A whole double below 2^63 is an
##   exact integer, so the in-line way takes dividends past 2^53 too, which
##   the routine stops at;
## - the quotient, rounded toward 0, is a multiply by a magic reciprocal
##   (`remainder_magic`, Hacker's Delight's for a signed dividend: the high
##   half of a 128-bit product, a shift, and 1 more for a negative
##   dividend), and the remainder is the dividend less the quotient times
##   the divisor, with the dividend's sign; a divisor of 1 leaves 0;
## - the remainder is made a double and the dividend's sign bit or-ed in, so
##   a remainder of 0 is -0 when the dividend is negative or -0, as
##   JavaScript's, and one not 0 keeps the sign it has.
## The expect under `magic_remainder` holds the multiply to Roc's own
## remainder for the divisors the tests use, over dividends to 2^63 in
## size, and x86/tests/remainder-constant.js holds the whole of it to node.
import js.Ast
import js.Bytecode
import Assembly
import Boxing
import Emit
import IndexLowering
import LoweringBasics
import Runtime
import X86

OperatorLowering :: [].{

	## A binary operator on the two values on top of the stack, its answer in
	## the place of the first. `checked` is what the straight run before it
	## proved (IndexLowering's header), which says where the top came from.
	binary_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.BinaryOperator,
		checked : IndexLowering.Checked,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	binary_items = |site, { state, operator, checked }| {
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
					Ok(kind) => {
						called = [
							Emit.load(Rdi, left),
							Emit.load(Rsi, right),
							Emit.call(Runtime.add),
							Emit.store(left, Rax),
						]
						# Two values that may be numbers are added in line when they
						# are, and by `runtime_add` when either isn't.
						statements =
							if LoweringBasics.are_numeric(kinds) {
								numbers_first_items(
									site,
									{
										kinds,
										left,
										right,
										fast_items: arithmetic(Addsd).statements,
										slow_items: called,
									},
								)
							} else {
								called
							}
						Ok(
							LoweringBasics.falling(
								statements,
								LoweringBasics.with_top(LoweringBasics.without_top(state, 2), kind),
							),
						)
					}
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
				tested = LoweringBasics.number_check_items({ kind: kinds.0, place: left })
					.concat(LoweringBasics.number_check_items({ kind: kinds.1, place: right }))
				done = arithmetic(operation)
				Ok({ ..done, statements: tested.concat(done.statements) })
			}
			(Less, _)
			| (LessOrEqual, _)
			| (Greater, _)
			| (GreaterOrEqual, _) if LoweringBasics.is_ordered(kinds) => {
				numbered = match operator {
					Less => ordered({
						first: right,
						second: left,
						condition: A,
					})
					LessOrEqual => ordered({
						first: right,
						second: left,
						condition: Ae,
					})
					Greater => ordered({
						first: left,
						second: right,
						condition: A,
					})
					_ => ordered({
						first: left,
						second: right,
						condition: Ae,
					})
				}
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
				called = [
					Emit.load(Rdi, left),
					Emit.load(Rsi, right),
					Emit.call(Runtime.compare),
				]
					.concat(mapped)
					.concat(LoweringBasics.boolean_items)
					.append(Emit.store(left, Rax))
				# Two values that may be numbers are ordered in line when they are,
				# and by `runtime_compare` when either isn't (two strings).
				statements =
					if LoweringBasics.are_numeric(kinds) {
						numbers_first_items(
							site,
							{
								kinds,
								left,
								right,
								fast_items: numbered.statements,
								slow_items: called,
							},
						)
					} else {
						called
					}
				Ok(
					LoweringBasics.falling(
						statements,
						LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Boolean),
					),
				)
			}
			(
				Remainder,
				_,
			) if LoweringBasics.is_numeric(kinds.0) and LoweringBasics.is_numeric(kinds.1) => {
				called = [
					Emit.load(Rdi, left),
					Emit.load(Rsi, right),
					Emit.call(Runtime.remainder),
					Emit.store(left, Rax),
				]
				statements = match known_divisor(site, { state, checked }) {
					Ok(divisor) =>
						constant_remainder_items(
							site,
							{
								kind: kinds.0,
								left,
								divisor,
								slow_items: called,
							},
						)
					Err(Unknown) => called
				}
				Ok(
					LoweringBasics.falling(
						statements,
						LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
					),
				)
			}
			(
				Power,
				_,
			) if LoweringBasics.is_numeric(kinds.0) and LoweringBasics.is_numeric(kinds.1) => {
				tested = LoweringBasics.number_check_items({ kind: kinds.0, place: left })
					.concat(LoweringBasics.number_check_items({ kind: kinds.1, place: right }))
				Ok(
					LoweringBasics.falling(
						tested.concat([
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

	## An ordering of the two values on top that may be numbers, followed by a
	## `JumpIfFalse`, as one: both values dropped, and the jump taken to the
	## `JumpIfFalse`'s target when the ordering is false. Two numbers take a
	## `ucomisd` and a jump on its flags, with no boolean made and tested; a
	## value that turns out not to be a number takes `runtime_compare`, its
	## answer tested in place of the boolean. `Lowering` fuses the two only
	## where no other way reaches the `JumpIfFalse`.
	ordered_jump_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.BinaryOperator,
		skip : U64,
	} -> LoweringBasics.Lowered
	ordered_jump_items = |site, { state, operator, skip }| {
		left = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 2)
		right = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		kinds = (LoweringBasics.kind_below(state, 1), LoweringBasics.kind_below(state, 0))
		target = site.at + 2 + skip
		label = LoweringBasics.place_label(site.context, target)
		# The flags of a `ucomisd` leave CF and ZF clear only when the first is
		# the greater and neither is a NaN, so `a < b` is false when `b > a`
		# isn't (`jbe`), and `a <= b` when `b >= a` isn't (`jb`); a NaN sets
		# CF, so every ordering with one is false.
		{ first, second, falsy } = match operator {
			Less => {
				first: right,
				second: left,
				falsy: Be,
			}
			LessOrEqual => {
				first: right,
				second: left,
				falsy: B,
			}
			Greater => {
				first: left,
				second: right,
				falsy: Be,
			}
			_ => {
				first: left,
				second: right,
				falsy: B,
			}
		}
		compared = [
			Instruction(MovsdLoad({ to: Xmm0, from: first })),
			Instruction(MovsdLoad({ to: Xmm1, from: second })),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(falsy, label),
		]
		# `runtime_compare` answers 0 for less, 1 equal, 2 greater, 3 unordered.
		answered = match operator {
			Less => [Emit.cmp_imm(Rax, 0), Emit.jcc(Ne, label)]
			LessOrEqual => [Emit.cmp_imm(Rax, 1), Emit.jcc(A, label)]
			Greater => [Emit.cmp_imm(Rax, 2), Emit.jcc(Ne, label)]
			_ => [
				Emit.minus_imm(Rax, 1),
				Emit.cmp_imm(Rax, 1),
				Emit.jcc(A, label),
			]
		}
		called = [
			Emit.load(Rdi, left),
			Emit.load(Rsi, right),
			Emit.call(Runtime.compare),
		]
			.concat(answered)
		statements =
			if kinds == (Number, Number) {
				compared
			} else {
				numbers_first_items(
					site,
					{
						kinds,
						left,
						right,
						fast_items: compared,
						slow_items: called,
					},
				)
			}
		after = LoweringBasics.without_top(state, 2)
		{
			statements,
			falls: Falls(after),
			branch: Branch({ target, state: after }),
			result: GivesNothing,
		}
	}

	## `+`, `-`, `*` or `%` of the two `Integer`s on top, which give `kind`
	## (`LoweringBasics.integer_arithmetic`), in the first's place: integer
	## arithmetic, which the bounds keep from overflowing. A sum or a
	## difference whose second is a literal (`checked`'s origins say where the
	## top came from) adds or takes its integer as an immediate; a remainder
	## is `integer_remainder_items`'.
	integer_arithmetic_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.BinaryOperator,
		kind : LoweringBasics.Kind,
		checked : IndexLowering.Checked,
	} -> LoweringBasics.Lowered
	integer_arithmetic_items = |site, { state, operator, kind, checked }| {
		depth = state.stack_kinds.len()
		left = LoweringBasics.stack_place(site.code, depth - 2)
		right = LoweringBasics.stack_place(site.code, depth - 1)
		literal =
			if checked.origins.len() == depth {
				match checked.origins.last() {
					Ok(Literal(number)) if number >= -2147483648.0 and number <= 2147483647.0 =>
						Ok(LoweringBasics.whole_of_literal(number))
					_ => Err(Unknown)
				}
			} else {
				Err(Unknown)
			}
		operated = match (operator, literal) {
			(Add, Ok(whole)) => [Emit.plus_imm(Rax, whole)]
			(Subtract, Ok(whole)) => [Emit.minus_imm(Rax, whole)]
			(Add, _) => [Emit.load(Rcx, right), Emit.plus(Rax, Rcx)]
			(Subtract, _) => [Emit.load(Rcx, right), Emit.minus(Rax, Rcx)]
			_ => [Emit.load(Rcx, right), Instruction(Imul({ to: Rax, from: Rcx }))]
		}
		statements = match operator {
			Remainder =>
				integer_remainder_items({
					left,
					right,
					divisor: LoweringBasics.kind_below(state, 0),
				})
			_ => [Emit.load(Rax, left)].concat(operated).append(Emit.store(left, Rax))
		}
		LoweringBasics.falling(
			statements,
			LoweringBasics.with_top(LoweringBasics.without_top(state, 2), kind),
		)
	}

	## `Math.floor(a / b)` of the two `Integer`s on top, the divisor at least
	## 1 (`LoweringBasics.integer_floor_quotient`, which gives `kind`): the
	## quotient rounded down, in the place of `Math` below the function, the
	## call's four places taken. A divisor whose range is one value is a
	## constant: 1 gives the dividend, a power of two an arithmetic shift
	## (which rounds down), any other the magic multiply. Any other divisor
	## takes an `idiv`. Both round toward 0, so a dividend that may be
	## negative takes 1 from the quotient where the remainder is negative.
	integer_floor_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		kind : LoweringBasics.Kind,
	} -> LoweringBasics.Lowered
	integer_floor_items = |site, { state, kind }| {
		depth = state.stack_kinds.len()
		receiver = LoweringBasics.stack_place(site.code, depth - 4)
		left = LoweringBasics.stack_place(site.code, depth - 2)
		right = LoweringBasics.stack_place(site.code, depth - 1)
		signed = match LoweringBasics.kind_below(state, 1) {
			Integer({ low, high: _ }) => low < 0
			_ => crash "OperatorLowering.integer_floor_items: an Integer dividend"
		}
		statements = match constant_size(LoweringBasics.kind_below(state, 0)) {
			Ok(1) => [Emit.load(Rax, left), Emit.store(receiver, Rax)]
			Ok(size) if is_power_of_two(size) => [
				Emit.load(Rax, left),
				Instruction(
					Shift({
						operation: Sar,
						reg: Rax,
						count: power_of(size),
					}),
				),
				Emit.store(receiver, Rax),
			]
			Ok(size) => {
				# The remainder's sign, -1 or 0, added to the quotient in `rdx`.
				rounded =
					if signed {
						[
							Emit.imm(Rax, size.to_i64_wrap()),
							Instruction(Imul({ to: Rax, from: Rdx })),
							Emit.minus(Rcx, Rax),
							Instruction(
								Shift({
									operation: Sar,
									reg: Rcx,
									count: 63,
								}),
							),
							Emit.plus(Rdx, Rcx),
						]
					} else {
						[]
					}
				[Emit.load(Rcx, left)]
					.concat(magic_quotient_items({ divisor: size, signed }))
					.concat(rounded)
					.append(Emit.store(receiver, Rdx))
			}
			Err(Unknown) => {
				rounded =
					if signed {
						[
							Instruction(
								Shift({
									operation: Sar,
									reg: Rdx,
									count: 63,
								}),
							),
							Emit.plus(Rax, Rdx),
						]
					} else {
						[]
					}
				[
					Emit.load(Rax, left),
					Instruction(Cqo),
					Emit.load(Rcx, right),
					Instruction(Idiv(Rcx)),
				]
					.concat(rounded)
					.append(Emit.store(receiver, Rax))
			}
		}
		LoweringBasics.falling(
			statements,
			LoweringBasics.with_top(LoweringBasics.without_top(state, 4), kind),
		)
	}

	## An ordering of the two `Integer`s on top and the `JumpIfFalse` after
	## it, as one: a `cmp` and a signed jump to the target when the ordering
	## is false. On the way that falls through the ordering holds, so a slot
	## either side was loaded from (`origins`, IndexLowering's) has its range
	## narrowed by the other side's (x86/README.md, "A loop's head"): `i < n`
	## leaves `i` at most `n`'s most less 1, and `n` at least `i`'s least
	## and 1.
	integer_jump_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.BinaryOperator,
		skip : U64,
		origins : List(IndexLowering.Origin),
	} -> LoweringBasics.Lowered
	integer_jump_items = |site, { state, operator, skip, origins }| {
		depth = state.stack_kinds.len()
		left = LoweringBasics.stack_place(site.code, depth - 2)
		right = LoweringBasics.stack_place(site.code, depth - 1)
		target = site.at + 2 + skip
		label = LoweringBasics.place_label(site.context, target)
		falsy = match operator {
			Less => Ge
			LessOrEqual => G
			Greater => Le
			_ => L
		}
		after = LoweringBasics.without_top(state, 2)
		side = |down| {
			kind: LoweringBasics.kind_below(state, down),
			origin: origins.get(depth - 1 - down) ?? Other,
		}
		# What holds where the ordering is true, as `lower <= upper - gap`.
		narrowed = match operator {
			Less => narrowed_below(
				after,
				{
					lower: side(1),
					upper: side(0),
					gap: 1,
				},
			)
			LessOrEqual => narrowed_below(
				after,
				{
					lower: side(1),
					upper: side(0),
					gap: 0,
				},
			)
			Greater => narrowed_below(
				after,
				{
					lower: side(0),
					upper: side(1),
					gap: 1,
				},
			)
			_ => narrowed_below(
				after,
				{
					lower: side(0),
					upper: side(1),
					gap: 0,
				},
			)
		}
		{
			statements: [
				Emit.load(Rax, left),
				Emit.load(Rcx, right),
				Emit.cmp(Rax, Rcx),
				Emit.jcc(falsy, label),
			],
			falls: Falls(narrowed),
			branch: Branch({ target, state: after }),
			result: GivesNothing,
		}
	}

	## `++` or `--` of a slot that holds an `Integer` and then holds
	## `stepped` (`LoweringBasics.integer_stepped`): the slot stepped by an
	## integer add, and its old value (postfix) or its new (prefix) pushed.
	integer_update_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
		step : Bytecode.Update,
		stepped : LoweringBasics.Kind,
	} -> LoweringBasics.Lowered
	integer_update_items = |site, { state, slot, step, stepped }| {
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len())
		place = LoweringBasics.slot_place(slot)
		held = match state.slots.get(slot) {
			Ok(Ready(kind)) => kind
			_ => crash "OperatorLowering.integer_update_items: a slot that holds an Integer"
		}
		moved = [
			Emit.load(Rax, place),
			Emit.plus_imm(Rax, LoweringBasics.whole_of_literal(step.delta)),
			Emit.store(place, Rax),
		]
		(items, pushed) = match step.fixity {
			Postfix => (LoweringBasics.copy_items({ from: place, to: top }).concat(moved), held)
			Prefix => (moved.append(Emit.store(top, Rax)), stepped)
		}
		slots = state.slots.set(
			slot,
			Ready(stepped),
		) ?? crash "OperatorLowering.integer_update_items: a slot"
		LoweringBasics.falling(items, LoweringBasics.with_top({ ..state, slots }, pushed))
	}

	## A `===` or `!==` of the two known numbers on top, followed by a
	## `JumpIfFalse`, as one (Lowering's `fused_jump` has the rule): both
	## dropped, and the jump taken to the `JumpIfFalse`'s target when the
	## operator's answer is false. Two doubles are equal when `ucomisd` sets
	## ZF and not PF, NaN's flag, so `===` is false on either `jne` or `jp`,
	## and `!==` is false when `je` holds and `jp` doesn't.
	equal_jump_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.BinaryOperator,
		skip : U64,
	} -> LoweringBasics.Lowered
	equal_jump_items = |site, { state, operator, skip }| {
		left = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 2)
		right = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		target = site.at + 2 + skip
		label = LoweringBasics.place_label(site.context, target)
		compared = [
			Instruction(MovsdLoad({ to: Xmm0, from: left })),
			Instruction(MovsdLoad({ to: Xmm1, from: right })),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
		]
		jumped = match operator {
			StrictEqual => [Emit.jcc(Ne, label), Emit.jcc(P, label)]
			_ => {
				unordered = LoweringBasics.inner_label(site, "unordered")
				[
					Emit.jcc(P, unordered),
					Emit.jcc(E, label),
					Emit.mark(unordered),
				]
			}
		}
		after = LoweringBasics.without_top(state, 2)
		{
			statements: compared.concat(jumped),
			falls: Falls(after),
			branch: Branch({ target, state: after }),
			result: GivesNothing,
		}
	}

	## Where a select's arm finds its known number: a literal's bits, or a
	## place of the frame.
	Arm : [Bits(I64), Place(X86.Mem)]

	## An ordering of two known numbers and a conditional of two known numbers
	## after it, lowered as one with no jump (Lowering's `fused_jump` says
	## when): the arm `held` when the ordering holds, `otherwise` when it
	## doesn't, in the place of the ordering's first operand. Both arms'
	## bits are loaded (`rax`, `rcx`) before the `ucomisd`, and `cmov` on its
	## flags keeps `held`'s: CF and ZF are clear only when the first is the
	## greater and neither is a NaN (`cmova`), and CF alone when the first is
	## at least the second (`cmovae`), so an ordering with a NaN keeps
	## `otherwise`, as JavaScript's false.
	selected_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		operator : Ast.BinaryOperator,
		held : OperatorLowering.Arm,
		otherwise : OperatorLowering.Arm,
	} -> LoweringBasics.Lowered
	selected_items = |site, { state, operator, held, otherwise }| {
		left = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 2)
		right = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		{ first, second, truthy } = match operator {
			Less => {
				first: right,
				second: left,
				truthy: A,
			}
			LessOrEqual => {
				first: right,
				second: left,
				truthy: Ae,
			}
			Greater => {
				first: left,
				second: right,
				truthy: A,
			}
			_ => {
				first: left,
				second: right,
				truthy: Ae,
			}
		}
		statements = [
			Instruction(arm_load(held, Rax)),
			Instruction(arm_load(otherwise, Rcx)),
			Instruction(MovsdLoad({ to: Xmm0, from: first })),
			Instruction(MovsdLoad({ to: Xmm1, from: second })),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Instruction(
				Cmov({
					condition: truthy,
					to: Rcx,
					from: Rax,
				}),
			),
			Instruction(MovMemReg({ to: left, from: Rcx })),
		]
		LoweringBasics.falling(
			statements,
			LoweringBasics.with_top(LoweringBasics.without_top(state, 2), Number),
		)
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
					Number | Integer(_) => Named("runtime_text_type_number")
					String => Named("runtime_text_type_string")
					Boolean => Named("runtime_text_type_boolean")
					Undefined => Named("runtime_text_undefined")
					Null | Array | Numbers | Object | Console => Named("runtime_text_type_object")
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
				Emit.jcc(Ne, LoweringBasics.place_label(site.context, target)),
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
		compared = binary_items(
			site,
			{
				state,
				operator: StrictEqual,
				checked: IndexLowering.nothing_proved(state.stack_kinds.len()),
			},
		)?
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
				Emit.jcc(E, LoweringBasics.place_label(site.context, target)),
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
		short_label = "${LoweringBasics.place_label(site.context, site.at)}_short"
		going_label = "${LoweringBasics.place_label(site.context, site.at)}_going"
		jumped = LoweringBasics.constant_items({
			bits: Boxing.undefined_bits.to_u64_wrap(),
			to: top,
		})
			.append(JmpTo(LoweringBasics.place_label(site.context, target)))
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
		jump = JccTo({ condition, label: LoweringBasics.place_label(site.context, target) })
		Ok({
			statements: tested.append(jump),
			falls: Falls(LoweringBasics.without_top(state, 1)),
			branch: Branch({ target, state: sent }),
			result: GivesNothing,
		})
	}
}

## An operator's statements for two values that may be numbers: `fast_items`,
## in line, when both are numbers (a known number's tag isn't tested), else
## `slow_items`, the runtime's routine.
numbers_first_items : LoweringBasics.Site,
{
	kinds : (LoweringBasics.Kind, LoweringBasics.Kind),
	left : X86.Mem,
	right : X86.Mem,
	fast_items : List(Assembly.Statement),
	slow_items : List(Assembly.Statement),
} -> List(Assembly.Statement)
numbers_first_items = |site, { kinds, left, right, fast_items, slow_items }| {
	slow_label = LoweringBasics.inner_label(site, "slow")
	done_label = LoweringBasics.inner_label(site, "done")
	LoweringBasics.unless_number_items({
		kind: kinds.0,
		place: left,
		label: slow_label,
	})
		.concat(
			LoweringBasics.unless_number_items({
				kind: kinds.1,
				place: right,
				label: slow_label,
			}),
		)
		.concat(fast_items)
		.concat([Emit.jmp(done_label), Emit.mark(slow_label)])
		.concat(slow_items)
		.append(Emit.mark(done_label))
}

## One side of an ordering of two `Integer`s: its kind, and where its stack
## place came from.
OrderedSide : { kind : LoweringBasics.Kind, origin : IndexLowering.Origin }

## `state` with what `lower <= upper - gap` says, on the way an ordering of
## two `Integer`s holds: the slot `lower` was loaded from holds at most
## `upper`'s most less the gap, and the slot `upper` was loaded from at
## least `lower`'s least and the gap. A range that would be empty is left as
## it was, since that way is never taken.
narrowed_below : LoweringBasics.State,
{
	lower : OrderedSide,
	upper : OrderedSide,
	gap : I64,
} -> LoweringBasics.State
narrowed_below = |state, { lower, upper, gap }| {
	narrowed = |slots, origin, bound|
		match origin {
			Local(slot) =>
				match slots.get(slot) {
					Ok(Ready(Integer(range))) => {
						kept = bound(range)
						if kept.low > kept.high {
							slots
						} else {
							slots.set(
								slot,
								Ready(Integer(kept)),
							) ?? crash "OperatorLowering.narrowed_below: a slot"
						}
					}
					_ => slots
				}
			_ => slots
		}
	match (lower.kind, upper.kind) {
		(Integer(low_side), Integer(high_side)) => {
			capped = narrowed(
				state.slots,
				lower.origin,
				|range| { ..range, high: I64.min(range.high, high_side.high - gap) },
			)
			floored = narrowed(
				capped,
				upper.origin,
				|range| { ..range, low: I64.max(range.low, low_side.low + gap) },
			)
			{ ..state, slots: floored }
		}
		_ => state
	}
}

## The load of an arm's bits into `to`.
arm_load : OperatorLowering.Arm, X86.Register -> X86.Instruction
arm_load = |arm, to|
	match arm {
		Bits(value) => MovRegImm({ to, value })
		Place(from) => MovRegMem({ to, from })
	}

## The size of the divisor on top of the stack, when the straight run says
## it is a number known before the program runs (a literal, or a boxed
## variable `KnownFunctions.constant_numbers` holds), and that number is a
## whole one, not 0, of at most 2^53 in size (the header's rule).
known_divisor : LoweringBasics.Site,
{
	state : LoweringBasics.State,
	checked : IndexLowering.Checked,
} -> Try(U64, [Unknown])
known_divisor = |site, { state, checked }| {
	depth = state.stack_kinds.len()
	known =
		if checked.origins.len() != depth {
			Err(Unknown)
		} else {
			match checked.origins.last() {
				Ok(Literal(number)) => Ok(number)
				Ok(Boxed(slot)) =>
					match site.context.numbers.get(slot) {
						Ok(number) => Ok(number)
						Err(_) => Err(Unknown)
					}
				_ => Err(Unknown)
			}
		}
	number = known?
	size = if number < 0.0 {
		-number
	} else {
		number
	}
	if size >= 1.0 and size <= 9007199254740992.0 and size.div_trunc_by(1.0) == size {
		match size.to_u64_try() {
			Ok(whole) => Ok(whole)
			Err(_) => Err(Unknown)
		}
	} else {
		Err(Unknown)
	}
}

## `%` of the value at `left` by a whole number known before the program
## runs, `divisor` its size, in line when the value is a number with no
## fraction of less than 2^63 in size, else `slow_items`, the routine's
## call (the header's rule).
constant_remainder_items : LoweringBasics.Site,
{
	kind : LoweringBasics.Kind,
	left : X86.Mem,
	divisor : U64,
	slow_items : List(Assembly.Statement),
} -> List(Assembly.Statement)
constant_remainder_items = |site, { kind, left, divisor, slow_items }| {
	slow_label = LoweringBasics.inner_label(site, "slow")
	done_label = LoweringBasics.inner_label(site, "done")
	# The dividend in `rcx`: a double with no fraction, of less than 2^63 in
	# size, survives the round trip through an integer; a fraction, an
	# infinity, a NaN or a number past 2^63 doesn't.
	whole = LoweringBasics.unless_number_items({ kind, place: left, label: slow_label })
		.concat([
			Instruction(MovsdLoad({ to: Xmm0, from: left })),
			Instruction(Cvttsd2si({ to: Rcx, from: Xmm0 })),
			Instruction(Cvtsi2sd({ to: Xmm1, from: Rcx })),
			Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
			Emit.jcc(P, slow_label),
			Emit.jcc(Ne, slow_label),
		])
	# The remainder in `rcx`, the dividend less the quotient times the
	# divisor; the quotient, rounded toward 0, is the high half of the
	# dividend times the magic multiplier, shifted, plus 1 for a negative
	# dividend.
	remainder =
		if divisor == 1 {
			[Emit.zero(Rcx)]
		} else {
			magic_remainder_items({ divisor, signed: True })
		}
	# The remainder made a double, with the dividend's sign bit or-ed in: a
	# remainder not 0 has the dividend's sign already, and a 0 one is -0
	# when the dividend is negative or -0.
	signed = [
		Instruction(Cvtsi2sd({ to: Xmm0, from: Rcx })),
		Instruction(MovqFromXmm({ to: Rax, from: Xmm0 })),
		Emit.load(Rdx, left),
		Emit.shr(Rdx, 63),
		Emit.shl(Rdx, 63),
		Instruction(
			Alu({
				operation: Or,
				to: Rax,
				from: Rdx,
			}),
		),
		Emit.store(left, Rax),
		Emit.jmp(done_label),
		Emit.mark(slow_label),
	]
	whole
		.concat(remainder)
		.concat(signed)
		.concat(slow_items)
		.append(Emit.mark(done_label))
}

## `%` of the `Integer` at `left`, at least 0, by the one at `right`, whose
## range holds no 0 (`LoweringBasics.integer_arithmetic` says so), the
## remainder at `left`. A divisor whose range is one value is a constant of
## that size (`n % -d` is `n % d`): 1 gives 0, a power of two up to 2^31 an
## `and`, any other the magic multiply. Any other divisor takes an `idiv`,
## whose remainder has the dividend's sign, as `%`'s has.
integer_remainder_items : {
	left : X86.Mem,
	right : X86.Mem,
	divisor : LoweringBasics.Kind,
} -> List(Assembly.Statement)
integer_remainder_items = |{ left, right, divisor }|
	match constant_size(divisor) {
		Ok(1) => [Emit.zero(Rax), Emit.store(left, Rax)]
		Ok(size) if is_power_of_two(size) and size <= 2147483648 => [
			Emit.load(Rax, left),
			Emit.bit_and_imm(Rax, (size - 1).to_i64_wrap()),
			Emit.store(left, Rax),
		]
		Ok(size) =>
			[Emit.load(Rcx, left)]
				.concat(magic_remainder_items({ divisor: size, signed: False }))
				.append(Emit.store(left, Rcx))
		Err(Unknown) => [
			Emit.load(Rax, left),
			Instruction(Cqo),
			Emit.load(Rcx, right),
			Instruction(Idiv(Rcx)),
			Emit.store(left, Rdx),
		]
	}

## The size of an `Integer` divisor whose range is one value, not 0.
constant_size : LoweringBasics.Kind -> Try(U64, [Unknown])
constant_size = |kind|
	match kind {
		Integer({ low, high }) if low == high and low > 0 => Ok(low.to_u64_wrap())
		Integer({ low, high }) if low == high and low < 0 => Ok((0 - low).to_u64_wrap())
		_ => Err(Unknown)
	}

## Whether a size is a power of two.
is_power_of_two : U64 -> Bool
is_power_of_two = |size| size > 0 and size.bitwise_and(size - 1) == 0

## The power of two a size that is one is: 16 is 2^4.
power_of : U64 -> U8
power_of = |size| {
	var $power = 0
	var $left = size
	while $left > 1 {
		$left = $left.shr_wrap(1)
		$power = $power + 1
	}
	$power
}

## The quotient of the integer in `rcx` by `divisor`, at least 2, rounded
## toward 0, in `rdx`, by the magic multiply (`remainder_magic`; `rax`
## taken). A dividend known to be at least 0 (`signed` false) leaves out
## the 1 a negative one adds.
magic_quotient_items : { divisor : U64, signed : Bool } -> List(Assembly.Statement)
magic_quotient_items = |{ divisor, signed }| {
	{ multiplier, shift } = remainder_magic(divisor)
	added =
		if multiplier < 0 {
			[Emit.plus(Rdx, Rcx)]
		} else {
			[]
		}
	shifted =
		if shift > 0 {
			[
				Instruction(
					Shift({
						operation: Sar,
						reg: Rdx,
						count: shift,
					}),
				),
			]
		} else {
			[]
		}
	rounded =
		if signed {
			[Emit.mov(Rax, Rcx), Emit.shr(Rax, 63), Emit.plus(Rdx, Rax)]
		} else {
			[]
		}
	[Emit.imm(Rax, multiplier), Instruction(ImulWide(Rcx))]
		.concat(added)
		.concat(shifted)
		.concat(rounded)
}

## The remainder of the integer in `rcx` by `divisor`, at least 2, in
## `rcx`: the dividend less its quotient (`magic_quotient_items`) times the
## divisor, so it has the dividend's sign (`rax` and `rdx` taken).
magic_remainder_items : { divisor : U64, signed : Bool } -> List(Assembly.Statement)
magic_remainder_items = |{ divisor, signed }|
	magic_quotient_items({ divisor, signed }).concat([
		Emit.imm(Rax, divisor.to_i64_wrap()),
		Instruction(Imul({ to: Rdx, from: Rax })),
		Emit.minus(Rcx, Rdx),
	])

## The multiplier and shift that divide a signed 64-bit integer by
## `divisor`, at least 2, with a multiply (Hacker's Delight, figure 10-1,
## for a positive divisor): the quotient of a dividend is the high half of
## the dividend times `multiplier`, plus the dividend when `multiplier` is
## negative, shifted right by `shift`, plus 1 when the dividend is
## negative.
RemainderMagic : { multiplier : I64, shift : U8 }

## The search of figure 10-1, its names made words: `limit` is the largest
## dividend below 2^63 whose remainder is `divisor - 1` (the book's `anc`),
## and the power of two grows from 2^63 until 2^power over `divisor`,
## rounded up, is close enough to the exact reciprocal for every dividend
## up to `limit`. Each quotient and its rest is kept as the power grows (the
## book's `q1`, `r1` of `limit`, `q2`, `r2` of `divisor`), and the
## multiplier is the divisor's quotient plus 1.
remainder_magic : U64 -> RemainderMagic
remainder_magic = |divisor| {
	two_to_63 : U64
	two_to_63 = 9223372036854775808
	limit = two_to_63 - 1 - two_to_63 % divisor
	var $power = 63
	var $limit_quotient = two_to_63 // limit
	var $limit_rest = two_to_63 - $limit_quotient * limit
	var $divisor_quotient = two_to_63 // divisor
	var $divisor_rest = two_to_63 - $divisor_quotient * divisor
	var $going = True
	while $going {
		$power = $power + 1
		$limit_quotient = $limit_quotient.shl_wrap(1)
		$limit_rest = $limit_rest.shl_wrap(1)
		if $limit_rest >= limit {
			$limit_quotient = $limit_quotient.plus_wrap(1)
			$limit_rest = $limit_rest - limit
		}
		$divisor_quotient = $divisor_quotient.shl_wrap(1)
		$divisor_rest = $divisor_rest.shl_wrap(1)
		if $divisor_rest >= divisor {
			$divisor_quotient = $divisor_quotient.plus_wrap(1)
			$divisor_rest = $divisor_rest - divisor
		}
		gap = divisor - $divisor_rest
		$going = $limit_quotient < gap or ($limit_quotient == gap and $limit_rest == 0)
	}
	multiplier = $divisor_quotient.plus_wrap(1).to_i64_wrap()
	shift = ($power - 64).to_u8_wrap()
	{ multiplier, shift }
}

## `dividend` over `divisor`, rounded down, as an arithmetic shift rounds.
floor_quotient : I128, I128 -> I128
floor_quotient = |dividend, divisor| {
	rest = ((dividend % divisor) + divisor) % divisor
	(dividend - rest) // divisor
}

## `dividend % divisor` as `constant_remainder_items`'s instructions work it
## out, for the expect.
magic_remainder : I64, U64 -> I64
magic_remainder = |dividend, divisor| {
	{ multiplier, shift } = remainder_magic(divisor)
	two_to_64 : I128
	two_to_64 = 18446744073709551616
	wide = dividend.to_i128()
	high = floor_quotient(wide * multiplier.to_i128(), two_to_64)
	added = if multiplier < 0 {
		high + wide
	} else {
		high
	}
	shifted = floor_quotient(added, ((1).to_i128()).shl_wrap(shift))
	quotient = if dividend < 0 {
		shifted + 1
	} else {
		shifted
	}
	(wide - quotient * divisor.to_i128()).to_i64_wrap()
}

expect {
	# The magic remainder is the truncating one for every divisor the
	# tests use, the race's among them, over dividends of both signs up to
	# 2^63 in size.
	divisors = [
		2,
		3,
		7,
		10,
		500,
		10000,
		50000,
		2147483647,
		1000000007,
		1099511627776,
		9007199254740991,
		9007199254740992,
	]
	dividends = [
		0,
		1,
		-1,
		2,
		-2,
		6,
		-6,
		7,
		-7,
		13,
		-13,
		2147483646,
		2147483647,
		-2147483648,
		4294967296,
		103723447396417,
		9007199254740991,
		9007199254740992,
		-9007199254740992,
		9007199254740993,
		4611686018427387904,
		9223372036854775807,
		-9223372036854775807,
	]
	is_truncating = |divisor, dividend| {
		truncated = dividend % divisor.to_i64_wrap()
		magic_remainder(dividend, divisor) == truncated
	}
	divisors.all(|divisor| dividends.all(|dividend| is_truncating(divisor, dividend)))
}

# `i < n` with `i` any `Integer` and `n` a length: where it holds, `i` is at
# most the length's most less 1, and `n` at least 1 more than `i`'s least
# (floored by `n`'s own 0); `<=` keeps the most; a side not loaded from a
# slot narrows nothing.
expect {
	length = Integer({ low: 0, high: 4294967296 })
	state = { slots: [Ready(LoweringBasics.any_integer), Ready(length)], stack_kinds: [] }
	below = |gap, origin| narrowed_below(
		state,
		{
			lower: { kind: LoweringBasics.any_integer, origin: Local(0) },
			upper: { kind: length, origin },
			gap,
		},
	)
	counter = Ready(Integer({ low: 0 - LoweringBasics.integer_limit, high: 4294967295 }))
	below(1, Local(1)).slots == [counter, Ready(length)]
		and below(0, Other).slots == [
			Ready(Integer({ low: 0 - LoweringBasics.integer_limit, high: 4294967296 })),
			Ready(length),
		]
}

# `i >= 0`, as `0 <= i`: `i` is at least 0 where it holds, its most kept.
expect {
	state = { slots: [Ready(Integer({ low: -2, high: 99 }))], stack_kinds: [] }
	narrowed = narrowed_below(
		state,
		{
			lower: { kind: Integer({ low: 0, high: 0 }), origin: Literal(0.0) },
			upper: { kind: Integer({ low: -2, high: 99 }), origin: Local(0) },
			gap: 0,
		},
	)
	narrowed.slots == [Ready(Integer({ low: 0, high: 99 }))]
}
