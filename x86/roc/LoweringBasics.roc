## This module holds what every part of the x86-64 lowering shares: the
## kinds it knows before the program runs (`Kind`, `Slot`, `State`), what
## lowering one function knows of the rest (`Context`, `Site`), what an
## instruction lowers to (`Lowered`), the labels of codes and texts, a
## refusal naming its function and place, and the frame and stack basics:
## a slot's and a stack place's address, the stack's top kinds, a copy, a
## constant, a slot read and written, a truth test, a number checked.
##
## It stands apart from Lowering because Lowering is being split into
## families of instructions (the closure analysis, the operators, the
## builtins, the calls), each a module of its own that Lowering imports and
## that uses these too: a module they all import, and that imports none of
## them, is the one place the basics can live without a cycle.
import js.Ast
import js.Bytecode
import Assembly
import Boxing
import Emit
import ObjectTable
import Runtime
import X86

LoweringBasics :: [].{

	## What a slot or a place on the stack holds, known before the program runs.
	## A value's kind (`Number` to `Value`, whose bits are a value's boxed bits,
	## `Boxing.roc`; `Closure(code)` a function value whose code is known), or
	## what takes no bytes: a function known before the program runs by its
	## code, `console`, its `log`, and a method looked up by name on a value.
	Kind : [
		Number,
		# A whole number kept as an integer, not a double, between `low` and
		# `high`, both within ±2^53 (x86/README.md, "An integer kind"): never
		# -0, NaN or an infinity, and exactly a double when converted.
		Integer({ low : I64, high : I64 }),
		Boolean,
		Undefined,
		Null,
		String,
		Array,
		# An array that holds only numbers for good (`Lowering`'s
		# `NUMBER-ONLY ARRAYS`): its items read as numbers.
		Numbers,
		# An array of numbers whose items are whole numbers between `low` and
		# `high` for good, kept as doubles (`Lowering`'s `INTEGER ARRAYS`): its
		# items read as `Integer`s.
		Integers({ low : I64, high : I64 }),
		Object,
		Value,
		Closure(U64),
		Function(U64),
		Console,
		Log,
		Method(Str),
		ErrorClass(Str),
		# `Map` or `Set`, which `new` makes one of.
		CollectionClass(Str),
		# `setTimeout`, `setInterval`, `clearTimeout` or `clearInterval`.
		TimerFunction(Str),
		Static(Str),
		StaticMethod({ owner : Str, name : Str }),
	]

	## A slot holds a value of its kind once its declaration has run: on every
	## way here (`Ready`), on none (`Unready`, which a read or a write throws
	## node's ReferenceError for), or on some (`Unsure`, refused).
	Slot : [Unready, Unsure, Ready(LoweringBasics.Kind)]

	## The kinds at one instruction: each slot's, and the stack's, bottom first.
	State : { slots : List(LoweringBasics.Slot), stack_kinds : List(LoweringBasics.Kind) }

	## Where each function's code is made: the code that makes it and the slots
	## of that code's frame its closure captures, in order.
	Maker : {
		parent : U64,
		captures : List(U64),
		name : Str,
		form : Ast.Form,
	}

	## What `held_function` reads: the program, where each code is made, and
	## the codes known before the program runs.
	Known : {
		program : Bytecode.Program,
		makers : Dict(U64, LoweringBasics.Maker),
		statics : List(U64),
	}

	## What lowering one function needs to know of the rest.
	Context : {
		program : Bytecode.Program,
		makers : Dict(U64, LoweringBasics.Maker),
		statics : List(U64),
		escaped_codes : List(U64),
		# The slots of this code's frame that hold a cell's address.
		cells : List(U64),
		# The captured cells that hold one number for good, with the number
		# (`KnownFunctions.constant_numbers`).
		numbers : Dict(U64, F64),
		# Whether the program has a `try` anywhere, which keeps every value of
		# every frame in the frame (`Registers.roc`).
		trying : Bool,
		# Which array literals are made `Numbers` or `Integers`.
		arrays : LoweringBasics.ArrayRule,
		returns : Dict(U64, LoweringBasics.Kind),
		parameters : Dict(U64, List(LoweringBasics.Kind)),
		literals : Dict(Str, U64),
		# The places an instance's entries are expected to hold each field at
		# (`FieldSlots.field_slots`).
		field_slots : Dict(Str, List(U64)),
		# The places a class's table is expected to hold each key at, and the
		# codes it may hold there (`MethodTables.method_tables`).
		methods : LoweringBasics.MethodGuesses,
		index : U64,
	}

	## For each key some class's table holds, the places among a table's
	## entries it is expected at, and the codes of the methods it may hold.
	MethodGuesses : { places : Dict(Str, List(U64)), codes : Dict(Str, List(U64)) }

	## Which array literals a lowering keeps as arrays of numbers: none
	## (`AnyItems`), those of known numbers (`NumberItems`, `Numbers`), and
	## those too whose items are `Integer`s (`IntegerItems`, `Integers`).
	ArrayRule : [AnyItems, NumberItems, IntegerItems]

	## Whether a kind is an array that holds only numbers for good, its items
	## doubles or whole numbers: `Numbers` or `Integers`.
	holds_numbers : LoweringBasics.Kind -> Bool
	holds_numbers = |kind|
		match kind {
			Numbers | Integers(_) => True
			_ => False
		}

	## A call of a function by its code, with its arguments' kinds.
	CallKinds : { code : U64, kinds : List(LoweringBasics.Kind) }

	## Whether a kind is a value's, with boxed bits: an `Integer`'s bits are an
	## integer's, so it isn't one until it is converted.
	is_value_kind : LoweringBasics.Kind -> Bool
	is_value_kind = |kind|
		match kind {
			Integer(_) => False
			Number | Boolean | Undefined | Null => True
			String | Array | Numbers | Integers(_) | Object | Value | Closure(_) => True
			Function(_) | Console | Log | Method(_) => False
			ErrorClass(_) | CollectionClass(_) | TimerFunction(_) => False
			Static(_) | StaticMethod(_) => False
		}

	## Whether a direct call may push an argument of this kind: a value's, or
	## an `Integer`, which the walk leaves only where the callee's parameter
	## takes one (Lowering's `integer_arguments`).
	is_argument_kind : LoweringBasics.Kind -> Bool
	is_argument_kind = |kind| LoweringBasics.is_value_kind(kind) or LoweringBasics.is_integer(kind)

	## The kind two ways give a place: their own when they agree, `Value` when
	## both are values, and none for anything else. An `Integer` meets a value
	## as the number it is (`Integer ⊑ Number`), as two calls' arguments meet
	## at a parameter.
	met_kind : LoweringBasics.Kind, LoweringBasics.Kind -> Try(LoweringBasics.Kind, [Apart])
	met_kind = |one, other|
		if one == other {
			Ok(one)
		} else if LoweringBasics.is_integer(one) and LoweringBasics.is_integer(other) {
			Ok(LoweringBasics.integer_hull(one, other))
		} else if LoweringBasics.is_integer(one) and LoweringBasics.is_value_kind(other) {
			LoweringBasics.met_kind(Number, other)
		} else if LoweringBasics.is_value_kind(one) and LoweringBasics.is_integer(other) {
			LoweringBasics.met_kind(one, Number)
		} else if LoweringBasics.is_value_kind(one) and LoweringBasics.is_value_kind(other) {
			Ok(Value)
		} else {
			Err(Apart)
		}

	## Whether a kind is an `Integer`.
	is_integer : LoweringBasics.Kind -> Bool
	is_integer = |kind|
		match kind {
			Integer(_) => True
			_ => False
		}

	## The `Integer` of both of two `Integer`s' ranges, where two ways meet.
	integer_hull : LoweringBasics.Kind, LoweringBasics.Kind -> LoweringBasics.Kind
	integer_hull = |one, other|
		match (one, other) {
			(Integer(one_range), Integer(other_range)) =>
				Integer({
					low: I64.min(one_range.low, other_range.low),
					high: I64.max(one_range.high, other_range.high),
				})
			_ => crash "LoweringBasics.integer_hull: two Integers"
		}

	## The most an `Integer` may hold either side of 0, 2^53: every whole number
	## up to it is exactly a double.
	integer_limit : I64
	integer_limit = 9007199254740992

	## An `Integer` of the whole range, as a loop's head widens one whose range
	## grows on the way back.
	any_integer : LoweringBasics.Kind
	any_integer = Integer({
		low: 0 - LoweringBasics.integer_limit,
		high: LoweringBasics.integer_limit,
	})

	## The `Integer` at `place` made the double it is, in place: exact, since an
	## `Integer` is within ±2^53.
	integer_converted_items : X86.Mem -> List(Assembly.Statement)
	integer_converted_items = |place| [
		Emit.load(Rax, place),
		Instruction(Cvtsi2sd({ to: Xmm0, from: Rax })),
		Instruction(MovsdStore({ to: place, from: Xmm0 })),
	]

	## The `Integer` a number literal is: a whole number within ±2^53 that
	## isn't -0.
	integer_of_literal : F64 -> Try(LoweringBasics.Kind, [NotInteger])
	integer_of_literal = |number| {
		limit = LoweringBasics.integer_limit.to_f64()
		if number.is_nan() or number.is_infinite() or number < 0 - limit or number > limit {
			return Err(NotInteger)
		}
		if number.to_bits() == negative_zero_bits or number.div_trunc_by(1.0) != number {
			return Err(NotInteger)
		}
		whole = LoweringBasics.whole_of_literal(number)
		Ok(Integer({ low: whole, high: whole }))
	}

	## A whole number literal within ±2^53, as an integer.
	whole_of_literal : F64 -> I64
	whole_of_literal = |number|
		match number.floor_to_i64_try() {
			Ok(whole) => whole
			Err(_) => crash "LoweringBasics.whole_of_literal: a whole number within ±2^53"
		}

	## The `Integer` that `+`, `-`, `*` or `%` of two kinds gives
	## (x86/README.md, "An integer kind"): both `Integer`s, and the result's
	## bounds within ±2^53. A product that may be -0 (a factor that may be 0
	## times one that may be negative) is no `Integer`, nor is a remainder
	## that may be NaN or -0 (`integer_remainder`).
	integer_arithmetic : {
		operator : Ast.BinaryOperator,
		left : LoweringBasics.Kind,
		right : LoweringBasics.Kind,
	} -> Try(LoweringBasics.Kind, [NotInteger])
	integer_arithmetic = |{ operator, left, right }|
		match (left, right) {
			(Integer(one), Integer(other)) =>
				match operator {
					Add => integer_within(one.low + other.low, one.high + other.high)
					Subtract => integer_within(one.low - other.high, one.high - other.low)
					Multiply => integer_product(one, other)
					Remainder => integer_remainder(one, other)
					_ => Err(NotInteger)
				}
			_ => Err(NotInteger)
		}

	## The `Integer` that `Math.floor(a / b)` of two kinds gives: both
	## `Integer`s and the divisor at least 1, so the quotient is never NaN, an
	## infinity or -0 (a dividend of 0 over a positive divisor is 0). Its
	## bounds are the least and the most of the four corners' floored
	## quotients, within the dividend's own.
	integer_floor_quotient : LoweringBasics.Kind,
	LoweringBasics.Kind -> Try(
		LoweringBasics.Kind,
		[NotInteger],
	)
	integer_floor_quotient = |left, right|
		match (left, right) {
			(Integer(dividend), Integer(divisor)) if divisor.low >= 1 => {
				first = floor_of_quotient(dividend.low, divisor.low)
				corners = [
					floor_of_quotient(dividend.low, divisor.high),
					floor_of_quotient(dividend.high, divisor.low),
					floor_of_quotient(dividend.high, divisor.high),
				]
				low = corners.fold(first, I64.min)
				high = corners.fold(first, I64.max)
				integer_within(low, high)
			}
			_ => Err(NotInteger)
		}

	## Whether an operator is a bitwise one: `&`, `|`, `^`, `<<`, `>>` or
	## `>>>`.
	is_bitwise : Ast.BinaryOperator -> Bool
	is_bitwise = |operator|
		match operator {
			BitAnd | BitOr | BitExclusiveOr => True
			ShiftLeft | ShiftRight | ShiftRightUnsigned => True
			_ => False
		}

	## Whether a bitwise operator takes an operand of this kind: an `Integer`
	## as it is, a number or a value made its 32-bit integer as it runs (a
	## value that isn't a number stops the program). Any other kind is a
	## coercion, refused.
	takes_bitwise : LoweringBasics.Kind -> Bool
	takes_bitwise = |kind|
		match kind {
			Integer(_) | Number | Value => True
			_ => False
		}

	## The `Integer` a bitwise operator gives, whatever its operands' kinds:
	## a signed 32-bit integer, or an unsigned one for `>>>`, its range
	## narrowed where the operands' ranges say (x86/README.md, "The bitwise
	## operators"). An operand's range counts only when it lies within 32
	## bits, signed (or unsigned, for `>>>`'s first): any other wraps.
	bitwise_kind : {
		operator : Ast.BinaryOperator,
		left : LoweringBasics.Kind,
		right : LoweringBasics.Kind,
	} -> LoweringBasics.Kind
	bitwise_kind = |{ operator, left, right }| {
		one = signed_range(left)
		other = signed_range(right)
		count = shift_count_of(right)
		range = match operator {
			BitAnd => anded_range(one, other)
			BitOr | BitExclusiveOr => united_range(one, other)
			ShiftLeft => left_shifted_range(one, count)
			ShiftRight => right_shifted_range(one, count)
			_ => unsigned_shifted_range(unsigned_range(left), count)
		}
		Integer(range)
	}

	## The `Integer` `~` gives: the operand's 32 bits turned over, so a range
	## within 32 bits, signed, is its mirror less 1.
	bitwise_not_kind : LoweringBasics.Kind -> LoweringBasics.Kind
	bitwise_not_kind = |kind| {
		range = signed_range(kind)
		Integer({ low: -1 - range.high, high: -1 - range.low })
	}

	## The `Integer` a slot holding `kind` holds after `++` or `--` steps it
	## by `delta`.
	integer_stepped : LoweringBasics.Kind, F64 -> Try(LoweringBasics.Kind, [NotInteger])
	integer_stepped = |kind, delta|
		match LoweringBasics.integer_of_literal(delta) {
			Ok(step) => LoweringBasics.integer_arithmetic({
				operator: Add,
				left: kind,
				right: step,
			})
			Err(NotInteger) => Err(NotInteger)
		}

	literal_label : U64 -> Str
	literal_label = |number| "literal_${number.to_str()}"

	## The label of a text the program names.
	text_label : LoweringBasics.Site, Str -> Str
	text_label = |site, text| {
		number = match site.context.literals.get(text) {
			Ok(numbered) => numbered
			Err(_) => crash "LoweringBasics.text_label: every text is numbered"
		}
		LoweringBasics.literal_label(number)
	}

	## One instruction's place, for the code it lowers to and its messages.
	Site : {
		context : LoweringBasics.Context,
		code : Bytecode.Code,
		at : U64,
		skipped : List(U64),
	}

	## What an instruction lowers to: its machine code, the state after it when
	## the next instruction follows, and the state at a jump's target.
	Lowered : {
		statements : List(Assembly.Statement),
		falls : [Falls(LoweringBasics.State), Ends],
		branch : [Branch({ target : U64, state : LoweringBasics.State }), NoBranch],
		result : [Gives(LoweringBasics.Kind), GivesNothing],
	}

	function_name : LoweringBasics.Context -> Str
	function_name = |context|
		if context.index == context.program.main {
			"the program"
		} else {
			match context.makers.get(context.index) {
				Ok(maker) => "the function `${maker.name}`"
				Err(_) => "a function made nowhere"
			}
		}

	code_label : U64 -> Str
	code_label = |index| "code_${index.to_str()}"

	## The entry of a call through a value, whose count of arguments is in `rcx`.
	value_label : U64 -> Str
	value_label = |index| "code_${index.to_str()}_value"

	## Where both entries meet, once the parameters are in their slots.
	start_label : U64 -> Str
	start_label = |index| "code_${index.to_str()}_start"

	## The closure record of a function known before the program runs.
	closure_label : U64 -> Str
	closure_label = |index| "closure_${index.to_str()}"

	## The text console.log writes for a function.
	function_text_label : U64 -> Str
	function_text_label = |index| "function_text_${index.to_str()}"

	## The label of an instruction of the code being lowered.
	place_label : LoweringBasics.Context, U64 -> Str
	place_label = |context, at| "code_${context.index.to_str()}_${at.to_str()}"

	slot_place : U64 -> X86.Mem
	slot_place = |slot| Based({
		base: Rbp,
		index: NoIndex,
		displacement: (0 - 8 * (slot.to_i64_wrap() + 1)).to_i32_wrap(),
	})

	## The place of the value `depth` places up the stack of a code.
	stack_place : Bytecode.Code, U64 -> X86.Mem
	stack_place = |code, depth| LoweringBasics.slot_place(code.frame_size + depth)

	## The instruction's refusal, naming its function and place.
	refusal : LoweringBasics.Site, Str -> Try(a, [Refused(Str)])
	refusal = |site, why| {
		named = LoweringBasics.function_name(site.context)
		Err(Refused("${named}, instruction ${site.at.to_str()}: ${why}"))
	}

	## An instruction that falls through to the next with `state`.
	falling : List(Assembly.Statement), LoweringBasics.State -> LoweringBasics.Lowered
	falling = |items, state| {
		statements: items,
		falls: Falls(state),
		branch: NoBranch,
		result: GivesNothing,
	}

	## The value `down` places down from the top of the stack (0 is the top).
	kind_below : LoweringBasics.State, U64 -> LoweringBasics.Kind
	kind_below = |state, down| {
		kinds = state.stack_kinds
		match kinds.get(kinds.len() - 1 - down) {
			Ok(kind) => kind
			Err(_) => crash "LoweringBasics.kind_below: a value the stack holds"
		}
	}

	## The stack with its top `count` values gone.
	without_top : LoweringBasics.State, U64 -> LoweringBasics.State
	without_top = |state, count| {
		..state,
		stack_kinds: state.stack_kinds.take_first(state.stack_kinds.len() - count),
	}

	with_top : LoweringBasics.State, LoweringBasics.Kind -> LoweringBasics.State
	with_top = |state, kind| { ..state, stack_kinds: state.stack_kinds.append(kind) }

	## A copy of 8 bytes from one place to another, through `rax`.
	copy_items : { from : X86.Mem, to : X86.Mem } -> List(Assembly.Statement)
	copy_items = |{ from, to }| [
		Instruction(MovRegMem({ to: Rax, from })),
		Instruction(MovMemReg({ to, from: Rax })),
	]

	## The bits of a constant stored at a place.
	constant_items : { bits : U64, to : X86.Mem } -> List(Assembly.Statement)
	constant_items = |{ bits, to }| [
		Instruction(MovRegImm({ to: Rax, value: bits.to_i64_wrap() })),
		Instruction(MovMemReg({ to, from: Rax })),
	]

	## A slot read: refused while it is unready, or when it is no slot.
	slot_kind : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
		name : Str,
	} -> Try(LoweringBasics.Kind, [Refused(Str)])
	slot_kind = |site, { state, slot, name }|
		match state.slots.get(slot) {
			Ok(Ready(kind)) => Ok(kind)
			Ok(Unready) | Ok(Unsure) => LoweringBasics.refusal(
				site,
				"${name} is read before its declaration has run, which throws in node",
			)
			Err(_) => crash "LoweringBasics.slot_kind: a slot of the frame"
		}

	## A slot written with the value on top of the stack: refused for a
	## function's name, and for a value that isn't a number, a boolean or
	## `undefined`.
	written_slot : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
	} -> Try(LoweringBasics.State, [Refused(Str)])
	written_slot = |site, { state, slot }| {
		match state.slots.get(slot) {
			Ok(Ready(Function(_))) => return LoweringBasics.refusal(
				site,
				"a function's name is assigned",
			)
			_ => {}
		}
		given = LoweringBasics.kind_below(state, 0)
		if !LoweringBasics.is_value_kind(given) and !LoweringBasics.is_integer(given) {
			return LoweringBasics.refusal(
				site,
				"a variable is given a function, `console` or a method",
			)
		}
		# An `Integer`'s bits are no value's, so one reaches a cell made a
		# double (Lowering's `integers_made`).
		if LoweringBasics.is_integer(given) and site.context.cells.contains(slot) {
			crash "LoweringBasics.written_slot: an Integer reaches no cell"
		}
		# A cell is shared with the closures that capture it, whose writes no
		# walk of this code sees.
		kind =
			if site.context.cells.contains(slot) {
				Value
			} else {
				given
			}
		slots = state.slots.set(
			slot,
			Ready(kind),
		) ?? crash "LoweringBasics.written_slot: a slot of the frame"
		Ok({ ..state, slots })
	}

	## The value on top of the stack stored in its slot.
	store_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
	} -> List(Assembly.Statement)
	store_items = |site, { state, slot }| LoweringBasics.copy_items({
		from: LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1),
		to: LoweringBasics.slot_place(slot),
	})

	## A slot's value pushed.
	load_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
	} -> List(Assembly.Statement)
	load_items = |site, { state, slot }| LoweringBasics.copy_items({
		from: LoweringBasics.slot_place(slot),
		to: LoweringBasics.stack_place(site.code, state.stack_kinds.len()),
	})

	## A truth test of the value on top of the stack: the flags set so that
	## `E` holds when it is falsy (false, 0, -0 or NaN).
	truth_items : LoweringBasics.Site,
	LoweringBasics.State -> Try(
		List(Assembly.Statement),
		[Refused(Str)],
	)
	truth_items = |site, state| {
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		match LoweringBasics.kind_below(state, 0) {
			Boolean => Ok([
				Instruction(MovRegMem({ to: Rax, from: top })),
				Emit.imm(Rcx, Boxing.false_bits),
				Emit.cmp(Rax, Rcx),
			])
			Number =>
				Ok([
					Instruction(MovsdLoad({ to: Xmm0, from: top })),
					Instruction(
						Alu({
							operation: Xor,
							to: Rcx,
							from: Rcx,
						}),
					),
					Instruction(MovqToXmm({ to: Xmm1, from: Rcx })),
					Instruction(Ucomisd({ left: Xmm0, right: Xmm1 })),
				])
			kind =>
				if LoweringBasics.is_value_kind(kind) {
					Ok([
						Emit.load(Rdi, top),
						Emit.call(Runtime.truthy),
						Emit.test(Rax, Rax),
					])
				} else {
					LoweringBasics.refusal(site, "a test of ${LoweringBasics.kind_phrase(kind)}")
				}
		}
	}

	## A jump's target: `skip` instructions on from the next, or back.
	forward : LoweringBasics.Site, U64 -> U64
	forward = |site, skip| site.at + 1 + skip

	## `++` or `--` of a slot holding a number: the slot stepped, and the old
	## value (postfix) or the new (prefix) pushed.
	update_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
		step : Bytecode.Update,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	update_items = |site, { state, slot, step }| {
		kind = LoweringBasics.slot_kind(site, { state, slot, name: "a variable" })?
		if !LoweringBasics.is_numeric(kind) {
			return LoweringBasics.refusal(site, "`++` or `--` of a value that is not a number")
		}
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len())
		checked = LoweringBasics.number_check_items({
			kind,
			place: LoweringBasics.slot_place(slot),
		})
		numbered = {
			..state,
			slots: state.slots.set(
				slot,
				Ready(Number),
			) ?? crash "LoweringBasics.update_items: a slot",
		}
		stepped = [
			Instruction(MovsdLoad({ to: Xmm0, from: LoweringBasics.slot_place(slot) })),
			Instruction(MovRegImm({ to: Rax, value: step.delta.to_bits().to_i64_wrap() })),
			Instruction(MovqToXmm({ to: Xmm1, from: Rax })),
			Instruction(
				Sse({
					operation: Addsd,
					to: Xmm0,
					from: Xmm1,
				}),
			),
			Instruction(MovsdStore({ to: LoweringBasics.slot_place(slot), from: Xmm0 })),
		]
		items = match step.fixity {
			Postfix => LoweringBasics.copy_items({
				from: LoweringBasics.slot_place(slot),
				to: top,
			}).concat(stepped)
			Prefix => stepped.append(Instruction(MovsdStore({ to: top, from: Xmm0 })))
		}
		Ok(LoweringBasics.falling(checked.concat(items), LoweringBasics.with_top(numbered, Number)))
	}

	## `o.k++`, `--o.k` and their kin, the receiver on top: the runtime's
	## read, step and write (`runtime_update_property_hashed`), its answer, the
	## old number or the new, in the receiver's place. A receiver that is
	## `undefined` or `null` throws node's TypeError in the read.
	property_update_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		key : Str,
		step : Bytecode.Update,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	property_update_items = |site, { state, key, step }| {
		kind = LoweringBasics.kind_below(state, 0)
		match kind {
			Object | Value | Null | Undefined => {}
			_ => return LoweringBasics.refusal(
				site,
				"`++` or `--` of the property `${key}` of ${LoweringBasics.kind_phrase(kind)}",
			)
		}
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)
		fixity = match step.fixity {
			Postfix => 0
			Prefix => 1
		}
		items = [
			Emit.load(Rdi, top),
			Emit.address_of(Rsi, LoweringBasics.text_label(site, key)),
			Emit.imm(R8, ObjectTable.key_hash(key)),
			Emit.imm(Rdx, step.delta.to_bits().to_i64_wrap()),
			Emit.imm(Rcx, fixity),
			Emit.call(ObjectTable.update_property_hashed),
			Emit.store(top, Rax),
		]
		Ok(
			LoweringBasics.falling(
				items,
				LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Number),
			),
		)
	}

	## Whether a kind may be a number: arithmetic on it is checked or free.
	is_numeric : LoweringBasics.Kind -> Bool
	is_numeric = |kind|
		match kind {
			Number | Value => True
			_ => False
		}

	## Whether two kinds may each be a number.
	are_numeric : (LoweringBasics.Kind, LoweringBasics.Kind) -> Bool
	are_numeric = |(one, other)| LoweringBasics.is_numeric(one) and LoweringBasics.is_numeric(other)

	## Whether two kinds may be ordered by `runtime_compare`: two numbers or two
	## strings, as far as is known.
	is_ordered : (LoweringBasics.Kind, LoweringBasics.Kind) -> Bool
	is_ordered = |kinds|
		match kinds {
			(Number, Number) | (Number, Value) | (Value, Number) | (Value, Value) => True
			(String, String) | (String, Value) | (Value, String) => True
			_ => False
		}

	## The kind `+` gives: a string when either is one, a number of two, and an
	## unknown value when either is unknown. Anything else isn't compiled.
	added_kind : (LoweringBasics.Kind, LoweringBasics.Kind) -> Try(LoweringBasics.Kind, [Unadded])
	added_kind = |kinds|
		match kinds {
			(Number, Number) => Ok(Number)
			(String, other) | (other, String) if LoweringBasics.is_value_kind(other) => Ok(String)
			(Value, other) | (other, Value) if LoweringBasics.is_value_kind(other) => Ok(Value)
			# An array or an object is made a string, so `+` joins.
			(Array, other) | (other, Array) if LoweringBasics.is_value_kind(other) => Ok(String)
			(Object, other) | (other, Object) if LoweringBasics.is_value_kind(other) => Ok(String)
			# `undefined`, `null` and the booleans are made numbers.
			(one, other) if [one, other].all(LoweringBasics.is_primitive_number) => Ok(Number)
			_ => Err(Unadded)
		}

	## Whether `+` makes a kind a number: a number, `undefined`, `null` or a
	## boolean.
	is_primitive_number : LoweringBasics.Kind -> Bool
	is_primitive_number = |kind|
		match kind {
			Number | Boolean | Undefined | Null => True
			_ => False
		}

	## The statements that stop the program unless the value at `place` is a
	## number, for a kind that may not be one: the tag tested in line, no call.
	number_check_items : { kind : LoweringBasics.Kind, place : X86.Mem } -> List(Assembly.Statement)
	number_check_items = |{ kind, place }|
		LoweringBasics.unless_number_items({ kind, place, label: Runtime.not_a_number_stop })

	## The statements that jump to `label` unless the value at `place` is a
	## number, for a kind that may not be one; none for a number. They change
	## `rax` and `rcx`.
	unless_number_items : {
		kind : LoweringBasics.Kind,
		place : X86.Mem,
		label : Str,
	} -> List(Assembly.Statement)
	unless_number_items = |{ kind, place, label }|
		match kind {
			Number => []
			_ => [
				Emit.load(Rax, place),
				Emit.mov(Rcx, Rax),
				Emit.shr(Rcx, Boxing.tag_shift),
				Emit.cmp_imm(Rcx, Boxing.first_tag),
				Emit.jcc(Ae, label),
			]
		}

	## The label of a piece of the code one instruction lowers to, past its
	## own place: its slow way, where a fast way's test fails, or its end.
	inner_label : LoweringBasics.Site, Str -> Str
	inner_label = |site, piece| "${LoweringBasics.place_label(site.context, site.at)}_${piece}"

	## The flag in `al` (0 or 1) made a boolean's bits in `rax`.
	boolean_items : List(Assembly.Statement)
	boolean_items = [
		Instruction(MovzxByte({ to: Rax, from: Al })),
		Emit.imm(Rcx, Boxing.false_bits),
		Emit.plus(Rax, Rcx),
	]

	## A count and its noun, singular for one: `1 argument`, `2 arguments`.
	count_text : U64, Str -> Str
	count_text = |count, noun|
		if count == 1 {
			"1 ${noun}"
		} else {
			"${count.to_str()} ${noun}s"
		}

	## A kind's words with their article: `a number`, `an array`.
	kind_phrase : LoweringBasics.Kind -> Str
	kind_phrase = |kind| {
		noun = LoweringBasics.kind_noun(kind)
		match kind {
			Array | Numbers | Integers(_) | Object | Undefined => "an ${noun}"
			_ => "a ${noun}"
		}
	}

	## A kind's words with no article: `number`, `array`.
	kind_noun : LoweringBasics.Kind -> Str
	kind_noun = |kind|
		match kind {
			Number => "number"
			Integer(_) => "number kept as an integer"
			Boolean => "boolean"
			Undefined => "undefined"
			Null => "null"
			String => "string"
			Array => "array"
			Numbers => "array of numbers"
			Integers(_) => "array of whole numbers"
			Object => "object"
			Value => "value of a kind not known before it runs"
			Method(name) => "method `${name}`"
			Function(_) | Closure(_) => "function"
			Console => "console"
			Log => "console.log"
			ErrorClass(name) | CollectionClass(name) | TimerFunction(name) => "`${name}`"
			Static(name) => "`${name}`"
			StaticMethod({ owner, name }) => "`${owner}.${name}`"
		}

	## The statements that put an array of `count` values from the stack's
	## place `base` on, in order, in `rax`: a call's arguments, for a routine
	## that takes any count of them.
	arguments_array_items : LoweringBasics.Site,
	{
		base : U64,
		count : U64,
	} -> List(Assembly.Statement)
	arguments_array_items = |site, { base, count }| {
		var $filled = [Emit.imm(Rdi, count.to_i64_wrap()), Emit.call(Runtime.new_array)]
		for item in 0..<count {
			$filled = $filled.concat([
				Emit.load(Rcx, LoweringBasics.stack_place(site.code, base + item)),
				Emit.store(Emit.mem(Rdx, (8 * item).to_i64_wrap()), Rcx),
			])
		}
		$filled
	}
}

