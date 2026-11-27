## This module holds the heap: its pages, the allocator, the header every
## block carries, and the heap walk that checks every header. Nothing is
## freed yet; x86/COLLECTOR.md is the collector's design, and this is its
## first lane.
##
## **THE HEAP IS 64 KiB PAGES, EACH OF ONE BLOCK SIZE.** A block is 16, 32,
## 64 ... up to 32768 bytes, a power of two, so a page holds 4096 to 2 of
## them and a block starts at an address that is a multiple of its size. A
## block bigger than 32768 bytes takes whole pages of its own, as many as
## it needs, its block starting at its first page. Every block starts with
## its **header**, 8 bytes: its kind (`Heap.BlockKind`'s code, 1 to 13) in the
## top 16 bits and the bytes asked for, rounded up to 8, in the low 48.
## What the allocator answers is the address past the header, so a string's
## length is at the answer, as before, and its header 8 bytes below it.
##
## `r15` holds the heap's state for the whole run (`state_size` bytes,
## mapped with the rest), laid out as these places say: the next free page,
## the first page, the walk's mode, the walk's four counts, then each size
## class's next free block and block size, 16 bytes a class, then the page
## table, one byte a page: 0 a page not taken, 3 to 14 a page of blocks of
## 2 << that many bytes, `large_first` a large block's first page and
## `large_rest` each page after it. The pages start at the first multiple
## of 64 KiB past the state; `r14` is the end of the mapping.
##
## **AN INTERIOR POINTER FINDS ITS BLOCK BY ARITHMETIC** (`Heap.block_start`,
## for the collector's conservative scan): its page is its offset from the
## first page shifted right 16, and the page table names the page's block
## size, so the block's header is the address and-ed with minus the block
## size. A large block's later page walks back the table to its first.
##
## The allocator takes the next block of its size class, a bump through the
## class's page; a class whose page is full (or that has none yet) takes the
## next free page. Each kind has its own entry (`Heap.allocate`), which puts
## the kind's header bits in `rax` before the shared path.
import Assembly
import Emit
import RuntimeBuilders
import X86

