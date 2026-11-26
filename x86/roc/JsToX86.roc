app [main!] { js: "../../js/roc/main.roc" }

# The JavaScript subset compiled to a static Linux x86-64 executable: the
# program is parsed and compiled to bytecode by js/roc's own front end, as
# js-vm compiles it, then lowered to machine code (Lowering.roc), assembled
# (Assembly.roc) and wrapped as an executable (Elf.roc), every byte here.
#
#   js-x86 "<program>"
#
# It runs on Roc's default platform, whose one effect writes text to
# stdout, so it prints the executable's bytes as hex (X86.hex_text: two
# lowercase digits a byte, a space between) and nothing else; x86/fib.shale
# turns the hex back into the file. A program the parser refuses, one the
# bytecode compiler refuses, and one that uses what the lowering doesn't
# compile yet each end with a line `js-x86: <why>` and exit 1.
import js.Compile
import js.Parser
import Assembly
import Elf
import Lowering
import X86

main! = |arguments| {
	match (arguments.get(0), arguments.get(1)) {
		(Ok(src), Err(_)) => write_program!(src)
		(Ok(src), Ok("inlined")) => write_inlined!(src)
		_ => {
			echo!("usage: js-x86 \"<program>\" [inlined]\n")
			Err(Exit(2))
		}
	}
}

write_program! : Str => Try({}, [Exit(I8)])
write_program! = |src| {
	match executable_of(src) {
		Ok(file) => {
			echo!(X86.hex_text(file))
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## The line `inlined: <sites> sites, <instructions> instructions` for a
## program that lowers:
## how many call sites Inlining put in line, and the instructions their
## bodies placed, for x86/programs.shale's held count.
write_inlined! : Str => Try({}, [Exit(I8)])
write_inlined! = |src| {
	match lowering_of(src) {
		Ok(lowered) => {
			sites = lowered.inlined.sites.to_str()
			instructions = lowered.inlined.instructions.to_str()
			echo!("inlined: ${sites} sites, ${instructions} instructions\n")
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## The executable a program compiles to, or why it doesn't.
executable_of : Str -> Try(List(U8), Str)
executable_of = |src| {
	lowered = lowering_of(src)?
	match Assembly.assemble(lowered.statements) {
		Ok(code) => Ok(Elf.executable(code))
		Err(UnknownLabel(label)) => Err("no label ${label}")
		Err(DuplicateLabel(label)) => Err("the label ${label} is marked twice")
	}
}

## A program's lowering, or why it has none.
lowering_of : Str -> Try(
	{ statements : List(Assembly.Statement), inlined : { sites : U64, instructions : U64 } },
	Str,
)
lowering_of = |src| {
	tree = match Parser.program_of(src, Core) {
		Ok(parsed) => parsed
		Err(fault) => {
			place = "line ${fault.line.to_str()}, column ${fault.column.to_str()}"
			return Err("${fault.why} (${place})")
		}
	}
	program = match Compile.program(tree) {
		Ok(compiled) => compiled
		Err(Unsupported(why)) => return Err(why)
	}
	match Lowering.program_lowering(program) {
		Ok(lowered) => Ok(lowered)
		Err(Refused(why)) => Err("refused: ${why}")
	}
}