## The bits of -0.
negative_zero_bits : U64
negative_zero_bits = 0x8000000000000000

## The `Integer` between two bounds, or `NotInteger` when either leaves
## ±2^53.
integer_within : I64, I64 -> Try(LoweringBasics.Kind, [NotInteger])
integer_within = |low, high|
	if low < 0 - LoweringBasics.integer_limit or high > LoweringBasics.integer_limit {
		Err(NotInteger)
	} else {
		Ok(Integer({ low, high }))
	}

## The `Integer` of a product of two ranges: its bounds are the least and the
## most of the four corners' products, each first checked as a double, so the
## integers' products can't overflow 64 bits. A range that holds 0 times one
## that holds a negative may give -0, and gives `NotInteger`.
integer_product : { low : I64, high : I64 },
{ low : I64, high : I64 } -> Try(
	LoweringBasics.Kind,
	[NotInteger],
)
integer_product = |one, other| {
	holds_zero = |range| range.low <= 0 and range.high >= 0
	if (holds_zero(one) and other.low < 0) or (holds_zero(other) and one.low < 0) {
		return Err(NotInteger)
	}
	corners = [
		(one.low, other.low),
		(one.low, other.high),
		(one.high, other.low),
		(one.high, other.high),
	]
	far = 2.0 * LoweringBasics.integer_limit.to_f64()
	if corners.any(|(a, b)| a.to_f64() * b.to_f64() > far or a.to_f64() * b.to_f64() < 0 - far) {
		return Err(NotInteger)
	}
	var $low = one.low * other.low
	var $high = $low
	for (a, b) in corners {
		$low = I64.min($low, a * b)
		$high = I64.max($high, a * b)
	}
	integer_within($low, $high)
}

