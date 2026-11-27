## This module runs Lowering's post-passes (Jumps, Forwarding, Moves, then
## Jumps again) over a program with the runtime's statements done once,
## when js-x86 is built, rather than on every compile. The runtime is most
## of what a small program's passes walk (7,447 statements, about 20 ms of
## the fib race's 45, x86/buildrace/PROFILE.md).
##
## **WHAT IS COMPILED IS THE SAME, BYTE FOR BYTE**, as the passes make of
## the whole (`posts_of_whole`): the program's own statements (`program`:
## the start and the functions), then the runtime's (`RuntimeCode.items`),
## then `tail` (the texts and the closure records). Where a rule below
## isn't met, the whole is walked as before.
##
## **THE RUNTIME IN UNITS.** The runtime is cut after every `jmp` and `ret`,
## so no way falls into a unit: each is entered only at its labels. Jumps
## keeps a unit whole when a label it starts with is named (by the program,
## the tail or another unit kept) and drops its code otherwise, round after
## round, until the units kept name each other. Forwarding and Moves forget
## what they know at a `jmp` and a `ret`, so a unit's passes see only its
## own statements, the labels named among its own marks, the labels whose
## address is taken among those it jumps to and marks, and what is read at
## the labels it jumps to. So every unit is passed once, when js-x86 is
## built, as if every unit were kept (each unit's first labels taken as
## named, and a seam between units that stops a jump from being dropped
## as one to just after it), and a compile keeps the units the program
## reaches as Jumps would, then holds that what each kept unit saw is what
## it sees beside this program:
##
## - **Its labels are named as they were**: each label it marks past its
##   first is named by the program, the tail or a kept unit exactly when
##   the runtime alone named it; and no label a dropped unit marks is named.
## - **Its labels' addresses are taken as they were**: each label it marks
##   or jumps to has its address taken (a call, a `lea`, a distance)
##   beside this program exactly when it had in the runtime alone.
## - **No jump of it is to just after it**: a kept unit ending with a `jmp`
##   is not followed by a kept unit starting with that `jmp`'s label (Jumps
##   would drop the jump and the two would run together), nor is the
##   program's code.
## - **Jumps settles in time**: the program's rounds and the units' drops
##   together fit the 8 rounds `Jumps.thread_jumps` runs, and every round's
##   result is what one more round leaves as it is.
##
## The program and the tail are passed beside the runtime: the program
## jumps to the runtime's labels (its hops, what is read at them, whose
## address is taken), and the runtime names none of theirs. The program's
## code must end with a `ret` or a `jmp`, after which every walk forgets
## what it knew, and the tail must be labels, data and distances.
import Assembly
import Forwarding
import Jumps
import Moves
import RuntimeCode

RuntimePosts :: [].{

	## The post-passes of `program`, then the runtime's statements, then
	## `tail`, as `posts_of_whole` makes them, and how they were run (`way`):
	## `beside` when the runtime's were taken as done, else the rule above
	## that wasn't met.
	posts : { program : List(Assembly.Statement), tail : List(Assembly.Statement) } -> { statements : List(Assembly.Statement), way : Str }
	posts = |{ program, tail }|
		match posts_beside({ program, tail }) {
			Ok(done) => { statements: done, way: "beside" }
			Err(Apart(why)) => {
				statements: RuntimePosts.posts_of_whole(program.concat(RuntimeCode.items).concat(tail)),
				way: why,
			}
		}

	## The post-passes over a whole program's statements: Jumps first, so
	## that the labels its threading leaves unnamed (an item read's `done`) no
	## longer end Forwarding's and Moves' straight runs; then again, for the
	## jumps Moves leaves next to their labels.
	posts_of_whole : List(Assembly.Statement) -> List(Assembly.Statement)
	posts_of_whole = |statements|
		Jumps.thread_jumps(Moves.trim_moves(Forwarding.forward_loads(Jumps.thread_jumps(statements))))

}

## A distance to this label, which nothing marks, stands between the units
## while their passes run: no pass takes it out or moves anything past it.
seam_label : Str
seam_label = "runtime_posts_seam"

seam : Assembly.Statement
seam = Distance(seam_label)

## Whether a statement is the seam.
is_seam : Assembly.Statement -> Bool
is_seam = |statement|
	match statement {
		Distance(label) => label == seam_label
		_ => False
	}

