# The fourteen race, x86/fourteen/fourteen.js, in Roc: the Nibble machine as
# one function, f : {0,1}^14 -> {0,1}, run over all 16,384 points N times.
# `step` and `f` are cook-levin-riff's roc/Fourteen.roc, which fourteen.js
# was written from: the 14 bits are a number below 2^14, the top 2 bits the
# input, where AX starts, and the low 12 the program, six lines of two bits,
# line 1 the highest pair (nada 00, zero 01, decr 10, mod2 11). Each round
# counts the points where f is 1, which is 5,596, and it prints the same
# three lines as the JS, so x86/fourteen.shale holds it the same way. Built
# with --opt=speed for the race.

point_count : U64
point_count = 16384

# The points where f is 1, as the C's cross-check counts.
wanted_count : U64
wanted_count = 5596

## A Nibble machine's run: still going, with AX, or done.
Run : [Going(U64), Accepted, Rejected]

## One line: `zero` accepts at 0, `decr` rejects at 0 or takes 1 from AX,
## `mod2` keeps AX's low bit, `nada` does nothing. A run that is done stays
## done.
step : Run, U64 -> Run
step = |run, operation|
	match run {
		Going(ax) =>
			if operation == 1 and ax == 0 {
				Accepted
			} else if operation == 2 and ax == 0 {
				Rejected
			} else if operation == 2 {
				Going(ax - 1)
			} else if operation == 3 {
				Going(ax % 2)
			} else {
				run
			}
		Accepted | Rejected => run
	}

## f itself: true when the program accepts the input. A run that gets past
## line 6 still going rejects.
is_accepted : U64 -> Bool
is_accepted = |bits| {
	input = bits // 4096
	program = bits % 4096
	# Each line's two bits, line 1 first: 4^5, 4^4, ... 4^0.
	places = [1024, 256, 64, 16, 4, 1]
	places.fold(Going(input), |run, place| step(run, (program // place) % 4)) == Accepted
}

# N comes from the command line, so that nothing of the race is known when
# the program is compiled: Roc runs at compile time any call whose arguments
# are all known then.
main! = |arguments| {
	rounds = match arguments.get(0) {
		Ok(word) =>
			match U64.from_str(word) {
				Ok(given) if given >= 1 => given
				_ => crash "usage: fourteen N, N at least 1"
			}
		Err(_) => crash "usage: fourteen N, N at least 1"
	}
	var $total = 0
	var $wrong = 0
	var $first = 0
	for round in 0..<rounds {
		var $count = 0
		for bits in 0..<point_count {
			if is_accepted(bits) {
				$count = $count + 1
			}
		}
		if round == 0 {
			$first = $count
		}
		if $count != wanted_count {
			$wrong = $wrong + 1
		}
		$total = $total + $count
	}
	echo!("f is 1 at ${$first.to_str()} of ${point_count.to_str()} points\n")
	echo!("${rounds.to_str()} rounds, ${$total.to_str()} points where f is 1 in all\n")
	verdict = if $wrong == 0 {
		"PASS"
	} else {
		"FAIL: ${$wrong.to_str()} rounds counted another number"
	}
	echo!("${verdict}\n")
	Ok({})
}
