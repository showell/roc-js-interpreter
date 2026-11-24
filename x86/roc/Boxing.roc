## This module holds the layout of a value's 8 bytes, NaN-boxed, which the
## lowering and the runtime share.
##
## A number is its IEEE double, as it is. Any other value is a NaN no
## arithmetic makes: its top 16 bits are a tag from 0xFFF9 up, and its low
## 48 a payload, a pointer or a constant. The doubles x86-64 makes as NaNs
## are 0x7FF8... (`NaN`) and 0xFFF8... (`0 / 0`), both below every tag, so a
## value is a number exactly when it is below `Boxing.first_tag` shifted
## into place, one unsigned compare.
##
## | top 16 bits | value | low 48 bits |
## |---|---|---|
## | below 0xFFF9 | a number | (the double's) |
## | 0xFFF9 | `undefined`, `null`, `false`, `true` | 0, 1, 2, 3 |
## | 0xFFFA | a string | its address |
## | 0xFFFB | an array | its address |
## | 0xFFFC | a plain object | its address |
##
## Every value has these bits wherever it is held, so a kind known before
## the program runs costs no conversion where two ways meet and the kind
## becomes unknown; a known kind only lets the code skip the tag's test.
Boxing :: [].{

	## The tag of `undefined`, `null` and the booleans, and the least tag:
	## a value whose top 16 bits are below it is a number.
	first_tag : I64
	first_tag = 0xFFF9

	string_tag : I64
	string_tag = 0xFFFA

	array_tag : I64
	array_tag = 0xFFFB

	object_tag : I64
	object_tag = 0xFFFC

	## How far a tag is shifted into a value's top bits.
	tag_shift : U8
	tag_shift = 48

	undefined_bits : I64
	undefined_bits = constant_bits(0)

	null_bits : I64
	null_bits = constant_bits(1)

	false_bits : I64
	false_bits = constant_bits(2)

	true_bits : I64
	true_bits = constant_bits(3)

	## A tag in its place: the bits a pointer is or-ed with to box it.
	tag_bits : I64 -> I64
	tag_bits = |tag| (tag.to_u64_wrap() * 0x1000000000000).to_i64_wrap()

	expect Boxing.true_bits == -1970324836974589
	expect Boxing.tag_bits(Boxing.string_tag).to_u64_wrap() == 0xFFFA000000000000
	expect Boxing.false_bits.to_u64_wrap() == 0xFFF9000000000002
}

constant_bits : I64 -> I64
constant_bits = |payload| Boxing.tag_bits(Boxing.first_tag) + payload
