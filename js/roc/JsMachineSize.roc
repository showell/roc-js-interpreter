# A probe of the machine's size inline (`Machine.Machine`), for
# tools/machine_size.shale, which reads it with roc-alloc-trace's `where`.
#
#   js-machine-size <passes> <room>
#
# Each pass makes an empty list of machines with room for `room` of them, so
# `where` names the bytes it asked for. Two runs, with room for one and for
# two, differ by one machine's size, whatever header a list carries. Nothing
# here runs a program.
import Machine

main! = |arguments| {
	passes = number_in(arguments.get(0) ?? crash "js-machine-size: usage: js-machine-size <passes> <room>")
	room = number_in(arguments.get(1) ?? crash "js-machine-size: usage: js-machine-size <passes> <room>")
	var $held = 0
	var $i = 0
	while $i < passes {
		$held = $held + machines_with_room(room).len()
		$i = $i + 1
	}
	echo!("machine-size: ${passes.to_str()} passes, ${$held.to_str()} machines held\n")
	Ok({})
}

## An empty list with room for `count` machines, in a function of its own:
## `where` names an allocation by the function that called the builtin, and
## one written in `main!` itself it names by none.
machines_with_room : U64 -> List(Machine.Machine)
machines_with_room = |count| List.with_capacity(count)

# The whole number a command-line argument's digits write.
number_in : Str -> U64
number_in = |text|
	text.to_utf8().fold(0, |accumulated, byte| accumulated * 10 + (byte - '0').to_u64())
