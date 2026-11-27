## This module finds a key in an object with many keys by hashing it, where
## a small object's keys are still searched in order. It holds
## `runtime_object_entry`, which every property read and write calls, the
## table it keeps (`runtime_object_index`) and the strings' hash
## (`runtime_text_hash`).
##
## **A key the program writes is hashed ahead of time** (`key_hash`, the
## same FNV-1a as `runtime_text_hash`): a property read, a property write
## and a method's lookup of a name written in the program (`o.k`, `o.k = v`,
## `o.m(...)`) load its hash into `r8` and call `runtime_get_property_hashed`
## or `runtime_set_property_hashed`. On an object these find the key by
## `runtime_object_entry_hashed`, which uses the hash given and skips
## hashing the key's bytes; on anything else they go to
## `runtime_get_property` and `runtime_set_property`, the hash unread. An
## object of fewer than `threshold` keys is searched in order either way.
##
## **An object keeps its entries in order**, as before: they are its
## properties in JavaScript's order, which `Object.keys`, printing and the
## spreads walk. Its header has two more words for the table: 24 bytes in,
## the table's address (0 for none), and 32 bytes in, how many of the
## entries the table covers, from the first.
##
## **The table** is 8 bytes holding its mask (its slots less one, the slots
## a power of two), then its slots, 8 bytes each: an entry's place plus one,
## or 0 for an empty slot. A key's slot is its hash under the mask, and a
## slot taken goes on to the next (linear probing). An object of fewer than
## `threshold` keys has no table, and its keys are searched in order
## (Runtime's `runtime_object_entry_scan`).
##
## **The table is brought up to date when a key is looked up**, never when
## one is set, so no routine that adds an entry needs to know of it:
##
## - Entries added since the table was last brought up to date are put in
##   it then, those past what it covers. A key is only ever appended this
##   way, so nothing else changes.
## - An index key (`"7"`) goes in among the entries, not after them, and
##   the entries after it move up one. `runtime_set_property` then sets the
##   count covered to 0, and the next lookup empties the table and puts every
##   entry in it again.
## - A table more than half full is replaced by one of at least four times
##   the entries' count in slots (32 at least), so a table is allocated once
##   for each doubling, never for a lookup. The old one is left for the
##   collector.
##
## No object loses a key: the subset has no `delete`.
##
## **A method's name is looked up in the class's table first.** A read
## whose key is the name of some class's method (Lowering asks
## `KnownFunctions.is_method_name`) calls `runtime_get_method_hashed`: of an
## instance, it looks in the instance's class's table before the instance's
## own keys, which are its fields, so a method call skips the search of the
## fields it would miss. That is only right while no instance holds an own
## property its class's table also has, so `runtime_set_property`, adding
## a key to an instance, sets `Runtime.shadowed_place` when the table holds
## it, and from then on every such read is the plain one, own keys first.
import Assembly
import Boxing
import Emit
import Heap
import Runtime
import RuntimeBuilders
import X86

ObjectTable :: [].{

	## The routines, laid down with Runtime's.
	items : List(Assembly.Statement)
	items = [
		entry_items,
		index_items,
		hash_items,
		hashed_property_items,
		method_items,
		update_items,
	].join()

	## The routine that reads the property `rsi` of `rdi`, a name some
	## class's method has, as `runtime_get_property_hashed` does: of an
	## instance its class's table first (the module's header).
	get_method_hashed : Str
	get_method_hashed = "runtime_get_method_hashed"

	## The routine that reads the property `rsi` of `rdi` as
	## `runtime_get_property` does, the key's hash in `r8`.
	get_property_hashed : Str
	get_property_hashed = "runtime_get_property_hashed"

	## The routine that sets the property `rsi` of `rdi` to `rdx` as
	## `runtime_set_property` does, the key's hash in `r8`.
	set_property_hashed : Str
	set_property_hashed = "runtime_set_property_hashed"

	## The routine of `o.k++` and its kin: the property `rsi` of `rdi`, its
	## hash in `r8`, read, held to be a number, stepped by the double whose
	## bits are in `rdx` and written back; the answer in `rax` is the old
	## number when `rcx` is 0 (postfix), the new one when it is 1 (prefix).
	update_property_hashed : Str
	update_property_hashed = "runtime_update_property_hashed"

	## The hash `runtime_text_hash` gives the string `text`, as an
	## immediate takes it: worked out ahead of time for a key the program
	## writes.
	key_hash : Str -> I64
	key_hash = |text| {
		var $hash = hash_offset
		for byte in text.to_utf8() {
			$hash = U64.bitwise_xor($hash, byte.to_u64()).times_wrap(hash_prime)
		}
		U64.bitwise_xor($hash, $hash.div_trunc_by(4294967296)).to_i64_wrap()
	}

	expect ObjectTable.key_hash("") == (14695981038468906945).to_i64_wrap()
	expect ObjectTable.key_hash("balance") == 4756422021403512235
	expect ObjectTable.key_hash("acct-217") == 2167080111786900480

	## The count of keys from which an object's keys are found by its table.
	threshold : I64
	threshold = 8
}

