## This module assembles a program: a list of instructions, labels and data
## becomes the bytes of one piece of code. A jump, a call or a `lea` may name
## a label instead of an offset; it is written with a placeholder rel32, and
## once every label's place is known, each placeholder is patched to the
## distance from the end of its instruction to the label.
##
## The bytes are built by appending into one list and patched with `set`
## while that list has one owner, so neither pass copies it.
import X86

Assembly :: [].{
	Statement := [
		Instruction(X86.Instruction),

		## A label for the next byte.
		Mark(Str),
		JmpTo(Str),
		JccTo({ condition : X86.Condition, label : Str }),
		CallTo(Str),

		## The label's address, by its distance from the instruction.
		LeaTo({ to : X86.Register, label : Str }),

		## Bytes placed as they are: a string, a table.
		Data(List(U8)),
	]

	## The code for `items`, or the first label one names that none marks,
	## or the first label marked twice.
	assemble : List(Assembly.Statement) -> Try(List(U8), [UnknownLabel(Str), DuplicateLabel(Str)])
	assemble = |items| {
		var $bytes = []
		var $marks = Dict.empty()
		var $fixups = []
		for item in items {
			match item {
				Instruction(instruction) => {
					$bytes = X86.append_instruction($bytes, instruction)
				}
				Mark(label) => {
					if $marks.contains(label) {
						return Err(DuplicateLabel(label))
					}
					$marks = $marks.insert(label, $bytes.len())
				}
				JmpTo(label) => {
					$bytes = X86.append_instruction($bytes, Jmp(0))
					$fixups = $fixups.append({ end: $bytes.len(), label })
				}
				JccTo({ condition, label }) => {
					$bytes = X86.append_instruction($bytes, Jcc({ condition, offset: 0 }))
					$fixups = $fixups.append({ end: $bytes.len(), label })
				}
				CallTo(label) => {
					$bytes = X86.append_instruction($bytes, Call(0))
					$fixups = $fixups.append({ end: $bytes.len(), label })
				}
				LeaTo({ to, label }) => {
					$bytes = X86.append_instruction($bytes, Lea({ to, from: Rip(0) }))
					$fixups = $fixups.append({ end: $bytes.len(), label })
				}
				Data(data) => {
					$bytes = $bytes.concat(data)
				}
			}
		}
		for fixup in $fixups {
			match $marks.get(fixup.label) {
				Ok(target) => {
					$bytes = patched_rel32(
						$bytes,
						{
							end: fixup.end,
							distance: target.to_i64_wrap() - fixup.end.to_i64_wrap(),
						},
					)
				}
				Err(_) => return Err(UnknownLabel(fixup.label))
			}
		}
		Ok($bytes)
	}

	expect Assembly.assemble([
		Mark("top"),
		Instruction(Ret),
		JmpTo("top"),
	]).map_ok(X86.hex_text) == Ok("c3 e9 fa ff ff ff")
	expect Assembly.assemble([
		JccTo({ condition: E, label: "out" }),
		Instruction(Ret),
		Mark("out"),
	]).map_ok(X86.hex_text) == Ok("0f 84 01 00 00 00 c3")
	expect Assembly.assemble([
		CallTo("f"),
		Instruction(Ret),
		Mark("f"),
		Instruction(Ret),
	]).map_ok(X86.hex_text) == Ok("e8 01 00 00 00 c3 c3")
	expect Assembly.assemble([
		LeaTo({ to: Rsi, label: "m" }),
		Mark("m"),
		Data([0x41]),
	]).map_ok(X86.hex_text) == Ok("48 8d 35 00 00 00 00 41")
	expect Assembly.assemble([
		Mark("here"),
		JmpTo("here"),
	]).map_ok(X86.hex_text) == Ok("e9 fb ff ff ff")
	expect Assembly.assemble([JmpTo("nowhere")]) == Err(UnknownLabel("nowhere"))
	expect Assembly.assemble([
		Mark("a"),
		Instruction(Ret),
		Mark("a"),
	]) == Err(DuplicateLabel("a"))
}

## `bytes` with the rel32 that ends at `end` set to `distance`. A program
## is far below the 2 GiB a rel32 reaches, so a distance past it is a bug.
patched_rel32 : List(U8), { end : U64, distance : I64 } -> List(U8)
patched_rel32 = |bytes, { end, distance }| {
	if distance < -2147483648 or distance > 2147483647 {
		crash "Assembly.patched_rel32: a jump past the reach of a rel32"
	}
	field = X86.append_little_endian([], { value: distance, size: 4 })
	var $out = bytes
	for i in 0..<4 {
		byte = field.get(i) ?? crash "Assembly.patched_rel32: a rel32 has four bytes"
		$out = $out.set(
			end - 4 + i,
			byte,
		) ?? crash "Assembly.patched_rel32: the rel32 lies inside the code"
	}
	$out
}