## The runtime cut after every `jmp` and `ret`.
pieces : List(List(Assembly.Statement))
pieces = {
	var $out = []
	var $now = []
	for statement in RuntimeCode.items {
		$now = $now.append(statement)
		ends = match statement {
			JmpTo(_) | Instruction(Ret) => True
			_ => False
		}
		if ends {
			$out = $out.append($now)
			$now = []
		}
	}
	if $now.is_empty() {
		$out
	} else {
		$out.append($now)
	}
}

## The pieces with the seam between each two.
seamed : List(List(Assembly.Statement)) -> List(Assembly.Statement)
seamed = |parts| {
	var $out = []
	for part in parts {
		if !$out.is_empty() {
			$out = $out.append(seam)
		}
		$out = $out.concat(part)
	}
	$out
}

## Statements cut at each seam, the seams left out.
unseamed : List(Assembly.Statement) -> List(List(Assembly.Statement))
unseamed = |statements| {
	var $out = []
	var $now = []
	for statement in statements {
		if is_seam(statement) {
			$out = $out.append($now)
			$now = []
		} else {
			$now = $now.append(statement)
		}
	}
	$out.append($now)
}

## The labels marked before a unit's first statement that isn't a label.
leading_marks : List(Assembly.Statement) -> List(Str)
leading_marks = |statements| {
	var $marks = []
	for statement in statements {
		match statement {
			Mark(label) => {
				$marks = $marks.append(label)
			}
			_ => return $marks
		}
	}
	$marks
}

## The labels marked before the statements' first code (data between
## them passed by).
opening_marks : List(Assembly.Statement) -> List(Str)
opening_marks = |statements| {
	var $marks = []
	for statement in statements {
		match statement {
			Mark(label) => {
				$marks = $marks.append(label)
			}
			Data(_) | Distance(_) => {}
			_ => return $marks
		}
	}
	$marks
}

## Every label the statements mark.
marks_of : List(Assembly.Statement) -> List(Str)
marks_of = |statements| {
	var $marks = []
	for statement in statements {
		match statement {
			Mark(label) => {
				$marks = $marks.append(label)
			}
			_ => {}
		}
	}
	$marks
}

## Every label the statements name, once each.
names_of : List(Assembly.Statement) -> List(Str)
names_of = |statements| Assembly.named_labels(statements).to_list()

## Every label whose address the statements take: by a call, a `lea` or a
## distance.
addressed_of : List(Assembly.Statement) -> Set(Str)
addressed_of = |statements| {
	var $addressed = Set.empty()
	for statement in statements {
		match statement {
			CallTo(label) | Distance(label) | LeaTo({ to: _, label }) => {
				$addressed = $addressed.insert(label)
			}
			_ => {}
		}
	}
	$addressed
}

## Every label the statements jump to.
jumped_of : List(Assembly.Statement) -> List(Str)
jumped_of = |statements| {
	var $jumped = []
	for statement in statements {
		match statement {
			JmpTo(label) | JccTo({ condition: _, label }) => {
				$jumped = $jumped.append(label)
			}
			_ => {}
		}
	}
	$jumped
}

## Whether a unit holds code, not only labels and data.
holds_code : List(Assembly.Statement) -> Bool
holds_code = |statements|
	statements.any(
		|statement|
			match statement {
				Mark(_) | Data(_) | Distance(_) => False
				_ => True
			},
	)

## Whether a unit holds data or a distance.
holds_data : List(Assembly.Statement) -> Bool
holds_data = |statements|
	statements.any(
		|statement|
			match statement {
				Data(_) | Distance(_) => True
				_ => False
			},
	)

## The label of a `jmp` that ends the statements, if one does.
last_jump : List(Assembly.Statement) -> Try(Str, [NoJump])
last_jump = |statements|
	match statements.last() {
		Ok(JmpTo(label)) => Ok(label)
		_ => Err(NoJump)
	}

## Every unit's first labels, taken as named while the runtime is passed
## alone, so that no unit is dropped.
first_labels : Set(Str)
first_labels = {
	var $all = Set.empty()
	for piece in pieces {
		for label in leading_marks(piece) {
			$all = $all.insert(label)
		}
	}
	$all
}

## The labels of both sets.
with_labels : Set(Str), Set(Str) -> Set(Str)
with_labels = |one, other| {
	var $all = one
	for label in other {
		$all = $all.insert(label)
	}
	$all
}

## The runtime through the first Jumps, alone, every unit kept.
first_jumps : { threaded : List(Assembly.Statement), rounds : U64, settled : Bool }
first_jumps = Jumps.thread_jumps_beside(seamed(pieces), { named: first_labels, hops: Dict.empty() })

## The labels named while the runtime's Forwarding and Moves run alone.
alone_named : Set(Str)
alone_named = with_labels(Assembly.named_labels(first_jumps.threaded), first_labels)

