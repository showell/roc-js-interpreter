## This module wraps machine code as a static Linux x86-64 executable: an
## ELF header, one program header and the code, in one file the kernel loads
## as it is. There are no sections, no libc and no dynamic linker: the kernel
## maps the whole file at `load_address`, read and execute, and jumps to the
## code's first byte.
##
## The code and its data share the one segment. Data in it is read-only,
## which a string to print is; a program that writes memory will map its
## own.
import X86

Elf :: [].{

	## Where the kernel maps the file's first byte.
	load_address : U64
	load_address = 0x400000

	## Where the code starts in the file, and so in memory past
	## `load_address`: just after the two headers.
	code_offset : U64
	code_offset = elf_header_size + program_header_size

	## The executable whose entry point is the first byte of `code`.
	executable : List(U8) -> List(U8)
	executable = |code| {
		file_size = Elf.code_offset + code.len()
		header = [
			0x7F,
			'E',
			'L',
			'F',
			class_64_bit,
			little_endian,
			1,
			system_v_abi,
			0,
			0,
			0,
			0,
			0,
			0,
			0,
			0,
		]
		with_header = append_fields(
			header,
			[
				{ value: executable_type, size: 2 },
				{ value: machine_x86_64, size: 2 },
				{ value: 1, size: 4 },
				{ value: Elf.load_address + Elf.code_offset, size: 8 },
				{ value: elf_header_size, size: 8 },
				{ value: 0, size: 8 },
				{ value: 0, size: 4 },
				{ value: elf_header_size, size: 2 },
				{ value: program_header_size, size: 2 },
				{ value: 1, size: 2 },
				{ value: section_header_size, size: 2 },
				{ value: 0, size: 2 },
				{ value: 0, size: 2 },
			],
		)
		with_program_header = append_fields(
			with_header,
			[
				{ value: loadable_segment, size: 4 },
				{ value: readable + executable_flag, size: 4 },
				{ value: 0, size: 8 },
				{ value: Elf.load_address, size: 8 },
				{ value: Elf.load_address, size: 8 },
				{ value: file_size, size: 8 },
				{ value: file_size, size: 8 },
				{ value: page_size, size: 8 },
			],
		)
		with_program_header.concat(code)
	}

	expect Elf.executable([]).len() == 120
	expect Elf.executable([0xC3]).len() == 121
	expect header_hex(Elf.executable([0xC3]), { start: 0, len: 4 }) == "7f 45 4c 46"
	# The entry point, 0x400078, at byte 24.
	expect header_hex(Elf.executable([0xC3]), { start: 24, len: 8 }) == "78 00 40 00 00 00 00 00"
	# The segment's flags (R and X) at byte 68, and its file size at 96.
	expect header_hex(Elf.executable([0xC3]), { start: 68, len: 4 }) == "05 00 00 00"
	expect {
		file_size = header_hex(Elf.executable([0xC3, 0xC3]), { start: 96, len: 8 })
		file_size == "7a 00 00 00 00 00 00 00"
	}
	expect Elf.executable([0xC3]).last() == Ok(0xC3)
}

elf_header_size : U64
elf_header_size = 64

program_header_size : U64
program_header_size = 56

section_header_size : U64
section_header_size = 64

class_64_bit : U8
class_64_bit = 2

little_endian : U8
little_endian = 1

system_v_abi : U8
system_v_abi = 0

executable_type : U64
executable_type = 2

machine_x86_64 : U64
machine_x86_64 = 0x3E

loadable_segment : U64
loadable_segment = 1

readable : U64
readable = 4

executable_flag : U64
executable_flag = 1

page_size : U64
page_size = 0x1000

## Each field's value appended to `out`, little-endian, in its size.
append_fields : List(U8), List({ value : U64, size : U64 }) -> List(U8)
append_fields = |out, fields| {
	var $bytes = out
	for field in fields {
		$bytes = X86.append_little_endian(
			$bytes,
			{ value: field.value.to_i64_wrap(), size: field.size },
		)
	}
	$bytes
}

## Part of an executable's headers as hex, for the expects.
header_hex : List(U8), { start : U64, len : U64 } -> Str
header_hex = |file, part| X86.hex_text(file.sublist(part))
