# fibonacci_remainder.roc: x86/kernels/fibonacci_remainder.js in Roc, its
# loop as `var` and `while`, so the shapes match.
# Each size comes from the command line, in the order of the JS file's
# `const` lines, so nothing of the work is known when Roc compiles it: Roc
# runs at compile time any call whose arguments are all known then.

size_given : List(Str), U64 -> U64
size_given = |arguments, place|
	match arguments.get(place) {
		Ok(word) =>
			match U64.from_str(word) {
				Ok(given) => given
				Err(_) => crash "usage: give the kernel's sizes as whole numbers"
			}
		Err(_) => crash "usage: give the kernel's sizes"
	}

prime : U64
prime = 1000000007

main! = |arguments| {
	steps = size_given(arguments, 0)
	var $older = 0
	var $newer = 1
	var $i = 0
	while $i < steps {
		next = ($older + $newer) % prime
		$older = $newer
		$newer = next
		$i = $i + 1
	}
	echo!("${$older.to_str()}\n")
	Ok({})
}