## The runtime through Forwarding, alone.
forwarded : List(Assembly.Statement)
forwarded = Forwarding.forward_loads_named(first_jumps.threaded, alone_named)

## The labels whose address the runtime takes, alone.
alone_addressed : Set(Str)
alone_addressed = addressed_of(forwarded)

## The runtime through Moves, alone, and what its walks found read at its
## labels.
trimmed : { trimmed : List(Assembly.Statement), reads : List(Dict(Str, U32)) }
trimmed = Moves.trim_moves_beside(
	forwarded,
	{ named: alone_named, beside: { addressed: Set.empty(), reads: [Dict.empty(), Dict.empty()] } },
)

## The runtime through the second Jumps, alone, every unit kept.
second_jumps : { threaded : List(Assembly.Statement), rounds : U64, settled : Bool }
second_jumps = Jumps.thread_jumps_beside(trimmed.trimmed, { named: first_labels, hops: Dict.empty() })

## The hops of the runtime's labels in each Jumps.
first_hops : Dict(Str, Str)
first_hops = Jumps.hops_of(first_jumps.threaded)

second_hops : Dict(Str, Str)
second_hops = Jumps.hops_of(trimmed.trimmed)

## A unit's statements from one label to the next (the first from the
## unit's start to its first label, its `label` empty), as the passes left
## them, and what a compile checks of them. Jumps keeps a unit from its
## first label that is named on, so a unit is kept from one of these on.
Segment : {
	label : Str,

	## Whether the runtime alone took its label as named (a unit's first
	## labels always), and whether its label is one the unit starts with.
	named : Bool,
	leading : Bool,

	## Its count of statements after the first Jumps, and after Moves.
	first_length : U64,
	trimmed_length : U64,

	## The labels it names after the first Jumps, and after the second.
	first_names : List(Str),
	second_names : List(Str),

	## The labels it jumps to before Moves, each with its address taken in
	## the runtime alone or not.
	reached : List({ label : Str, addressed : Bool }),

	## Whose address it takes before Moves.
	addressing : List(Str),

	## Its statements after every pass.
	done : List(Assembly.Statement),
}

## One unit of the runtime, as its passes left it.
Unit : {
	## Whether it holds code (else only labels and data, always kept).
	code : Bool,
	segments : List(Segment),

	## The labels it marks before its first code, in order (for a unit of
	## data, whose unnamed labels Jumps drops before its first named one).
	opening : List(Str),

	## Its count of statements before the passes.
	piece_length : U64,

	## The label of a `jmp` it ends with, after each Jumps.
	first_last : Try(Str, [NoJump]),
	second_last : Try(Str, [NoJump]),
}

## A unit's statements cut at each label: the statements before its first
## label (with the label ""), then each label's.
segments_of : List(Assembly.Statement) -> List({ label : Str, statements : List(Assembly.Statement) })
segments_of = |statements| {
	var $out = []
	var $label = ""
	var $now = []
	for statement in statements {
		match statement {
			Mark(label) => {
				$out = $out.append({ label: $label, statements: $now })
				$label = label
				$now = [statement]
			}
			_ => {
				$now = $now.append(statement)
			}
		}
	}
	$out.append({ label: $label, statements: $now })
}

## The runtime's units, in its order.
units : List(Unit)
units = {
	firsts = unseamed(first_jumps.threaded)
	befores = unseamed(forwarded)
	thirds = unseamed(trimmed.trimmed)
	seconds = unseamed(second_jumps.threaded)
	var $out = []
	for at in 0..<pieces.len() {
		piece = pieces.get(at) ?? crash "RuntimePosts.units: a piece"
		first = firsts.get(at) ?? []
		before = befores.get(at) ?? []
		third = thirds.get(at) ?? []
		second = seconds.get(at) ?? []
		leading = leading_marks(piece)
		first_parts = segments_of(first)
		before_parts = segments_of(before)
		third_parts = segments_of(third)
		second_parts = segments_of(second)
		var $segments = []
		for place in 0..<first_parts.len() {
			one = first_parts.get(place) ?? crash "RuntimePosts.units: a segment"
			was = before_parts.get(place) ?? one
			trim = third_parts.get(place) ?? one
			done = second_parts.get(place) ?? one
			$segments = $segments.append({
				label: one.label,
				named: alone_named.contains(one.label),
				leading: leading.contains(one.label),
				first_length: one.statements.len(),
				trimmed_length: trim.statements.len(),
				first_names: names_of(one.statements),
				second_names: names_of(done.statements),
				reached: jumped_of(was.statements).map(|label| { label, addressed: alone_addressed.contains(label) }),
				addressing: addressed_of(was.statements).to_list(),
				done: done.statements,
			})
		}
		$out = $out.append({
			code: holds_code(piece),
			segments: $segments,
			opening: opening_marks(piece),
			piece_length: piece.len(),
			first_last: last_jump(first),
			second_last: last_jump(second),
		})
	}
	$out
}

