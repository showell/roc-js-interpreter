## This module takes out the jumps the lowered code doesn't need. A test's
## slow way is lowered where the test is, so an item read of an array of
## numbers is the test's `jae slow`, the fast way's load and its `jmp done`
## over the slow way, `slow: jmp stop`, then `done:`: the fast way, the usual
## one, takes a jump at every access. `thread_jumps` walks the whole program,
## the runtime's routines too, and does three things until none changes it:
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
	thread_jumps = |statements| {
		var $now = statements
		for _ in 0..<8 {
			once = next_jumps_dropped(unreached_dropped(thread_each_jump($now)))
			if once.len() == $now.len() {
				return once
			}
			$now = once
		}
		$now
	}
}

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
final_target : Dict(Str, Str), Str -> Str
final_target = |hops, label| {
	var $at = label
	for _ in 0..<8 {
		match hops.get($at) {
			Ok(next) if next != label => {
				$at = next
			}
			_ => return $at
		}
	}
	$at
}

## The statements with each jump to a jump made a jump to its target.
thread_each_jump : List(Assembly.Statement) -> List(Assembly.Statement)
thread_each_jump = |statements| {
	hops = jump_labels(statements)
	statements.map(
		|statement|
			match statement {
				JmpTo(label) => JmpTo(final_target(hops, label))
				JccTo({ condition, label }) => {
					landing = final_target(hops, label)
					JccTo({ condition, label: landing })
				}
				_ => statement
			},
	)
}

## The statements with what follows a jump or a `ret`, up to the next label
## a statement names, taken out, data kept.
unreached_dropped : List(Assembly.Statement) -> List(Assembly.Statement)
unreached_dropped = |statements| {
	named = Assembly.named_labels(statements)
	var $kept = List.with_capacity(statements.len())
	var $reached = True
	for statement in statements {
		match statement {
			Mark(label) if named.contains(label) => {
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
