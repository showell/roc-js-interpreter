## This module takes out the jumps the lowered code doesn't need. A test's
## slow way is lowered where the test is, so an item read of an array of
## numbers is the test's `jae slow`, the fast way's load and its `jmp done`
## over the slow way, `slow: jmp stop`, then `done:`: the fast way, the usual
## one, takes a jump at every access. `thread_jumps` walks the whole program,
## the runtime's routines too (whose rounds RuntimePosts runs once, when
## js-x86 is built, and stands beside a program's as these rounds would),
## and does three things until none changes it:
##
## - **A jump to a jump goes to its target** (`thread_each_jump`): a jump,
##   or a conditional jump, to a label whose first instruction is a jump goes
##   where that jump goes, so `jae slow` is `jae stop`.
## - **Code no way reaches is taken out** (`unreached_dropped`): what
##   follows a jump or a `ret`, up to the next label a statement names.
## - **A jump to the place just after it is taken out**
##   (`next_jumps_dropped`): `jmp done` right before `done:`.
##
## **THE RULE, KEPT CONSERVATIVE.** A label is reached only by the
## statements that name it (a jump, a call, a `lea` of it, a distance to
## it), as Forwarding and Moves hold it, so a label nothing names, and what
## follows a jump or a `ret` up to a label something names, is reached by
## no way. Data stays wherever it is, since only a label before it is a
## way to it. A jump is followed only to an unconditional jump to a label
## (`JmpTo`), never into a cycle of them, and nothing else changes: no
## instruction other than a jump is taken out or moved.
import Assembly

Jumps :: [].{

	## The statements with each jump to a jump made a jump to its target,
	## each statement no way reaches and each jump to just after it taken out.
	thread_jumps : List(Assembly.Statement) -> List(Assembly.Statement)
	thread_jumps = |statements| Jumps.thread_jumps_beside(statements, alone).threaded

	## `thread_jumps` of statements that run beside others it doesn't see
	## (RuntimePosts): `beside.named` are labels to take as named whatever
	## these statements name, and `beside.hops` the others' labels whose
	## first instruction is a jump, by their targets. It says how many
	## rounds it ran and whether the last changed nothing (`settled`; at most
	## 8 rounds run, as `thread_jumps` runs).
	thread_jumps_beside : List(Assembly.Statement), Jumps.Beside -> { threaded : List(Assembly.Statement), rounds : U64, settled : Bool }
	thread_jumps_beside = |statements, beside| {
		var $now = statements
		for round in 0..<most_rounds {
			once = Jumps.round_beside($now, beside).after
			if once.len() == $now.len() {
				return { threaded: once, rounds: round + 1, settled: True }
			}
			$now = once
		}
		{ threaded: $now, rounds: most_rounds, settled: False }
	}

	## One round of `thread_jumps_beside`: the statements after it, and the
	## labels named once its threading was done, before anything was taken
	## out.
	round_beside : List(Assembly.Statement), Jumps.Beside -> { after : List(Assembly.Statement), threaded_named : Set(Str) }
	round_beside = |statements, beside| {
		threaded = Jumps.round_threaded(statements, beside.hops)
		named = Assembly.named_labels(threaded)
		{ after: Jumps.round_dropped(threaded, { named, beside: beside.named }), threaded_named: named }
	}

	## A round's threading: each jump to a jump made a jump to its target,
	## the hops of the labels beside taken too.
	round_threaded : List(Assembly.Statement), Dict(Str, Str) -> List(Assembly.Statement)
	round_threaded = |statements, hops| thread_each_jump(statements, hops)

	## A round's taking out, after its threading: what no way reaches (a
	## label in `named` or `beside` taken as named), then each jump to just
	## after it.
	round_dropped : List(Assembly.Statement), { named : Set(Str), beside : Set(Str) } -> List(Assembly.Statement)
	round_dropped = |threaded, names| next_jumps_dropped(unreached_dropped(threaded, names))

	## The most rounds `thread_jumps` runs.
	most_rounds : U64
	most_rounds = 8

	## What `thread_jumps_beside` takes of the labels beside.
	Beside : { named : Set(Str), hops : Dict(Str, Str) }

	## Each label's first instruction that is an unconditional jump to a
	## label, by the label.
	hops_of : List(Assembly.Statement) -> Dict(Str, Str)
	hops_of = |statements| jump_labels(statements)
}

## Nothing beside.
alone : Jumps.Beside
alone = { named: Set.empty(), hops: Dict.empty() }

