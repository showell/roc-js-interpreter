## This module holds the heap and its collector: the pages, the allocator,
## the header every block carries, the mark and the sweep, and the heap walk
## that checks every header and every free list. x86/COLLECTOR.md is the
## collector's design.
##
## **THE HEAP IS 64 KiB PAGES, EACH OF ONE BLOCK SIZE.** A block is 16, 32,
## 64 ... up to 32768 bytes, a power of two, so a page holds 4096 to 2 of
## them and a block starts at an address that is a multiple of its size. A
## block bigger than 32768 bytes takes whole pages of its own, as many as
## it needs, its block starting at its first page. Every block starts with
## its **header**, 8 bytes: its kind (`Heap.BlockKind`'s code, 1 to 15) in the
## top 16 bits, the collector's mark in bit 47 (set only while a collection
## runs), and the bytes asked for, rounded up to 8, in the low 47. What the
## allocator answers is the address past the header, so a string's length
## is at the answer, as before, and its header 8 bytes below it. **A block
## not taken has the header 0**, and its contents are 0 but for the free
## list's link 8 bytes in, so a block the allocator answers is all 0.
##
## **AN ARRAY'S HEADER SAYS WHAT ITS ITEMS ARE** (`Heap.ElementKind`): its
## record's block is an `Int32Array` (every item a double holding a whole
## number from -2^31 to 2^31 - 1, never -0), a `NumbersArray` (every item a
## double) or an `Array` (any values). The items stay NaN-boxed values
## whichever it is, so every routine reads them as it would any array's. A
## kind only falls, from Int32 to Numbers to Values, and every store keeps
## it true (`Heap.kind_kept_items`, `Heap.keep_item_kind`): a store of a
## number that isn't such a whole number lowers Int32 to Numbers, and a
## store of anything but a number lowers either to Values. The kind's code
## fits the header's byte 6, so a lowering is one byte stored. The heap
## walk holds every Int32 and Numbers array's items to its kind.
##
## `r15` holds the heap's state for the whole run (`state_size` bytes,
## mapped with the rest), laid out as these places say: the next free page,
## the first page, the walk's mode, the walk's counts, the collector's
## counts and its threshold, the free pages' runs, then each size class's
## next block, block size and free list, 32 bytes a class, then the page
## table, one byte a page: 0 a page not taken, 3 to 14 a page of blocks of
## 2 << that many bytes, `large_first` a large block's first page and
## `large_rest` each page after it. The pages start at the first multiple
## of 64 KiB past the state; `r14` is the end of the heap, and the mark
## stack lies past it, in the same mapping.
##
## **AN INTERIOR POINTER FINDS ITS BLOCK BY ARITHMETIC** (`Heap.block_start`,
## for the collector's conservative scan): its page is its offset from the
## first page shifted right 16, and the page table names the page's block
## size, so the block's header is the address and-ed with minus the block
## size. A large block's later page walks back the table to its first.
##
## The allocator takes the head of its size class's free list, else the
## next block of the class's page, a bump; a class whose page is full (or
## that has none) takes a free page. Each kind has its own entry
## (`Heap.allocate`), which puts the kind's header bits in `rax` before the
## shared path. Pages are taken from the free pages' runs, first fit, before
## the heap's end is bumped.
##
## **THE COLLECTOR** (`runtime_gc_collect`) is a mark and a sweep, nothing
## moving, run from the allocator when the bytes taken since the last
## collection, with the bytes it found live, pass the threshold: twice
## those live bytes, and never below `least_threshold`. It keeps every
## register.
##
## - **The roots are conservative.** Every general register and every xmm
##   register is pushed, and the machine stack is read word by word, from
##   `rsp` to the stack's base (the program's entry's `rsp`), and so are the
##   runtime's places past `r13` (`Heap.runtime_roots_size` bytes: the
##   timers' list is the one that holds a block). A word is a possible
##   pointer as it is, or with its tag cleared when its top 16 bits are a
##   pointer's tag (0xFFFA and up); `Heap.block_start` finds its block, or
##   none.
## - **The mark is the header's bit 47**, beside the kind and the size a
##   trace reads anyway, so marking a block touches nothing else, and the
##   sweep, which reads every header, clears it. A block marked for the
##   first time goes on the mark stack, past `r14`, unless its kind holds no
##   pointer; the stack has room for every block the heap could hold, so it
##   never overflows, and no trace recurses.
## - **A block is traced by its kind** (`trace_from`): every word of its
##   bytes asked, from the first that may hold a value or a raw address, is
##   a possible pointer, as a root is. A string and a table hold none.
## - **The sweep** goes page by page. Each class's free list and its bump
##   page are dropped and the lists built again: a marked block is kept and
##   its mark cleared; an unmarked one is zeroed and goes on its class's free
##   list, with the blocks already free. A page of blocks with none kept
##   becomes a free page, and so do a large block's pages when it is not
##   marked. Free pages next to each other make one run, and a run at the
##   heap's end gives its pages back to the bump.
import Assembly
import Boxing
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
		# An array's record, as `Array`'s, whose items are all numbers.
		NumbersArray,
		# An array's record, as `Array`'s, whose items are all whole numbers
		# of 32 bits.
		Int32Array,
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
		NumbersArray,
		Int32Array,
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
			NumbersArray => 14
			Int32Array => 15
		}

	## What every item of an array holds, as its record's header says (the
	## module's header): its codes fall as the kind does, Int32 the highest.
	ElementKind := [Int32, Numbers, Values]

	## The code of an element kind's block kind, which its header holds.
	element_code : Heap.ElementKind -> I64
	element_code = |element|
		match element {
			Int32 => Heap.kind_code(Int32Array)
			Numbers => Heap.kind_code(NumbersArray)
			Values => Heap.kind_code(Array)
		}

	## The header's byte that holds the element kind's code, of the array
	## whose record's address is in `rdi` (the header's byte 6, which holds a
	## kind's code below 256 whole). Every routine and store that keeps the
	## kind has the record there.
	element_kind_place : X86.Mem
	element_kind_place = Emit.mem(Rdi, -2)

	## What an item stored in an array is known to be before the program
	## runs, which decides the code that keeps the array's element kind true:
	## `InKind`, an item every element kind holds (an `Integer` within 32
	## bits); `Number`, a double; `Value`, any value; `NotNumber`, a value
	## known to be no number.
	ItemStored : [InKind, Number, Value, NotNumber]

	## The statements that keep the element kind of the array whose record's
	## address is in `rdi` true of the item whose bits are in `bits`, stored
	## or about to be, known to be `stored`: they lower the kind where the
	## item doesn't fit it. `label` starts their labels' names. They change
	## `rcx`, `rdx`, `xmm0` and `xmm1`, so `bits` may be neither `rcx` nor
	## `rdx`.
	kind_kept_items : {
		bits : X86.Register,
		stored : Heap.ItemStored,
		label : Str,
	} -> List(Assembly.Statement)
	kind_kept_items = |{ bits, stored, label }| {
		place = Heap.element_kind_place
		kept = "${label}_kind_kept"
		lowered = "${label}_kind_lowered"
		not_int32 = "${label}_kind_not_int32"
		to_values = "${label}_kind_values"
		# A whole number of 32 bits, not -0, which every kind holds: the
		# double made back from its 32-bit integer has its bits (a value that
		# is no number is a NaN to `cvttsd2si`, as `X86.Cvttsd2si32` says).
		int32_tested = [
			Emit.to_xmm(Xmm0, bits),
			Instruction(Cvttsd2si32({ to: Rcx, from: Xmm0 })),
			Instruction(Cvtsi2sd32({ to: Xmm1, from: Rcx })),
			Instruction(MovqFromXmm({ to: Rdx, from: Xmm1 })),
			Emit.cmp(Rdx, bits),
			Emit.jcc(E, kept),
			Emit.mark(not_int32),
		]
		match stored {
			InKind => []
			NotNumber => [Emit.imm(Rdx, Heap.element_code(Values)), Emit.byte_store(place, Dl)]
			Number =>
				[
					Emit.byte_load(Rdx, place),
					Emit.cmp_imm(Rdx, Heap.element_code(Int32)),
					Emit.jcc(Ne, kept),
				]
					.concat(int32_tested)
					.concat([
						Emit.imm(Rdx, Heap.element_code(Numbers)),
						Emit.byte_store(place, Dl),
						Emit.mark(kept),
					])
			# An Int32 item fits any kind, so it is tested first, with no load
			# of the header: a whole number, the commonest item the SAT race
			# stores, takes 6 instructions. Then Values holds any item, a
			# number keeps Numbers or lowers Int32 to it, and any other value
			# lowers either to Values.
			Value =>
				int32_tested
					.concat([
						Emit.byte_load(Rdx, place),
						Emit.cmp_imm(Rdx, Heap.element_code(Values)),
						Emit.jcc(E, kept),
						Emit.mov(Rcx, bits),
						Emit.shr(Rcx, Boxing.tag_shift),
						Emit.cmp_imm(Rcx, Boxing.first_tag),
						Emit.jcc(Ae, to_values),
						Emit.cmp_imm(Rdx, Heap.element_code(Numbers)),
						Emit.jcc(E, kept),
						Emit.imm(Rdx, Heap.element_code(Numbers)),
						Emit.jmp(lowered),
						Emit.mark(to_values),
						Emit.imm(Rdx, Heap.element_code(Values)),
						Emit.mark(lowered),
						Emit.byte_store(place, Dl),
						Emit.mark(kept),
					])
		}
	}

	## The routine that keeps the element kind of the array whose record's
	## address is in `rdi` true of the value in `rsi`, as
	## `Heap.kind_kept_items` does. It keeps every register.
	keep_item_kind : Str
	keep_item_kind = "runtime_keep_item_kind"

	## The routine that gives the array whose boxed bits are in `rax`, its
	## items just made, the element kind they hold: Int32 when each is a whole
	## number of 32 bits, else Numbers when each is a number, else Values. It
	## keeps `rax`, and changes `rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r9`, `xmm0`
	## and `xmm1`.
	find_element_kind : Str
	find_element_kind = "runtime_find_element_kind"

	## The routine that takes `rdi` bytes of the heap for a block of `kind`,
	## the address past its header in `rax`, the block's bytes all 0. It
	## changes `rax` and `rdi` alone, and may collect.
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
	## asked, the bytes their blocks hold and the pages taken; then it checks
	## each class's free list and the free pages' runs against the free
	## blocks and pages it saw. It changes every general register but `rbx`,
	## `rbp`, `rsp` and `r12` to `r15`.
	walk : Str
	walk = "runtime_heap_walk"

	## The routine that collects: marks from the roots, then sweeps. It
	## keeps every register.
	collect : Str
	collect = "runtime_gc_collect"

	## Where the allocator goes past the end of the heap.
	out_of_memory : Str
	out_of_memory = "runtime_out_of_memory"

	## The text the walk stops with.
	bad_header_text : Str
	bad_header_text = "runtime_text_bad_header"

	## The text the walk stops with at an array's item that its element kind
	## doesn't hold.
	bad_element_text : Str
	bad_element_text = "runtime_text_bad_element"

	## The walk's mode, which the start sets from the program's first
	## argument: 0 none, 1 a walk at the exit and at a stop (`heapwalk`), 2
	## a walk and its counts written at the exit (`heapstat`), 3 a collection
	## at every allocation, each followed by a walk, and a walk at the exit
	## and at a stop (`gcalways`, the torture tier's), 4 the same but with a
	## collection each time `sample_bytes` more are taken (`gcsample`, the
	## torture tier's for a program too big for a collection at every
	## allocation).
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

	## The most pages the heap has reached, free pages among them, and the
	## collections run.
	peak_place : X86.Mem
	peak_place = Emit.mem(R15, 112)

	collections_place : X86.Mem
	collections_place = Emit.mem(R15, 104)

	## The blocks allocated in the whole run, large ones among them.
	allocations_place : X86.Mem
	allocations_place = Emit.mem(R15, 144)

	## The bytes of the heap: the program stops, out of memory, past them.
	## The mapping reserves nothing (`MAP_NORESERVE`), so only the pages a
	## program touches are memory.
	mapped_size : I64
	mapped_size = 0x80000000

	## The bytes mapped: the state and the heap, then the mark stack, 8 bytes
	## for each 16 of the heap, room for a mark of every block.
	mapping_size : I64
	mapping_size = Heap.mapped_size + Heap.mapped_size // 2

	## The mapping's last 8 bytes, which the mark stack never reaches (a heap
	## of fewer than `mapped_size` bytes holds fewer than `mapped_size // 16`
	## blocks): js-x86's `guardsflip` mode counts there the side exits'
	## tests its programs make (Lowering's `flip_items`). No other program
	## touches it.
	spare_place : X86.Mem
	spare_place = Emit.mem(R14, Heap.mapped_size // 2 - 8)

	## The runtime's places past `r13` that the collector reads as roots:
	## all of them before the output buffer (Runtime's `buffer_place`).
	runtime_roots_size : I64
	runtime_roots_size = 64

	## The heap's start: with `r15` at the state and `r14` at the heap's end,
	## the stack's base kept, the first page placed, each class's block size
	## set, the walk's mode taken from the first argument (`[rsp + 16]`, at
	## the program's entry) and the threshold set. It changes `rax` and
	## `rcx`.
	start_items : List(Assembly.Statement)
	start_items = [
		Emit.store(stack_base_place, Rsp),
		Emit.lea(Rax, Emit.mem(R15, state_size + page_size - 1)),
		Emit.bit_and_imm(Rax, 0 - page_size),
		Emit.store(next_page_place, Rax),
		Emit.store(first_page_place, Rax),
		Emit.imm(Rax, least_block),
		Emit.lea(Rcx, Emit.mem(R15, classes_place + 8)),
		Emit.mark("runtime_heap_class_sized"),
		Emit.store(Emit.mem(Rcx, 0), Rax),
		Emit.plus_imm(Rcx, class_bytes),
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
		Emit.jmp("runtime_heap_moded"),
		Emit.mark("runtime_heap_mode_stat"),
		Emit.imm(Rax, word_bits("heapstat")),
		Emit.cmp(Rcx, Rax),
		Emit.jcc(Ne, "runtime_heap_mode_always"),
		Emit.imm(Rax, 2),
		Emit.store(Heap.mode_place, Rax),
		Emit.jmp("runtime_heap_moded"),
		Emit.mark("runtime_heap_mode_always"),
		Emit.imm(Rax, word_bits("gcalways")),
		Emit.cmp(Rcx, Rax),
		Emit.jcc(Ne, "runtime_heap_mode_sample"),
		Emit.imm(Rax, torture_mode),
		Emit.store(Heap.mode_place, Rax),
		Emit.jmp("runtime_heap_moded"),
		Emit.mark("runtime_heap_mode_sample"),
		Emit.imm(Rax, word_bits("gcsample")),
		Emit.cmp(Rcx, Rax),
		Emit.jcc(Ne, "runtime_heap_moded"),
		Emit.imm(Rax, sampled_mode),
		Emit.store(Heap.mode_place, Rax),
		Emit.mark("runtime_heap_moded"),
		Emit.call("runtime_gc_threshold"),
	]

	## Every routine of the heap's: the kinds' entries, the allocator, the
	## block start, the collector and the walk.
	items : List(Assembly.Statement)
	items = [
		entry_items,
		keep_item_kind_items,
		find_element_kind_items,
		allocate_items,
		take_pages_items,
		threshold_items,
		block_start_items,
		collect_items,
		consider_items,
		sweep_items,
		walk_items,
	].join()
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
		NumbersArray => "numbers_array"
		Int32Array => "int32_array"
	}

