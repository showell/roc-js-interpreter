# concat.roc: x86/kernels/concat.js in Roc, its loops as `var` and `while`,
# so their shapes match.
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

main! = |arguments| {
	size = size_given(arguments, 0)
	rounds = size_given(arguments, 1)
	var $total = 0
	var $r = 0
	while $r < rounds {
		var $text = ""
		var $i = 0
		while $i < size {
			$text = Str.concat($text, "ab")
			$i = $i + 1
		}
		$total = $total + $text.count_utf8_bytes()
		$r = $r + 1
	}
	echo!("${$total.to_str()}\n")
	Ok({})
}
