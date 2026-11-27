## This module is js-x86's `counted` mode, an exact dynamic count of the
## instructions a compiled program runs (x86/COST.md, "The counter"). It
## takes the program's whole code, the statements Lowering and its
## post-passes made, and puts a counter at the start of each block:
## `inc qword ptr [counts_address + 8 * k]`, one instruction, `k` the
## block's place among the counters. A block starts at
##
## - the code's first statement, the executable's entry;
## - each run of labels before code (data's labels, a text's or a record's,
##   are passed by), one counter for the run, since the run is one place;
## - the statement after each conditional jump, which runs when the jump
##   falls through.
##
## Every way into code is a label a statement names (Jumps' rule), so with
## a counter at each named label and after each conditional jump, each
## block runs straight from its counter to the next, and its count times
## its instructions is exactly what it ran. x86/cost.shale reads that back
## against the uncounted executable's bytes, which are the race's.
##
## **THE FLAGS RULE.** `inc` writes the flags. A block's start where the
## flags are live (a `cmp` before the label, its `jcc` after) would read
## the counter's flags, so each start is walked forward (`flags_at`, jumps
## followed) to the first instruction that reads the flags or sets them:
## set first, the counter is the `inc` alone. A label no statement names is
## a place and not a way in, so where its flags are live it is passed by,
## its block joined to the one before. A start that is a way in with the
## flags live keeps them: `pushfq`, the `inc`, `popfq` (`kept`). These are
## the falls through a chain of jumps on one compare (`ucomisd`, `jp`,
## `jne`; `cmp`, `jb`, `ja`) and a label such a chain's first jump lands on:
## 17 of the 1,131 starts of a loop of ten trips. The design refused them;
## a refusal of 17 would leave no program counted, and the pair counts
## them exactly. The `pushfq` writes the 8 bytes below `rsp`, which no code
## here keeps anything in (the profiler's signal lands there too). A call
## is taken as setting the flags (no routine reads the flags it is called
## with), and a `ret` as setting them unless some call site reads the
## flags a routine returns with (`returns_read`), in which case a walk that
## reaches a `ret` is live.
##
## **THE COUNTS.** The executable's start opens `x86.counts` in the working
## folder, sizes it at 8 bytes a counter and maps it shared at
## `counts_address`, so the counts reach the file however the program ends:
## its exit, a stop, a throw nothing catches. That start runs before the
## runtime's own, and leaves every register it used at 0, as the kernel
## gave them. Nothing else of the runtime changes: the counted executable is
## the program's statements with the counters put in, never the race's
## build.
##
## `inc qword ptr [disp32]` has no `X86.Instruction` of its own: an
## absolute memory operand is used nowhere else, and a new instruction
## would be one more case in every pass's match, so the counter is its
## bytes, as data placed in the code (`increment`, held to objdump's
## reading by an expect).
import Assembly
import Emit
import X86