## The place in the object's header of its table's address.
table_place : I64
table_place = 24

## The place in the object's header of the count of entries its table
## covers.
covered_place : I64
covered_place = 32

## FNV-1a's 64-bit offset basis and prime.
hash_offset : U64
hash_offset = 0xcbf29ce484222325

hash_prime : U64
hash_prime = 0x100000001b3

## Slot `reg` of the table at `r11`.
slot : X86.Register -> X86.Mem
slot = |reg| Based({
	base: R11,
	index: Scaled({ reg, scale: Times8 }),
	displacement: 8,
})

## `reg` kept to the table's slots: `and` with the mask in `rcx`.
apply_mask : X86.Register -> Assembly.Statement
apply_mask = |reg| Instruction(
	Alu({
		operation: And,
		to: reg,
		from: Rcx,
	}),
)

## `rax` made `rax` xor `r9`, a step of the hash.
fold_r9 : Assembly.Statement
fold_r9 = Instruction(
	Alu({
		operation: Xor,
		to: Rax,
		from: R9,
	}),
)

## `runtime_object_entry`: the address of the value of the key `rsi` (a
## string) in the object `rdi`, or 0, keeping `rsi`;
## `runtime_object_entry_hashed` the same with the key's hash in `r8`. Each
## changes `rax`,
## `rcx`, `rdx`, `rdi` and `r8` to `r11`, as the search in order does.
## `r11` holds the table, `r10` the entries and `r9` the slot, which
## `runtime_text_equal` keeps.
entry_items : List(Assembly.Statement)
entry_items = [
	Emit.mark("runtime_object_entry"),
	Emit.load(R10, Emit.mem(Rdi, 0)),
	Emit.cmp_imm(R10, ObjectTable.threshold),
	Emit.jcc(B, "runtime_object_entry_scan"),
	Emit.call("runtime_object_index"),
	Emit.mov(Rdx, Rsi),
	Emit.call("runtime_text_hash"),
	Emit.jmp("runtime_object_entry_hashed_probe"),
	# The same, the key's hash given in `r8`.
	Emit.mark("runtime_object_entry_hashed"),
	Emit.load(R10, Emit.mem(Rdi, 0)),
	Emit.cmp_imm(R10, ObjectTable.threshold),
	Emit.jcc(B, "runtime_object_entry_scan"),
	Emit.save(R8),
	Emit.call("runtime_object_index"),
	Emit.restore(Rax),
	Emit.mark("runtime_object_entry_hashed_probe"),
	Emit.load(R11, Emit.mem(Rdi, table_place)),
	Emit.load(R10, Emit.mem(Rdi, 16)),
	Emit.load(Rcx, Emit.mem(R11, 0)),
	apply_mask(Rax),
	Emit.mov(R9, Rax),
	Emit.mark("runtime_object_entry_probe"),
	Emit.load(Rax, slot(R9)),
	Emit.test(Rax, Rax),
	Emit.jcc(E, "runtime_object_entry_missing"),
	Emit.minus_imm(Rax, 1),
	Emit.shl(Rax, 4),
	Emit.plus(Rax, R10),
	Emit.save(Rax),
	Emit.load(Rdi, Emit.mem(Rax, 0)),
	Emit.call("runtime_text_equal"),
	Emit.restore(Rdx),
	Emit.test(Rax, Rax),
	Emit.jcc(Ne, "runtime_object_entry_hit"),
	Emit.plus_imm(R9, 1),
	Emit.load(Rcx, Emit.mem(R11, 0)),
	apply_mask(R9),
	Emit.jmp("runtime_object_entry_probe"),
	Emit.mark("runtime_object_entry_hit"),
	Emit.lea(Rax, Emit.mem(Rdx, 8)),
	Emit.ret,
	Emit.mark("runtime_object_entry_missing"),
	Emit.zero(Rax),
	Emit.ret,
]

