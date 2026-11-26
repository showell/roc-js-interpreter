# fib_race.roc: x86/race/fib_race.js in Roc, line for line: compute F(N),
# the Nth Fibonacci number, and print it. The numbers are lists of base-10^7
# limbs, least significant first, and a step adds one into the other; Roc
# writes a list in place when nothing else refers to it, so each step's
# `add_into` updates its list where it is, as the JS's push and store do.
# It prints the same lines as the JS, so x86/race.shale's checks hold it
# the same way. Built with --opt=speed for the race.

base : U64
base = 10000000

f100 : Str
f100 = "354224848179261915075"

# A limb of `limbs`; the race's indexes are always in range.
limb : List(U64), U64 -> U64
limb = |limbs, i|
	match limbs.get(i) {
		Ok(x) => x
		Err(_) => crash "fib_race: a limb past the end"
	}

# a += b; b at least as long as a and no longer than a + 1 (b is the
# larger number). The common part, where both have a limb, is a loop of its
# own, then b's one limb past a's end and the carry's tail.
add_into : List(U64), List(U64) -> List(U64)
add_into = |a, b| {
	a_length = a.len()
	b_length = b.len()
	var $a = a
	var $carry = 0
	var $i = 0
	while $i < a_length {
		s = limb($a, $i) + limb(b, $i) + $carry
		$carry = if (s >= base) 1 else 0
		$a = match $a.set($i, s - $carry * base) {
			Ok(next) => next
			Err(_) => crash "fib_race: a limb past the end"
		}
		$i = $i + 1
	}
	while $i < b_length {
		s = limb(b, $i) + $carry
		$carry = if (s >= base) 1 else 0
		$a = $a.append(s - $carry * base)
		$i = $i + 1
	}
	if ($carry > 0) $a.append($carry) else $a
}

# The number's decimal digits as bytes: the top limb as it is, then each
# lower limb as exactly seven digits.
digits_of : List(U64) -> List(U8)
digits_of = |limbs| {
	top = limbs.len() - 1
	var $out = limb(limbs, top).to_str().to_utf8()
	var $i = top
	while $i > 0 {
		$i = $i - 1
		x = limb(limbs, $i)
		var $place = 1000000
		while $place > 0 {
			$out = $out.append(48 + ((x // $place) % 10).to_u8_wrap())
			$place = $place // 10
		}
	}
	$out
}

text : List(U8) -> Str
text = |bytes|
	match Str.from_utf8(bytes) {
		Ok(s) => s
		Err(_) => crash "fib_race: digits are ASCII"
	}

# F(n), from lo = F(0) and hi = F(1), one step at a time: a step adds lo
# into hi's place and the two swap names. F(100)'s and F(1000)'s digits are
# kept as the run passes them.
Run : { hi : List(U64), digits100 : List(U8), digits1000 : List(U8) }

race : U64 -> Run
race = |count| {
	var $lo = [0]
	var $hi = [1]
	var $m = 1
	var $digits100 = []
	var $digits1000 = []
	while $m < count {
		sum = add_into($lo, $hi)
		$lo = $hi
		$hi = sum
		$m = $m + 1
		$digits100 = if ($m == 100) digits_of($hi) else $digits100
		$digits1000 = if ($m == 1000) digits_of($hi) else $digits1000
	}
	{ hi: $hi, digits100: $digits100, digits1000: $digits1000 }
}

# N comes from the command line, so that nothing of the race is known when
# the program is compiled: Roc runs at compile time any call whose arguments
# are all known then.
main! = |arguments| {
	count = match arguments.get(0) {
		Ok(word) =>
			match U64.from_str(word) {
				Ok(x) if x >= 1000 => x
				_ => crash "usage: fib_race N, N at least 1000"
			}
		Err(_) => crash "usage: fib_race N, N at least 1000"
	}
	done = race(count)
	digits100 = text(done.digits100)
	digits = digits_of(done.hi)
	length = digits.len()
	if (digits100 == f100) echo!("F(100) is ${f100}, as expected\n") else echo!("F(100) is ${digits100}, not ${f100}\n")
	echo!("F(1000) ends ${text(done.digits1000.sublist({ start: done.digits1000.len() - 12, len: 12 }))}\n")
	echo!("F(${count.to_str()}): ${length.to_str()} digits\n")
	first = text(digits.sublist({ start: 0, len: 20 }))
	last = text(digits.sublist({ start: length - 20, len: 20 }))
	echo!("first digits ${first}, last digits ${last}\n")
	echo!("${text(digits)}\n")
	Ok({})
}
