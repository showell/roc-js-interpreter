## This module runs Lowering's post-passes (Jumps, Forwarding, Moves, then
## Jumps again) over a program with the runtime's statements done once,
## when js-x86 is built, rather than on every compile. The runtime is most
## of what a small program's passes walk (7,447 statements, about 20 ms of
## the fib race's 45, x86/buildrace/PROFILE.md).
##
## **WHAT IS COMPILED IS THE SAME, BYTE FOR BYTE**, as the passes make of
## the whole (`posts_of_whole`): the program's own statements
## (`program_statements`: the start and the functions), then the runtime's
## (`RuntimeCode.items`), then `tail_statements` (the texts and the closure records).
##
## **THE RUNTIME IN UNITS.** The runtime is cut after every `jmp` and `ret`,
## so no way falls into a unit: each is entered only at its labels. Jumps
## keeps a unit from its first label that is named (by the program, the
## tail or a unit kept) and drops what comes before it, round after round,
## until the units kept name each other. Forwarding and Moves forget what
## they know at a `jmp` and a `ret`, so a unit's passes see only its own
## statements, which of its labels are named, whose address is taken among
## the labels it jumps to, and what is read at them. So every unit is passed
## once, when js-x86 is built, as if every unit were kept (each unit's first
## labels taken as named, and a seam between units that stops a jump from
## being dropped as one to just after it), and a compile runs Jumps' rounds
## over the program beside the units as Jumps runs them over the whole
## (`phase`), then holds that what each unit kept saw alone is what it sees
## beside this program:
##
## - **Its labels are named as they were** (`inner_named`): each label it
##   keeps past the one it is kept from is named exactly when the runtime
##   alone named it.
## - **Its labels' addresses are taken as they were**: each label it jumps
##   to has its address taken (a call, a `lea`, a distance) beside this
##   program exactly when it had in the runtime alone.
## - **No jump of it is to just after it** (`ends_apart`): a unit ending
##   with a `jmp` is not followed, in what is kept, by a unit starting with
##   that `jmp`'s label (Jumps would drop the jump and the two would run
##   together), nor is the program's code.
## - **What it reads at a unit passed with the program is as it was**
##   (`reads_held`, `hops_held`).
##
## **A UNIT THAT DOESN'T FIT IS PASSED WITH THE PROGRAM**: its statements go
## through the passes with the program's, in its place in the whole's
## order, and the compile is run again with it so (`posts_beside`), until
## every unit done once fits. The units that most programs pass are found
## when js-x86 is built (`seed`), so most compiles fit at the first try.
## The allocator's kind entries are such units: each ends with a jump to
## the shared path, and the last one a program keeps runs into it. The program's code must end with a `ret` or a `jmp`,
## and the tail must be labels, data and distances; where either isn't so,
## or the units passed keep growing, the whole is passed as before.
##
## The runtime names no label of the program's or the tail's, so the
## program's passes take the runtime's labels as they stand beside it (its
## hops, what is read at them, whose address is taken).
import Assembly
import Forwarding
import Jumps
import Moves
import ObjectTable
import Runtime
import RuntimeCode