## The `Integer` of a remainder of two ranges. The divisor's range must hold
## no 0 (`x % 0` is NaN), and the dividend's no negative: the remainder's
## sign is the dividend's, so a negative one that divides evenly gives -0. A
## divisor's sign is dropped, as JavaScript's `n % -d` is `n % d`. The
## remainder is at most the dividend and less than the divisor's largest
## size, and a dividend below the divisor's least size is its own remainder.
integer_remainder : { low : I64, high : I64 },
{ low : I64, high : I64 } -> Try(
	LoweringBasics.Kind,
	[NotInteger],
)
integer_remainder = |dividend, divisor| {
	if dividend.low < 0 or (divisor.low <= 0 and divisor.high >= 0) {
		return Err(NotInteger)
	}
	(least, most) =
		if divisor.low > 0 {
			(divisor.low, divisor.high)
		} else {
			(0 - divisor.high, 0 - divisor.low)
		}
	if dividend.high < least {
		Ok(Integer(dividend))
	} else {
		Ok(Integer({ low: 0, high: I64.min(dividend.high, most - 1) }))
	}
}

## A range of integers, as an `Integer` holds one.
WordRange : { low : I64, high : I64 }

## Every signed 32-bit integer.
every_signed : WordRange
every_signed = { low: -2147483648, high: 2147483647 }