## `runtime_object_index`: the table of the object `rdi`, of `r10` keys,
## made, grown or brought up to date (the module's header), keeping `rdi`
## and `rsi`; it changes `rax`, `rcx`, `rdx` and `r8` to `r11`.
index_items : List(Assembly.Statement)
index_items = [
	Emit.mark("runtime_object_index"),
	Emit.load(R11, Emit.mem(Rdi, table_place)),
	Emit.test(R11, R11),
	Emit.jcc(E, "runtime_object_index_new"),
	# Half full at most: twice the keys no more than the mask.
	Emit.load(Rcx, Emit.mem(R11, 0)),
	Emit.mov(Rdx, R10),
	Emit.plus(Rdx, Rdx),
	Emit.cmp(Rdx, Rcx),
	Emit.jcc(Be, "runtime_object_index_kept"),
	Emit.mark("runtime_object_index_new"),
	Emit.imm(Rcx, 32),
	Emit.mov(Rdx, R10),
	Emit.shl(Rdx, 2),
	Emit.mark("runtime_object_index_size"),
	Emit.cmp(Rcx, Rdx),
	Emit.jcc(Ae, "runtime_object_index_sized"),
	Emit.plus(Rcx, Rcx),
	Emit.jmp("runtime_object_index_size"),
	Emit.mark("runtime_object_index_sized"),
	Emit.save(Rdi),
	Emit.save(Rcx),
	Emit.mov(Rdi, Rcx),
	Emit.shl(Rdi, 3),
	Emit.plus_imm(Rdi, 8),
	Emit.call(Heap.allocate(Table)),
	Emit.restore(Rcx),
	Emit.restore(Rdi),
	Emit.minus_imm(Rcx, 1),
	Emit.store(Emit.mem(Rax, 0), Rcx),
	Emit.store(Emit.mem(Rdi, table_place), Rax),
	Emit.zero(Rdx),
	Emit.store(Emit.mem(Rdi, covered_place), Rdx),
	Emit.mark("runtime_object_index_kept"),
	Emit.load(R11, Emit.mem(Rdi, table_place)),
	Emit.load(R9, Emit.mem(Rdi, covered_place)),
	Emit.cmp(R9, R10),
	Emit.jcc(E, "runtime_object_index_done"),
	Emit.test(R9, R9),
	Emit.jcc(Ne, "runtime_object_index_fill"),
	# Covering nothing: every slot emptied first, since the table may hold
	# the entries' old places.
	Emit.load(Rcx, Emit.mem(R11, 0)),
	Emit.zero(Rdx),
	Emit.zero(R8),
	Emit.mark("runtime_object_index_clear"),
	Emit.cmp(R8, Rcx),
	Emit.jcc(A, "runtime_object_index_fill"),
	Emit.store(slot(R8), Rdx),
	Emit.plus_imm(R8, 1),
	Emit.jmp("runtime_object_index_clear"),
	# Each entry from `r9`, the first not covered, to the last.
	Emit.mark("runtime_object_index_fill"),
	Emit.cmp(R9, R10),
	Emit.jcc(Ae, "runtime_object_index_filled"),
	Emit.load(Rdx, Emit.mem(Rdi, 16)),
	Emit.mov(R8, R9),
	Emit.shl(R8, 4),
	Emit.plus(Rdx, R8),
	Emit.load(Rdx, Emit.mem(Rdx, 0)),
	Emit.call("runtime_text_hash"),
	Emit.load(Rcx, Emit.mem(R11, 0)),
	apply_mask(Rax),
	Emit.mark("runtime_object_index_probe"),
	Emit.load(R8, slot(Rax)),
	Emit.test(R8, R8),
	Emit.jcc(E, "runtime_object_index_put"),
	Emit.plus_imm(Rax, 1),
	apply_mask(Rax),
	Emit.jmp("runtime_object_index_probe"),
	Emit.mark("runtime_object_index_put"),
	Emit.mov(R8, R9),
	Emit.plus_imm(R8, 1),
	Emit.store(slot(Rax), R8),
	Emit.plus_imm(R9, 1),
	Emit.jmp("runtime_object_index_fill"),
	Emit.mark("runtime_object_index_filled"),
	Emit.store(Emit.mem(Rdi, covered_place), R10),
	Emit.mark("runtime_object_index_done"),
	Emit.ret,
]

