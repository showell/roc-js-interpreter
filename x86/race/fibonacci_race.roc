# The Fibonacci race, x86/race/fib_race.js, in Roc, line for line: compute
# F(N), the Nth Fibonacci number, and print it. The numbers are lists of base-10^7
# limbs, least significant first, and a step adds one into the other; Roc
# writes a list in place when nothing else refers to it, so each step's
# `add_into` updates its list where it is, as the JS's push and store do.
# It prints the same lines as the JS, so x86/race.shale's checks hold it
# the same way. Built with --opt=speed for the race. The JS's names are
# spelled out here (its `a` and `b` are `total_limbs` and `addend_limbs`,
# its `lo` and `hi` are `smaller` and `larger`).

base : U64
base = 10000000

f100 : Str
f100 = "354224848179261915075"

# A limb of `limbs`; the race's indexes are always in range.
limb : List(U64), U64 -> U64
limb = |limbs, place|
	match limbs.get(place) {
		Ok(found) => found
		Err(_) => crash "fib_race: a limb past the end"
	}

# total += addend; addend at least as long as total and no longer than
# total + 1 (addend is the larger number). The common part, where both
# have a limb, is a loop of its own, then addend's one limb past total's
# end and the carry's tail.
add_into : List(U64), List(U64) -> List(U64)
add_into = |total_limbs, addend_limbs| {
	total_length = total_limbs.len()
	addend_length = addend_limbs.len()
	var $total = total_limbs
	var $carry = 0
	var $place = 0
	while $place < total_length {
		limb_sum = limb($total, $place) + limb(addend_limbs, $place) + $carry
		$carry = if limb_sum >= base {
			1
		} else {
			0
		}
		$total = match $total.set($place, limb_sum - $carry * base) {
			Ok(next) => next
			Err(_) => crash "fib_race: a limb past the end"
		}
		$place = $place + 1
	}
	while $place < addend_length {
		limb_sum = limb(addend_limbs, $place) + $carry
		$carry = if limb_sum >= base {
			1
		} else {
			0
		}
		$total = $total.append(limb_sum - $carry * base)
		$place = $place + 1
	}
	if $carry > 0 {
		$total.append($carry)
	} else {
		$total
	}
}

# The number's decimal digits as bytes: the top limb as it is, then each
# lower limb as exactly seven digits.
digits_of : List(U64) -> List(U8)
digits_of = |limbs| {
	top = limbs.len() - 1
	var $out = limb(limbs, top).to_str().to_utf8()
	var $place = top
	while $place > 0 {
		$place = $place - 1
		lower = limb(limbs, $place)
		var $power = 1000000
		while $power > 0 {
			$out = $out.append(48 + ((lower // $power) % 10).to_u8_wrap())
			$power = $power // 10
		}
	}
	$out
}

text : List(U8) -> Str
text = |bytes|
	match Str.from_utf8(bytes) {
		Ok(decoded) => decoded
		Err(_) => crash "fib_race: digits are ASCII"
	}

# What the race ends with: F(N)'s limbs, and F(100)'s and F(1000)'s digits,
# kept as the run passed them.
Finish : {
	larger_limbs : List(U64),
	digits100 : List(U8),
	digits1000 : List(U8),
}

# F(n), from smaller = F(0) and larger = F(1), one step at a time: a step
# adds smaller into larger's place and the two swap names.
race : U64 -> Finish
race = |count| {
	var $smaller = [0]
	var $larger = [1]
	var $m = 1
	var $digits100 = []
	var $digits1000 = []
	while $m < count {
		sum = add_into($smaller, $larger)
		$smaller = $larger
		$larger = sum
		$m = $m + 1
		$digits100 = if $m == 100 {
			digits_of($larger)
		} else {
			$digits100
		}
		$digits1000 = if $m == 1000 {
			digits_of($larger)
		} else {
			$digits1000
		}
	}
	{
		larger_limbs: $larger,
		digits100: $digits100,
		digits1000: $digits1000,
	}
}

# N comes from the command line, so that nothing of the race is known when
# the program is compiled: Roc runs at compile time any call whose arguments
# are all known then.
main! = |arguments| {
	count = match arguments.get(0) {
		Ok(word) =>
			match U64.from_str(word) {
				Ok(given) if given >= 1000 => given
				_ => crash "usage: fib_race N, N at least 1000"
			}
		Err(_) => crash "usage: fib_race N, N at least 1000"
	}
	done = race(count)
	digits100 = text(done.digits100)
	digits = digits_of(done.larger_limbs)
	length = digits.len()
	if digits100 == f100 {
		echo!("F(100) is ${f100}, as expected\n")
	} else {
		echo!("F(100) is ${digits100}, not ${f100}\n")
	}
	ends1000 = text(done.digits1000.sublist({ start: done.digits1000.len() - 12, len: 12 }))
	echo!("F(1000) ends ${ends1000}\n")
	echo!("F(${count.to_str()}): ${length.to_str()} digits\n")
	first = text(digits.sublist({ start: 0, len: 20 }))
	last = text(digits.sublist({ start: length - 20, len: 20 }))
	echo!("first digits ${first}, last digits ${last}\n")
	echo!("${text(digits)}\n")
	Ok({})
}