## Where a block's trace starts, in bytes past its header: from there to
## the end of its bytes asked, every word may be a value or a raw address
## of a block. A record's counts and distances before it hold none; a
## string's bytes and a table's places are never read as pointers.
trace_from : Heap.BlockKind -> [Untraced, From(I64)]
trace_from = |kind|
	match kind {
		String => Untraced
		Array => From(16)
		Items => From(0)
		Object => From(16)
		Entries => From(0)
		Table => Untraced
		Closure => From(24)
		Cell => From(0)
		Collection => From(0)
		CollectionEntries => From(0)
		Iterator => From(0)
		Timer => From(0)
		Texts => From(0)
		NumbersArray => From(16)
		Int32Array => From(16)
	}

## What a kind's code is multiplied by in a header: its place, the top 16
## bits.
kind_place : I64
kind_place = 0x1000000000000

## The collector's mark in a header.
mark_bit : I64
mark_bit = 0x800000000000

## The shift that clears a header's kind and mark, left then right, leaving
## its bytes asked.
asked_shift : U8
asked_shift = 17

## The modes of the torture tier: a collection at every allocation, and one
## each time `sample_bytes` more are taken.
torture_mode : I64
torture_mode = 3

sampled_mode : I64
sampled_mode = 4

## The bytes taken between two collections in the sampled mode: a page's
## worth of blocks.
sample_bytes : I64
sample_bytes = page_size