RuntimePosts :: [].{

	## The post-passes of `program_statements`, then the runtime's
	## statements, then `tail_statements`, as `posts_of_whole` makes them, and how they were run (`way`):
	## `beside` when the runtime's were taken as done, else why the whole
	## was passed.
	posts : {
		program_statements : List(Assembly.Statement),
		tail_statements : List(Assembly.Statement),
	} -> { statements : List(Assembly.Statement), way : Str }
	posts = |{ program_statements, tail_statements }|
		match posts_beside({ program_statements, tail_statements }) {
			Ok({ statements, tries, passed }) => {
				tries_text = "${tries.to_str()} tries"
				passed_text = "${passed.to_str()} units passed with the program"
				seed_text = "${seed.len().to_str()} from the start"
				{ statements, way: "beside (${tries_text}, ${passed_text}, ${seed_text})" }
			}
			Err(Apart(why)) => {
				whole = program_statements.concat(RuntimeCode.items).concat(tail_statements)
				{ statements: RuntimePosts.posts_of_whole(whole), way: why }
			}
		}

	## The post-passes over a whole program's statements: Jumps first, so
	## that the labels its threading leaves unnamed (an item read's `done`) no
	## longer end Forwarding's and Moves' straight runs; then again, for the
	## jumps Moves leaves next to their labels.
	posts_of_whole : List(Assembly.Statement) -> List(Assembly.Statement)
	posts_of_whole = |statements| {
		jumped = Jumps.thread_jumps(statements)
		moved = Moves.trim_moves(Forwarding.forward_loads(jumped))
		Jumps.thread_jumps(moved)
	}

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
join_with_seams : List(List(Assembly.Statement)) -> List(Assembly.Statement)
join_with_seams = |parts| {
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
cut_at_seams : List(Assembly.Statement) -> List(List(Assembly.Statement))
cut_at_seams = |statements| {
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
first_jumps : {
	threaded : List(Assembly.Statement),
	rounds : U64,
	settled : Bool,
}
first_jumps = Jumps.thread_jumps_beside(join_with_seams(pieces), { named: first_labels, hops: Dict.empty() })

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
second_jumps : {
	threaded : List(Assembly.Statement),
	rounds : U64,
	settled : Bool,
}
second_jumps = Jumps.thread_jumps_beside(
	trimmed.trimmed,
	{ named: first_labels, hops: Dict.empty() },
)

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

	## Its label's number (`label_numbers`; `label_count` for none).
	number : U64,

	## Its count of statements after the first Jumps, and after Moves, and
	## each with the counts of the segments after it in its unit.
	first_length : U64,
	trimmed_length : U64,
	first_rest : U64,
	trimmed_rest : U64,

	## The numbers of the labels it names after the first Jumps, and after
	## the second.
	first_names : List(U64),
	second_names : List(U64),

	## The labels it jumps to before Moves, each with its address taken in
	## the runtime alone or not.
	reached : List({ label : Str, addressed : Bool }),

	## Whose address it takes before Moves.
	addressed_labels : List(Str),

	## Its statements after every pass.
	done : List(Assembly.Statement),
}

## One unit of the runtime, as its passes left it.
Unit : {
	## Whether it holds code (else only labels and data, always kept).
	code : Bool,
	segments : List(Segment),

	## The numbers of the labels it marks before its first code, in order
	## (for a unit of data, whose unnamed labels Jumps drops before its first
	## named one).
	opening_numbers : List(U64),

	## Its count of statements before the passes.
	piece_length : U64,

	## The label of a `jmp` it ends with, after each Jumps.
	first_last : Try(Str, [NoJump]),
	second_last : Try(Str, [NoJump]),
}

## A unit's statements cut at each label: the statements before its first
## label (with the label ""), then each label's.
segments_of : List(Assembly.Statement) -> List(
	{ label : Str, statements : List(Assembly.Statement) },
)
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
	firsts = cut_at_seams(first_jumps.threaded)
	befores = cut_at_seams(forwarded)
	thirds = cut_at_seams(trimmed.trimmed)
	seconds = cut_at_seams(second_jumps.threaded)
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
				number: label_numbers.get(one.label) ?? label_count,
				first_length: one.statements.len(),
				trimmed_length: trim.statements.len(),
				first_rest: 0,
				trimmed_rest: 0,
				first_names: numbers_of(names_of(one.statements)),
				second_names: numbers_of(names_of(done.statements)),
				reached: jumped_of(was.statements).map(
					|label| { label, addressed: alone_addressed.contains(label) },
				),
				addressed_labels: addressed_of(was.statements).to_list(),
				done: done.statements,
			})
		}
		# Each segment's count with those after it.
		var $rested = []
		var $first_rest = 0
		var $trimmed_rest = 0
		for back in 0..<$segments.len() {
			index = $segments.len() - 1 - back
			segment = $segments.get(index) ?? crash "RuntimePosts.units: a segment"
			$first_rest = $first_rest + segment.first_length
			$trimmed_rest = $trimmed_rest + segment.trimmed_length
			$rested = $rested.append({
				..segment,
				first_rest: $first_rest,
				trimmed_rest: $trimmed_rest,
			})
		}
		var $forward = []
		for back in 0..<$rested.len() {
			index = $rested.len() - 1 - back
			segment = $rested.get(index) ?? crash "RuntimePosts.units: a segment"
			$forward = $forward.append(segment)
		}
		$out = $out.append({
			code: holds_code(piece),
			segments: $forward,
			opening_numbers: numbers_of(opening_marks(piece)),
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
	forms = [first_jumps.threaded, forwarded, trimmed.trimmed, second_jumps.threaded].map(cut_at_seams)
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
## seam lost), every pass kept every unit's labels, and each Jumps settled
## in two rounds, one more round leaving it as it was.
closed : Bool
closed = {
	counts = [first_jumps.threaded, forwarded, trimmed.trimmed, second_jumps.threaded].all(
		|statements| cut_at_seams(statements).len() == pieces.len(),
	)
	settles = |jumps| {
		again = Jumps.thread_jumps_beside(
			jumps.threaded,
			{ named: first_labels, hops: Dict.empty() },
		)
		jumps.settled and jumps.rounds <= 2 and same_jumps(again.threaded, jumps.threaded)
	}
	counts and labels_kept and settles(first_jumps) and settles(second_jumps)
}

expect closed

## Whether a round of Jumps left statements as they were: the same count
## (a round only drops statements, so none was dropped) and every jump to
## the same label (the threading changes nothing else).
same_jumps : List(Assembly.Statement), List(Assembly.Statement) -> Bool
same_jumps = |later, earlier|
	later.len() == earlier.len() and List.map2(
		later,
		earlier,
		|one, other|
			match (one, other) {
				(JmpTo(late), JmpTo(early)) => late == early
				(JccTo(late), JccTo(early)) => late.label == early.label
				_ => True
			},
	).all(|same| same)

## How many of a unit of data's opening labels a round of Jumps takes
## out, given the labels named: those before the first named one, or all of
## them when none is named.
opening_dropped : Unit, List(Bool) -> U64
opening_dropped = |unit, named| {
	var $count = 0
	for number in unit.opening_numbers {
		if is_named(named, number) {
			return $count
		}
		$count = $count + 1
	}
	$count
}

## Where Jumps keeps a code unit from, given where it kept it from before
## and the runtime's labels named, by their numbers: its first segment from
## there whose label is named, or past its last (the unit dropped).
kept_from : Unit, { from : U64, named : List(Bool) } -> U64
kept_from = |unit, { from, named }| {
	for place in from..<unit.segments.len() {
		segment = unit.segments.get(place) ?? crash "RuntimePosts.kept_from: a segment"
		if is_named(named, segment.number) {
			return place
		}
	}
	unit.segments.len()
}

## A unit's segments from `from` on.
segments_from : Unit, U64 -> List(Segment)
segments_from = |unit, from| unit.segments.drop_first(from)

## Where each unit stands in a phase: a code unit kept from a segment on
## (`places`, past the last when dropped or passed with the program), and how
## many opening labels of a unit of data were taken out (`dropped`).
Standing : { places : List(U64), dropped : List(U64) }

## Where a unit stands kept from in a phase (`Standing.places`).
place_of : Standing, U64 -> U64
place_of = |standing, at| standing.places.get(at) ?? crash "RuntimePosts.place_of: a unit"

## How many opening labels of a unit of data a phase took out.
dropped_of : Standing, U64 -> U64
dropped_of = |standing, at| standing.dropped.get(at) ?? crash "RuntimePosts.dropped_of: a unit"

## The units' count of statements as they stand, by `rest`, a segment's
## count with those after it in its unit, in this phase.
standing_length : Standing, (Segment -> U64) -> U64
standing_length = |standing, rest| {
	var $sum = 0
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.standing_length: a unit"
		from = if unit.code {
			place_of(standing, at)
		} else {
			0
		}
		match unit.segments.get(from) {
			Ok(segment) => {
				$sum = $sum + rest(segment) - (
					if unit.code {
						0
					} else {
						dropped_of(standing, at)
					}
				)
			}
			Err(_) => {}
		}
	}
	$sum
}

## Which of the runtime's labels the units name as they stand (by `names`,
## the numbers of a segment's in this phase), by their numbers.
standing_named : Standing, (Segment -> List(U64)) -> List(Bool)
standing_named = |standing, names| {
	var $named = List.repeat(False, label_count)
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.standing_named: a unit"
		from = if unit.code {
			place_of(standing, at)
		} else {
			0
		}
		for segment in segments_from(unit, from) {
			for number in names(segment) {
				$named = $named.set(
					number,
					True,
				) ?? crash "RuntimePosts.standing_named: a label's number"
			}
		}
	}
	$named
}