## Every unsigned 32-bit integer.
every_unsigned : WordRange
every_unsigned = { low: 0, high: 4294967295 }

## The signed 32-bit integers an operand of this kind is made: its own
## range when it is an `Integer` within them, else any.
signed_range : LoweringBasics.Kind -> WordRange
signed_range = |kind|
	match kind {
		Integer(range) if range.low >= every_signed.low and range.high <= every_signed.high => range
		_ => every_signed
	}

## The unsigned 32-bit integers `>>>`'s first operand of this kind is made:
## its own range when it is an `Integer` within them, else any.
unsigned_range : LoweringBasics.Kind -> WordRange
unsigned_range = |kind|
	match kind {
		Integer(range) if range.low >= 0 and range.high <= every_unsigned.high => range
		_ => every_unsigned
	}

## A shift's count, 0 to 31, when its operand is one known integer.
shift_count_of : LoweringBasics.Kind -> Try(U8, [Unknown])
shift_count_of = |kind|
	match kind {
		Integer({ low, high }) if low == high => Ok(I64.bitwise_and(low, 31).to_u8_wrap())
		_ => Err(Unknown)
	}

## `&` of two ranges: at most a side that can't be negative, whose bits the
## answer is among.
anded_range : WordRange, WordRange -> WordRange
anded_range = |one, other|
	if one.low >= 0 and other.low >= 0 {
		{ low: 0, high: I64.min(one.high, other.high) }
	} else if one.low >= 0 {
		{ low: 0, high: one.high }
	} else if other.low >= 0 {
		{ low: 0, high: other.high }
	} else {
		every_signed
	}