Heap :: [].{

	## What a block holds, so a collector can trace it and the heap walk can
	## check it. Every allocation names one.
	BlockKind := [
		# Its length in 8 bytes, then its bytes; no pointer.
		String,
		# An array's record: its length, its capacity and its items' address,
		# then room for its first items, the address pointing past the record.
		Array,
		# An array's items, each a value, once they outgrow the record.
		Items,
		# A plain object's record: its count, its capacity, its entries'
		# address, its table's address and the count the table covers, then
		# room for its first entries, the address pointing past the record.
		Object,
		# An object's entries, 16 bytes each: a key's address and a value.
		Entries,
		# An object's hash table: its mask, then places; no pointer.
		Table,
		# A closure record: two distances, the count of captures, then each
		# capture's cell's address.
		Closure,
		# A captured variable's cell: one value.
		Cell,
		# A Map's or a Set's record: what it is, its size, the entries used,
		# their room and their address, then room for its first entries.
		Collection,
		# A Map's or a Set's entries, 16 bytes each: a key and a value.
		CollectionEntries,
		# An iterator: what it says it is, what it walks, its place and what
		# it gives.
		Iterator,
		# A timer: what it says it is, its time, its callback and the rest
		# `Timers` lays out.
		Timer,
		# A routine's list of strings' addresses, raw, as `join` and
		# console.log keep the texts they put together.
		Texts,
	]

	## Every kind, in the order of their codes.
	kinds : List(Heap.BlockKind)
	kinds = [
		String,
		Array,
		Items,
		Object,
		Entries,
		Table,
		Closure,
		Cell,
		Collection,
		CollectionEntries,
		Iterator,
		Timer,
		Texts,
	]

	## A kind's code in a header's top 16 bits: 1 and on, so no header is 0.
	kind_code : Heap.BlockKind -> I64
	kind_code = |kind|
		match kind {
			String => 1
			Array => 2
			Items => 3
			Object => 4
			Entries => 5
			Table => 6
			Closure => 7
			Cell => 8
			Collection => 9
			CollectionEntries => 10
			Iterator => 11
			Timer => 12
			Texts => 13
		}

	## The routine that takes `rdi` bytes of the heap for a block of `kind`,
	## the address past its header in `rax`. It changes `rax` and `rdi` alone.
	allocate : Heap.BlockKind -> Str
	allocate = |kind| "runtime_allocate_${kind_word(kind)}"

	## The routine that gives the address of the header of the block that
	## holds the address in `rdi` (its header, its contents or the room past
	## them), or 0 when no block taken holds it. It changes `rax`, `rcx` and
	## `rdx`.
	block_start : Str
	block_start = "runtime_block_start"

	## The routine that walks every page block by block and stops the program
	## at the first header that is wrong, counting the blocks, the bytes
	## asked, the bytes their blocks hold and the pages. It changes every
	## general register but `rbx`, `rbp`, `rsp` and `r12` to `r15`.
	walk : Str
	walk = "runtime_heap_walk"

	## Where the allocator goes past the end of the mapping.
	out_of_memory : Str
	out_of_memory = "runtime_out_of_memory"

	## The text the walk stops with.
	bad_header_text : Str
	bad_header_text = "runtime_text_bad_header"

	## The walk's mode, which the start sets from the program's first
	## argument: 0 none, 1 a walk at the exit and at a stop (`heapwalk`), 2
	## a walk and its counts written at the exit (`heapstat`).
	mode_place : X86.Mem
	mode_place = Emit.mem(R15, 16)

	## The walk's counts, which `Heap.walk` sets: the blocks, the bytes asked,
	## the bytes their blocks hold, and the pages taken.
	blocks_place : X86.Mem
	blocks_place = Emit.mem(R15, 24)

	asked_place : X86.Mem
	asked_place = Emit.mem(R15, 32)

	held_place : X86.Mem
	held_place = Emit.mem(R15, 40)

	pages_place : X86.Mem
	pages_place = Emit.mem(R15, 48)

	## The bytes mapped for the state and the heap together: the program
	## stops, out of memory, past them. 2 GiB, where the bump heap had 1:
	## the headers and the size classes' rounding take about 1.35 times the
	## bytes asked (big daddy's day), and big daddy's 300 rounds ask about
	## 900 MB. The mapping reserves nothing (`MAP_NORESERVE`), so only the
	## pages a program touches are memory.
	mapped_size : I64
	mapped_size = 0x80000000

	## The heap's start: with `r15` at the state and `r14` at the mapping's
	## end, the first page placed, each class's block size set, and the
	## walk's mode taken from the first argument (`[rsp + 16]`, at the
	## program's entry). It changes `rax` and `rcx`.
	start_items : List(Assembly.Statement)
	start_items = [
		Emit.lea(Rax, Emit.mem(R15, state_size + page_size - 1)),
		Emit.bit_and_imm(Rax, 0 - page_size),
		Emit.store(next_page_place, Rax),
		Emit.store(first_page_place, Rax),
		Emit.imm(Rax, least_block),
		Emit.lea(Rcx, Emit.mem(R15, classes_place + 8)),
		Emit.mark("runtime_heap_class_sized"),
		Emit.store(Emit.mem(Rcx, 0), Rax),
		Emit.plus_imm(Rcx, 16),
		Emit.plus(Rax, Rax),
		Emit.cmp_imm(Rax, most_block),
		Emit.jcc(Be, "runtime_heap_class_sized"),
		Emit.load(Rcx, Emit.mem(Rsp, 0)),
		Emit.cmp_imm(Rcx, 2),
		Emit.jcc(B, "runtime_heap_moded"),
		Emit.load(Rcx, Emit.mem(Rsp, 16)),
		Emit.byte_load(Rax, Emit.mem(Rcx, 8)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_heap_moded"),
		Emit.load(Rcx, Emit.mem(Rcx, 0)),
		Emit.imm(Rax, word_bits("heapwalk")),
		Emit.cmp(Rcx, Rax),
		Emit.jcc(Ne, "runtime_heap_mode_stat"),
		Emit.imm(Rax, 1),
		Emit.store(Heap.mode_place, Rax),
		Emit.mark("runtime_heap_mode_stat"),
		Emit.imm(Rax, word_bits("heapstat")),
		Emit.cmp(Rcx, Rax),
		Emit.jcc(Ne, "runtime_heap_moded"),
		Emit.imm(Rax, 2),
		Emit.store(Heap.mode_place, Rax),
		Emit.mark("runtime_heap_moded"),
	]

	## Every routine of the heap's: the kinds' entries, the allocator, the
	## block start and the walk.
	items : List(Assembly.Statement)
	items = [entry_items, allocate_items, block_start_items, walk_items].join()
}

## A kind's word in its entry's label.
kind_word : Heap.BlockKind -> Str
kind_word = |kind|
	match kind {
		String => "string"
		Array => "array"
		Items => "items"
		Object => "object"
		Entries => "entries"
		Table => "table"
		Closure => "closure"
		Cell => "cell"
		Collection => "collection"
		CollectionEntries => "collection_entries"
		Iterator => "iterator"
		Timer => "timer"
		Texts => "texts"
	}

## What a kind's code is multiplied by in a header: its place, the top 16
## bits.
kind_place : I64
kind_place = 0x1000000000000

## A page's size, and the bits an address within one takes.
page_size : I64
page_size = 0x10000

page_bits : U8
page_bits = 16

## The least block and the most a page of blocks holds; past it a block
## takes pages of its own. A class is named by its block size's highest
## bit, `least_class` to `most_class`.
least_block : I64
least_block = 16

most_block : I64
most_block = 32768

least_class : I64
least_class = 3

most_class : I64
most_class = 14

## The page table's marks of a large block's pages.
large_first : I64
large_first = 0x80

large_rest : I64
large_rest = 0x81

## The state's places past `r15`, as the module's header lays them out.
next_page_place : X86.Mem
next_page_place = Emit.mem(R15, 0)

first_page_place : X86.Mem
first_page_place = Emit.mem(R15, 8)

classes_place : I64
classes_place = 56

table_place : I64
table_place = classes_place + 16 * (most_class - least_class + 1)

## The page table's room: one byte for each page the mapping could hold.
table_size : I64
table_size = Heap.mapped_size // page_size

state_size : I64
state_size = table_place + table_size

## The place of a class's next free block, the class's offset (its highest
## bit times 16) in `offset`; its block size is 8 bytes on.
class_place : { offset : X86.Register, past : I64 } -> X86.Mem
class_place = |{ offset, past }| Emit.mem_index({
	base: R15,
	index: offset,
	displacement: classes_place - 16 * least_class + past,
})

## The page table's byte of the page whose number is in `index`.
table_entry : X86.Register -> X86.Mem
table_entry = |index| Emit.mem_index({ base: R15, index, displacement: table_place })

## The eight bytes of a word of 8 letters as a little-endian integer.
word_bits : Str -> I64
word_bits = |word| {
	var $last_first = []
	for byte in word.to_utf8() {
		$last_first = [byte].concat($last_first)
	}
	var $bits = 0
	for byte in $last_first {
		$bits = $bits * 256 + byte.to_i64()
	}
	$bits
}

## Each kind's entry: its header bits in `rax`, then the shared path.
entry_items : List(Assembly.Statement)
entry_items = {
	var $out = []
	for kind in Heap.kinds {
		$out = $out.concat([
			Emit.mark(Heap.allocate(kind)),
			Emit.imm(Rax, Heap.kind_code(kind) * kind_place),
			Emit.jmp("runtime_allocate_kind"),
		])
	}
	$out
}

## The allocator: `rdi` rounded up to 8, the header that and the kind in
## `rax` make, and the class whose block holds them both (the highest bit
## of `rdi + 7`, at least 3). A class's next block is taken unless it lies
## at a page's start, which says its page is full or it has none: then a
## page is taken first. A block past the most a page of blocks holds takes
## pages of its own. It keeps every register but `rax` and `rdi`.
allocate_items : List(Assembly.Statement)
allocate_items = [
	Emit.mark("runtime_allocate_kind"),
	Emit.save(Rcx),
	Emit.save(Rdx),
	Emit.plus_imm(Rdi, 7),
	Emit.bit_and_imm(Rdi, -8),
	Emit.lea(Rcx, Emit.mem(Rdi, 7)),
	Instruction(
		AluImm({
			operation: Or,
			to: Rcx,
			value: 8,
		}),
	),
	Instruction(Bsr({ to: Rcx, from: Rcx })),
	Instruction(
		Alu({
			operation: Or,
			to: Rdi,
			from: Rax,
		}),
	),
	Emit.cmp_imm(Rcx, most_class),
	Emit.jcc(A, "runtime_allocate_large"),
	Emit.shl(Rcx, 4),
	Emit.load(Rax, class_place({ offset: Rcx, past: 0 })),
	Emit.mov(Rdx, Rax),
	Emit.bit_and_imm(Rdx, page_size - 1),
	Emit.jcc(E, "runtime_allocate_page"),
	Emit.mark("runtime_allocate_block"),
	Emit.load(Rdx, class_place({ offset: Rcx, past: 8 })),
	Emit.plus(Rdx, Rax),
	Emit.store(class_place({ offset: Rcx, past: 0 }), Rdx),
	Emit.store(Emit.mem(Rax, 0), Rdi),
	Emit.plus_imm(Rax, 8),
	Emit.restore(Rdx),
	Emit.restore(Rcx),
	Emit.ret,
	# A page for the class whose offset is in `rcx`, marked in the table
	# with the class's bit.
	Emit.mark("runtime_allocate_page"),
	Emit.load(Rax, next_page_place),
	Emit.lea(Rdx, Emit.mem(Rax, page_size)),
	Emit.cmp(Rdx, R14),
	Emit.jcc(A, Heap.out_of_memory),
	Emit.store(next_page_place, Rdx),
	Emit.save(Rsi),
	Emit.mov(Rsi, Rax),
	Emit.load(Rdx, first_page_place),
	Emit.minus(Rsi, Rdx),
	Emit.shr(Rsi, page_bits),
	Emit.mov(Rdx, Rcx),
	Emit.shr(Rdx, 4),
	Emit.byte_store(table_entry(Rsi), Dl),
	Emit.restore(Rsi),
	Emit.jmp("runtime_allocate_block"),
	# A large block: the pages its header and its bytes fill, the first
	# marked `large_first` and the rest `large_rest`.
	Emit.mark("runtime_allocate_large"),
	Emit.mov(Rax, Rdi),
	Emit.shl(Rax, 16),
	Emit.shr(Rax, 16),
	Emit.plus_imm(Rax, 8 + page_size - 1),
	Emit.bit_and_imm(Rax, 0 - page_size),
	Emit.load(Rdx, next_page_place),
	Emit.plus(Rax, Rdx),
	Emit.cmp(Rax, R14),
	Emit.jcc(A, Heap.out_of_memory),
	Emit.store(next_page_place, Rax),
	Emit.save(Rsi),
	Emit.mov(Rsi, Rdx),
	Emit.store(Emit.mem(Rsi, 0), Rdi),
	Emit.mov(Rcx, Rax),
	Emit.minus(Rcx, Rsi),
	Emit.shr(Rcx, page_bits),
	Emit.mov(Rax, Rsi),
	Emit.load(Rdx, first_page_place),
	Emit.minus(Rax, Rdx),
	Emit.shr(Rax, page_bits),
	Emit.imm(Rdx, large_first),
	Emit.byte_store(table_entry(Rax), Dl),
	Emit.imm(Rdx, large_rest),
	Emit.mark("runtime_allocate_large_page"),
	Emit.minus_imm(Rcx, 1),
	Emit.jcc(E, "runtime_allocate_large_done"),
	Emit.plus_imm(Rax, 1),
	Emit.byte_store(table_entry(Rax), Dl),
	Emit.jmp("runtime_allocate_large_page"),
	Emit.mark("runtime_allocate_large_done"),
	Emit.lea(Rax, Emit.mem(Rsi, 8)),
	Emit.restore(Rsi),
	Emit.restore(Rdx),
	Emit.restore(Rcx),
	Emit.ret,
]

## `runtime_block_start`: the interior pointer's block, by its page's class
## (the address and-ed with minus the block size), or by walking a large
## block's pages back to its first; 0 for an address in no page taken, or
## in a block not taken yet (its header 0).
block_start_items : List(Assembly.Statement)
block_start_items = [
	Emit.mark(Heap.block_start),
	Emit.load(Rax, first_page_place),
	Emit.cmp(Rdi, Rax),
	Emit.jcc(B, "runtime_block_start_none"),
	Emit.load(Rcx, next_page_place),
	Emit.cmp(Rdi, Rcx),
	Emit.jcc(Ae, "runtime_block_start_none"),
	Emit.mov(Rcx, Rdi),
	Emit.minus(Rcx, Rax),
	Emit.shr(Rcx, page_bits),
	Emit.byte_load(Rdx, table_entry(Rcx)),
	Emit.cmp_imm(Rdx, large_first),
	Emit.jcc(Ae, "runtime_block_start_large"),
	Emit.cmp_imm(Rdx, least_class),
	Emit.jcc(B, "runtime_block_start_none"),
	Emit.shl(Rdx, 4),
	Emit.load(Rdx, class_place({ offset: Rdx, past: 8 })),
	Instruction(Neg(Rdx)),
	Instruction(
		Alu({
			operation: And,
			to: Rdx,
			from: Rdi,
		}),
	),
	Emit.load(Rax, Emit.mem(Rdx, 0)),
	Emit.test(Rax, Rax),
	Emit.jcc(E, "runtime_block_start_none"),
	Emit.mov(Rax, Rdx),
	Emit.ret,
	Emit.mark("runtime_block_start_large"),
	Emit.jcc(E, "runtime_block_start_first"),
	Emit.minus_imm(Rcx, 1),
	Emit.byte_load(Rdx, table_entry(Rcx)),
	Emit.cmp_imm(Rdx, large_first),
	Emit.jmp("runtime_block_start_large"),
	Emit.mark("runtime_block_start_first"),
	Emit.shl(Rcx, page_bits),
	Emit.plus(Rax, Rcx),
	Emit.ret,
	Emit.mark("runtime_block_start_none"),
	Emit.zero(Rax),
	Emit.ret,
]

## `runtime_heap_walk`: each page from the first to the next free one, by
## the table. A page of blocks is walked block by block: each header taken
## is checked (`runtime_heap_block`), and from the first block not taken,
## which must be its class's next block, every header must be 0. A large
## block's header is checked, and each page after its first must be marked
## `large_rest`. Any other mark stops the program. The walk holds the page
## in `r8`, the block in `r9`, its block size in `r10` and the page's end in
## `r11`.
walk_items : List(Assembly.Statement)
walk_items = [
	[
		Emit.mark(Heap.walk),
		Emit.zero(Rax),
		Emit.store(Heap.blocks_place, Rax),
		Emit.store(Heap.asked_place, Rax),
		Emit.store(Heap.held_place, Rax),
		Emit.load(Rax, next_page_place),
		Emit.load(Rcx, first_page_place),
		Emit.minus(Rax, Rcx),
		Emit.shr(Rax, page_bits),
		Emit.store(Heap.pages_place, Rax),
		Emit.load(R8, first_page_place),
		Emit.mark("runtime_heap_walk_page"),
		Emit.load(Rax, next_page_place),
		Emit.cmp(R8, Rax),
		Emit.jcc(Ae, "runtime_heap_walked"),
	],
	page_mark_items,
	[
		Emit.cmp_imm(Rdx, large_first),
		Emit.jcc(E, "runtime_heap_walk_large"),
		Emit.cmp_imm(Rdx, least_class),
		Emit.jcc(B, "runtime_heap_bad"),
		Emit.cmp_imm(Rdx, most_class),
		Emit.jcc(A, "runtime_heap_bad"),
		Emit.shl(Rdx, 4),
		Emit.load(R10, class_place({ offset: Rdx, past: 8 })),
		Emit.mov(R9, R8),
		Emit.lea(R11, Emit.mem(R8, page_size)),
		Emit.mark("runtime_heap_walk_block"),
		Emit.cmp(R9, R11),
		Emit.jcc(Ae, "runtime_heap_walk_paged"),
		Emit.load(Rax, Emit.mem(R9, 0)),
		Emit.test(Rax, Rax),
		Emit.jcc(E, "runtime_heap_walk_rest"),
		# Asked for more than half the block, but in the least class.
		Emit.mov(Rdi, R10),
		Emit.shr(Rdi, 1),
		Emit.cmp_imm(R10, least_block),
		Emit.jcc(Ne, "runtime_heap_walk_least"),
		Emit.zero(Rdi),
		Emit.mark("runtime_heap_walk_least"),
		Emit.call("runtime_heap_block"),
		Emit.plus(R9, R10),
		Emit.jmp("runtime_heap_walk_block"),
		# The first block not taken: its class's next, in no block, and
		# every header after it 0.
		Emit.mark("runtime_heap_walk_rest"),
	],
	page_mark_items,
	[
		Emit.shl(Rdx, 4),
		Emit.load(Rax, class_place({ offset: Rdx, past: 0 })),
		Emit.cmp(R9, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.lea(Rdi, Emit.mem(R9, 8)),
		Emit.call(Heap.block_start),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.mark("runtime_heap_walk_free"),
		Emit.plus(R9, R10),
		Emit.cmp(R9, R11),
		Emit.jcc(Ae, "runtime_heap_walk_paged"),
		Emit.load(Rax, Emit.mem(R9, 0)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.jmp("runtime_heap_walk_free"),
		Emit.mark("runtime_heap_walk_paged"),
		Emit.mov(R8, R11),
		Emit.jmp("runtime_heap_walk_page"),
		# A large block: its pages, which must lie below the next free one,
		# and asked for more than a page of blocks holds and more than the
		# pages but its last.
		Emit.mark("runtime_heap_walk_large"),
		Emit.load(Rax, Emit.mem(R8, 0)),
		Emit.mov(R10, Rax),
		Emit.shl(R10, 16),
		Emit.shr(R10, 16),
		Emit.plus_imm(R10, 8 + page_size - 1),
		Emit.bit_and_imm(R10, 0 - page_size),
		Emit.lea(
			R11,
			Emit.mem_index({
				base: R8,
				index: R10,
				displacement: 0,
			}),
		),
		Emit.load(Rcx, next_page_place),
		Emit.cmp(R11, Rcx),
		Emit.jcc(A, "runtime_heap_bad"),
		Emit.lea(Rdi, Emit.mem(R10, 0 - page_size)),
		Emit.cmp_imm(Rdi, most_block),
		Emit.jcc(Ae, "runtime_heap_walk_most"),
		Emit.imm(Rdi, most_block),
		Emit.mark("runtime_heap_walk_most"),
		Emit.mov(R9, R8),
		Emit.call("runtime_heap_block"),
		Emit.mark("runtime_heap_walk_later"),
		Emit.plus_imm(R8, page_size),
		Emit.cmp(R8, R11),
		Emit.jcc(Ae, "runtime_heap_walk_page"),
	],
	page_mark_items,
	[
		Emit.cmp_imm(Rdx, large_rest),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.jmp("runtime_heap_walk_later"),
		Emit.mark("runtime_heap_walked"),
		Emit.ret,
	],
	block_check_items,
	[Emit.mark("runtime_heap_bad")],
	RuntimeBuilders.stopping_items(Heap.bad_header_text),
].join()

## The page table's mark of the page at `r8`, in `rdx`. It changes `rax`
## and `rcx`.
page_mark_items : List(Assembly.Statement)
page_mark_items = [
	Emit.mov(Rcx, R8),
	Emit.load(Rax, first_page_place),
	Emit.minus(Rcx, Rax),
	Emit.shr(Rcx, page_bits),
	Emit.byte_load(Rdx, table_entry(Rcx)),
]

## `runtime_heap_block`: the header `rax` of the block at `r9`, whose block
## size is `r10`, checked: a kind's code, and asked for more than `rdi`
## bytes with its header and at most the block size. The block's first
## byte past the header and its last byte must each find the block by
## `Heap.block_start`. It counts the block, its bytes asked and its block
## size. It changes `rax`, `rcx`, `rdx` and `rdi`.
block_check_items : List(Assembly.Statement)
block_check_items = [
	Emit.mark("runtime_heap_block"),
	Emit.mov(Rcx, Rax),
	Emit.shr(Rcx, 48),
	Emit.cmp_imm(Rcx, 1),
	Emit.jcc(B, "runtime_heap_bad"),
	Emit.cmp_imm(Rcx, Heap.kinds.len().to_i64_wrap()),
	Emit.jcc(A, "runtime_heap_bad"),
	Emit.shl(Rax, 16),
	Emit.shr(Rax, 16),
	Emit.mov(Rdx, Rax),
	Emit.bit_and_imm(Rdx, 7),
	Emit.jcc(Ne, "runtime_heap_bad"),
	Emit.lea(Rdx, Emit.mem(Rax, 8)),
	Emit.cmp(Rdx, Rdi),
	Emit.jcc(Be, "runtime_heap_bad"),
	Emit.cmp(Rdx, R10),
	Emit.jcc(A, "runtime_heap_bad"),
	Emit.load(Rdx, Heap.asked_place),
	Emit.plus(Rdx, Rax),
	Emit.store(Heap.asked_place, Rdx),
	Emit.load(Rdx, Heap.held_place),
	Emit.plus(Rdx, R10),
	Emit.store(Heap.held_place, Rdx),
	Emit.load(Rdx, Heap.blocks_place),
	Emit.plus_imm(Rdx, 1),
	Emit.store(Heap.blocks_place, Rdx),
	Emit.lea(Rdi, Emit.mem(R9, 8)),
	Emit.call(Heap.block_start),
	Emit.cmp(Rax, R9),
	Emit.jcc(Ne, "runtime_heap_bad"),
	Emit.lea(
		Rdi,
		Emit.mem_index({
			base: R9,
			index: R10,
			displacement: -1,
		}),
	),
	Emit.call(Heap.block_start),
	Emit.cmp(Rax, R9),
	Emit.jcc(Ne, "runtime_heap_bad"),
	Emit.ret,
]

expect Heap.kinds.map(Heap.kind_code) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
expect word_bits("heapwalk") == 0x6b6c617770616568
# The state's places fit before the first page's room, and every
# displacement past `r15` fits 32 bits.
expect state_size == 56 + 16 * 12 + 32768