## The runtime's labels named, by their numbers, with those of `labels`.
with_named : List(Bool), Set(Str) -> List(Bool)
with_named = |named, labels| {
	var $named = named
	for label in labels {
		match label_numbers.get(label) {
			Ok(number) => {
				$named = $named.set(
					number,
					True,
				) ?? crash "RuntimePosts.with_named: a label's number"
			}
			Err(_) => {}
		}
	}
	$named
}

## Whether the runtime's label of the number is named.
is_named : List(Bool), U64 -> Bool
is_named = |named, number| named.get(number) ?? False

## The labels of `marks` (the units passed with the program) that `named`
## names.
marks_named : List(Bool), List({ label : Str, number : U64 }) -> Set(Str)
marks_named = |named, marks| {
	var $out = Set.empty()
	for { label, number } in marks {
		if is_named(named, number) {
			$out = $out.insert(label)
		}
	}
	$out
}

## A phase of Jumps over the own statements (the program's, the units
## passed with it, the tail's) and the runtime's units done once beside
## them, as `Jumps.thread_jumps` runs it over the whole: round by round, the
## own statements' round (`Jumps.round_threaded`, then `round_dropped`,
## their labels the units name taken as named), each code unit kept from its
## first segment whose label is named by the own statements or by the units
## as they stood (`names`, a segment's after the threading), and the unnamed
## opening labels of each unit of data dropped; the rounds stop when the
## whole's count of statements stays the same, or after 8, as the whole's
## would. `first` is the units' count of statements before the phase, and
## `rest` a segment's count with those after it, after its rounds. `marks`
## are the labels of the units passed with the program.
phase : {
	own_statements : List(Assembly.Statement),
	hops : Dict(Str, Str),
	standing : Standing,
	first : U64,
	names : Segment -> List(U64),
	rest : Segment -> U64,
	marks : List({ label : Str, number : U64 }),
} -> {
	own_statements : List(Assembly.Statement),
	standing : Standing,
	named : Set(Str),
	named_numbers : List(Bool),
}
phase = |
	{
		own_statements,
		hops,
		standing,
		first,
		names,
		rest,
		marks,
	},