## The threshold's floor: a program that keeps little collects once this
## many bytes are taken since the last collection.
least_threshold : I64
least_threshold = 8 * 1024 * 1024

## How many times the live bytes the last collection found the threshold is,
## when that passes `least_threshold`.
growth : I64
growth = 2

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

## The state's places past `r15`, as the module's header lays them out,
## past the walk's (`Heap.mode_place` to `Heap.pages_place`): the bytes taken
## since the last collection with those it found live, the threshold, the
## live bytes the last collection found, the first free pages' run, the
## sweep's run being made and its pages, the collections run, the most
## pages reached, the walk's free blocks and free pages, the stack's base
## and the blocks allocated.
next_page_place : X86.Mem
next_page_place = Emit.mem(R15, 0)

first_page_place : X86.Mem
first_page_place = Emit.mem(R15, 8)

in_use_place : X86.Mem
in_use_place = Emit.mem(R15, 56)

threshold_place : X86.Mem
threshold_place = Emit.mem(R15, 64)

live_place : X86.Mem
live_place = Emit.mem(R15, 72)

runs_offset : I64
runs_offset = 80

runs_place : X86.Mem
runs_place = Emit.mem(R15, runs_offset)

run_start_place : X86.Mem
run_start_place = Emit.mem(R15, 88)

run_pages_place : X86.Mem
run_pages_place = Emit.mem(R15, 96)

free_blocks_place : X86.Mem
free_blocks_place = Emit.mem(R15, 120)

free_pages_place : X86.Mem
free_pages_place = Emit.mem(R15, 128)

stack_base_place : X86.Mem
stack_base_place = Emit.mem(R15, 136)

## Each class's 32 bytes: its next block (0), its block size (8) and its
## free list's first block (16).
classes_place : I64
classes_place = 152

class_bytes : I64
class_bytes = 32

class_shift : U8
class_shift = 5

class_count : I64
class_count = most_class - least_class + 1

table_place : I64
table_place = classes_place + class_bytes * class_count

## The page table's room: one byte for each page the heap could hold.
table_size : I64
table_size = Heap.mapped_size // page_size

state_size : I64
state_size = table_place + table_size