Counter :: [].{

	## Where the counts are mapped: above the profiler's counts (Profiler's
	## 0x10000000, 16 MiB) and far below the heap's mapping, which the
	## kernel places near the top of the address space. It and every
	## counter's address fit a disp32.
	counts_address : I64
	counts_address = 0x20000000

	## A block's start: `kind` is `entry`, `named` (a run of labels one of
	## which a statement names), `unnamed` or `after_jcc`; `labels` the
	## run's labels, joined with `,` (`-` for none); `flags` is `set`
	## where the counter is the `inc` alone and `kept` where the flags are
	## live and kept around it.
	Point : {
		kind : Str,
		labels : Str,
		flags : Str,
	}

	## The program's code with its counters: `counted` the statements to
	## assemble (the start that maps the counts first), `marked` the
	## statements as they were with a label at each counter (`count_<k>`)
	## and at each piece of data (`count_data_<k>`), which take no bytes, so
	## `marked`'s code is the uncounted executable's, byte for byte.
	Plan : {
		counted : List(Assembly.Statement),
		marked : List(Assembly.Statement),
		points : List(Counter.Point),
		data : U64,
		returns_read : U64,
	}

	## The counters for `statements`, a program's whole code.
	plan : List(Assembly.Statement) -> Counter.Plan
	plan = |statements| {
		places = mark_places(statements)
		named = Assembly.named_labels(statements)
		returns_read = calls_reading_flags(statements, places)
		var $counted = List.with_capacity(statements.len() + statements.len() // 2)
		var $marked = List.with_capacity(statements.len() + statements.len() // 4)
		var $points = []
		var $data = 0
		var $run = []
		var $after_jcc = False
		for at in 0..<statements.len() {
			statement = statements.get(at) ?? crash "Counter.plan: a statement"
			match statement {
				Mark(label) => {
					$run = $run.append(label)
				}
				Data(_) | Distance(_) => {
					data_mark = Mark("count_data_${$data.to_str()}")
					$counted = $counted.append(data_mark)
					$marked = $marked.append(data_mark)
					$data = $data + 1
					$run = []
					$after_jcc = False
				}
				_ => {
					start = start_of({
						marks: $run,
						after_jcc: $after_jcc,
						first: at == 0,
						named,
					})
					match start {
						Ok(point) => {
							live = match flags_at({ statements, places }, at) {
								Live => True
								AtReturn => returns_read > 0
								Dead => False
							}
							if !live or point.kind != "unnamed" {
								counter = Mark("count_${$points.len().to_str()}")
								$counted = $counted.append(counter).concat(
									counter_items($points.len(), live),
								)
								$marked = $marked.append(counter)
								$points = $points.append({
									..point,
									flags: if live {
										"kept"
									} else {
										"set"
									},
								})
							}
						}
						Err(NoStart) => {}
					}
					$run = []
					$after_jcc = match statement {
						JccTo(_) => True
						_ => False
					}
				}
			}
			$counted = $counted.append(statement)
			$marked = $marked.append(statement)
		}
		{
			counted: start_items($points.len()).concat($counted).concat(text_items),
			marked: $marked,
			points: $points,
			data: $data,
			returns_read,
		}
	}

	## The plan's map, for x86/cost.shale: a line `points <n> kept <n>
	## returns_read <n>`, then `point <k> <offset> <kind> <labels> <flags>`
	## for each counter and `data <offset>` for each piece of data, every
	## offset in the uncounted code (`marked`'s), from its start.
	map_text : Counter.Plan -> Try(Str, Str)
	map_text = |counters| {
		laid = match Assembly.laid_out(counters.marked) {
			Ok(it) => it
			Err(_) => return Err("the code does not assemble")
		}
		offset = |label|
			laid.marks.get(label) ?? crash "Counter.map_text: a counter's label is marked"
		points = counters.points.len().to_str()
		kept = counters.points.keep_if(|point| point.flags == "kept").len().to_str()
		var $text = "points ${points} kept ${kept} returns_read ${counters.returns_read.to_str()}\n"
		for k in 0..<counters.points.len() {
			point = counters.points.get(k) ?? crash "Counter.map_text: a point"
			at = offset("count_${k.to_str()}").to_str()
			what = "${point.kind} ${point.labels} ${point.flags}"
			$text = $text.concat("point ${k.to_str()} ${at} ${what}\n")
		}
		for k in 0..<counters.data {
			at = offset("count_data_${k.to_str()}").to_str()
			$text = $text.concat("data ${at}\n")
		}
		Ok($text)
	}

	## The counter `k`: `inc qword ptr [counts_address + 8 * k]`, REX.W,
	## `FF /0`, a ModRM of a SIB with no base and no index, then the
	## absolute disp32.
	increment : U64 -> Assembly.Statement
	increment = |index| Data(
		X86.append_little_endian(
			[0x48, 0xFF, 0x04, 0x25],
			{ value: counts_address + 8 * index.to_i64_wrap(), size: 4 },
		),
	)
}

## The counter `k`, the flags kept around it (`pushfq` and `popfq`) when
## they are live.
counter_items : U64, Bool -> List(Assembly.Statement)
counter_items = |index, live|
	if live {
		[
			Data([0x9C]),
			Counter.increment(index),
			Data([0x9D]),
		]
	} else {
		[Counter.increment(index)]
	}

## Each label's statement's place.
mark_places : List(Assembly.Statement) -> Dict(Str, U64)
mark_places = |statements| {
	var $places = Dict.empty()
	for at in 0..<statements.len() {
		match statements.get(at) {
			Ok(Mark(label)) => {
				$places = $places.insert(label, at)
			}
			_ => {}
		}
	}
	$places
}

## The block that starts at a statement of code, if one does: after a run
## of labels, after a conditional jump, or at the code's first statement.
start_of : {
	marks : List(Str),
	after_jcc : Bool,
	first : Bool,
	named : Set(Str),
} -> Try(Counter.Point, [NoStart])
start_of = |{ marks, after_jcc, first, named }| {
	labels = Str.join_with(marks, ",")
	if !marks.is_empty() {
		var $kind = "unnamed"
		for label in marks {
			if named.contains(label) {
				$kind = "named"
			}
		}
		Ok({
			kind: if first or after_jcc {
				"named"
			} else {
				$kind
			},
			labels,
			flags: "set",
		})
	} else if after_jcc {
		Ok({
			kind: "after_jcc",
			labels: "-",
			flags: "set",
		})
	} else if first {
		Ok({
			kind: "entry",
			labels: "-",
			flags: "set",
		})
	} else {
		Err(NoStart)
	}
}

## How many call sites read the flags a routine returns with: the walk
## from the statement after each call.
calls_reading_flags : List(Assembly.Statement), Dict(Str, U64) -> U64
calls_reading_flags = |statements, places| {
	var $count = 0
	for at in 0..<statements.len() {
		call = match statements.get(at) {
			Ok(CallTo(_)) | Ok(Instruction(CallReg(_))) | Ok(Instruction(Call(_))) => True
			_ => False
		}
		if call {
			match flags_at({ statements, places }, at + 1) {
				Live => {
					$count = $count + 1
				}
				_ => {}
			}
		}
	}
	$count
}

## The most statements a walk of the flags takes before it calls them
## live.
most_steps : U64
most_steps = 4096

## Whether the flags are live at the statement at `start`: the walk
## forward, through labels and unconditional jumps, to the first statement
## that reads them (`Live`) or sets them (`Dead`), or to a `ret`
## (`AtReturn`). Data, the code's end, a call and a jump to no label of
## these statements end the walk as setting them, but for a jump whose
## target is unknown (an `X86.Jmp`'s offset), which is live.
flags_at : {
	statements : List(Assembly.Statement),
	places : Dict(Str, U64),
},
U64 -> [Live, Dead, AtReturn]
flags_at = |{ statements, places }, start| {
	var $at = start
	var $steps = 0
	while $steps < most_steps {
		$steps = $steps + 1
		match statements.get($at) {
			Err(_) => return Dead
			Ok(Mark(_)) | Ok(LeaTo(_)) => {
				$at = $at + 1
			}
			Ok(JccTo(_)) => return Live
			Ok(CallTo(_)) | Ok(Data(_)) | Ok(Distance(_)) => return Dead
			Ok(JmpTo(label)) => {
				match places.get(label) {
					Ok(place) => {
						$at = place
					}
					Err(_) => return Dead
				}
			}
			Ok(Instruction(instruction)) => {
				match flags_use(instruction) {
					Reads => return Live
					Sets => return Dead
					Returns => return AtReturn
					Keeps => {
						$at = $at + 1
					}
				}
			}
		}
	}
	Live
}

## What an instruction does with the flags. A shift by a count of 0 (mod
## 64) leaves them, and so may one by `cl`; `div` and `idiv` leave them
## undefined, which no code reads; a call is taken as setting them (above).
flags_use : X86.Instruction -> [Reads, Sets, Returns, Keeps]
flags_use = |instruction|
	match instruction {
		Jcc(_) | Setcc(_) | Cmov(_) | Jmp(_) => Reads
		Alu(_) | AluImm(_) | Imul(_) | Bsr(_) | ImulWide(_) => Sets
		Div(_) | Idiv(_) | Div32(_) | Neg(_) | Test(_) | Ucomisd(_) => Sets
		Call(_) | CallReg(_) => Sets
		Shift({ operation: _, reg: _, count }) =>
			if count.bitwise_and(63) == 0 {
				Keeps
			} else {
				Sets
			}
		Ret => Returns
		_ => Keeps
	}

## The start's part: `x86.counts` opened in the working folder, sized at 8
## bytes a counter and mapped shared at `counts_address`; a line on stderr
## and exit 1 when that fails. Every register it uses is left at 0.
start_items : U64 -> List(Assembly.Statement)
start_items = |counters| {
	kept = if counters == 0 {
		1
	} else {
		counters
	}
	size = 8 * kept.to_i64_wrap()
	[
		# open("x86.counts", O_RDWR | O_CREAT | O_TRUNC, 0644)
		Emit.imm(Rax, 2),
		Emit.address_of(Rdi, "count_path"),
		Emit.imm(Rsi, 0x242),
		Emit.imm(Rdx, 420),
		Emit.syscall,
		Emit.test(Rax, Rax),
		Emit.jcc(S, "count_failed"),
		Emit.mov(R8, Rax),
		# ftruncate(fd, size): the counts, zero.
		Emit.imm(Rax, 77),
		Emit.mov(Rdi, R8),
		Emit.imm(Rsi, size),
		Emit.syscall,
		Emit.test(Rax, Rax),
		Emit.jcc(S, "count_failed"),
		# mmap(counts_address, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0)
		Emit.imm(Rax, 9),
		Emit.imm(Rdi, Counter.counts_address),
		Emit.imm(Rsi, size),
		Emit.imm(Rdx, 3),
		Emit.imm(R10, 0x11),
		Emit.zero(R9),
		Emit.syscall,
		Emit.test(Rax, Rax),
		Emit.jcc(S, "count_failed"),
		# close(fd): the mapping stays.
		Emit.imm(Rax, 3),
		Emit.mov(Rdi, R8),
		Emit.syscall,
	]
		.concat([Rax, Rcx, Rdx, Rsi, Rdi, R8, R9, R10, R11].map(|reg| Emit.zero(reg)))
		.concat([
			Emit.jmp("count_started"),
			Emit.mark("count_failed"),
			# write(2, the line, its length), then exit_group(1)
			Emit.imm(Rax, 1),
			Emit.imm(Rdi, 2),
			Emit.address_of(Rsi, "count_failure"),
			Emit.imm(Rdx, failure_text.count_utf8_bytes().to_i64_wrap()),
			Emit.syscall,
			Emit.imm(Rax, 231),
			Emit.imm(Rdi, 1),
			Emit.syscall,
			Emit.mark("count_started"),
		])
}

failure_text : Str
failure_text = "x86: counted: x86.counts could not be opened and mapped in the working folder\n"

## The start's texts, after the program's code.
text_items : List(Assembly.Statement)
text_items = [
	Mark("count_path"),
	Data("x86.counts".to_utf8().append(0)),
	Mark("count_failure"),
	Data(failure_text.to_utf8()),
]

# The counter's bytes, as objdump reads them back:
# `inc QWORD PTR ds:0x20000018`.
expect {
	bytes = Assembly.assemble([Counter.increment(3)]).map_ok(X86.hex_text)
	bytes == Ok("48 ff 04 25 18 00 00 20")
}

# A label a jump reaches gets a counter; a label nobody names between a
# compare and its jump is passed by; the fall through after a jump gets
# its own.
expect {
	counters = Counter.plan([
		Mark("top"),
		Instruction(
			AluImm({
				operation: Cmp,
				to: Rax,
				value: 1,
			}),
		),
		Mark("place"),
		JccTo({ condition: E, label: "out" }),
		Instruction(
			AluImm({
				operation: Add,
				to: Rax,
				value: 1,
			}),
		),
		JmpTo("top"),
		Mark("out"),
		Instruction(Ret),
	])
	counters.points.map(|point| point.kind) == ["named", "after_jcc", "named"]
		and counters.points.map(|point| point.flags) == ["set", "set", "set"]
}

# A label a jump reaches where the flags are live, and a fall through to a
# jump on the same flags, keep the flags around their counters.
expect {
	counters = Counter.plan([
		Instruction(
			AluImm({
				operation: Cmp,
				to: Rax,
				value: 1,
			}),
		),
		Mark("there"),
		JccTo({ condition: E, label: "out" }),
		JmpTo("there"),
		Mark("out"),
		Instruction(Ret),
	])
	counters.points.map(|point| point.flags) == ["set", "kept", "kept", "set"]
}