## Whether each unit's forms are cut at the same labels as the runtime
## before the passes: no pass took a label out or added one.
labels_kept : Bool
labels_kept = {
	forms = [first_jumps.threaded, forwarded, trimmed.trimmed, second_jumps.threaded].map(unseamed)
	List.map_with_index(
		pieces,
		|piece, at| {
			wanted = segments_of(piece).map(|part| part.label)
			forms.all(
				|form| {
					unit = form.get(at) ?? []
					segments_of(unit).map(|part| part.label) == wanted
				},
			)
		},
	).all(|kept| kept)
}

## The rules checked once, when js-x86 is built (Roc evaluates it then,
## and the expect below holds it): each pass's units are the pieces (no
## seam lost), no unit holds both code and data (a dropped one would keep
## its data), every pass kept every unit's labels, and each Jumps settled
## in two rounds, one more round leaving it as it was.
closed : Bool
closed = {
	counts = [first_jumps.threaded, forwarded, trimmed.trimmed, second_jumps.threaded].all(
		|statements| unseamed(statements).len() == pieces.len(),
	)
	unmixed = pieces.all(|piece| !holds_code(piece) or !holds_data(piece))
	settles = |jumps| {
		again = Jumps.thread_jumps_beside(jumps.threaded, { named: first_labels, hops: Dict.empty() })
		jumps.settled and jumps.rounds <= 2 and same_jumps(again.threaded, jumps.threaded)
	}
	counts and unmixed and labels_kept and settles(first_jumps) and settles(second_jumps)
}

expect closed

## Whether a round of Jumps left statements as they were: the same count
## (a round only drops statements, so none was dropped) and every jump to
## the same label (the threading changes nothing else).
same_jumps : List(Assembly.Statement), List(Assembly.Statement) -> Bool
same_jumps = |after, before|
	after.len() == before.len() and List.map2(
		after,
		before,
		|one, other|
			match (one, other) {
				(JmpTo(a), JmpTo(b)) => a == b
				(JccTo({ condition: _, label: a }), JccTo({ condition: _, label: b })) => a == b
				_ => True
			},
	).all(|same| same)

## How many of a unit of data's opening labels a round of Jumps takes
## out, given the labels named: those before the first named one, or all of
## them when none is named.
opening_dropped : Unit, Set(Str) -> U64
opening_dropped = |unit, named| {
	var $count = 0
	for label in unit.opening {
		if named.contains(label) {
			return $count
		}
		$count = $count + 1
	}
	$count
}

## Where Jumps keeps a code unit from, given where it kept it from before
## and the labels named: its first segment from there whose label is named,
## or past its last (the unit dropped).
kept_from : Unit, { from : U64, named : Set(Str) } -> U64
kept_from = |unit, { from, named }| {
	for place in from..<unit.segments.len() {
		segment = unit.segments.get(place) ?? crash "RuntimePosts.kept_from: a segment"
		if segment.label != "" and named.contains(segment.label) {
			return place
		}
	}
	unit.segments.len()
}

## A unit's segments from `from` on.
segments_from : Unit, U64 -> List(Segment)
segments_from = |unit, from| unit.segments.drop_first(from)

## Where each unit stands in a phase: a code unit kept from a segment on
## (`from`, past the last when dropped or passed with the program), and how
## many opening labels of a unit of data were taken out (`dropped`).
Standing : { from : List(U64), dropped : List(U64) }

## The units' count of statements as they stand, by `length`, a segment's
## in this phase.
standing_length : Standing, (Segment -> U64) -> U64
standing_length = |standing, length| {
	var $sum = 0
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.standing_length: a unit"
		if unit.code {
			from = standing.from.get(at) ?? 0
			for segment in segments_from(unit, from) {
				$sum = $sum + length(segment)
			}
		} else {
			for segment in unit.segments {
				$sum = $sum + length(segment)
			}
			$sum = $sum - (standing.dropped.get(at) ?? 0)
		}
	}
	$sum
}