## `|` or `^` of two ranges: two sides that can't be negative give an answer
## among the bits of the larger one's highest.
united_range : WordRange, WordRange -> WordRange
united_range = |one, other|
	if one.low >= 0 and other.low >= 0 {
		{ low: 0, high: ones_through(I64.max(one.high, other.high)) }
	} else {
		every_signed
	}

## The least `2^k - 1` at least `most`, at least 0: every bit up to
## `most`'s highest set.
ones_through : I64 -> I64
ones_through = |most| {
	var $ones = 0
	while $ones < most {
		$ones = $ones * 2 + 1
	}
	$ones
}

## `<<` of a range by a known count: each end shifted, when both stay
## within 32 bits, signed; any other gives any.
left_shifted_range : WordRange, Try(U8, [Unknown]) -> WordRange
left_shifted_range = |range, count|
	match count {
		Ok(by) => {
			low = range.low.shl_wrap(by)
			high = range.high.shl_wrap(by)
			if low >= every_signed.low and high <= every_signed.high {
				{ low, high }
			} else {
				every_signed
			}
		}
		Err(Unknown) => every_signed
	}

## `>>` of a range: each end shifted by a known count (rounding down, as
## the arithmetic shift does); by any count, the range with 0, or -1 for one
## all below it, taken in.
right_shifted_range : WordRange, Try(U8, [Unknown]) -> WordRange
right_shifted_range = |range, count|
	match count {
		Ok(by) => { low: range.low.shr_wrap(by), high: range.high.shr_wrap(by) }
		Err(Unknown) => {
			low: I64.min(range.low, 0),
			high: if range.high >= 0 {
				range.high
			} else {
				-1
			},
		}
	}