## Each label's first instruction that is an unconditional jump to a label,
## by the label: the jump's target.
jump_labels : List(Assembly.Statement) -> Dict(Str, Str)
jump_labels = |statements| {
	var $hops = Dict.empty()
	# The labels marked since the last instruction.
	var $marks = []
	for statement in statements {
		match statement {
			Mark(label) => {
				$marks = $marks.append(label)
			}
			JmpTo(target) => {
				for label in $marks {
					$hops = $hops.insert(label, target)
				}
				$marks = []
			}
			_ => {
				$marks = []
			}
		}
	}
	$hops
}

## Where a jump to `label` ends up, following jumps to jumps, at most
## eight of them, so a cycle of jumps ends.
final_target : Dict(Str, Str), Dict(Str, Str), Str -> Str
final_target = |hops, outside, label| {
	var $at = label
	for _ in 0..<8 {
		hop = match hops.get($at) {
			Ok(next) => Ok(next)
			Err(_) => outside.get($at)
		}
		match hop {
			Ok(next) if next != label => {
				$at = next
			}
			_ => return $at
		}
	}
	$at
}

## The statements with each jump to a jump made a jump to its target.
thread_each_jump : List(Assembly.Statement), Dict(Str, Str) -> List(Assembly.Statement)
thread_each_jump = |statements, outside| {
	hops = jump_labels(statements)
	statements.map(
		|statement|
			match statement {
				JmpTo(label) => JmpTo(final_target(hops, outside, label))
				JccTo({ condition, label }) => {
					landing = final_target(hops, outside, label)
					JccTo({ condition, label: landing })
				}
				_ => statement
			},
	)
}

## The statements with what follows a jump or a `ret`, up to the next label
## a statement names, taken out, data kept.
unreached_dropped : List(Assembly.Statement), { named : Set(Str), beside : Set(Str) } -> List(Assembly.Statement)
unreached_dropped = |statements, { named, beside }| {
	var $kept = List.with_capacity(statements.len())
	var $reached = True
	for statement in statements {
		match statement {
			Mark(label) if named.contains(label) or beside.contains(label) => {
				$reached = True
				$kept = $kept.append(statement)
			}
			Data(_) | Distance(_) => {
				$kept = $kept.append(statement)
			}
			_ =>
				if $reached {
					$kept = $kept.append(statement)
					$reached = match statement {
						JmpTo(_) | Instruction(Ret) => False
						_ => True
					}
				}
		}
	}
	$kept
}

## The statements with each jump to the labels right after it taken out.
next_jumps_dropped : List(Assembly.Statement) -> List(Assembly.Statement)
next_jumps_dropped = |statements| {
	var $kept = List.with_capacity(statements.len())
	for at in 0..<statements.len() {
		statement = statements.get(at) ?? crash "Jumps.next_jumps_dropped: a statement"
		next_to = match statement {
			JmpTo(label) => marks_after(statements, at).contains(label)
			_ => False
		}
		if !next_to {
			$kept = $kept.append(statement)
		}
	}
	$kept
}

## The labels marked right after the statement at `at`, before the next
## statement that isn't a label.
marks_after : List(Assembly.Statement), U64 -> List(Str)
marks_after = |statements, at| {
	var $marks = []
	for next in (at + 1)..<statements.len() {
		match statements.get(next) {
			Ok(Mark(label)) => {
				$marks = $marks.append(label)
			}
			_ => return $marks
		}
	}
	$marks
}

## Whether `thread_jumps` makes of `statements` the code of `expected`.
threads_to : List(Assembly.Statement), List(Assembly.Statement) -> Bool
threads_to = |statements, expected|
	Assembly.assemble(Jumps.thread_jumps(statements)) == Assembly.assemble(expected)

# A test's slow way that is a jump elsewhere: the test jumps there, and the
# fast way's jump over the slow way goes.
expect {
	threads_to(
		[
			JccTo({ condition: Ae, label: "slow" }),
			Instruction(MovRegImm({ to: Rax, value: 1 })),
			JmpTo("done"),
			Mark("slow"),
			JmpTo("stop"),
			Mark("done"),
			Instruction(Ret),
			Mark("stop"),
			Instruction(Ret),
		],
		[
			JccTo({ condition: Ae, label: "stop" }),
			Instruction(MovRegImm({ to: Rax, value: 1 })),
			Mark("done"),
			Instruction(Ret),
			Mark("stop"),
			Instruction(Ret),
		],
	)
}

# A cycle of jumps ends, and code another way reaches stays.
expect {
	body = [
		Assembly.Statement.Mark("one"),
		JmpTo("two"),
		Mark("two"),
		JmpTo("one"),
		Mark("other"),
		Instruction(Ret),
		JccTo({ condition: E, label: "other" }),
	]
	Assembly.assemble(Jumps.thread_jumps(body)).is_ok()
}