| {
	var $own = own_statements
	var $standing = standing
	var $length = own_length(own_statements) + first
	for _ in 0..<Jumps.most_rounds {
		units_named = standing_named($standing, names)
		threaded = Jumps.round_threaded($own, hops)
		own_named = Assembly.named_labels(threaded)
		named = with_named(units_named, own_named)
		beside = marks_named(units_named, marks)
		# The tail follows the runtime's last unit: reached past it when
		# that unit is data with a label named, as `tail_mark` stands for.
		reached = tail_opening_numbers.any(|number| is_named(named, number))
		after = Jumps.round_dropped(
			threaded,
			{
				named: own_named,
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
			if unit.code {
				$from = $from.append(kept_from(unit, { from: place_of($standing, at), named }))
				$dropped = $dropped.append(0)
			} else {
				was_dropped = dropped_of($standing, at)
				now_dropped = opening_dropped(unit, named)
				$from = $from.append(0)
				$dropped = $dropped.append(
					if now_dropped > was_dropped {
						now_dropped
					} else {
						was_dropped
					},
				)
			}
		}
		$own = after
		$standing = { places: $from, dropped: $dropped }
		whole = own_length($own) + standing_length($standing, rest)
		if whole == $length {
			return phase_left({
				own_statements: $own,
				standing: $standing,
				names,
				marks,
			})
		}
		$length = whole
	}
	phase_left({
		own_statements: $own,
		standing: $standing,
		names,
		marks,
	})
}

## The labels of the runtime's last unit when it is data, by their numbers,
## any of which named leaves the tail after it reached.
tail_opening_numbers : List(U64)
tail_opening_numbers =
	match units.last() {
		Ok(unit) if !unit.code => unit.opening_numbers
		_ => []
	}

## The own statements' count, `tail_mark` left out: the whole has none.
own_length : List(Assembly.Statement) -> U64
own_length = |statements| statements.len() - statements.count_if(is_tail_mark)

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

## A phase's end, with what the next passes see as named: of the own
## statements' labels, those the statements left name or a unit names
## (`named`; no other label of the whole's reaches the own statements'
## walks), and the runtime's labels named, by their numbers.
phase_left : {
	own_statements : List(Assembly.Statement),
	standing : Standing,
	names : Segment -> List(U64),
	marks : List({ label : Str, number : U64 }),
} -> {
	own_statements : List(Assembly.Statement),
	standing : Standing,
	named : Set(Str),
	named_numbers : List(Bool),
}
phase_left = |{ own_statements, standing, names, marks }| {
	units_named = standing_named(standing, names)
	own_named = Assembly.named_labels(own_statements)
	{
		own_statements,
		standing,
		named: with_labels(own_named, marks_named(units_named, marks)),
		named_numbers: with_named(units_named, own_named),
	}
}

## Each label the runtime marks, by its number.
label_numbers : Dict(Str, U64)
label_numbers = {
	var $all = Dict.empty()
	for piece in pieces {
		for label in marks_of(piece) {
			$all = $all.insert(label, $all.len())
		}
	}
	$all
}

## How many labels the runtime marks.
label_count : U64
label_count = label_numbers.len()

## The numbers of the labels that are the runtime's, among `labels`.
numbers_of : List(Str) -> List(U64)
numbers_of = |labels| {
	var $out = []
	for label in labels {
		match label_numbers.get(label) {
			Ok(number) => {
				$out = $out.append(number)
			}
			Err(_) => {}
		}
	}
	$out
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
Own : {
	code_statements : List(Assembly.Statement),
	passed : Dict(U64, List(Assembly.Statement)),
	tail_statements : List(Assembly.Statement),
}

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
	{
		code_statements: $code,
		passed: $passed,
		tail_statements: $tail,
	}
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
posts_beside : {
	program_statements : List(Assembly.Statement),
	tail_statements : List(Assembly.Statement),
} -> Try(
	{
		statements : List(Assembly.Statement),
		tries : U64,
		passed : U64,
	},
	[Apart(Str)],
)
posts_beside = |{ program_statements, tail_statements }| {
	tail_ok = tail_statements.all(
		|statement|
			match statement {
				Mark(_) | Data(_) | Distance(_) => True
				_ => False
			},
	)
	if !tail_ok {
		return Err(Apart("the tail holds code"))
	}
	var $passed = seed
	for try in 0..<most_tries {
		match trial_posts({ program_statements, tail_statements, passed: $passed }) {
			Ok(done) => return Ok({
				statements: done,
				tries: try + 1,
				passed: $passed.len(),
			})
			Err(Grow(more)) => {
				$passed = with_units($passed, more)
			}
			Err(Apart(why)) => return Err(Apart(why))
		}
	}
	counts = "${$passed.len().to_str()} of ${units.len().to_str()}"
	Err(Apart("the units passed with the program grew for too long: ${counts}"))
}

## The units passed with the program from a compile's first try: those a
## program of the start, a function's stack check, the calls of a
## property's and a method's lookup (an object's read and a method's call
## lower to them) and a jump to the timers' loop has passed, found when
## js-x86 is built. Most programs pass these and few more, so most compiles
## take one try; a unit passed that would have fit costs only its passes.
seed : Set(U64)
seed = {
	start = Runtime.start_items(seed_main).concat([
		Mark(seed_main),
		JccTo({ condition: B, label: Runtime.stack_overflow }),
	])
	plain = start.append(JmpTo(Runtime.run_timers))
	objects = start.concat([
		CallTo(ObjectTable.get_property_hashed),
		CallTo(ObjectTable.get_method_hashed),
		JmpTo(Runtime.run_timers),
	])
	# A unit holding both code and data (the profiler's return, its path,
	# then `runtime_write`) is always passed with the program: Jumps keeps
	# its data wherever it drops its code, which a unit done once doesn't.
	var $mixed = Set.empty()
	for at in 0..<pieces.len() {
		piece = pieces.get(at) ?? crash "RuntimePosts.seed: a piece"
		if holds_code(piece) and holds_data(piece) {
			$mixed = $mixed.insert(at)
		}
	}
	seed_over([plain, objects], $mixed)
}

## The units passed with each program, each's growth from what the others
## left, until none grows them.
seed_over : List(List(Assembly.Statement)), Set(U64) -> Set(U64)
seed_over = |programs, first| {
	var $passed = first
	for _ in 0..<most_tries {
		before = $passed.len()
		for program in programs {
			$passed = seed_of(program, $passed)
		}
		if $passed.len() == before {
			return $passed
		}
	}
	$passed
}

## The units passed with `program`, from `passed`, or `passed` when its
## passes don't go beside the runtime's.
seed_of : List(Assembly.Statement), Set(U64) -> Set(U64)
seed_of = |program_statements, passed| {
	var $passed = passed
	for _ in 0..<most_tries {
		match trial_posts({ program_statements, tail_statements: [], passed: $passed }) {
			Ok(_) => return $passed
			Err(Grow(more)) => {
				$passed = with_units($passed, more)
			}
			Err(Apart(_)) => return passed
		}
	}
	passed
}

## The empty program's main, for `seed`.
seed_main : Str
seed_main = "runtime_posts_seed_main"

## How many times a compile may grow the units passed with the program.
most_tries : U64
most_tries = 6

## The units of both.
with_units : Set(U64), List(U64) -> Set(U64)
with_units = |one, more_units| {
	var $all = one
	for at in more_units {
		$all = $all.insert(at)
	}
	$all
}

## The post-passes with every unit but `passed` done already, those passed
## with the program; or the units whose passes done once don't fit beside
## this program (`Grow`), or `Apart` naming the rule above it doesn't meet.
trial_posts : {
	program_statements : List(Assembly.Statement),
	tail_statements : List(Assembly.Statement),
	passed : Set(U64),
} -> Try(List(Assembly.Statement), [Apart(Str), Grow(List(U64))])
trial_posts = |{ program_statements, tail_statements, passed }| {
	order = passed_list(passed)
	var $own = program_statements
	var $passed_length = 0
	for at in order {
		piece = pieces.get(at) ?? crash "RuntimePosts.trial_posts: a piece"
		$own = $own.concat(piece)
		$passed_length = $passed_length + piece.len()
	}
	own = $own.append(seam).append(tail_mark).concat(tail_statements)
	var $marks = []
	for at in order {
		piece = pieces.get(at) ?? crash "RuntimePosts.trial_posts: a piece"
		for label in marks_of(piece) {
			$marks = $marks.append({ label, number: label_numbers.get(label) ?? label_count })
		}
	}
	marks = $marks
	var $pieces_length = 0
	for piece in pieces {
		$pieces_length = $pieces_length + piece.len()
	}
	start = {
		places: List.map_with_index(
			units,
			|unit, at|
				if passed.contains(at) {
					unit.segments.len()
				} else {
					0
				},
		),
		dropped: units.map(|_| 0),
	}

	# The first Jumps.
	first = phase({
		own_statements: own,
		hops: first_hops,
		standing: start,
		first: $pieces_length - $passed_length,
		names: |segment| segment.first_names,
		rest: |segment| segment.first_rest,
		marks,
	})
	first_cut = own_cut(first.own_statements)
	# Every unit the first Jumps finds that doesn't fit, found at once, so
	# that a compile tries again as few times as it can.
	apart = units_to_grow(
		ends_apart(
			first_cut,
			{
				standing: first.standing,
				passed,
				last: |unit| unit.first_last,
				length: |segment| segment.first_length,
			},
		),
	)?
	inner = units_to_grow(inner_named(first.standing, first.named_numbers))?

	# Whose address is taken: no pass but Jumps' dropping changes that.
	var $addressed = addressed_of(first.own_statements)
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.trial_posts: a unit"
		from = if unit.code {
			place_of(first.standing, at)
		} else {
			0
		}
		for segment in segments_from(unit, from) {
			for label in segment.addressed_labels {
				$addressed = $addressed.insert(label)
			}
		}
	}
	addressed = $addressed
	var $grow = []
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.trial_posts: a unit"
		if unit.code {
			fits = segments_from(unit, place_of(first.standing, at)).all(
				|segment| segment.reached.all(
					|
						{ label, addressed: was },
					| addressed.contains(label) == was,
				),
			)
			if !fits {
				$grow = $grow.append(at)
			}
		}
	}
	# What the runtime alone found read at a label whose address it took
	# was never walked for: that label's unit is passed with the program.
	for label in jumped_of(first.own_statements) {
		if alone_addressed.contains(label) and !addressed.contains(label) {
			match unit_of.get(label) {
				Ok(at) if !passed.contains(at) => {
					$grow = $grow.append(at)
				}
				_ => {}
			}
		}
	}
	all_grown = apart.concat(inner).concat($grow)
	if !all_grown.is_empty() {
		return Err(Grow(all_grown))
	}

	# Forwarding and Moves.
	own_forwarded = Forwarding.forward_loads_named(first.own_statements, first.named)
	own_moved = Moves.trim_moves_beside(
		own_forwarded,
		{ named: first.named, beside: { addressed, reads: trimmed.reads } },
	)
	reads_held(own_moved.reads, { standing: first.standing, passed, addressed })?
	hops_held(Jumps.hops_of(own_moved.trimmed), { standing: first.standing, passed })?

	# The second Jumps.
	second = phase({
		own_statements: own_moved.trimmed,
		hops: second_hops,
		standing: first.standing,
		first: standing_length(first.standing, |segment| segment.trimmed_rest),
		names: |segment| segment.second_names,
		rest: |segment| segment.trimmed_rest,
		marks,
	})
	second_cut = own_cut(second.own_statements)
	ends_apart(
		second_cut,
		{
			standing: second.standing,
			passed,
			last: |unit| unit.second_last,
			length: |segment| segment.trimmed_length,
		},
	)?

	# The program's code, the units as they stand or as they were passed
	# with it, then the tail.
	var $out = second_cut.code_statements
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.trial_posts: a unit"
		if passed.contains(at) {
			$out = $out.concat(second_cut.passed.get(at) ?? [])
		} else {
			from = if unit.code {
				place_of(second.standing, at)
			} else {
				0
			}
			for segment in segments_from(unit, from) {
				$out = $out.concat(segment.done)
			}
		}
	}
	Ok($out.concat(second_cut.tail_statements.drop_if(is_tail_mark)))
}

