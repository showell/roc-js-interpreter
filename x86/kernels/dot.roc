# dot.roc: x86/kernels/dot.js in Roc, its loops as `var` and `while`, so
# their shapes match.
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

real_at : List(F64), U64 -> F64
real_at = |items, place|
	match items.get(place) {
		Ok(item) => item
		Err(_) => crash "no item at ${place.to_str()}"
	}

main! = |arguments| {
	size = size_given(arguments, 0)
	rounds = size_given(arguments, 1)
	var $x = []
	var $y = []
	var $i = 0
	while $i < size {
		$x = $x.append(($i % 17).to_f64() * 0.5)
		$y = $y.append(($i % 13).to_f64() * 0.25)
		$i = $i + 1
	}
	var $total = 0.0
	var $r = 0
	while $r < rounds {
		var $j = 0
		while $j < $x.len() {
			$total = $total + real_at($x, $j) * real_at($y, $j)
			$j = $j + 1
		}
		$r = $r + 1
	}
	eighths = match ($total * 8.0).to_u64_try() {
		Ok(whole) => whole
		Err(_) => crash "the total times 8 is no whole number"
	}
	echo!("${eighths.to_str()}\n")
	Ok({})
}