## `>>>` of an unsigned range: each end shifted by a known count; by any
## count, from 0 to its most.
unsigned_shifted_range : WordRange, Try(U8, [Unknown]) -> WordRange
unsigned_shifted_range = |range, count|
	match count {
		Ok(by) => { low: range.low.shr_wrap(by), high: range.high.shr_wrap(by) }
		Err(Unknown) => { low: 0, high: range.high }
	}

## `dividend` over `divisor`, at least 1, rounded down.
floor_of_quotient : I64, I64 -> I64
floor_of_quotient = |dividend, divisor| {
	truncated = dividend // divisor
	if dividend < 0 and truncated * divisor != dividend {
		truncated - 1
	} else {
		truncated
	}
}

## A range's least and most, for the expects.
Bounds : (I64, I64)

## An `Integer`, or none, for the expects.
IntegerAnswer : Try(LoweringBasics.Kind, [NotInteger])

## `+`, `-` or `*` of two ranges, for the expects.
arithmetic_of_ranges : Ast.BinaryOperator -> (Bounds, Bounds -> IntegerAnswer)
arithmetic_of_ranges = |operator| |(one_low, one_high), (other_low, other_high)| {
	left = Integer({ low: one_low, high: one_high })
	right = Integer({ low: other_low, high: other_high })
	LoweringBasics.integer_arithmetic({ operator, left, right })
}