## Whether what the own statements' walks found read at the labels of the
## units passed with them is what the runtime alone found, wherever a unit
## done once jumps to one of them.
reads_held : List(Dict(Str, U32)),
{
	standing : Standing,
	passed : Set(U64),
	addressed : Set(Str),
} -> Try({}, [Apart(Str), Grow(List(U64))])
reads_held = |reads, { standing, passed, addressed }| {
	var $grow = []
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.reads_held: a unit"
		if unit.code and !passed.contains(at) {
			for segment in segments_from(unit, place_of(standing, at)) {
				for { label, addressed: _ } in segment.reached {
					passed_to = match unit_of.get(label) {
						Ok(target) => passed.contains(target)
						Err(_) => False
					}
					if passed_to and !addressed.contains(label) {
						same = List.map2(
							reads,
							trimmed.reads,
							|own, alone| own.get(label) == alone.get(label),
						).all(|held| held)
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

## The units a check found that don't fit, or none; a rule no unit's
## passing would meet stays `Apart`.
units_to_grow : Try({}, [Apart(Str), Grow(List(U64))]) -> Try(List(U64), [Apart(Str), Grow(List(U64))])
units_to_grow = |checked|
	match checked {
		Ok({}) => Ok([])
		Err(Grow(more)) => Ok(more)
		Err(Apart(why)) => Err(Apart(why))
	}

## Whether the labels of the units passed with the program hop after Moves
## as they did in the runtime alone, wherever a unit done once jumps to one.
hops_held : Dict(Str, Str),
{
	standing : Standing,
	passed : Set(U64),
} -> Try({}, [Apart(Str), Grow(List(U64))])
hops_held = |hops, { standing, passed }| {
	var $grow = []
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.hops_held: a unit"
		if unit.code and !passed.contains(at) {
			for segment in segments_from(unit, place_of(standing, at)) {
				for { label, addressed: _ } in segment.reached {
					passed_to = match unit_of.get(label) {
						Ok(target) => passed.contains(target)
						Err(_) => False
					}
					hop_moved = hops.get(label) != second_hops.get(label)
					if passed_to and hop_moved and !$grow.contains(at) {
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
ends_apart : Own,
{
	standing : Standing,
	passed : Set(U64),
	last : Unit -> Try(Str, [NoJump]),
	length : Segment -> U64,
} -> Try({}, [Apart(Str), Grow(List(U64))])
ends_apart = |cut, { standing, passed, last, length }| {
	match cut.code_statements.last() {
		Ok(JmpTo(_)) | Ok(Instruction(Ret)) => {}
		_ => return Err(Apart("the program's code doesn't end with a ret or a jmp"))
	}
	# The kept pieces in the whole's order, each with the label of the
	# `jmp` it ends with and the labels it starts with.
	var $kept = [
		{
			piece: Code,
			ending: last_jump(cut.code_statements),
			starting: [],
		},
	]
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.ends_apart: a unit"
		if passed.contains(at) {
			statements = cut.passed.get(at) ?? []
			if !statements.is_empty() {
				$kept = $kept.append({
					piece: Passed(at),
					ending: last_jump(statements),
					starting: leading_marks(statements),
				})
			}
		} else if unit.code {
			from = place_of(standing, at)
			if from < unit.segments.len() {
				$kept = $kept.append({
					piece: Done(at),
					ending: last(unit),
					starting: starting_labels(unit, { from, length }),
				})
			}
		} else {
			$kept = $kept.append({
				piece: Done(at),
				ending: Err(NoJump),
				starting: [],
			})
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

## Whether each kept code unit done once has its labels named as the
## runtime alone took them: the one it is kept from (named, so the runtime
## alone must have taken it so), and each past it but those it starts with,
## which stand beside the first. A unit that doesn't is passed with the
## program (`Grow`).
inner_named : Standing, List(Bool) -> Try({}, [Apart(Str), Grow(List(U64))])
inner_named = |standing, named| {
	var $grow = []
	for at in 0..<units.len() {
		unit = units.get(at) ?? crash "RuntimePosts.inner_named: a unit"
		from = place_of(standing, at)
		if unit.code and from < unit.segments.len() {
			fits = segments_from(unit, from).all(
				|segment| segment.leading or segment.named == is_named(named, segment.number),
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