## The place of a class's next block, the class's offset (its highest bit
## times 32) in `offset`; its block size is 8 bytes on, its free list 16.
class_place : { offset : X86.Register, past : I64 } -> X86.Mem
class_place = |{ offset, past }| Emit.mem_index({
	base: R15,
	index: offset,
	displacement: classes_place - class_bytes * least_class + past,
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

## A register or-ed with another.
or_item : X86.Register, X86.Register -> Assembly.Statement
or_item = |to, from| Instruction(Alu({ operation: Or, to, from }))

## The mark, which `rbp` holds while a collection runs, cleared from the
## header in `rax`.
unmark_item : Assembly.Statement
unmark_item = Instruction(
	Alu({
		operation: Xor,
		to: Rax,
		from: Rbp,
	}),
)

## The page number of the address in `from`, in `to`. It changes `rax`.
page_number_items : { to : X86.Register, from : X86.Register } -> List(Assembly.Statement)
page_number_items = |{ to, from }| [
	Emit.mov(to, from),
	Emit.load(Rax, first_page_place),
	Emit.minus(to, Rax),
	Emit.shr(to, page_bits),
]

## The threshold the bytes taken must pass for a collection: `growth` times
## the live bytes the last collection found (0 before one), at least
## `least_threshold`; in the torture tier 0, so every allocation collects,
## or in its sampled mode the live bytes and `sample_bytes`:
## `runtime_gc_threshold`. It changes `rax` and `rcx`.
threshold_items : List(Assembly.Statement)
threshold_items = [
	Emit.mark("runtime_gc_threshold"),
	Emit.load(Rax, live_place),
	Emit.imm(Rcx, growth),
	Instruction(Imul({ to: Rax, from: Rcx })),
	Emit.imm(Rcx, least_threshold),
	Emit.cmp(Rax, Rcx),
	Emit.jcc(Ae, "runtime_gc_threshold_floored"),
	Emit.mov(Rax, Rcx),
	Emit.mark("runtime_gc_threshold_floored"),
	Emit.load(Rcx, Heap.mode_place),
	Emit.cmp_imm(Rcx, torture_mode),
	Emit.jcc(B, "runtime_gc_threshold_set"),
	Emit.jcc(Ne, "runtime_gc_threshold_sampled"),
	Emit.zero(Rax),
	Emit.jmp("runtime_gc_threshold_set"),
	Emit.mark("runtime_gc_threshold_sampled"),
	Emit.load(Rax, live_place),
	Emit.plus_imm(Rax, sample_bytes),
	Emit.mark("runtime_gc_threshold_set"),
	Emit.store(threshold_place, Rax),
	Emit.ret,
]

## `runtime_keep_item_kind`: `Heap.kind_kept_items` of the record in `rdi`
## and the value in `rsi`, with the registers it changes saved around it.
keep_item_kind_items : List(Assembly.Statement)
keep_item_kind_items =
	[
		Emit.mark(Heap.keep_item_kind),
		Emit.save(Rcx),
		Emit.save(Rdx),
		Instruction(MovqFromXmm({ to: Rcx, from: Xmm0 })),
		Emit.save(Rcx),
		Instruction(MovqFromXmm({ to: Rcx, from: Xmm1 })),
		Emit.save(Rcx),
	]
		.concat(
			Heap.kind_kept_items({
				bits: Rsi,
				stored: Value,
				label: Heap.keep_item_kind,
			}),
		)
		.concat([
			Emit.restore(Rcx),
			Emit.to_xmm(Xmm1, Rcx),
			Emit.restore(Rcx),
			Emit.to_xmm(Xmm0, Rcx),
			Emit.restore(Rdx),
			Emit.restore(Rcx),
			Emit.ret,
		])

## `runtime_find_element_kind`: the kind set to Int32, then kept true of
## each item in turn, `r8` the item's address and `r9` the items left.
find_element_kind_items : List(Assembly.Statement)
find_element_kind_items =
	[
		[Emit.mark(Heap.find_element_kind), Emit.mov(Rdi, Rax)],
		RuntimeBuilders.unboxed_items(Rdi),
		[
			Emit.imm(Rcx, Heap.element_code(Int32)),
			Emit.byte_store(Heap.element_kind_place, Cl),
			Emit.load(R8, Emit.mem(Rdi, 16)),
			Emit.load(R9, Emit.mem(Rdi, 0)),
			Emit.mark("runtime_find_element_kind_item"),
			Emit.test(R9, R9),
			Emit.jcc(E, "runtime_find_element_kind_found"),
			Emit.load(Rsi, Emit.mem(R8, 0)),
		],
		Heap.kind_kept_items({
			bits: Rsi,
			stored: Value,
			label: Heap.find_element_kind,
		}),
		[
			Emit.plus_imm(R8, 8),
			Emit.minus_imm(R9, 1),
			Emit.jmp("runtime_find_element_kind_item"),
			Emit.mark("runtime_find_element_kind_found"),
			Emit.ret,
		],
	].join()

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
## of `rdi + 7`, at least 3). The block's bytes are counted as taken, and
## past the threshold the heap is collected first. The class's free list's
## first block is taken, else its next block, unless that lies at a page's
## start, which says its page is full or it has none: then a page is taken
## first. A block past the most a page of blocks holds takes pages of its
## own. It keeps every register but `rax` and `rdi`.
allocate_items : List(Assembly.Statement)
allocate_items = [
	Emit.mark("runtime_allocate_kind"),
	Emit.save(Rcx),
	Emit.save(Rdx),
	Emit.load(Rdx, Heap.allocations_place),
	Emit.plus_imm(Rdx, 1),
	Emit.store(Heap.allocations_place, Rdx),
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
	or_item(Rdi, Rax),
	Emit.cmp_imm(Rcx, most_class),
	Emit.jcc(A, "runtime_allocate_large"),
	Emit.shl(Rcx, class_shift),
	Emit.load(Rax, in_use_place),
	Emit.load(Rdx, class_place({ offset: Rcx, past: 8 })),
	Emit.plus(Rax, Rdx),
	Emit.store(in_use_place, Rax),
	Emit.load(Rdx, threshold_place),
	Emit.cmp(Rax, Rdx),
	Emit.jcc(A, "runtime_allocate_collect"),
	Emit.mark("runtime_allocate_small"),
	Emit.load(Rax, class_place({ offset: Rcx, past: 16 })),
	Emit.test(Rax, Rax),
	Emit.jcc(E, "runtime_allocate_bump"),
	Emit.load(Rdx, Emit.mem(Rax, 8)),
	Emit.store(class_place({ offset: Rcx, past: 16 }), Rdx),
	Emit.zero(Rdx),
	Emit.store(Emit.mem(Rax, 8), Rdx),
	Emit.jmp("runtime_allocate_header"),
	Emit.mark("runtime_allocate_bump"),
	Emit.load(Rax, class_place({ offset: Rcx, past: 0 })),
	Emit.mov(Rdx, Rax),
	Emit.bit_and_imm(Rdx, page_size - 1),
	Emit.jcc(E, "runtime_allocate_page"),
	Emit.mark("runtime_allocate_block"),
	Emit.load(Rdx, class_place({ offset: Rcx, past: 8 })),
	Emit.plus(Rdx, Rax),
	Emit.store(class_place({ offset: Rcx, past: 0 }), Rdx),
	Emit.mark("runtime_allocate_header"),
	Emit.store(Emit.mem(Rax, 0), Rdi),
	Emit.plus_imm(Rax, 8),
	Emit.restore(Rdx),
	Emit.restore(Rcx),
	Emit.ret,
	Emit.mark("runtime_allocate_collect"),
	Emit.call(Heap.collect),
	Emit.jmp("runtime_allocate_small"),
	# A page for the class whose offset is in `rcx`, marked in the table
	# with the class's bit.
	Emit.mark("runtime_allocate_page"),
	Emit.imm(Rax, 1),
	Emit.call("runtime_take_pages"),
	Emit.save(Rsi),
	Emit.mov(Rsi, Rax),
	Emit.load(Rdx, first_page_place),
	Emit.minus(Rsi, Rdx),
	Emit.shr(Rsi, page_bits),
	Emit.mov(Rdx, Rcx),
	Emit.shr(Rdx, class_shift),
	Emit.byte_store(table_entry(Rsi), Dl),
	Emit.restore(Rsi),
	Emit.jmp("runtime_allocate_block"),
	# A large block: the pages its header and its bytes fill, counted as
	# taken, the first marked `large_first` and the rest `large_rest`; `rsi`
	# holds their bytes, then the block.
	Emit.mark("runtime_allocate_large"),
	Emit.save(Rsi),
	Emit.mov(Rsi, Rdi),
	Emit.shl(Rsi, 16),
	Emit.shr(Rsi, 16),
	Emit.plus_imm(Rsi, 8 + page_size - 1),
	Emit.bit_and_imm(Rsi, 0 - page_size),
	Emit.load(Rax, in_use_place),
	Emit.plus(Rax, Rsi),
	Emit.store(in_use_place, Rax),
	Emit.load(Rdx, threshold_place),
	Emit.cmp(Rax, Rdx),
	Emit.jcc(Be, "runtime_allocate_large_go"),
	Emit.call(Heap.collect),
	Emit.mark("runtime_allocate_large_go"),
	Emit.mov(Rax, Rsi),
	Emit.shr(Rax, page_bits),
	Emit.call("runtime_take_pages"),
	Emit.store(Emit.mem(Rax, 0), Rdi),
	Emit.mov(Rcx, Rsi),
	Emit.shr(Rcx, page_bits),
	Emit.mov(Rsi, Rax),
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

## `runtime_take_pages`: `rax` pages, their first's address in `rax`. The
## free pages' runs are searched first, in order, each run's first page
## holding the next run's address and its count of pages: a run of just
## that many is taken whole, its words cleared, and a longer one gives its
## last pages. With none, the heap's end is bumped, and the most pages
## reached kept. A free page is 0 but for a run's two words, so the pages
## taken are 0. It keeps every register but `rax`.
take_pages_items : List(Assembly.Statement)
take_pages_items = [
	Emit.mark("runtime_take_pages"),
	Emit.save(Rcx),
	Emit.save(Rdx),
	Emit.save(Rsi),
	# `rsi` is the address of the link to the run being looked at.
	Emit.lea(Rsi, runs_place),
	Emit.mark("runtime_take_pages_next"),
	Emit.load(Rcx, Emit.mem(Rsi, 0)),
	Emit.test(Rcx, Rcx),
	Emit.jcc(E, "runtime_take_pages_bump"),
	Emit.load(Rdx, Emit.mem(Rcx, 8)),
	Emit.cmp(Rdx, Rax),
	Emit.jcc(Ae, "runtime_take_pages_fit"),
	Emit.mov(Rsi, Rcx),
	Emit.jmp("runtime_take_pages_next"),
	Emit.mark("runtime_take_pages_fit"),
	Emit.jcc(E, "runtime_take_pages_whole"),
	Emit.minus(Rdx, Rax),
	Emit.store(Emit.mem(Rcx, 8), Rdx),
	Emit.shl(Rdx, page_bits),
	Emit.lea(
		Rax,
		Emit.mem_index({
			base: Rcx,
			index: Rdx,
			displacement: 0,
		}),
	),
	Emit.jmp("runtime_take_pages_taken"),
	Emit.mark("runtime_take_pages_whole"),
	Emit.load(Rdx, Emit.mem(Rcx, 0)),
	Emit.store(Emit.mem(Rsi, 0), Rdx),
	Emit.zero(Rdx),
	Emit.store(Emit.mem(Rcx, 0), Rdx),
	Emit.store(Emit.mem(Rcx, 8), Rdx),
	Emit.mov(Rax, Rcx),
	Emit.jmp("runtime_take_pages_taken"),
	Emit.mark("runtime_take_pages_bump"),
	Emit.shl(Rax, page_bits),
	Emit.load(Rdx, next_page_place),
	Emit.plus(Rax, Rdx),
	Emit.cmp(Rax, R14),
	Emit.jcc(A, Heap.out_of_memory),
	Emit.store(next_page_place, Rax),
	Emit.mov(Rcx, Rax),
	Emit.load(Rsi, first_page_place),
	Emit.minus(Rcx, Rsi),
	Emit.shr(Rcx, page_bits),
	Emit.load(Rsi, Heap.peak_place),
	Emit.cmp(Rcx, Rsi),
	Emit.jcc(Be, "runtime_take_pages_peaked"),
	Emit.store(Heap.peak_place, Rcx),
	Emit.mark("runtime_take_pages_peaked"),
	Emit.mov(Rax, Rdx),
	Emit.mark("runtime_take_pages_taken"),
	Emit.restore(Rsi),
	Emit.restore(Rdx),
	Emit.restore(Rcx),
	Emit.ret,
]

## `runtime_block_start`: the interior pointer's block, by its page's class
## (the address and-ed with minus the block size), or by walking a large
## block's pages back to its first; 0 for an address in no page taken, or
## in a block not taken (its header 0).
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
	Emit.shl(Rdx, class_shift),
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

## The general registers the collector pushes, and so reads as roots and
## puts back; `r12` to `r15` are the runtime's and hold no block.
pushed_registers : List(X86.Register)
pushed_registers = [Rax, Rcx, Rdx, Rbx, Rbp, Rsi, Rdi, R8, R9, R10, R11]

## The xmm registers, which a value may sit in across a routine's call.
xmm_registers : List(X86.Xmm)
xmm_registers = [
	Xmm0,
	Xmm1,
	Xmm2,
	Xmm3,
	Xmm4,
	Xmm5,
	Xmm6,
	Xmm7,
	Xmm8,
	Xmm9,
	Xmm10,
	Xmm11,
	Xmm12,
	Xmm13,
	Xmm14,
	Xmm15,
]

## A list's items, last first.
backwards : List(a) -> List(a)
backwards = |list| {
	var $out = []
	for item in list {
		$out = [item].concat($out)
	}
	$out
}

## `runtime_gc_collect`: every register pushed, the roots read, the mark
## stack traced to its bottom, the sweep, the threshold set again, and in
## the torture tier a walk; then every register put back. While it marks,
## `rbp` holds the mark bit and `r8` the mark stack's top, which starts at
## `r14`; `runtime_gc_scan` reads the words from `r9` to `r10`.
collect_items : List(Assembly.Statement)
collect_items = {
	pushes = pushed_registers.map(Emit.save)
	pops = backwards(pushed_registers.map(Emit.restore))
	xmm_pushes = xmm_registers.map(
		|xmm| [Instruction(MovqFromXmm({ to: Rax, from: xmm })), Emit.save(Rax)],
	)
	xmm_pops = backwards(xmm_registers.map(|xmm| [Emit.restore(Rax), Emit.to_xmm(xmm, Rax)]))
	[
		[Emit.mark(Heap.collect)],
		pushes,
		xmm_pushes.join(),
		[
			Emit.imm(Rbp, mark_bit),
			Emit.mov(R8, R14),
			Emit.mov(R9, Rsp),
			Emit.load(R10, stack_base_place),
			Emit.call("runtime_gc_scan"),
			Emit.mov(R9, R13),
			Emit.lea(R10, Emit.mem(R13, Heap.runtime_roots_size)),
			Emit.call("runtime_gc_scan"),
			Emit.mark("runtime_gc_trace"),
			Emit.cmp(R8, R14),
			Emit.jcc(Be, "runtime_gc_traced"),
			Emit.minus_imm(R8, 8),
			Emit.load(Rbx, Emit.mem(R8, 0)),
			Emit.load(Rax, Emit.mem(Rbx, 0)),
			Emit.mov(Rcx, Rax),
			Emit.shr(Rcx, 48),
			Emit.shl(Rax, asked_shift),
			Emit.shr(Rax, asked_shift),
			Emit.lea(
				R10,
				Emit.mem_index({
					base: Rbx,
					index: Rax,
					displacement: 8,
				}),
			),
			Emit.lea(R9, Emit.mem(Rbx, 8)),
		],
		trace_dispatch_items,
		[
			Emit.jmp("runtime_heap_bad"),
			Emit.mark("runtime_gc_trace_words"),
			Emit.call("runtime_gc_scan"),
			Emit.jmp("runtime_gc_trace"),
			Emit.mark("runtime_gc_traced"),
			Emit.call("runtime_gc_sweep"),
			Emit.load(Rax, Heap.mode_place),
			Emit.cmp_imm(Rax, torture_mode),
			Emit.jcc(B, "runtime_gc_walked"),
			Emit.call(Heap.walk),
			Emit.mark("runtime_gc_walked"),
		],
		xmm_pops.join(),
		pops,
		[Emit.ret],
	].join()
}

## The trace's choice by the kind's code in `rcx`: the words to read from
## `r9`, moved past the kind's counts, or none.
trace_dispatch_items : List(Assembly.Statement)
trace_dispatch_items = {
	var $out = []
	for kind in Heap.kinds {
		past = "runtime_gc_trace_past_${kind_word(kind)}"
		chosen =
			match trace_from(kind) {
				Untraced => [Emit.jmp("runtime_gc_trace")]
				From(0) => [Emit.jmp("runtime_gc_trace_words")]
				From(offset) => [Emit.plus_imm(R9, offset), Emit.jmp("runtime_gc_trace_words")]
			}
		$out = $out
			.concat([Emit.cmp_imm(Rcx, Heap.kind_code(kind)), Emit.jcc(Ne, past)])
			.concat(chosen)
			.append(Emit.mark(past))
	}
	$out
}

## `runtime_gc_scan`: each word from `r9` up to `r10` considered. And
## `runtime_gc_consider`: the word in `rdi` as a possible pointer, its tag
## cleared when its top 16 bits are a pointer's tag; the block it falls in,
## when it falls in one taken and not yet marked, marked, and pushed on the
## mark stack at `r8` unless its kind holds no pointer. They change `rax`,
## `rcx`, `rdx` and `rdi`, and `r9` and `r8` as they say.
consider_items : List(Assembly.Statement)
consider_items = {
	untraced = Heap.kinds.keep_if(|kind| trace_from(kind) == Untraced)
	[
		[
			Emit.mark("runtime_gc_scan"),
			Emit.cmp(R9, R10),
			Emit.jcc(Ae, "runtime_gc_scanned"),
			Emit.load(Rdi, Emit.mem(R9, 0)),
			Emit.call("runtime_gc_consider"),
			Emit.plus_imm(R9, 8),
			Emit.jmp("runtime_gc_scan"),
			Emit.mark("runtime_gc_scanned"),
			Emit.ret,
			Emit.mark("runtime_gc_consider"),
			Emit.mov(Rax, Rdi),
			Emit.shr(Rax, 48),
			Emit.cmp_imm(Rax, Boxing.string_tag),
			Emit.jcc(B, "runtime_gc_consider_raw"),
		],
		RuntimeBuilders.unboxed_items(Rdi),
		[
			Emit.mark("runtime_gc_consider_raw"),
			Emit.call(Heap.block_start),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_gc_considered"),
			Emit.load(Rcx, Emit.mem(Rax, 0)),
			Emit.test(Rcx, Rbp),
			Emit.jcc(Ne, "runtime_gc_considered"),
			or_item(Rcx, Rbp),
			Emit.store(Emit.mem(Rax, 0), Rcx),
			Emit.shr(Rcx, 48),
		],
		untraced
			.map(
				|kind| [
					Emit.cmp_imm(Rcx, Heap.kind_code(kind)),
					Emit.jcc(E, "runtime_gc_considered"),
				],
			)
			.join(),
		[
			Emit.store(Emit.mem(R8, 0), Rax),
			Emit.plus_imm(R8, 8),
			Emit.mark("runtime_gc_considered"),
			Emit.ret,
		],
	].join()
}

## `runtime_gc_sweep`: every class's free list and bump page dropped, then
## each page from the first to the next free one, by the table. On a page of
## blocks (`r9` the block, `r10` the block size, `r11` the page's end), a
## marked block is kept, its mark cleared, and counted in `rbx`; an unmarked
## one is zeroed and joins the free blocks, linked from `rsi` (the first)
## to `rdi` (the last). A page with a block kept gives its free blocks to
## its class's list (the class's offset in `rdx`); one with none becomes a
## free page, its links cleared. A large block's pages are kept or freed
## with it. Free pages make runs (`runtime_gc_run_extend` and
## `runtime_gc_run_close`), the last given back to the bump. Then the bytes
## kept are the bytes taken, and the threshold is set again from them.
sweep_items : List(Assembly.Statement)
sweep_items =
	[
		[
			Emit.mark("runtime_gc_sweep"),
			Emit.zero(Rax),
			Emit.store(live_place, Rax),
			Emit.store(runs_place, Rax),
			Emit.store(run_start_place, Rax),
			Emit.store(run_pages_place, Rax),
			Emit.lea(Rcx, Emit.mem(R15, classes_place)),
			Emit.imm(Rdx, class_count),
			Emit.mark("runtime_gc_sweep_class"),
			Emit.store(Emit.mem(Rcx, 0), Rax),
			Emit.store(Emit.mem(Rcx, 16), Rax),
			Emit.plus_imm(Rcx, class_bytes),
			Emit.minus_imm(Rdx, 1),
			Emit.jcc(Ne, "runtime_gc_sweep_class"),
			Emit.load(R8, first_page_place),
			Emit.mark("runtime_gc_sweep_page"),
			Emit.load(Rax, next_page_place),
			Emit.cmp(R8, Rax),
			Emit.jcc(Ae, "runtime_gc_swept"),
		],
		page_mark_items,
		[
			Emit.test(Rdx, Rdx),
			Emit.jcc(E, "runtime_gc_sweep_free_page"),
			Emit.cmp_imm(Rdx, large_first),
			Emit.jcc(E, "runtime_gc_sweep_large"),
			Emit.shl(Rdx, class_shift),
			Emit.load(R10, class_place({ offset: Rdx, past: 8 })),
			Emit.mov(R9, R8),
			Emit.lea(R11, Emit.mem(R8, page_size)),
			Emit.zero(Rbx),
			Emit.zero(Rsi),
			Emit.zero(Rdi),
			Emit.mark("runtime_gc_sweep_block"),
			Emit.cmp(R9, R11),
			Emit.jcc(Ae, "runtime_gc_sweep_paged"),
			Emit.load(Rax, Emit.mem(R9, 0)),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_gc_sweep_link"),
			Emit.test(Rax, Rbp),
			Emit.jcc(E, "runtime_gc_sweep_dead"),
			unmark_item,
			Emit.store(Emit.mem(R9, 0), Rax),
			Emit.plus_imm(Rbx, 1),
			Emit.plus(R9, R10),
			Emit.jmp("runtime_gc_sweep_block"),
			Emit.mark("runtime_gc_sweep_dead"),
			Emit.zero(Rax),
			Emit.mov(Rcx, R10),
			Emit.mark("runtime_gc_sweep_zero"),
			Emit.minus_imm(Rcx, 8),
			Emit.store(
				Emit.mem_index({
					base: R9,
					index: Rcx,
					displacement: 0,
				}),
				Rax,
			),
			Emit.jcc(Ne, "runtime_gc_sweep_zero"),
			Emit.mark("runtime_gc_sweep_link"),
			Emit.store(Emit.mem(R9, 8), Rsi),
			Emit.mov(Rsi, R9),
			Emit.test(Rdi, Rdi),
			Emit.jcc(Ne, "runtime_gc_sweep_linked"),
			Emit.mov(Rdi, R9),
			Emit.mark("runtime_gc_sweep_linked"),
			Emit.plus(R9, R10),
			Emit.jmp("runtime_gc_sweep_block"),
			Emit.mark("runtime_gc_sweep_paged"),
			Emit.test(Rbx, Rbx),
			Emit.jcc(E, "runtime_gc_sweep_emptied"),
			Emit.call("runtime_gc_run_close"),
			Instruction(Imul({ to: Rbx, from: R10 })),
			Emit.load(Rax, live_place),
			Emit.plus(Rax, Rbx),
			Emit.store(live_place, Rax),
			Emit.test(Rsi, Rsi),
			Emit.jcc(E, "runtime_gc_sweep_spliced"),
			Emit.load(Rax, class_place({ offset: Rdx, past: 16 })),
			Emit.store(Emit.mem(Rdi, 8), Rax),
			Emit.store(class_place({ offset: Rdx, past: 16 }), Rsi),
			Emit.mark("runtime_gc_sweep_spliced"),
			Emit.mov(R8, R11),
			Emit.jmp("runtime_gc_sweep_page"),
			# No block kept: the links cleared, and the page free.
			Emit.mark("runtime_gc_sweep_emptied"),
			Emit.zero(Rax),
			Emit.mark("runtime_gc_sweep_unlink"),
			Emit.test(Rsi, Rsi),
			Emit.jcc(E, "runtime_gc_sweep_unlinked"),
			Emit.load(Rcx, Emit.mem(Rsi, 8)),
			Emit.store(Emit.mem(Rsi, 8), Rax),
			Emit.mov(Rsi, Rcx),
			Emit.jmp("runtime_gc_sweep_unlink"),
			Emit.mark("runtime_gc_sweep_unlinked"),
		],
		page_number_items({ to: Rcx, from: R8 }),
		[
			Emit.zero(Rax),
			Emit.byte_store(table_entry(Rcx), Al),
			Emit.imm(Rax, 1),
			Emit.call("runtime_gc_run_extend"),
			Emit.mov(R8, R11),
			Emit.jmp("runtime_gc_sweep_page"),
			# A free page: a run's words, if it held them, cleared.
			Emit.mark("runtime_gc_sweep_free_page"),
			Emit.zero(Rax),
			Emit.store(Emit.mem(R8, 0), Rax),
			Emit.store(Emit.mem(R8, 8), Rax),
			Emit.imm(Rax, 1),
			Emit.call("runtime_gc_run_extend"),
			Emit.plus_imm(R8, page_size),
			Emit.jmp("runtime_gc_sweep_page"),
			# A large block, its pages' bytes in `r10`.
			Emit.mark("runtime_gc_sweep_large"),
			Emit.load(Rax, Emit.mem(R8, 0)),
			Emit.mov(R10, Rax),
			Emit.shl(R10, asked_shift),
			Emit.shr(R10, asked_shift),
			Emit.plus_imm(R10, 8 + page_size - 1),
			Emit.bit_and_imm(R10, 0 - page_size),
			Emit.test(Rax, Rbp),
			Emit.jcc(E, "runtime_gc_sweep_large_dead"),
			unmark_item,
			Emit.store(Emit.mem(R8, 0), Rax),
			Emit.call("runtime_gc_run_close"),
			Emit.load(Rax, live_place),
			Emit.plus(Rax, R10),
			Emit.store(live_place, Rax),
			Emit.plus(R8, R10),
			Emit.jmp("runtime_gc_sweep_page"),
			# Its header and its bytes asked zeroed, its pages free.
			Emit.mark("runtime_gc_sweep_large_dead"),
			Emit.mov(Rcx, Rax),
			Emit.shl(Rcx, asked_shift),
			Emit.shr(Rcx, asked_shift),
			Emit.plus_imm(Rcx, 8),
			Emit.zero(Rax),
			Emit.mark("runtime_gc_sweep_large_zero"),
			Emit.minus_imm(Rcx, 8),
			Emit.store(
				Emit.mem_index({
					base: R8,
					index: Rcx,
					displacement: 0,
				}),
				Rax,
			),
			Emit.jcc(Ne, "runtime_gc_sweep_large_zero"),
		],
		page_number_items({ to: Rcx, from: R8 }),
		[
			Emit.mov(Rdx, R10),
			Emit.shr(Rdx, page_bits),
			Emit.zero(Rax),
			Emit.mark("runtime_gc_sweep_large_unmark"),
			Emit.byte_store(table_entry(Rcx), Al),
			Emit.plus_imm(Rcx, 1),
			Emit.minus_imm(Rdx, 1),
			Emit.jcc(Ne, "runtime_gc_sweep_large_unmark"),
			Emit.mov(Rax, R10),
			Emit.shr(Rax, page_bits),
			Emit.call("runtime_gc_run_extend"),
			Emit.plus(R8, R10),
			Emit.jmp("runtime_gc_sweep_page"),
			# A run open at the end gives its pages back to the bump.
			Emit.mark("runtime_gc_swept"),
			Emit.load(Rax, run_start_place),
			Emit.test(Rax, Rax),
			Emit.jcc(E, "runtime_gc_sweep_ended"),
			Emit.store(next_page_place, Rax),
			Emit.zero(Rax),
			Emit.store(run_start_place, Rax),
			Emit.mark("runtime_gc_sweep_ended"),
			Emit.load(Rax, live_place),
			Emit.store(in_use_place, Rax),
			Emit.call("runtime_gc_threshold"),
			Emit.load(Rax, Heap.collections_place),
			Emit.plus_imm(Rax, 1),
			Emit.store(Heap.collections_place, Rax),
			Emit.ret,
			# The free page at `r8` and the `rax` pages after it join the run
			# being made, or start one. It changes `rcx`.
			Emit.mark("runtime_gc_run_extend"),
			Emit.load(Rcx, run_start_place),
			Emit.test(Rcx, Rcx),
			Emit.jcc(Ne, "runtime_gc_run_extended"),
			Emit.store(run_start_place, R8),
			Emit.zero(Rcx),
			Emit.store(run_pages_place, Rcx),
			Emit.mark("runtime_gc_run_extended"),
			Emit.load(Rcx, run_pages_place),
			Emit.plus(Rcx, Rax),
			Emit.store(run_pages_place, Rcx),
			Emit.ret,
			# The run being made, if any, put first in the runs: its first
			# page holds the next run's address and its count of pages. It
			# changes `rax` and `rcx`.
			Emit.mark("runtime_gc_run_close"),
			Emit.load(Rcx, run_start_place),
			Emit.test(Rcx, Rcx),
			Emit.jcc(E, "runtime_gc_run_closed"),
			Emit.load(Rax, runs_place),
			Emit.store(Emit.mem(Rcx, 0), Rax),
			Emit.load(Rax, run_pages_place),
			Emit.store(Emit.mem(Rcx, 8), Rax),
			Emit.store(runs_place, Rcx),
			Emit.zero(Rax),
			Emit.store(run_start_place, Rax),
			Emit.mark("runtime_gc_run_closed"),
			Emit.ret,
		],
	].join()

## `runtime_heap_walk`: each page from the first to the next free one, by
## the table. A page of blocks is walked block by block: each header taken
## is checked (`runtime_heap_block`), and a block not taken must be 0 but
## for its link, and is counted free unless it lies in its class's bump
## page at or past the class's next block, where its link must be 0 too. A
## large block's header is checked, and each page after its first must be
## marked `large_rest`. A free page is counted. Any other mark stops the
## program. Then `runtime_heap_lists` checks the free lists and the runs.
## The walk holds the page in `r8`, the block in `r9`, its block size in
## `r10` and the page's end in `r11`.
walk_items : List(Assembly.Statement)
walk_items = [
	[
		Emit.mark(Heap.walk),
		Emit.zero(Rax),
		Emit.store(Heap.blocks_place, Rax),
		Emit.store(Heap.asked_place, Rax),
		Emit.store(Heap.held_place, Rax),
		Emit.store(Heap.pages_place, Rax),
		Emit.store(free_blocks_place, Rax),
		Emit.store(free_pages_place, Rax),
		Emit.load(R8, first_page_place),
		Emit.mark("runtime_heap_walk_page"),
		Emit.load(Rax, next_page_place),
		Emit.cmp(R8, Rax),
		Emit.jcc(Ae, "runtime_heap_lists"),
	],
	page_mark_items,
	[
		Emit.test(Rdx, Rdx),
		Emit.jcc(Ne, "runtime_heap_walk_taken"),
		Emit.load(Rax, free_pages_place),
		Emit.plus_imm(Rax, 1),
		Emit.store(free_pages_place, Rax),
		Emit.plus_imm(R8, page_size),
		Emit.jmp("runtime_heap_walk_page"),
		Emit.mark("runtime_heap_walk_taken"),
		Emit.load(Rax, Heap.pages_place),
		Emit.plus_imm(Rax, 1),
		Emit.store(Heap.pages_place, Rax),
		Emit.cmp_imm(Rdx, large_first),
		Emit.jcc(E, "runtime_heap_walk_large"),
		Emit.cmp_imm(Rdx, least_class),
		Emit.jcc(B, "runtime_heap_bad"),
		Emit.cmp_imm(Rdx, most_class),
		Emit.jcc(A, "runtime_heap_bad"),
		Emit.shl(Rdx, class_shift),
		Emit.load(R10, class_place({ offset: Rdx, past: 8 })),
		Emit.mov(R9, R8),
		Emit.lea(R11, Emit.mem(R8, page_size)),
		Emit.mark("runtime_heap_walk_block"),
		Emit.cmp(R9, R11),
		Emit.jcc(Ae, "runtime_heap_walk_paged"),
		Emit.load(Rax, Emit.mem(R9, 0)),
		Emit.test(Rax, Rax),
		Emit.jcc(E, "runtime_heap_walk_free"),
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
		# A block not taken: 0 past its link, in no block, and free or in
		# its class's bump.
		Emit.mark("runtime_heap_walk_free"),
		Emit.mov(Rcx, R10),
		Emit.mark("runtime_heap_walk_zero"),
		Emit.minus_imm(Rcx, 8),
		Emit.cmp_imm(Rcx, 8),
		Emit.jcc(Be, "runtime_heap_walk_zeroed"),
		Emit.load(
			Rax,
			Emit.mem_index({
				base: R9,
				index: Rcx,
				displacement: 0,
			}),
		),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.jmp("runtime_heap_walk_zero"),
		Emit.mark("runtime_heap_walk_zeroed"),
		Emit.lea(Rdi, Emit.mem(R9, 8)),
		Emit.call(Heap.block_start),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
	],
	page_mark_items,
	[
		Emit.shl(Rdx, class_shift),
		Emit.load(Rax, class_place({ offset: Rdx, past: 0 })),
		Emit.cmp(Rax, R8),
		Emit.jcc(B, "runtime_heap_walk_listed"),
		Emit.cmp(Rax, R9),
		Emit.jcc(A, "runtime_heap_walk_listed"),
		Emit.load(Rax, Emit.mem(R9, 8)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.jmp("runtime_heap_walk_freed"),
		Emit.mark("runtime_heap_walk_listed"),
		Emit.load(Rax, free_blocks_place),
		Emit.plus_imm(Rax, 1),
		Emit.store(free_blocks_place, Rax),
		Emit.mark("runtime_heap_walk_freed"),
		Emit.plus(R9, R10),
		Emit.jmp("runtime_heap_walk_block"),
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
		Emit.load(Rax, Heap.pages_place),
		Emit.plus_imm(Rax, 1),
		Emit.store(Heap.pages_place, Rax),
		Emit.jmp("runtime_heap_walk_later"),
	],
	lists_check_items,
	block_check_items,
	[Emit.mark("runtime_heap_bad")],
	RuntimeBuilders.stopping_items(Heap.bad_header_text),
	[Emit.mark("runtime_heap_bad_element")],
	RuntimeBuilders.stopping_items(Heap.bad_element_text),
].join()

## `runtime_heap_lists`: each class's free list (its offset in `r10`), every
## block on it below the next free page, its header 0, in a page of its
## class, at a multiple of its size, and the lists' blocks, counted in `r9`,
## as many as the free blocks the walk saw (never more, so a list that
## loops stops); then each run of free pages, at a page's start, of at least
## a page, each page marked 0 in the table, and their pages as many as the
## free pages the walk saw.
lists_check_items : List(Assembly.Statement)
lists_check_items = [
	[
		Emit.mark("runtime_heap_lists"),
		Emit.zero(R9),
		Emit.imm(R10, least_class * class_bytes),
		Emit.mark("runtime_heap_lists_class"),
		Emit.load(Rsi, class_place({ offset: R10, past: 16 })),
		Emit.mark("runtime_heap_lists_block"),
		Emit.test(Rsi, Rsi),
		Emit.jcc(E, "runtime_heap_lists_classed"),
		Emit.plus_imm(R9, 1),
		Emit.load(Rax, free_blocks_place),
		Emit.cmp(R9, Rax),
		Emit.jcc(A, "runtime_heap_bad"),
		Emit.load(Rax, first_page_place),
		Emit.cmp(Rsi, Rax),
		Emit.jcc(B, "runtime_heap_bad"),
		Emit.load(Rax, next_page_place),
		Emit.cmp(Rsi, Rax),
		Emit.jcc(Ae, "runtime_heap_bad"),
		Emit.load(Rax, Emit.mem(Rsi, 0)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
	],
	page_number_items({ to: Rcx, from: Rsi }),
	[
		Emit.byte_load(Rdx, table_entry(Rcx)),
		Emit.shl(Rdx, class_shift),
		Emit.cmp(Rdx, R10),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.load(Rax, class_place({ offset: R10, past: 8 })),
		Emit.minus_imm(Rax, 1),
		Emit.test(Rax, Rsi),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.load(Rsi, Emit.mem(Rsi, 8)),
		Emit.jmp("runtime_heap_lists_block"),
		Emit.mark("runtime_heap_lists_classed"),
		Emit.plus_imm(R10, class_bytes),
		Emit.cmp_imm(R10, most_class * class_bytes),
		Emit.jcc(Be, "runtime_heap_lists_class"),
		Emit.load(Rax, free_blocks_place),
		Emit.cmp(R9, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.zero(R9),
		Emit.load(Rsi, runs_place),
		Emit.mark("runtime_heap_lists_run"),
		Emit.test(Rsi, Rsi),
		Emit.jcc(E, "runtime_heap_lists_ran"),
		Emit.load(Rax, first_page_place),
		Emit.cmp(Rsi, Rax),
		Emit.jcc(B, "runtime_heap_bad"),
		Emit.load(Rax, next_page_place),
		Emit.cmp(Rsi, Rax),
		Emit.jcc(Ae, "runtime_heap_bad"),
		Emit.mov(Rax, Rsi),
		Emit.bit_and_imm(Rax, page_size - 1),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.load(R10, Emit.mem(Rsi, 8)),
		Emit.test(R10, R10),
		Emit.jcc(E, "runtime_heap_bad"),
		Emit.plus(R9, R10),
		Emit.load(Rax, free_pages_place),
		Emit.cmp(R9, Rax),
		Emit.jcc(A, "runtime_heap_bad"),
	],
	page_number_items({ to: Rdx, from: Rsi }),
	[
		Emit.mark("runtime_heap_lists_page"),
		Emit.byte_load(Rax, table_entry(Rdx)),
		Emit.test(Rax, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.plus_imm(Rdx, 1),
		Emit.minus_imm(R10, 1),
		Emit.jcc(Ne, "runtime_heap_lists_page"),
		Emit.load(Rsi, Emit.mem(Rsi, 0)),
		Emit.jmp("runtime_heap_lists_run"),
		Emit.mark("runtime_heap_lists_ran"),
		Emit.load(Rax, free_pages_place),
		Emit.cmp(R9, Rax),
		Emit.jcc(Ne, "runtime_heap_bad"),
		Emit.ret,
	],
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
## size is `r10`, checked: a kind's code, no mark, and asked for more than
## `rdi` bytes with its header and at most the block size. The block's
## first byte past the header and its last byte must each find the block
## by `Heap.block_start`. It counts the block, its bytes asked and its
## block size. An Int32 or a Numbers array's items, from its items' address
## to its length, must each be a number, and an Int32 array's a whole
## number of 32 bits that isn't -0. It changes `rax`, `rcx`, `rdx`, `rsi`,
## `rdi`, `xmm0` and `xmm1`.
block_check_items : List(Assembly.Statement)
block_check_items = [
	block_header_check_items,
	[
		Emit.load(Rax, Emit.mem(R9, 0)),
		Emit.shr(Rax, 48),
		Emit.cmp_imm(Rax, Heap.element_code(Numbers)),
		Emit.jcc(B, "runtime_heap_block_checked"),
		Emit.load(Rcx, Emit.mem(R9, 8)),
		Emit.load(Rdi, Emit.mem(R9, 24)),
		Emit.mark("runtime_heap_block_item"),
		Emit.test(Rcx, Rcx),
		Emit.jcc(E, "runtime_heap_block_checked"),
		Emit.load(Rdx, Emit.mem(Rdi, 0)),
		Emit.mov(Rsi, Rdx),
		Emit.shr(Rsi, Boxing.tag_shift),
		Emit.cmp_imm(Rsi, Boxing.first_tag),
		Emit.jcc(Ae, "runtime_heap_bad_element"),
		Emit.cmp_imm(Rax, Heap.element_code(Int32)),
		Emit.jcc(Ne, "runtime_heap_block_next"),
		Emit.to_xmm(Xmm0, Rdx),
		Instruction(Cvttsd2si32({ to: Rsi, from: Xmm0 })),
		Instruction(Cvtsi2sd32({ to: Xmm1, from: Rsi })),
		Instruction(MovqFromXmm({ to: Rsi, from: Xmm1 })),
		Emit.cmp(Rsi, Rdx),
		Emit.jcc(Ne, "runtime_heap_bad_element"),
		Emit.mark("runtime_heap_block_next"),
		Emit.plus_imm(Rdi, 8),
		Emit.minus_imm(Rcx, 1),
		Emit.jmp("runtime_heap_block_item"),
		Emit.mark("runtime_heap_block_checked"),
		Emit.ret,
	],
].join()

## The header's checks of `runtime_heap_block`.
block_header_check_items : List(Assembly.Statement)
block_header_check_items = [
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
]

expect Heap.kinds.map(Heap.kind_code) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
# A kind only falls, so its codes fall with it, and each fits the header's
# byte that `Heap.element_kind_place` names.
expect {
	codes = [Int32, Numbers, Values].map(Heap.element_code)
	codes == [15, 14, 2] and codes.all(|code| code < 256)
}
expect word_bits("heapwalk") == 0x6b6c617770616568
# The state's places fit before the first page's room, and every
# displacement past `r15` fits 32 bits.
expect state_size == 152 + 32 * 12 + 32768
# A header's bytes asked lie below its mark: the heap holds no block of
# 2^47 bytes.
expect Heap.mapped_size < mark_bit
