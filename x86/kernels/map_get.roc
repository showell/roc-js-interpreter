# map_get.roc: x86/kernels/map_get.js in Roc, the Map a Dict and the loops
# `var` and `while`, so their shapes match.
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

## The value under `key`, a function of its own because the JS reads it in
## one expression, so the two loops keep one shape.
value_at : Dict(U64, U64), U64 -> U64
value_at = |values, key|
	match values.get(key) {
		Ok(value) => value
		Err(_) => crash "no value at ${key.to_str()}"
	}

main! = |arguments| {
	keys = size_given(arguments, 0)
	lookups = size_given(arguments, 1)
	var $values = Dict.empty()
	var $k = 0
	while $k < keys {
		$values = $values.insert($k, $k * 3)
		$k = $k + 1
	}
	var $sum = 0
	var $i = 0
	while $i < lookups {
		$sum = $sum + value_at($values, $i % keys)
		$i = $i + 1
	}
	echo!("${$sum.to_str()}\n")
	Ok({})
}