## `runtime_text_hash`: FNV-1a of the bytes of the string `rdx`, its top
## half folded into its bottom, in `rax`. It keeps every other register.
hash_items : List(Assembly.Statement)
hash_items = [
	Emit.mark("runtime_text_hash"),
	Emit.save(Rcx),
	Emit.save(R8),
	Emit.save(R9),
	Emit.imm(Rax, hash_offset.to_i64_wrap()),
	Emit.load(Rcx, Emit.mem(Rdx, 0)),
	Emit.zero(R8),
	Emit.mark("runtime_text_hash_byte"),
	Emit.cmp(R8, Rcx),
	Emit.jcc(Ae, "runtime_text_hash_done"),
	Emit.byte_load(
		R9,
		Emit.mem_index({
			base: Rdx,
			index: R8,
			displacement: 8,
		}),
	),
	fold_r9,
	Emit.imm(R9, hash_prime.to_i64_wrap()),
	Instruction(Imul({ to: Rax, from: R9 })),
	Emit.plus_imm(R8, 1),
	Emit.jmp("runtime_text_hash_byte"),
	Emit.mark("runtime_text_hash_done"),
	Emit.mov(R9, Rax),
	Emit.shr(R9, 32),
	fold_r9,
	Emit.restore(R9),
	Emit.restore(R8),
	Emit.restore(Rcx),
	Emit.ret,
]

## `runtime_get_property_hashed` and `runtime_set_property_hashed`: on an
## object, the key `rsi` found by its hash in `r8`, its value read into `rax`
## (`undefined` for none) or set to `rdx` (a key not there added by
## `runtime_set_property`'s own way); on any other value, Runtime's routine
## of the same name without the hash, which reads none.
hashed_property_items : List(Assembly.Statement)
hashed_property_items =
	[Emit.mark(ObjectTable.get_property_hashed)]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.object_tag), Emit.jcc(Ne, Runtime.get_property)])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.save(Rdi),
			Emit.save(R8),
			Emit.call("runtime_object_entry_hashed"),
			Emit.restore(R8),
			Emit.restore(Rdi),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_get_inherited_hashed"),
			Emit.load(Rax, Emit.mem(Rax, 0)),
			Emit.ret,
		])
		.concat(inherited_items({ label: "runtime_get_inherited", entry: "runtime_object_entry" }))
		.concat(
			inherited_items({
				label: "runtime_get_inherited_hashed",
				entry: "runtime_object_entry_hashed",
			}),
		)
		.concat([Emit.mark(ObjectTable.set_property_hashed)])
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([Emit.cmp_imm(Rcx, Boxing.object_tag), Emit.jcc(Ne, Runtime.set_property)])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.save(Rdi),
			Emit.save(Rdx),
			Emit.call("runtime_object_entry_hashed"),
			Emit.restore(Rdx),
			Emit.restore(Rdi),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_set_property_new"),
			Emit.store(Emit.mem(Rax, 0), Rdx),
			Emit.ret,
		])