## The labels the units name as they stand, by `names`, a segment's in this
## phase, added to `named`.
standing_names : Standing, { named : Set(Str), names : Segment -> List(Str) } -> Set(Str)
standing_names = |standing, { named, names }| {
	var $all = named
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.standing_names: a unit"
		from = if unit.code {
			standing.from.get(at) ?? 0
		} else {
			0
		}
		for segment in segments_from(unit, from) {
			for label in names(segment) {
				$all = $all.insert(label)
			}
		}
	}
	$all
}

## A phase of Jumps over the own statements (the program's, the units
## passed with it, the tail's) and the runtime's units done once beside
## them, as `Jumps.thread_jumps` runs it over the whole: round by round, the
## own statements' round (`Jumps.round_beside`, the units' names as they
## stood taken as named), each code unit kept from its first segment whose
## label is named by the own statements or by the units as they stood
## (`names`, a segment's after the threading), and the unnamed opening
## labels of each unit of data dropped; the rounds stop when the whole's
## count of statements stays the same, or after 8, as the whole's would.
## `first` is the units' count of statements before the phase, and `length`
## a segment's count after its rounds.
phase : {
	own : List(Assembly.Statement),
	hops : Dict(Str, Str),
	standing : Standing,
	first : U64,
	names : Segment -> List(Str),
	length : Segment -> U64,
} -> { own : List(Assembly.Statement), standing : Standing, named : Set(Str) }
phase = |{ own, hops, standing, first, names, length }| {
	var $own = own
	var $standing = standing
	var $length = own_length(own) + first
	for _ in 0..<Jumps.most_rounds {
		beside = standing_names($standing, { named: Set.empty(), names })
		threaded = Jumps.round_threaded($own, hops)
		named = with_labels(beside, Assembly.named_labels(threaded))
		# The tail follows the runtime's last unit: reached past it when
		# that unit is data with a label named, as `tail_mark` stands for.
		reached = tail_opening.any(|label| named.contains(label))
		after = Jumps.round_dropped(
			threaded,
			{
				named,
				beside: if reached {
					beside.insert(tail_label)
				} else {
					beside
				},
			},
		)
		var $from = []
		var $dropped = []
		for at in 0..<units.len() {
			unit = units.get(at) ?? crash "RuntimePosts.phase: a unit"
			was_from = $standing.from.get(at) ?? 0
			was_dropped = $standing.dropped.get(at) ?? 0
			now_dropped = opening_dropped(unit, named)
			$from = $from.append(
				if unit.code {
					kept_from(unit, { from: was_from, named })
				} else {
					0
				},
			)
			$dropped = $dropped.append(
				if now_dropped > was_dropped {
					now_dropped
				} else {
					was_dropped
				},
			)
		}
		$own = after
		$standing = { from: $from, dropped: $dropped }
		whole = own_length($own) + standing_length($standing, length)
		if whole == $length {
			return phase_left({ own: $own, standing: $standing, names })
		}
		$length = whole
	}
	phase_left({ own: $own, standing: $standing, names })
}

## The labels of the runtime's last unit when it is data, any of which
## named leaves the tail after it reached.
tail_opening : List(Str)
tail_opening =
	match units.last() {
		Ok(unit) if !unit.code => unit.opening
		_ => []
	}

## The own statements' count, `tail_mark` left out: the whole has none.
own_length : List(Assembly.Statement) -> U64
own_length = |own| own.len() - own.count_if(|statement| is_tail_mark(statement))

## A label before the tail, named in a round of Jumps when the runtime's
## last unit leaves the tail reached (`phase`), so the tail's labels that
## nothing names are kept or dropped as the whole would.
tail_label : Str
tail_label = "runtime_posts_tail"

tail_mark : Assembly.Statement
tail_mark = Mark(tail_label)

is_tail_mark : Assembly.Statement -> Bool
is_tail_mark = |statement|
	match statement {
		Mark(label) => label == tail_label
		_ => False
	}

## A phase's end, with what the next pass sees as named: what the
## statements left name.
phase_left : { own : List(Assembly.Statement), standing : Standing, names : Segment -> List(Str) } -> { own : List(Assembly.Statement), standing : Standing, named : Set(Str) }
phase_left = |{ own, standing, names }| {
	named = standing_names(standing, { named: Assembly.named_labels(own), names })
	{ own, standing, named }
}

## Each label the runtime marks, by the unit that marks it.
unit_of : Dict(Str, U64)
unit_of = {
	var $all = Dict.empty()
	for at in 0..<pieces.len() {
		piece = pieces.get(at) ?? crash "RuntimePosts.unit_of: a piece"
		for label in marks_of(piece) {
			$all = $all.insert(label, at)
		}
	}
	$all
}

