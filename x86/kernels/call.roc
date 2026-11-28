# call.roc: x86/kernels/call.js in Roc, its loop as `var` and `while`, so
# the shapes match.
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

## One step of the mix, a function of its own because the kernel is a
## small function called in a loop.
mix : U64, U64 -> U64
mix = |state, step| (state * 31 + step) % 65536

main! = |arguments| {
	calls = size_given(arguments, 0)
	var $state = 0
	var $i = 0
	while $i < calls {
		$state = mix($state, $i)
		$i = $i + 1
	}
	echo!("${$state.to_str()}\n")
	Ok({})
}