## At `label`, the key `rsi` the object `rdi` (unboxed) lacks: `undefined`,
## unless the object is a class's instance, whose first entry, its mark,
## holds its class's table; then the key is looked up there by `entry`
## (`r8` the key's hash for the hashed one), the table's own keys alone.
inherited_items : { label : Str, entry : Str } -> List(Assembly.Statement)
inherited_items = |{ label, entry }|
	[Emit.mark(label)]
		.concat(RuntimeBuilders.instance_jump_items("${label}_table"))
		.concat([
			Emit.jmp("runtime_get_undefined"),
			Emit.mark("${label}_table"),
			Emit.load(Rdi, Emit.mem(Rdi, 16)),
			Emit.load(Rdi, Emit.mem(Rdi, 8)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.call(entry),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_get_undefined"),
			Emit.load(Rax, Emit.mem(Rax, 0)),
			Emit.ret,
		])

## `runtime_get_method_hashed`: the key `rsi`, hashed in `r8`, of `rdi`.
## Of an instance, while no method was ever shadowed, its class's table
## first; then, or of anything else, `runtime_get_property_hashed`.
method_items : List(Assembly.Statement)
method_items =
	[Emit.mark(ObjectTable.get_method_hashed)]
		.concat(RuntimeBuilders.tag_load_items(Rdi))
		.concat([
			Emit.cmp_imm(Rcx, Boxing.object_tag),
			Emit.jcc(Ne, Runtime.get_property),
			Emit.load(Rcx, Runtime.shadowed_place),
			Emit.test(Rcx, Rcx),
			Emit.jcc(Ne, ObjectTable.get_property_hashed),
			Emit.save(Rdi),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat(RuntimeBuilders.instance_jump_items("runtime_get_method_table"))
		.concat([
			Emit.restore(Rdi),
			Emit.jmp(ObjectTable.get_property_hashed),
			Emit.mark("runtime_get_method_table"),
			Emit.load(Rdi, Emit.mem(Rdi, 16)),
			Emit.load(Rdi, Emit.mem(Rdi, 8)),
		])
		.concat(RuntimeBuilders.unboxed_items(Rdi))
		.concat([
			Emit.save(R8),
			Emit.call("runtime_object_entry_hashed"),
			Emit.restore(R8),
			Emit.restore(Rdi),
			Emit.test(Rax, Rax),
			Emit.jcc(E, ObjectTable.get_property_hashed),
			Emit.load(Rax, Emit.mem(Rax, 0)),
			Emit.ret,
		])

## `runtime_update_property_hashed`, a read and a write of the property as
## `o.k` and `o.k = v` make them, the number between stepped. Its frame holds
## the receiver (`[rbp - 8]`), the key (16), its hash (24), the step (32),
## the fixity (40) and the answer (48).
update_items : List(Assembly.Statement)
update_items = [
	Emit.mark(ObjectTable.update_property_hashed),
	Emit.save(Rbp),
	Emit.mov(Rbp, Rsp),
	Emit.minus_imm(Rsp, 48),
	Emit.store(RuntimeBuilders.local(8), Rdi),
	Emit.store(RuntimeBuilders.local(16), Rsi),
	Emit.store(RuntimeBuilders.local(24), R8),
	Emit.store(RuntimeBuilders.local(32), Rdx),
	Emit.store(RuntimeBuilders.local(40), Rcx),
	Emit.call(ObjectTable.get_property_hashed),
	Emit.call(Runtime.check_number),
	Emit.store(RuntimeBuilders.local(48), Rax),
	Emit.to_xmm(Xmm0, Rax),
	Emit.load(Rax, RuntimeBuilders.local(32)),
	Emit.to_xmm(Xmm1, Rax),
	Emit.double_sum(Xmm0, Xmm1),
	Instruction(MovqFromXmm({ to: Rdx, from: Xmm0 })),
	Emit.load(Rcx, RuntimeBuilders.local(40)),
	Emit.test(Rcx, Rcx),
	Emit.jcc(E, "runtime_update_property_answered"),
	Emit.store(RuntimeBuilders.local(48), Rdx),
	Emit.mark("runtime_update_property_answered"),
	Emit.load(Rdi, RuntimeBuilders.local(8)),
	Emit.load(Rsi, RuntimeBuilders.local(16)),
	Emit.load(R8, RuntimeBuilders.local(24)),
	Emit.call(ObjectTable.set_property_hashed),
	Emit.load(Rax, RuntimeBuilders.local(48)),
	Emit.mov(Rsp, Rbp),
	Emit.restore(Rbp),
	Emit.ret,
]