## The own statements, cut back into the program's code, each unit passed
## with it (by its labels: Jumps keeps a kept unit's first named label, and
## no pass drops a label it keeps) and the tail.
Own : { code : List(Assembly.Statement), passed : Dict(U64, List(Assembly.Statement)), tail : List(Assembly.Statement) }

own_cut : List(Assembly.Statement) -> Own
own_cut = |statements| {
	var $code = []
	var $passed = Dict.empty()
	var $tail = []
	var $at = Code
	for statement in statements {
		if is_seam(statement) {
			$at = Tail
		} else {
			match statement {
				Mark(label) =>
					match ($at, unit_of.get(label)) {
						(Tail, _) => {}
						(_, Ok(unit)) => {
							$at = Passed(unit)
						}
						_ => {}
					}
				_ => {}
			}
			match $at {
				Code => {
					$code = $code.append(statement)
				}
				Passed(unit) => {
					$passed = $passed.insert(unit, ($passed.get(unit) ?? []).append(statement))
				}
				Tail => {
					$tail = $tail.append(statement)
				}
			}
		}
	}
	{ code: $code, passed: $passed, tail: $tail }
}

## The units passed with the program, in the runtime's order.
passed_list : Set(U64) -> List(U64)
passed_list = |passed| {
	var $out = []
	for at in 0..<units.len() {
		if passed.contains(at) {
			$out = $out.append(at)
		}
	}
	$out
}

## What a compile's checks found: the post-passes, or units to pass with
## the program instead (`Grow`), or a rule no unit's passing would meet.
posts_beside : { program : List(Assembly.Statement), tail : List(Assembly.Statement) } -> Try(List(Assembly.Statement), [Apart(Str)])
posts_beside = |{ program, tail }| {
	tail_ok = tail.all(
		|statement|
			match statement {
				Mark(_) | Data(_) | Distance(_) => True
				_ => False
			},
	)
	if !tail_ok {
		return Err(Apart("the tail holds code"))
	}
	var $passed = Set.empty()
	for _ in 0..<most_tries {
		match posts_passing({ program, tail, passed: $passed }) {
			Ok(done) => return Ok(done)
			Err(Grow(more)) => {
				$passed = with_units($passed, more)
			}
			Err(Apart(why)) => return Err(Apart(why))
		}
	}
	Err(Apart("the units passed with the program grew for too long: ${$passed.len().to_str()} of ${units.len().to_str()}"))
}

## How many times a compile may grow the units passed with the program.
most_tries : U64
most_tries = 6

## The units of both.
with_units : Set(U64), List(U64) -> Set(U64)
with_units = |one, more| {
	var $all = one
	for at in more {
		$all = $all.insert(at)
	}
	$all
}

