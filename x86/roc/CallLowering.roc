## This module lowers JavaScript's calls and what makes a closure's
## pieces: a call of a function known by its code, directly, or of any
## other value, through it (`call_items`); a closure record made as the
## program runs (`record_items`); a captured variable's cell loaded, stored
## and stepped (`boxed_load_items`, `boxed_store_items`,
## `cell_update_items`); the spreads and rests (`spread_items`); and a
## `try`'s handler pushed (`try_items`).
##
## It stands apart from Lowering because calls and closures are a family
## read whole beside the runtime routines they call, and none of them needs
## the walk: Lowering's dispatch hands each its site and state, and takes
## back what it lowered.
import js.Bytecode
import Assembly
import Boxing
import BuiltinLowering
import Emit
import LoweringBasics
import Runtime
import X86

CallLowering :: [].{

	## A call: of a function known by its code, directly, `rbx` holding its
	## closure record when it has one; of any other value, through it.
	call_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		count : U64,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	call_items = |site, { state, count }| {
		callee_place = LoweringBasics.stack_place(site.code, state.stack_kinds.len() - count - 1)
		match LoweringBasics.kind_below(state, count) {
			Function(made) => direct_call_items(site, { state, count, made, record_statements: [] })
			Closure(made) => {
				codes = site.context.program.codes
				callee = codes.get(made) ?? crash "CallLowering.call_items: a function's code"
				takes_count = match callee.arguments {
					Each(parameters) => parameters == count
					Packed(_) => True
				}
				if takes_count {
					record_statements = [
						Emit.load(Rbx, callee_place),
						Emit.shl(Rbx, 16),
						Emit.shr(Rbx, 16),
					]
					direct_call_items(site, { state, count, made, record_statements })
				} else {
					value_call_items(site, { state, count, taken: count + 1 })
				}
			}
			Value => value_call_items(site, { state, count, taken: count + 1 })
			TimerFunction(name) => BuiltinLowering.timer_items(site, { state, count, name })
			# node's TypeError for `Map()` or `Set()` without `new`.
			CollectionClass(name) =>
				Ok({
					statements: [
						Emit.address_of(Rsi, Runtime.new_required_text(name)),
						Emit.address_of(Rdi, Runtime.error_name_label("TypeError")),
						Emit.call(Runtime.new_error),
						Emit.jmp(Runtime.throw),
					],
					falls: Ends,
					branch: NoBranch,
					result: GivesNothing,
				})
			Static("String") => {
				made =
					if count == 0 {
						[
							Emit.address_of(Rax, "runtime_text_empty"),
							Emit.imm(Rcx, Boxing.tag_bits(Boxing.string_tag)),
							Emit.plus(Rax, Rcx),
						]
					} else if LoweringBasics.is_value_kind(
						LoweringBasics.kind_below(state, count - 1),
					) {
						argument = LoweringBasics.stack_place(
							site.code,
							state.stack_kinds.len() - count,
						)
						[Emit.load(Rdi, argument), Emit.call(Runtime.text_of_boxed)]
					} else {
						phrase = LoweringBasics.kind_phrase(
							LoweringBasics.kind_below(state, count - 1),
						)
						return LoweringBasics.refusal(site, "`String` of ${phrase}")
					}
				Ok(
					LoweringBasics.falling(
						made.append(Emit.store(callee_place, Rax)),
						LoweringBasics.with_top(
							LoweringBasics.without_top(state, count + 1),
							String,
						),
					),
				)
			}
			kind => LoweringBasics.refusal(site, "a call of ${LoweringBasics.kind_phrase(kind)}")
		}
	}

	## A direct call of the function `made`: its arguments pushed, the last
	## first, the call, and its result in the callee's place.
	direct_call_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		count : U64,
		made : U64,
		record_statements : List(Assembly.Statement),
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	direct_call_items = |site, { state, count, made, record_statements }| {
		callee = match site.context.program.codes.get(made) {
			Ok(code) => code
			Err(_) => crash "CallLowering.direct_call_items: a function's code"
		}
		counted = match callee.arguments {
			Each(parameters) =>
				if parameters != count {
					given = LoweringBasics.count_text(count, "argument")
					taken = LoweringBasics.count_text(parameters, "parameter")
					return LoweringBasics.refusal(site, "a call with ${given} to ${taken}")
				} else {
					[]
				}
			Packed(_) => [Emit.imm(Rcx, count.to_i64_wrap())]
		}
		base = state.stack_kinds.len() - count - 1
		pushed = arguments_pushed(site, { state, count })?
		call = CallTo(LoweringBasics.code_label(made))
		var $items = record_statements.concat(pushed).concat(counted).append(call)
		if count > 0 {
			$items = $items.append(Emit.plus_imm(Rsp, (8 * count).to_i64_wrap()))
		}
		result = site.context.returns.get(made) ?? crash "CallLowering.direct_call_items: a result"
		Ok(
			LoweringBasics.falling(
				$items.append(
					Instruction(
						MovMemReg({ to: LoweringBasics.stack_place(site.code, base), from: Rax }),
					),
				),
				LoweringBasics.with_top(LoweringBasics.without_top(state, count + 1), result),
			),
		)
	}

	## The `count` arguments on top of the stack pushed, the last first, an
	## `Integer` as it is (`LoweringBasics.is_argument_kind`).
	arguments_pushed : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		count : U64,
	} -> Try(List(Assembly.Statement), [Refused(Str)])
	arguments_pushed = |site, { state, count }| {
		base = state.stack_kinds.len() - count
		var $items = []
		for back in 0..<count {
			argument = count - 1 - back
			if !LoweringBasics.is_argument_kind(LoweringBasics.kind_below(state, back)) {
				return LoweringBasics.refusal(
					site,
					"a call with a function, `console` or a method as an argument",
				)
			}
			$items = $items.concat([
				Emit.load(Rax, LoweringBasics.stack_place(site.code, base + argument)),
				Emit.save(Rax),
			])
		}
		Ok($items)
	}

	## A call through the value below the `count` arguments on top of the
	## stack: stopped unless it is a function, else its record in `rbx`, the
	## arguments pushed, their count in `rcx`, and a call of its value entry.
	## The result, a `Value`, takes the place of the `taken` values on top (the
	## callee and the arguments, and a method call's receiver).
	value_call_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		count : U64,
		taken : U64,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	value_call_items = |site, { state, count, taken }| {
		depth = state.stack_kinds.len()
		pushed = arguments_pushed(site, { state, count })?
		var $items = [
			Emit.load(Rax, LoweringBasics.stack_place(site.code, depth - count - 1)),
			Emit.call(Runtime.check_function),
			Emit.shl(Rax, 16),
			Emit.shr(Rax, 16),
			Emit.mov(Rbx, Rax),
		]
			.concat(pushed)
			.concat([
				Emit.load(Rax, Emit.mem(Rbx, 0)),
				Emit.plus(Rax, Rbx),
				Emit.imm(Rcx, count.to_i64_wrap()),
				# A method's receiver, or `undefined` (Lowering's `entry_items`).
				if taken == count + 2 {
					Emit.load(Rdx, LoweringBasics.stack_place(site.code, depth - count - 2))
				} else {
					Emit.imm(Rdx, Boxing.undefined_bits)
				},
				Instruction(CallReg(Rax)),
			])
		if count > 0 {
			$items = $items.append(Emit.plus_imm(Rsp, (8 * count).to_i64_wrap()))
		}
		result_place = LoweringBasics.stack_place(site.code, depth - taken)
		Ok(
			LoweringBasics.falling(
				$items.append(Emit.store(result_place, Rax)),
				LoweringBasics.with_top(LoweringBasics.without_top(state, taken), Value),
			),
		)
	}

	## A closure made as the program runs: its record taken from the heap, the
	## distances to its value entry and its text, and the address of each cell
	## it captures (0 for a function known before the program runs), boxed at
	## `place`.
	record_items : LoweringBasics.Site,
	{
		made : U64,
		captures : List(U64),
		place : X86.Mem,
	} -> List(Assembly.Statement)
	record_items = |site, { made, captures, place }| {
		count = captures.len()
		var $items = [
			Emit.imm(Rdi, (24 + 8 * count).to_i64_wrap()),
			Emit.call(Runtime.allocate),
			Emit.address_of(Rcx, LoweringBasics.value_label(made)),
			Emit.minus(Rcx, Rax),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			Emit.address_of(Rcx, LoweringBasics.function_text_label(made)),
			Emit.minus(Rcx, Rax),
			Emit.minus_imm(Rcx, 8),
			Emit.store(Emit.mem(Rax, 8), Rcx),
			Emit.imm(Rcx, count.to_i64_wrap()),
			Emit.store(Emit.mem(Rax, 16), Rcx),
		]
		for (capture, from) in captures.map_with_index(|from, capture| (capture, from)) {
			held =
				if site.context.cells.contains(from) {
					Emit.load(Rcx, LoweringBasics.slot_place(from))
				} else {
					Emit.zero(Rcx)
				}
			field = Emit.mem(Rax, (24 + 8 * capture).to_i64_wrap())
			$items = $items.concat([held, Emit.store(field, Rcx)])
		}
		$items.concat([
			Emit.imm(Rcx, Boxing.tag_bits(Boxing.function_tag)),
			Emit.plus(Rax, Rcx),
			Emit.store(place, Rax),
		])
	}

	## A cell's value pushed, or a plain slot's.
	boxed_load_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
	} -> List(Assembly.Statement)
	boxed_load_items = |site, { state, slot }|
		if site.context.cells.contains(slot) {
			[
				Emit.load(Rax, LoweringBasics.slot_place(slot)),
				Emit.load(Rax, Emit.mem(Rax, 0)),
				Emit.store(LoweringBasics.stack_place(site.code, state.stack_kinds.len()), Rax),
			]
		} else {
			LoweringBasics.load_items(site, { state, slot })
		}

	## The value on top of the stack stored in a cell, or in a plain slot.
	boxed_store_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
	} -> List(Assembly.Statement)
	boxed_store_items = |site, { state, slot }|
		if site.context.cells.contains(slot) {
			[
				Emit.load(Rcx, LoweringBasics.slot_place(slot)),
				Emit.load(Rax, LoweringBasics.stack_place(site.code, state.stack_kinds.len() - 1)),
				Emit.store(Emit.mem(Rcx, 0), Rax),
			]
		} else {
			LoweringBasics.store_items(site, { state, slot })
		}

	## `++` or `--` of a cell's value, checked a number: the cell stepped, and
	## the old value (postfix) or the new (prefix) pushed.
	cell_update_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		slot : U64,
		step : Bytecode.Update,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	cell_update_items = |site, { state, slot, step }| {
		_ = LoweringBasics.slot_kind(site, { state, slot, name: "a variable" })?
		top = LoweringBasics.stack_place(site.code, state.stack_kinds.len())
		old = [
			Emit.load(Rax, LoweringBasics.slot_place(slot)),
			Emit.load(Rax, Emit.mem(Rax, 0)),
			Emit.call(Runtime.check_number),
		]
		stepped = [
			Emit.to_xmm(Xmm0, Rax),
			Emit.imm(Rax, step.delta.to_bits().to_i64_wrap()),
			Emit.to_xmm(Xmm1, Rax),
			Instruction(
				Sse({
					operation: Addsd,
					to: Xmm0,
					from: Xmm1,
				}),
			),
			Emit.load(Rcx, LoweringBasics.slot_place(slot)),
			Instruction(MovsdStore({ to: Emit.mem(Rcx, 0), from: Xmm0 })),
		]
		items = match step.fixity {
			Postfix => old.append(Emit.store(top, Rax)).concat(stepped)
			Prefix => old.concat(stepped).append(Instruction(MovsdStore({ to: top, from: Xmm0 })))
		}
		Ok(LoweringBasics.falling(items, LoweringBasics.with_top(state, Number)))
	}

	## The instructions of spreads and rests: an array literal's items and
	## spreads appended (`[...xs, 1]`), a call's arguments spread (`f(...xs)`,
	## `console.log(...xs)`, `Math.max(...xs)`), an object's properties spread
	## (`{ ...o }`), and an object pattern's rest.
	spread_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		instruction : Bytecode.Op,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	spread_items = |site, { state, instruction }| {
		depth = state.stack_kinds.len()
		top_place = |down| LoweringBasics.stack_place(site.code, depth - 1 - down)
		top_kind = LoweringBasics.kind_below(state, 0)
		if !LoweringBasics.is_value_kind(top_kind) {
			return LoweringBasics.refusal(
				site,
				"a spread or a rest of ${LoweringBasics.kind_phrase(top_kind)}",
			)
		}
		unboxed = |reg| [Emit.shl(reg, 16), Emit.shr(reg, 16)]
		match instruction {
			AppendItem =>
				Ok(
					LoweringBasics.falling(
						[Emit.load(Rdi, top_place(1))]
							.concat(unboxed(Rdi))
							.concat([Emit.load(Rsi, top_place(0)), Emit.call("runtime_push_item")]),
						LoweringBasics.without_top(state, 1),
					),
				)
			AppendSpread(_) =>
				Ok(
					LoweringBasics.falling(
						[
							Emit.load(Rdi, top_place(0)),
							Emit.call(Runtime.items_of),
							Emit.mov(Rsi, Rax),
							Emit.load(Rdi, top_place(1)),
						]
							.concat(unboxed(Rdi))
							.append(Emit.call(Runtime.concat_item)),
						LoweringBasics.without_top(state, 1),
					),
				)
			SpreadFields(_) =>
				Ok(
					LoweringBasics.falling(
						[
							Emit.load(Rdi, top_place(1)),
							Emit.load(Rsi, top_place(0)),
							Emit.call(Runtime.spread_fields),
						],
						LoweringBasics.without_top(state, 1),
					),
				)
			PropertiesLeft({ keys, at: _ }) => {
				var $listed = [
					Emit.imm(Rdi, keys.len().to_i64_wrap()),
					Emit.call(Runtime.new_array),
				]
				for (at, key) in keys.map_with_index(|key, at| (at, key)) {
					$listed = $listed.concat([
						Emit.address_of(Rcx, LoweringBasics.text_label(site, key)),
						Emit.imm(R8, Boxing.tag_bits(Boxing.string_tag)),
						Emit.plus(Rcx, R8),
						Emit.store(Emit.mem(Rdx, (8 * at).to_i64_wrap()), Rcx),
					])
				}
				called = [
					Emit.mov(Rsi, Rax),
					Emit.load(Rdi, top_place(0)),
					Emit.call(Runtime.properties_left),
					Emit.store(top_place(0), Rax),
				]
				Ok(
					LoweringBasics.falling(
						$listed.concat(called),
						LoweringBasics.with_top(LoweringBasics.without_top(state, 1), Object),
					),
				)
			}
			CallSpread(_) =>
				match LoweringBasics.kind_below(state, 1) {
					Closure(_) | Value =>
						Ok(
							LoweringBasics.falling(
								[
									Emit.load(Rdi, top_place(1)),
									Emit.load(Rsi, top_place(0)),
									Emit.imm(Rdx, Boxing.undefined_bits),
									Emit.call(Runtime.call_spread),
									Emit.store(top_place(1), Rax),
								],
								LoweringBasics.with_top(
									LoweringBasics.without_top(state, 2),
									Value,
								),
							),
						)
					kind => LoweringBasics.refusal(
						site,
						"a call with a spread of ${LoweringBasics.kind_phrase(kind)}",
					)
				}
			CallMethodSpread(_) => {
				receiver = top_place(2)
				after = |kind| LoweringBasics.with_top(LoweringBasics.without_top(state, 3), kind)
				match LoweringBasics.kind_below(state, 1) {
					Log =>
						Ok(
							LoweringBasics.falling(
								[Emit.load(Rdi, top_place(0)), Emit.call(Runtime.log_spread)],
								after(Undefined),
							),
						)
					StaticMethod({ owner: "Math", name }) if name == "max" or name == "min" => {
						extreme = if name == "max" {
							0
						} else {
							1
						}
						called = [
							Emit.load(Rdi, top_place(0)),
							Emit.imm(Rsi, extreme),
							Emit.call(Runtime.extreme_of),
							Emit.store(receiver, Rax),
						]
						Ok(LoweringBasics.falling(called, after(Number)))
					}
					Value =>
						Ok(
							LoweringBasics.falling(
								[
									Emit.load(Rdi, top_place(1)),
									Emit.load(Rsi, top_place(0)),
									Emit.load(Rdx, receiver),
									Emit.call(Runtime.call_spread),
									Emit.store(receiver, Rax),
								],
								after(Value),
							),
						)
					kind => LoweringBasics.refusal(
						site,
						"a method call with a spread of ${LoweringBasics.kind_phrase(kind)}",
					)
				}
			}
			_ => crash "CallLowering.spread_items: a spread's or a rest's instruction"
		}
	}

	## A `try`'s handler pushed: its record on the machine's stack (the code
	## a throw enters, the frame's `rbp`, the handler before it), the innermost
	## handler made it. The code a throw enters puts the value thrown where the
	## stack's top was, with a `finally`'s line and column under it (0 and 0,
	## which only node's report of an uncaught throw would read), and jumps to
	## the handler's instruction. A throw may come from anywhere in the `try`,
	## after its variables took other kinds, so there each holds a `Value`.
	try_items : LoweringBasics.Site,
	{
		state : LoweringBasics.State,
		skip : U64,
		handling : Bytecode.Handling,
	} -> Try(LoweringBasics.Lowered, [Refused(Str)])
	try_items = |site, { state, skip, handling }| {
		target = LoweringBasics.forward(site, skip)
		depth = state.stack_kinds.len()
		landing = "${LoweringBasics.place_label(site.context, site.at)}_thrown"
		after = "${LoweringBasics.place_label(site.context, site.at)}_tried"
		widened = {
			..state,
			slots: state.slots.map(
				|slot|
					match slot {
						Ready(kind) if LoweringBasics.is_value_kind(kind) => Ready(Value)
						# A throw may come after its declaration ran.
						Unready => Unsure
						_ => slot
					},
			),
		}
		(placed, sent) = match handling {
			Catching => (
				[Emit.store(LoweringBasics.stack_place(site.code, depth), Rax)],
				LoweringBasics.with_top(widened, Value),
			)
			Finishing => (
				[
					Emit.zero(Rcx),
					Emit.store(LoweringBasics.stack_place(site.code, depth), Rcx),
					Emit.store(LoweringBasics.stack_place(site.code, depth + 1), Rcx),
					Emit.store(LoweringBasics.stack_place(site.code, depth + 2), Rax),
				],
				LoweringBasics.with_top(
					LoweringBasics.with_top(LoweringBasics.with_top(widened, Number), Number),
					Value,
				),
			)
		}
		statements = [
			Emit.address_of(Rax, landing),
			Emit.save(Rax),
			Emit.save(Rbp),
			Emit.load(Rcx, Runtime.handler_place),
			Emit.save(Rcx),
			Emit.store(Runtime.handler_place, Rsp),
			Emit.jmp(after),
			Emit.mark(landing),
		]
			.concat(placed)
			.concat([Emit.jmp(LoweringBasics.place_label(site.context, target)), Emit.mark(after)])
		Ok({
			statements,
			falls: Falls(state),
			branch: Branch({ target, state: sent }),
			result: GivesNothing,
		})
	}
}
