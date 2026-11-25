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
import js.Bytecode
import Assembly
import Boxing
import Emit
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
		Boolean,
		Undefined,
		Null,
		String,
		Array,
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
		form : [Ordinary, MakesInstances],
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
		returns : Dict(U64, LoweringBasics.Kind),
		parameters : Dict(U64, List(LoweringBasics.Kind)),
		literals : Dict(Str, U64),
		index : U64,
	}

	## A call of a function by its code, with its arguments' kinds.
	CallKinds : { code : U64, kinds : List(LoweringBasics.Kind) }

	## Whether a kind is a value's, with boxed bits.
	is_value_kind : LoweringBasics.Kind -> Bool
	is_value_kind = |kind|
		match kind {
			Number | Boolean | Undefined | Null => True
			String | Array | Object | Value | Closure(_) => True
			Function(_) | Console | Log | Method(_) => False
			ErrorClass(_) | CollectionClass(_) | TimerFunction(_) => False
			Static(_) | StaticMethod(_) => False
		}

	## The kind two ways give a place: their own when they agree, `Value` when
	## both are values, and none for anything else.
	met_kind : LoweringBasics.Kind, LoweringBasics.Kind -> Try(LoweringBasics.Kind, [Apart])
	met_kind = |one, other|
		if one == other {
			Ok(one)
		} else if LoweringBasics.is_value_kind(one) and LoweringBasics.is_value_kind(other) {
			Ok(Value)
		} else {
			Err(Apart)
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
		if !LoweringBasics.is_value_kind(given) {
			return LoweringBasics.refusal(
				site,
				"a variable is given a function, `console` or a method",
			)
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

	## Whether a kind may be a number: arithmetic on it is checked or free.
	is_numeric : LoweringBasics.Kind -> Bool
	is_numeric = |kind|
		match kind {
			Number | Value => True
			_ => False
		}

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
	## number, for a kind that may not be one.
	number_check_items : { kind : LoweringBasics.Kind, place : X86.Mem } -> List(Assembly.Statement)
	number_check_items = |{ kind, place }|
		match kind {
			Number => []
			_ => [Emit.load(Rax, place), Emit.call(Runtime.check_number)]
		}

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
	kind_phrase = |kind|
		match kind {
			Array | Object | Undefined => "an ${LoweringBasics.kind_noun(kind)}"
			_ => "a ${LoweringBasics.kind_noun(kind)}"
		}

	## A kind's words with no article: `number`, `array`.
	kind_noun : LoweringBasics.Kind -> Str
	kind_noun = |kind|
		match kind {
			Number => "number"
			Boolean => "boolean"
			Undefined => "undefined"
			Null => "null"
			String => "string"
			Array => "array"
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