## The post-passes with every unit but `passed` done already, those passed
## with the program; or the units whose passes done once don't fit beside
## this program (`Grow`), or `Apart` naming the rule above it doesn't meet.
posts_passing : { program : List(Assembly.Statement), tail : List(Assembly.Statement), passed : Set(U64) } -> Try(List(Assembly.Statement), [Apart(Str), Grow(List(U64))])
posts_passing = |{ program, tail, passed }| {
	order = passed_list(passed)
	var $own = program
	var $passed_length = 0
	for at in order {
		piece = pieces.get(at) ?? crash "RuntimePosts.posts_passing: a piece"
		$own = $own.concat(piece)
		$passed_length = $passed_length + piece.len()
	}
	own = $own.append(seam).append(tail_mark).concat(tail)
	var $pieces_length = 0
	for piece in pieces {
		$pieces_length = $pieces_length + piece.len()
	}
	start = {
		from: List.map_with_index(
			units,
			|unit, at| if passed.contains(at) {
				unit.segments.len()
			} else {
				0
			},
		),
		dropped: units.map(|_| 0),
	}

	# The first Jumps.
	first = phase({
		own,
		hops: first_hops,
		standing: start,
		first: $pieces_length - $passed_length,
		names: |segment| segment.first_names,
		length: |segment| segment.first_length,
	})
	first_cut = own_cut(first.own)
	ends_apart(first_cut, { standing: first.standing, passed, last: |unit| unit.first_last, length: |segment| segment.first_length })?
	inner_named(first.standing, first.named)?

	# Forwarding and Moves.
	own_forwarded = Forwarding.forward_loads_named(first.own, first.named)
	var $addressed = addressed_of(own_forwarded)
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.posts_passing: a unit"
		from = if unit.code {
			first.standing.from.get(at) ?? 0
		} else {
			0
		}
		for segment in segments_from(unit, from) {
			for label in segment.addressing {
				$addressed = $addressed.insert(label)
			}
		}
	}
	addressed = $addressed
	var $grow = []
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.posts_passing: a unit"
		if unit.code {
			fits = segments_from(unit, first.standing.from.get(at) ?? 0).all(
				|segment| segment.reached.all(|{ label, addressed: was }| addressed.contains(label) == was),
			)
			if !fits {
				$grow = $grow.append(at)
			}
		}
	}
	# What the runtime alone found read at a label whose address it took
	# was never walked for: that label's unit is passed with the program.
	for label in jumped_of(own_forwarded) {
		if alone_addressed.contains(label) and !addressed.contains(label) {
			match unit_of.get(label) {
				Ok(at) if !passed.contains(at) => {
					$grow = $grow.append(at)
				}
				_ => {}
			}
		}
	}
	if !$grow.is_empty() {
		return Err(Grow($grow))
	}
	own_moved = Moves.trim_moves_beside(
		own_forwarded,
		{ named: first.named, beside: { addressed, reads: trimmed.reads } },
	)
	reads_held(own_moved.reads, { standing: first.standing, passed, addressed })?
	hops_held(Jumps.hops_of(own_moved.trimmed), { standing: first.standing, passed })?

	# The second Jumps.
	second = phase({
		own: own_moved.trimmed,
		hops: second_hops,
		standing: first.standing,
		first: standing_length(first.standing, |segment| segment.trimmed_length),
		names: |segment| segment.second_names,
		length: |segment| segment.trimmed_length,
	})
	second_cut = own_cut(second.own)
	ends_apart(second_cut, { standing: second.standing, passed, last: |unit| unit.second_last, length: |segment| segment.trimmed_length })?

	# The program's code, the units as they stand or as they were passed
	# with it, then the tail.
	var $out = second_cut.code
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.posts_passing: a unit"
		if passed.contains(at) {
			$out = $out.concat(second_cut.passed.get(at) ?? [])
		} else {
			from = if unit.code {
				second.standing.from.get(at) ?? 0
			} else {
				0
			}
			for segment in segments_from(unit, from) {
				$out = $out.concat(segment.done)
			}
		}
	}
	Ok($out.concat(second_cut.tail.drop_if(is_tail_mark)))
}

## Whether what the own statements' walks found read at the labels of the
## units passed with them is what the runtime alone found, wherever a unit
## done once jumps to one of them.
reads_held : List(Dict(Str, U32)), { standing : Standing, passed : Set(U64), addressed : Set(Str) } -> Try({}, [Apart(Str), Grow(List(U64))])
reads_held = |reads, { standing, passed, addressed }| {
	var $grow = []
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.reads_held: a unit"
		if unit.code and !passed.contains(at) {
			for segment in segments_from(unit, standing.from.get(at) ?? 0) {
				for { label, addressed: _ } in segment.reached {
					passed_to = match unit_of.get(label) {
						Ok(target) => passed.contains(target)
						Err(_) => False
					}
					if passed_to and !addressed.contains(label) {
						same = List.map2(reads, trimmed.reads, |own, alone| own.get(label) == alone.get(label)).all(|held| held)
						if !same and !$grow.contains(at) {
							$grow = $grow.append(at)
						}
					}
				}
			}
		}
	}
	if $grow.is_empty() {
		Ok({})
	} else {
		Err(Grow($grow))
	}
}

## Whether the labels of the units passed with the program hop after Moves
## as they did in the runtime alone, wherever a unit done once jumps to one.
hops_held : Dict(Str, Str), { standing : Standing, passed : Set(U64) } -> Try({}, [Apart(Str), Grow(List(U64))])
hops_held = |hops, { standing, passed }| {
	var $grow = []
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.hops_held: a unit"
		if unit.code and !passed.contains(at) {
			for segment in segments_from(unit, standing.from.get(at) ?? 0) {
				for { label, addressed: _ } in segment.reached {
					passed_to = match unit_of.get(label) {
						Ok(target) => passed.contains(target)
						Err(_) => False
					}
					if passed_to and hops.get(label) != second_hops.get(label) and !$grow.contains(at) {
						$grow = $grow.append(at)
					}
				}
			}
		}
	}
	if $grow.is_empty() {
		Ok({})
	} else {
		Err(Grow($grow))
	}
}

