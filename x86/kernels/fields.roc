# fields.roc: x86/kernels/fields.js in Roc, the object a record and the
# loop `var` and `while`, so the shapes match.
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
	steps = size_given(arguments, 0)
	var $point = { x: 0, y: 0 }
	var $i = 0
	while $i < steps {
		$point = { ..$point, x: $point.x + $i % 7 }
		$point = { ..$point, y: $point.y + $point.x % 5 }
		$i = $i + 1
	}
	echo!("${($point.x + $point.y).to_str()}\n")
	Ok({})
}