## The `Integer` between two bounds, for the expects.
between : I64, I64 -> IntegerAnswer
between = |low, high| Ok(Integer({ low, high }))

# A sum or a difference stays an `Integer` up to ±2^53 exactly, and is none
# one past it either way.
expect {
	limit = LoweringBasics.integer_limit
	sum = arithmetic_of_ranges(Add)
	difference = arithmetic_of_ranges(Subtract)
	sum((0, limit - 1), (1, 1)) == between(1, limit)
		and sum((0, limit), (1, 1)) == Err(NotInteger)
		and difference((0 - limit + 1, 0), (1, 1)) == between(0 - limit, -1)
		and difference((0 - limit, 0), (1, 1)) == Err(NotInteger)
		and difference((0, 10), (0, 4)) == between(-4, 10)
}

# A product that may be -0 (a range holding 0 times one holding a negative,
# either way round) is no `Integer`; one of factors that can't be is, with
# its corners' bounds; one past 2^53 is none.
expect {
	product = arithmetic_of_ranges(Multiply)
	product((0, 5), (-1, -1)) == Err(NotInteger)
		and product((-3, 2), (0, 0)) == Err(NotInteger)
		and product((1, 5), (-3, -1)) == between(-15, -1)
		and product((-2, 3), (2, 4)) == between(-8, 12)
		and product((0, 5), (2, 3)) == between(0, 15)
		and product((0, 94906265), (0, 94906265)) == between(0, 9007199136250225)
		and product((0, 94906267), (0, 94906267)) == Err(NotInteger)
		and product((0, 4294967296), (0, 4294967296)) == Err(NotInteger)
}