## The labels a kept code unit starts with as it stands: its first kept
## segment's, and those of the segments right after that hold only their
## label.
starting_labels : Unit, { from : U64, length : Segment -> U64 } -> List(Str)
starting_labels = |unit, { from, length }| {
	var $labels = []
	for segment in segments_from(unit, from) {
		$labels = $labels.append(segment.label)
		if length(segment) > 1 {
			return $labels
		}
	}
	$labels
}

## One piece of the whole in its order, for `ends_apart`: the program's
## code, a unit passed with it, or a unit done once.
Piece : [Code, Passed(U64), Done(U64)]

## Whether no `jmp` ending one piece of the whole is to a label the next
## kept piece starts with, which Jumps would drop: between two units done
## once, or one done once and one passed with the program (both are passed
## with it then, `Grow`); and between two pieces passed with the program
## with a kept unit done once between them, which the program's own Jumps
## wouldn't see (that unit is passed too). The program's code must end with
## a `ret` or a `jmp`.
ends_apart : Own, { standing : Standing, passed : Set(U64), last : Unit -> Try(Str, [NoJump]), length : Segment -> U64 } -> Try({}, [Apart(Str), Grow(List(U64))])
ends_apart = |cut, { standing, passed, last, length }| {
	match cut.code.last() {
		Ok(JmpTo(_)) | Ok(Instruction(Ret)) => {}
		_ => return Err(Apart("the program's code doesn't end with a ret or a jmp"))
	}
	# The kept pieces in the whole's order, each with the label of the
	# `jmp` it ends with and the labels it starts with.
	var $kept = [{ piece: Code, ending: last_jump(cut.code), starting: [] }]
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.ends_apart: a unit"
		if passed.contains(at) {
			statements = cut.passed.get(at) ?? []
			if !statements.is_empty() {
				$kept = $kept.append({ piece: Passed(at), ending: last_jump(statements), starting: leading_marks(statements) })
			}
		} else if unit.code {
			from = standing.from.get(at) ?? 0
			if from < unit.segments.len() {
				$kept = $kept.append({ piece: Done(at), ending: last(unit), starting: starting_labels(unit, { from, length }) })
			}
		} else {
			$kept = $kept.append({ piece: Done(at), ending: Err(NoJump), starting: [] })
		}
	}
	var $grow = []
	for place in 1..<$kept.len() {
		before = $kept.get(place - 1) ?? crash "RuntimePosts.ends_apart: a piece"
		after = $kept.get(place) ?? crash "RuntimePosts.ends_apart: a piece"
		joined = match before.ending {
			Ok(label) => after.starting.contains(label)
			Err(_) => False
		}
		if joined {
			match before.piece {
				Done(at) => {
					$grow = $grow.append(at)
				}
				_ => {}
			}
			match after.piece {
				Done(at) => {
					$grow = $grow.append(at)
				}
				_ => {}
			}
		}
	}
	# Two own pieces with units done once between them: the program's own
	# Jumps sees them side by side.
	var $own_before = Err(NoPiece)
	var $between = []
	for kept in $kept {
		match kept.piece {
			Done(at) => {
				$between = $between.append(at)
			}
			_ => {
				match $own_before {
					Ok(earlier) =>
						match earlier.ending {
							Ok(label) if kept.starting.contains(label) and !$between.is_empty() => {
								$grow = $grow.concat($between)
							}
							_ => {}
						}
					Err(_) => {}
				}
				$own_before = Ok(kept)
				$between = []
			}
		}
	}
	if $grow.is_empty() {
		Ok({})
	} else {
		Err(Grow($grow))
	}
}

## The statements before the seam: the program's own code.
before_seam : List(Assembly.Statement) -> List(Assembly.Statement)
before_seam = |own| {
	var $before = []
	for statement in own {
		if is_seam(statement) {
			return $before
		}
		$before = $before.append(statement)
	}
	$before
}

## Whether each kept code unit done once has its labels named as the
## runtime alone took them: the one it is kept from (named, so the runtime
## alone must have taken it so), and each past it but those it starts with,
## which stand beside the first. A unit that doesn't is passed with the
## program (`Grow`).
inner_named : Standing, Set(Str) -> Try({}, [Apart(Str), Grow(List(U64))])
inner_named = |standing, named| {
	var $grow = []
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.inner_named: a unit"
		from = standing.from.get(at) ?? 0
		if unit.code and from < unit.segments.len() {
			fits = segments_from(unit, from).all(
				|segment| segment.leading or segment.named == named.contains(segment.label),
			)
			if !fits {
				$grow = $grow.append(at)
			}
		}
	}
	if $grow.is_empty() {
		Ok({})
	} else {
		Err(Grow($grow))
	}
}