# A remainder is an `Integer` when its divisor can't be 0 and its dividend
# can't be negative, between 0 and one less than the divisor's largest size
# (or the dividend's most), a dividend below the divisor its own; one that
# may be NaN or -0 is none.
expect {
	remainder = arithmetic_of_ranges(Remainder)
	limit = LoweringBasics.integer_limit
	remainder((0, limit), (4, 4)) == between(0, 3)
		and remainder((0, 2), (4, 4)) == between(0, 2)
		and remainder((5, 9), (16, 16)) == between(5, 9)
		and remainder((0, 100), (1, 4294967297)) == between(0, 100)
		and remainder((0, limit), (-3, -3)) == between(0, 2)
		and remainder((-1, 10), (4, 4)) == Err(NotInteger)
		and remainder((0, 10), (0, 4)) == Err(NotInteger)
		and remainder((0, 10), (-2, 3)) == Err(NotInteger)
}

# `Math.floor(a / b)` is an `Integer` when `b` is at least 1, rounded down
# for a negative dividend, its bounds the corners'; a divisor that may be 0
# or negative gives none.
expect {
	quotient = |(one_low, one_high), (other_low, other_high)|
		LoweringBasics.integer_floor_quotient(
			Integer({ low: one_low, high: one_high }),
			Integer({ low: other_low, high: other_high }),
		)
	quotient((0, 199999), (16, 16)) == between(0, 12499)
		and quotient((-7, 7), (4, 4)) == between(-2, 1)
		and quotient((-7, 7), (2, 5)) == between(-4, 3)
		and quotient((-9, -5), (2, 3)) == between(-5, -2)
		and quotient((0, 10), (0, 4)) == Err(NotInteger)
		and quotient((0, 10), (-3, -1)) == Err(NotInteger)
}

# A bitwise operator's answer is a 32-bit integer whatever its operands, its
# range narrowed by theirs: `x & 255` is 0 to 255 of any `x`, `>>> 0` 0 to
# 2^32 - 1, `>> k` shrinks a range by 2^k, `|` of two that can't be negative
# fills the larger one's bits, and an operand past 32 bits narrows nothing.
expect {
	given = |(low, high)| Integer({ low, high })
	whole = |low, high| Integer({ low, high })
	ranged = |operator| |left, right|
		LoweringBasics.bitwise_kind({
			operator,
			left: given(left),
			right: given(right),
		})
	numbered = |operator| |right|
		LoweringBasics.bitwise_kind({
			operator,
			left: Number,
			right: given(right),
		})
	anded = ranged(BitAnd)
	unsigned = ranged(ShiftRightUnsigned)
	signed = ranged(ShiftRight)
	shifted = ranged(ShiftLeft)
	every = whole(-2147483648, 2147483647)
	numbered(BitAnd)((255, 255)) == whole(0, 255)
		and anded((0, 1000), (0, 15)) == whole(0, 15)
		and anded((0, 4294967295), (255, 255)) == whole(0, 255)
		and ranged(BitOr)((0, 5), (0, 9)) == whole(0, 15)
		and ranged(BitExclusiveOr)((0, 6), (1, 1)) == whole(0, 7)
		and ranged(BitOr)((-1, 5), (1, 1)) == every
		and numbered(ShiftRightUnsigned)((0, 0)) == whole(0, 4294967295)
		and numbered(ShiftRightUnsigned)((28, 28)) == whole(0, 15)
		and unsigned((0, 1000), (0, 31)) == whole(0, 1000)
		and signed((-1000, 1000), (3, 3)) == whole(-125, 125)
		and signed((-1000, 1000), (35, 35)) == whole(-125, 125)
		and signed((-9, -3), (0, 31)) == whole(-9, -1)
		and numbered(ShiftRight)((16, 16)) == whole(-32768, 32767)
		and shifted((0, 255), (8, 8)) == whole(0, 65280)
		and shifted((0, 255), (24, 24)) == every
		and shifted((0, 4294967296), (1, 1)) == every
		and LoweringBasics.bitwise_not_kind(whole(0, 255)) == whole(-256, -1)
		and LoweringBasics.bitwise_not_kind(Value) == every
}

# A literal is an `Integer` when it is whole, within ±2^53 and not -0; a
# step that would pass 2^53 gives none.
expect {
	limit = LoweringBasics.integer_limit
	literal = LoweringBasics.integer_of_literal
	literal(7.0) == between(7, 7)
		and literal(-9007199254740992.0) == between(0 - limit, 0 - limit)
		and literal(9007199254740994.0) == Err(NotInteger)
		and literal(-0.0) == Err(NotInteger)
		and literal(2.5) == Err(NotInteger)
		and LoweringBasics.integer_stepped(Integer({ low: 0, high: limit }), 1.0) == Err(NotInteger)
}
